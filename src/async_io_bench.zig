//! Measures whether a durable write through `AsyncIo` leaves the caller
//! free, and how long the write takes, for the ways a log could be written.
//!
//!     zig build async-io-bench -- /path/on/the/disk/to/measure
//!
//! Each row writes one sector at a time. After starting a write, the
//! program calls `poll` in a tight loop until the write is durable, and
//! records three things:
//!
//! - how long the write took in all;
//! - the longest single call to `poll`, which is how long the caller was
//!   stuck and could not have served a read;
//! - how many calls to `poll` were made, which is how many times the caller
//!   got the chance to do something else.
//!
//! A write that the kernel does in the background shows a short longest
//! call and many calls. A write that the kernel does inside the call that
//! hands it over shows a longest call about as long as the whole write.
//!
//! Every sync here is a data sync, which is what `AsyncIo` does. bean's log
//! today does a full sync, which also saves the file's timestamps;
//! `bench/sync-cost.py` measures that as its first row.
//!
//! Linux only: on macOS every operation blocks, by design.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;

const async_io = @import("async_io.zig");
const AsyncIo = async_io.AsyncIo;
const Completion = async_io.Completion;

const sector_size = 4096;
const writes_per_row = 300;
const file_size = sector_size * writes_per_row;

const Method = struct {
    name: []const u8,
    /// Whether the file's space is allocated and written before the
    /// measurement, so that the measured writes change no metadata.
    prewritten: bool,
    direct: bool,
    dsync: bool,
    /// Whether each write is followed by a sync started from its callback.
    sync_after: bool,
};

const methods = [_]Method{
    .{ .name = "append, buffered, then data sync", .prewritten = false, .direct = false, .dsync = false, .sync_after = true },
    .{ .name = "overwrite, buffered, then data sync", .prewritten = true, .direct = false, .dsync = false, .sync_after = true },
    .{ .name = "overwrite, O_DSYNC", .prewritten = true, .direct = false, .dsync = true, .sync_after = false },
    .{ .name = "overwrite, O_DIRECT, then data sync", .prewritten = true, .direct = true, .dsync = false, .sync_after = true },
    .{ .name = "overwrite, O_DIRECT + O_DSYNC (TigerBeetle)", .prewritten = true, .direct = true, .dsync = true, .sync_after = false },
};

/// One write and, for some methods, the sync that follows it.
const DurableWrite = struct {
    io: *AsyncIo,
    fd: linux.fd_t,
    sync_after: bool,
    completion: Completion = .{},
    done: bool = false,

    fn start(self: *DurableWrite, sector: []const u8, offset: u64) void {
        self.done = false;
        self.io.write(&self.completion, onWrite, self.fd, sector, offset);
    }

    fn onWrite(completion: *Completion) void {
        const self: *DurableWrite = @fieldParentPtr("completion", completion);
        const written = completion.result.write catch |err| {
            std.debug.panic("write failed: {t}", .{err});
        };
        // One sector is written whole or not at all.
        assert(written == sector_size);
        if (self.sync_after) {
            self.io.sync(completion, onSync, self.fd);
            return;
        }
        self.done = true;
    }

    fn onSync(completion: *Completion) void {
        const self: *DurableWrite = @fieldParentPtr("completion", completion);
        completion.result.sync catch |err| {
            std.debug.panic("sync failed: {t}", .{err});
        };
        self.done = true;
    }
};

const Samples = struct {
    total_ns: [writes_per_row]u64,
    longest_poll_ns: [writes_per_row]u64,
    polls: [writes_per_row]u64,
};

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) {
        std.debug.print("async-io-bench: Linux only\n", .{});
        std.process.exit(1);
    }

    var arguments = init.minimal.args.iterate();
    _ = arguments.skip();
    const directory = arguments.next();
    if (directory == null) {
        std.debug.print("usage: async-io-bench <directory on the disk to measure>\n", .{});
        std.process.exit(1);
    }

    var path_buffer: [4096]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/async-io-bench.tmp", .{directory.?}, 0);

    var io: AsyncIo = try .init();
    defer io.deinit();

    std.debug.print("{d} writes of {d} bytes per row, one at a time; medians\n\n", .{ writes_per_row, sector_size });
    std.debug.print("{s:<46} {s:>10} {s:>16} {s:>8}\n", .{ "method", "total us", "longest poll us", "polls" });
    for (methods) |method| {
        var samples: Samples = undefined;
        measure(&io, path, method, &samples);
        std.debug.print("{s:<46} {d:>10} {d:>16} {d:>8}\n", .{
            method.name,
            median(&samples.total_ns) / std.time.ns_per_us,
            median(&samples.longest_poll_ns) / std.time.ns_per_us,
            median(&samples.polls),
        });
    }
}

fn measure(io: *AsyncIo, path: [:0]const u8, method: Method, samples: *Samples) void {
    const fd = createFile(path, method);
    defer {
        _ = linux.close(fd);
        _ = linux.unlink(path);
    }

    // Direct I/O needs the buffer's address to be a multiple of the sector
    // size.
    var sector: [sector_size]u8 align(sector_size) = undefined;
    @memset(&sector, 0xb5);

    var write: DurableWrite = .{ .io = io, .fd = fd, .sync_after = method.sync_after };
    for (0..writes_per_row) |index| {
        const started_ns = nowNs();
        write.start(&sector, index * sector_size);

        var longest_poll_ns: u64 = 0;
        var polls: u64 = 0;
        while (!write.done) {
            const poll_started_ns = nowNs();
            io.poll();
            const poll_ns = nowNs() - poll_started_ns;
            if (poll_ns > longest_poll_ns) {
                longest_poll_ns = poll_ns;
            }
            polls += 1;
        }

        samples.total_ns[index] = nowNs() - started_ns;
        samples.longest_poll_ns[index] = longest_poll_ns;
        samples.polls[index] = polls;
    }
}

/// Creates the file through an ordinary descriptor, allocates and writes
/// all of its space if the method asks for it, syncs it, and reopens it
/// with the method's flags.
fn createFile(path: [:0]const u8, method: Method) linux.fd_t {
    _ = linux.unlink(path);

    // The space is written through an ordinary descriptor first, so that
    // preparing the file is the same for every method.
    const plain_flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true };
    const plain_fd: linux.fd_t = @intCast(check(linux.open(path, plain_flags, 0o600), "create"));
    if (method.prewritten) {
        _ = check(linux.fallocate(plain_fd, 0, 0, file_size), "fallocate");
        const zeros: [sector_size]u8 = @splat(0);
        var offset: u64 = 0;
        while (offset < file_size) : (offset += sector_size) {
            const written = check(linux.pwrite(plain_fd, &zeros, zeros.len, @intCast(offset)), "prewrite");
            assert(written == zeros.len);
        }
    }
    _ = check(linux.fsync(plain_fd), "sync");
    _ = check(linux.close(plain_fd), "close");

    const flags: linux.O = .{
        .ACCMODE = .RDWR,
        .DIRECT = method.direct,
        .DSYNC = method.dsync,
    };
    return @intCast(check(linux.open(path, flags, 0), "open"));
}

fn check(result: usize, what: []const u8) usize {
    const errno = linux.errno(result);
    if (errno != .SUCCESS) {
        std.debug.panic("async-io-bench: {s} failed: {t}", .{ what, errno });
    }
    return result;
}

fn nowNs() u64 {
    var now: linux.timespec = undefined;
    _ = check(linux.clock_gettime(.MONOTONIC, &now), "clock_gettime");
    const seconds: u64 = @intCast(now.sec);
    const nanoseconds: u64 = @intCast(now.nsec);
    return seconds * std.time.ns_per_s + nanoseconds;
}

fn median(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}
