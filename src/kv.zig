//! The key-value store: an ordered map from byte-string keys to byte-string
//! values that survives a crash.
//!
//! A `Store` lives in one directory. Every write goes to the write-ahead log
//! and is synced before it is applied to the memtable, so a write that
//! returned without an error is durable. Opening a store replays its log.
//!
//! Writes are grouped into a `WriteBatch`, which is applied as a unit: after
//! a crash either every operation in it is present or none is. A batch
//! becomes exactly one record in the log.
//!
//! For now everything the store holds has to fit in the memtable. Writing
//! memtables out to tables comes next, and until then a store that has filled
//! its memtable reports `StoreFull`.
//!
//! A directory is open in at most one `Store` at a time. `open` takes a lock
//! on a `LOCK` file in the directory and reports `StoreAlreadyOpen` if
//! another store holds it.
//!
//! The store is not safe to use from more than one thread.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const MemTable = @import("memtable.zig").MemTable;
const sstable = @import("sstable.zig");
const wal = @import("wal.zig");
const write_batch = @import("write_batch.zig");
const WriteBatch = write_batch.WriteBatch;

comptime {
    // A flushed memtable must fit in one table. `sstable.table_size_max` is
    // the memtable's size, which holds as long as an entry takes no more
    // room in a table than it does in the memtable.
    assert(MemTable.buffer_size_max <= sstable.table_size_max);
    assert(sstable.entry_overhead <= MemTable.entry_overhead_min);

    // A batch is the payload of one log record.
    assert(write_batch.size_max <= wal.payload_size_format_max);

    // Every key and value a batch accepts is one the memtable can hold, so
    // applying a valid batch never passes the memtable an oversized entry.
    assert(write_batch.key_size_max <= MemTable.key_size_max);
    assert(write_batch.value_size_max <= MemTable.value_size_max);

    // Any batch fits in an empty memtable, so a batch can always be applied
    // after a flush. Each operation takes at most the memtable's largest
    // overhead beyond its own bytes in the batch, and a batch holds the most
    // operations when every one of them is the smallest.
    const overhead_max = MemTable.entrySizeMax(0, 0) - write_batch.operation_size_min;
    const batch_memtable_size_max = write_batch.size_max + write_batch.operation_count_max * overhead_max;
    assert(batch_memtable_size_max <= MemTable.buffer_size_max - MemTable.buffer_size_min);
}

/// The name of the store's log file in its directory.
const log_file_name = "bean.log";

/// The name of the file a store holds locked for as long as it is open, so
/// that a directory is never open in two stores at once. The file is empty,
/// and is left in the directory when the store is closed or when `open`
/// fails: only the lock on it means anything.
const lock_file_name = "LOCK";

/// The longest payload the store's log accepts: one batch.
const log_payload_size_max: u32 = write_batch.size_max;

pub const Options = struct {
    /// Create the store if `dir` does not hold one yet.
    create_if_missing: bool = true,
};

pub const Store = struct {
    io: Io,
    /// Held locked from `open` to `close`.
    lock_file: Io.File,
    memtable: MemTable,
    log: wal.Writer,
    /// A batch for `put` and `delete` to build their one operation in. Its
    /// buffer also holds each record while the log is replayed in `open`.
    scratch: WriteBatch,
    /// Set when a write to the log has failed. The log's state is then
    /// unknown, so every later write is refused.
    broken: bool,

    /// What `open` can report. `wal.Reader.open` can also report
    /// `IncompleteLog`, which is not here: `open` handles it itself, by
    /// creating the log again or by reporting `StoreNotFound`.
    pub const OpenError = error{
        /// `dir` holds no store and `create_if_missing` is false.
        StoreNotFound,
        /// Another store has `dir` open, in this process or another one.
        StoreAlreadyOpen,
        /// The log file does not start with a valid log file header.
        NotALog,
        /// The log is damaged in a way a crash during a write cannot explain.
        Corrupt,
        /// The log holds a record that is not a valid batch.
        InvalidBatch,
        /// The log holds more than fits in the memtable.
        LogTooLargeForMemtable,
    } || Allocator.Error || Io.Dir.DeleteFileError ||
        Io.File.OpenError || Io.File.LengthError || Io.File.ReadPositionalError ||
        wal.Writer.CreateError || wal.Writer.OpenError;

    /// What writing a batch that holds at least one operation can report.
    pub const CommitError = error{
        /// The memtable has no room for the batch. Until the store can flush
        /// memtables to files, this means the store is full.
        StoreFull,
        /// An earlier write failed, and the store must be closed and opened
        /// again before it is written to.
        StoreBroken,
    } || Io.File.WritePositionalError || Io.File.SyncError;

    /// `write` also rejects a batch with nothing in it.
    pub const WriteError = error{
        /// The batch holds no operations.
        EmptyBatch,
    } || CommitError;

    /// `put` also rejects a key or value over the limit.
    pub const PutError = error{
        /// The key is longer than `write_batch.key_size_max`.
        KeyTooLarge,
        /// The value is longer than `write_batch.value_size_max`.
        ValueTooLarge,
    } || CommitError;

    /// `delete` also rejects a key over the limit.
    pub const DeleteError = error{
        /// The key is longer than `write_batch.key_size_max`.
        KeyTooLarge,
    } || CommitError;

    /// Reads cannot fail yet. They will once they can touch files, so
    /// callers handle an error from the start.
    pub const ReadError = error{};

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// A forward-only cursor over the store's live entries in key order.
    /// Deleted keys are skipped. The cursor, and every slice it returned,
    /// is valid until the next write to the store.
    ///
    /// The cursor points at the store it came from, so the store must not be
    /// moved or closed while the cursor is in use.
    pub const Iterator = struct {
        memtable_iterator: MemTable.Iterator,

        /// Positions the cursor at the first entry.
        pub fn seekToFirst(self: *Iterator) void {
            self.memtable_iterator.seekToFirst();
        }

        /// Positions the cursor at the first entry whose key is >= `key`.
        pub fn seek(self: *Iterator, key: []const u8) ReadError!void {
            self.memtable_iterator.seek(key);
        }

        /// Returns the entry at the cursor and advances past it, or returns
        /// `null` after the last entry.
        pub fn next(self: *Iterator) ReadError!?Entry {
            while (true) {
                // The memtable gives the newest entry for each key.
                const found = self.memtable_iterator.next();
                if (found == null) {
                    return null;
                }
                const entry = found.?;

                // A tombstone means the key was deleted.
                if (entry.value == null) {
                    continue;
                }
                return .{ .key = entry.key, .value = entry.value.? };
            }
        }
    };

    /// Opens the store in `dir`, replaying its log. `gpa` is used only here,
    /// to allocate everything the store will need, and is not retained.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, options: Options) OpenError!Store {
        // The lock comes first: replaying the log can truncate or remove it,
        // which must not happen under a store that is already open.
        const lock_file = try lockDir(io, dir);
        errdefer lock_file.close(io);

        var memtable: MemTable = try .init(gpa, MemTable.buffer_size_max);
        errdefer memtable.deinit(gpa);
        var scratch: WriteBatch = try .init(gpa);
        errdefer scratch.deinit(gpa);

        // Nothing is in the scratch batch yet, so its buffer is free to hold
        // the records being replayed.
        const log = try openLog(io, dir, options, &memtable, scratch.buffer);

        return .{
            .io = io,
            .lock_file = lock_file,
            .memtable = memtable,
            .log = log,
            .scratch = scratch,
            .broken = false,
        };
    }

    /// `gpa` must be the allocator passed to `open`.
    pub fn close(self: *Store, gpa: Allocator) void {
        self.log.close();
        self.memtable.deinit(gpa);
        self.scratch.deinit(gpa);
        // Closing the file releases the lock.
        self.lock_file.close(self.io);
        self.* = undefined;
    }

    /// Applies `batch` as a unit. When this returns without an error, the
    /// batch is durable.
    ///
    /// `EmptyBatch`, `StoreFull` and `StoreBroken` are reported before
    /// anything is written. `EmptyBatch` and `StoreFull` leave the store
    /// unchanged and usable.
    ///
    /// After any other error the batch may or may not be in the log: it can
    /// appear when the store is next opened. Every later write returns
    /// `StoreBroken` until the store is closed and opened again.
    pub fn write(self: *Store, batch: *const WriteBatch) WriteError!void {
        // An empty batch is never logged: replay rejects an empty record.
        if (batch.count() == 0) {
            return error.EmptyBatch;
        }
        try self.commit(batch);
    }

    /// Logs `batch` and then applies it to the memtable. `batch` must hold
    /// at least one operation.
    fn commit(self: *Store, batch: *const WriteBatch) CommitError!void {
        assert(batch.count() > 0);
        if (self.broken) {
            return error.StoreBroken;
        }
        const batch_bytes = batch.bytes();

        // The batch goes to the log only if all of it can then be applied.
        if (memtableSizeMax(batch_bytes) > self.memtable.bytesFree()) {
            return error.StoreFull;
        }

        _ = self.log.append(batch_bytes) catch |err| switch (err) {
            // A batch is never longer than the log's payload limit.
            error.PayloadTooLarge => unreachable,
            else => |other| {
                self.broken = true;
                return other;
            },
        };
        applyBatch(&self.memtable, batch_bytes);
    }

    /// Writes a batch holding one put. `StoreFull` and `StoreBroken` mean
    /// what they do for `write`.
    pub fn put(self: *Store, key: []const u8, value: []const u8) PutError!void {
        self.scratch.clear();
        self.scratch.put(key, value) catch |err| switch (err) {
            error.KeyTooLarge => return error.KeyTooLarge,
            error.ValueTooLarge => return error.ValueTooLarge,
            // One operation always fits in an empty batch.
            error.BatchFull => unreachable,
        };
        try self.commit(&self.scratch);
    }

    /// Writes a batch holding one delete. Deleting a key that is not present
    /// is not an error. `StoreFull` and `StoreBroken` mean what they do for
    /// `write`.
    pub fn delete(self: *Store, key: []const u8) DeleteError!void {
        self.scratch.clear();
        self.scratch.delete(key) catch |err| switch (err) {
            error.KeyTooLarge => return error.KeyTooLarge,
            // A delete has no value.
            error.ValueTooLarge => unreachable,
            // One operation always fits in an empty batch.
            error.BatchFull => unreachable,
        };
        try self.commit(&self.scratch);
    }

    /// Returns the value for `key`, or `null` if the key is not present. The
    /// value is valid until the next write to the store.
    pub fn get(self: *Store, key: []const u8) ReadError!?[]const u8 {
        const lookup = self.memtable.get(key);
        switch (lookup) {
            .value => |value| return value,
            .tombstone => return null,
            .absent => return null,
        }
    }

    /// Returns a cursor positioned at the first entry.
    ///
    /// The cursor keeps a pointer to this store, so the store must not be
    /// moved or closed while the cursor is in use.
    pub fn iterator(self: *Store) Iterator {
        return .{ .memtable_iterator = self.memtable.iterator() };
    }

    /// The op number of the last batch written, or 0 if there has been none.
    /// Each batch is given the next op number.
    pub fn opLatest(self: *const Store) u64 {
        return self.log.last.op;
    }
};

/// Takes the lock that marks `dir` as open in a store. The lock is held until
/// the returned file is closed, or the process ends.
fn lockDir(io: Io, dir: Io.Dir) Store.OpenError!Io.File {
    // The file is not truncated: it is always empty, and another store may
    // hold it locked.
    const lock_file = dir.createFile(io, lock_file_name, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.StoreAlreadyOpen,
        else => |other| return other,
    };
    return lock_file;
}

/// Opens the store's log for appending. If the log exists, its batches are
/// first applied to `memtable`, which must be empty. If it does not exist, it
/// is created when `options` allow that.
///
/// `replay_buffer` holds one record at a time while the log is read. It must
/// be at least `log_payload_size_max` long.
fn openLog(
    io: Io,
    dir: Io.Dir,
    options: Options,
    memtable: *MemTable,
    replay_buffer: []u8,
) Store.OpenError!wal.Writer {
    assert(replay_buffer.len >= log_payload_size_max);

    var reader = wal.Reader.open(io, dir, log_file_name, replay_buffer) catch |err| switch (err) {
        error.FileNotFound => {
            if (!options.create_if_missing) {
                return error.StoreNotFound;
            }
            return createLog(io, dir);
        },
        error.IncompleteLog => {
            // A crash while the store was first being created leaves a log
            // that holds nothing: a file too short to be a log, or a file
            // header of zeros. It is removed and created again.
            if (!options.create_if_missing) {
                return error.StoreNotFound;
            }
            try dir.deleteFile(io, log_file_name);
            return createLog(io, dir);
        },
        else => |other| return other,
    };
    defer reader.close();

    try replayLog(&reader, memtable);
    const end = reader.end();
    if (end.last.op == std.math.maxInt(u64)) {
        // The log ends on the largest op, so there is no op number left for
        // the next batch. A store cannot write that many batches, so this
        // is a log the store did not write.
        return error.Corrupt;
    }
    return wal.Writer.open(io, dir, log_file_name, log_payload_size_max, end);
}

/// Creates the log of a brand-new store. The caller has checked that the
/// options allow creating one.
fn createLog(io: Io, dir: Io.Dir) Store.OpenError!wal.Writer {
    return wal.Writer.create(io, dir, log_file_name, log_payload_size_max, .none);
}

/// Reads every record of the log and applies it to `memtable` as a batch.
fn replayLog(reader: *wal.Reader, memtable: *MemTable) Store.OpenError!void {
    while (true) {
        const record = try reader.next();
        if (record == null) {
            return;
        }
        const batch_bytes = record.?.payload;

        try write_batch.validate(batch_bytes);
        // `write` makes the same check before it logs a batch, and the
        // memtable fills the same way every time, so this only fails for a
        // log the store did not write.
        if (memtableSizeMax(batch_bytes) > memtable.bytesFree()) {
            return error.LogTooLargeForMemtable;
        }
        applyBatch(memtable, batch_bytes);
    }
}

/// The most bytes of the memtable that applying a batch can take. If this is
/// no more than the memtable's free bytes, applying the batch cannot fail.
/// `valid_bytes` must be the bytes of a valid batch.
fn memtableSizeMax(valid_bytes: []const u8) usize {
    var size: usize = 0;
    var operations: write_batch.Iterator = .init(valid_bytes);
    while (operations.next()) |operation| {
        switch (operation) {
            .put => |put| {
                size += MemTable.entrySizeMax(put.key.len, put.value.len);
            },
            .delete => |delete| {
                size += MemTable.entrySizeMax(delete.key.len, 0);
            },
        }
    }
    return size;
}

/// Applies the operations of a batch to the memtable, in order. The caller
/// has checked with `memtableSizeMax` that they fit. `valid_bytes` must be
/// the bytes of a valid batch.
fn applyBatch(memtable: *MemTable, valid_bytes: []const u8) void {
    var operations: write_batch.Iterator = .init(valid_bytes);
    while (operations.next()) |operation| {
        switch (operation) {
            .put => |put| {
                memtable.put(put.key, put.value) catch unreachable;
            },
            .delete => |delete| {
                memtable.delete(delete.key) catch unreachable;
            },
        }
    }
}

const testing = std.testing;

fn openStore(dir: Io.Dir) !Store {
    return Store.open(testing.allocator, testing.io, dir, .{});
}

fn expectValue(store: *Store, key: []const u8, value: []const u8) !void {
    const found = try store.get(key);
    try testing.expect(found != null);
    try testing.expectEqualSlices(u8, value, found.?);
}

fn expectAbsent(store: *Store, key: []const u8) !void {
    const found = try store.get(key);
    try testing.expect(found == null);
}

fn expectEntry(entry: ?Store.Entry, key: []const u8, value: []const u8) !void {
    try testing.expect(entry != null);
    try testing.expectEqualSlices(u8, key, entry.?.key);
    try testing.expectEqualSlices(u8, value, entry.?.value);
}

fn logLength(dir: Io.Dir) !u64 {
    const file = try dir.openFile(testing.io, log_file_name, .{ .mode = .read_only });
    defer file.close(testing.io);
    return try file.length(testing.io);
}

fn setLogLength(dir: Io.Dir, len: u64) !void {
    const file = try dir.openFile(testing.io, log_file_name, .{ .mode = .write_only });
    defer file.close(testing.io);
    try file.setLength(testing.io, len);
}

/// Swaps the file the store's log writes to for a read-only handle on the
/// same file, so that the next append fails with `NotOpenForWriting`. The
/// store closes the new handle when it is closed.
fn makeLogReadOnly(store: *Store, dir: Io.Dir) !void {
    const read_only = try dir.openFile(testing.io, log_file_name, .{ .mode = .read_only });
    store.log.file.close(testing.io);
    store.log.file = read_only;
}

test "a new store is empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    try testing.expectEqual(@as(u64, 0), store.opLatest());
    try expectAbsent(&store, "a");
    var it = store.iterator();
    try testing.expect(try it.next() == null);
}

test "open fails when there is no store and it may not create one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const options: Options = .{ .create_if_missing = false };
    const result = Store.open(testing.allocator, testing.io, tmp.dir, options);
    try testing.expectError(error.StoreNotFound, result);

    // Once the store exists, the same options open it.
    var created = try openStore(tmp.dir);
    created.close(testing.allocator);
    var store: Store = try .open(testing.allocator, testing.io, tmp.dir, options);
    store.close(testing.allocator);
}

test "put, get and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    try store.put("a", "1");
    try store.put("b", "2");
    try expectValue(&store, "a", "1");
    try expectValue(&store, "b", "2");
    try expectAbsent(&store, "c");

    try store.put("a", "one");
    try expectValue(&store, "a", "one");

    try store.delete("a");
    try expectAbsent(&store, "a");
    try expectValue(&store, "b", "2");

    // Deleting a key that is not present is not an error.
    try store.delete("never");
    try expectAbsent(&store, "never");

    try store.put("a", "back");
    try expectValue(&store, "a", "back");
}

test "each batch is given the next op number" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    try store.put("a", "1");
    try testing.expectEqual(@as(u64, 1), store.opLatest());
    try store.delete("a");
    try testing.expectEqual(@as(u64, 2), store.opLatest());

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    try batch.put("b", "2");
    try batch.put("c", "3");
    try store.write(&batch);
    try testing.expectEqual(@as(u64, 3), store.opLatest());
}

test "a batch applies its operations in order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("gone", "before");

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    try batch.put("a", "first");
    try batch.put("a", "second");
    try batch.delete("gone");
    try batch.put("b", "kept");
    try batch.delete("c");
    try batch.put("c", "after the delete");
    try store.write(&batch);

    try expectValue(&store, "a", "second");
    try expectAbsent(&store, "gone");
    try expectValue(&store, "b", "kept");
    try expectValue(&store, "c", "after the delete");
}

test "put and delete do not carry over an earlier write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    // A delete after a put must not write the put again.
    try store.put("a", "1");
    try batch.put("a", "2");
    try store.write(&batch);
    try store.delete("b");
    try expectValue(&store, "a", "2");

    // A put after a delete must not write the delete again.
    try store.delete("c");
    batch.clear();
    try batch.put("c", "3");
    try store.write(&batch);
    try store.put("d", "4");
    try expectValue(&store, "c", "3");
}

test "an empty batch is rejected and nothing is written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        const len_before = try logLength(tmp.dir);

        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        try testing.expectError(error.EmptyBatch, store.write(&batch));

        // A batch that was cleared is empty again.
        try batch.put("b", "2");
        batch.clear();
        try testing.expectError(error.EmptyBatch, store.write(&batch));

        // The rejected writes used no op number and left no trace.
        try testing.expectEqual(@as(u64, 1), store.opLatest());
        try testing.expectEqual(len_before, try logLength(tmp.dir));
    }

    // The log holds no empty record, so the store opens again.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 1), store.opLatest());
    try expectValue(&store, "a", "1");
}

test "the iterator gives live entries in key order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    try store.put("c", "3");
    try store.put("a", "old");
    try store.put("b", "2");
    try store.put("d", "4");
    try store.put("a", "1");
    try store.delete("b");

    var it = store.iterator();
    try expectEntry(try it.next(), "a", "1");
    try expectEntry(try it.next(), "c", "3");
    try expectEntry(try it.next(), "d", "4");
    try testing.expect(try it.next() == null);
    try testing.expect(try it.next() == null);

    // A seek to a deleted key lands on the next live one.
    try it.seek("b");
    try expectEntry(try it.next(), "c", "3");

    try it.seek("d");
    try expectEntry(try it.next(), "d", "4");
    try testing.expect(try it.next() == null);

    try it.seek("e");
    try testing.expect(try it.next() == null);

    it.seekToFirst();
    try expectEntry(try it.next(), "a", "1");
}

test "writes are still there after the store is closed and opened" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        try store.put("b", "2");
        try store.delete("a");
        try store.put("c", "3");
    }

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 4), store.opLatest());
    try expectAbsent(&store, "a");
    try expectValue(&store, "b", "2");
    try expectValue(&store, "c", "3");

    // New writes carry on from the last op.
    try store.put("d", "4");
    try testing.expectEqual(@as(u64, 5), store.opLatest());
}

test "a batch that was only partly written to the log is not there after a crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var len_before_last: u64 = 0;
    var len_after_last: u64 = 0;
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        len_before_last = try logLength(tmp.dir);

        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        try batch.put("a", "changed");
        try batch.put("b", "2");
        try store.write(&batch);
        len_after_last = try logLength(tmp.dir);
    }

    // With the log whole, the store opens with both operations of the batch.
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try testing.expectEqual(@as(u64, 2), store.opLatest());
        try expectValue(&store, "a", "changed");
        try expectValue(&store, "b", "2");
    }

    // Cut the log at every point inside the last record. Each time, the
    // store opens with the first write and nothing of the second batch.
    var len = len_before_last;
    while (len < len_after_last) {
        try setLogLength(tmp.dir, len);

        var store = try openStore(tmp.dir);
        try testing.expectEqual(@as(u64, 1), store.opLatest());
        try expectValue(&store, "a", "1");
        try expectAbsent(&store, "b");
        store.close(testing.allocator);

        len += 1;
    }

    // The store carries on from there.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("c", "3");
    try testing.expectEqual(@as(u64, 2), store.opLatest());
    try expectValue(&store, "c", "3");
}

test "a log left too short by a crash while the store was created is replaced" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        store.close(testing.allocator);
    }
    try setLogLength(tmp.dir, wal.file_header_size - 1);

    // Without leave to create a store, there is none to open.
    const options: Options = .{ .create_if_missing = false };
    const result = Store.open(testing.allocator, testing.io, tmp.dir, options);
    try testing.expectError(error.StoreNotFound, result);
    // The refused open left the short log as it was.
    try testing.expectEqual(@as(u64, wal.file_header_size - 1), try logLength(tmp.dir));

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 0), store.opLatest());
    try store.put("a", "1");
    try expectValue(&store, "a", "1");
}

test "a log left as a header of zeros by a crash is created again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const zeros: [wal.file_header_size]u8 = @splat(0);
        const file = try tmp.dir.createFile(testing.io, log_file_name, .{});
        try file.writePositionalAll(testing.io, &zeros, 0);
        file.close(testing.io);
    }

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 0), store.opLatest());
    try store.put("a", "1");
    try expectValue(&store, "a", "1");
}

test "a directory cannot be open in two stores at once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try openStore(tmp.dir);
    try first.put("a", "1");
    const len_before = try logLength(tmp.dir);

    // A second open is refused, and leaves the log alone.
    try testing.expectError(error.StoreAlreadyOpen, openStore(tmp.dir));
    try testing.expectEqual(len_before, try logLength(tmp.dir));

    // The first store still works.
    try first.put("b", "2");
    first.close(testing.allocator);

    // Closing the store released the directory.
    var second = try openStore(tmp.dir);
    defer second.close(testing.allocator);
    try testing.expectEqual(@as(u64, 2), second.opLatest());
    try expectValue(&second, "a", "1");
    try expectValue(&second, "b", "2");
}

test "a log record that is not a batch is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var log: wal.Writer = try .create(testing.io, tmp.dir, log_file_name, log_payload_size_max, .none);
        defer log.close();
        _ = try log.append("this is not a batch");
    }

    try testing.expectError(error.InvalidBatch, openStore(tmp.dir));
}

test "a log that ends on the largest op is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const previous: wal.RecordId = .{ .op = std.math.maxInt(u64) - 1, .checksum = 0 };
        var log: wal.Writer = try .create(testing.io, tmp.dir, log_file_name, log_payload_size_max, previous);
        defer log.close();

        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        try batch.put("a", "1");
        _ = try log.append(batch.bytes());
    }

    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "a log that holds more than the memtable is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const value = try testing.allocator.alloc(u8, write_batch.value_size_max);
    defer testing.allocator.free(value);
    @memset(value, 'v');

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    {
        var log: wal.Writer = try .create(testing.io, tmp.dir, log_file_name, log_payload_size_max, .none);
        defer log.close();

        // Append batches of one put each, as the store would, but carry on
        // until the entries cannot fit in a memtable however little room
        // each one takes there.
        var key_buffer: [8]u8 = undefined;
        var puts: u64 = 0;
        var memtable_size_min: usize = 0;
        while (memtable_size_min <= MemTable.buffer_size_max) {
            const key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{puts});
            batch.clear();
            try batch.put(key, value);
            _ = try log.append(batch.bytes());
            memtable_size_min += MemTable.entry_overhead_min + key.len + value.len;
            puts += 1;
        }
    }

    try testing.expectError(error.LogTooLargeForMemtable, openStore(tmp.dir));
}

test "a key or value over the limit is rejected and nothing is written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    const long_key: [write_batch.key_size_max + 1]u8 = @splat('k');
    const long_value = try testing.allocator.alloc(u8, write_batch.value_size_max + 1);
    defer testing.allocator.free(long_value);
    @memset(long_value, 'v');

    try testing.expectError(error.KeyTooLarge, store.put(&long_key, "1"));
    try testing.expectError(error.KeyTooLarge, store.delete(&long_key));
    try testing.expectError(error.ValueTooLarge, store.put("a", long_value));
    try testing.expectEqual(@as(u64, 0), store.opLatest());
    try expectAbsent(&store, "a");
}

test "a full store rejects a write, stays usable, and opens again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const value = try testing.allocator.alloc(u8, write_batch.value_size_max);
    defer testing.allocator.free(value);
    @memset(value, 'v');

    var key_buffer: [8]u8 = undefined;
    var puts: u64 = 0;
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);

        // Fill the memtable with the largest values.
        while (true) {
            const key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{puts});
            store.put(key, value) catch |err| {
                try testing.expectEqual(error.StoreFull, err);
                break;
            };
            puts += 1;
        }
        try testing.expect(puts > 0);

        // The rejected write used no op number and left no trace.
        try testing.expectEqual(puts, store.opLatest());
        const rejected_key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{puts});
        try expectAbsent(&store, rejected_key);

        // Everything written before it is still readable.
        const first_key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{0});
        try expectValue(&store, first_key, value);

        // A write that fits is still accepted, and takes the next op number.
        try store.put("small", "1");
        try testing.expectEqual(puts + 1, store.opLatest());
        try expectValue(&store, "small", "1");
    }

    // The log holds exactly what the memtable held, so it replays.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(puts + 1, store.opLatest());
    const last_key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{puts - 1});
    try expectValue(&store, last_key, value);
    try expectValue(&store, "small", "1");
}

test "a batch is rejected only when its estimate is over the free bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const value = try testing.allocator.alloc(u8, write_batch.value_size_max);
    defer testing.allocator.free(value);
    @memset(value, 'v');

    var key_buffer: [8]u8 = undefined;
    var puts: u64 = 0;
    var value_len_exact: usize = 0;
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);

        // Fill the memtable until the largest value no longer fits.
        while (true) {
            const key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{puts});
            store.put(key, value) catch |err| {
                try testing.expectEqual(error.StoreFull, err);
                break;
            };
            puts += 1;
        }

        // Size a value for the rejected key so that the estimate for its put
        // is exactly the free bytes.
        const key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{puts});
        const free = store.memtable.bytesFree();
        const size_without_value = MemTable.entrySizeMax(key.len, 0);
        try testing.expect(free >= size_without_value);
        value_len_exact = free - size_without_value;

        // One byte over the free bytes is rejected.
        const result = store.put(key, value[0 .. value_len_exact + 1]);
        try testing.expectError(error.StoreFull, result);
        try testing.expectEqual(free, store.memtable.bytesFree());

        // Exactly the free bytes is accepted.
        try store.put(key, value[0..value_len_exact]);
        try testing.expectEqual(puts + 1, store.opLatest());
        try expectValue(&store, key, value[0..value_len_exact]);
    }

    // Replay accepts the same batch at the same boundary.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(puts + 1, store.opLatest());
    const key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{puts});
    try expectValue(&store, key, value[0..value_len_exact]);
}

test "memtableSizeMax is the sum of the largest size of each operation" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    try batch.put("ab", "value");
    try batch.delete("abc");
    try batch.put("k", "");

    var expected: usize = 0;
    expected += MemTable.entrySizeMax("ab".len, "value".len);
    expected += MemTable.entrySizeMax("abc".len, 0);
    expected += MemTable.entrySizeMax("k".len, 0);
    try testing.expectEqual(expected, memtableSizeMax(batch.bytes()));
}

/// Fills `batch` with small puts and deletes until it has no room for another.
/// Each operation uses the next key number, which is returned for the next
/// call.
fn fillBatchWithSmallOperations(batch: *WriteBatch, key_number_first: u64) !u64 {
    var key_buffer: [8]u8 = undefined;
    var key_number = key_number_first;

    batch.clear();
    while (true) {
        const key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{key_number});
        if (key_number % 2 == 0) {
            batch.put(key, "") catch |err| {
                try testing.expectEqual(error.BatchFull, err);
                return key_number;
            };
        } else {
            batch.delete(key) catch |err| {
                try testing.expectEqual(error.BatchFull, err);
                return key_number;
            };
        }
        key_number += 1;
    }
}

test "a store filled by batches of small operations reports full and opens again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    var key_number: u64 = 0;
    var batches: u64 = 0;
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);

        // A small operation takes far more room in the memtable than it does
        // in the batch, so the memtable fills long before the log is as large.
        while (true) {
            key_number = try fillBatchWithSmallOperations(&batch, key_number);
            store.write(&batch) catch |err| {
                try testing.expectEqual(error.StoreFull, err);
                break;
            };
            batches += 1;
        }
        try testing.expect(batches > 0);
        try testing.expectEqual(batches, store.opLatest());
    }

    // Every batch that was logged fits in the memtable again.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(batches, store.opLatest());
}

test "a write that fails to reach the log is not applied" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("a", "1");

    try makeLogReadOnly(&store, tmp.dir);
    try testing.expectError(error.NotOpenForWriting, store.put("b", "2"));

    // The failed write is not readable and used no op number.
    try expectAbsent(&store, "b");
    try expectValue(&store, "a", "1");
    try testing.expectEqual(@as(u64, 1), store.opLatest());
}

test "after a failed write every later write is refused until the store is opened again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    try batch.put("c", "3");

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");

        try makeLogReadOnly(&store, tmp.dir);
        try testing.expectError(error.NotOpenForWriting, store.put("b", "2"));

        // Every kind of write is refused from then on.
        try testing.expectError(error.StoreBroken, store.put("b", "2"));
        try testing.expectError(error.StoreBroken, store.delete("a"));
        try testing.expectError(error.StoreBroken, store.write(&batch));

        // Reads still work, and show nothing of the refused writes.
        try expectValue(&store, "a", "1");
        try expectAbsent(&store, "b");
        try expectAbsent(&store, "c");
        try testing.expectEqual(@as(u64, 1), store.opLatest());
    }

    // Opened again, the store accepts writes.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try expectValue(&store, "a", "1");
    try store.put("b", "2");
    try testing.expectEqual(@as(u64, 2), store.opLatest());
}

const model_key_count = 48;

/// Checks every key and a full scan of the store against the model. Entry
/// `i` of the model is the value of key number `i`, or `null` if that key is
/// not present.
fn expectModel(store: *Store, model: *const [model_key_count]?[]const u8) !void {
    var key_buffer: [3]u8 = undefined;

    var it = store.iterator();
    for (model, 0..) |expected, key_number| {
        const key = try std.fmt.bufPrint(&key_buffer, "k{d:0>2}", .{key_number});
        if (expected == null) {
            try expectAbsent(store, key);
        } else {
            try expectValue(store, key, expected.?);
            try expectEntry(try it.next(), key, expected.?);
        }
    }
    try testing.expect(try it.next() == null);
}

test "random writes and reopens match a model" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();

    var model: [model_key_count]?[]const u8 = @splat(null);
    var op_expected: u64 = 0;
    var key_buffer: [3]u8 = undefined;

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    for (0..600) |step| {
        // A batch of one to five operations on random keys.
        batch.clear();
        const operation_count = 1 + random.uintLessThan(usize, 5);
        for (0..operation_count) |_| {
            const key_number = random.uintLessThan(usize, model_key_count);
            const key = try std.fmt.bufPrint(&key_buffer, "k{d:0>2}", .{key_number});

            if (random.uintLessThan(u8, 4) == 0) {
                try batch.delete(key);
                model[key_number] = null;
            } else {
                const value = try arena.alloc(u8, random.uintAtMost(usize, 60));
                random.bytes(value);
                try batch.put(key, value);
                model[key_number] = value;
            }
        }
        try store.write(&batch);
        op_expected += 1;
        try testing.expectEqual(op_expected, store.opLatest());

        if (step % 50 == 49) {
            try expectModel(&store, &model);
            store.close(testing.allocator);
            store = try openStore(tmp.dir);
            try testing.expectEqual(op_expected, store.opLatest());
            try expectModel(&store, &model);
        }
    }
}
