//! A bloom filter: a compact, approximate record of which keys a table
//! holds.
//!
//! A lookup asks the filter before it reads the table. "No" is always
//! right, so the table is skipped without touching its file. "Maybe" is
//! usually right, and the table is read to find out. Most lookups for a key
//! that a table does not hold end at the filter.
//!
//! The filter is an array of bits. Adding a key sets a few of them, at
//! positions worked out from the key's hash. A key may be present only if
//! all of its positions are set. With `bits_per_key` bits for each key and
//! `probe_count` positions for each, about one absent key in a hundred is
//! answered "maybe".
//!
//! The filter never forgets a key and cannot have one taken out, which
//! suits a table: a table never changes once it is written.

const std = @import("std");
const assert = std.debug.assert;

const constants = @import("constants.zig");

/// How many bits a filter has for each key it is sized for.
pub const bits_per_key = constants.filter_bits_per_key;

/// How many bits a key sets. The fewest wrong answers come at about 0.69
/// times the bits for each key.
pub const probe_count = 7;

comptime {
    assert(bits_per_key >= 1);
    // The number of probes that is best for this many bits a key, to the
    // nearest whole number.
    const best: comptime_float = 0.693 * @as(comptime_float, bits_per_key);
    assert(probe_count == @as(comptime_int, @intFromFloat(@round(best))));
}

/// The length in bytes of a filter for `key_count` keys.
pub fn sizeFor(key_count: usize) usize {
    const bits = key_count * bits_per_key;
    const bytes = (bits + 7) / 8;
    // A filter is never empty, so that a position can always be worked out.
    return @max(bytes, 8);
}

/// The hash a filter works from. It is written out here, and not taken from
/// the standard library, so that it never changes under a filter that has
/// been stored: FNV-1a over the bytes, then a mixing step, because FNV on
/// its own leaves the high bits of short keys nearly the same.
pub fn hash(key: []const u8) u64 {
    var state: u64 = 0xcbf29ce484222325;
    for (key) |byte| {
        state ^= byte;
        state *%= 0x100000001b3;
    }
    state ^= state >> 30;
    state *%= 0xbf58476d1ce4e5b9;
    state ^= state >> 27;
    state *%= 0x94d049bb133111eb;
    state ^= state >> 31;
    return state;
}

pub const Filter = struct {
    /// The bits. The caller owns the memory.
    bits: []u8,

    pub fn init(buffer: []u8) Filter {
        assert(buffer.len >= 8);
        return .{ .bits = buffer };
    }

    /// Empties the filter: it then holds no key.
    pub fn clear(self: Filter) void {
        @memset(self.bits, 0);
    }

    /// Adds the key whose hash is `key_hash`.
    pub fn add(self: Filter, key_hash: u64) void {
        var probe: u64 = 0;
        while (probe < probe_count) : (probe += 1) {
            const position = self.bitPosition(key_hash, probe);
            self.bits[position / 8] |= @as(u8, 1) << @intCast(position % 8);
        }
    }

    /// Whether the key whose hash is `key_hash` may have been added. If
    /// this is false, it was not.
    pub fn mayContain(self: Filter, key_hash: u64) bool {
        var probe: u64 = 0;
        while (probe < probe_count) : (probe += 1) {
            const position = self.bitPosition(key_hash, probe);
            const bit = self.bits[position / 8] & (@as(u8, 1) << @intCast(position % 8));
            if (bit == 0) {
                return false;
            }
        }
        return true;
    }

    /// The bit a key's `probe`-th probe lands on. The two halves of the
    /// hash act as two hashes, and each probe is the first plus a multiple
    /// of the second.
    fn bitPosition(self: Filter, key_hash: u64, probe: u64) usize {
        const first: u64 = key_hash & 0xffffffff;
        // Odd, so that the probes do not all land on one bit.
        const second: u64 = (key_hash >> 32) | 1;
        const bit_count: u64 = self.bits.len * 8;
        return @intCast((first + probe * second) % bit_count);
    }
};

const testing = std.testing;

fn testKey(buffer: *[16]u8, number: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "key{d:0>10}", .{number}) catch unreachable;
}

test "a filter says maybe for every key that was added" {
    const key_count = 10_000;
    const buffer = try testing.allocator.alloc(u8, sizeFor(key_count));
    defer testing.allocator.free(buffer);
    const filter: Filter = .init(buffer);
    filter.clear();

    var key_buffer: [16]u8 = undefined;
    var number: u64 = 0;
    while (number < key_count) : (number += 1) {
        filter.add(hash(testKey(&key_buffer, number)));
    }
    number = 0;
    while (number < key_count) : (number += 1) {
        try testing.expect(filter.mayContain(hash(testKey(&key_buffer, number))));
    }
}

test "a filter says no to nearly every key that was not added" {
    const key_count = 10_000;
    const buffer = try testing.allocator.alloc(u8, sizeFor(key_count));
    defer testing.allocator.free(buffer);
    const filter: Filter = .init(buffer);
    filter.clear();

    var key_buffer: [16]u8 = undefined;
    var number: u64 = 0;
    while (number < key_count) : (number += 1) {
        filter.add(hash(testKey(&key_buffer, number)));
    }

    // Keys that were never added. About one in a hundred is expected to be
    // answered "maybe"; three in a hundred would mean something is wrong.
    const absent_count = 100_000;
    var wrong: u64 = 0;
    number = key_count;
    while (number < key_count + absent_count) : (number += 1) {
        if (filter.mayContain(hash(testKey(&key_buffer, number)))) {
            wrong += 1;
        }
    }
    try testing.expect(wrong < absent_count * 3 / 100);
    // And an empty answer for all of them would mean the test asked nothing.
    try testing.expect(wrong > 0);
}

test "an empty filter holds no key" {
    var buffer: [64]u8 = undefined;
    const filter: Filter = .init(&buffer);
    filter.clear();
    var key_buffer: [16]u8 = undefined;
    var number: u64 = 0;
    while (number < 1000) : (number += 1) {
        try testing.expect(!filter.mayContain(hash(testKey(&key_buffer, number))));
    }
}

test "the hash of a key is fixed" {
    // A stored filter is only as good as the hash it was built with. These
    // values were worked out by hand from the definition and must never
    // change.
    try testing.expectEqual(@as(u64, 0xf52a15e9a9b5e89b), hash(""));
    try testing.expectEqual(@as(u64, 0xb544ab6163919a5e), hash("bean"));
}
