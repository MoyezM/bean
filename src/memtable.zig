const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const constants = @import("constants.zig");

/// A fixed-size, in-memory sorted table. All memory is allocated in
/// `init`; no other method allocates.
///
/// Entries are kept in a skiplist whose nodes are carved from one buffer.
/// Every `put` and `delete` links in a new node; nodes are never modified,
/// moved or freed. Slices returned by `get` and by iterators stay valid
/// until `reset` or `deinit`.
///
/// Every write carries a sequence number, which the caller chooses. Nodes
/// are ordered by key, and nodes with equal keys by sequence number, largest
/// first. The entry with the largest sequence number is the newest one for
/// its key, whatever order the writes were made in.
pub const MemTable = struct {
    arena: FixedBufferAllocator,
    /// A node with no key that links to the first node on every level.
    head: *Node,
    prng: std.Random.DefaultPrng,

    /// With a branching factor of 4 this covers about 4^12 entries.
    const max_height = 12;
    const branching = 4;

    /// The longest key the table stores. A longer key is a bug in the caller.
    pub const key_size_max = constants.key_size_max;

    /// The longest value the table stores. A longer value is a bug in the
    /// caller.
    pub const value_size_max = constants.value_size_max;

    /// The most bytes any one entry can take from the table.
    pub const entry_size_max = entrySizeMax(key_size_max, value_size_max);

    /// The fewest bytes an entry takes from the table beyond its key and
    /// value: a node of height one.
    pub const entry_overhead_min = Node.size(1, 0, 0);

    /// The most bytes of padding the arena puts before a node to align it.
    const node_padding_max = @alignOf(Node) - 1;

    /// The largest buffer `init` accepts, and the size the store gives its
    /// memtable. A flushed memtable must fit in one table, so nothing larger
    /// is allowed.
    pub const buffer_size_max = constants.memtable_size;

    /// The longest key a node can represent. `Node.key_len` is a u16.
    const key_size_node_max = std.math.maxInt(u16);

    /// The longest value a node can represent. `Node.value_len` is a u32.
    const value_size_node_max = std.math.maxInt(u32);

    comptime {
        assert(key_size_max <= key_size_node_max);
        assert(value_size_max <= value_size_node_max);

        // An empty table of the largest size has room for the largest entry.
        assert(buffer_size_max >= buffer_size_min + entry_size_max);
    }

    /// The smallest `buffer_size` that `init` accepts. A table this size has
    /// no room for entries.
    pub const buffer_size_min = Node.size(max_height, 0, 0);

    /// One skiplist node. The header is followed in memory by:
    ///
    ///     links[0..height] | key bytes | value bytes
    ///
    /// The methods below are the only code that knows this layout.
    const Node = extern struct {
        /// The sequence number of the write that made this node. It is
        /// first so that the header is pointer-aligned and the links can
        /// follow it directly.
        sequence: u64,
        value_len: u32,
        key_len: u16,
        height: u8,
        tombstone: bool,

        comptime {
            assert(@sizeOf(Node) == 16);
            assert(@alignOf(Node) == @alignOf(?*Node));
        }

        /// Bytes needed for a node, including everything after the header.
        fn size(height: usize, key_len: usize, value_len: usize) usize {
            return @sizeOf(Node) + height * @sizeOf(?*Node) + key_len + value_len;
        }

        /// Writes a node into `bytes`, which must be exactly `size` long.
        fn init(
            bytes: []align(@alignOf(Node)) u8,
            height: u8,
            key_bytes: []const u8,
            value_bytes: ?[]const u8,
            sequence: u64,
        ) *Node {
            const value_len = if (value_bytes) |v| v.len else 0;
            assert(height >= 1 and height <= max_height);
            assert(bytes.len == size(height, key_bytes.len, value_len));

            const node: *Node = @ptrCast(bytes.ptr);
            node.* = .{
                .sequence = sequence,
                .value_len = @intCast(value_len),
                .key_len = @intCast(key_bytes.len),
                .height = height,
                .tombstone = value_bytes == null,
            };
            @memset(node.links(), null);
            @memcpy(bytes[size(height, 0, 0)..][0..key_bytes.len], key_bytes);
            if (value_bytes) |v| @memcpy(bytes[size(height, key_bytes.len, 0)..], v);
            return node;
        }

        /// The next node on each level, or `null` at the end of that level.
        fn links(node: *Node) []?*Node {
            const after_header: [*]Node = @as([*]Node, @ptrCast(node)) + 1;
            const first: [*]?*Node = @ptrCast(after_header);
            return first[0..node.height];
        }

        fn key(node: *Node) []const u8 {
            const after_links: [*]const u8 = @ptrCast(node.links().ptr + node.height);
            return after_links[0..node.key_len];
        }

        /// `null` for a tombstone.
        fn value(node: *Node) ?[]const u8 {
            if (node.tombstone) return null;
            const after_key = node.key().ptr + node.key_len;
            return after_key[0..node.value_len];
        }
    };

    pub const Error = error{
        /// No room left for this entry. Flush the table and retry.
        Full,
        /// The entry could never fit, even in an empty table.
        TooLarge,
    };

    pub const Lookup = union(enum) {
        value: []const u8,
        /// The key was deleted here; older tables must not be consulted.
        tombstone,
        /// This table has no entry for the key.
        absent,
    };

    pub const Entry = struct {
        key: []const u8,
        /// `null` means the entry is a tombstone.
        value: ?[]const u8,
        /// The sequence number of the write that made the entry.
        sequence: u64,
    };

    /// The largest sequence number. A search for a key with this number
    /// lands on the newest entry for the key.
    const sequence_newest = std.math.maxInt(u64);

    /// A forward-only cursor over the newest entry for each key, in key
    /// order, tombstones included. Stays valid across `put` and `delete`;
    /// whether it sees writes made after it was positioned is unspecified.
    pub const Iterator = struct {
        table: *const MemTable,
        node: ?*Node,

        /// Positions the cursor at the first entry.
        pub fn seekToFirst(self: *Iterator) void {
            self.node = self.table.head.links()[0];
        }

        /// Positions the cursor at the first entry whose key is >= `key`.
        pub fn seek(self: *Iterator, key: []const u8) void {
            self.node = self.table.findGreaterOrEqual(key);
        }

        /// Returns the entry at the cursor and advances past it.
        pub fn next(self: *Iterator) ?Entry {
            const node = self.node orelse return null;
            const entry: Entry = .{
                .key = node.key(),
                .value = node.value(),
                .sequence = node.sequence,
            };

            // Skip older entries for the same key.
            self.node = node.links()[0];
            while (self.node) |older| {
                if (!std.mem.eql(u8, older.key(), entry.key)) break;
                self.node = older.links()[0];
            }
            return entry;
        }

        /// Returns the entry at the cursor and advances to the entry right
        /// after it, which may be an older entry for the same key. Calling
        /// only this visits every entry: by key, and for one key from the
        /// newest entry to the oldest.
        pub fn nextVersion(self: *Iterator) ?Entry {
            if (self.node == null) {
                return null;
            }
            const node = self.node.?;
            const entry: Entry = .{
                .key = node.key(),
                .value = node.value(),
                .sequence = node.sequence,
            };
            self.node = node.links()[0];
            return entry;
        }
    };

    /// Allocates `buffer_size` bytes for the table. `gpa` is not retained.
    /// `buffer_size` must be between `buffer_size_min` and `buffer_size_max`.
    pub fn init(gpa: Allocator, buffer_size: usize) Allocator.Error!MemTable {
        assert(buffer_size >= buffer_size_min);
        assert(buffer_size <= buffer_size_max);

        const buffer = try gpa.alignedAlloc(u8, .of(Node), buffer_size);
        var table: MemTable = .{
            .arena = .init(buffer),
            .head = undefined,
            .prng = .init(0),
        };
        table.head = table.createNode(max_height, "", null, 0).?;
        return table;
    }

    /// `gpa` must be the allocator passed to `init`.
    pub fn deinit(self: *MemTable, gpa: Allocator) void {
        const buffer: []align(@alignOf(Node)) u8 = @alignCast(self.arena.buffer);
        gpa.free(buffer);
        self.* = undefined;
    }

    /// Empties the table, keeping its memory. Invalidates all slices and
    /// iterators obtained from it.
    pub fn reset(self: *MemTable) void {
        self.arena.reset();
        self.head = self.createNode(max_height, "", null, 0).?;
    }

    /// Records `value` for `key`, as the write numbered `sequence`.
    ///
    /// No two writes to one key may have the same sequence number. Giving
    /// the same key and number twice is a bug in the caller.
    pub fn put(self: *MemTable, key: []const u8, value: []const u8, sequence: u64) Error!void {
        try self.insert(key, value, sequence);
    }

    /// Records a tombstone for `key`, as the write numbered `sequence`,
    /// whether or not the key is present.
    pub fn delete(self: *MemTable, key: []const u8, sequence: u64) Error!void {
        try self.insert(key, null, sequence);
    }

    /// Looks up the newest entry for `key`: the one with the largest
    /// sequence number.
    pub fn get(self: *const MemTable, key: []const u8) Lookup {
        const node = self.findGreaterOrEqual(key) orelse return .absent;
        if (!std.mem.eql(u8, node.key(), key)) return .absent;
        const value = node.value() orelse return .tombstone;
        return .{ .value = value };
    }

    /// Whether the table holds no entries.
    pub fn isEmpty(self: *const MemTable) bool {
        return self.head.links()[0] == null;
    }

    /// Returns a cursor positioned at the first entry.
    pub fn iterator(self: *const MemTable) Iterator {
        return .{ .table = self, .node = self.head.links()[0] };
    }

    /// The most bytes one entry can take from the table, whatever height its
    /// node is given. If the sum of this over a set of entries is at most
    /// `bytesFree()`, inserting all of them cannot return `Full`.
    pub fn entrySizeMax(key_len: usize, value_len: usize) usize {
        const node_size_max = Node.size(max_height, key_len, value_len);
        return node_size_max + node_padding_max;
    }

    /// Bytes not yet used. An empty table has `buffer_size_min` fewer than
    /// its buffer size.
    pub fn bytesFree(self: *const MemTable) usize {
        return self.arena.buffer.len - self.arena.end_index;
    }

    /// Links in a new node at its place in the order: after every node with
    /// a smaller key, and after the nodes for `key` that have a larger
    /// sequence number. A `null` value inserts a tombstone.
    fn insert(self: *MemTable, key: []const u8, value: ?[]const u8, sequence: u64) Error!void {
        const value_len = if (value) |v| v.len else 0;
        assert(key.len <= key_size_max);
        assert(value_len <= value_size_max);
        if (!self.fitsWhenEmpty(key.len, value_len)) return error.TooLarge;

        const height = self.randomHeight();
        const created = self.createTallestNodeThatFits(height, key, value, sequence);
        if (created == null) {
            return error.Full;
        }
        const node = created.?;

        const preds = self.findPredecessors(key, sequence);

        // The node that will follow the new one must not be the same write.
        if (preds[0].links()[0]) |next| {
            const same_key = std.mem.eql(u8, next.key(), key);
            assert(!(same_key and next.sequence == sequence));
        }

        for (node.links(), 0..) |*link, level| {
            const pred_link = &preds[level].links()[level];
            link.* = pred_link.*;
            pred_link.* = node;
        }
    }

    /// Returns the first node whose key is >= `key`, or `null` if there is
    /// none. Among nodes for one key that is the newest.
    fn findGreaterOrEqual(self: *const MemTable, key: []const u8) ?*Node {
        const preds = self.findPredecessors(key, sequence_newest);
        return preds[0].links()[0];
    }

    /// Returns, for each level, the last node that sorts before the write
    /// to `key` numbered `sequence`. That is the head when no node on the
    /// level sorts before it.
    fn findPredecessors(self: *const MemTable, key: []const u8, sequence: u64) [max_height]*Node {
        var preds: [max_height]*Node = undefined;
        var node = self.head;
        var level: usize = max_height;
        while (level > 0) {
            level -= 1;
            node = lastNodeBefore(node, level, key, sequence);
            preds[level] = node;
        }
        return preds;
    }

    /// Walks right along one level from `start`, and returns the last node
    /// that sorts before the write to `key` numbered `sequence`. Returns
    /// `start` if the next node already does not.
    fn lastNodeBefore(start: *Node, level: usize, key: []const u8, sequence: u64) *Node {
        var node = start;
        while (node.links()[level]) |next| {
            if (!sortsBefore(next, key, sequence)) {
                break;
            }
            node = next;
        }
        return node;
    }

    /// Whether `node` sorts before the write to `key` numbered `sequence`:
    /// its key is smaller, or its key is the same and its sequence number
    /// is larger.
    fn sortsBefore(node: *Node, key: []const u8, sequence: u64) bool {
        const key_order = std.mem.order(u8, node.key(), key);
        if (key_order == .lt) {
            return true;
        }
        if (key_order == .gt) {
            return false;
        }
        return node.sequence > sequence;
    }

    /// Whether an entry of this size fits in a table holding nothing else.
    fn fitsWhenEmpty(self: *const MemTable, key_len: usize, value_len: usize) bool {
        const overhead = buffer_size_min + entry_overhead_min;
        if (self.arena.buffer.len < overhead) return false;
        const room = self.arena.buffer.len - overhead;
        return key_len <= room and value_len <= room - key_len;
    }

    /// Creates a node of `height_max` levels if it fits, and otherwise of the
    /// tallest shorter height that does. A shorter node is still correct.
    /// Returns `null` when not even a one-level node fits.
    fn createTallestNodeThatFits(
        self: *MemTable,
        height_max: u8,
        key: []const u8,
        value: ?[]const u8,
        sequence: u64,
    ) ?*Node {
        var height = height_max;
        while (height > 0) {
            const node = self.createNode(height, key, value, sequence);
            if (node != null) {
                return node;
            }
            height -= 1;
        }
        return null;
    }

    /// Returns `null` if the node doesn't fit in the space left.
    fn createNode(
        self: *MemTable,
        height: u8,
        key: []const u8,
        value: ?[]const u8,
        sequence: u64,
    ) ?*Node {
        const value_len = if (value) |v| v.len else 0;
        const bytes = self.arena.allocator().alignedAlloc(
            u8,
            .of(Node),
            Node.size(height, key.len, value_len),
        ) catch return null;
        return .init(bytes, height, key, value, sequence);
    }

    fn randomHeight(self: *MemTable) u8 {
        const random = self.prng.random();
        var height: u8 = 1;
        while (height < max_height and random.uintLessThan(u8, branching) == 0) height += 1;
        return height;
    }
};

const testing = std.testing;
const test_buffer_size = 64 * 1024;

/// The sequence number of the last write a test made through `put` or
/// `delete` below.
var test_sequence: u64 = 0;

/// Writes with the next sequence number, as the store does.
fn put(table: *MemTable, key: []const u8, value: []const u8) MemTable.Error!void {
    test_sequence += 1;
    try table.put(key, value, test_sequence);
}

/// Deletes with the next sequence number, as the store does.
fn delete(table: *MemTable, key: []const u8) MemTable.Error!void {
    test_sequence += 1;
    try table.delete(key, test_sequence);
}

fn expectValue(table: *const MemTable, key: []const u8, expected: []const u8) !void {
    switch (table.get(key)) {
        .value => |actual| try testing.expectEqualSlices(u8, expected, actual),
        else => return error.TestExpectedValue,
    }
}

/// What a test expects an iterator to return next. The sequence number is
/// left out, because the tests' writes are numbered by a counter.
const ExpectedEntry = struct {
    key: []const u8,
    /// `null` means a tombstone.
    value: ?[]const u8,
};

fn expectEntries(it: *MemTable.Iterator, expected: []const ExpectedEntry) !void {
    for (expected) |entry| {
        const actual = it.next() orelse return error.TestExpectedEntry;
        try testing.expectEqualSlices(u8, entry.key, actual.key);
        if (entry.value) |value| {
            try testing.expect(actual.value != null);
            try testing.expectEqualSlices(u8, value, actual.value.?);
        } else {
            try testing.expect(actual.value == null);
        }
    }
    try testing.expect(it.next() == null);
}

test "put then get returns value" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "hello", "world");

    try expectValue(&table, "hello", "world");
}

test "get on empty table returns absent" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);

    try testing.expect(table.get("hello") == .absent);
}

test "put then delete returns tombstone" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "hello", "world");

    try expectValue(&table, "hello", "world");
    try delete(&table, "hello");
    try testing.expect(table.get("hello") == .tombstone);
}

test "delete of missing key records tombstone" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try delete(&table, "missing");
    try testing.expect(table.get("missing") == .tombstone);
    try testing.expect(table.get("other") == .absent);

    try put(&table, "hello", "world");
    try expectValue(&table, "hello", "world");
}

test "put overwrites existing value" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "hello", "world");
    try expectValue(&table, "hello", "world");

    try put(&table, "hello", "new-world");
    try expectValue(&table, "hello", "new-world");
}

test "overwrite leaves earlier slices intact" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "hello", "world");
    const before = table.get("hello").value;

    try put(&table, "hello", "other");
    try testing.expectEqualSlices(u8, "world", before);
    try expectValue(&table, "hello", "other");
}

test "delete only affects target key" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "a", "value-a");
    try put(&table, "b", "value-b");

    try delete(&table, "a");
    try testing.expect(table.get("a") == .tombstone);
    try expectValue(&table, "b", "value-b");
}

test "keys sharing a prefix are distinct" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "a", "short");
    try put(&table, "ab", "long");

    try expectValue(&table, "a", "short");
    try expectValue(&table, "ab", "long");

    try delete(&table, "a");
    try testing.expect(table.get("a") == .tombstone);
    try expectValue(&table, "ab", "long");
}

test "empty value is not a tombstone" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "hello", "");

    try expectValue(&table, "hello", "");
}

test "put after delete restores key" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "hello", "world");
    try delete(&table, "hello");
    try testing.expect(table.get("hello") == .tombstone);

    try put(&table, "hello", "new-world");
    try expectValue(&table, "hello", "new-world");
}

test "empty key is allowed" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "", "world");
    try expectValue(&table, "", "world");

    try delete(&table, "");
    try testing.expect(table.get("") == .tombstone);
}

test "iterator on empty table yields nothing" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);

    var it = table.iterator();
    try testing.expect(it.next() == null);
}

test "iterator yields entries in key order" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "c", "3");
    try put(&table, "a", "1");
    try put(&table, "b", "2");

    var it = table.iterator();
    try expectEntries(&it, &.{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
        .{ .key = "c", .value = "3" },
    });
}

test "iterator orders by bytes not length" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "b", "");
    try put(&table, "ab", "");
    try put(&table, "a", "");
    try put(&table, "", "");
    try put(&table, "\xff", "");

    var it = table.iterator();
    try expectEntries(&it, &.{
        .{ .key = "", .value = "" },
        .{ .key = "a", .value = "" },
        .{ .key = "ab", .value = "" },
        .{ .key = "b", .value = "" },
        .{ .key = "\xff", .value = "" },
    });
}

test "iterator yields tombstones" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "a", "1");
    try put(&table, "b", "2");
    try put(&table, "c", "3");
    try delete(&table, "b");
    try delete(&table, "d");

    var it = table.iterator();
    try expectEntries(&it, &.{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = null },
        .{ .key = "c", .value = "3" },
        .{ .key = "d", .value = null },
    });
}

test "iterator yields latest value after overwrite" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "a", "old");
    try put(&table, "a", "new");

    var it = table.iterator();
    try expectEntries(&it, &.{
        .{ .key = "a", .value = "new" },
    });
}

test "iterator yields each key once after many writes" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    for (0..50) |_| {
        try put(&table, "a", "old");
        try put(&table, "b", "old");
        try delete(&table, "c");
    }
    try put(&table, "a", "new");
    try delete(&table, "b");
    try put(&table, "c", "new");

    var it = table.iterator();
    try expectEntries(&it, &.{
        .{ .key = "a", .value = "new" },
        .{ .key = "b", .value = null },
        .{ .key = "c", .value = "new" },
    });

    it.seek("b");
    try expectEntries(&it, &.{
        .{ .key = "b", .value = null },
        .{ .key = "c", .value = "new" },
    });
}

test "seek positions at first key at or after target" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    try put(&table, "b", "2");
    try put(&table, "d", "4");
    try put(&table, "f", "6");

    var it = table.iterator();
    it.seek("d");
    try expectEntries(&it, &.{
        .{ .key = "d", .value = "4" },
        .{ .key = "f", .value = "6" },
    });

    it.seek("c");
    try expectEntries(&it, &.{
        .{ .key = "d", .value = "4" },
        .{ .key = "f", .value = "6" },
    });

    it.seek("g");
    try testing.expect(it.next() == null);

    it.seekToFirst();
    try testing.expectEqualSlices(u8, "b", it.next().?.key);
}

test "the newest entry is the one with the largest sequence number" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);

    // The writes arrive out of order. The order they arrive in does not
    // matter: sequence number 9 is the newest whenever it is written.
    try table.put("a", "five", 5);
    try expectValue(&table, "a", "five");

    try table.put("a", "three", 3);
    try expectValue(&table, "a", "five");

    try table.put("a", "nine", 9);
    try expectValue(&table, "a", "nine");

    try table.delete("a", 7);
    try expectValue(&table, "a", "nine");

    try table.delete("a", 10);
    try testing.expect(table.get("a") == .tombstone);
}

test "the largest sequence number there is can be written and found" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);

    // A search looks for the largest sequence number, so a write that has
    // that number must still be found.
    const sequence_max = std.math.maxInt(u64);
    try table.put("a", "old", 1);
    try table.put("a", "max", sequence_max);
    try table.put("b", "other", 2);

    try expectValue(&table, "a", "max");

    var it = table.iterator();
    it.seek("a");
    const entry = it.next().?;
    try testing.expectEqualSlices(u8, "a", entry.key);
    try testing.expectEqual(@as(u64, sequence_max), entry.sequence);
}

test "iterator reports the sequence number of the newest entry for each key" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);

    try table.put("b", "old", 4);
    try table.put("a", "1", 20);
    try table.put("b", "new", 11);
    try table.put("b", "older", 2);
    try table.delete("c", 6);

    var it = table.iterator();
    const first = it.next().?;
    try testing.expectEqualSlices(u8, "a", first.key);
    try testing.expectEqualSlices(u8, "1", first.value.?);
    try testing.expectEqual(@as(u64, 20), first.sequence);

    const second = it.next().?;
    try testing.expectEqualSlices(u8, "b", second.key);
    try testing.expectEqualSlices(u8, "new", second.value.?);
    try testing.expectEqual(@as(u64, 11), second.sequence);

    const third = it.next().?;
    try testing.expectEqualSlices(u8, "c", third.key);
    try testing.expect(third.value == null);
    try testing.expectEqual(@as(u64, 6), third.sequence);

    try testing.expect(it.next() == null);

    // A seek lands on the newest entry for a key too.
    it.seek("b");
    try testing.expectEqual(@as(u64, 11), it.next().?.sequence);
}

test "writes in a random order of sequence numbers match a model" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);

    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();

    // Every sequence number from 1 to `write_count`, in a random order.
    const write_count = 400;
    var sequences: [write_count]u64 = undefined;
    for (&sequences, 1..) |*sequence, number| {
        sequence.* = number;
    }
    random.shuffle(u64, &sequences);

    // For each key, the largest sequence number written to it so far, or 0
    // if it has not been written.
    const key_count = 20;
    var newest: [key_count]u64 = @splat(0);

    var key_buffer: [3]u8 = undefined;
    var value_buffer: [8]u8 = undefined;
    for (sequences) |sequence| {
        const key_number = random.uintLessThan(usize, key_count);
        const key = try std.fmt.bufPrint(&key_buffer, "k{d:0>2}", .{key_number});
        // The value of a write is its sequence number.
        const value = try std.fmt.bufPrint(&value_buffer, "{d}", .{sequence});
        try table.put(key, value, sequence);

        if (sequence > newest[key_number]) {
            newest[key_number] = sequence;
        }
    }

    var it = table.iterator();
    for (newest, 0..) |sequence, key_number| {
        const key = try std.fmt.bufPrint(&key_buffer, "k{d:0>2}", .{key_number});
        if (sequence == 0) {
            try testing.expect(table.get(key) == .absent);
            continue;
        }
        const value = try std.fmt.bufPrint(&value_buffer, "{d}", .{sequence});
        try expectValue(&table, key, value);

        const entry = it.next().?;
        try testing.expectEqualSlices(u8, key, entry.key);
        try testing.expectEqualSlices(u8, value, entry.value.?);
        try testing.expectEqual(sequence, entry.sequence);
    }
    try testing.expect(it.next() == null);
}

test "put reports full and leaves table intact" {
    var table: MemTable = try .init(testing.allocator, 512);
    defer table.deinit(testing.allocator);

    var key_buffer: [8]u8 = undefined;
    var count: usize = 0;
    while (true) : (count += 1) {
        const key = try std.fmt.bufPrint(&key_buffer, "{d:0>4}", .{count});
        const free_before = table.bytesFree();
        put(&table, key, "value") catch |err| {
            try testing.expectEqual(error.Full, err);
            // Full means not even the shortest node fits, and nothing was used.
            const node_size_min = MemTable.Node.size(1, key.len, "value".len);
            try testing.expect(free_before < node_size_min + MemTable.node_padding_max);
            try testing.expectEqual(free_before, table.bytesFree());
            break;
        };
    }
    try testing.expect(count > 0);

    for (0..count) |index| {
        const key = try std.fmt.bufPrint(&key_buffer, "{d:0>4}", .{index});
        try expectValue(&table, key, "value");
    }
    const rejected = try std.fmt.bufPrint(&key_buffer, "{d:0>4}", .{count});
    try testing.expect(table.get(rejected) == .absent);
}

test "entry larger than the table is too large" {
    const size = 256;
    var table: MemTable = try .init(testing.allocator, size);
    defer table.deinit(testing.allocator);

    const free_before = table.bytesFree();
    // As long as the whole buffer, so it cannot fit as a key or as a value.
    const big: [size]u8 = @splat('x');
    try testing.expectError(error.TooLarge, put(&table, "key", &big));
    try testing.expectError(error.TooLarge, put(&table, &big, "value"));
    try testing.expectError(error.TooLarge, delete(&table, &big));
    try testing.expectEqual(free_before, table.bytesFree());
}

test "smallest table accepts no entries" {
    var table: MemTable = try .init(testing.allocator, MemTable.buffer_size_min);
    defer table.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), table.bytesFree());
    try testing.expectError(error.TooLarge, put(&table, "", ""));
    try testing.expectError(error.TooLarge, delete(&table, ""));
    try testing.expect(table.get("") == .absent);
}

test "largest legal entry fits in an empty table" {
    const size = 256;
    var table: MemTable = try .init(testing.allocator, size);
    defer table.deinit(testing.allocator);

    const value: [size]u8 = @splat('x');
    const len = table.bytesFree() - MemTable.Node.size(1, "key".len, 0);
    try testing.expectError(error.TooLarge, put(&table, "key", value[0 .. len + 1]));

    // Whatever height is drawn, a legal entry fits once the table is empty.
    for (0..2000) |_| {
        table.reset();
        try put(&table, "key", value[0..len]);
        try expectValue(&table, "key", value[0..len]);
        try testing.expectEqual(@as(usize, 0), table.bytesFree());
    }

    // The same entry in a table that isn't empty is full, not too large.
    table.reset();
    try put(&table, "a", "");
    try testing.expectError(error.Full, put(&table, "key", value[0..len]));
}

test "entries that fit by entrySizeMax never report full" {
    var table: MemTable = try .init(testing.allocator, 16 * 1024);
    defer table.deinit(testing.allocator);

    var prng: std.Random.DefaultPrng = .init(0xba7c4);
    const random = prng.random();
    var key_buffer: [40]u8 = undefined;
    const value_buffer: [200]u8 = @splat('v');
    var batches_applied: usize = 0;
    var resets: usize = 0;

    for (0..5000) |_| {
        // Choose the sizes of a batch of entries.
        var key_lens: [8]usize = undefined;
        var value_lens: [8]usize = undefined;
        const batch_len = 1 + random.uintLessThan(usize, 8);
        var size_max: usize = 0;
        for (0..batch_len) |i| {
            key_lens[i] = random.uintLessThan(usize, key_buffer.len + 1);
            value_lens[i] = random.uintLessThan(usize, value_buffer.len + 1);
            size_max += MemTable.entrySizeMax(key_lens[i], value_lens[i]);
        }

        if (size_max > table.bytesFree()) {
            table.reset();
            resets += 1;
            continue;
        }

        // The batch was judged to fit, so every insert must succeed.
        for (0..batch_len) |i| {
            random.bytes(key_buffer[0..key_lens[i]]);
            try put(&table, key_buffer[0..key_lens[i]], value_buffer[0..value_lens[i]]);
        }
        batches_applied += 1;
    }

    try testing.expect(batches_applied > 0);
    try testing.expect(resets > 0);
}

test "one entry of entrySizeMax fits at any height" {
    const key = "key";
    const value = "value";
    const size = MemTable.buffer_size_min + MemTable.entrySizeMax(key.len, value.len);
    var table: MemTable = try .init(testing.allocator, size);
    defer table.deinit(testing.allocator);

    for (0..2000) |_| {
        table.reset();
        try put(&table, key, value);
    }
}

test "reset empties the table and reuses its memory" {
    var table: MemTable = try .init(testing.allocator, test_buffer_size);
    defer table.deinit(testing.allocator);
    const free_when_empty = table.bytesFree();
    try testing.expectEqual(test_buffer_size - MemTable.buffer_size_min, free_when_empty);
    try put(&table, "a", "1");
    try delete(&table, "b");
    try testing.expect(table.bytesFree() < free_when_empty);

    table.reset();
    try testing.expectEqual(free_when_empty, table.bytesFree());
    try testing.expect(table.get("a") == .absent);
    try testing.expect(table.get("b") == .absent);
    var it = table.iterator();
    try testing.expect(it.next() == null);

    try put(&table, "a", "2");
    try expectValue(&table, "a", "2");
}

test "random operations match a model" {
    const key_count = 300;
    const Model = union(enum) {
        absent,
        tombstone,
        value: struct { byte: u8, len: u8 },
    };

    var table: MemTable = try .init(testing.allocator, 8 * 1024);
    defer table.deinit(testing.allocator);

    var model: [key_count]Model = @splat(.absent);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [255]u8 = undefined;
    var resets: usize = 0;

    for (0..20_000) |_| {
        const index = random.uintLessThan(usize, key_count);
        const key = try std.fmt.bufPrint(&key_buffer, "{d}", .{index});

        switch (random.uintLessThan(u8, 10)) {
            0...4 => {
                const byte = random.int(u8);
                const len = random.uintLessThan(u8, 40);
                @memset(value_buffer[0..len], byte);
                if (put(&table, key, value_buffer[0..len])) {
                    model[index] = .{ .value = .{ .byte = byte, .len = len } };
                } else |err| {
                    try testing.expectEqual(error.Full, err);
                    table.reset();
                    model = @splat(.absent);
                    resets += 1;
                }
            },
            5...6 => {
                if (delete(&table, key)) {
                    model[index] = .tombstone;
                } else |err| {
                    try testing.expectEqual(error.Full, err);
                    table.reset();
                    model = @splat(.absent);
                    resets += 1;
                }
            },
            else => {},
        }

        switch (model[index]) {
            .absent => try testing.expect(table.get(key) == .absent),
            .tombstone => try testing.expect(table.get(key) == .tombstone),
            .value => |v| {
                @memset(value_buffer[0..v.len], v.byte);
                try expectValue(&table, key, value_buffer[0..v.len]);
            },
        }
    }
    try testing.expect(resets > 0);

    // The iterator must yield exactly the model's entries, in byte order.
    var present: usize = 0;
    for (model) |entry| {
        if (entry != .absent) present += 1;
    }
    var it = table.iterator();
    var previous_buffer: [8]u8 = undefined;
    var previous: ?[]const u8 = null;
    var seen: usize = 0;
    while (it.next()) |entry| : (seen += 1) {
        if (previous) |p| try testing.expect(std.mem.order(u8, p, entry.key) == .lt);
        const index = try std.fmt.parseInt(usize, entry.key, 10);
        switch (model[index]) {
            .absent => return error.TestUnexpectedEntry,
            .tombstone => try testing.expect(entry.value == null),
            .value => |v| {
                @memset(value_buffer[0..v.len], v.byte);
                try testing.expectEqualSlices(u8, value_buffer[0..v.len], entry.value.?);
            },
        }
        @memcpy(previous_buffer[0..entry.key.len], entry.key);
        previous = previous_buffer[0..entry.key.len];
    }
    try testing.expectEqual(present, seen);
}

test "nextVersion visits every entry, newest first for each key" {
    var table: MemTable = try .init(testing.allocator, 4096);
    defer table.deinit(testing.allocator);
    try testing.expect(table.isEmpty());

    try table.put("b", "old", 1);
    try table.put("a", "1", 2);
    try table.delete("b", 3);
    try table.put("b", "new", 4);
    try testing.expect(!table.isEmpty());

    var it = table.iterator();
    const first = it.nextVersion().?;
    try testing.expectEqualSlices(u8, "a", first.key);
    try testing.expectEqual(@as(u64, 2), first.sequence);

    const second = it.nextVersion().?;
    try testing.expectEqualSlices(u8, "b", second.key);
    try testing.expectEqualSlices(u8, "new", second.value.?);
    try testing.expectEqual(@as(u64, 4), second.sequence);

    const third = it.nextVersion().?;
    try testing.expectEqualSlices(u8, "b", third.key);
    try testing.expect(third.value == null);
    try testing.expectEqual(@as(u64, 3), third.sequence);

    const fourth = it.nextVersion().?;
    try testing.expectEqualSlices(u8, "b", fourth.key);
    try testing.expectEqualSlices(u8, "old", fourth.value.?);
    try testing.expectEqual(@as(u64, 1), fourth.sequence);

    try testing.expect(it.nextVersion() == null);
    try testing.expect(it.nextVersion() == null);

    table.reset();
    try testing.expect(table.isEmpty());
}
