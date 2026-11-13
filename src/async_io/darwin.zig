//! The asynchronous I/O interface on macOS, where file I/O blocks.
//!
//! This backend does not run a read, a write or a sync of a regular file in
//! the background. kqueue cannot: it reports when sockets and pipes are
//! ready, and a regular file always counts as ready. So this backend keeps
//! the interface and the rule about when callbacks run, and does the work
//! with ordinary blocking calls.
//!
//! Starting an operation only queues it. `poll` and `wait` then do each
//! queued operation and call its callback. A callback therefore never runs
//! inside the call that started its operation, which is the same as on
//! Linux, but the thread is blocked for as long as each operation takes.
//! macOS is for development; measure on Linux.

const std = @import("std");
const assert = std.debug.assert;
const c = std.c;

const common = @import("common.zig");

const Completion = common.Completion;
const Fd = common.Fd;
const Queue = common.Queue;

/// This backend never fails to start. It shares the error set with Linux so
/// that code which handles the errors is compiled on both systems.
pub const InitError = common.InitError;

pub const AsyncIo = struct {
    /// Operations that have been started and not yet done.
    pending: Queue,

    /// How many operations have been started and not yet called back.
    in_flight: u32,

    /// Whether `poll` or `wait` is running. A callback must not call them.
    running: bool,

    pub fn init() InitError!AsyncIo {
        return .{
            .pending = .{},
            .in_flight = 0,
            .running = false,
        };
    }

    /// Nothing may be in flight.
    pub fn deinit(self: *AsyncIo) void {
        assert(self.in_flight == 0);
        assert(self.pending.isEmpty());
        assert(!self.running);
    }

    /// Starts reading into `buffer` from `offset` in the file.
    pub fn read(
        self: *AsyncIo,
        completion: *Completion,
        callback: *const fn (completion: *Completion) void,
        fd: Fd,
        buffer: []u8,
        offset: u64,
    ) void {
        self.start(completion, callback, .{ .read = .{
            .fd = fd,
            .buffer = buffer,
            .offset = offset,
        } });
    }

    /// Starts writing `buffer` at `offset` in the file.
    pub fn write(
        self: *AsyncIo,
        completion: *Completion,
        callback: *const fn (completion: *Completion) void,
        fd: Fd,
        buffer: []const u8,
        offset: u64,
    ) void {
        self.start(completion, callback, .{ .write = .{
            .fd = fd,
            .buffer = buffer,
            .offset = offset,
        } });
    }

    /// Starts a sync of the file: when it ends without an error, everything
    /// written to the file before the sync was started is in permanent
    /// storage and can be read back. The file's timestamps are not
    /// necessarily saved.
    ///
    /// On a file system that does not support the full sync (network and
    /// some external volumes) this falls back to an ordinary sync, which
    /// can leave the data in the drive's cache.
    pub fn sync(
        self: *AsyncIo,
        completion: *Completion,
        callback: *const fn (completion: *Completion) void,
        fd: Fd,
    ) void {
        self.start(completion, callback, .{ .sync = .{ .fd = fd } });
    }

    fn start(
        self: *AsyncIo,
        completion: *Completion,
        callback: *const fn (completion: *Completion) void,
        operation: common.Operation,
    ) void {
        assert(!completion.in_flight);
        assert(completion.next == null);
        completion.* = .{
            .in_flight = true,
            .callback = callback,
            .operation = operation,
        };
        self.in_flight += 1;
        self.pending.push(completion);
    }

    /// Does the operations that were queued before this call and runs their
    /// callbacks. Operations that those callbacks start wait for the next
    /// call, so one call does a bounded amount of work.
    pub fn poll(self: *AsyncIo) void {
        assert(!self.running);
        self.running = true;
        defer self.running = false;

        var batch = self.pending.takeAll();
        while (batch.pop()) |completion| {
            assert(completion.in_flight);
            completion.result = perform(completion.operation);
            completion.in_flight = false;
            self.in_flight -= 1;
            completion.callback(completion);
        }
    }

    /// Like `poll`, but when nothing is queued, sleeps for `timeout_ns`.
    /// Nothing can finish during the sleep, because nothing runs in the
    /// background here; the sleep is what paces a loop that calls `wait`.
    pub fn wait(self: *AsyncIo, timeout_ns: u64) void {
        assert(!self.running);
        if (self.pending.isEmpty()) {
            sleep(timeout_ns);
            return;
        }
        self.poll();
    }
};

fn perform(operation: common.Operation) common.Result {
    switch (operation) {
        .read => |read| {
            return .{ .read = performRead(read.fd, read.buffer, read.offset) };
        },
        .write => |write| {
            return .{ .write = performWrite(write.fd, write.buffer, write.offset) };
        },
        .sync => |sync| {
            return .{ .sync = performSync(sync.fd) };
        },
    }
}

fn performRead(fd: Fd, buffer: []u8, offset: u64) common.ReadError!usize {
    const len = common.transferSize(buffer.len);
    while (true) {
        const result = c.pread(fd, buffer.ptr, len, @intCast(offset));
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                return @intCast(result);
            },
            .INTR, .AGAIN => {
                continue;
            },
            .IO => {
                return error.InputOutput;
            },
            .INVAL => {
                return error.Alignment;
            },
            .BADF => {
                return error.NotOpenForReading;
            },
            else => {
                return error.Unexpected;
            },
        }
    }
}

fn performWrite(fd: Fd, buffer: []const u8, offset: u64) common.WriteError!usize {
    const len = common.transferSize(buffer.len);
    while (true) {
        const result = c.pwrite(fd, buffer.ptr, len, @intCast(offset));
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                return @intCast(result);
            },
            .INTR => {
                continue;
            },
            .IO => {
                return error.InputOutput;
            },
            .NOSPC => {
                return error.NoSpaceLeft;
            },
            .DQUOT => {
                return error.DiskQuota;
            },
            .FBIG => {
                return error.FileTooBig;
            },
            .INVAL => {
                return error.Alignment;
            },
            .BADF => {
                return error.NotOpenForWriting;
            },
            else => {
                return error.Unexpected;
            },
        }
    }
}

/// Asks the drive to empty its cache, which an ordinary sync on macOS does
/// not do. Falls back to an ordinary sync on a file system that does not
/// support the request.
fn performSync(fd: Fd) common.SyncError!void {
    while (true) {
        const result = c.fcntl(fd, c.F.FULLFSYNC, @as(c_int, 0));
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                return;
            },
            .INTR => {
                continue;
            },
            .IO => {
                return error.InputOutput;
            },
            .NOSPC => {
                return error.NoSpaceLeft;
            },
            .DQUOT => {
                return error.DiskQuota;
            },
            .OPNOTSUPP, .NOTTY, .INVAL, .NODEV => {
                // Network and some external file systems do not support the
                // full sync, and answer with one of these. An ordinary sync
                // is the most they can do.
                return ordinarySync(fd);
            },
            else => {
                // The full sync is supported and failed. An ordinary sync
                // could succeed without the data reaching the disk, so
                // this must not be reported as a success.
                return error.Unexpected;
            },
        }
    }
}

fn ordinarySync(fd: Fd) common.SyncError!void {
    while (true) {
        const result = c.fsync(fd);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                return;
            },
            .INTR => {
                continue;
            },
            .IO => {
                return error.InputOutput;
            },
            .NOSPC => {
                return error.NoSpaceLeft;
            },
            .DQUOT => {
                return error.DiskQuota;
            },
            else => {
                return error.Unexpected;
            },
        }
    }
}

fn sleep(duration_ns: u64) void {
    var remaining: c.timespec = .{
        .sec = @intCast(duration_ns / std.time.ns_per_s),
        .nsec = @intCast(duration_ns % std.time.ns_per_s),
    };
    while (true) {
        const request = remaining;
        const result = c.nanosleep(&request, &remaining);
        if (std.posix.errno(result) != .INTR) {
            return;
        }
        // A signal cut the sleep short and `remaining` holds what is left.
    }
}
