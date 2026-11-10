//! A write batch: a group of puts and deletes that the store applies as one
//! unit. After a crash either every operation of a batch is present or none
//! is.
//!
//! A batch is a fixed buffer that operations are appended to. The bytes in
//! the buffer are the batch's encoding. The store writes them to the log as
//! the payload of one record, and reads them back from the log when it
//! recovers.
//!
//! Layout, with all integers little-endian:
//!
//!     operation, operation, ...       back to back, in the order added
//!
//!     operation:      kind (u8)               0 = put, 1 = delete
//!                     key length (u16)
//!                     value length (u32)      0 for a delete
//!                     key
//!                     value
//!
//! There is no header for the batch as a whole and no checksum. The log
//! record that carries a batch stores its length and a checksum of it.
//!
//! Operations apply in the order they were added, so a later operation on a
//! key wins over an earlier one.
//!
//! This is where keys and values enter the store, so `put` and `delete`
//! report one that is too long as an error. The modules below this one treat
//! a key or value over the limit as a bug in their caller.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");

/// The longest key a batch accepts.
pub const key_size_max = constants.key_size_max;

/// The longest value a batch accepts.
pub const value_size_max = constants.value_size_max;

/// The size of a batch's buffer: the most bytes of encoded operations one
/// batch holds.
pub const size_max = constants.batch_size_max;

/// The fewest bytes one operation takes: a delete of the empty key.
pub const operation_size_min = operation_header_size;

/// The most operations one batch holds: a full buffer of the smallest
/// operation.
pub const operation_count_max = size_max / operation_size_min;

/// The most bytes one operation takes: a put of the longest key and the
/// longest value.
pub const operation_size_max = operation_header_size + key_size_max + value_size_max;

// The size of the operation header comes from the struct that describes it,
// further down.
const operation_header_size = @sizeOf(OperationHeader);

/// The longest key the encoding can represent. The key length is a u16.
const key_size_format_max = std.math.maxInt(u16);

/// The longest value the encoding can represent. The value length is a u32.
const value_size_format_max = std.math.maxInt(u32);

/// The most operations `WriteBatch.operation_count` can count. It is a u32.
const operation_count_field_max = std.math.maxInt(u32);

comptime {
    // The header is written to the buffer exactly as it is in memory, and
    // the encoding is little-endian.
    assert(builtin.cpu.arch.endian() == .little);

    // This size is part of the encoding. A change to the struct that makes
    // this fail has changed the encoding.
    assert(operation_header_size == 7);

    assert(key_size_max <= key_size_format_max);
    assert(value_size_max <= value_size_format_max);

    // A batch can hold the largest operation.
    assert(size_max >= operation_size_max);

    // The count of operations in a full batch fits in its field.
    assert(operation_count_max <= operation_count_field_max);
}

/// What an operation does.
const OperationKind = enum(u8) {
    put = 0,
    delete = 1,
    /// Any other number. Bytes that are not a batch can hold one.
    _,
};

/// The first bytes of every operation, as they are in the buffer. The key
/// follows, then the value.
///
/// The fields are marked `align(1)` so that the struct has no padding.
const OperationHeader = extern struct {
    kind: OperationKind,
    key_len: u16 align(1),
    /// Zero for a delete.
    value_len: u32 align(1),

    fn fromBytes(bytes: *const [operation_header_size]u8) OperationHeader {
        return std.mem.bytesToValue(OperationHeader, bytes);
    }

    fn toBytes(header: *const OperationHeader) *const [operation_header_size]u8 {
        return std.mem.asBytes(header);
    }
};

/// One operation of a batch. The slices point into the batch's bytes.
pub const Operation = union(enum) {
    put: struct { key: []const u8, value: []const u8 },
    delete: struct { key: []const u8 },
};

/// A group of puts and deletes to apply together.
pub const WriteBatch = struct {
    /// Holds the encoded operations. Always `size_max` bytes long.
    buffer: []u8,
    /// How many bytes of `buffer` are in use.
    len: usize,
    /// How many operations have been added.
    operation_count: u32,

    pub const Error = error{
        /// The key is longer than `key_size_max`.
        KeyTooLarge,
        /// The value is longer than `value_size_max`.
        ValueTooLarge,
        /// The batch has no room left for this operation.
        BatchFull,
    };

    /// Allocates the batch's buffer. `gpa` is not retained, and no other
    /// method allocates.
    pub fn init(gpa: Allocator) Allocator.Error!WriteBatch {
        const buffer = try gpa.alloc(u8, size_max);
        return .{
            .buffer = buffer,
            .len = 0,
            .operation_count = 0,
        };
    }

    /// `gpa` must be the allocator passed to `init`.
    pub fn deinit(self: *WriteBatch, gpa: Allocator) void {
        gpa.free(self.buffer);
        self.* = undefined;
    }

    /// Removes every operation, so that the batch can be used again.
    pub fn clear(self: *WriteBatch) void {
        self.len = 0;
        self.operation_count = 0;
    }

    /// Adds an operation that sets `key` to `value`. If this fails, the
    /// batch is left as it was.
    pub fn put(self: *WriteBatch, key: []const u8, value: []const u8) Error!void {
        if (key.len > key_size_max) {
            return error.KeyTooLarge;
        }
        if (value.len > value_size_max) {
            return error.ValueTooLarge;
        }
        try self.append(.put, key, value);
    }

    /// Adds an operation that deletes `key`, whether or not the key is
    /// present. If this fails, the batch is left as it was.
    pub fn delete(self: *WriteBatch, key: []const u8) Error!void {
        if (key.len > key_size_max) {
            return error.KeyTooLarge;
        }
        try self.append(.delete, key, "");
    }

    /// How many operations the batch holds.
    pub fn count(self: *const WriteBatch) u32 {
        return self.operation_count;
    }

    /// The encoded operations. This is what the store writes to the log. The
    /// slice is valid until the batch is next changed.
    pub fn bytes(self: *const WriteBatch) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Returns a cursor over the batch's operations, in the order they were
    /// added. The cursor is valid until the batch is next changed.
    pub fn iterator(self: *const WriteBatch) Iterator {
        return .init(self.bytes());
    }

    /// Writes one operation after those already in the buffer. The key and
    /// value must be within their limits.
    fn append(
        self: *WriteBatch,
        kind: OperationKind,
        key: []const u8,
        value: []const u8,
    ) error{BatchFull}!void {
        const operation_size = operation_header_size + key.len + value.len;
        const bytes_free = self.buffer.len - self.len;
        if (operation_size > bytes_free) {
            return error.BatchFull;
        }

        const header: OperationHeader = .{
            .kind = kind,
            .key_len = @intCast(key.len),
            .value_len = @intCast(value.len),
        };
        const key_start = self.len + operation_header_size;
        const value_start = key_start + key.len;
        const value_end = value_start + value.len;

        @memcpy(self.buffer[self.len..key_start], header.toBytes());
        @memcpy(self.buffer[key_start..value_start], key);
        @memcpy(self.buffer[value_start..value_end], value);

        self.len = value_end;
        self.operation_count += 1;
    }
};

/// Checks that `bytes` are the encoding of a batch that `WriteBatch` could
/// have produced and the store could have written: at least one operation,
/// each one whole, with a kind the encoding defines and a key and value
/// within their limits, and no more than `size_max` bytes in all.
///
/// Bytes read from the log are checked with this before they are used.
pub fn validate(bytes: []const u8) error{InvalidBatch}!void {
    // The store never writes an empty batch.
    if (bytes.len == 0) {
        return error.InvalidBatch;
    }
    if (bytes.len > size_max) {
        return error.InvalidBatch;
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        const decoded = try decodeOperation(bytes[offset..]);
        offset += decoded.size;
    }
}

/// A forward-only cursor over the operations of a batch.
pub const Iterator = struct {
    /// The operations not yet returned.
    bytes_left: []const u8,

    /// `valid_bytes` must come from a `WriteBatch`, or have passed
    /// `validate`.
    pub fn init(valid_bytes: []const u8) Iterator {
        return .{ .bytes_left = valid_bytes };
    }

    /// Returns the next operation, or `null` after the last one.
    pub fn next(self: *Iterator) ?Operation {
        if (self.bytes_left.len == 0) {
            return null;
        }

        // The bytes are valid, so decoding cannot fail.
        const decoded = decodeOperation(self.bytes_left) catch unreachable;
        self.bytes_left = self.bytes_left[decoded.size..];
        return decoded.operation;
    }
};

/// An operation read from the front of some bytes, and how many bytes it
/// took.
const Decoded = struct {
    operation: Operation,
    size: usize,
};

/// Reads the operation at the front of `bytes`. Fails if the bytes do not
/// start with a whole operation that `WriteBatch` could have produced.
fn decodeOperation(bytes: []const u8) error{InvalidBatch}!Decoded {
    if (bytes.len < operation_header_size) {
        return error.InvalidBatch;
    }
    const header = OperationHeader.fromBytes(bytes[0..operation_header_size]);
    const key_len: usize = header.key_len;
    const value_len: usize = header.value_len;

    if (header.kind == .delete and value_len != 0) {
        return error.InvalidBatch;
    }
    if (key_len > key_size_max) {
        return error.InvalidBatch;
    }
    if (value_len > value_size_max) {
        return error.InvalidBatch;
    }

    const size = operation_header_size + key_len + value_len;
    if (size > bytes.len) {
        return error.InvalidBatch;
    }
    const key_start = operation_header_size;
    const value_start = key_start + key_len;
    const key = bytes[key_start..value_start];
    const value = bytes[value_start..size];

    // Every kind is named here, so a kind added to `OperationKind` does not
    // compile until it is handled.
    switch (header.kind) {
        .put => {
            return .{ .operation = .{ .put = .{ .key = key, .value = value } }, .size = size };
        },
        .delete => {
            return .{ .operation = .{ .delete = .{ .key = key } }, .size = size };
        },
        _ => {
            return error.InvalidBatch;
        },
    }
}

const testing = std.testing;

fn expectPut(operation: ?Operation, key: []const u8, value: []const u8) !void {
    try testing.expect(operation != null);
    try testing.expect(operation.? == .put);
    try testing.expectEqualSlices(u8, key, operation.?.put.key);
    try testing.expectEqualSlices(u8, value, operation.?.put.value);
}

fn expectDelete(operation: ?Operation, key: []const u8) !void {
    try testing.expect(operation != null);
    try testing.expect(operation.? == .delete);
    try testing.expectEqualSlices(u8, key, operation.?.delete.key);
}

test "a new batch is empty" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), batch.count());
    try testing.expectEqual(@as(usize, 0), batch.bytes().len);

    var it = batch.iterator();
    try testing.expect(it.next() == null);
}

test "operations are read back in the order they were added" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    try batch.put("b", "2");
    try batch.delete("a");
    try batch.put("c", "3");
    try testing.expectEqual(@as(u32, 3), batch.count());

    var it = batch.iterator();
    try expectPut(it.next(), "b", "2");
    try expectDelete(it.next(), "a");
    try expectPut(it.next(), "c", "3");
    try testing.expect(it.next() == null);
    try testing.expect(it.next() == null);
}

test "the encoding of a small batch, byte for byte" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    try batch.put("k", "v");
    try batch.delete("d");

    const expected = [_]u8{
        0, 1, 0, 1, 0, 0, 0, 'k', 'v', // a put: key length 1, value length 1
        1, 1, 0, 0, 0, 0, 0, 'd', // a delete: key length 1, value length 0
    };
    try testing.expectEqualSlices(u8, &expected, batch.bytes());
}

test "two operations on one key are both kept, in order" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    try batch.put("a", "old");
    try batch.delete("a");
    try batch.put("a", "new");

    var it = batch.iterator();
    try expectPut(it.next(), "a", "old");
    try expectDelete(it.next(), "a");
    try expectPut(it.next(), "a", "new");
    try testing.expect(it.next() == null);
}

test "the empty key and an empty value are operations" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    try batch.put("", "");
    try batch.delete("");
    try testing.expectEqual(@as(u32, 2), batch.count());
    try testing.expectEqual(@as(usize, 2 * operation_size_min), batch.bytes().len);

    var it = batch.iterator();
    try expectPut(it.next(), "", "");
    try expectDelete(it.next(), "");
    try testing.expect(it.next() == null);
}

test "clear empties the batch for reuse" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    try batch.put("a", "1");
    try batch.put("b", "2");
    batch.clear();
    try testing.expectEqual(@as(u32, 0), batch.count());
    try testing.expectEqual(@as(usize, 0), batch.bytes().len);

    try batch.put("c", "3");
    var it = batch.iterator();
    try expectPut(it.next(), "c", "3");
    try testing.expect(it.next() == null);
}

test "a key or value of exactly the longest size is accepted" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    const key: [key_size_max]u8 = @splat('k');
    const value = try testing.allocator.alloc(u8, value_size_max);
    defer testing.allocator.free(value);
    @memset(value, 'v');

    try batch.put(&key, value);
    try testing.expectEqual(@as(usize, operation_size_max), batch.bytes().len);

    var it = batch.iterator();
    try expectPut(it.next(), &key, value);
    try testing.expect(it.next() == null);
    try validate(batch.bytes());

    // A delete has its own check of the key.
    batch.clear();
    try batch.delete(&key);

    it = batch.iterator();
    try expectDelete(it.next(), &key);
    try testing.expect(it.next() == null);
    try validate(batch.bytes());
}

test "a key or value over the limit is rejected and the batch is unchanged" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    const long_key: [key_size_max + 1]u8 = @splat('k');
    const long_value = try testing.allocator.alloc(u8, value_size_max + 1);
    defer testing.allocator.free(long_value);
    @memset(long_value, 'v');

    try batch.put("a", "1");
    try testing.expectError(error.KeyTooLarge, batch.put(&long_key, "1"));
    try testing.expectError(error.KeyTooLarge, batch.delete(&long_key));
    try testing.expectError(error.ValueTooLarge, batch.put("b", long_value));

    try testing.expectEqual(@as(u32, 1), batch.count());
    var it = batch.iterator();
    try expectPut(it.next(), "a", "1");
    try testing.expect(it.next() == null);
}

test "a full batch rejects an operation and is unchanged" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    const value = try testing.allocator.alloc(u8, value_size_max);
    defer testing.allocator.free(value);
    @memset(value, 'v');

    // Fill the buffer with large puts until one does not fit.
    var puts: u32 = 0;
    while (true) {
        batch.put("key", value) catch |err| {
            try testing.expectEqual(error.BatchFull, err);
            break;
        };
        puts += 1;
    }
    try testing.expect(puts > 0);
    try testing.expectEqual(puts, batch.count());

    // The value that would fill what is left exactly.
    const bytes_free = size_max - batch.bytes().len;
    const last_key = "last";
    const last_value_len = bytes_free - operation_header_size - last_key.len;

    // One byte more than that does not fit.
    const long_value_len = last_value_len + 1;
    try testing.expectError(error.BatchFull, batch.put(last_key, value[0..long_value_len]));
    try testing.expectEqual(puts, batch.count());

    // Fill what is left except for the size of the smallest operation.
    const short_value_len = last_value_len - operation_size_min;
    try batch.put(last_key, value[0..short_value_len]);
    try testing.expectEqual(@as(usize, size_max - operation_size_min), batch.bytes().len);

    // A header fits in what is left, and nothing more. One byte of key or
    // value is one byte too many.
    try testing.expectError(error.BatchFull, batch.delete("k"));
    try testing.expectError(error.BatchFull, batch.put("k", ""));
    try testing.expectError(error.BatchFull, batch.put("", "v"));
    try testing.expectEqual(puts + 1, batch.count());

    // The smallest operation fills the batch exactly.
    try batch.delete("");
    try testing.expectEqual(@as(usize, size_max), batch.bytes().len);

    // Not even the smallest operation fits now.
    try testing.expectError(error.BatchFull, batch.delete(""));
    try testing.expectError(error.BatchFull, batch.put("", ""));
    try testing.expectEqual(puts + 2, batch.count());
    try testing.expectEqual(@as(usize, size_max), batch.bytes().len);
    try validate(batch.bytes());
}

test "validate accepts what a batch produced" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    try batch.put("a", "1");
    try batch.delete("b");
    try batch.put("", "");
    try validate(batch.bytes());
}

test "validate rejects an empty batch" {
    try testing.expectError(error.InvalidBatch, validate(""));
}

test "validate rejects bytes that stop partway through an operation" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    try batch.put("key", "value");
    try batch.delete("gone");
    const whole = batch.bytes();

    // The only lengths that end on the boundary of an operation.
    const first_operation_len = operation_header_size + "key".len + "value".len;
    for (1..whole.len) |len| {
        const result = validate(whole[0..len]);
        if (len == first_operation_len) {
            try result;
        } else {
            try testing.expectError(error.InvalidBatch, result);
        }
    }
    try validate(whole);
}

test "validate rejects an operation of a kind the encoding does not define" {
    // A whole operation with key length 1 and value length 0, which is valid
    // as a put and as a delete. The kind is filled in below.
    var bytes = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 'a' };

    for (0..256) |kind| {
        bytes[0] = @intCast(kind);
        const result = validate(&bytes);

        const kind_is_put = kind == @backingInt(OperationKind.put);
        const kind_is_delete = kind == @backingInt(OperationKind.delete);
        if (kind_is_put or kind_is_delete) {
            try result;
        } else {
            try testing.expectError(error.InvalidBatch, result);
        }
    }
}

test "validate rejects a delete that has a value" {
    const bytes = [_]u8{
        1, 1, 0, 1, 0, 0, 0, 'a', 'v', // a delete: key length 1, value length 1
    };
    try testing.expectError(error.InvalidBatch, validate(&bytes));
}

test "validate rejects a key or value over the limit" {
    const bytes = try testing.allocator.alloc(u8, size_max);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'x');

    // A put whose key is one byte too long, with every byte it claims.
    const long_key_header: OperationHeader = .{
        .kind = .put,
        .key_len = key_size_max + 1,
        .value_len = 0,
    };
    const long_key_size = operation_header_size + key_size_max + 1;
    @memcpy(bytes[0..operation_header_size], long_key_header.toBytes());
    try testing.expectError(error.InvalidBatch, validate(bytes[0..long_key_size]));

    // The same with a key of exactly the longest size is accepted.
    const longest_key_header: OperationHeader = .{
        .kind = .put,
        .key_len = key_size_max,
        .value_len = 0,
    };
    @memcpy(bytes[0..operation_header_size], longest_key_header.toBytes());
    try validate(bytes[0 .. long_key_size - 1]);

    // A put whose value is one byte too long, with every byte it claims.
    const long_value_header: OperationHeader = .{
        .kind = .put,
        .key_len = 0,
        .value_len = value_size_max + 1,
    };
    const long_value_size = operation_header_size + value_size_max + 1;
    @memcpy(bytes[0..operation_header_size], long_value_header.toBytes());
    try testing.expectError(error.InvalidBatch, validate(bytes[0..long_value_size]));
}

/// Fills `bytes` exactly with valid deletes: deletes of the empty key, then
/// one last delete whose key takes the bytes that are left over.
fn fillWithDeletes(bytes: []u8) void {
    assert(bytes.len >= operation_size_min);
    const last_key_len = bytes.len % operation_size_min;
    const last_start = bytes.len - operation_header_size - last_key_len;

    const empty_key_header: OperationHeader = .{ .kind = .delete, .key_len = 0, .value_len = 0 };
    var offset: usize = 0;
    while (offset < last_start) {
        @memcpy(bytes[offset..][0..operation_header_size], empty_key_header.toBytes());
        offset += operation_size_min;
    }
    assert(offset == last_start);

    const last_header: OperationHeader = .{
        .kind = .delete,
        .key_len = @intCast(last_key_len),
        .value_len = 0,
    };
    @memcpy(bytes[last_start..][0..operation_header_size], last_header.toBytes());
    @memset(bytes[last_start + operation_header_size ..], 'k');
}

test "validate rejects more bytes than a batch can hold" {
    const bytes = try testing.allocator.alloc(u8, size_max + 1);
    defer testing.allocator.free(bytes);

    // Whole, valid operations that take exactly as many bytes as a batch
    // holds are accepted.
    fillWithDeletes(bytes[0..size_max]);
    try validate(bytes[0..size_max]);

    // Whole, valid operations that take one byte more are rejected.
    fillWithDeletes(bytes);
    try testing.expectError(error.InvalidBatch, validate(bytes));
}

test "random batches read back what was added" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    var prng: std.Random.DefaultPrng = .init(11);
    const random = prng.random();

    for (0..20) |_| {
        batch.clear();
        var model: std.ArrayList(Operation) = .empty;

        const operation_count = random.uintAtMost(usize, 200);
        for (0..operation_count) |_| {
            const key = try arena.alloc(u8, random.uintAtMost(usize, 40));
            random.bytes(key);

            if (random.uintLessThan(u8, 4) == 0) {
                try batch.delete(key);
                try model.append(arena, .{ .delete = .{ .key = key } });
            } else {
                const value = try arena.alloc(u8, random.uintAtMost(usize, 300));
                random.bytes(value);
                try batch.put(key, value);
                try model.append(arena, .{ .put = .{ .key = key, .value = value } });
            }
        }

        try testing.expectEqual(@as(u32, @intCast(model.items.len)), batch.count());
        if (model.items.len > 0) {
            try validate(batch.bytes());
        }

        var it = batch.iterator();
        for (model.items) |expected| {
            switch (expected) {
                .put => |put| try expectPut(it.next(), put.key, put.value),
                .delete => |delete| try expectDelete(it.next(), delete.key),
            }
        }
        try testing.expect(it.next() == null);
    }
}
