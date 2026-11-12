//! Benchmarks for the memtable and the write-ahead log. Run with
//! `zig build bench`.
//!
//! Memtable: each workload runs several times against a table of the store's
//! memtable size, filled with 16-byte keys and 100-byte values, and the
//! fastest run is reported.
//! The timings include generating each key, which costs a few nanoseconds.
//!
//! Log: appends records of several sizes to a real file under `.zig-cache`,
//! then replays each file. Append times are mostly the cost of a sync on the
//! disk that holds this directory. Replay reads a file that was just
//! written, so it comes from the operating system's cache and measures the
//! reader's own work, not the disk.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const MemTable = @import("memtable.zig").MemTable;
const checksum = @import("checksum.zig");
const wal = @import("wal.zig");

/// The memtable is benchmarked at the size the store gives it.
const buffer_size = MemTable.buffer_size_max;
const key_size = 16;
const value_size = 100;
const rounds = 5;

comptime {
    // The table asserts these, and the bench is built without run-time checks.
    std.debug.assert(key_size <= MemTable.key_size_max);
    std.debug.assert(value_size <= MemTable.value_size_max);
    // One entry fits in an empty table, so `put` cannot return `TooLarge`.
    std.debug.assert(buffer_size >= MemTable.buffer_size_min + MemTable.entry_overhead_min + key_size + value_size);
}

const KeyOrder = enum { sequential, random };

const Workload = enum {
    put_sequential,
    put_random,
    get_hit,
    get_miss,
    seek,
    scan,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.page_allocator;

    try benchMemtable(io, gpa);
    std.debug.print("\n", .{});
    try benchWal(io, gpa);
}

fn benchMemtable(io: Io, gpa: std.mem.Allocator) !void {
    var table: MemTable = try .init(gpa, buffer_size);
    defer table.deinit(gpa);

    // Fill once untimed so every page of the buffer is mapped before timing.
    const entry_count = fill(&table, .random);

    std.debug.print("buffer {d} MiB, key {d} B, value {d} B, {d} entries per table\n\n", .{
        buffer_size / (1024 * 1024),
        key_size,
        value_size,
        entry_count,
    });
    std.debug.print("{s:<24} {s:>10} {s:>12}\n", .{ "workload", "ns/op", "M ops/s" });

    // The put workloads come first and leave the table filled in random
    // order, which is what the read workloads then run against.
    const workloads = [_]Workload{
        .put_sequential,
        .put_random,
        .get_hit,
        .get_miss,
        .seek,
        .scan,
    };
    for (workloads) |workload| {
        var best_ns: u64 = std.math.maxInt(u64);
        var round: usize = 0;
        while (round < rounds) {
            const start_ns = nowNs(io);
            const result = run(workload, &table, entry_count);
            const elapsed_ns = nowNs(io) - start_ns;
            std.mem.doNotOptimizeAway(result);

            if (elapsed_ns < best_ns) {
                best_ns = elapsed_ns;
            }
            round += 1;
        }

        const ns_per_op = @as(f64, @floatFromInt(best_ns)) / @as(f64, @floatFromInt(entry_count));
        const million_ops_per_second = 1000.0 / ns_per_op;
        std.debug.print("{s:<24} {d:>10.1} {d:>12.2}\n", .{
            @tagName(workload),
            ns_per_op,
            million_ops_per_second,
        });
    }
}

/// Runs one workload of `entry_count` operations and returns a value that
/// depends on its results, so the compiler can't remove the work.
fn run(workload: Workload, table: *MemTable, entry_count: u64) u64 {
    switch (workload) {
        .put_sequential => {
            table.reset();
            return fill(table, .sequential);
        },
        .put_random => {
            table.reset();
            return fill(table, .random);
        },
        .get_hit => return getMany(table, entry_count, 0, entry_count),
        // Indexes past `entry_count` were never inserted, and their keys
        // are spread across the whole key range.
        .get_miss => return getMany(table, entry_count, entry_count, entry_count),
        .seek => return seekMany(table, entry_count),
        .scan => return scan(table),
    }
}

/// Inserts entries until the table is full. Returns how many were inserted.
fn fill(table: *MemTable, order: KeyOrder) u64 {
    const value: [value_size]u8 = @splat('v');
    var key: [key_size]u8 = undefined;
    var index: u64 = 0;
    while (true) {
        makeKey(&key, index, order);
        // Each entry is written once, so its index numbers its write.
        const sequence = index + 1;
        table.put(&key, &value, sequence) catch |err| {
            switch (err) {
                error.Full => return index,
                error.TooLarge => unreachable,
            }
        };
        index += 1;
    }
}

/// Looks up `count` keys chosen at random from the `index_count` indexes
/// starting at `index_first`. Returns the number of keys found.
fn getMany(table: *const MemTable, count: u64, index_first: u64, index_count: u64) u64 {
    var key: [key_size]u8 = undefined;
    var found: u64 = 0;
    var i: u64 = 0;
    while (i < count) {
        const index = index_first + scramble(i ^ 0xabcdef) % index_count;
        makeKey(&key, index, .random);
        switch (table.get(&key)) {
            .value => found += 1,
            .tombstone => {},
            .absent => {},
        }
        i += 1;
    }
    return found;
}

/// Seeks to `count` random keys and reads one entry at each.
fn seekMany(table: *const MemTable, count: u64) u64 {
    var key: [key_size]u8 = undefined;
    var it = table.iterator();
    var total_len: u64 = 0;
    var i: u64 = 0;
    while (i < count) {
        makeKey(&key, scramble(i ^ 0x123456), .random);
        it.seek(&key);
        if (it.next()) |entry| {
            total_len += entry.key.len;
        }
        i += 1;
    }
    return total_len;
}

/// Reads every entry in key order.
fn scan(table: *const MemTable) u64 {
    var it = table.iterator();
    var total_len: u64 = 0;
    while (it.next()) |entry| {
        total_len += entry.key.len;
        if (entry.value) |value| {
            total_len += value.len;
        }
    }
    return total_len;
}

/// Writes the key for `index`. Sequential keys sort in index order; random
/// keys are unique but sort in an unrelated order.
fn makeKey(key: *[key_size]u8, index: u64, order: KeyOrder) void {
    const number = switch (order) {
        .sequential => index,
        .random => scramble(index),
    };
    std.mem.writeInt(u64, key[0..8], number, .big);
    @memset(key[8..], 'k');
}

/// The splitmix64 mixing function. It maps each input to a distinct output.
fn scramble(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// A reading of a clock that only moves forwards, in nanoseconds.
fn nowNs(io: Io) u64 {
    return @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
}

const wal_dir_path = ".zig-cache/bench-wal";
const wal_file_name = "bench.wal";
const raw_file_name = "bench.raw";
const wal_payload_size_max = 1024 * 1024;
const wal_appends_max = 1000;

const WalCase = struct {
    payload_size: u32,
    /// How many records to append through the log.
    append_count: u32,
    /// How many writes to time with a full sync. These are slow, so fewer.
    full_sync_count: u32,
};

const wal_cases = [_]WalCase{
    .{ .payload_size = 100, .append_count = 1000, .full_sync_count = 100 },
    .{ .payload_size = 4 * 1024, .append_count = 1000, .full_sync_count = 100 },
    .{ .payload_size = 64 * 1024, .append_count = 300, .full_sync_count = 100 },
    .{ .payload_size = wal_payload_size_max, .append_count = 50, .full_sync_count = 30 },
};

comptime {
    for (wal_cases) |case| {
        // The payload is a prefix of a buffer of `wal_payload_size_max` bytes.
        std.debug.assert(case.payload_size <= wal_payload_size_max);
        // The timings are stored in an array of `wal_appends_max` entries.
        std.debug.assert(case.append_count <= wal_appends_max);
        std.debug.assert(case.full_sync_count <= wal_appends_max);
    }
}

fn benchWal(io: Io, gpa: std.mem.Allocator) !void {
    var dir = try Io.Dir.cwd().createDirPathOpen(io, wal_dir_path, .{});
    defer dir.close(io);

    const payload = try gpa.alloc(u8, wal_payload_size_max);
    defer gpa.free(payload);
    fillWithNoise(payload);

    const read_buffer = try gpa.alloc(u8, wal_payload_size_max);
    defer gpa.free(read_buffer);

    std.debug.print("write-ahead log, files in {s}\n\n", .{wal_dir_path});

    benchChecksum(io, payload);
    std.debug.print("\n", .{});

    std.debug.print("{s:>9} {s:>12} {s:>10} {s:>10} {s:>14} {s:>11} {s:>14}\n", .{
        "payload",
        "append ms",
        "p99 ms",
        "MiB/s",
        "full sync ms",
        "replay MiB/s",
        "replay rec/s",
    });

    for (wal_cases) |case| {
        dir.deleteFile(io, wal_file_name) catch {};
        dir.deleteFile(io, raw_file_name) catch {};

        const case_payload = payload[0..case.payload_size];

        const append = try timeAppends(io, dir, case_payload, case.append_count);
        const replay = try timeReplay(io, dir, read_buffer);
        const full_sync_median_ns = try timeFullSyncWrites(io, dir, case_payload, case.full_sync_count);

        std.debug.assert(replay.record_count == case.append_count);

        const append_ms = nsToMs(append.median_ns);
        const append_p99_ms = nsToMs(append.p99_ns);
        const append_mib_per_s = mibPerSecond(case.payload_size, append.median_ns);
        const replay_mib_per_s = mibPerSecond(replay.payload_bytes, replay.elapsed_ns);
        const replay_records_per_s =
            @as(f64, @floatFromInt(replay.record_count)) * 1e9 /
            @as(f64, @floatFromInt(replay.elapsed_ns));

        std.debug.print("{d:>9} {d:>12.3} {d:>10.3} {d:>10.2} ", .{
            case.payload_size,
            append_ms,
            append_p99_ms,
            append_mib_per_s,
        });
        if (full_sync_median_ns) |ns| {
            std.debug.print("{d:>14.3} ", .{nsToMs(ns)});
        } else {
            std.debug.print("{s:>14} ", .{"n/a"});
        }
        std.debug.print("{d:>11.0} {d:>14.0}\n", .{ replay_mib_per_s, replay_records_per_s });
    }

    dir.deleteFile(io, wal_file_name) catch {};
    dir.deleteFile(io, raw_file_name) catch {};
}

/// Prints how fast the store's checksum runs on its own, next to the
/// standard library's version of the same checksum. Replay is mostly
/// checksum work.
fn benchChecksum(io: Io, bytes: []const u8) void {
    const ours_mib_per_s = timeChecksum(io, bytes, checksum.crc32c);
    const std_mib_per_s = timeChecksum(io, bytes, std.hash.crc.@"CRC-32/ISCSI".hash);

    std.debug.print("CRC-32C: {d:.0} MiB/s (standard library: {d:.0} MiB/s)\n", .{
        ours_mib_per_s,
        std_mib_per_s,
    });
}

/// Returns the speed of `hash` over `bytes` in MiB per second, taking the
/// fastest of several rounds.
fn timeChecksum(io: Io, bytes: []const u8, comptime hash: fn ([]const u8) u32) f64 {
    const passes = 64;

    var best_ns: u64 = std.math.maxInt(u64);
    var round: usize = 0;
    while (round < rounds) {
        const start_ns = nowNs(io);
        var pass: usize = 0;
        while (pass < passes) {
            std.mem.doNotOptimizeAway(hash(bytes));
            pass += 1;
        }
        const elapsed_ns = nowNs(io) - start_ns;
        if (elapsed_ns < best_ns) {
            best_ns = elapsed_ns;
        }
        round += 1;
    }

    return mibPerSecond(bytes.len * passes, best_ns);
}

const AppendTimes = struct {
    median_ns: u64,
    p99_ns: u64,
};

/// Creates a log and appends `count` records of `payload` to it, timing each
/// append. Leaves the log on disk for `timeReplay`.
fn timeAppends(io: Io, dir: Io.Dir, payload: []const u8, count: u32) !AppendTimes {
    std.debug.assert(count <= wal_appends_max);
    var times_ns: [wal_appends_max]u64 = undefined;

    var writer: wal.Writer = try .create(io, dir, wal_file_name, wal_payload_size_max, .none);
    defer writer.close();

    var index: u32 = 0;
    while (index < count) {
        const start_ns = nowNs(io);
        _ = try writer.append(payload);
        times_ns[index] = nowNs(io) - start_ns;
        index += 1;
    }

    const times = times_ns[0..count];
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    return .{
        .median_ns = times[count / 2],
        .p99_ns = times[(count * 99) / 100],
    };
}

const ReplayResult = struct {
    record_count: u64,
    payload_bytes: u64,
    elapsed_ns: u64,
};

/// Reads every record of the log left by `timeAppends`. Reports the fastest
/// of several passes.
fn timeReplay(io: Io, dir: Io.Dir, buffer: []u8) !ReplayResult {
    var best: ReplayResult = .{
        .record_count = 0,
        .payload_bytes = 0,
        .elapsed_ns = std.math.maxInt(u64),
    };

    var round: usize = 0;
    while (round < rounds) {
        var record_count: u64 = 0;
        var payload_bytes: u64 = 0;

        const start_ns = nowNs(io);
        var reader: wal.Reader = try .open(io, dir, wal_file_name, buffer);
        while (try reader.next()) |record| {
            record_count += 1;
            payload_bytes += record.payload.len;
        }
        reader.close();
        const elapsed_ns = nowNs(io) - start_ns;

        if (elapsed_ns < best.elapsed_ns) {
            best = .{
                .record_count = record_count,
                .payload_bytes = payload_bytes,
                .elapsed_ns = elapsed_ns,
            };
        }
        round += 1;
    }
    return best;
}

/// Times writing `payload` to a plain file followed by a full sync, which
/// asks the drive itself to flush. Returns the median, or `null` on systems
/// where an ordinary sync already does that.
///
/// This is how the log syncs on macOS; see `durable.zig`. Timing it on a
/// plain file shows how much of an append's time is the sync.
fn timeFullSyncWrites(io: Io, dir: Io.Dir, payload: []const u8, count: u32) !?u64 {
    if (builtin.os.tag != .macos) {
        return null;
    }
    std.debug.assert(count <= wal_appends_max);
    var times_ns: [wal_appends_max]u64 = undefined;

    const file = try dir.createFile(io, raw_file_name, .{});
    defer file.close(io);

    var offset: u64 = 0;
    var index: u32 = 0;
    while (index < count) {
        const start_ns = nowNs(io);
        try file.writePositionalAll(io, payload, offset);
        const result = std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0));
        if (result == -1) {
            return error.FullSyncFailed;
        }
        times_ns[index] = nowNs(io) - start_ns;

        offset += payload.len;
        index += 1;
    }

    const times = times_ns[0..count];
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    return times[count / 2];
}

/// Fills `bytes` with a fixed pattern that does not compress or repeat.
fn fillWithNoise(bytes: []u8) void {
    var prng: std.Random.DefaultPrng = .init(0xbea9);
    prng.random().bytes(bytes);
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn mibPerSecond(byte_count: u64, elapsed_ns: u64) f64 {
    const mib = @as(f64, @floatFromInt(byte_count)) / (1024.0 * 1024.0);
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    return mib / seconds;
}
