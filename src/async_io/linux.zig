//! Asynchronous file I/O on Linux, through io_uring.
//!
//! An operation is written into the ring's submission queue, which is
//! memory shared with the kernel. `poll` and `wait` hand the queue to the
//! kernel with one system call, collect the operations the kernel has
//! finished, and run their callbacks. The kernel does the work while this
//! thread does something else.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const IoUring = linux.IoUring;

const common = @import("common.zig");
const constants = @import("../constants.zig");

const Completion = common.Completion;
const Fd = common.Fd;
const Queue = common.Queue;

/// How many operations the ring's submission queue holds. More can be in
/// flight than this: when the queue is full it is handed to the kernel to
/// make room.
const ring_entries = constants.async_io_ring_entries;

/// The largest submission queue the kernel allows.
const ring_entries_kernel_max = 32768;

comptime {
    assert(ring_entries >= 1);
    assert(ring_entries <= ring_entries_kernel_max);
    assert(std.math.isPowerOfTwo(ring_entries));
}

pub const InitError = common.InitError;

pub const AsyncIo = struct {
    ring: IoUring,

    /// Operations the kernel has finished whose callbacks have not run yet.
    completed: Queue,

    /// How many operations have been started and not yet called back.
    in_flight: u32,

    /// How many of those the kernel has been given and has not yet
    /// reported as finished. Only these can finish.
    in_kernel: u32,

    /// Whether `poll` or `wait` is running. A callback must not call them.
    running: bool,

    pub fn init() InitError!AsyncIo {
        var ring = IoUring.init(ring_entries, 0) catch |err| {
            switch (err) {
                error.SystemOutdated, error.PermissionDenied => {
                    return error.IoUringUnavailable;
                },
                error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => {
                    return error.SystemResources;
                },
                else => {
                    return error.Unexpected;
                },
            }
        };
        errdefer ring.deinit();

        // `wait` passes its time limit straight to the kernel, which needs
        // this feature. It arrived in Linux 5.11.
        if ((ring.features & linux.IORING_FEAT_EXT_ARG) == 0) {
            return error.IoUringUnavailable;
        }

        return .{
            .ring = ring,
            .completed = .{},
            .in_flight = 0,
            .in_kernel = 0,
            .running = false,
        };
    }

    /// Nothing may be in flight: the kernel would be left holding pointers
    /// to completions and buffers.
    pub fn deinit(self: *AsyncIo) void {
        assert(self.in_flight == 0);
        assert(self.in_kernel == 0);
        assert(self.completed.isEmpty());
        assert(!self.running);
        self.ring.deinit();
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
        self.enqueue(completion);
    }

    /// Writes the operation into the submission queue. Makes no system call
    /// unless the queue is full, when it hands the queue to the kernel
    /// first. Never runs a callback.
    fn enqueue(self: *AsyncIo, completion: *Completion) void {
        var sqe = self.ring.get_sqe() catch null;
        if (sqe == null) {
            // The queue is full. Hand it to the kernel, which empties it.
            self.enter(0);
            sqe = self.ring.get_sqe() catch null;
        }
        const entry = sqe.?;

        switch (completion.operation) {
            .read => |operation| {
                const len = common.transferSize(operation.buffer.len);
                entry.prep_read(operation.fd, operation.buffer[0..len], operation.offset);
            },
            .write => |operation| {
                const len = common.transferSize(operation.buffer.len);
                entry.prep_write(operation.fd, operation.buffer[0..len], operation.offset);
            },
            .sync => |operation| {
                // A data sync, not a full one. A full sync also saves the
                // file's modification time, which every write changes, and
                // on ext4 that costs a journal commit of several
                // milliseconds. A data sync still saves everything needed
                // to read the data back, including a change in the file's
                // size.
                entry.prep_fsync(operation.fd, linux.IORING_FSYNC_DATASYNC);
            },
        }
        // The kernel gives this number back with the outcome, which is how
        // the outcome finds its completion.
        entry.user_data = @intFromPtr(completion);
    }

    /// Hands queued operations to the kernel and runs the callbacks of the
    /// operations that have finished. Does not wait for an operation to
    /// finish.
    ///
    /// The call lasts as long as the kernel spends on the hand-over, which
    /// is short when the kernel does the work in the background. In the
    /// rare case that the kernel has no room for more operations, it waits
    /// for one to finish.
    pub fn poll(self: *AsyncIo) void {
        self.run(0);
    }

    /// Like `poll`, but when no operation has finished yet, blocks until
    /// one does or until `timeout_ns` has passed.
    pub fn wait(self: *AsyncIo, timeout_ns: u64) void {
        self.run(timeout_ns);
    }

    fn run(self: *AsyncIo, timeout_ns: u64) void {
        assert(!self.running);
        self.running = true;
        defer self.running = false;

        var wait_ns = timeout_ns;
        if (!self.completed.isEmpty()) {
            // There are callbacks to run already, so there is nothing to
            // wait for.
            wait_ns = 0;
        }
        self.enter(wait_ns);
        self.collect(0);
        self.runCallbacks();
        // Callbacks usually start further operations. Hand those over now
        // so that they do not sit in the queue until the next call.
        self.enter(0);
    }

    /// Makes the system call that gives the kernel the submission queue.
    /// With a `wait_ns` above zero it also blocks until at least one
    /// operation has finished or that long has passed.
    ///
    /// A failure of the ring itself is a bug or a broken kernel object.
    /// The operations in flight would be in an unknown state and there is
    /// no way to carry on, so it stops the program.
    fn enter(self: *AsyncIo, wait_ns: u64) void {
        var wait_remaining_ns = wait_ns;
        while (true) {
            const to_submit = self.ring.flush_sq();
            if (to_submit == 0 and wait_remaining_ns == 0) {
                return;
            }

            var flags: u32 = linux.IORING_ENTER_EXT_ARG;
            var min_complete: u32 = 0;
            var timespec: linux.kernel_timespec = .{
                .sec = @intCast(wait_remaining_ns / std.time.ns_per_s),
                .nsec = @intCast(wait_remaining_ns % std.time.ns_per_s),
            };
            var argument: linux.io_uring_getevents_arg = .{
                .sigmask = 0,
                .sigmask_sz = linux.NSIG / 8,
                .pad = 0,
                .ts = 0,
            };
            if (wait_remaining_ns > 0) {
                flags |= linux.IORING_ENTER_GETEVENTS;
                min_complete = 1;
                argument.ts = @intFromPtr(&timespec);
            }

            // The standard library's wrapper cannot pass the time limit, so
            // this is the raw call.
            const result = linux.syscall6(
                .io_uring_enter,
                @as(usize, @bitCast(@as(isize, self.ring.fd))),
                to_submit,
                min_complete,
                flags,
                @intFromPtr(&argument),
                @sizeOf(linux.io_uring_getevents_arg),
            );

            switch (linux.errno(result)) {
                .SUCCESS => {
                    // The result is how many operations the kernel took.
                    const submitted: u32 = @intCast(result);
                    assert(submitted <= to_submit);
                    self.in_kernel += submitted;
                    return;
                },
                .TIME, .INTR => {
                    // The time limit passed, or a signal arrived, before an
                    // operation finished. The kernel reports these only
                    // when it took no operations in this call; any that
                    // were queued are still queued for the next call.
                    return;
                },
                .AGAIN, .BUSY => {
                    // The kernel has no room for more operations until some
                    // finished ones have been collected.
                    if (self.in_kernel == 0) {
                        // Nothing is in the kernel, so nothing can finish
                        // and waiting would never end.
                        std.debug.panic("async_io: the kernel refused operations with none in flight", .{});
                    }
                    self.collect(1);
                    // Finished operations are now waiting for their
                    // callbacks, so there is nothing left to block for.
                    wait_remaining_ns = 0;
                },
                else => |errno| {
                    std.debug.panic("async_io: io_uring_enter failed: {t}", .{errno});
                },
            }
        }
    }

    /// Moves the operations the kernel has finished onto `completed`. With
    /// `wait_count` above zero, blocks until that many have finished.
    ///
    /// Callbacks are not run here. This is reached from inside the calls
    /// that start operations, where a callback must not run.
    fn collect(self: *AsyncIo, wait_count: u32) void {
        var cqes: [256]linux.io_uring_cqe = undefined;
        var wait_remaining = wait_count;
        while (true) {
            const count = self.ring.copy_cqes(&cqes, wait_remaining) catch |err| {
                switch (err) {
                    error.SignalInterrupt => {
                        continue;
                    },
                    else => {
                        std.debug.panic("async_io: collecting finished operations failed: {t}", .{err});
                    },
                }
            };
            for (cqes[0..count]) |cqe| {
                const completion: *Completion = @ptrFromInt(cqe.user_data);
                assert(completion.in_flight);
                completion.kernel_result = cqe.res;
                self.in_kernel -= 1;
                self.completed.push(completion);
            }
            if (count < cqes.len) {
                return;
            }
            wait_remaining = 0;
        }
    }

    fn runCallbacks(self: *AsyncIo) void {
        while (self.completed.pop()) |completion| {
            assert(completion.in_flight);
            if (mustRetry(completion)) {
                self.enqueue(completion);
                continue;
            }
            completion.result = resultOf(completion);
            completion.in_flight = false;
            self.in_flight -= 1;
            completion.callback(completion);
        }
    }
};

/// Whether the operation did not run and should simply be started again.
fn mustRetry(completion: *const Completion) bool {
    if (completion.kernel_result >= 0) {
        return false;
    }
    const errno: linux.E = @fromBackingInt(@intCast(-completion.kernel_result));
    switch (completion.operation) {
        .read => {
            // Some file systems answer a read with "try again".
            return errno == .INTR or errno == .AGAIN;
        },
        .write, .sync => {
            return errno == .INTR;
        },
    }
}

fn resultOf(completion: *const Completion) common.Result {
    const kernel_result = completion.kernel_result;
    switch (completion.operation) {
        .read => {
            if (kernel_result >= 0) {
                return .{ .read = @as(usize, @intCast(kernel_result)) };
            }
            const errno: linux.E = @fromBackingInt(@intCast(-kernel_result));
            return .{ .read = switch (errno) {
                .IO => error.InputOutput,
                .INVAL => error.Alignment,
                .BADF => error.NotOpenForReading,
                else => error.Unexpected,
            } };
        },
        .write => {
            if (kernel_result >= 0) {
                return .{ .write = @as(usize, @intCast(kernel_result)) };
            }
            const errno: linux.E = @fromBackingInt(@intCast(-kernel_result));
            return .{ .write = switch (errno) {
                .IO => error.InputOutput,
                .NOSPC => error.NoSpaceLeft,
                .DQUOT => error.DiskQuota,
                .FBIG => error.FileTooBig,
                .INVAL => error.Alignment,
                .BADF => error.NotOpenForWriting,
                else => error.Unexpected,
            } };
        },
        .sync => {
            if (kernel_result >= 0) {
                return .{ .sync = {} };
            }
            const errno: linux.E = @fromBackingInt(@intCast(-kernel_result));
            return .{ .sync = switch (errno) {
                .IO => error.InputOutput,
                .NOSPC => error.NoSpaceLeft,
                .DQUOT => error.DiskQuota,
                else => error.Unexpected,
            } };
        },
    }
}
