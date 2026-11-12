//! Group commit, for the benchmark client only. It is not part of the store
//! and is not a supported way to use it.
//!
//! The store is single-threaded by design. Batching writes from many clients
//! is the job of whatever sits above it, and in a replicated store that is
//! the replication layer. This file exists so that `bean-bench` can be run
//! with many threads and compared with RocksDB, which batches the writes of
//! its threads inside the engine.
//!
//! It lets several threads each make single durable writes to one store,
//! while the store only ever sees one writer.
//!
//! The store is used from one thread at a time and syncs every batch it is
//! given. If many threads each wrote one operation, each would pay for a
//! sync of its own. A `GroupCommitter` sits in front of the store and shares
//! the syncs out:
//!
//! - A thread adds its operation to the group that is being collected.
//! - If no group is being written, that thread becomes the leader. It takes
//!   everything collected so far, writes it to the store as one batch, and
//!   wakes the threads whose operations were in it.
//! - Operations that arrive while the leader is writing collect into the
//!   next group. When the leader finishes, one of the waiting threads leads
//!   that group.
//!
//! A call returns once the group holding its operation is durable. The more
//! threads there are, the more operations share each sync.
//!
//! Threads can also read through the committer. The store cannot be read
//! while it is written to, and it reads a table through one buffer of its
//! own, so a reader takes a lock alone, and the leader holds the same lock
//! for the whole time it writes a group, sync included. A read sees all of a
//! group or none of it.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const kv = @import("kv.zig");
const write_batch = @import("write_batch.zig");
const WriteBatch = write_batch.WriteBatch;

pub const GroupCommitter = struct {
    io: Io,
    /// Only the thread that is leading a group writes to the store.
    store: *kv.Store,
    /// Held shared by a thread that is reading from the store, and held
    /// alone by the leader while it writes a group to the store.
    readers: Io.RwLock,
    /// Guards every field below.
    mutex: Io.Mutex,
    /// Signalled each time a group has been written.
    group_written: Io.Condition,
    /// Collects the operations of the next group.
    filling: WriteBatch,
    /// Holds the group the leader is writing. Empty when there is no leader.
    writing: WriteBatch,
    /// The number the group in `filling` will have when it is written.
    /// Groups are numbered from 1.
    filling_group: u64,
    /// The number of the last group that was written, or that failed.
    finished_group: u64,
    /// Whether a thread is writing a group to the store.
    leader_active: bool,
    /// The error of the first group that failed, if one has. Every group
    /// from `failed_from_group` on fails with it.
    failure: ?kv.Store.WriteError,
    failed_from_group: u64,
    /// How many groups have been written without an error.
    groups_written: u64,

    pub const Error = error{
        /// The key is longer than `write_batch.key_size_max`.
        KeyTooLarge,
        /// The value is longer than `write_batch.value_size_max`.
        ValueTooLarge,
    } || kv.Store.WriteError;

    pub const GetError = kv.Store.GetError;

    /// Allocates the two batches. `gpa` is not retained. The committer must
    /// not be moved once a thread is using it, and `store` must outlive it.
    pub fn init(gpa: Allocator, io: Io, store: *kv.Store) Allocator.Error!GroupCommitter {
        var filling: WriteBatch = try .init(gpa);
        errdefer filling.deinit(gpa);
        const writing: WriteBatch = try .init(gpa);

        return .{
            .io = io,
            .store = store,
            .readers = .init,
            .mutex = .init,
            .group_written = .init,
            .filling = filling,
            .writing = writing,
            .filling_group = 1,
            .finished_group = 0,
            .leader_active = false,
            .failure = null,
            .failed_from_group = 0,
            .groups_written = 0,
        };
    }

    /// `gpa` must be the allocator passed to `init`. No thread may be in a
    /// call on the committer.
    pub fn deinit(self: *GroupCommitter, gpa: Allocator) void {
        assert(!self.leader_active);
        self.filling.deinit(gpa);
        self.writing.deinit(gpa);
        self.* = undefined;
    }

    /// Sets `key` to `value`. Returns once the write is durable. Safe to
    /// call from many threads at once.
    ///
    /// After a group fails, every later call fails with the same error.
    pub fn put(self: *GroupCommitter, key: []const u8, value: []const u8) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const group = try self.addOperation(.{ .put = .{ .key = key, .value = value } });
        try self.waitForGroup(group);
    }

    /// Deletes `key`. Returns once the write is durable. Safe to call from
    /// many threads at once.
    pub fn delete(self: *GroupCommitter, key: []const u8) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const group = try self.addOperation(.{ .delete = .{ .key = key } });
        try self.waitForGroup(group);
    }

    /// Copies the value for `key` into `buffer` and returns the copy, or
    /// returns `null` if the key is not present. Safe to call from many
    /// threads at once, while other threads write. A read waits while a
    /// group is being written, and while another read is in progress: the
    /// store reads a table through one buffer of its own, so only one
    /// thread may be in `Store.get` at a time.
    ///
    /// Reports `BufferTooSmall` if the value does not fit in `buffer`.
    pub fn get(self: *GroupCommitter, key: []const u8, buffer: []u8) GetError!?[]u8 {
        self.readers.lockUncancelable(self.io);
        defer self.readers.unlock(self.io);

        return self.store.get(key, buffer);
    }

    /// How many groups have been written without an error. Each one was one
    /// batch and one sync.
    pub fn groupsWritten(self: *GroupCommitter) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.groups_written;
    }

    /// Adds one operation to the group being collected, and returns that
    /// group's number. If the group has no room, this first waits for it to
    /// be written. The mutex must be held.
    fn addOperation(self: *GroupCommitter, operation: write_batch.Operation) Error!u64 {
        while (true) {
            if (self.failure) |err| {
                return err;
            }

            const added = switch (operation) {
                .put => |put_operation| self.filling.put(put_operation.key, put_operation.value),
                .delete => |delete_operation| self.filling.delete(delete_operation.key),
            };
            added catch |err| switch (err) {
                error.KeyTooLarge => return error.KeyTooLarge,
                error.ValueTooLarge => return error.ValueTooLarge,
                error.BatchFull => {
                    // The group is full. Once it has been written there is
                    // room again.
                    self.writeOrWait();
                    continue;
                },
            };
            return self.filling_group;
        }
    }

    /// Returns once group number `group` has been written, or with its error
    /// if it failed. The mutex must be held.
    fn waitForGroup(self: *GroupCommitter, group: u64) Error!void {
        while (self.finished_group < group) {
            self.writeOrWait();
        }

        if (self.failure) |err| {
            if (group >= self.failed_from_group) {
                return err;
            }
        }
    }

    /// Makes progress on getting groups written: leads the group being
    /// collected if nobody is leading, and otherwise waits for the leader to
    /// finish. The mutex must be held.
    fn writeOrWait(self: *GroupCommitter) void {
        if (self.leader_active) {
            self.group_written.waitUncancelable(self.io, &self.mutex);
            return;
        }
        self.writeGroup();
    }

    /// Writes the group being collected to the store, as its leader. The
    /// mutex must be held; it is released while the store is written to, so
    /// that other threads can add to the next group meanwhile.
    fn writeGroup(self: *GroupCommitter) void {
        assert(!self.leader_active);
        assert(self.filling.count() > 0);
        assert(self.writing.count() == 0);

        self.leader_active = true;
        std.mem.swap(WriteBatch, &self.filling, &self.writing);
        const group = self.filling_group;
        self.filling_group += 1;

        self.mutex.unlock(self.io);
        const result = self.writeToStore();
        self.mutex.lockUncancelable(self.io);

        self.writing.clear();
        if (result) |_| {
            self.groups_written += 1;
        } else |err| {
            if (self.failure == null) {
                self.failure = err;
                self.failed_from_group = group;
            }
        }
        self.finished_group = group;
        self.leader_active = false;
        self.group_written.broadcast(self.io);
    }

    /// Writes the group in `writing` to the store, with readers kept out.
    /// Only the leader calls this, with the mutex released.
    fn writeToStore(self: *GroupCommitter) kv.Store.WriteError!void {
        self.readers.lockUncancelable(self.io);
        defer self.readers.unlock(self.io);
        try self.store.write(&self.writing);
    }
};

const testing = std.testing;

test "one thread writes through the committer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store: kv.Store = try .open(testing.allocator, testing.io, tmp.dir, .{});
    defer store.close(testing.allocator);
    var committer: GroupCommitter = try .init(testing.allocator, testing.io, &store);
    defer committer.deinit(testing.allocator);

    try committer.put("a", "1");
    try committer.put("b", "2");
    try committer.delete("a");

    // With one thread there is nobody to share a sync with.
    try testing.expectEqual(@as(u64, 3), committer.groupsWritten());
    try testing.expectEqual(@as(u64, 3), store.opLatest());
    var value_buffer: [8]u8 = undefined;
    try testing.expect(try store.get("a", &value_buffer) == null);
    try testing.expectEqualSlices(u8, "2", (try store.get("b", &value_buffer)).?);
}

test "a key over the limit is rejected and the committer stays usable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store: kv.Store = try .open(testing.allocator, testing.io, tmp.dir, .{});
    defer store.close(testing.allocator);
    var committer: GroupCommitter = try .init(testing.allocator, testing.io, &store);
    defer committer.deinit(testing.allocator);

    const long_key: [write_batch.key_size_max + 1]u8 = @splat('k');
    try testing.expectError(error.KeyTooLarge, committer.put(&long_key, "1"));
    try testing.expectError(error.KeyTooLarge, committer.delete(&long_key));

    try committer.put("a", "1");
    try testing.expectEqual(@as(u64, 1), committer.groupsWritten());
    var value_buffer: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, "1", (try store.get("a", &value_buffer)).?);
}

const test_thread_count = 8;
const test_puts_per_thread = 40;

/// Writes `test_puts_per_thread` keys that no other thread writes.
fn testWriter(committer: *GroupCommitter, thread_number: usize, failed: *std.atomic.Value(bool)) void {
    var key_buffer: [16]u8 = undefined;
    for (0..test_puts_per_thread) |put_number| {
        const key = std.fmt.bufPrint(&key_buffer, "t{d:0>2}-{d:0>4}", .{ thread_number, put_number }) catch unreachable;
        committer.put(key, key) catch {
            failed.store(true, .monotonic);
            return;
        };
    }
}

test "many threads share syncs and every write is there" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const write_count = test_thread_count * test_puts_per_thread;
    var groups_written: u64 = 0;
    {
        var store: kv.Store = try .open(testing.allocator, testing.io, tmp.dir, .{});
        defer store.close(testing.allocator);
        var committer: GroupCommitter = try .init(testing.allocator, testing.io, &store);
        defer committer.deinit(testing.allocator);

        var failed: std.atomic.Value(bool) = .init(false);
        var threads: [test_thread_count]std.Thread = undefined;
        for (&threads, 0..) |*thread, thread_number| {
            thread.* = try std.Thread.spawn(.{}, testWriter, .{ &committer, thread_number, &failed });
        }
        for (threads) |thread| {
            thread.join();
        }
        try testing.expect(!failed.load(.monotonic));

        // Every group is one batch in the store, and holds at least one
        // write and at most all of them.
        groups_written = committer.groupsWritten();
        try testing.expectEqual(groups_written, store.opLatest());
        try testing.expect(groups_written >= 1);
        try testing.expect(groups_written <= write_count);
    }

    // Every write is durable: it is there after the store is opened again.
    var store: kv.Store = try .open(testing.allocator, testing.io, tmp.dir, .{});
    defer store.close(testing.allocator);
    try testing.expectEqual(groups_written, store.opLatest());

    var key_buffer: [16]u8 = undefined;
    var value_buffer: [16]u8 = undefined;
    var entries_found: usize = 0;
    for (0..test_thread_count) |thread_number| {
        for (0..test_puts_per_thread) |put_number| {
            const key = try std.fmt.bufPrint(&key_buffer, "t{d:0>2}-{d:0>4}", .{ thread_number, put_number });
            const value = try store.get(key, &value_buffer);
            try testing.expect(value != null);
            try testing.expectEqualSlices(u8, key, value.?);
            entries_found += 1;
        }
    }
    try testing.expectEqual(@as(usize, write_count), entries_found);
}

/// Reads keys that the writer threads are writing, until told to stop. Every
/// value must be absent or whole: a key's value is the key itself.
fn testReader(committer: *GroupCommitter, stop: *std.atomic.Value(bool), failed: *std.atomic.Value(bool)) void {
    var key_buffer: [16]u8 = undefined;
    var value_buffer: [16]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();

    while (!stop.load(.monotonic)) {
        const thread_number = random.uintLessThan(usize, test_thread_count);
        const put_number = random.uintLessThan(usize, test_puts_per_thread);
        const key = std.fmt.bufPrint(&key_buffer, "t{d:0>2}-{d:0>4}", .{ thread_number, put_number }) catch unreachable;

        const value = committer.get(key, &value_buffer) catch {
            failed.store(true, .monotonic);
            return;
        };
        if (value != null) {
            if (!std.mem.eql(u8, key, value.?)) {
                failed.store(true, .monotonic);
                return;
            }
        }
    }
}

test "threads read whole values while other threads write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store: kv.Store = try .open(testing.allocator, testing.io, tmp.dir, .{});
    defer store.close(testing.allocator);
    var committer: GroupCommitter = try .init(testing.allocator, testing.io, &store);
    defer committer.deinit(testing.allocator);

    var stop: std.atomic.Value(bool) = .init(false);
    var failed: std.atomic.Value(bool) = .init(false);

    const reader_count = 4;
    var readers: [reader_count]std.Thread = undefined;
    for (&readers) |*reader| {
        reader.* = try std.Thread.spawn(.{}, testReader, .{ &committer, &stop, &failed });
    }
    var writers: [test_thread_count]std.Thread = undefined;
    for (&writers, 0..) |*writer, thread_number| {
        writer.* = try std.Thread.spawn(.{}, testWriter, .{ &committer, thread_number, &failed });
    }

    for (writers) |writer| {
        writer.join();
    }
    stop.store(true, .monotonic);
    for (readers) |reader| {
        reader.join();
    }
    try testing.expect(!failed.load(.monotonic));

    // Once the writers are done, every key reads back through the committer.
    var key_buffer: [16]u8 = undefined;
    var value_buffer: [16]u8 = undefined;
    const last_key = try std.fmt.bufPrint(&key_buffer, "t{d:0>2}-{d:0>4}", .{ test_thread_count - 1, test_puts_per_thread - 1 });
    const value = try committer.get(last_key, &value_buffer);
    try testing.expect(value != null);
    try testing.expectEqualSlices(u8, last_key, value.?);
}

test "get reports a buffer that is too small for the value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store: kv.Store = try .open(testing.allocator, testing.io, tmp.dir, .{});
    defer store.close(testing.allocator);
    var committer: GroupCommitter = try .init(testing.allocator, testing.io, &store);
    defer committer.deinit(testing.allocator);

    try committer.put("a", "value");

    var small_buffer: [4]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, committer.get("a", &small_buffer));

    var exact_buffer: [5]u8 = undefined;
    const value = try committer.get("a", &exact_buffer);
    try testing.expectEqualSlices(u8, "value", value.?);

    try testing.expect(try committer.get("missing", &exact_buffer) == null);
}
