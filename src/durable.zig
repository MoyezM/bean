//! Syncing a file so that what was written to it survives a power failure.
//!
//! On most systems an ordinary sync does this: it returns once the drive has
//! the data in permanent storage. On macOS it does not. There `fsync` hands
//! the data to the drive, which may still hold it in a cache that is lost
//! when the power goes. macOS has a separate request, `F_FULLFSYNC`, that
//! makes the drive empty that cache. It is much slower, by a factor of about
//! a hundred on a laptop's built-in drive.
//!
//! Every sync in the store goes through `sync` here, so that a write the
//! store reports as durable is durable on every system.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Whether this build syncs with the full sync that makes the drive empty
/// its cache. It is decided when the program is compiled.
pub const uses_full_sync = builtin.os.tag.isDarwin();

/// Blocks until everything written to `file` is in permanent storage.
///
/// On macOS this talks to the system directly and not through `io`.
/// `Io` has no call for a full sync.
pub fn sync(io: Io, file: Io.File) Io.File.SyncError!void {
    if (uses_full_sync) {
        return fullSync(io, file);
    }
    return file.sync(io);
}

/// Asks the drive to empty its cache. Falls back to an ordinary sync on a
/// file system that does not support the request.
fn fullSync(io: Io, file: Io.File) Io.File.SyncError!void {
    while (true) {
        const result = std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0));
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
                // Network and some external file systems do not support the
                // full sync. An ordinary sync is the most they can do.
                return file.sync(io);
            },
        }
    }
}

const testing = std.testing;

test "sync succeeds on a file and leaves its contents alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "synced", .{ .read = true });
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, "contents", 0);
    try sync(testing.io, file);

    var buffer: [8]u8 = undefined;
    const bytes_read = try file.readPositionalAll(testing.io, &buffer, 0);
    try testing.expectEqualSlices(u8, "contents", buffer[0..bytes_read]);
}
