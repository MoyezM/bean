//! The parts of the asynchronous I/O layer that are the same on every
//! operating system: what an operation is, what its result is, and the
//! queue the backends keep operations in.

const std = @import("std");
const assert = std.debug.assert;

/// A file, as the operating system names it.
pub const Fd = std.posix.fd_t;

/// The most bytes one read or write transfers. Linux transfers at most this
/// many in one call, and the same cap is used everywhere so that code
/// behaves the same on every system.
pub const transfer_size_max = 0x7ffff000;

pub const InitError = error{
    /// Linux only: the kernel is older than 5.11 or has io_uring switched
    /// off.
    IoUringUnavailable,
    SystemResources,
    Unexpected,
};

pub const ReadError = error{
    /// The disk reported an error.
    InputOutput,
    /// The system rejected the buffer, the length or the offset. For a file
    /// opened for direct I/O this means one of them is not a multiple of
    /// the sector size.
    Alignment,
    NotOpenForReading,
    Unexpected,
};

pub const WriteError = error{
    /// The disk reported an error.
    InputOutput,
    NoSpaceLeft,
    DiskQuota,
    FileTooBig,
    /// The system rejected the buffer, the length or the offset. For a file
    /// opened for direct I/O this means one of them is not a multiple of
    /// the sector size.
    Alignment,
    NotOpenForWriting,
    Unexpected,
};

pub const SyncError = error{
    /// The disk reported an error.
    InputOutput,
    NoSpaceLeft,
    DiskQuota,
    Unexpected,
};

/// What an operation was asked to do.
pub const Operation = union(enum) {
    read: struct {
        fd: Fd,
        buffer: []u8,
        offset: u64,
    },
    write: struct {
        fd: Fd,
        buffer: []const u8,
        offset: u64,
    },
    sync: struct {
        fd: Fd,
    },
};

/// How an operation ended. The active field matches the operation's.
///
/// A read or a write gives the number of bytes it transferred, which can be
/// fewer than the buffer holds. A read that gives 0 is at the end of the
/// file.
pub const Result = union(enum) {
    read: ReadError!usize,
    write: WriteError!usize,
    sync: SyncError!void,
};

/// One operation, from the call that starts it until its callback runs.
///
/// The caller owns this memory and usually keeps it inside a larger struct
/// of its own, which the callback finds again with `@fieldParentPtr`. While
/// the operation is in flight the layer and the system hold pointers to the
/// completion and to the operation's buffer, so neither may be moved, freed
/// or assigned to. Once the callback has been called the completion can be used for
/// another operation, including from inside the callback.
///
/// Create one with `.{}`.
pub const Completion = struct {
    /// Whether an operation has been started with this completion and its
    /// callback has not run yet.
    in_flight: bool = false,

    /// Called once when the operation has ended, with this completion.
    /// `result` is set by then.
    callback: *const fn (completion: *Completion) void = undefined,

    operation: Operation = undefined,
    result: Result = undefined,

    /// The next completion in the queue this one is in.
    next: ?*Completion = null,

    /// The number the Linux kernel gave as the outcome, before it is turned
    /// into `result`. Unused on other systems.
    kernel_result: i32 = undefined,
};

/// Completions in the order they were added, linked through their `next`
/// fields. It allocates nothing.
pub const Queue = struct {
    head: ?*Completion = null,
    tail: ?*Completion = null,

    pub fn isEmpty(self: *const Queue) bool {
        return self.head == null;
    }

    pub fn push(self: *Queue, completion: *Completion) void {
        assert(completion.next == null);
        if (self.tail) |tail| {
            tail.next = completion;
        } else {
            self.head = completion;
        }
        self.tail = completion;
    }

    pub fn pop(self: *Queue) ?*Completion {
        if (self.head == null) {
            return null;
        }
        const completion = self.head.?;
        self.head = completion.next;
        if (self.head == null) {
            self.tail = null;
        }
        completion.next = null;
        return completion;
    }

    /// Empties this queue and returns what it held, in the same order.
    pub fn takeAll(self: *Queue) Queue {
        const taken = self.*;
        self.* = .{};
        return taken;
    }
};

/// The length to ask the system to transfer for a buffer of `len` bytes.
pub fn transferSize(len: usize) usize {
    return @min(len, transfer_size_max);
}

test "a queue gives completions back in the order they were added" {
    var first: Completion = .{};
    var second: Completion = .{};
    var third: Completion = .{};

    var queue: Queue = .{};
    try std.testing.expect(queue.isEmpty());
    queue.push(&first);
    queue.push(&second);
    try std.testing.expectEqual(&first, queue.pop().?);
    queue.push(&third);
    try std.testing.expectEqual(&second, queue.pop().?);
    try std.testing.expectEqual(&third, queue.pop().?);
    try std.testing.expectEqual(null, queue.pop());
    try std.testing.expect(queue.isEmpty());
}

test "taking all leaves the queue empty and keeps the order" {
    var first: Completion = .{};
    var second: Completion = .{};

    var queue: Queue = .{};
    queue.push(&first);
    queue.push(&second);

    var taken = queue.takeAll();
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(&first, taken.pop().?);
    try std.testing.expectEqual(&second, taken.pop().?);
    try std.testing.expectEqual(null, taken.pop());
}
