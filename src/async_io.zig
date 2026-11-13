//! File I/O that does not block the caller.
//!
//! An operation is started with a `Completion` the caller owns and a
//! callback. The call only queues the operation. Later, a call to `poll` or `wait`
//! runs the callback with the completion, whose `result` says how the
//! operation ended.
//!
//!     var io: AsyncIo = try .init();
//!     io.write(&completion, onWrite, fd, bytes, offset);
//!     while (!done) io.wait(timeout_ns);
//!
//! What a caller can rely on, on every system:
//!
//! - A callback never runs inside the call that started its operation. It
//!   runs only from `poll` or `wait`.
//! - A callback may start further operations, and may reuse its own
//!   completion to do so. It must not call `poll` or `wait`.
//! - Operations that are in flight together are not ordered: they can be
//!   carried out, and their callbacks can run, in any order. To sync after
//!   a write, start the sync from the write's callback. A sync started
//!   alongside the write can be carried out before it.
//! - A read or a write can transfer fewer bytes than its buffer holds. The
//!   caller starts another operation for the rest. This layer does not,
//!   because what to do about a short transfer is for the caller to decide.
//! - An operation that is in flight cannot be cancelled. It can only be
//!   waited for.
//! - `poll` and `wait` do not fail. If the mechanism underneath breaks, the
//!   operations in flight are in an unknown state and the program stops.
//!
//! On Linux the work is done by the kernel through io_uring while the
//! caller carries on. On macOS it is done by blocking calls inside `poll`
//! and `wait`; see `async_io/darwin.zig`.
//!
//! This layer is modelled on TigerBeetle's. It differs in two ways: the
//! callback takes only the completion and finds its own state with
//! `@fieldParentPtr`, and a completion records whether it is in flight so
//! that starting it twice is caught.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;

const common = @import("async_io/common.zig");
const constants = @import("constants.zig");

/// How many operations the kernel's queue holds on Linux. Used only to
/// size the test that starts more than that at once.
const ring_entries = constants.async_io_ring_entries;

const backend = switch (builtin.os.tag) {
    .linux => @import("async_io/linux.zig"),
    .macos => @import("async_io/darwin.zig"),
    else => @compileError("async_io supports Linux and macOS"),
};

pub const AsyncIo = backend.AsyncIo;

pub const Completion = common.Completion;
pub const Fd = common.Fd;
pub const InitError = common.InitError;
pub const Operation = common.Operation;
pub const Result = common.Result;
pub const ReadError = common.ReadError;
pub const WriteError = common.WriteError;
pub const SyncError = common.SyncError;
pub const transfer_size_max = common.transfer_size_max;

test {
    _ = common;
}

const test_file_name = "async_io_test";

/// How long a test lets `wait` block before it looks again.
const test_wait_ns = 10 * std.time.ns_per_ms;

/// A file in a fresh directory, and an `AsyncIo` to use on it.
const TestFile = struct {
    tmp: testing.TmpDir,
    file: std.Io.File,
    io: AsyncIo,

    fn create() !TestFile {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const file = try tmp.dir.createFile(testing.io, test_file_name, .{ .read = true });
        errdefer file.close(testing.io);
        const io: AsyncIo = try .init();
        return .{ .tmp = tmp, .file = file, .io = io };
    }

    fn destroy(self: *TestFile) void {
        self.io.deinit();
        self.file.close(testing.io);
        self.tmp.cleanup();
    }

    fn fd(self: *const TestFile) Fd {
        return self.file.handle;
    }
};

/// Writes a whole buffer, or reads until a buffer is full or the file ends,
/// by starting another operation from the callback whenever a transfer was
/// short. This is the pattern a caller is expected to use.
const Transfer = struct {
    const Direction = enum { read, write };

    io: *AsyncIo,
    fd: Fd,
    direction: Direction,
    buffer: []u8,
    offset: u64,
    completion: Completion = .{},

    /// How many bytes have been transferred so far.
    transferred: usize = 0,
    done: bool = false,
    failed: bool = false,

    /// How many times the callback has run.
    callbacks: u32 = 0,

    fn start(self: *Transfer) void {
        const rest = self.buffer[self.transferred..];
        const offset = self.offset + self.transferred;
        switch (self.direction) {
            .read => {
                self.io.read(&self.completion, onTransfer, self.fd, rest, offset);
            },
            .write => {
                self.io.write(&self.completion, onTransfer, self.fd, rest, offset);
            },
        }
    }

    fn onTransfer(completion: *Completion) void {
        const self: *Transfer = @fieldParentPtr("completion", completion);
        self.callbacks += 1;

        var count: usize = 0;
        switch (completion.result) {
            .read => |result| {
                count = result catch {
                    self.failed = true;
                    self.done = true;
                    return;
                };
            },
            .write => |result| {
                count = result catch {
                    self.failed = true;
                    self.done = true;
                    return;
                };
            },
            .sync => unreachable,
        }

        self.transferred += count;
        if (count == 0 or self.transferred == self.buffer.len) {
            self.done = true;
            return;
        }
        self.start();
    }

    fn run(self: *Transfer) !void {
        self.start();
        // Starting the operation must not have run the callback.
        try testing.expectEqual(@as(u32, 0), self.callbacks);
        while (!self.done) {
            self.io.wait(test_wait_ns);
        }
        try testing.expect(!self.failed);
    }
};

fn writeAll(test_file: *TestFile, bytes: []const u8, offset: u64) !void {
    var transfer: Transfer = .{
        .io = &test_file.io,
        .fd = test_file.fd(),
        .direction = .write,
        // A write never changes its buffer.
        .buffer = @constCast(bytes),
        .offset = offset,
    };
    try transfer.run();
    try testing.expectEqual(bytes.len, transfer.transferred);
}

/// Reads into `buffer` from `offset` and returns how many bytes the file
/// had there.
fn readAll(test_file: *TestFile, buffer: []u8, offset: u64) !usize {
    var transfer: Transfer = .{
        .io = &test_file.io,
        .fd = test_file.fd(),
        .direction = .read,
        .buffer = buffer,
        .offset = offset,
    };
    try transfer.run();
    return transfer.transferred;
}

test "what is written can be read back" {
    var test_file: TestFile = try .create();
    defer test_file.destroy();

    try writeAll(&test_file, "hello, ", 0);
    try writeAll(&test_file, "world", 7);

    var buffer: [12]u8 = undefined;
    const len = try readAll(&test_file, &buffer, 0);
    try testing.expectEqualStrings("hello, world", buffer[0..len]);
}

test "a read at the end of the file transfers nothing" {
    var test_file: TestFile = try .create();
    defer test_file.destroy();

    try writeAll(&test_file, "abc", 0);

    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try readAll(&test_file, &buffer, 3));
    try testing.expectEqual(@as(usize, 1), try readAll(&test_file, &buffer, 2));
}

/// One operation that records how it ended.
const Single = struct {
    completion: Completion = .{},
    done: bool = false,
    result: Result = undefined,

    fn onDone(completion: *Completion) void {
        const self: *Single = @fieldParentPtr("completion", completion);
        assert(!self.done);
        self.result = completion.result;
        self.done = true;
    }

    fn waitFor(self: *Single, io: *AsyncIo) void {
        while (!self.done) {
            io.wait(test_wait_ns);
        }
    }
};

test "a sync ends without an error" {
    var test_file: TestFile = try .create();
    defer test_file.destroy();

    try writeAll(&test_file, "to be synced", 0);

    var sync: Single = .{};
    test_file.io.sync(&sync.completion, Single.onDone, test_file.fd());
    try testing.expect(!sync.done);
    try testing.expect(sync.completion.in_flight);
    sync.waitFor(&test_file.io);
    try testing.expect(!sync.completion.in_flight);
    try sync.result.sync;
}

test "an operation on a file that does not allow it gives an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const created = try tmp.dir.createFile(testing.io, test_file_name, .{});
        created.close(testing.io);
    }
    const read_only = try tmp.dir.openFile(testing.io, test_file_name, .{ .mode = .read_only });
    defer read_only.close(testing.io);
    const write_only = try tmp.dir.openFile(testing.io, test_file_name, .{ .mode = .write_only });
    defer write_only.close(testing.io);

    var io: AsyncIo = try .init();
    defer io.deinit();

    var write: Single = .{};
    io.write(&write.completion, Single.onDone, read_only.handle, "x", 0);
    write.waitFor(&io);
    try testing.expectError(error.NotOpenForWriting, write.result.write);

    var buffer: [1]u8 = undefined;
    var read: Single = .{};
    io.read(&read.completion, Single.onDone, write_only.handle, &buffer, 0);
    read.waitFor(&io);
    try testing.expectError(error.NotOpenForReading, read.result.read);
}

/// A write that, from its callback, starts a sync on the same completion.
/// This is how a caller makes a write durable: the sync is started only
/// once the write has ended.
const WriteThenSync = struct {
    io: *AsyncIo,
    fd: Fd,
    completion: Completion = .{},
    write_ended: bool = false,
    sync_ended: bool = false,
    failed: bool = false,

    fn start(self: *WriteThenSync, bytes: []const u8) void {
        self.io.write(&self.completion, onWrite, self.fd, bytes, 0);
    }

    fn onWrite(completion: *Completion) void {
        const self: *WriteThenSync = @fieldParentPtr("completion", completion);
        _ = completion.result.write catch {
            self.failed = true;
        };
        self.write_ended = true;
        // The completion is free again by the time its callback runs.
        assert(!completion.in_flight);
        self.io.sync(completion, onSync, self.fd);
        // Starting the sync must not have run its callback.
        assert(!self.sync_ended);
    }

    fn onSync(completion: *Completion) void {
        const self: *WriteThenSync = @fieldParentPtr("completion", completion);
        assert(self.write_ended);
        completion.result.sync catch {
            self.failed = true;
        };
        self.sync_ended = true;
    }
};

test "a callback can start the next operation on its own completion" {
    var test_file: TestFile = try .create();
    defer test_file.destroy();

    var operation: WriteThenSync = .{ .io = &test_file.io, .fd = test_file.fd() };
    operation.start("durable");
    try testing.expect(!operation.write_ended);
    while (!operation.sync_ended) {
        test_file.io.wait(test_wait_ns);
    }
    try testing.expect(!operation.failed);

    var buffer: [7]u8 = undefined;
    const len = try readAll(&test_file, &buffer, 0);
    try testing.expectEqualStrings("durable", buffer[0..len]);
}

test "more operations can be in flight than the kernel's queue holds" {
    var test_file: TestFile = try .create();
    defer test_file.destroy();

    // Several times the queue's size on Linux, so that starting them hands
    // the queue to the kernel part way through.
    const count = ring_entries * 8;
    const singles = try testing.allocator.alloc(Single, count);
    defer testing.allocator.free(singles);
    const bytes = try testing.allocator.alloc(u8, count);
    defer testing.allocator.free(bytes);

    for (singles, bytes, 0..) |*single, *byte, index| {
        single.* = .{};
        byte.* = @intCast(index % 251);
        test_file.io.write(&single.completion, Single.onDone, test_file.fd(), byte[0..1], index);
    }
    // Starting operations never runs a callback, not even when the queue
    // filled up on the way.
    for (singles) |*single| {
        try testing.expect(!single.done);
    }
    try testing.expectEqual(@as(u32, count), test_file.io.in_flight);

    for (singles) |*single| {
        single.waitFor(&test_file.io);
        try testing.expectEqual(@as(usize, 1), try single.result.write);
    }
    try testing.expectEqual(@as(u32, 0), test_file.io.in_flight);

    const read_back = try testing.allocator.alloc(u8, count);
    defer testing.allocator.free(read_back);
    try testing.expectEqual(@as(usize, count), try readAll(&test_file, read_back, 0));
    try testing.expectEqualSlices(u8, bytes, read_back);
}

test "one completion can be used again and again" {
    var test_file: TestFile = try .create();
    defer test_file.destroy();

    var single: Single = .{};
    var round: u8 = 0;
    while (round < 50) : (round += 1) {
        single.done = false;
        const byte = [1]u8{round};
        test_file.io.write(&single.completion, Single.onDone, test_file.fd(), &byte, round);
        single.waitFor(&test_file.io);
        try testing.expectEqual(@as(usize, 1), try single.result.write);
    }

    var buffer: [50]u8 = undefined;
    try testing.expectEqual(@as(usize, 50), try readAll(&test_file, &buffer, 0));
    for (buffer, 0..) |byte, index| {
        try testing.expectEqual(@as(u8, @intCast(index)), byte);
    }
}

test "poll and wait return when nothing is in flight" {
    var io: AsyncIo = try .init();
    defer io.deinit();

    io.poll();
    io.wait(std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 0), io.in_flight);
}

test "poll alone finishes an operation without blocking for it" {
    var test_file: TestFile = try .create();
    defer test_file.destroy();

    var single: Single = .{};
    test_file.io.write(&single.completion, Single.onDone, test_file.fd(), "polled", 0);
    while (!single.done) {
        test_file.io.poll();
    }
    try testing.expectEqual(@as(usize, 6), try single.result.write);
}
