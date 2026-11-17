//! The files of one store, on a real disk.
//!
//! Storage sits between the store and the event loop (`AsyncIo`). The event
//! loop knows how to start one read, write or sync on a file descriptor and
//! call back when it ends. Storage knows what the store needs from its
//! files:
//!
//! - A read fills its whole buffer unless the file ends first, and a write
//!   writes its whole buffer. The event loop may transfer less in one
//!   operation; Storage starts the rest.
//! - A write can be asked to be durable: its callback runs only after the
//!   data is in permanent storage.
//! - A file can be opened for direct I/O, which goes around the system's
//!   cache. Then a failed write is reported by that write, and a read never
//!   returns bytes that are only in memory. Direct I/O needs whole sectors:
//!   the buffer's address, its length and the offset must be multiples of
//!   `sector_size`, and Storage asserts it on every system.
//!
//! Reads, writes and syncs are asynchronous: the call queues the operation
//! and the callback runs later, from `poll` or `wait`, never from inside the
//! call that started it. The caller owns the operation struct and its
//! buffer, and neither may be moved, freed or assigned to until the
//! callback has run.
//!
//! Creating, opening, closing, truncating, deleting and listing files,
//! syncing the directory, and taking the directory's lock are ordinary
//! blocking calls for now.
//!
//! The store takes its Storage type as a compile-time parameter. Tests pass
//! a simulated one, which keeps files in memory and can crash; see
//! `testing/storage.zig`. The two have the same declarations.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;

const async_io = @import("async_io.zig");
const constants = @import("constants.zig");
const durable = @import("durable.zig");

const AsyncIo = async_io.AsyncIo;
const Completion = async_io.Completion;

/// The unit of direct I/O.
pub const sector_size = constants.sector_size;

comptime {
    assert(std.math.isPowerOfTwo(sector_size));
    // A sector must be a whole number of the disk's own blocks, which are
    // 512 or 4096 bytes.
    assert(sector_size % 512 == 0);
}

pub const Storage = struct {
    io: *AsyncIo,
    std_io: Io,
    dir: Io.Dir,

    /// The most bytes handed to the event loop in one operation. Tests
    /// lower it so that every transfer takes several operations, which is
    /// what a short read or write from the system looks like.
    transfer_size_max: usize,

    /// Held locked while this storage has the directory's lock.
    lock_file: ?Io.File,

    pub const ReadError = async_io.ReadError;
    pub const WriteError = async_io.WriteError || async_io.SyncError || error{
        /// The system wrote nothing and reported no error.
        WroteNothing,
    };
    pub const SyncError = async_io.SyncError;

    pub const CreateError = Io.File.OpenError || error{DirectIoUnsupported};
    pub const OpenError = Io.File.OpenError || error{DirectIoUnsupported};
    pub const DeleteError = Io.Dir.DeleteFileError;
    pub const SizeError = Io.File.LengthError;
    pub const SyncDirError = Io.Dir.OpenError || Io.File.SyncError;
    pub const TruncateError = Io.File.SetLengthError;
    pub const ListError = Io.Dir.OpenError || Io.Dir.Iterator.Error;
    pub const LockError = Io.File.OpenError || error{
        /// Another storage has the directory locked, in this process or
        /// another one.
        AlreadyLocked,
    };

    /// The name of the file that is held locked for as long as a storage
    /// has the directory's lock. The file is empty, and is left in the
    /// directory afterwards: only the lock on it means anything.
    pub const lock_file_name = "LOCK";

    /// The names of the files in the directory, in no particular order.
    pub const Listing = struct {
        std_io: Io,
        dir: Io.Dir,
        entries: Io.Dir.Iterator,

        /// The next name, or `null` when every file has been named. The
        /// name is valid until the next call.
        pub fn next(self: *Listing) ListError!?[]const u8 {
            const entry = try self.entries.next(self.std_io);
            if (entry == null) {
                return null;
            }
            return entry.?.name;
        }

        pub fn close(self: *Listing) void {
            self.dir.close(self.std_io);
            self.* = undefined;
        }
    };

    pub const Access = enum { read_only, read_write };

    pub const FileOptions = struct {
        /// Go around the system's cache. Every read and write of the file
        /// must then be whole sectors.
        direct: bool,
    };

    /// An open file.
    pub const File = struct {
        handle: Io.File,
        direct: bool,
    };

    /// Whether a write's callback waits for the data to be in permanent
    /// storage.
    pub const Durability = enum {
        /// The callback runs once the data is in permanent storage.
        durable,
        /// The callback runs once the system has taken the data. A later
        /// `sync` makes it durable.
        unsynced,
    };

    pub const Read = struct {
        completion: Completion = .{},
        storage: *Storage = undefined,
        callback: *const fn (read: *Read) void = undefined,
        file: File = undefined,
        buffer: []u8 = undefined,
        offset: u64 = undefined,
        /// How many bytes have been read so far.
        transferred: usize = 0,

        /// Set when the callback runs: how many bytes were read. Fewer than
        /// the buffer holds only if the file ended first.
        result: ReadError!usize = undefined,
    };

    pub const Write = struct {
        completion: Completion = .{},
        storage: *Storage = undefined,
        callback: *const fn (write: *Write) void = undefined,
        file: File = undefined,
        buffer: []const u8 = undefined,
        offset: u64 = undefined,
        durability: Durability = undefined,
        /// How many bytes have been written so far.
        transferred: usize = 0,

        /// Set when the callback runs.
        result: WriteError!void = undefined,
    };

    pub const Sync = struct {
        completion: Completion = .{},
        callback: *const fn (sync: *Sync) void = undefined,

        /// Set when the callback runs.
        result: SyncError!void = undefined,
    };

    /// `io` must outlive the storage and must not move.
    pub fn init(io: *AsyncIo, std_io: Io, dir: Io.Dir) Storage {
        return .{
            .io = io,
            .std_io = std_io,
            .dir = dir,
            .transfer_size_max = async_io.transfer_size_max,
            .lock_file = null,
        };
    }

    /// Nothing may be in flight, and the lock must have been given up.
    pub fn deinit(self: *Storage) void {
        assert(self.lock_file == null);
        self.* = undefined;
    }

    /// Takes the lock that marks the directory as in use, so that it is
    /// never open in two stores at once. The lock is held until `unlock`,
    /// or until the process ends.
    pub fn lock(self: *Storage) LockError!void {
        assert(self.lock_file == null);
        // The file is not truncated: it is always empty, and another
        // storage may hold it locked.
        const lock_file = self.dir.createFile(self.std_io, lock_file_name, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.AlreadyLocked,
            else => |other| return other,
        };
        self.lock_file = lock_file;
    }

    pub fn unlock(self: *Storage) void {
        // Closing the file releases the lock.
        self.lock_file.?.close(self.std_io);
        self.lock_file = null;
    }

    /// Starts a listing of the files in the directory. Close it when done.
    pub fn list(self: *Storage) ListError!Listing {
        const dir = try self.dir.openDir(self.std_io, ".", .{ .iterate = true });
        return .{
            .std_io = self.std_io,
            .dir = dir,
            .entries = dir.iterate(),
        };
    }

    /// Cuts the file down to `len` bytes. Like a write, the change is not
    /// durable until the file is synced. No operation on the file may be
    /// in flight.
    pub fn truncate(self: *Storage, file: File, len: u64) TruncateError!void {
        try file.handle.setLength(self.std_io, len);
    }

    /// Creates a file for reading and writing. Fails if it already exists.
    /// The name is not durable until `syncDir`.
    pub fn createFile(self: *Storage, name: []const u8, options: FileOptions) CreateError!File {
        const handle = try self.dir.createFile(self.std_io, name, .{ .read = true, .exclusive = true });
        errdefer {
            handle.close(self.std_io);
            self.dir.deleteFile(self.std_io, name) catch {};
        }
        if (options.direct) {
            try setDirect(handle);
        }
        return .{ .handle = handle, .direct = options.direct };
    }

    pub fn openFile(self: *Storage, name: []const u8, access: Access, options: FileOptions) OpenError!File {
        const handle = try self.dir.openFile(self.std_io, name, .{
            .mode = switch (access) {
                .read_only => .read_only,
                .read_write => .read_write,
            },
        });
        errdefer handle.close(self.std_io);
        if (options.direct) {
            try setDirect(handle);
        }
        return .{ .handle = handle, .direct = options.direct };
    }

    /// No operation on the file may be in flight.
    pub fn closeFile(self: *Storage, file: File) void {
        file.handle.close(self.std_io);
    }

    /// The removal is not durable until `syncDir`.
    pub fn deleteFile(self: *Storage, name: []const u8) DeleteError!void {
        try self.dir.deleteFile(self.std_io, name);
    }

    pub fn fileSize(self: *Storage, file: File) SizeError!u64 {
        return file.handle.length(self.std_io);
    }

    /// Blocks until the names of the files in the directory are in
    /// permanent storage: files created stay, files deleted stay gone.
    pub fn syncDir(self: *Storage) SyncDirError!void {
        try durable.syncDir(self.std_io, self.dir);
    }

    /// Starts reading into `buffer` from `offset`. The callback gets the
    /// number of bytes read, which is `buffer.len` unless the file ended.
    pub fn read(
        self: *Storage,
        operation: *Read,
        callback: *const fn (read: *Read) void,
        file: File,
        buffer: []u8,
        offset: u64,
    ) void {
        assert(buffer.len > 0);
        assertAligned(file, buffer, offset);
        operation.* = .{
            .storage = self,
            .callback = callback,
            .file = file,
            .buffer = buffer,
            .offset = offset,
        };
        self.readRest(operation);
    }

    fn readRest(self: *Storage, operation: *Read) void {
        const rest = operation.buffer[operation.transferred..];
        const len = @min(rest.len, self.transfer_size_max);
        self.io.read(
            &operation.completion,
            onRead,
            operation.file.handle.handle,
            rest[0..len],
            operation.offset + operation.transferred,
        );
    }

    fn onRead(completion: *Completion) void {
        const operation: *Read = @fieldParentPtr("completion", completion);
        const count = completion.result.read catch |err| {
            operation.result = err;
            operation.callback(operation);
            return;
        };
        operation.transferred += count;
        const file_ended = count == 0;
        if (file_ended or operation.transferred == operation.buffer.len) {
            operation.result = operation.transferred;
            operation.callback(operation);
            return;
        }
        operation.storage.readRest(operation);
    }

    /// Starts writing all of `buffer` at `offset`.
    pub fn write(
        self: *Storage,
        operation: *Write,
        callback: *const fn (write: *Write) void,
        file: File,
        buffer: []const u8,
        offset: u64,
        durability: Durability,
    ) void {
        assert(buffer.len > 0);
        assertAligned(file, buffer, offset);
        operation.* = .{
            .storage = self,
            .callback = callback,
            .file = file,
            .buffer = buffer,
            .offset = offset,
            .durability = durability,
        };
        self.writeRest(operation);
    }

    fn writeRest(self: *Storage, operation: *Write) void {
        const rest = operation.buffer[operation.transferred..];
        const len = @min(rest.len, self.transfer_size_max);
        self.io.write(
            &operation.completion,
            onWrite,
            operation.file.handle.handle,
            rest[0..len],
            operation.offset + operation.transferred,
        );
    }

    fn onWrite(completion: *Completion) void {
        const operation: *Write = @fieldParentPtr("completion", completion);
        const count = completion.result.write catch |err| {
            operation.result = err;
            operation.callback(operation);
            return;
        };
        if (count == 0) {
            // Starting the rest again would never end.
            operation.result = error.WroteNothing;
            operation.callback(operation);
            return;
        }
        operation.transferred += count;
        if (operation.transferred < operation.buffer.len) {
            operation.storage.writeRest(operation);
            return;
        }
        switch (operation.durability) {
            .unsynced => {
                operation.result = {};
                operation.callback(operation);
            },
            .durable => {
                // The sync is started only now that the write has ended. A
                // sync started alongside the write could be carried out
                // before it.
                operation.storage.io.sync(completion, onWriteSynced, operation.file.handle.handle);
            },
        }
    }

    fn onWriteSynced(completion: *Completion) void {
        const operation: *Write = @fieldParentPtr("completion", completion);
        operation.result = completion.result.sync;
        operation.callback(operation);
    }

    /// Starts a sync of the file: when it ends without an error, everything
    /// written to the file by writes whose callbacks had run before this
    /// call is in permanent storage.
    pub fn sync(
        self: *Storage,
        operation: *Sync,
        callback: *const fn (sync: *Sync) void,
        file: File,
    ) void {
        operation.* = .{ .callback = callback };
        self.io.sync(&operation.completion, onSync, file.handle.handle);
    }

    fn onSync(completion: *Completion) void {
        const operation: *Sync = @fieldParentPtr("completion", completion);
        operation.result = completion.result.sync;
        operation.callback(operation);
    }

    /// Runs the callbacks of the operations that have ended. Does not wait
    /// for one to end.
    pub fn poll(self: *Storage) void {
        self.io.poll();
    }

    /// Like `poll`, but when no operation has ended yet, blocks until one
    /// does or until `timeout_ns` has passed.
    pub fn wait(self: *Storage, timeout_ns: u64) void {
        self.io.wait(timeout_ns);
    }
};

/// Direct I/O transfers whole sectors, from memory that starts on a sector
/// boundary.
fn assertAligned(file: Storage.File, buffer: []const u8, offset: u64) void {
    if (!file.direct) {
        return;
    }
    assert(@intFromPtr(buffer.ptr) % sector_size == 0);
    assert(buffer.len % sector_size == 0);
    assert(offset % sector_size == 0);
}

/// Makes reads and writes of the file go around the system's cache.
fn setDirect(handle: Io.File) error{DirectIoUnsupported}!void {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            const flags = linux.fcntl(handle.handle, linux.F.GETFL, 0);
            if (linux.errno(flags) != .SUCCESS) {
                return error.DirectIoUnsupported;
            }
            const direct: u32 = @bitCast(linux.O{ .DIRECT = true });
            const result = linux.fcntl(handle.handle, linux.F.SETFL, flags | direct);
            if (linux.errno(result) != .SUCCESS) {
                // Some file systems, among them older memory-backed ones,
                // have no direct I/O.
                return error.DirectIoUnsupported;
            }
        },
        .macos => {
            const result = std.c.fcntl(handle.handle, std.c.F.NOCACHE, @as(c_int, 1));
            if (std.posix.errno(result) != .SUCCESS) {
                return error.DirectIoUnsupported;
            }
        },
        else => @compileError("storage supports Linux and macOS"),
    }
}

test {
    _ = @import("storage_test.zig");
}
