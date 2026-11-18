//! The files of one store, simulated in memory, for tests.
//!
//! It has the same declarations as the real `storage.zig`, so the store and
//! its modules, which take their Storage type as a compile-time parameter,
//! run on either. What the simulation adds is control: every run with the
//! same seed does the same thing, operations end in a shuffled order, and
//! the test can crash the machine at any operation and look at what a
//! restart would find.
//!
//! Each file has two copies of its contents:
//!
//! - `visible` is what a read returns. A write changes it when the write
//!   ends.
//! - `durable` is what is in permanent storage. A durable write, or a sync,
//!   brings it up to date with `visible`.
//!
//! The directory has the same split: a file's name is visible as soon as
//! the file is created or deleted, and durable only after `syncDir`.
//!
//! A crash is one of two kinds:
//!
//! - **Power loss.** Each sector of a write that was in flight either
//!   reached the disk or did not. Each sector that was written and not yet
//!   made durable is either kept or lost. Names that were not synced are
//!   all kept or all lost. What remains is what the restart sees.
//! - **Process kill.** The machine stays up. Sectors of writes in flight
//!   land or do not, and everything else is as the process last saw it,
//!   including data that is not durable yet. A power loss can still follow.
//!
//! After a crash every operation fails with `error.InputOutput` until
//! `restart`, which is how the store under test is made to stop: it sees
//! its storage fail, as it would if the process were dying.
//!
//! This is test code, so unlike the store it allocates as it goes, and it
//! stops the program if it runs out of memory.

const std = @import("std");
const assert = std.debug.assert;

const constants = @import("../constants.zig");

/// The unit of direct I/O, and the unit in which a crash keeps or loses
/// data.
pub const sector_size = constants.sector_size;

pub const Options = struct {
    /// Decides every random choice the simulation makes.
    seed: u64 = 0,
    /// An operation ends between 1 and this many ticks after it starts.
    /// Above 1, operations in flight together end in a shuffled order.
    latency_ticks_max: u64 = 4,
    /// The most files that can exist over the storage's lifetime,
    /// including deleted ones.
    files_max: u32 = 256,
};

pub const CrashKind = enum {
    /// The power goes. Each thing that was not durable is kept or lost by
    /// the toss of a coin.
    power_loss,
    /// The power goes, and everything that was not durable is lost.
    power_loss_worst,
    /// The process dies and the machine stays up.
    process_kill,
};

pub const Storage = struct {
    gpa: std.mem.Allocator,
    prng: std.Random.DefaultPrng,
    options: Options,

    /// Every file ever created, including deleted ones, which a crash can
    /// bring back.
    files: []FileState,
    file_count: u32,

    /// Simulated time, in ticks. It moves only in `poll` and `wait`.
    now: u64,

    /// Operations that have been started and not yet called back, ordered
    /// by when they end.
    pending: ?*Pending,
    in_flight: u32,

    /// How many operations have been started.
    operations_started: u64,

    /// A crash that will happen when `operations_started` reaches a number.
    crash_plan: ?CrashPlan,

    /// Whether the machine has crashed and not yet restarted.
    crashed: bool,

    /// Whether `poll` or `wait` is running. A callback must not call them.
    running: bool,

    /// Whether the directory's lock is held.
    locked: bool,

    pub const ReadError = error{InputOutput};
    pub const WriteError = error{InputOutput};
    pub const SyncError = error{InputOutput};
    pub const CreateError = error{ PathAlreadyExists, InputOutput };
    pub const OpenError = error{ FileNotFound, InputOutput };
    pub const DeleteError = error{ FileNotFound, InputOutput };
    pub const SizeError = error{InputOutput};
    pub const SyncDirError = error{InputOutput};
    pub const TruncateError = error{InputOutput};
    pub const ListError = error{InputOutput};
    pub const LockError = error{ AlreadyLocked, InputOutput };

    /// The names of the files in the directory, in the order they were
    /// created.
    pub const Listing = struct {
        storage: *Storage,
        index: u32,

        /// The next name, or `null` when every file has been named. The
        /// name is valid until the next call.
        pub fn next(self: *Listing) ListError!?[]const u8 {
            if (self.storage.crashed) {
                return error.InputOutput;
            }
            while (self.index < self.storage.file_count) {
                const file = &self.storage.files[self.index];
                self.index += 1;
                if (file.listed) {
                    return file.name;
                }
            }
            return null;
        }

        pub fn close(self: *Listing) void {
            self.* = undefined;
        }
    };

    pub const Access = enum { read_only, read_write };

    pub const FileOptions = struct {
        /// Every read and write of the file must be whole sectors.
        direct: bool,
    };

    /// An open file.
    pub const File = struct {
        index: u32,
        direct: bool,
        access: Access,
    };

    pub const Durability = enum { durable, unsynced };

    pub const Read = struct {
        pending: Pending = .{},
        callback: *const fn (read: *Read) void = undefined,
        file: File = undefined,
        buffer: []u8 = undefined,
        offset: u64 = undefined,

        /// Set when the callback runs: how many bytes were read. Fewer than
        /// the buffer holds only if the file ended first.
        result: ReadError!usize = undefined,
    };

    pub const Write = struct {
        pending: Pending = .{},
        callback: *const fn (write: *Write) void = undefined,
        file: File = undefined,
        buffer: []const u8 = undefined,
        offset: u64 = undefined,
        durability: Durability = undefined,

        /// Set when the callback runs.
        result: WriteError!void = undefined,
    };

    pub const Sync = struct {
        pending: Pending = .{},
        callback: *const fn (sync: *Sync) void = undefined,
        file: File = undefined,
        /// The file's contents when the sync started, which is what the
        /// sync makes durable.
        snapshot: []u8 = undefined,
        /// The file's `visible_version` when the sync started.
        snapshot_version: u64 = undefined,

        /// Set when the callback runs.
        result: SyncError!void = undefined,
    };

    const Pending = struct {
        kind: enum { read, write, sync } = undefined,
        /// The tick at which the operation ends.
        ready_at: u64 = undefined,
        /// The operation's place in the order operations were started.
        sequence: u64 = undefined,
        in_flight: bool = false,
        next: ?*Pending = null,
    };

    const CrashPlan = struct {
        at_operation: u64,
        kind: CrashKind,
    };

    const FileState = struct {
        name: []u8,
        visible: []u8,
        durable: []u8,
        /// Goes up by one each time `visible` changes.
        visible_version: u64,
        /// The `visible_version` that `durable` holds.
        durable_version: u64,
        /// Whether the directory lists the file.
        listed: bool,
        /// Whether the directory would list the file after a power loss.
        listed_durable: bool,
        /// Which operation was the last write started on the file, counted
        /// as `operations_started` counts. 0 if there has been none.
        write_operation_last: u64,
    };

    pub fn init(gpa: std.mem.Allocator, options: Options) Storage {
        assert(options.latency_ticks_max >= 1);
        const files = gpa.alloc(FileState, options.files_max) catch outOfMemory();
        return .{
            .gpa = gpa,
            .prng = .init(options.seed),
            .options = options,
            .files = files,
            .file_count = 0,
            .now = 0,
            .pending = null,
            .in_flight = 0,
            .operations_started = 0,
            .crash_plan = null,
            .crashed = false,
            .running = false,
            .locked = false,
        };
    }

    /// Takes the lock that marks the directory as in use. The lock is held
    /// until `unlock`, or until the machine crashes.
    pub fn lock(self: *Storage) LockError!void {
        if (self.crashed) {
            return error.InputOutput;
        }
        if (self.locked) {
            return error.AlreadyLocked;
        }
        self.locked = true;
    }

    pub fn unlock(self: *Storage) void {
        assert(self.locked);
        self.locked = false;
    }

    /// Starts a listing of the files in the directory. Close it when done.
    pub fn list(self: *Storage) ListError!Listing {
        if (self.crashed) {
            return error.InputOutput;
        }
        return .{ .storage = self, .index = 0 };
    }

    /// Cuts the file down to `len` bytes. Like a write, the change is not
    /// durable until the file is synced.
    pub fn truncate(self: *Storage, file: File, len: u64) TruncateError!void {
        if (self.crashed) {
            return error.InputOutput;
        }
        assert(file.access == .read_write);
        const state = &self.files[file.index];
        assert(len <= state.visible.len);
        state.visible = self.gpa.realloc(state.visible, @intCast(len)) catch outOfMemory();
        state.visible_version += 1;
    }

    /// Nothing may be in flight.
    pub fn deinit(self: *Storage) void {
        assert(self.in_flight == 0);
        assert(self.pending == null);
        for (self.files[0..self.file_count]) |file| {
            self.gpa.free(file.name);
            self.gpa.free(file.visible);
            self.gpa.free(file.durable);
        }
        self.gpa.free(self.files);
        self.* = undefined;
    }

    /// Creates a file for reading and writing. Fails if it already exists.
    /// The name is not durable until `syncDir`.
    pub fn createFile(self: *Storage, name: []const u8, options: FileOptions) CreateError!File {
        if (self.crashed) {
            return error.InputOutput;
        }
        if (self.findListed(name) != null) {
            return error.PathAlreadyExists;
        }
        assert(self.file_count < self.files.len);
        const index = self.file_count;
        self.files[index] = .{
            .name = self.gpa.dupe(u8, name) catch outOfMemory(),
            .visible = &.{},
            .durable = &.{},
            .visible_version = 0,
            .durable_version = 0,
            .listed = true,
            .listed_durable = false,
            .write_operation_last = 0,
        };
        self.file_count += 1;
        return .{ .index = index, .direct = options.direct, .access = .read_write };
    }

    pub fn openFile(self: *Storage, name: []const u8, access: Access, options: FileOptions) OpenError!File {
        if (self.crashed) {
            return error.InputOutput;
        }
        const index = self.findListed(name);
        if (index == null) {
            return error.FileNotFound;
        }
        return .{ .index = index.?, .direct = options.direct, .access = access };
    }

    /// No operation on the file may be in flight.
    pub fn closeFile(self: *Storage, file: File) void {
        assert(file.index < self.file_count);
    }

    /// The removal is not durable until `syncDir`.
    pub fn deleteFile(self: *Storage, name: []const u8) DeleteError!void {
        if (self.crashed) {
            return error.InputOutput;
        }
        const index = self.findListed(name);
        if (index == null) {
            return error.FileNotFound;
        }
        self.files[index.?].listed = false;
    }

    pub fn fileSize(self: *Storage, file: File) SizeError!u64 {
        if (self.crashed) {
            return error.InputOutput;
        }
        return self.files[file.index].visible.len;
    }

    /// Makes the names of the files in the directory durable: files created
    /// stay, files deleted stay gone.
    pub fn syncDir(self: *Storage) SyncDirError!void {
        if (self.crashed) {
            return error.InputOutput;
        }
        for (self.files[0..self.file_count]) |*file| {
            file.listed_durable = file.listed;
        }
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
        assert(!operation.pending.in_flight);
        assert(buffer.len > 0);
        assertAligned(file, buffer, offset);
        operation.* = .{
            .callback = callback,
            .file = file,
            .buffer = buffer,
            .offset = offset,
        };
        operation.pending.kind = .read;
        self.schedule(&operation.pending);
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
        assert(!operation.pending.in_flight);
        assert(file.access == .read_write);
        assert(buffer.len > 0);
        assertAligned(file, buffer, offset);
        operation.* = .{
            .callback = callback,
            .file = file,
            .buffer = buffer,
            .offset = offset,
            .durability = durability,
        };
        operation.pending.kind = .write;
        self.schedule(&operation.pending);
        self.files[file.index].write_operation_last = operation.pending.sequence;
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
        assert(!operation.pending.in_flight);
        const state = &self.files[file.index];
        operation.* = .{
            .callback = callback,
            .file = file,
            .snapshot = self.gpa.dupe(u8, state.visible) catch outOfMemory(),
            .snapshot_version = state.visible_version,
        };
        operation.pending.kind = .sync;
        self.schedule(&operation.pending);
    }

    /// Moves time on by one tick and runs the callbacks of the operations
    /// that have ended.
    pub fn poll(self: *Storage) void {
        self.now += 1;
        self.deliver();
    }

    /// Moves time on to when the next operation ends, and runs the
    /// callbacks of the operations that have ended. `timeout_ns` is
    /// ignored: simulated time has no nanoseconds.
    pub fn wait(self: *Storage, timeout_ns: u64) void {
        _ = timeout_ns;
        self.now += 1;
        if (self.pending) |first| {
            if (first.ready_at > self.now) {
                self.now = first.ready_at;
            }
        }
        self.deliver();
    }

    /// Crashes the machine now.
    pub fn crash(self: *Storage, kind: CrashKind) void {
        assert(!self.crashed);
        self.crash_plan = null;

        // Each sector of a write in flight reached the disk or did not.
        var pending = self.pending;
        while (pending) |operation| {
            if (operation.kind == .write) {
                const write_operation: *Write = @fieldParentPtr("pending", operation);
                self.tearWrite(write_operation);
            }
            // The process is dying: every operation ends at once, with an
            // error.
            operation.ready_at = self.now;
            pending = operation.next;
        }

        if (kind == .power_loss or kind == .power_loss_worst) {
            const lose_all = kind == .power_loss_worst;
            var names_kept = self.prng.random().boolean();
            if (lose_all) {
                names_kept = false;
            }
            for (self.files[0..self.file_count]) |*file| {
                self.losePower(file, lose_all);
                if (names_kept) {
                    file.listed_durable = file.listed;
                } else {
                    file.listed = file.listed_durable;
                }
            }
        }

        self.crashed = true;
    }

    /// Crashes the machine when `count` more operations have been started.
    /// The last of them is in flight when the crash happens.
    pub fn crashAfterOperations(self: *Storage, count: u64, kind: CrashKind) void {
        assert(!self.crashed);
        assert(count >= 1);
        self.crash_plan = .{
            .at_operation = self.operations_started + count,
            .kind = kind,
        };
    }

    /// Brings the machine back up after a crash. Everything that was in
    /// flight must have been called back, with its error, by then.
    pub fn restart(self: *Storage) void {
        assert(self.crashed);
        assert(self.in_flight == 0);
        self.crashed = false;
        // The process that held the lock is gone.
        self.locked = false;
    }

    /// Flips one byte of a file, in both copies, as a disk that damages
    /// data would.
    pub fn corruptByte(self: *Storage, name: []const u8, offset: u64) void {
        const index = self.findListed(name).?;
        const file = &self.files[index];
        const position: usize = @intCast(offset);
        file.visible[position] ^= 0xff;
        if (position < file.durable.len) {
            file.durable[position] ^= 0xff;
        }
    }

    /// Overwrites part of a file, in both copies, as if it had always
    /// held these bytes. The file must already be that long.
    pub fn setBytes(self: *Storage, name: []const u8, offset: u64, bytes: []const u8) void {
        const index = self.findListed(name).?;
        const file = &self.files[index];
        const start: usize = @intCast(offset);
        @memcpy(file.visible[start..][0..bytes.len], bytes);
        @memcpy(file.durable[start..][0..bytes.len], bytes);
        file.visible_version += 1;
        file.durable_version = file.visible_version;
    }

    /// What a read of the whole file would return.
    pub fn contents(self: *Storage, name: []const u8) []const u8 {
        const index = self.findListed(name).?;
        return self.files[index].visible;
    }

    /// Which operation was the last write started on the file: 1 for the
    /// first operation the storage was given. 0 if the file has not been
    /// written to. A test uses this to plan a crash during that write.
    pub fn lastWriteOperation(self: *Storage, name: []const u8) u64 {
        const index = self.findListed(name).?;
        return self.files[index].write_operation_last;
    }

    pub fn exists(self: *Storage, name: []const u8) bool {
        return self.findListed(name) != null;
    }

    fn findListed(self: *Storage, name: []const u8) ?u32 {
        for (self.files[0..self.file_count], 0..) |file, index| {
            if (file.listed and std.mem.eql(u8, file.name, name)) {
                return @intCast(index);
            }
        }
        return null;
    }

    fn schedule(self: *Storage, operation: *Pending) void {
        self.operations_started += 1;
        self.in_flight += 1;
        operation.in_flight = true;
        operation.sequence = self.operations_started;
        operation.next = null;
        if (self.crashed) {
            operation.ready_at = self.now + 1;
        } else {
            const latency = 1 + self.prng.random().uintLessThan(u64, self.options.latency_ticks_max);
            operation.ready_at = self.now + latency;
        }
        self.insert(operation);

        if (self.crash_plan) |plan| {
            if (self.operations_started == plan.at_operation) {
                self.crash(plan.kind);
            }
        }
    }

    /// Puts the operation into `pending`, after every operation that ends
    /// at the same tick or earlier.
    fn insert(self: *Storage, operation: *Pending) void {
        var link = &self.pending;
        while (link.*) |other| {
            if (other.ready_at > operation.ready_at) {
                break;
            }
            link = &other.next;
        }
        operation.next = link.*;
        link.* = operation;
    }

    /// Runs the callbacks of the operations that have ended. Operations
    /// that those callbacks start wait for a later call.
    fn deliver(self: *Storage) void {
        assert(!self.running);
        self.running = true;
        defer self.running = false;

        const last_sequence = self.operations_started;
        while (self.pending) |operation| {
            if (operation.ready_at > self.now) {
                break;
            }
            if (operation.sequence > last_sequence) {
                break;
            }
            self.pending = operation.next;
            operation.next = null;
            operation.in_flight = false;
            self.in_flight -= 1;
            switch (operation.kind) {
                .read => self.finishRead(@fieldParentPtr("pending", operation)),
                .write => self.finishWrite(@fieldParentPtr("pending", operation)),
                .sync => self.finishSync(@fieldParentPtr("pending", operation)),
            }
        }
    }

    fn finishRead(self: *Storage, operation: *Read) void {
        if (self.crashed) {
            operation.result = error.InputOutput;
            operation.callback(operation);
            return;
        }
        const visible = self.files[operation.file.index].visible;
        var count: usize = 0;
        if (operation.offset < visible.len) {
            const start: usize = @intCast(operation.offset);
            count = @min(operation.buffer.len, visible.len - start);
            @memcpy(operation.buffer[0..count], visible[start..][0..count]);
        }
        operation.result = count;
        operation.callback(operation);
    }

    fn finishWrite(self: *Storage, operation: *Write) void {
        if (self.crashed) {
            operation.result = error.InputOutput;
            operation.callback(operation);
            return;
        }
        const file = &self.files[operation.file.index];
        const durable_was_current = file.durable_version == file.visible_version;
        self.writeInto(&file.visible, operation.offset, operation.buffer);
        file.visible_version += 1;
        if (operation.durability == .durable) {
            // The sync that follows a durable write makes the whole file
            // durable, not only this write.
            if (durable_was_current) {
                // Only this write separates the two copies, so applying it
                // to the durable copy brings that one up to date without
                // copying the whole file.
                self.writeInto(&file.durable, operation.offset, operation.buffer);
            } else {
                self.gpa.free(file.durable);
                file.durable = self.gpa.dupe(u8, file.visible) catch outOfMemory();
            }
            file.durable_version = file.visible_version;
        }
        operation.result = {};
        operation.callback(operation);
    }

    fn finishSync(self: *Storage, operation: *Sync) void {
        if (self.crashed) {
            self.gpa.free(operation.snapshot);
            operation.result = error.InputOutput;
            operation.callback(operation);
            return;
        }
        const file = &self.files[operation.file.index];
        if (operation.snapshot_version > file.durable_version) {
            self.gpa.free(file.durable);
            file.durable = operation.snapshot;
            file.durable_version = operation.snapshot_version;
        } else {
            // Something newer than this sync's view is durable already.
            self.gpa.free(operation.snapshot);
        }
        operation.result = {};
        operation.callback(operation);
    }

    /// Copies `bytes` into `data` at `offset`, growing `data` with zeros
    /// if it is too short.
    fn writeInto(self: *Storage, data: *[]u8, offset: u64, bytes: []const u8) void {
        const start: usize = @intCast(offset);
        const end = start + bytes.len;
        if (end > data.len) {
            const old_len = data.len;
            data.* = self.gpa.realloc(data.*, end) catch outOfMemory();
            @memset(data.*[old_len..end], 0);
        }
        @memcpy(data.*[start..end], bytes);
    }

    /// A crash caught this write in flight: each sector of it lands or does
    /// not.
    fn tearWrite(self: *Storage, operation: *Write) void {
        const file = &self.files[operation.file.index];
        const random = self.prng.random();
        var done: usize = 0;
        var changed = false;
        while (done < operation.buffer.len) {
            const offset = operation.offset + done;
            const sector_end = (offset / sector_size + 1) * sector_size;
            const len: usize = @intCast(@min(sector_end - offset, operation.buffer.len - done));
            if (random.boolean()) {
                self.writeInto(&file.visible, offset, operation.buffer[done..][0..len]);
                changed = true;
            }
            done += len;
        }
        if (changed) {
            file.visible_version += 1;
        }
    }

    /// The power went: each sector that was written and not made durable is
    /// kept or lost. Afterwards the two copies are the same.
    fn losePower(self: *Storage, file: *FileState, lose_all: bool) void {
        const random = self.prng.random();
        if (file.visible.len < file.durable.len) {
            // The file was cut down and the cut was not synced. It holds
            // or it does not.
            if (!lose_all and random.boolean()) {
                file.durable = self.gpa.realloc(file.durable, file.visible.len) catch outOfMemory();
            }
        }
        var offset: usize = 0;
        while (offset < file.visible.len) : (offset += sector_size) {
            const end = @min(offset + sector_size, file.visible.len);
            const sector = file.visible[offset..end];
            var is_durable = false;
            if (end <= file.durable.len) {
                is_durable = std.mem.eql(u8, sector, file.durable[offset..end]);
            }
            if (is_durable) {
                continue;
            }
            if (!lose_all and random.boolean()) {
                self.writeInto(&file.durable, offset, sector);
            }
        }
        self.gpa.free(file.visible);
        file.visible = self.gpa.dupe(u8, file.durable) catch outOfMemory();
        file.visible_version += 1;
        file.durable_version = file.visible_version;
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

fn outOfMemory() noreturn {
    @panic("the simulated storage ran out of memory");
}
