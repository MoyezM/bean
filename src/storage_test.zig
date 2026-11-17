//! Tests of the real and the simulated Storage.
//!
//! Most tests are written once and run on both, because the store relies
//! on the two behaving the same. Tests of what only one of them can do,
//! such as crashing, follow.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const async_io = @import("async_io.zig");
const real = @import("storage.zig");
const simulated = @import("testing/storage.zig");
const BlockingType = @import("storage_blocking.zig").BlockingType;

const sector_size = real.sector_size;

comptime {
    assert(simulated.sector_size == sector_size);
}

/// A real Storage on a fresh directory. It holds pointers into itself, so
/// it is set up in place and must not be moved.
const RealFixture = struct {
    pub const Storage = real.Storage;

    tmp: testing.TmpDir,
    io: async_io.AsyncIo,
    storage: real.Storage,

    fn init(self: *RealFixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.io = try .init();
        self.storage = .init(&self.io, testing.io, self.tmp.dir);
    }

    fn deinit(self: *RealFixture) void {
        self.storage.deinit();
        self.io.deinit();
        self.tmp.cleanup();
    }
};

const SimulatedFixture = struct {
    pub const Storage = simulated.Storage;

    storage: simulated.Storage,

    fn init(self: *SimulatedFixture) !void {
        self.storage = .init(testing.allocator, .{ .seed = 7 });
    }

    fn deinit(self: *SimulatedFixture) void {
        self.storage.deinit();
    }
};

const fixtures = .{ RealFixture, SimulatedFixture };

const buffered: real.Storage.FileOptions = .{ .direct = false };

fn checkWrittenIsReadBack(comptime Storage: type, storage: *Storage) !void {
    const Blocking = BlockingType(Storage);
    const file = try storage.createFile("data", .{ .direct = false });
    defer storage.closeFile(file);

    try Blocking.writeAll(storage, file, "hello, ", 0, .unsynced);
    try Blocking.writeAll(storage, file, "world", 7, .durable);
    try testing.expectEqual(@as(u64, 12), try storage.fileSize(file));

    var buffer: [12]u8 = undefined;
    try testing.expectEqual(@as(usize, 12), try Blocking.readAll(storage, file, &buffer, 0));
    try testing.expectEqualStrings("hello, world", &buffer);
}

test "what is written can be read back" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try checkWrittenIsReadBack(Fixture.Storage, &fixture.storage);
    }
}

fn checkReadStopsAtEndOfFile(comptime Storage: type, storage: *Storage) !void {
    const Blocking = BlockingType(Storage);
    const file = try storage.createFile("data", .{ .direct = false });
    defer storage.closeFile(file);
    try Blocking.writeAll(storage, file, "abcde", 0, .unsynced);

    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try Blocking.readAll(storage, file, &buffer, 3));
    try testing.expectEqualStrings("de", buffer[0..2]);
    try testing.expectEqual(@as(usize, 0), try Blocking.readAll(storage, file, &buffer, 5));
    try testing.expectEqual(@as(usize, 0), try Blocking.readAll(storage, file, &buffer, 100));
}

test "a read stops at the end of the file" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try checkReadStopsAtEndOfFile(Fixture.Storage, &fixture.storage);
    }
}

fn checkNames(comptime Storage: type, storage: *Storage) !void {
    const Blocking = BlockingType(Storage);
    try testing.expectError(error.FileNotFound, storage.openFile("data", .read_only, .{ .direct = false }));
    try testing.expectError(error.FileNotFound, storage.deleteFile("data"));

    const created = try storage.createFile("data", .{ .direct = false });
    try Blocking.writeAll(storage, created, "kept", 0, .durable);
    storage.closeFile(created);
    try storage.syncDir();
    try testing.expectError(error.PathAlreadyExists, storage.createFile("data", .{ .direct = false }));

    const opened = try storage.openFile("data", .read_only, .{ .direct = false });
    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try Blocking.readAll(storage, opened, &buffer, 0));
    try testing.expectEqualStrings("kept", &buffer);
    storage.closeFile(opened);

    try storage.deleteFile("data");
    try testing.expectError(error.FileNotFound, storage.openFile("data", .read_only, .{ .direct = false }));
    const again = try storage.createFile("data", .{ .direct = false });
    try testing.expectEqual(@as(u64, 0), try storage.fileSize(again));
    storage.closeFile(again);
}

test "files are created, opened and deleted by name" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try checkNames(Fixture.Storage, &fixture.storage);
    }
}

fn checkDirectFile(comptime Storage: type, storage: *Storage) !void {
    const Blocking = BlockingType(Storage);
    const file = try storage.createFile("direct", .{ .direct = true });
    defer storage.closeFile(file);

    var written: [3 * sector_size]u8 align(sector_size) = undefined;
    for (&written, 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }
    try Blocking.writeAll(storage, file, &written, 0, .durable);
    // The middle sector again, on its own.
    @memset(written[sector_size .. 2 * sector_size], 0xee);
    try Blocking.writeAll(storage, file, written[sector_size .. 2 * sector_size], sector_size, .durable);

    var read_back: [3 * sector_size]u8 align(sector_size) = undefined;
    try testing.expectEqual(@as(usize, read_back.len), try Blocking.readAll(storage, file, &read_back, 0));
    try testing.expectEqualSlices(u8, &written, &read_back);
}

test "a direct file is read and written in whole sectors" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try checkDirectFile(Fixture.Storage, &fixture.storage);
    }
}

/// Many writes in flight at once, started without running the event loop
/// in between.
fn ManyWritesType(comptime Storage: type) type {
    return struct {
        const Self = @This();
        const count = 200;

        operations: [count]Storage.Write = @splat(.{}),
        bytes: [count]u8 = undefined,
        ended: u32 = 0,
        failed: bool = false,

        fn onWrite(operation: *Storage.Write) void {
            // The callback is given only the operation. The operations are
            // elements of an array, so the struct that holds them is found
            // through `current`.
            const self = current.?;
            operation.result catch {
                self.failed = true;
            };
            self.ended += 1;
        }

        var current: ?*Self = null;
    };
}

fn checkManyInFlight(comptime Storage: type, storage: *Storage) !void {
    const Blocking = BlockingType(Storage);
    const ManyWrites = ManyWritesType(Storage);
    const file = try storage.createFile("many", .{ .direct = false });
    defer storage.closeFile(file);

    var many: ManyWrites = .{};
    ManyWrites.current = &many;
    defer ManyWrites.current = null;

    for (&many.operations, &many.bytes, 0..) |*operation, *byte, index| {
        byte.* = @intCast(index % 251);
        storage.write(operation, ManyWrites.onWrite, file, byte[0..1], index, .unsynced);
    }
    // Starting an operation never runs a callback.
    try testing.expectEqual(@as(u32, 0), many.ended);

    while (many.ended < ManyWrites.count) {
        storage.wait(std.time.ns_per_ms);
    }
    try testing.expect(!many.failed);

    var read_back: [ManyWrites.count]u8 = undefined;
    try testing.expectEqual(@as(usize, read_back.len), try Blocking.readAll(storage, file, &read_back, 0));
    try testing.expectEqualSlices(u8, &many.bytes, &read_back);
}

test "many operations can be in flight, and starting one never calls back" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try checkManyInFlight(Fixture.Storage, &fixture.storage);
    }
}

fn checkSync(comptime Storage: type, storage: *Storage) !void {
    const Blocking = BlockingType(Storage);
    const file = try storage.createFile("synced", .{ .direct = false });
    defer storage.closeFile(file);
    try Blocking.writeAll(storage, file, "to be synced", 0, .unsynced);
    try Blocking.syncFile(storage, file);
}

test "a sync ends without an error" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try checkSync(Fixture.Storage, &fixture.storage);
    }
}

test "real: a transfer that takes several operations is finished" {
    var fixture: RealFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const storage = &fixture.storage;
    const Blocking = BlockingType(real.Storage);

    // Every transfer now moves at most three bytes at a time, which is
    // what short reads and writes from the system look like.
    storage.transfer_size_max = 3;

    const file = try storage.createFile("short", buffered);
    defer storage.closeFile(file);
    const text = "a transfer in many small pieces";
    try Blocking.writeAll(storage, file, text, 0, .durable);

    var buffer: [text.len + 5]u8 = undefined;
    const len = try Blocking.readAll(storage, file, &buffer, 0);
    try testing.expectEqualStrings(text, buffer[0..len]);
}

// From here on: what only the simulated storage can do.

const Simulated = simulated.Storage;
const SimulatedBlocking = BlockingType(Simulated);
const simulated_buffered: Simulated.FileOptions = .{ .direct = false };

fn expectContents(storage: *Simulated, name: []const u8, expected: []const u8) !void {
    try testing.expectEqualSlices(u8, expected, storage.contents(name));
}

test "simulated: the same seed gives the same order of completions" {
    var orders: [2][8]u8 = undefined;
    for (&orders) |*order| {
        var storage: Simulated = .init(testing.allocator, .{ .seed = 99, .latency_ticks_max = 8 });
        defer storage.deinit();
        const file = try storage.createFile("data", simulated_buffered);

        const Recorder = struct {
            operations: [8]Simulated.Write = @splat(.{}),
            order: [8]u8 = undefined,
            ended: u8 = 0,

            var current: ?*@This() = null;

            fn onWrite(operation: *Simulated.Write) void {
                const self = current.?;
                const index = (@intFromPtr(operation) - @intFromPtr(&self.operations[0])) / @sizeOf(Simulated.Write);
                self.order[self.ended] = @intCast(index);
                self.ended += 1;
            }
        };
        var recorder: Recorder = .{};
        Recorder.current = &recorder;
        defer Recorder.current = null;

        const byte = [1]u8{1};
        for (&recorder.operations, 0..) |*operation, index| {
            storage.write(operation, Recorder.onWrite, file, &byte, index, .unsynced);
        }
        while (recorder.ended < 8) {
            storage.wait(0);
        }
        order.* = recorder.order;
    }
    try testing.expectEqualSlices(u8, &orders[0], &orders[1]);

    // With this seed the order is not the order they were started in, so
    // the test above compared something.
    const started_order = [8]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try testing.expect(!std.mem.eql(u8, &orders[0], &started_order));
}

test "simulated: a power loss keeps durable data and may lose the rest" {
    // Over many seeds, unsynced data is sometimes kept and sometimes lost,
    // and durable data is always kept.
    var kept: u32 = 0;
    var lost: u32 = 0;
    var seed: u64 = 0;
    while (seed < 40) : (seed += 1) {
        var storage: Simulated = .init(testing.allocator, .{ .seed = seed });
        defer storage.deinit();
        const file = try storage.createFile("data", simulated_buffered);
        try storage.syncDir();
        try SimulatedBlocking.writeAll(&storage, file, "durable!", 0, .durable);
        try SimulatedBlocking.writeAll(&storage, file, "unsynced", 8, .unsynced);

        storage.crash(.power_loss);
        storage.restart();

        const after = storage.contents("data");
        try testing.expect(after.len >= 8);
        try testing.expectEqualStrings("durable!", after[0..8]);
        if (after.len == 16) {
            try testing.expectEqualStrings("unsynced", after[8..16]);
            kept += 1;
        } else {
            try testing.expectEqual(@as(usize, 8), after.len);
            lost += 1;
        }
    }
    try testing.expect(kept > 0);
    try testing.expect(lost > 0);
}

test "simulated: a sync makes what was written before it durable" {
    var seed: u64 = 0;
    while (seed < 20) : (seed += 1) {
        var storage: Simulated = .init(testing.allocator, .{ .seed = seed });
        defer storage.deinit();
        const file = try storage.createFile("data", simulated_buffered);
        try storage.syncDir();
        try SimulatedBlocking.writeAll(&storage, file, "first", 0, .unsynced);
        try SimulatedBlocking.syncFile(&storage, file);

        storage.crash(.power_loss);
        storage.restart();
        try expectContents(&storage, "data", "first");
    }
}

test "simulated: a process kill keeps what was written, durable or not" {
    var storage: Simulated = .init(testing.allocator, .{ .seed = 3 });
    defer storage.deinit();
    const file = try storage.createFile("data", simulated_buffered);
    try SimulatedBlocking.writeAll(&storage, file, "in the cache", 0, .unsynced);

    storage.crash(.process_kill);
    storage.restart();
    try expectContents(&storage, "data", "in the cache");
}

test "simulated: a name that was not synced can be lost with the power" {
    var created_kept: u32 = 0;
    var created_lost: u32 = 0;
    var seed: u64 = 0;
    while (seed < 40) : (seed += 1) {
        var storage: Simulated = .init(testing.allocator, .{ .seed = seed });
        defer storage.deinit();

        const old = try storage.createFile("old", simulated_buffered);
        storage.closeFile(old);
        try storage.syncDir();

        // Neither of these is synced.
        try storage.deleteFile("old");
        const new = try storage.createFile("new", simulated_buffered);
        storage.closeFile(new);

        storage.crash(.power_loss);
        storage.restart();

        // Either both changes happened or neither did.
        if (storage.exists("new")) {
            try testing.expect(!storage.exists("old"));
            created_kept += 1;
        } else {
            try testing.expect(storage.exists("old"));
            created_lost += 1;
        }
    }
    try testing.expect(created_kept > 0);
    try testing.expect(created_lost > 0);
}

test "simulated: a crash tears a write that is in flight, sector by sector" {
    // A three-sector write is caught in flight. Over many seeds every
    // sector is seen both landed and not landed.
    var landed: [3]u32 = @splat(0);
    var missing: [3]u32 = @splat(0);
    var seed: u64 = 0;
    while (seed < 60) : (seed += 1) {
        var storage: Simulated = .init(testing.allocator, .{ .seed = seed });
        defer storage.deinit();
        const file = try storage.createFile("data", .{ .direct = true });

        var old: [3 * sector_size]u8 align(sector_size) = undefined;
        @memset(&old, 'o');
        try SimulatedBlocking.writeAll(&storage, file, &old, 0, .durable);

        var new: [3 * sector_size]u8 align(sector_size) = undefined;
        @memset(&new, 'n');

        // The next operation started is the write, and the crash catches
        // it in flight.
        storage.crashAfterOperations(1, .process_kill);
        try testing.expectError(
            error.InputOutput,
            SimulatedBlocking.writeAll(&storage, file, &new, 0, .durable),
        );
        storage.restart();

        const after = storage.contents("data");
        try testing.expectEqual(@as(usize, 3 * sector_size), after.len);
        for (0..3) |sector| {
            const bytes = after[sector * sector_size ..][0..sector_size];
            // A sector is all old or all new, never a mix.
            const is_new = std.mem.allEqual(u8, bytes, 'n');
            const is_old = std.mem.allEqual(u8, bytes, 'o');
            try testing.expect(is_new or is_old);
            if (is_new) {
                landed[sector] += 1;
            } else {
                missing[sector] += 1;
            }
        }
    }
    for (landed, missing) |landed_count, missing_count| {
        try testing.expect(landed_count > 0);
        try testing.expect(missing_count > 0);
    }
}

test "simulated: after a crash every operation fails until the restart" {
    var storage: Simulated = .init(testing.allocator, .{ .seed = 1 });
    defer storage.deinit();
    const file = try storage.createFile("data", simulated_buffered);
    try SimulatedBlocking.writeAll(&storage, file, "before", 0, .durable);

    storage.crash(.process_kill);
    var buffer: [6]u8 = undefined;
    try testing.expectError(error.InputOutput, SimulatedBlocking.readAll(&storage, file, &buffer, 0));
    try testing.expectError(error.InputOutput, SimulatedBlocking.writeAll(&storage, file, "after!", 0, .durable));
    try testing.expectError(error.InputOutput, SimulatedBlocking.syncFile(&storage, file));
    try testing.expectError(error.InputOutput, storage.createFile("other", simulated_buffered));
    try testing.expectError(error.InputOutput, storage.syncDir());

    storage.restart();
    try testing.expectEqual(@as(usize, 6), try SimulatedBlocking.readAll(&storage, file, &buffer, 0));
    try testing.expectEqualStrings("before", &buffer);
}

test "simulated: a durable write is not undone by an older sync that ends later" {
    // A sync is started, then a durable write. Whichever ends first, the
    // durable write's data must survive a power loss.
    var seed: u64 = 0;
    while (seed < 40) : (seed += 1) {
        var storage: Simulated = .init(testing.allocator, .{ .seed = seed, .latency_ticks_max = 8 });
        defer storage.deinit();
        const file = try storage.createFile("data", simulated_buffered);
        try storage.syncDir();
        try SimulatedBlocking.writeAll(&storage, file, "old", 0, .durable);

        const State = struct {
            sync: Simulated.Sync = .{},
            write: Simulated.Write = .{},
            ended: u8 = 0,

            var current: ?*@This() = null;

            fn onSync(_: *Simulated.Sync) void {
                current.?.ended += 1;
            }
            fn onWrite(_: *Simulated.Write) void {
                current.?.ended += 1;
            }
        };
        var state: State = .{};
        State.current = &state;
        defer State.current = null;

        storage.sync(&state.sync, State.onSync, file);
        storage.write(&state.write, State.onWrite, file, "new", 0, .durable);
        while (state.ended < 2) {
            storage.wait(0);
        }

        storage.crash(.power_loss);
        storage.restart();
        try expectContents(&storage, "data", "new");
    }
}

fn checkListing(comptime Storage: type, storage: *Storage) !void {
    const names = [_][]const u8{ "one", "two", "three" };
    for (names) |name| {
        const file = try storage.createFile(name, .{ .direct = false });
        storage.closeFile(file);
    }
    try storage.deleteFile("two");

    var seen_one = false;
    var seen_three = false;
    var listing = try storage.list();
    defer listing.close();
    while (try listing.next()) |name| {
        try testing.expect(!std.mem.eql(u8, name, "two"));
        if (std.mem.eql(u8, name, "one")) {
            seen_one = true;
        }
        if (std.mem.eql(u8, name, "three")) {
            seen_three = true;
        }
    }
    try testing.expect(seen_one);
    try testing.expect(seen_three);
}

test "a listing names the files that exist" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try checkListing(Fixture.Storage, &fixture.storage);
    }
}

fn checkTruncate(comptime Storage: type, storage: *Storage) !void {
    const Blocking = BlockingType(Storage);
    const file = try storage.createFile("cut", .{ .direct = false });
    defer storage.closeFile(file);
    try Blocking.writeAll(storage, file, "keep this, drop this", 0, .durable);
    try storage.truncate(file, 9);
    try Blocking.syncFile(storage, file);
    try testing.expectEqual(@as(u64, 9), try storage.fileSize(file));

    var buffer: [20]u8 = undefined;
    const len = try Blocking.readAll(storage, file, &buffer, 0);
    try testing.expectEqualStrings("keep this", buffer[0..len]);
}

test "a file can be cut down" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try checkTruncate(Fixture.Storage, &fixture.storage);
    }
}

fn checkLock(comptime Storage: type, storage: *Storage) !void {
    try storage.lock();
    storage.unlock();
    // It can be taken again once it has been given up.
    try storage.lock();
    storage.unlock();
}

test "the directory's lock can be taken and given up" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        try checkLock(Fixture.Storage, &fixture.storage);
    }
}

test "real: a second storage on the same directory cannot take the lock" {
    var fixture: RealFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var other: real.Storage = .init(&fixture.io, testing.io, fixture.tmp.dir);
    defer other.deinit();

    try fixture.storage.lock();
    try testing.expectError(error.AlreadyLocked, other.lock());
    fixture.storage.unlock();
    try other.lock();
    other.unlock();
}

test "simulated: the lock is held once, and a crash releases it" {
    var storage: Simulated = .init(testing.allocator, .{});
    defer storage.deinit();
    try storage.lock();
    try testing.expectError(error.AlreadyLocked, storage.lock());
    storage.crash(.process_kill);
    storage.restart();
    try storage.lock();
    storage.unlock();
}
