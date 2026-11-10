//! Benchmarks for the memtable. Run with `zig build bench`.
//!
//! Each workload runs several times against a 64 MiB table filled with
//! 16-byte keys and 100-byte values, and the fastest run is reported. The
//! timings include generating each key, which costs a few nanoseconds.

const std = @import("std");
const MemTable = @import("memtable.zig").MemTable;

const buffer_size = 64 * 1024 * 1024;
const key_size = 16;
const value_size = 100;
const rounds = 5;

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
            const start = std.Io.Timestamp.now(io, .awake);
            const checksum = run(workload, &table, entry_count);
            const stop = std.Io.Timestamp.now(io, .awake);
            std.mem.doNotOptimizeAway(checksum);

            const elapsed_ns: u64 = @intCast(start.durationTo(stop).nanoseconds);
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
        table.put(&key, &value) catch |err| {
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
