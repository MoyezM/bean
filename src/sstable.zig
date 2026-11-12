//! A sorted table: an immutable file of key-value entries in key order.
//!
//! A table is written once, front to back, from entries that are already
//! sorted, and is never changed afterwards. A flush writes the memtable out
//! as one table.
//!
//! Writing and reading are separate types. A `Writer` creates the file and
//! takes entries in key order. A `Reader` opens a finished file, looks up
//! single keys, and hands out iterators.
//!
//! Nothing here allocates. The caller lends every buffer, so the store can
//! allocate them all once when it opens.
//!
//! A table does not know about other tables. Deciding which table to ask
//! first, and what a tombstone hides, is the job of the layer above.
//!
//! File layout, with all integers little-endian:
//!
//!     data block, data block, ...     (none if the table is empty)
//!     index block
//!     footer
//!
//! Data blocks and the index block share one block layout:
//!
//!     block header:   header checksum (u32)   covers the rest of the header
//!                     body checksum (u32)     covers the body
//!                     kind (u32)              1 = data, 2 = index
//!                     entry count (u32)
//!                     body length (u32)
//!     body:           entry, entry, ...       back to back, in order
//!                     slot, slot, ...         one for each entry, last entry first
//!
//!     entry:          flags (u8)              0 = value, 1 = tombstone
//!                     key length (u16)
//!                     value length (u32)      0 for a tombstone
//!                     sequence (u64)          the number of the write
//!                     key
//!                     value
//!
//!     slot:           entry offset (u32)      where the entry starts in the body
//!
//! Every entry carries the sequence number of the write that made it. Entries
//! are ordered by key, and entries with the same key by sequence number,
//! largest first. So a table can hold several entries for one key, and the
//! first of them is the newest. No two entries have the same key and the same
//! sequence number.
//!
//! There is no padding anywhere. The entries start at the front of the body
//! and the slots fill the end of it. The slots are in the opposite order to
//! the entries: the last four bytes of the body are the slot of the first
//! entry, the four bytes before those are the slot of the second entry, and
//! so on. Slots have a fixed width, so a key is found inside a block by
//! binary search.
//!
//! Blocks vary in size. The writer closes a data block before adding an entry
//! that would take the block past `Options.block_size`, so a block is only
//! longer than that when it holds a single large entry.
//!
//! The index block has one entry for each data block, in file order. The
//! entry's key and sequence number are those of the last entry of the data
//! block, and its value says where the data block is:
//!
//!     block location: block offset (u64)
//!                     block length (u32)      header and body together
//!                     block header checksum (u32)
//!
//!     footer:         magic (8 bytes)
//!                     version (u32)
//!                     index block location (16 bytes, as above)
//!                     largest data block length (u32)
//!                     footer checksum (u32)   covers the rest of the footer
//!
//! The checksums are CRC-32C, and they form a chain that covers the whole
//! table. The footer checksum covers the index block's header checksum. That
//! covers the index block's body checksum, and so the index body, which holds
//! the header checksum of every data block. A data block's header checksum
//! covers its body checksum in the same way. The blocks must also fill the
//! file exactly, with no gaps: the data blocks run from offset zero to the
//! index block, and the index block runs to the footer.
//!
//! The reader loads the whole index block when it opens the table. A lookup
//! binary searches the index block for the one data block that can hold the
//! newest entry for the key, reads that block from the file, and binary
//! searches it.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const constants = @import("constants.zig");
const crc32c = @import("checksum.zig").crc32c;
const durable = @import("durable.zig");

/// The longest key a table stores. A longer key is a bug in the caller.
pub const key_size_max = constants.key_size_max;

/// The longest value a table stores. A longer value is a bug in the caller.
pub const value_size_max = constants.value_size_max;

/// The size data blocks are filled up to, unless `Options` says otherwise.
pub const block_size = constants.block_size;

/// The longest block a table written with the default options can hold: a
/// full block, or one entry with the longest key and the longest value,
/// whichever is longer. A buffer of this size can hold any block.
pub const block_size_max = blockSizeMax(.{}, key_size_max, value_size_max);

/// The most bytes of entries, counted with their slots, that one table holds.
/// A flush writes one memtable to one table, and an entry takes less room in
/// a table than it does in the memtable, so this is the memtable's size.
pub const table_size_max = constants.memtable_size;

/// The most data blocks one table has.
pub const block_count_max = blockCountMax(.{}, table_size_max);

/// The longest index block one table has. A buffer of this size can hold the
/// index of any table, for writing it and for opening it.
pub const index_size_max = indexSizeMax(block_count_max, key_size_max);

/// The bytes an entry takes in a table beyond its key and value.
pub const entry_overhead = entry_header_size + slot_size;

/// The longest key the format can represent. The key length is a u16 on disk.
const key_size_format_max = std.math.maxInt(u16);

/// The longest value the format can represent. The value length is a u32 on
/// disk.
const value_size_format_max = std.math.maxInt(u32);

/// The longest block the format can represent. Block lengths are a u32 on
/// disk.
const block_size_format_max = std.math.maxInt(u32);

comptime {
    assert(key_size_max <= key_size_format_max);
    assert(value_size_max <= value_size_format_max);
    assert(block_size_max <= block_size_format_max);
    assert(index_size_max <= block_size_format_max);
}

/// How a table is written.
pub const Options = struct {
    /// The size data blocks are filled up to. A block is only longer than
    /// this when it holds a single entry that is larger than a block.
    block_size: u32 = block_size,
};

/// What a table knows about one key.
pub const Lookup = union(enum) {
    value: []const u8,
    /// The key was deleted here, so older tables must not be consulted.
    tombstone,
    /// This table has no entry for the key.
    absent,
};

/// One entry returned by an iterator.
pub const Entry = struct {
    key: []const u8,
    /// `null` means the entry is a tombstone.
    value: ?[]const u8,
    /// The sequence number of the write that made the entry.
    sequence: u64,
};

/// The largest sequence number. A search for a key with this number lands on
/// the newest entry for the key.
const sequence_newest = std.math.maxInt(u64);

/// The magic never changes. A change to the format changes `version`.
const magic: [8]u8 = "beansst1".*;
const version = 2;

// The sizes of the parts of the file come from the structs that describe
// them, further down.
const block_header_size = @sizeOf(BlockHeader);
const entry_header_size = @sizeOf(EntryHeader);
const slot_size = @sizeOf(Slot);
const block_location_size = @sizeOf(BlockLocation);
const footer_size = @sizeOf(Footer);

comptime {
    // The structs are written to the file exactly as they are in memory,
    // and the format is little-endian.
    assert(builtin.cpu.arch.endian() == .little);

    // These sizes are part of the format. A change to a struct that makes
    // one of these fail has changed the format, and needs a new `version`.
    assert(block_header_size == 20);
    assert(entry_header_size == 15);
    assert(slot_size == 4);
    assert(block_location_size == 16);
    assert(footer_size == 36);
}

/// The size of the largest block a table can hold when no key is longer than
/// `key_len_max` and no value is longer than `value_len_max`. A buffer of
/// this size can hold any block of such a table.
pub fn blockSizeMax(options: Options, key_len_max: usize, value_len_max: usize) usize {
    assert(key_len_max <= key_size_max);
    assert(value_len_max <= value_size_max);

    // A block is longer than the block size only when it holds one entry.
    const entry_size = entrySize(key_len_max, value_len_max);
    const single_entry_block_size = block_header_size + entry_size + slot_size;
    return @max(options.block_size, single_entry_block_size);
}

/// The most data blocks a table can have when its entries, counted with their
/// slots, take no more than `size_max` bytes.
///
/// A block is closed only when the next entry would take it past the block
/// size. So the entries of any two blocks that are next to each other take
/// more than one block size less a block header, and a table has at most two
/// blocks for each such amount, plus one.
pub fn blockCountMax(options: Options, size_max: usize) usize {
    assert(options.block_size > block_header_size);

    const pair_size_min = options.block_size - block_header_size;
    return (2 * size_max) / pair_size_min + 1;
}

/// The size of the largest index block a table can have when it has no more
/// than `block_count` data blocks and no key is longer than `key_len_max`.
/// Every data block holds at least one entry, so the number of entries in a
/// table is a safe `block_count`.
///
/// A `Writer` whose index buffer is this long never reports `TableFull` for
/// such a table, and a `Reader` whose index buffer is this long can open it.
pub fn indexSizeMax(block_count: usize, key_len_max: usize) usize {
    assert(key_len_max <= key_size_max);

    const entries_size = block_count * indexEntrySize(key_len_max);
    return block_header_size + entries_size;
}

/// What a block holds.
const BlockKind = enum(u32) {
    data = 1,
    index = 2,
    /// Any other number. A damaged file can hold one.
    _,
};

/// What an entry is.
const EntryFlags = enum(u8) {
    value = 0,
    tombstone = 1,
    /// Any other number. A damaged file can hold one.
    _,
};

/// Where an entry starts in the body of its block.
const Slot = u32;

/// The first bytes of every block, as they are in the file.
const BlockHeader = extern struct {
    /// Covers the rest of the header.
    header_checksum: u32,
    /// Covers the body.
    body_checksum: u32,
    kind: BlockKind,
    entry_count: u32,
    body_len: u32,

    fn fromBytes(bytes: *const [block_header_size]u8) BlockHeader {
        return std.mem.bytesToValue(BlockHeader, bytes);
    }

    fn toBytes(header: *const BlockHeader) *const [block_header_size]u8 {
        return std.mem.asBytes(header);
    }

    /// The header checksum these fields must carry. It covers every field
    /// after `header_checksum`.
    fn expectedHeaderChecksum(header: *const BlockHeader) u32 {
        const bytes = header.toBytes();
        const covered_start = @offsetOf(BlockHeader, "body_checksum");
        return crc32c(bytes[covered_start..]);
    }
};

/// The first bytes of every entry, as they are in the file. The key follows,
/// then the value.
///
/// The fields are marked `align(1)` so that the struct has no padding, in
/// memory or in the file.
const EntryHeader = extern struct {
    flags: EntryFlags,
    key_len: u16 align(1),
    /// Zero for a tombstone.
    value_len: u32 align(1),
    /// The sequence number of the write that made the entry.
    sequence: u64 align(1),

    fn fromBytes(bytes: *const [entry_header_size]u8) EntryHeader {
        return std.mem.bytesToValue(EntryHeader, bytes);
    }

    fn toBytes(header: *const EntryHeader) *const [entry_header_size]u8 {
        return std.mem.asBytes(header);
    }
};

/// Where one block is in the file, as it is stored in the file. This is the
/// value of an index entry, and the footer holds one for the index block.
const BlockLocation = extern struct {
    offset: u64 align(1),
    /// The length of the whole block, header and body together.
    len: u32 align(1),
    /// The header checksum in the block's header.
    header_checksum: u32 align(1),

    fn fromBytes(bytes: *const [block_location_size]u8) BlockLocation {
        return std.mem.bytesToValue(BlockLocation, bytes);
    }

    fn toBytes(location: *const BlockLocation) *const [block_location_size]u8 {
        return std.mem.asBytes(location);
    }
};

/// The last bytes of the file, as they are in the file.
const Footer = extern struct {
    magic: [8]u8,
    version: u32 align(1),
    index: BlockLocation,
    /// The length of the longest data block, or zero if there are none.
    block_len_max: u32 align(1),
    /// Covers the rest of the footer.
    checksum: u32 align(1),

    fn init(index: BlockLocation, block_len_max: u32) Footer {
        var footer: Footer = .{
            .magic = magic,
            .version = version,
            .index = index,
            .block_len_max = block_len_max,
            .checksum = 0,
        };
        footer.checksum = footer.expectedChecksum();
        return footer;
    }

    /// Fails with `Corrupt` if `bytes` is not an intact footer, and with
    /// `UnsupportedVersion` if it is an intact footer of another version.
    fn fromBytes(bytes: *const [footer_size]u8) error{ Corrupt, UnsupportedVersion }!Footer {
        const footer = std.mem.bytesToValue(Footer, bytes);
        if (!std.mem.eql(u8, &footer.magic, &magic)) {
            return error.Corrupt;
        }
        if (footer.checksum != footer.expectedChecksum()) {
            return error.Corrupt;
        }
        // The version can be trusted now that the checksum has been checked.
        if (footer.version != version) {
            return error.UnsupportedVersion;
        }
        return footer;
    }

    fn toBytes(footer: *const Footer) *const [footer_size]u8 {
        return std.mem.asBytes(footer);
    }

    /// The checksum these fields must carry. It covers every field before
    /// `checksum`.
    fn expectedChecksum(footer: *const Footer) u32 {
        const bytes = footer.toBytes();
        const covered_end = @offsetOf(Footer, "checksum");
        return crc32c(bytes[0..covered_end]);
    }
};

/// Bytes one entry takes in a block body, not counting its slot.
fn entrySize(key_len: usize, value_len: usize) usize {
    return entry_header_size + key_len + value_len;
}

/// Bytes the index block needs for one data block whose last key is
/// `key_len` long: the index entry and its slot.
fn indexEntrySize(key_len: usize) usize {
    return entrySize(key_len, block_location_size) + slot_size;
}

/// Whether an entry with key `a_key` and sequence number `a_sequence` comes
/// before one with `b_key` and `b_sequence` in a table: its key is smaller,
/// or the keys are the same and its sequence number is larger.
pub fn sortsBefore(a_key: []const u8, a_sequence: u64, b_key: []const u8, b_sequence: u64) bool {
    const key_order = std.mem.order(u8, a_key, b_key);
    if (key_order == .lt) {
        return true;
    }
    if (key_order == .gt) {
        return false;
    }
    return a_sequence > b_sequence;
}

/// Writes one entry into `bytes`, which must be exactly `entrySize` long.
/// Returns the key as it is stored in `bytes`.
fn writeEntry(
    bytes: []u8,
    flags: EntryFlags,
    key: []const u8,
    value: []const u8,
    sequence: u64,
) []const u8 {
    assert(bytes.len == entrySize(key.len, value.len));
    const key_start = entry_header_size;
    const value_start = key_start + key.len;

    const header: EntryHeader = .{
        .flags = flags,
        .key_len = @intCast(key.len),
        .value_len = @intCast(value.len),
        .sequence = sequence,
    };
    @memcpy(bytes[0..entry_header_size], header.toBytes());
    @memcpy(bytes[key_start..value_start], key);
    @memcpy(bytes[value_start..], value);

    return bytes[key_start..value_start];
}

/// One entry read out of a block. The slices point into the block.
const StoredEntry = struct {
    flags: EntryFlags,
    key: []const u8,
    value: []const u8,
    sequence: u64,
};

/// Reads the entry that starts at `offset` in `entries`, the part of a block
/// body that holds the entries. Fails if the entry does not fit there or has
/// flags the format does not define.
fn readEntry(entries: []const u8, offset: usize) error{Corrupt}!StoredEntry {
    if (offset > entries.len) {
        return error.Corrupt;
    }
    const bytes_left = entries.len - offset;
    if (bytes_left < entry_header_size) {
        return error.Corrupt;
    }

    const header_bytes = entries[offset..][0..entry_header_size];
    const header = EntryHeader.fromBytes(header_bytes);
    const flags = header.flags;
    const key_len: usize = header.key_len;
    const value_len: usize = header.value_len;

    if (flags != .value and flags != .tombstone) {
        return error.Corrupt;
    }
    if (flags == .tombstone and value_len != 0) {
        return error.Corrupt;
    }

    const bytes_after_header = bytes_left - entry_header_size;
    if (key_len > bytes_after_header) {
        return error.Corrupt;
    }
    if (value_len > bytes_after_header - key_len) {
        return error.Corrupt;
    }

    const key_start = offset + entry_header_size;
    const value_start = key_start + key_len;
    const value_end = value_start + value_len;
    return .{
        .flags = flags,
        .key = entries[key_start..value_start],
        .value = entries[value_start..value_end],
        .sequence = header.sequence,
    };
}

/// A block that has been read and checked. The slices point into the buffer
/// the block was read into.
const Block = struct {
    /// The header checksum in the block's header.
    header_checksum: u32,
    entry_count: usize,
    /// The front of the body: the entries.
    entries: []const u8,
    /// The end of the body: one slot for each entry, last entry first.
    slots: []const u8,

    /// A block with no entries, for an iterator that has not read one yet.
    const empty: Block = .{
        .header_checksum = 0,
        .entry_count = 0,
        .entries = "",
        .slots = "",
    };
};

/// Checks a whole block that was read from the file: both checksums, its
/// kind, that its body length matches the length it was read with, and that
/// its slots fit in the body.
fn checkBlock(bytes: []const u8, kind: BlockKind) error{Corrupt}!Block {
    if (bytes.len < block_header_size) {
        return error.Corrupt;
    }
    const header = BlockHeader.fromBytes(bytes[0..block_header_size]);
    const body = bytes[block_header_size..];

    // Nothing in the header can be trusted until its checksum is checked.
    if (header.header_checksum != header.expectedHeaderChecksum()) {
        return error.Corrupt;
    }
    if (header.kind != kind) {
        return error.Corrupt;
    }
    if (header.body_len != body.len) {
        return error.Corrupt;
    }
    if (header.body_checksum != crc32c(body)) {
        return error.Corrupt;
    }

    // The count is checked before it is multiplied, so that a huge count
    // cannot overflow where `usize` is 32 bits.
    const entry_count: usize = header.entry_count;
    const entry_count_max = body.len / slot_size;
    if (entry_count > entry_count_max) {
        return error.Corrupt;
    }
    const slots_len = entry_count * slot_size;
    const entries_len = body.len - slots_len;

    return .{
        .header_checksum = header.header_checksum,
        .entry_count = entry_count,
        .entries = body[0..entries_len],
        .slots = body[entries_len..],
    };
}

/// Reads entry number `entry_index` of a block, by way of its slot.
fn blockEntry(block: Block, entry_index: usize) error{Corrupt}!StoredEntry {
    assert(entry_index < block.entry_count);

    // The slots are in the opposite order to the entries, so the slot of
    // entry 0 is the last one.
    const slot_end = block.slots.len - entry_index * slot_size;
    const slot_start = slot_end - slot_size;
    const slot = block.slots[slot_start..][0..slot_size];

    const entry_offset = std.mem.readInt(Slot, slot, .little);
    return readEntry(block.entries, entry_offset);
}

/// Returns the number of the first entry in the block that does not come
/// before the write to `key` numbered `sequence`, or the block's entry count
/// if every entry comes before it. With `sequence_newest`, that is the first
/// entry whose key is >= `key`.
fn blockLowerBound(block: Block, key: []const u8, sequence: u64) error{Corrupt}!usize {
    // Binary search. Every entry before `low` comes before the target, and
    // every entry from `high` on does not.
    var low: usize = 0;
    var high: usize = block.entry_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = try blockEntry(block, middle);
        if (sortsBefore(entry.key, entry.sequence, key, sequence)) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

/// Returns the number of the first entry whose key is >= `key`, in the data
/// block that `Reader.findBlock` chose for `key`. Among entries for one key
/// that is the newest.
///
/// Such an entry always exists. The index entry of the block does not come
/// before the newest write to `key`, and `Reader.readBlock` has checked that
/// the block's last entry has the index entry's key and sequence number.
fn lowerBoundInFoundBlock(block: Block, key: []const u8) error{Corrupt}!usize {
    const entry_index = try blockLowerBound(block, key, sequence_newest);
    assert(entry_index < block.entry_count);
    return entry_index;
}

/// Builds one block in a buffer lent by the caller. The writer has two: one
/// for the data block being filled and one for the index block.
///
/// While a block is being built, the buffer is filled from both ends. The
/// entries follow the block header at the front, and each entry's slot is
/// written at the back, so the free space is in the middle:
///
///     header, entry 0, entry 1, ...   free   ..., slot 1, slot 0
///
/// `finish` closes the gap by moving the slots up against the entries.
const BlockBuilder = struct {
    buffer: []u8,
    /// How many bytes of entries have been added.
    entries_len: usize,
    entry_count: usize,

    /// A block that is ready to be written to the file.
    const Finished = struct {
        /// The whole block. Points into the builder's buffer.
        bytes: []const u8,
        header_checksum: u32,
    };

    fn init(buffer: []u8) BlockBuilder {
        assert(buffer.len >= block_header_size);
        assert(buffer.len <= block_size_format_max);
        return .{
            .buffer = buffer,
            .entries_len = 0,
            .entry_count = 0,
        };
    }

    /// The length the block would have if it were finished now.
    fn blockLen(self: *const BlockBuilder) usize {
        const slots_len = self.entry_count * slot_size;
        return block_header_size + self.entries_len + slots_len;
    }

    /// Bytes of the buffer that are not used yet.
    fn bytesFree(self: *const BlockBuilder) usize {
        return self.buffer.len - self.blockLen();
    }

    /// Adds one entry after the entries already in the block. The entry and
    /// its slot must fit in the free space. Returns the key as it is stored
    /// in the buffer.
    fn add(
        self: *BlockBuilder,
        flags: EntryFlags,
        key: []const u8,
        value: []const u8,
        sequence: u64,
    ) []const u8 {
        const entry_size = entrySize(key.len, value.len);
        assert(entry_size + slot_size <= self.bytesFree());

        const entry_start = block_header_size + self.entries_len;
        const entry_bytes = self.buffer[entry_start..][0..entry_size];
        const stored_key = writeEntry(entry_bytes, flags, key, value, sequence);

        const slots_len = self.entry_count * slot_size;
        const slot_end = self.buffer.len - slots_len;
        const slot_start = slot_end - slot_size;
        const slot = self.buffer[slot_start..][0..slot_size];
        std.mem.writeInt(Slot, slot, @intCast(self.entries_len), .little);

        self.entries_len += entry_size;
        self.entry_count += 1;
        return stored_key;
    }

    /// Moves the slots up against the entries and fills in the block header.
    /// The block must be written out before anything else is added.
    fn finish(self: *BlockBuilder, kind: BlockKind) Finished {
        const slots_len = self.entry_count * slot_size;
        const slots_at_back = self.buffer[self.buffer.len - slots_len ..];

        const block = self.buffer[0..self.blockLen()];
        const body = block[block_header_size..];
        const slots_in_body = body[self.entries_len..];

        // The two ranges overlap when the buffer is nearly full.
        @memmove(slots_in_body, slots_at_back);

        var header: BlockHeader = .{
            .header_checksum = 0,
            .body_checksum = crc32c(body),
            .kind = kind,
            .entry_count = @intCast(self.entry_count),
            .body_len = @intCast(body.len),
        };
        header.header_checksum = header.expectedHeaderChecksum();
        @memcpy(block[0..block_header_size], header.toBytes());

        return .{ .bytes = block, .header_checksum = header.header_checksum };
    }

    /// Empties the builder so that it can build the next block.
    fn reset(self: *BlockBuilder) void {
        self.entries_len = 0;
        self.entry_count = 0;
    }
};

/// Writes a table file. Entries are added in key order, then `finish` writes
/// the index block and the footer.
pub const Writer = struct {
    io: Io,
    file: Io.File,
    block_size: u32,
    /// The data block being filled.
    data: BlockBuilder,
    /// The index block: one entry for every data block written so far.
    index: BlockBuilder,
    /// The key of the entry added last. It points into the buffer of `data`.
    /// Only meaningful once an entry has been added.
    last_key: []const u8,
    /// The sequence number of the entry added last. Only meaningful once an
    /// entry has been added.
    last_sequence: u64,
    /// Where in the file the next block will be written.
    offset: u64,
    /// How many entries have been added.
    entry_count: u64,
    /// The length of the longest data block written.
    block_len_max: u32,
    /// Set once `finish` has completed the table.
    finished: bool,
    /// Set when a write or sync has failed and the file's state is unknown.
    broken: bool,

    /// Memory the writer works in. The caller owns both buffers, and they
    /// must stay valid until the writer is closed.
    pub const Buffers = struct {
        /// Holds the data block being filled. It must be at least
        /// `Options.block_size` long, and it bounds the largest entry that
        /// can be added; see `blockSizeMax`.
        block: []u8,
        /// Holds the index, which gets one entry for each data block
        /// written. It bounds how large the table can grow; see
        /// `indexSizeMax`.
        index: []u8,
    };

    /// What `finish` reports about the table it completed. The layer above
    /// records `file_size` and `checksum`, and compares them with
    /// `Reader.fileSize` and `Reader.checksum` when it opens the file, to
    /// tell that it is the file that was written.
    pub const Summary = struct {
        /// For the caller's information. It is not stored in the file.
        entry_count: u64,
        /// The length of the file in bytes.
        file_size: u64,
        /// The footer checksum, which covers the whole table through the
        /// chain of checksums.
        checksum: u32,
    };

    pub const CreateError = Io.File.OpenError;

    pub const AddError = error{
        /// The entry does not fit in `Buffers.block`.
        EntryTooLarge,
        /// `Buffers.index` has no room for another data block.
        TableFull,
    } || Io.File.WritePositionalError;

    pub const FinishError = Io.File.WritePositionalError || Io.File.SyncError;

    /// Creates the file `name` in `dir`. Fails if the file already exists.
    pub fn create(
        io: Io,
        dir: Io.Dir,
        name: []const u8,
        options: Options,
        buffers: Buffers,
    ) CreateError!Writer {
        assert(buffers.block.len >= options.block_size);

        const data: BlockBuilder = .init(buffers.block);
        const index: BlockBuilder = .init(buffers.index);

        const file = try dir.createFile(io, name, .{ .exclusive = true });

        return .{
            .io = io,
            .file = file,
            .block_size = options.block_size,
            .data = data,
            .index = index,
            .last_key = "",
            .last_sequence = 0,
            .offset = 0,
            .entry_count = 0,
            .block_len_max = 0,
            .finished = false,
            .broken = false,
        };
    }

    /// Closes the file. If `finish` has not returned without an error, the
    /// file is not a valid table and the caller should delete it.
    pub fn close(self: *Writer) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// Adds one entry. A `null` value adds a tombstone.
    ///
    /// Entries are added in the table's order: `key` must be greater than
    /// the key added before it, or the same key with a smaller `sequence`.
    /// Adding entries out of order, or the same key and sequence number
    /// twice, is a bug in the caller.
    ///
    /// `EntryTooLarge` and `TableFull` are reported before anything
    /// is changed, so the caller can still finish the table as it stands.
    /// After any other error the file's state is unknown, and the writer
    /// must only be closed.
    pub fn add(self: *Writer, key: []const u8, value: ?[]const u8, sequence: u64) AddError!void {
        assert(!self.finished);
        assert(!self.broken);

        var flags: EntryFlags = .tombstone;
        var value_bytes: []const u8 = "";
        if (value) |present| {
            flags = .value;
            value_bytes = present;
        }

        assert(key.len <= key_size_max);
        assert(value_bytes.len <= value_size_max);

        // The entry must fit in a block that holds nothing else.
        const entry_size = entrySize(key.len, value_bytes.len);
        const single_entry_block_len = block_header_size + entry_size + slot_size;
        if (single_entry_block_len > self.data.buffer.len) {
            return error.EntryTooLarge;
        }

        if (self.entry_count > 0) {
            assert(sortsBefore(self.last_key, self.last_sequence, key, sequence));
        }

        // The current block is closed first if this entry and its slot would
        // take it past the block size. An empty block takes the entry however
        // large it is.
        const block_has_entries = self.data.entry_count > 0;
        const block_len_with_entry = self.data.blockLen() + entry_size + slot_size;
        const closes_block = block_has_entries and block_len_with_entry > self.block_size;

        // The block this entry goes into will end with `key` until another
        // entry is added, so the index must have room for an entry with that
        // key. If the current block is closed first, the index also takes an
        // entry for it.
        var index_bytes_needed = indexEntrySize(key.len);
        if (closes_block) {
            index_bytes_needed += indexEntrySize(self.last_key.len);
        }
        if (index_bytes_needed > self.index.bytesFree()) {
            return error.TableFull;
        }

        if (closes_block) {
            // A failure here leaves the file in an unknown state.
            errdefer self.broken = true;
            try self.writeDataBlock();
        }
        self.last_key = self.data.add(flags, key, value_bytes, sequence);
        self.last_sequence = sequence;
        self.entry_count += 1;
    }

    /// Writes everything that is still buffered and syncs the file. When
    /// this returns without an error, the table is complete and durable.
    /// Nothing may be added afterwards.
    ///
    /// The file's name is not durable until the caller syncs `dir`.
    ///
    /// After an error the file's state is unknown, and the writer must only
    /// be closed.
    pub fn finish(self: *Writer) FinishError!Summary {
        assert(!self.finished);
        assert(!self.broken);
        errdefer self.broken = true;

        if (self.data.entry_count > 0) {
            try self.writeDataBlock();
        }

        const index = self.index.finish(.index);
        try self.file.writePositionalAll(self.io, index.bytes, self.offset);

        const index_location: BlockLocation = .{
            .offset = self.offset,
            .len = @intCast(index.bytes.len),
            .header_checksum = index.header_checksum,
        };
        const footer: Footer = .init(index_location, self.block_len_max);
        const footer_offset = self.offset + index.bytes.len;
        try self.file.writePositionalAll(self.io, footer.toBytes(), footer_offset);

        try durable.sync(self.io, self.file);

        self.finished = true;
        return .{
            .entry_count = self.entry_count,
            .file_size = footer_offset + footer_size,
            .checksum = footer.checksum,
        };
    }

    /// Writes the data block being filled to the file, adds an entry for it
    /// to the index, and starts a new, empty block.
    fn writeDataBlock(self: *Writer) Io.File.WritePositionalError!void {
        assert(self.data.entry_count > 0);

        const block = self.data.finish(.data);
        try self.file.writePositionalAll(self.io, block.bytes, self.offset);

        const location: BlockLocation = .{
            .offset = self.offset,
            .len = @intCast(block.bytes.len),
            .header_checksum = block.header_checksum,
        };

        // The entry added last is the last entry of this block. `add` has
        // already made sure the index has room for it.
        _ = self.index.add(.value, self.last_key, location.toBytes(), self.last_sequence);

        self.offset += block.bytes.len;
        self.block_len_max = @max(self.block_len_max, location.len);
        self.data.reset();
    }
};

/// Reads a table file. The index block is held in memory for as long as the
/// reader is open; data blocks are read from the file when they are needed.
pub const Reader = struct {
    io: Io,
    file: Io.File,
    /// The index block, checked. Points into the buffer given to `open`.
    index: Block,
    /// The length of the longest data block, or zero if there are none.
    block_len_max: u32,
    /// The length of the file in bytes.
    file_size: u64,
    /// The footer checksum, which covers the whole table through the chain
    /// of checksums.
    footer_checksum: u32,

    pub const OpenError = error{
        /// The file is not a table, or it is damaged.
        Corrupt,
        /// The file is an intact table of a format version this code does
        /// not read.
        UnsupportedVersion,
        /// The table's index does not fit in the buffer given to `open`.
        IndexTooLarge,
    } || Io.File.OpenError || Io.File.LengthError || Io.File.ReadPositionalError;

    pub const ReadError = error{
        /// A data block is damaged.
        Corrupt,
    } || Io.File.ReadPositionalError;

    /// A forward-only cursor over every entry of a table, in the table's
    /// order: by key, and for one key from the newest entry to the oldest.
    /// Tombstones are included.
    pub const Iterator = struct {
        reader: *const Reader,
        /// Holds the current data block.
        buffer: []u8,
        /// The data block to read once the current one is used up.
        block_next: usize,
        /// The current data block. Empty until a block is read.
        block: Block,
        /// The entry of the current block that `next` returns next.
        entry_next: usize,

        /// Positions the cursor at the first entry. Nothing is read from the
        /// file until `next` is called.
        pub fn seekToFirst(self: *Iterator) void {
            self.block_next = 0;
            self.block = .empty;
            self.entry_next = 0;
        }

        /// Positions the cursor at the first entry whose key is >= `key`.
        /// If this fails, the cursor is left at the end of the table.
        pub fn seek(self: *Iterator, key: []const u8) ReadError!void {
            // The cursor goes to the end first. It stays there if every key
            // is smaller than `key`, or if anything below fails.
            self.block_next = self.reader.blockCount();
            self.block = .empty;
            self.entry_next = 0;

            const found = try self.reader.findBlock(key);
            if (found == null) {
                return;
            }
            const block_index = found.?;
            const block = try self.reader.readBlock(block_index, self.buffer);
            const entry_index = try lowerBoundInFoundBlock(block, key);

            self.block = block;
            self.block_next = block_index + 1;
            self.entry_next = entry_index;
        }

        /// Returns the entry at the cursor and advances past it, or returns
        /// `null` at the end of the table. The entry is valid until the next
        /// call on this iterator. If this fails, the cursor does not move.
        pub fn next(self: *Iterator) ReadError!?Entry {
            if (self.entry_next == self.block.entry_count) {
                if (self.block_next == self.reader.blockCount()) {
                    return null;
                }
                try self.readBlock(self.block_next);
            }

            const entry = try blockEntry(self.block, self.entry_next);
            self.entry_next += 1;

            if (entry.flags == .tombstone) {
                return .{ .key = entry.key, .value = null, .sequence = entry.sequence };
            }
            return .{ .key = entry.key, .value = entry.value, .sequence = entry.sequence };
        }

        /// Reads one data block and puts the cursor at its first entry.
        fn readBlock(self: *Iterator, block_index: usize) ReadError!void {
            // If the read fails, the cursor is left with no current block.
            self.block = .empty;
            self.entry_next = 0;

            self.block = try self.reader.readBlock(block_index, self.buffer);
            self.block_next = block_index + 1;
        }
    };

    /// Opens the table `name` in `dir`, checks its footer and index block,
    /// and loads the index into `index_buffer`. Data blocks are not read
    /// here. Each one is checked when `get` or an iterator reads it, so a
    /// successful open does not show that every data block is intact.
    ///
    /// The caller owns `index_buffer`, and it must stay valid until the
    /// reader is closed. See `indexSizeMax` for how long it has to be.
    pub fn open(io: Io, dir: Io.Dir, name: []const u8, index_buffer: []u8) OpenError!Reader {
        const file = try dir.openFile(io, name, .{ .mode = .read_only });
        errdefer file.close(io);

        const file_len = try file.length(io);
        if (file_len < footer_size) {
            return error.Corrupt;
        }
        const footer_offset = file_len - footer_size;

        var footer_bytes: [footer_size]u8 = undefined;
        const footer_read = try file.readPositionalAll(io, &footer_bytes, footer_offset);
        if (footer_read < footer_size) {
            return error.Corrupt;
        }
        const footer = try Footer.fromBytes(&footer_bytes);

        // The index block must end exactly where the footer starts.
        if (footer.index.len > footer_offset) {
            return error.Corrupt;
        }
        if (footer.index.offset != footer_offset - footer.index.len) {
            return error.Corrupt;
        }

        if (footer.index.len > index_buffer.len) {
            return error.IndexTooLarge;
        }
        const index_bytes = index_buffer[0..footer.index.len];
        const index_read = try file.readPositionalAll(io, index_bytes, footer.index.offset);
        if (index_read < index_bytes.len) {
            return error.Corrupt;
        }
        const index = try checkBlock(index_bytes, .index);
        if (index.header_checksum != footer.index.header_checksum) {
            return error.Corrupt;
        }
        try checkIndexEntries(index, footer);

        return .{
            .io = io,
            .file = file,
            .index = index,
            .block_len_max = footer.block_len_max,
            .file_size = file_len,
            .footer_checksum = footer.checksum,
        };
    }

    /// Closes the file. No cursor made from this reader may be used
    /// afterwards.
    pub fn close(self: *Reader) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// The length of the longest data block in this table, or zero if it has
    /// none. A buffer passed to `get` or `iterator` must be at least this
    /// long. The index block is not counted; it is in the buffer given to
    /// `open`.
    pub fn blockSizeMax(self: *const Reader) usize {
        return self.block_len_max;
    }

    /// The length of the file in bytes. Equal to `Writer.Summary.file_size`
    /// for the table that was written.
    pub fn fileSize(self: *const Reader) u64 {
        return self.file_size;
    }

    /// The footer checksum. Equal to `Writer.Summary.checksum` for the table
    /// that was written.
    pub fn checksum(self: *const Reader) u32 {
        return self.footer_checksum;
    }

    /// Looks up the newest entry for `key`, the one with the largest
    /// sequence number, reading at most one data block from the file into
    /// `block_buffer`. A returned value points into `block_buffer`.
    pub fn get(self: *const Reader, key: []const u8, block_buffer: []u8) ReadError!Lookup {
        assert(block_buffer.len >= self.block_len_max);

        const found = try self.findBlock(key);
        if (found == null) {
            return .absent;
        }
        const block = try self.readBlock(found.?, block_buffer);

        const entry_index = try lowerBoundInFoundBlock(block, key);
        const entry = try blockEntry(block, entry_index);
        if (!std.mem.eql(u8, entry.key, key)) {
            return .absent;
        }
        if (entry.flags == .tombstone) {
            return .tombstone;
        }
        return .{ .value = entry.value };
    }

    /// Returns a cursor positioned at the first entry. The cursor reads one
    /// data block at a time into `block_buffer`, which must stay valid for as
    /// long as the cursor is used. Each cursor needs its own buffer.
    ///
    /// The cursor keeps a pointer to this reader, so the reader must not be
    /// moved or closed while the cursor is in use.
    pub fn iterator(self: *const Reader, block_buffer: []u8) Iterator {
        assert(block_buffer.len >= self.block_len_max);
        return .{
            .reader = self,
            .buffer = block_buffer,
            .block_next = 0,
            .block = .empty,
            .entry_next = 0,
        };
    }

    /// How many data blocks the table has.
    fn blockCount(self: *const Reader) usize {
        return self.index.entry_count;
    }

    /// Returns the first data block whose last key is >= `key`. That is the
    /// only block that can hold the newest entry for `key`. Returns `null`
    /// if `key` is greater than every key in the table.
    fn findBlock(self: *const Reader, key: []const u8) error{Corrupt}!?usize {
        const block_index = try blockLowerBound(self.index, key, sequence_newest);
        if (block_index == self.blockCount()) {
            return null;
        }
        return block_index;
    }

    /// Reads one data block from the file into `buffer`, in a single read,
    /// and checks it.
    fn readBlock(self: *const Reader, block_index: usize, buffer: []u8) ReadError!Block {
        // `open` has checked that every index entry holds a block location
        // and that no block is longer than `block_len_max`.
        assert(buffer.len >= self.block_len_max);
        const index_entry = try blockEntry(self.index, block_index);
        const location = BlockLocation.fromBytes(index_entry.value[0..block_location_size]);

        const bytes = buffer[0..location.len];
        const bytes_read = try self.file.readPositionalAll(self.io, bytes, location.offset);
        if (bytes_read < bytes.len) {
            return error.Corrupt;
        }

        const block = try checkBlock(bytes, .data);
        if (block.header_checksum != location.header_checksum) {
            return error.Corrupt;
        }
        if (block.entry_count == 0) {
            return error.Corrupt;
        }

        // The block's entries must lie in the range the index gives it:
        // after the last entry of the block before it, and up to the entry
        // its own index entry names.
        const first_entry = try blockEntry(block, 0);
        const last_entry = try blockEntry(block, block.entry_count - 1);
        if (!std.mem.eql(u8, last_entry.key, index_entry.key)) {
            return error.Corrupt;
        }
        if (last_entry.sequence != index_entry.sequence) {
            return error.Corrupt;
        }
        if (block_index > 0) {
            const previous_index_entry = try blockEntry(self.index, block_index - 1);
            const previous_comes_first = sortsBefore(
                previous_index_entry.key,
                previous_index_entry.sequence,
                first_entry.key,
                first_entry.sequence,
            );
            if (!previous_comes_first) {
                return error.Corrupt;
            }
        }
        return block;
    }
};

/// Checks every entry of the index block. Each must hold a block location,
/// the data blocks they describe must lie back to back from the start of the
/// file to the index block, their last entries must be in order, and the longest of
/// them must be as long as the footer says.
fn checkIndexEntries(index: Block, footer: Footer) error{Corrupt}!void {
    var file_offset: u64 = 0;
    var block_len_largest: u32 = 0;
    var block_index: usize = 0;
    while (block_index < index.entry_count) {
        const entry = try blockEntry(index, block_index);
        if (entry.flags != .value) {
            return error.Corrupt;
        }
        if (entry.value.len != block_location_size) {
            return error.Corrupt;
        }

        const location = BlockLocation.fromBytes(entry.value[0..block_location_size]);
        if (location.offset != file_offset) {
            return error.Corrupt;
        }

        // Each data block ends after the block before it does.
        if (block_index > 0) {
            const previous = try blockEntry(index, block_index - 1);
            if (!sortsBefore(previous.key, previous.sequence, entry.key, entry.sequence)) {
                return error.Corrupt;
            }
        }

        if (location.len > block_len_largest) {
            block_len_largest = location.len;
        }
        file_offset += location.len;
        block_index += 1;
    }

    if (file_offset != footer.index.offset) {
        return error.Corrupt;
    }
    if (block_len_largest != footer.block_len_max) {
        return error.Corrupt;
    }
}

const testing = std.testing;
const test_name = "test.sst";

/// An index buffer of this size has room for a table holding `entries`,
/// whatever the block size. At worst every entry gets a block of its own.
fn testIndexSize(entries: []const Entry) usize {
    var size: usize = block_header_size;
    for (entries) |entry| {
        size += indexEntrySize(entry.key.len);
    }
    return size;
}

/// A block buffer of this size can hold any block of a table holding
/// `entries`, and is no larger than it has to be.
fn testBlockSize(options: Options, entries: []const Entry) usize {
    var size: usize = @max(options.block_size, block_header_size);
    for (entries) |entry| {
        var value_len: usize = 0;
        if (entry.value) |value| {
            value_len = value.len;
        }
        size = @max(size, blockSizeMax(options, entry.key.len, value_len));
    }
    return size;
}

/// Writes a table holding `entries`, replacing the test file if it exists.
/// The entries must be in the table's order: by key, and for one key from
/// the largest sequence number to the smallest.
fn writeTable(dir: Io.Dir, options: Options, entries: []const Entry) !Writer.Summary {
    const gpa = testing.allocator;
    const block_buffer = try gpa.alloc(u8, testBlockSize(options, entries));
    defer gpa.free(block_buffer);
    const index_buffer = try gpa.alloc(u8, testIndexSize(entries));
    defer gpa.free(index_buffer);

    dir.deleteFile(testing.io, test_name) catch {};
    const buffers: Writer.Buffers = .{ .block = block_buffer, .index = index_buffer };
    var writer: Writer = try .create(testing.io, dir, test_name, options, buffers);
    defer writer.close();

    for (entries) |entry| {
        try writer.add(entry.key, entry.value, entry.sequence);
    }
    return try writer.finish();
}

/// A reader of the test file, together with the buffers it needs.
const TestReader = struct {
    reader: Reader,
    index_buffer: []u8,
    get_buffer: []u8,
    iterator_buffer: []u8,

    fn open(dir: Io.Dir) !TestReader {
        const gpa = testing.allocator;

        // The index is part of the file, so it is never longer than the file.
        const file_len: usize = @intCast(try fileLength(dir));
        const index_buffer = try gpa.alloc(u8, file_len);
        errdefer gpa.free(index_buffer);

        var reader: Reader = try .open(testing.io, dir, test_name, index_buffer);
        errdefer reader.close();

        const get_buffer = try gpa.alloc(u8, reader.blockSizeMax());
        errdefer gpa.free(get_buffer);
        const iterator_buffer = try gpa.alloc(u8, reader.blockSizeMax());
        errdefer gpa.free(iterator_buffer);

        return .{
            .reader = reader,
            .index_buffer = index_buffer,
            .get_buffer = get_buffer,
            .iterator_buffer = iterator_buffer,
        };
    }

    fn close(self: *TestReader) void {
        const gpa = testing.allocator;
        self.reader.close();
        gpa.free(self.index_buffer);
        gpa.free(self.get_buffer);
        gpa.free(self.iterator_buffer);
    }

    fn get(self: *const TestReader, key: []const u8) !Lookup {
        return self.reader.get(key, self.get_buffer);
    }

    fn iterator(self: *const TestReader) Reader.Iterator {
        return self.reader.iterator(self.iterator_buffer);
    }
};

/// Checks that an iterator returned exactly `expected`: the same key, the
/// same sequence number, and the same value or a tombstone.
fn expectEntry(expected: Entry, actual: ?Entry) !void {
    try testing.expect(actual != null);
    try testing.expectEqualSlices(u8, expected.key, actual.?.key);
    try testing.expectEqual(expected.sequence, actual.?.sequence);
    if (expected.value) |expected_value| {
        try testing.expect(actual.?.value != null);
        try testing.expectEqualSlices(u8, expected_value, actual.?.value.?);
    } else {
        try testing.expect(actual.?.value == null);
    }
}

/// Checks that looking up the key of `expected` found exactly that entry.
/// A lookup does not report the sequence number, so it is not checked.
fn expectLookup(expected: Entry, lookup: Lookup) !void {
    if (expected.value) |expected_value| {
        try testing.expect(lookup == .value);
        try testing.expectEqualSlices(u8, expected_value, lookup.value);
    } else {
        try testing.expect(lookup == .tombstone);
    }
}

/// Checks that the test file holds exactly `entries`, by a full scan and by
/// looking up every key. `entries` is in the table's order, so the first
/// entry for a key is its newest, and that is the one a lookup must find.
fn expectTable(dir: Io.Dir, entries: []const Entry) !void {
    var table: TestReader = try .open(dir);
    defer table.close();

    var it = table.iterator();
    for (entries) |expected| {
        try expectEntry(expected, try it.next());
    }
    try testing.expect(try it.next() == null);
    try testing.expect(try it.next() == null);

    for (entries, 0..) |expected, entry_number| {
        var is_newest_for_key = true;
        if (entry_number > 0) {
            const previous = entries[entry_number - 1];
            is_newest_for_key = !std.mem.eql(u8, previous.key, expected.key);
        }
        if (is_newest_for_key) {
            try expectLookup(expected, try table.get(expected.key));
        }
    }
}

/// Opens the test file and reads every entry. Returns how many there are.
fn scanTable(dir: Io.Dir) !usize {
    var table: TestReader = try .open(dir);
    defer table.close();

    var it = table.iterator();
    var count: usize = 0;
    while (try it.next()) |_| {
        count += 1;
    }
    return count;
}

fn fileLength(dir: Io.Dir) !u64 {
    const file = try dir.openFile(testing.io, test_name, .{ .mode = .read_only });
    defer file.close(testing.io);
    return try file.length(testing.io);
}

fn setFileLength(dir: Io.Dir, len: u64) !void {
    const file = try dir.openFile(testing.io, test_name, .{ .mode = .write_only });
    defer file.close(testing.io);
    try file.setLength(testing.io, len);
}

/// Returns the bytes of the test file. The caller frees them.
fn readWholeFile(dir: Io.Dir) ![]u8 {
    const file = try dir.openFile(testing.io, test_name, .{ .mode = .read_only });
    defer file.close(testing.io);

    const len: usize = @intCast(try file.length(testing.io));
    const bytes = try testing.allocator.alloc(u8, len);
    errdefer testing.allocator.free(bytes);

    const bytes_read = try file.readPositionalAll(testing.io, bytes, 0);
    try testing.expectEqual(len, bytes_read);
    return bytes;
}

/// Makes the test file hold exactly `bytes`.
fn writeWholeFile(dir: Io.Dir, bytes: []const u8) !void {
    const file = try dir.openFile(testing.io, test_name, .{ .mode = .write_only });
    defer file.close(testing.io);
    try file.setLength(testing.io, bytes.len);
    try file.writePositionalAll(testing.io, bytes, 0);
}

/// Encodes a block header for `body`, working the checksums out from the
/// format's description and not by way of `BlockHeader`.
fn testBlockHeader(kind: u32, entry_count: u32, body: []const u8) [block_header_size]u8 {
    var bytes: [block_header_size]u8 = undefined;
    std.mem.writeInt(u32, bytes[4..8], crc32c(body), .little);
    std.mem.writeInt(u32, bytes[8..12], kind, .little);
    std.mem.writeInt(u32, bytes[12..16], entry_count, .little);
    std.mem.writeInt(u32, bytes[16..20], @intCast(body.len), .little);
    std.mem.writeInt(u32, bytes[0..4], crc32c(bytes[4..20]), .little);
    return bytes;
}

/// Where the sequence number is in an entry: after the flags (1 byte), the
/// key length (2 bytes) and the value length (4 bytes). It is the last 8
/// bytes of the entry header, so the key follows it. The number is counted
/// from the format's description and not taken from `EntryHeader`, so that
/// a test that uses it also checks where the header puts the field.
const test_sequence_offset = 7;

/// Reads the sequence number of the entry that starts at `entry_start` in
/// `bytes`, a whole table file.
fn readEntrySequence(bytes: []const u8, entry_start: usize) u64 {
    const sequence_bytes = bytes[entry_start + test_sequence_offset ..][0..8];
    return std.mem.readInt(u64, sequence_bytes, .little);
}

/// Overwrites the sequence number of the entry that starts at `entry_start`
/// in `bytes`, a whole table file.
fn writeEntrySequence(bytes: []u8, entry_start: usize, sequence: u64) void {
    const sequence_bytes = bytes[entry_start + test_sequence_offset ..][0..8];
    std.mem.writeInt(u64, sequence_bytes, sequence, .little);
}

/// Where the blocks are in a table that a test edits by hand. Every data
/// block has the same length, and every key is one byte long.
const TestLayout = struct {
    data_block_len: usize,
    data_block_count: usize,
};

/// An index entry whose key is one byte long: an entry header, the key, and
/// a block location. Its slot is not counted.
const test_index_entry_len = entrySize(1, block_location_size);

/// Gives a block's header the two checksums that its bytes now call for.
/// The kind, the entry count and the body length stay as they are. The
/// checksums are worked out from the format's description and not by way of
/// `BlockHeader`.
fn sealBlock(block: []u8) void {
    const body = block[block_header_size..];
    std.mem.writeInt(u32, block[4..8], crc32c(body), .little);
    std.mem.writeInt(u32, block[0..4], crc32c(block[4..20]), .little);
}

/// Gives the footer at the end of `bytes` the checksum that its bytes now
/// call for.
fn sealFooter(bytes: []u8) void {
    const footer = bytes[bytes.len - footer_size ..][0..footer_size];
    std.mem.writeInt(u32, footer[32..36], crc32c(footer[0..32]), .little);
}

/// Gives the index block its checksums, copies its header checksum into the
/// footer, and gives the footer its checksum. The data blocks, and the
/// header checksums the index holds for them, stay as they are.
fn sealIndexAndFooter(bytes: []u8, layout: TestLayout) void {
    const index_start = layout.data_block_len * layout.data_block_count;
    const footer_start = bytes.len - footer_size;

    const index_block = bytes[index_start..footer_start];
    sealBlock(index_block);

    // The index block's header checksum is at bytes 24 to 28 of the footer.
    const footer = bytes[footer_start..];
    @memcpy(footer[24..28], index_block[0..4]);
    sealFooter(bytes);
}

/// Gives every checksum in `bytes`, a whole table file, the value that its
/// bytes now call for. A test changes some bytes and then calls this, so
/// that the file is wrong only in its structure and no checksum notices.
///
/// The blocks are found by way of `layout` and not by way of the file's own
/// index and footer, because those may be what the test has changed.
fn sealTable(bytes: []u8, layout: TestLayout) void {
    const index_start = layout.data_block_len * layout.data_block_count;
    const index_body_start = index_start + block_header_size;

    var block_number: usize = 0;
    while (block_number < layout.data_block_count) {
        const block_start = block_number * layout.data_block_len;
        const block = bytes[block_start..][0..layout.data_block_len];
        sealBlock(block);

        // The index entry of this block ends with the block's header
        // checksum: the last 4 bytes of the entry.
        const index_entry_start = index_body_start + block_number * test_index_entry_len;
        const index_entry_end = index_entry_start + test_index_entry_len;
        const checksum_copy = bytes[index_entry_end - 4 ..][0..4];
        @memcpy(checksum_copy, block[0..4]);

        block_number += 1;
    }

    sealIndexAndFooter(bytes, layout);
}

/// The small table of the layout test: one data block, then the index block
/// with one entry, then the footer. The layout test spells out every byte.
const small_table_entries = [_]Entry{
    .{ .key = "a", .value = "1", .sequence = 0x0807060504030201 },
    .{ .key = "b", .value = null, .sequence = 0x1817161514131211 },
};
/// The data block of the small table: a block header, the entry for "a"
/// with its one-byte value, the tombstone for "b", and two slots.
const small_data_block_len = block_header_size + entrySize(1, 1) + entrySize(1, 0) + 2 * slot_size;
/// The index block of the small table: one entry for a one-byte key.
const small_index_block_len = indexSizeMax(1, 1);
const small_table_layout: TestLayout = .{
    .data_block_len = small_data_block_len,
    .data_block_count = 1,
};
const small_table_len = small_data_block_len + small_index_block_len + footer_size;
/// Where the parts of the small table start in the file.
const small_data_body_start = block_header_size;
const small_index_body_start = small_data_block_len + block_header_size;
const small_footer_start = small_data_block_len + small_index_block_len;

/// Writes the small table and returns the bytes of the file, for a test to
/// change by hand. The caller frees them.
fn smallTableBytes(dir: Io.Dir) ![]u8 {
    _ = try writeTable(dir, .{}, &small_table_entries);
    const bytes = try readWholeFile(dir);
    errdefer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, small_table_len), bytes.len);
    return bytes;
}

/// The length of a data block that holds four entries, each with a one-byte
/// key and an 8-byte value: the block header, and for each entry the entry
/// itself and its slot. With this as the block size, a table of eight such
/// entries has two data blocks that are exactly full.
const eight_data_block_len = block_header_size + 4 * (entrySize(1, 8) + slot_size);

/// The layout of a table of eight entries with one-byte keys and 8-byte
/// values, written with a block size of `eight_data_block_len`. The two data
/// blocks come first, back to back. The index block follows, with two
/// entries for one-byte keys, and then the footer.
const eight_table_layout: TestLayout = .{
    .data_block_len = eight_data_block_len,
    .data_block_count = 2,
};
const eight_index_block_len = indexSizeMax(2, 1);
const eight_table_len = 2 * eight_data_block_len + eight_index_block_len + footer_size;
const eight_index_body_start = 2 * eight_data_block_len + block_header_size;

/// Where one entry of the eight-entry table starts in the file. Both
/// numbers count from zero.
fn eightTableEntryOffset(block_number: usize, entry_number: usize) usize {
    const block_start = block_number * eight_table_layout.data_block_len;
    // Every entry has a 1-byte key and an 8-byte value.
    return block_start + block_header_size + entry_number * entrySize(1, 8);
}

/// Where the key of one entry of the eight-entry table is in the file.
/// Both numbers count from zero.
fn eightTableKeyOffset(block_number: usize, entry_number: usize) usize {
    const entry_start = eightTableEntryOffset(block_number, entry_number);
    return entry_start + entry_header_size;
}

/// Where one index entry of the eight-entry table starts in the file.
fn eightTableIndexEntryOffset(block_number: usize) usize {
    return eight_index_body_start + block_number * test_index_entry_len;
}

/// Where the key of one index entry of the eight-entry table is in the file.
fn eightTableIndexKeyOffset(block_number: usize) usize {
    const entry_start = eightTableIndexEntryOffset(block_number);
    return entry_start + entry_header_size;
}

/// Eight entries with the keys "a" to "h", each with a value of `value_len`
/// bytes. The values point into `value_bytes`. The entries are numbered in
/// key order: "a" has sequence number 1 and "h" has 8.
fn eightEntries(value_bytes: []const u8, value_len: usize) [8]Entry {
    const keys = "abcdefgh";
    var entries: [8]Entry = undefined;
    for (&entries, 0..) |*entry, i| {
        entry.key = keys[i..][0..1];
        entry.value = value_bytes[0..value_len];
        entry.sequence = i + 1;
    }
    return entries;
}

/// Eight entries for the one key "k", each with the 8-byte value `value`.
/// They are in the table's order, newest first: the first has sequence
/// number 8 and the last has 1.
fn eightVersions(value: *const [8]u8) [8]Entry {
    var entries: [8]Entry = undefined;
    for (&entries, 0..) |*entry, i| {
        entry.key = "k";
        entry.value = value;
        entry.sequence = 8 - i;
    }
    return entries;
}

/// Writes `entries` as a table with the eight-entry layout, and returns the
/// bytes of the file, for a test to change by hand. Every entry must have a
/// one-byte key and an 8-byte value. The caller frees the bytes.
fn eightTableBytes(dir: Io.Dir, entries: *const [8]Entry) ![]u8 {
    _ = try writeTable(dir, .{ .block_size = eight_data_block_len }, entries);
    const bytes = try readWholeFile(dir);
    errdefer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, eight_table_len), bytes.len);
    return bytes;
}

/// Expects `Reader.open` itself to reject the test file, before any data
/// block is read.
fn expectOpenCorrupt(dir: Io.Dir) !void {
    // The eight-entry table is the longest table that tests edit by hand,
    // and an index is never longer than its file, so the index always fits
    // in this buffer.
    var index_buffer: [eight_table_len]u8 = undefined;
    const result = Reader.open(testing.io, dir, test_name, &index_buffer);
    try testing.expectError(error.Corrupt, result);
}

test "an empty table has no entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const summary = try writeTable(tmp.dir, .{}, &.{});
    try testing.expectEqual(@as(u64, 0), summary.entry_count);
    // An index block with no entries, then the footer.
    try testing.expectEqual(@as(u64, block_header_size + footer_size), summary.file_size);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 0), table.reader.blockSizeMax());
    try testing.expect(try table.get("a") == .absent);
    try testing.expect(try table.get("") == .absent);

    var it = table.iterator();
    try testing.expect(try it.next() == null);
    try it.seek("a");
    try testing.expect(try it.next() == null);
    it.seekToFirst();
    try testing.expect(try it.next() == null);
}

test "entries are read back in order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .key = "apple", .value = "red", .sequence = 3 },
        .{ .key = "banana", .value = "yellow", .sequence = 1 },
        .{ .key = "cherry", .value = "dark red", .sequence = 2 },
    };
    const summary = try writeTable(tmp.dir, .{}, &entries);
    try testing.expectEqual(@as(u64, 3), summary.entry_count);
    try expectTable(tmp.dir, &entries);
}

test "the layout of a small table, byte for byte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Each sequence number has eight different bytes, so that the test pins
    // where the number is and that its lowest byte comes first.
    const entries = [_]Entry{
        .{ .key = "a", .value = "1", .sequence = 0x0807060504030201 },
        .{ .key = "b", .value = null, .sequence = 0x1817161514131211 },
    };
    _ = try writeTable(tmp.dir, .{}, &entries);

    var expected: [153]u8 = undefined;

    // The data block is bytes 0 to 61: a 20-byte header and a 41-byte body.
    // The first entry takes 15 + 1 + 1 = 17 bytes and the second takes
    // 15 + 1 = 16, so the second starts at byte 17 of the body.
    const data_body = [_]u8{
        0, 1, 0, 1, 0, 0, 0, // a value: key length 1, value length 1
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // sequence number
        'a', '1', // key and value
        1, 1, 0, 0, 0, 0, 0, // a tombstone: key length 1, value length 0
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, // sequence number
        'b', // key
        17, 0, 0, 0, // slot of the second entry
        0, 0, 0, 0, // slot of the first entry
    };
    const data_header = testBlockHeader(@backingInt(BlockKind.data), 2, &data_body);
    @memcpy(expected[0..20], &data_header);
    @memcpy(expected[20..61], &data_body);

    // The index block is bytes 61 to 117: a 20-byte header and a 36-byte
    // body. Its entry has the key and the sequence number of the last entry
    // of the data block.
    var index_body = [_]u8{
        0, 1, 0, 16, 0, 0, 0, // a value: key length 1, value length 16
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, // sequence number
        'b', // key
        0, 0, 0, 0, 0, 0, 0, 0, // data block offset
        61, 0, 0, 0, // data block length
        0, 0, 0, 0, // data block header checksum, filled in below
        0, 0, 0, 0, // slot of the only entry
    };
    // The checksum follows the entry header (15), the key (1), the offset
    // (8) and the length (4).
    @memcpy(index_body[28..32], data_header[0..4]);
    const index_header = testBlockHeader(@backingInt(BlockKind.index), 1, &index_body);
    @memcpy(expected[61..81], &index_header);
    @memcpy(expected[81..117], &index_body);

    // The footer is bytes 117 to 153.
    var footer = [_]u8{
        'b', 'e', 'a', 'n', 's', 's', 't', '1', // magic
        2, 0, 0, 0, // version
        61, 0, 0, 0, 0, 0, 0, 0, // index block offset
        56, 0, 0, 0, // index block length
        0, 0, 0, 0, // index block header checksum, filled in below
        61, 0, 0, 0, // largest data block length
        0, 0, 0, 0, // footer checksum, filled in below
    };
    @memcpy(footer[24..28], index_header[0..4]);
    std.mem.writeInt(u32, footer[32..36], crc32c(footer[0..32]), .little);
    @memcpy(expected[117..153], &footer);

    const actual = try readWholeFile(tmp.dir);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, &expected, actual);
}

test "the summary describes the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .key = "a", .value = "1", .sequence = 1 },
        .{ .key = "b", .value = null, .sequence = 2 },
        .{ .key = "c", .value = "3", .sequence = 3 },
    };
    const summary = try writeTable(tmp.dir, .{}, &entries);

    const bytes = try readWholeFile(tmp.dir);
    defer testing.allocator.free(bytes);
    const stored_checksum = std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little);

    try testing.expectEqual(@as(u64, 3), summary.entry_count);
    try testing.expectEqual(@as(u64, bytes.len), summary.file_size);
    try testing.expectEqual(stored_checksum, summary.checksum);

    // A reader of the same file reports the same size and checksum.
    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(summary.file_size, table.reader.fileSize());
    try testing.expectEqual(summary.checksum, table.reader.checksum());
}

test "a tombstone is found as a tombstone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .key = "a", .value = "1", .sequence = 1 },
        .{ .key = "b", .value = null, .sequence = 2 },
        .{ .key = "c", .value = "3", .sequence = 3 },
    };
    _ = try writeTable(tmp.dir, .{}, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expect(try table.get("b") == .tombstone);

    // The iterator returns the tombstone with its sequence number.
    var it = table.iterator();
    try it.seek("b");
    try expectEntry(entries[1], try it.next());
}

test "an empty value is not a tombstone, and the empty key is a key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .key = "", .value = "empty key", .sequence = 1 },
        .{ .key = "a", .value = "", .sequence = 2 },
    };
    _ = try writeTable(tmp.dir, .{}, &entries);
    try expectTable(tmp.dir, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    const lookup = try table.get("a");
    try testing.expect(lookup == .value);
    try testing.expectEqual(@as(usize, 0), lookup.value.len);
}

test "keys that are not in the table are absent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .key = "bb", .value = "1", .sequence = 1 },
        .{ .key = "dd", .value = "2", .sequence = 2 },
    };
    _ = try writeTable(tmp.dir, .{}, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expect(try table.get("") == .absent);
    try testing.expect(try table.get("a") == .absent);
    try testing.expect(try table.get("b") == .absent);
    try testing.expect(try table.get("bbb") == .absent);
    try testing.expect(try table.get("cc") == .absent);
    try testing.expect(try table.get("ddd") == .absent);
    try testing.expect(try table.get("z") == .absent);
}

test "every entry for one key is returned, newest first, and get finds the newest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .key = "a", .value = "a4", .sequence = 4 },
        .{ .key = "b", .value = "b9", .sequence = 9 },
        .{ .key = "b", .value = "b7", .sequence = 7 },
        .{ .key = "b", .value = "b2", .sequence = 2 },
        .{ .key = "c", .value = "c1", .sequence = 1 },
    };
    const summary = try writeTable(tmp.dir, .{}, &entries);
    try testing.expectEqual(@as(u64, 5), summary.entry_count);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();

    // The iterator returns all three entries for "b", with their sequence
    // numbers, from the largest to the smallest.
    var it = table.iterator();
    try expectEntry(entries[0], try it.next());
    try expectEntry(entries[1], try it.next());
    try expectEntry(entries[2], try it.next());
    try expectEntry(entries[3], try it.next());
    try expectEntry(entries[4], try it.next());
    try testing.expect(try it.next() == null);

    const lookup = try table.get("b");
    try testing.expect(lookup == .value);
    try testing.expectEqualSlices(u8, "b9", lookup.value);

    // A seek to the key lands on its newest entry.
    try it.seek("b");
    try expectEntry(entries[1], try it.next());
    try expectEntry(entries[2], try it.next());
}

test "get returns a tombstone that is newer than a value for the same key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .key = "a", .value = "a1", .sequence = 1 },
        .{ .key = "b", .value = null, .sequence = 8 },
        .{ .key = "b", .value = "b5", .sequence = 5 },
        .{ .key = "c", .value = "c2", .sequence = 2 },
    };
    _ = try writeTable(tmp.dir, .{}, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expect(try table.get("b") == .tombstone);

    // The iterator still returns the older value, after the tombstone.
    var it = table.iterator();
    try it.seek("b");
    try expectEntry(entries[1], try it.next());
    try expectEntry(entries[2], try it.next());
    try expectEntry(entries[3], try it.next());
    try testing.expect(try it.next() == null);
}

test "get returns a value that is newer than a tombstone for the same key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .key = "a", .value = "a1", .sequence = 1 },
        .{ .key = "b", .value = "b8", .sequence = 8 },
        .{ .key = "b", .value = null, .sequence = 5 },
        .{ .key = "c", .value = "c2", .sequence = 2 },
    };
    _ = try writeTable(tmp.dir, .{}, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    const lookup = try table.get("b");
    try testing.expect(lookup == .value);
    try testing.expectEqualSlices(u8, "b8", lookup.value);

    // The iterator still returns the older tombstone, after the value.
    var it = table.iterator();
    try it.seek("b");
    try expectEntry(entries[1], try it.next());
    try expectEntry(entries[2], try it.next());
    try expectEntry(entries[3], try it.next());
    try testing.expect(try it.next() == null);
}

/// The length of a data block that holds two entries, each with a one-byte
/// key and a 2-byte value. With this as the block size, a table of such
/// entries has two entries in every data block.
const pair_block_len = block_header_size + 2 * (entrySize(1, 2) + slot_size);

test "entries for one key that start at the end of a block and go on in the next are all found" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two entries fill a block, so the blocks hold "a" and the newest "k",
    // then the two older entries for "k", then "m".
    const entries = [_]Entry{
        .{ .key = "a", .value = "a3", .sequence = 3 },
        .{ .key = "k", .value = "k9", .sequence = 9 },
        .{ .key = "k", .value = "k6", .sequence = 6 },
        .{ .key = "k", .value = "k2", .sequence = 2 },
        .{ .key = "m", .value = "m5", .sequence = 5 },
    };
    _ = try writeTable(tmp.dir, .{ .block_size = pair_block_len }, &entries);
    try expectTable(tmp.dir, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 3), table.reader.blockCount());

    // The newest entry for "k" is the last entry of the first block. The
    // second block holds only older entries for "k".
    const lookup = try table.get("k");
    try testing.expect(lookup == .value);
    try testing.expectEqualSlices(u8, "k9", lookup.value);

    // A seek lands on the newest entry, and the iterator then crosses into
    // the second block and the third.
    var it = table.iterator();
    try it.seek("k");
    try expectEntry(entries[1], try it.next());
    try expectEntry(entries[2], try it.next());
    try expectEntry(entries[3], try it.next());
    try expectEntry(entries[4], try it.next());
    try testing.expect(try it.next() == null);

    // A key between "k" and "m" is absent, and a seek to it skips every
    // entry for "k".
    try testing.expect(try table.get("l") == .absent);
    try it.seek("l");
    try expectEntry(entries[4], try it.next());
    try testing.expect(try it.next() == null);
}

test "entries for one key that fill a block and go on in the next are all found" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two entries fill a block, so the blocks hold "a" and "b", then the two
    // newest entries for "k", then the oldest entry for "k" and "m". The
    // first two blocks both end with an entry for "k".
    const entries = [_]Entry{
        .{ .key = "a", .value = "a3", .sequence = 3 },
        .{ .key = "b", .value = "b4", .sequence = 4 },
        .{ .key = "k", .value = "k9", .sequence = 9 },
        .{ .key = "k", .value = "k6", .sequence = 6 },
        .{ .key = "k", .value = "k2", .sequence = 2 },
        .{ .key = "m", .value = "m5", .sequence = 5 },
    };
    _ = try writeTable(tmp.dir, .{ .block_size = pair_block_len }, &entries);
    try expectTable(tmp.dir, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 3), table.reader.blockCount());

    const lookup = try table.get("k");
    try testing.expect(lookup == .value);
    try testing.expectEqualSlices(u8, "k9", lookup.value);

    var it = table.iterator();
    try it.seek("k");
    try expectEntry(entries[2], try it.next());
    try expectEntry(entries[3], try it.next());
    try expectEntry(entries[4], try it.next());
    try expectEntry(entries[5], try it.next());
    try testing.expect(try it.next() == null);
}

test "a table that holds only entries for one key, in two blocks, is read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Both data blocks end with an entry for "k", so the two index entries
    // have the same key and differ only in their sequence numbers.
    const entries = eightVersions("12345678");
    const bytes = try eightTableBytes(tmp.dir, &entries);
    defer testing.allocator.free(bytes);
    try expectTable(tmp.dir, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 2), table.reader.blockCount());

    var it = table.iterator();
    try it.seek("k");
    try expectEntry(entries[0], try it.next());

    try testing.expect(try table.get("j") == .absent);
    try testing.expect(try table.get("l") == .absent);
}

test "the smallest and the largest sequence numbers are written and read back" {
    const sequence_max = std.math.maxInt(u64);
    const entries = [_]Entry{
        .{ .key = "a", .value = "newest", .sequence = sequence_max },
        .{ .key = "a", .value = "oldest", .sequence = 0 },
        .{ .key = "b", .value = "zero", .sequence = 0 },
        .{ .key = "c", .value = "max", .sequence = sequence_max },
    };

    // With the first block size every entry gets a block of its own, so
    // each sequence number is also the one in an index entry. With the
    // second, all four entries are in one block.
    const block_sizes = [_]u32{ 48, block_size };
    const block_counts = [_]usize{ 4, 1 };
    for (block_sizes, block_counts) |table_block_size, block_count| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        _ = try writeTable(tmp.dir, .{ .block_size = table_block_size }, &entries);
        try expectTable(tmp.dir, &entries);

        var table: TestReader = try .open(tmp.dir);
        defer table.close();
        try testing.expectEqual(block_count, table.reader.blockCount());

        // A search looks for the largest sequence number, so an entry that
        // has that number must still be found.
        const lookup_a = try table.get("a");
        try testing.expect(lookup_a == .value);
        try testing.expectEqualSlices(u8, "newest", lookup_a.value);

        const lookup_c = try table.get("c");
        try testing.expect(lookup_c == .value);
        try testing.expectEqualSlices(u8, "max", lookup_c.value);

        var it = table.iterator();
        try it.seek("a");
        try expectEntry(entries[0], try it.next());
        try expectEntry(entries[1], try it.next());
        try it.seek("c");
        try expectEntry(entries[3], try it.next());
        try testing.expect(try it.next() == null);
    }
}

test "a block that fills its buffer exactly is written correctly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Each entry takes 15 + 1 + 8 bytes and a 4-byte slot, so four of them
    // and the 20-byte block header come to exactly 132 bytes. The writer's
    // block buffer is also 132 bytes, so it has no free space left when the
    // block is finished.
    try testing.expectEqual(@as(usize, 132), eight_data_block_len);
    const entries = eightEntries("12345678", 8);
    _ = try writeTable(tmp.dir, .{ .block_size = eight_data_block_len }, &entries);
    try expectTable(tmp.dir, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 2), table.reader.blockCount());
    try testing.expectEqual(@as(usize, eight_data_block_len), table.reader.blockSizeMax());
}

test "a block that nearly fills its buffer is written correctly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The values are one byte shorter than the block size is made for, so
    // four entries make a block of 128 bytes in a buffer of 132. The free
    // space is 4 bytes and the slots take 16, so the slots overlap their own
    // destination when they are moved.
    const entries = eightEntries("1234567", 7);
    _ = try writeTable(tmp.dir, .{ .block_size = eight_data_block_len }, &entries);
    try expectTable(tmp.dir, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 2), table.reader.blockCount());
    try testing.expectEqual(@as(usize, eight_data_block_len - 4), table.reader.blockSizeMax());
}

test "an entry that would take a block one byte past the block size starts a new block" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Three entries of 15 + 1 + 8 bytes, their slots and the 20-byte block
    // header come to 104 bytes. A fourth entry like them would fill the
    // block exactly, to 132 bytes. But the fourth entry is one byte longer:
    // it takes 25 bytes and a 4-byte slot, which would make the block 133
    // bytes.
    const entries = [_]Entry{
        .{ .key = "a", .value = "12345678", .sequence = 1 },
        .{ .key = "b", .value = "12345678", .sequence = 2 },
        .{ .key = "c", .value = "12345678", .sequence = 3 },
        .{ .key = "d", .value = "123456789", .sequence = 4 },
    };
    _ = try writeTable(tmp.dir, .{ .block_size = eight_data_block_len }, &entries);
    try expectTable(tmp.dir, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 2), table.reader.blockCount());
    const three_entry_block_len = block_header_size + 3 * (entrySize(1, 8) + slot_size);
    try testing.expectEqual(@as(usize, three_entry_block_len), table.reader.blockSizeMax());
}

test "an entry larger than a block gets a block to itself" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const large_value: [1000]u8 = @splat('x');
    const entries = [_]Entry{
        .{ .key = "a", .value = "1", .sequence = 1 },
        .{ .key = "b", .value = &large_value, .sequence = 2 },
        .{ .key = "c", .value = "3", .sequence = 3 },
    };
    _ = try writeTable(tmp.dir, .{ .block_size = 64 }, &entries);
    try expectTable(tmp.dir, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 3), table.reader.blockCount());
    const large_block_size = block_header_size + entry_header_size + 1 + 1000 + slot_size;
    try testing.expectEqual(@as(usize, large_block_size), table.reader.blockSizeMax());
}

test "seek positions the cursor at the first key at or after the target" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // An entry takes 15 + 1 + 1 bytes and a 4-byte slot, so a block with one
    // entry is 41 bytes and a second entry would make it 62. A block size of
    // 48 therefore gives every entry a block of its own, so these seeks also
    // cross from one block to the next.
    const entries = [_]Entry{
        .{ .key = "b", .value = "1", .sequence = 1 },
        .{ .key = "d", .value = "2", .sequence = 2 },
        .{ .key = "f", .value = "3", .sequence = 3 },
    };
    _ = try writeTable(tmp.dir, .{ .block_size = 48 }, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 3), table.reader.blockCount());
    var it = table.iterator();

    // Before the first key.
    try it.seek("a");
    try expectEntry(entries[0], try it.next());

    // Exactly on a key.
    try it.seek("d");
    try expectEntry(entries[1], try it.next());
    try expectEntry(entries[2], try it.next());
    try testing.expect(try it.next() == null);

    // Between two keys, just after the last key of the first block.
    try it.seek("c");
    try expectEntry(entries[1], try it.next());

    // After the last key.
    try it.seek("g");
    try testing.expect(try it.next() == null);

    // Back to the start.
    it.seekToFirst();
    try expectEntry(entries[0], try it.next());

    // Back to the start from the middle of the table.
    try it.seek("d");
    try expectEntry(entries[1], try it.next());
    it.seekToFirst();
    try expectEntry(entries[0], try it.next());
    try expectEntry(entries[1], try it.next());
    try expectEntry(entries[2], try it.next());
    try testing.expect(try it.next() == null);
}

test "two iterators and get do not disturb each other" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A block size of 48 gives every entry a block of its own.
    const entries = [_]Entry{
        .{ .key = "a", .value = "1", .sequence = 1 },
        .{ .key = "b", .value = "2", .sequence = 2 },
        .{ .key = "c", .value = "3", .sequence = 3 },
        .{ .key = "d", .value = "4", .sequence = 4 },
    };
    _ = try writeTable(tmp.dir, .{ .block_size = 48 }, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 4), table.reader.blockCount());

    const second_buffer = try testing.allocator.alloc(u8, table.reader.blockSizeMax());
    defer testing.allocator.free(second_buffer);

    var first = table.iterator();
    var second = table.reader.iterator(second_buffer);
    try second.seek("c");

    const first_entry = try first.next();
    const second_entry = try second.next();
    try expectLookup(entries[3], try table.get("d"));

    // Both entries are still intact after the other reads.
    try expectEntry(entries[0], first_entry);
    try expectEntry(entries[2], second_entry);

    try expectEntry(entries[1], try first.next());
    try expectEntry(entries[3], try second.next());
    try expectEntry(entries[2], try first.next());
    try testing.expect(try second.next() == null);
}

/// Overwrites one byte of the test file.
fn writeByte(dir: Io.Dir, offset: u64, byte: u8) !void {
    const file = try dir.openFile(testing.io, test_name, .{ .mode = .write_only });
    defer file.close(testing.io);
    const bytes = [1]u8{byte};
    try file.writePositionalAll(testing.io, &bytes, offset);
}

test "next keeps failing at a damaged block, and carries on once the block is whole again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two blocks that are exactly full, four entries each.
    const entries = eightEntries("12345678", 8);
    _ = try writeTable(tmp.dir, .{ .block_size = eight_data_block_len }, &entries);
    const original = try readWholeFile(tmp.dir);
    defer testing.allocator.free(original);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 2), table.reader.blockCount());

    var it = table.iterator();
    for (entries[0..4]) |expected| {
        try expectEntry(expected, try it.next());
    }

    // Damage one value byte of the first entry of the second block. The
    // value follows the entry's one-byte key.
    const damage_offset = eightTableKeyOffset(1, 0) + 1 + 2;
    try writeByte(tmp.dir, damage_offset, ~original[damage_offset]);

    try testing.expectError(error.Corrupt, it.next());
    // The cursor must not serve entries of the first block out of a buffer
    // that now holds the damaged block.
    try testing.expectError(error.Corrupt, it.next());

    // The cursor did not move, so it reads the same block again.
    try writeByte(tmp.dir, damage_offset, original[damage_offset]);
    for (entries[4..8]) |expected| {
        try expectEntry(expected, try it.next());
    }
    try testing.expect(try it.next() == null);
}

test "after a failed seek the cursor is at the end of the table" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two blocks that are exactly full, four entries each.
    const entries = eightEntries("12345678", 8);
    _ = try writeTable(tmp.dir, .{ .block_size = eight_data_block_len }, &entries);
    const original = try readWholeFile(tmp.dir);
    defer testing.allocator.free(original);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    var it = table.iterator();

    // The cursor is in the middle of the first block, which is intact.
    try expectEntry(entries[0], try it.next());
    try expectEntry(entries[1], try it.next());

    // Damage one value byte of the first entry of the second block. The
    // value follows the entry's one-byte key.
    const damage_offset = eightTableKeyOffset(1, 0) + 1 + 2;
    try writeByte(tmp.dir, damage_offset, ~original[damage_offset]);

    // "f" is in the second block. The cursor must not stay where it was,
    // and must not go on to read the block after its old position.
    try testing.expectError(error.Corrupt, it.seek("f"));
    try testing.expect(try it.next() == null);
    try testing.expect(try it.next() == null);

    // A seek that succeeds makes the cursor usable again.
    try it.seek("c");
    try expectEntry(entries[2], try it.next());
}

test "create fails if the file exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try writeTable(tmp.dir, .{}, &.{});

    var block_buffer: [1024]u8 = undefined;
    var index_buffer: [1024]u8 = undefined;
    const buffers: Writer.Buffers = .{ .block = &block_buffer, .index = &index_buffer };
    const options: Options = .{ .block_size = 1024 };
    const result = Writer.create(testing.io, tmp.dir, test_name, options, buffers);
    try testing.expectError(error.PathAlreadyExists, result);
}

test "a key and a value of exactly the longest size are accepted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const key: [key_size_max]u8 = @splat('k');
    const value = try testing.allocator.alloc(u8, value_size_max);
    defer testing.allocator.free(value);
    @memset(value, 'v');

    const entries = [_]Entry{
        .{ .key = &key, .value = value, .sequence = 1 },
    };
    _ = try writeTable(tmp.dir, .{}, &entries);
    try expectTable(tmp.dir, &entries);
}

test "an entry that does not fit in the block buffer is rejected and the writer stays usable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var block_buffer: [64]u8 = undefined;
    var index_buffer: [1024]u8 = undefined;
    const buffers: Writer.Buffers = .{ .block = &block_buffer, .index = &index_buffer };
    const options: Options = .{ .block_size = 64 };
    var writer: Writer = try .create(testing.io, tmp.dir, test_name, options, buffers);
    defer writer.close();

    // With a 64-byte buffer and a one-byte key, the largest value that fits
    // is 24 bytes: 20 (block header) + 15 (entry header) + 1 + 24 + 4 (slot).
    const too_large_value: [25]u8 = @splat('x');
    const largest_value: [24]u8 = @splat('y');

    // The rejected entry arrives while a block is partly filled.
    try writer.add("a", "1", 1);
    try testing.expectError(error.EntryTooLarge, writer.add("b", &too_large_value, 2));
    try writer.add("c", &largest_value, 3);
    _ = try writer.finish();

    const entries = [_]Entry{
        .{ .key = "a", .value = "1", .sequence = 1 },
        .{ .key = "c", .value = &largest_value, .sequence = 3 },
    };
    try expectTable(tmp.dir, &entries);
}

test "a full index rejects an entry that would start a new block" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A block size of 48 gives every entry a block of its own: a block with
    // one of these entries is 41 bytes, and a second would make it 62. The
    // index buffer has room for exactly two data blocks whose last keys are
    // one byte long.
    var block_buffer: [48]u8 = undefined;
    var index_buffer: [indexSizeMax(2, 1)]u8 = undefined;
    const buffers: Writer.Buffers = .{ .block = &block_buffer, .index = &index_buffer };
    const options: Options = .{ .block_size = 48 };
    var writer: Writer = try .create(testing.io, tmp.dir, test_name, options, buffers);
    defer writer.close();

    try writer.add("a", "1", 1);
    try writer.add("b", "2", 2);
    // Adding this would close the second block and start a third.
    try testing.expectError(error.TableFull, writer.add("c", "3", 3));
    _ = try writer.finish();

    const entries = [_]Entry{
        .{ .key = "a", .value = "1", .sequence = 1 },
        .{ .key = "b", .value = "2", .sequence = 2 },
    };
    try expectTable(tmp.dir, &entries);
}

test "a full index rejects an entry whose key would not fit in it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The index buffer has room for one data block whose last key is one
    // byte long.
    var block_buffer: [1024]u8 = undefined;
    var index_buffer: [indexSizeMax(1, 1)]u8 = undefined;
    const buffers: Writer.Buffers = .{ .block = &block_buffer, .index = &index_buffer };
    const options: Options = .{ .block_size = 1024 };
    var writer: Writer = try .create(testing.io, tmp.dir, test_name, options, buffers);
    defer writer.close();

    try writer.add("a", "1", 1);
    // This would go into the same block, but the block's last key would then
    // be two bytes long.
    try testing.expectError(error.TableFull, writer.add("bb", "2", 2));
    try writer.add("c", "3", 3);
    _ = try writer.finish();

    const entries = [_]Entry{
        .{ .key = "a", .value = "1", .sequence = 1 },
        .{ .key = "c", .value = "3", .sequence = 3 },
    };
    try expectTable(tmp.dir, &entries);
}

test "open fails if the index does not fit in the buffer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .key = "a", .value = "1", .sequence = 1 },
    };
    _ = try writeTable(tmp.dir, .{}, &entries);

    // The index block is a header and one entry for a one-byte key.
    const index_block_len = comptime indexSizeMax(1, 1);

    var small_buffer: [index_block_len - 1]u8 = undefined;
    const result = Reader.open(testing.io, tmp.dir, test_name, &small_buffer);
    try testing.expectError(error.IndexTooLarge, result);

    var exact_buffer: [index_block_len]u8 = undefined;
    var reader: Reader = try .open(testing.io, tmp.dir, test_name, &exact_buffer);
    reader.close();
}

test "blockSizeMax is the block size or one large entry, whichever is larger" {
    const options: Options = .{ .block_size = 4096 };
    try testing.expectEqual(@as(usize, 4096), blockSizeMax(options, 16, 100));

    const large_block_size = block_header_size + entry_header_size + 16 + 10_000 + slot_size;
    try testing.expectEqual(@as(usize, large_block_size), blockSizeMax(options, 16, 10_000));
}

test "blockCountMax covers a table whose blocks are each just over half full" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Each entry takes 15 + 2 + 20 bytes and a 4-byte slot: 41 bytes. With a
    // block size of 100, a block has 80 bytes for entries, so one entry
    // leaves room for 39 more bytes and the next entry does not fit. Every
    // entry gets a block of its own, which is the most blocks a table of
    // this size can have.
    const options: Options = .{ .block_size = 100 };
    const keys = "00010203040506070809101112131415161718192021222324252627282930313233343536373839";
    const value: [20]u8 = @splat('v');
    var entries: [40]Entry = undefined;
    for (&entries, 0..) |*entry, i| {
        entry.key = keys[i * 2 ..][0..2];
        entry.value = &value;
        entry.sequence = i + 1;
    }
    const entry_size_with_slot = entrySize(2, value.len) + slot_size;
    try testing.expectEqual(@as(usize, 41), entry_size_with_slot);
    _ = try writeTable(tmp.dir, options, &entries);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectEqual(@as(usize, 40), table.reader.blockCount());

    // 40 entries of 41 bytes are 1640 bytes: 2 * 1640 / 80 + 1.
    const entries_size = entries.len * entry_size_with_slot;
    try testing.expectEqual(@as(usize, 42), blockCountMax(options, entries_size));
    try testing.expect(table.reader.blockCount() <= blockCountMax(options, entries_size));
}

test "indexSizeMax is a block header and one largest index entry for each data block" {
    // With no data blocks the index block is only its 20-byte header.
    try testing.expectEqual(@as(usize, 20), indexSizeMax(0, 10));

    // An index entry for a one-byte key takes 15 (entry header) + 1 (key) +
    // 16 (block location) + 4 (slot) = 36 bytes. Three of them and the
    // header come to 20 + 3 * 36 = 128 bytes.
    try testing.expectEqual(@as(usize, 128), indexSizeMax(3, 1));

    // For a ten-byte key the entry takes 15 + 10 + 16 + 4 = 45 bytes. Two of
    // them and the header come to 20 + 2 * 45 = 110 bytes.
    try testing.expectEqual(@as(usize, 110), indexSizeMax(2, 10));
}

test "an index buffer of indexSizeMax is exactly enough when every entry gets its own block" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Every key has the longest length, 3 bytes, so the index buffer has no
    // byte to spare. An entry takes 15 + 3 + 1 bytes and a 4-byte slot, so a
    // block with one entry is 43 bytes and a second entry would make it 66.
    // A block size of 48 therefore gives every entry a block of its own.
    const entries = [_]Entry{
        .{ .key = "aaa", .value = "1", .sequence = 1 },
        .{ .key = "bbb", .value = "2", .sequence = 2 },
        .{ .key = "ccc", .value = "3", .sequence = 3 },
    };
    const index_size = indexSizeMax(entries.len, 3);
    const index_buffer = try testing.allocator.alloc(u8, index_size);
    defer testing.allocator.free(index_buffer);

    var block_buffer: [48]u8 = undefined;
    const buffers: Writer.Buffers = .{ .block = &block_buffer, .index = index_buffer };
    const options: Options = .{ .block_size = 48 };
    var writer: Writer = try .create(testing.io, tmp.dir, test_name, options, buffers);
    defer writer.close();

    for (entries) |entry| {
        try writer.add(entry.key, entry.value, entry.sequence);
    }
    // The index buffer is full now: a fourth data block does not fit.
    try testing.expectError(error.TableFull, writer.add("ddd", "4", 4));
    _ = try writer.finish();

    try expectTable(tmp.dir, &entries);

    // A reader can open the table with an index buffer of the same size.
    const reader_index_buffer = try testing.allocator.alloc(u8, index_size);
    defer testing.allocator.free(reader_index_buffer);
    var reader: Reader = try .open(testing.io, tmp.dir, test_name, reader_index_buffer);
    defer reader.close();
    try testing.expectEqual(@as(usize, 3), reader.blockCount());
}

const key_alphabet = "ab\x00\xff";

/// Whether `a` comes before `b` in a table: its key is smaller, or the keys
/// are the same and its sequence number is larger. This is the model's own
/// statement of the order, and does not use the table's.
fn modelSortsBefore(_: void, a: Entry, b: Entry) bool {
    const key_order = std.mem.order(u8, a.key, b.key);
    if (key_order == .lt) {
        return true;
    }
    if (key_order == .gt) {
        return false;
    }
    return a.sequence > b.sequence;
}

/// A random key. A small alphabet makes shared prefixes common.
fn randomKey(arena: std.mem.Allocator, random: std.Random, entry_number: usize) ![]u8 {
    var key_len: usize = random.uintAtMost(usize, 40);
    if (entry_number == 0) {
        key_len = 0;
    }
    if (entry_number % 97 == 1) {
        key_len = random.uintAtMost(usize, key_size_max);
    }

    const key = try arena.alloc(u8, key_len);
    for (key) |*byte| {
        byte.* = key_alphabet[random.uintLessThan(usize, key_alphabet.len)];
    }
    return key;
}

/// A random value: sometimes a tombstone, sometimes empty, now and then
/// larger than a block.
fn randomValue(arena: std.mem.Allocator, random: std.Random, entry_number: usize) !?[]u8 {
    const kind = random.uintLessThan(u8, 10);
    if (kind < 2) {
        return null;
    }

    var value_len: usize = 0;
    if (kind > 2) {
        value_len = random.uintAtMost(usize, 200);
    }
    if (entry_number % 53 == 2) {
        value_len = random.uintAtMost(usize, 5000);
    }

    const value = try arena.alloc(u8, value_len);
    random.bytes(value);
    return value;
}

/// The key of model entry number `entry_number`, given the entries made
/// before it. One time in three it is the key of an earlier entry, so that
/// the model holds several entries for many of its keys. Otherwise it is a
/// new random key.
fn modelKey(
    arena: std.mem.Allocator,
    random: std.Random,
    earlier_entries: []const Entry,
    entry_number: usize,
) ![]const u8 {
    var reuses_a_key = false;
    if (earlier_entries.len > 0) {
        reuses_a_key = random.uintLessThan(u8, 3) == 0;
    }
    if (reuses_a_key) {
        const earlier_number = random.uintLessThan(usize, earlier_entries.len);
        return earlier_entries[earlier_number].key;
    }
    return try randomKey(arena, random, entry_number);
}

/// Builds a list of `count` random entries in the table's order: by key,
/// and for one key from the largest sequence number to the smallest. Many
/// keys have several entries. Every entry has a different sequence number.
/// Everything is allocated from `arena`.
fn makeModel(arena: std.mem.Allocator, seed: u64, count: usize) ![]Entry {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    // Every sequence number from 1 to `count`, in a random order, so that
    // the order in which the entries for a key are made says nothing about
    // which of them is the newest.
    const sequences = try arena.alloc(u64, count);
    for (sequences, 1..) |*sequence, number| {
        sequence.* = number;
    }
    random.shuffle(u64, sequences);

    const entries = try arena.alloc(Entry, count);
    for (entries, 0..) |*entry, entry_number| {
        const earlier_entries = entries[0..entry_number];
        entry.key = try modelKey(arena, random, earlier_entries, entry_number);
        entry.value = try randomValue(arena, random, entry_number);
        entry.sequence = sequences[entry_number];
    }
    std.mem.sort(Entry, entries, {}, modelSortsBefore);
    return entries;
}

/// Returns the number of the first model entry whose key is >= `key`. When
/// the model has entries for `key`, that is the newest of them.
fn modelLowerBound(model: []const Entry, key: []const u8) usize {
    var low: usize = 0;
    var high: usize = model.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (std.mem.order(u8, model[middle].key, key) == .lt) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

/// A key to look up: half the time a random short key, and half the time a
/// key from the model, as it is or one byte longer or one byte shorter.
fn randomProbe(random: std.Random, model: []const Entry, buffer: []u8) []u8 {
    const near_a_key = model.len > 0 and random.boolean();
    if (!near_a_key) {
        const probe = buffer[0..random.uintAtMost(usize, 12)];
        for (probe) |*byte| {
            byte.* = key_alphabet[random.uintLessThan(usize, key_alphabet.len)];
        }
        return probe;
    }

    const base = model[random.uintLessThan(usize, model.len)].key;
    @memcpy(buffer[0..base.len], base);
    buffer[base.len] = key_alphabet[random.uintLessThan(usize, key_alphabet.len)];

    const change = random.uintLessThan(u8, 3);
    if (change == 0) {
        return buffer[0..base.len];
    }
    if (change == 1) {
        return buffer[0 .. base.len + 1];
    }
    if (base.len == 0) {
        return buffer[0..0];
    }
    return buffer[0 .. base.len - 1];
}

/// Looks up and seeks to many keys, present and absent, and checks the
/// results against the model.
fn expectProbes(dir: Io.Dir, model: []const Entry, seed: u64) !void {
    var table: TestReader = try .open(dir);
    defer table.close();
    var it = table.iterator();

    var prng: std.Random.DefaultPrng = .init(seed ^ 0x5eed);
    const random = prng.random();
    // The longest probe is a model key with one more byte after it.
    var probe_buffer: [key_size_max + 1]u8 = undefined;

    for (0..2000) |_| {
        const probe = randomProbe(random, model, &probe_buffer);
        const model_index = modelLowerBound(model, probe);

        var is_present = false;
        if (model_index < model.len) {
            is_present = std.mem.eql(u8, model[model_index].key, probe);
        }

        // A lookup finds the newest entry for the key, which is the first
        // of the model's entries for it.
        const lookup = try table.get(probe);
        if (is_present) {
            try expectLookup(model[model_index], lookup);
        } else {
            try testing.expect(lookup == .absent);
        }

        // The three entries after a seek must be the next three of the
        // model, older entries for the same key included.
        try it.seek(probe);
        var offset: usize = 0;
        while (offset < 3) {
            const actual = try it.next();
            if (model_index + offset == model.len) {
                try testing.expect(actual == null);
                break;
            }
            try expectEntry(model[model_index + offset], actual);
            offset += 1;
        }
    }
}

/// How many model entries have the same key as the entry before them. Each
/// one is an older entry for a key that has a newer one.
fn modelOlderEntryCount(model: []const Entry) usize {
    var count: usize = 0;
    var entry_number: usize = 1;
    while (entry_number < model.len) {
        const previous = model[entry_number - 1];
        const entry = model[entry_number];
        if (std.mem.eql(u8, previous.key, entry.key)) {
            count += 1;
        }
        entry_number += 1;
    }
    return count;
}

test "random tables match a model" {
    const block_sizes = [_]u32{ 64, 1024, 4096 };
    const counts = [_]usize{ 0, 1, 2, 17, 300, 3000 };

    for (block_sizes) |model_block_size| {
        for (counts, 0..) |count, round| {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();

            const seed = 1000 * @as(u64, model_block_size) + round;
            const model = try makeModel(arena_state.allocator(), seed, count);
            try testing.expectEqual(count, model.len);
            // The larger models must really hold several entries for some
            // keys, or this test would not cover them.
            if (count >= 300) {
                try testing.expect(modelOlderEntryCount(model) >= count / 4);
            }

            const summary = try writeTable(tmp.dir, .{ .block_size = model_block_size }, model);
            try testing.expectEqual(@as(u64, model.len), summary.entry_count);

            try expectTable(tmp.dir, model);
            try expectProbes(tmp.dir, model, seed);
        }
    }
}

test "the same entries give the same bytes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const model = try makeModel(arena_state.allocator(), 7, 1500);
    const options: Options = .{ .block_size = 1024 };

    const first_summary = try writeTable(tmp.dir, options, model);
    const first = try readWholeFile(tmp.dir);
    defer testing.allocator.free(first);

    const second_summary = try writeTable(tmp.dir, options, model);
    const second = try readWholeFile(tmp.dir);
    defer testing.allocator.free(second);

    try testing.expectEqualSlices(u8, first, second);
    try testing.expectEqual(first_summary, second_summary);
}

test "a flipped byte anywhere in the file is detected" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const model = try makeModel(arena_state.allocator(), 23, 60);
    _ = try writeTable(tmp.dir, .{ .block_size = 256 }, model);
    try testing.expectEqual(model.len, try scanTable(tmp.dir));

    const original = try readWholeFile(tmp.dir);
    defer testing.allocator.free(original);

    const file = try tmp.dir.openFile(testing.io, test_name, .{ .mode = .write_only });
    defer file.close(testing.io);

    for (original, 0..) |byte, offset| {
        const flipped = [1]u8{~byte};
        try file.writePositionalAll(testing.io, &flipped, offset);

        testing.expectError(error.Corrupt, scanTable(tmp.dir)) catch |err| {
            std.debug.print("flipping byte {d} of {d} went unnoticed\n", .{ offset, original.len });
            return err;
        };

        const restored = [1]u8{byte};
        try file.writePositionalAll(testing.io, &restored, offset);
    }
    try expectTable(tmp.dir, model);
}

test "a file cut short at any length is detected" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const model = try makeModel(arena_state.allocator(), 29, 20);
    _ = try writeTable(tmp.dir, .{ .block_size = 256 }, model);

    const original = try readWholeFile(tmp.dir);
    defer testing.allocator.free(original);

    for (0..original.len) |len| {
        try setFileLength(tmp.dir, len);
        testing.expectError(error.Corrupt, scanTable(tmp.dir)) catch |err| {
            std.debug.print("cutting the file to {d} of {d} bytes went unnoticed\n", .{ len, original.len });
            return err;
        };
        try writeWholeFile(tmp.dir, original);
    }
    try expectTable(tmp.dir, model);
}

test "bytes after the footer are detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .key = "a", .value = "1", .sequence = 1 },
    };
    _ = try writeTable(tmp.dir, .{}, &entries);

    const len = try fileLength(tmp.dir);
    try setFileLength(tmp.dir, len + 1);
    try testing.expectError(error.Corrupt, scanTable(tmp.dir));
}

test "a whole second table after the footer is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = try smallTableBytes(tmp.dir);
    defer testing.allocator.free(original);

    // The second footer is intact, and the index block it points at is
    // really there, in the first copy. Only the rule that the index block
    // ends where the footer starts can tell that something is wrong.
    const doubled = try testing.allocator.alloc(u8, original.len * 2);
    defer testing.allocator.free(doubled);
    @memcpy(doubled[0..original.len], original);
    @memcpy(doubled[original.len..], original);

    try writeWholeFile(tmp.dir, doubled);
    try expectOpenCorrupt(tmp.dir);
}

test "a file that is only a footer is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try writeTable(tmp.dir, .{}, &.{});

    // The footer says the index block is at offset 0 and has no bytes, not
    // even a block header.
    var footer = [_]u8{
        'b', 'e', 'a', 'n', 's', 's', 't', '1', // magic
        2, 0, 0, 0, // version
        0, 0, 0, 0, 0, 0, 0, 0, // index block offset
        0, 0, 0, 0, // index block length
        0, 0, 0, 0, // index block header checksum
        0, 0, 0, 0, // largest data block length
        0, 0, 0, 0, // footer checksum, filled in below
    };
    sealFooter(&footer);
    try writeWholeFile(tmp.dir, &footer);

    try expectOpenCorrupt(tmp.dir);
}

test "a footer with the wrong magic is detected even if its checksum is right" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try smallTableBytes(tmp.dir);
    defer testing.allocator.free(bytes);

    // The magic is the first 8 bytes of the footer.
    bytes[small_footer_start] = 'B';
    sealFooter(bytes);
    try writeWholeFile(tmp.dir, bytes);

    try expectOpenCorrupt(tmp.dir);
}

test "an intact footer of another version is reported as an unsupported version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try smallTableBytes(tmp.dir);
    defer testing.allocator.free(bytes);

    // The version is bytes 8 to 12 of the footer.
    const version_bytes = bytes[small_footer_start + 8 ..][0..4];
    try testing.expectEqual(@as(u32, version), std.mem.readInt(u32, version_bytes, .little));
    std.mem.writeInt(u32, version_bytes, version + 1, .little);
    sealFooter(bytes);
    try writeWholeFile(tmp.dir, bytes);

    var index_buffer: [small_table_len]u8 = undefined;
    const result = Reader.open(testing.io, tmp.dir, test_name, &index_buffer);
    try testing.expectError(error.UnsupportedVersion, result);
}

test "an index block longer than the file is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try smallTableBytes(tmp.dir);
    defer testing.allocator.free(bytes);

    // The index block's length is bytes 20 to 24 of the footer.
    const index_len_bytes = bytes[small_footer_start + 20 ..][0..4];
    std.mem.writeInt(u32, index_len_bytes, small_table_len + 1, .little);
    sealFooter(bytes);
    try writeWholeFile(tmp.dir, bytes);

    try expectOpenCorrupt(tmp.dir);
}

test "a footer that names a different index block is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try smallTableBytes(tmp.dir);
    defer testing.allocator.free(bytes);

    // Change the footer's copy of the index block's header checksum, then
    // give the footer a correct checksum again. The footer and the index
    // block each pass their own checks, but they no longer belong together.
    // The copy follows the magic (8), the version (4), the index offset (8)
    // and the index length (4).
    const index_header_checksum_offset = small_footer_start + 24;
    bytes[index_header_checksum_offset] ^= 1;
    sealFooter(bytes);
    try writeWholeFile(tmp.dir, bytes);

    try expectOpenCorrupt(tmp.dir);
}

test "a table sealed by hand with nothing changed is still read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // This shows that `sealTable` gives a valid table for both layouts, so
    // the tests below fail for the reason they name.
    const small = try smallTableBytes(tmp.dir);
    defer testing.allocator.free(small);
    const small_sealed = try testing.allocator.dupe(u8, small);
    defer testing.allocator.free(small_sealed);
    sealTable(small_sealed, small_table_layout);
    try testing.expectEqualSlices(u8, small, small_sealed);

    const entries = eightEntries("12345678", 8);
    const eight = try eightTableBytes(tmp.dir, &entries);
    defer testing.allocator.free(eight);
    const eight_sealed = try testing.allocator.dupe(u8, eight);
    defer testing.allocator.free(eight_sealed);
    sealTable(eight_sealed, eight_table_layout);
    try testing.expectEqualSlices(u8, eight, eight_sealed);

    // The offset helpers find the entries: the last entry of the first
    // block is "d", numbered 4, and the first index entry names it.
    const last_entry_offset = eightTableEntryOffset(0, 3);
    const last_key_offset = eightTableKeyOffset(0, 3);
    try testing.expectEqual(@as(u8, 'd'), eight[last_key_offset]);
    try testing.expectEqual(@as(u64, 4), readEntrySequence(eight, last_entry_offset));
    const index_entry_offset = eightTableIndexEntryOffset(0);
    const index_key_offset = eightTableIndexKeyOffset(0);
    try testing.expectEqual(@as(u8, 'd'), eight[index_key_offset]);
    try testing.expectEqual(@as(u64, 4), readEntrySequence(eight, index_entry_offset));

    // A change that keeps the structure whole is read back: the value of
    // "a" is the 8 bytes after its key.
    const value_offset = eightTableKeyOffset(0, 0) + 1;
    eight_sealed[value_offset] = 'X';
    sealTable(eight_sealed, eight_table_layout);
    try writeWholeFile(tmp.dir, eight_sealed);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    const lookup = try table.get("a");
    try testing.expect(lookup == .value);
    try testing.expectEqualSlices(u8, "X2345678", lookup.value);
    try expectLookup(entries[7], try table.get("h"));
}

test "a gap before a data block is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try smallTableBytes(tmp.dir);
    defer testing.allocator.free(bytes);

    // The index entry is an entry header, the key "b", and then the block
    // location, which starts with the block's offset. It becomes 1.
    const block_location_start = small_index_body_start + entry_header_size + 1;
    const block_offset_bytes = bytes[block_location_start..][0..8];
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, block_offset_bytes, .little));
    std.mem.writeInt(u64, block_offset_bytes, 1, .little);
    sealTable(bytes, small_table_layout);
    try writeWholeFile(tmp.dir, bytes);

    try expectOpenCorrupt(tmp.dir);
}

test "data blocks that stop short of the index are detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try smallTableBytes(tmp.dir);
    defer testing.allocator.free(bytes);

    // The block's length follows its 8-byte offset in the block location.
    // The index now says the data block is one byte shorter than it is, and
    // the footer agrees that this is the largest block, but the index block
    // starts one byte after the place where such a data block would end.
    const block_location_start = small_index_body_start + entry_header_size + 1;
    const block_len_bytes = bytes[block_location_start + 8 ..][0..4];
    const block_len = std.mem.readInt(u32, block_len_bytes, .little);
    try testing.expectEqual(@as(u32, small_data_block_len), block_len);
    std.mem.writeInt(u32, block_len_bytes, small_data_block_len - 1, .little);
    const block_len_max_bytes = bytes[small_footer_start + 28 ..][0..4];
    std.mem.writeInt(u32, block_len_max_bytes, small_data_block_len - 1, .little);
    sealTable(bytes, small_table_layout);
    try writeWholeFile(tmp.dir, bytes);

    try expectOpenCorrupt(tmp.dir);
}

test "a footer whose largest block length is not the longest block is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The only data block is `small_data_block_len` bytes long. The largest
    // block length is bytes 28 to 32 of the footer.
    const lengths = [_]u32{ small_data_block_len - 1, small_data_block_len + 1, 0, 1 << 20 };
    for (lengths) |block_len_max| {
        const bytes = try smallTableBytes(tmp.dir);
        defer testing.allocator.free(bytes);

        const block_len_max_bytes = bytes[small_footer_start + 28 ..][0..4];
        const block_len_max_before = std.mem.readInt(u32, block_len_max_bytes, .little);
        try testing.expectEqual(@as(u32, small_data_block_len), block_len_max_before);
        std.mem.writeInt(u32, block_len_max_bytes, block_len_max, .little);
        sealTable(bytes, small_table_layout);
        try writeWholeFile(tmp.dir, bytes);

        expectOpenCorrupt(tmp.dir) catch |err| {
            std.debug.print("a largest block length of {d} went unnoticed\n", .{block_len_max});
            return err;
        };
    }
}

test "an index entry that is not a block location is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try smallTableBytes(tmp.dir);
    defer testing.allocator.free(bytes);

    // The index entry's header starts with flags (1 byte), key length (2
    // bytes) and value length (4 bytes). The key grows from 1 byte to 2 and
    // the value shrinks from 16 bytes to 15, so the entry is as long as it
    // was but its value is no longer a block location.
    try testing.expectEqual(@as(u8, 1), bytes[small_index_body_start + 1]);
    try testing.expectEqual(@as(u8, 16), bytes[small_index_body_start + 3]);
    bytes[small_index_body_start + 1] = 2;
    bytes[small_index_body_start + 3] = 15;
    sealTable(bytes, small_table_layout);
    try writeWholeFile(tmp.dir, bytes);

    try expectOpenCorrupt(tmp.dir);
}

test "index keys that do not increase are detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The index entries are "d", numbered 4, and "h", numbered 8. A first
    // key after the second is not allowed. Two equal keys are allowed only
    // when the first has the larger sequence number, and here it has the
    // smaller one.
    const first_keys = [_]u8{ 'h', 'z' };
    for (first_keys) |first_key| {
        const entries = eightEntries("12345678", 8);
        const bytes = try eightTableBytes(tmp.dir, &entries);
        defer testing.allocator.free(bytes);

        const key_offset = eightTableIndexKeyOffset(0);
        try testing.expectEqual(@as(u8, 'd'), bytes[key_offset]);
        bytes[key_offset] = first_key;
        sealTable(bytes, eight_table_layout);
        try writeWholeFile(tmp.dir, bytes);

        expectOpenCorrupt(tmp.dir) catch |err| {
            std.debug.print("the index keys '{c}', 'h' went unnoticed\n", .{first_key});
            return err;
        };
    }
}

test "index entries for one key whose sequence numbers do not decrease are detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Every entry is for "k", so the index entries are "k" numbered 5 and
    // "k" numbered 1, and only the sequence numbers put them in order. The
    // first must have the larger one. Neither two equal numbers nor a
    // smaller number first is allowed.
    const first_sequences = [_]u64{ 1, 0 };
    for (first_sequences) |first_sequence| {
        const entries = eightVersions("12345678");
        const bytes = try eightTableBytes(tmp.dir, &entries);
        defer testing.allocator.free(bytes);

        const first_index_entry = eightTableIndexEntryOffset(0);
        const second_index_entry = eightTableIndexEntryOffset(1);
        try testing.expectEqual(@as(u64, 5), readEntrySequence(bytes, first_index_entry));
        try testing.expectEqual(@as(u64, 1), readEntrySequence(bytes, second_index_entry));
        writeEntrySequence(bytes, first_index_entry, first_sequence);
        sealTable(bytes, eight_table_layout);
        try writeWholeFile(tmp.dir, bytes);

        expectOpenCorrupt(tmp.dir) catch |err| {
            std.debug.print(
                "the index sequence numbers {d}, 1 for one key went unnoticed\n",
                .{first_sequence},
            );
            return err;
        };
    }
}

test "a data block whose last key is not its index key is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = eightEntries("12345678", 8);
    const bytes = try eightTableBytes(tmp.dir, &entries);
    defer testing.allocator.free(bytes);

    // The last key of the second block becomes "i". The block's keys still
    // increase, but the index says the block ends with "h".
    const key_offset = eightTableKeyOffset(1, 3);
    try testing.expectEqual(@as(u8, 'h'), bytes[key_offset]);
    bytes[key_offset] = 'i';
    sealTable(bytes, eight_table_layout);
    try writeWholeFile(tmp.dir, bytes);

    try testing.expectError(error.Corrupt, scanTable(tmp.dir));

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectError(error.Corrupt, table.get("e"));
    try testing.expectError(error.Corrupt, table.get("h"));
    // The first block is not affected.
    try testing.expect(try table.get("a") == .value);
}

test "a data block whose last entry has its index key but another sequence number is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The last entry of the second block is "h", numbered 8, and the index
    // says so. Its number becomes one more or one less. The block still ends
    // with the key "h", so only the sequence number in the index entry can
    // tell that this is not the entry the index names.
    const last_sequences = [_]u64{ 9, 7 };
    for (last_sequences) |last_sequence| {
        const entries = eightEntries("12345678", 8);
        const bytes = try eightTableBytes(tmp.dir, &entries);
        defer testing.allocator.free(bytes);

        const entry_offset = eightTableEntryOffset(1, 3);
        const key_offset = eightTableKeyOffset(1, 3);
        try testing.expectEqual(@as(u8, 'h'), bytes[key_offset]);
        try testing.expectEqual(@as(u64, 8), readEntrySequence(bytes, entry_offset));
        writeEntrySequence(bytes, entry_offset, last_sequence);
        sealTable(bytes, eight_table_layout);
        try writeWholeFile(tmp.dir, bytes);

        try testing.expectError(error.Corrupt, scanTable(tmp.dir));

        var table: TestReader = try .open(tmp.dir);
        defer table.close();
        try testing.expectError(error.Corrupt, table.get("e"));
        try testing.expectError(error.Corrupt, table.get("h"));
        // The first block is not affected.
        try testing.expect(try table.get("a") == .value);
    }
}

test "an index key past its block's last key is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try smallTableBytes(tmp.dir);
    defer testing.allocator.free(bytes);

    // The index now says the data block's last key is "z", so a lookup of
    // "c" is sent to this block. The block really ends with "b", which is
    // not the key the index gives it.
    const key_offset = small_index_body_start + entry_header_size;
    try testing.expectEqual(@as(u8, 'b'), bytes[key_offset]);
    bytes[key_offset] = 'z';
    sealTable(bytes, small_table_layout);
    try writeWholeFile(tmp.dir, bytes);

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectError(error.Corrupt, table.get("c"));

    var it = table.iterator();
    try testing.expectError(error.Corrupt, it.seek("c"));
    try testing.expect(try it.next() == null);
}

test "a data block that starts at or before the previous block's last key is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = eightEntries("12345678", 8);
    const bytes = try eightTableBytes(tmp.dir, &entries);
    defer testing.allocator.free(bytes);

    // The first key of the second block becomes "d", which is also the last
    // key of the first block. The second block's last key is still "h".
    //
    // Two blocks may share a key, but then the later block must hold the
    // older entries. Here the first block ends with "d" numbered 4 and the
    // second now starts with "d" numbered 5, a newer entry, so the second
    // block starts before the place where the first one ends.
    const entry_offset = eightTableEntryOffset(1, 0);
    const key_offset = eightTableKeyOffset(1, 0);
    const previous_index_entry_offset = eightTableIndexEntryOffset(0);
    try testing.expectEqual(@as(u8, 'e'), bytes[key_offset]);
    try testing.expectEqual(@as(u64, 5), readEntrySequence(bytes, entry_offset));
    try testing.expectEqual(@as(u64, 4), readEntrySequence(bytes, previous_index_entry_offset));
    bytes[key_offset] = 'd';
    sealTable(bytes, eight_table_layout);
    try writeWholeFile(tmp.dir, bytes);

    try testing.expectError(error.Corrupt, scanTable(tmp.dir));

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectError(error.Corrupt, table.get("f"));
}

test "a data block that starts at or before the previous block's last entry by sequence number alone is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Every entry is for "k". The first block ends with the entry numbered
    // 5, and the second block starts with the entry numbered 4. That number
    // becomes 5, the same entry the first block ends with, or 6, a newer
    // one. The keys cannot tell that anything is wrong, and the second
    // block still ends with the entry its index entry names, numbered 1.
    const first_sequences = [_]u64{ 5, 6 };
    for (first_sequences) |first_sequence| {
        const entries = eightVersions("12345678");
        const bytes = try eightTableBytes(tmp.dir, &entries);
        defer testing.allocator.free(bytes);

        const entry_offset = eightTableEntryOffset(1, 0);
        const previous_index_entry_offset = eightTableIndexEntryOffset(0);
        try testing.expectEqual(@as(u64, 5), readEntrySequence(bytes, previous_index_entry_offset));
        try testing.expectEqual(@as(u64, 4), readEntrySequence(bytes, entry_offset));
        writeEntrySequence(bytes, entry_offset, first_sequence);
        sealTable(bytes, eight_table_layout);
        try writeWholeFile(tmp.dir, bytes);

        testing.expectError(error.Corrupt, scanTable(tmp.dir)) catch |err| {
            std.debug.print(
                "a second block that starts with sequence number {d} went unnoticed\n",
                .{first_sequence},
            );
            return err;
        };

        // A lookup of "k" reads only the first block, which is not affected.
        var table: TestReader = try .open(tmp.dir);
        defer table.close();
        try testing.expect(try table.get("k") == .value);

        // An iterator reads the first block and then fails at the second.
        var it = table.iterator();
        for (entries[0..4]) |expected| {
            try expectEntry(expected, try it.next());
        }
        try testing.expectError(error.Corrupt, it.next());
    }
}

test "a changed entry count in a block header is detected by the header checksum" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = eightEntries("12345678", 8);
    const bytes = try eightTableBytes(tmp.dir, &entries);
    defer testing.allocator.free(bytes);

    // The first block's entry count, at bytes 12 to 16 of its header, goes
    // from 4 to 3. The block's body is unchanged, so its body checksum is
    // still right, and the slots of the first three entries are the last
    // 12 bytes of the body, so the block reads as "a", "b", "c".
    const entry_count_offset = 12;
    try testing.expectEqual(@as(u8, 4), bytes[entry_count_offset]);
    bytes[entry_count_offset] = 3;

    // The index is made to agree that the block ends with "c", numbered 3.
    // The index block and the footer get new checksums, but the data
    // block's header does not: only its header checksum can notice the
    // changed count.
    const index_entry_offset = eightTableIndexEntryOffset(0);
    const index_key_offset = eightTableIndexKeyOffset(0);
    try testing.expectEqual(@as(u8, 'd'), bytes[index_key_offset]);
    try testing.expectEqual(@as(u64, 4), readEntrySequence(bytes, index_entry_offset));
    const third_entry_offset = eightTableEntryOffset(0, 2);
    try testing.expectEqual(@as(u64, 3), readEntrySequence(bytes, third_entry_offset));
    bytes[index_key_offset] = 'c';
    writeEntrySequence(bytes, index_entry_offset, 3);
    sealIndexAndFooter(bytes, eight_table_layout);
    try writeWholeFile(tmp.dir, bytes);

    try testing.expectError(error.Corrupt, scanTable(tmp.dir));
}

test "a data block from another table with the same keys is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two tables with the same keys, the same sequence numbers and the same
    // layout, but other values.
    const other_entries = eightEntries("abcdefgh", 8);
    const other = try eightTableBytes(tmp.dir, &other_entries);
    defer testing.allocator.free(other);
    const entries = eightEntries("12345678", 8);
    const bytes = try eightTableBytes(tmp.dir, &entries);
    defer testing.allocator.free(bytes);

    // The first block of the other table passes its own checksums, has the
    // right length and ends with the right key and sequence number. Only
    // the header checksum that the index holds for the block notices that
    // it is the wrong one.
    const first_block_len = eight_table_layout.data_block_len;
    @memcpy(bytes[0..first_block_len], other[0..first_block_len]);
    try writeWholeFile(tmp.dir, bytes);

    try testing.expectError(error.Corrupt, scanTable(tmp.dir));

    var table: TestReader = try .open(tmp.dir);
    defer table.close();
    try testing.expectError(error.Corrupt, table.get("a"));
    // The second block is still the table's own.
    try testing.expect(try table.get("e") == .value);
}

/// One byte of the small table for a test to overwrite.
const ByteChange = struct {
    what: []const u8,
    offset: usize,
    value: u8,
};

test "a bad entry behind valid checksums is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The data body starts at byte 20. The first entry is at bytes 20 to
    // 37: flags (20), key length (21 and 22), value length (23 to 26), the
    // sequence number (27 to 34), the key "a" and the value "1". The entries
    // take 33 bytes in all. The slot of the first entry is the last four
    // bytes of the body, bytes 57 to 61.
    const first_entry = small_data_body_start;
    const first_slot = small_data_block_len - slot_size;
    const changes = [_]ByteChange{
        .{ .what = "flags the format does not define", .offset = first_entry, .value = 2 },
        .{ .what = "a tombstone with a value length of 1", .offset = first_entry, .value = 1 },
        .{ .what = "a key length of 257", .offset = first_entry + 2, .value = 1 },
        .{ .what = "a value length of 257", .offset = first_entry + 4, .value = 1 },
        .{ .what = "a slot that points past the entries", .offset = first_slot, .value = 200 },
        // An entry header takes 15 bytes, and only 13 of the 33 bytes of
        // entries are left after byte 20.
        .{ .what = "a slot with no room for an entry header", .offset = first_slot, .value = 20 },
    };

    for (changes) |change| {
        const bytes = try smallTableBytes(tmp.dir);
        defer testing.allocator.free(bytes);

        bytes[change.offset] = change.value;
        sealTable(bytes, small_table_layout);
        try writeWholeFile(tmp.dir, bytes);

        testing.expectError(error.Corrupt, scanTable(tmp.dir)) catch |err| {
            std.debug.print("{s} went unnoticed\n", .{change.what});
            return err;
        };
    }
}

test "a bad entry count behind valid checksums is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The data block's body is 41 bytes, so it has room for ten slots at
    // most. A data block is never empty, so a count of 0 is wrong too. The
    // last count is so large that four bytes for each slot would not fit in
    // 32 bits.
    const body_len = small_data_block_len - block_header_size;
    try testing.expectEqual(@as(usize, 10), body_len / slot_size);
    const entry_counts = [_]u32{ 0, 11, 0x4000_0000, 0xffff_ffff };
    for (entry_counts) |entry_count| {
        const bytes = try smallTableBytes(tmp.dir);
        defer testing.allocator.free(bytes);

        // The entry count is bytes 12 to 16 of the block header.
        std.mem.writeInt(u32, bytes[12..16], entry_count, .little);
        sealTable(bytes, small_table_layout);
        try writeWholeFile(tmp.dir, bytes);

        testing.expectError(error.Corrupt, scanTable(tmp.dir)) catch |err| {
            std.debug.print("an entry count of {d} went unnoticed\n", .{entry_count});
            return err;
        };
    }
}
