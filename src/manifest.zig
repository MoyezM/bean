//! The manifest: the durable record of which table files make up a store.
//!
//! A store's tables change in steps. A flush adds a table. A compaction
//! removes some tables and adds others. Each step is one edit, and the
//! manifest is the list of every edit since the store was created. Applying
//! the edits in order gives the tables the store has now.
//!
//! The manifest is stored as a write-ahead log (see `wal.zig`) whose records
//! are edits. That gives it the log's properties: every edit is checksummed
//! and synced before it counts, an edit is applied whole or not at all, and
//! an edit that a crash left half-written is ignored when the manifest is
//! read back.
//!
//! An edit, with all integers little-endian:
//!
//!     edit header:    tables added (u32)
//!                     tables removed (u32)
//!                     log number (u64)        the log file that holds the
//!                                             writes newer than every table
//!                     next file number (u64)  a number no file has had yet
//!                     flushed op (u64)        the last log op whose writes
//!                                             are in tables
//!                     flushed sequence number (u64)
//!                                             the last sequence number
//!                                             whose write is in tables
//!     added table, added table, ...
//!     removed file number (u64), ...
//!
//!     added table:    file number (u64)
//!                     file size (u64)
//!                     smallest sequence number (u64)
//!                     largest sequence number (u64)
//!                     checksum (u32)          the table's footer checksum
//!                     smallest key length (u16)
//!                     largest key length (u16)
//!                     level (u8)
//!                     smallest key
//!                     largest key
//!
//! Tables are removed before tables are added, so an edit can replace every
//! table of a full store.
//!
//! The flushed op and the flushed sequence number say where the log named
//! by the log number begins: its first record is the op after the flushed
//! op, and the first write in it takes the sequence number after the flushed
//! one. They change only when the log number changes, and they never go
//! down. A store that opens reads them to learn where its numbering resumes,
//! which the tables alone cannot say once a compaction has dropped entries.
//!
//! Files are named by number, and the manifest never gives one number to
//! two files. A crash can leave behind a file that no edit names. The store
//! must delete such files when it opens, before it hands out their numbers
//! again.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const constants = @import("constants.zig");
const wal = @import("wal.zig");

/// The longest key a table description holds.
pub const key_size_max = constants.key_size_max;

/// The most tables a store holds at once.
pub const tables_max = constants.tables_max;

/// The number of levels. A table's level is less than this.
pub const level_count = constants.level_count;

/// The name of the manifest file in a store's directory.
pub const file_name = "MANIFEST";

// The sizes of the two headers come from the structs that describe them,
// further down.
const edit_header_size = @sizeOf(EditHeader);
const table_header_size = @sizeOf(TableHeader);
const file_number_size = @sizeOf(u64);

/// The most bytes one added table takes in an edit: its header and two keys
/// of the longest size.
const table_size_max = table_header_size + 2 * key_size_max;

/// The most bytes one edit takes: every table of a full store removed, and
/// as many added.
pub const edit_size_max = edit_header_size +
    tables_max * table_size_max +
    tables_max * file_number_size;

/// The longest key the encoding can represent. Key lengths are a u16.
const key_size_format_max = std.math.maxInt(u16);

/// The most levels the encoding can represent. The level is a u8.
const level_count_format_max = std.math.maxInt(u8) + 1;

comptime {
    // The headers are written to the file exactly as they are in memory,
    // and the encoding is little-endian.
    assert(builtin.cpu.arch.endian() == .little);

    // These sizes are part of the encoding. A change to a struct that makes
    // one of these fail has changed the encoding.
    assert(edit_header_size == 40);
    assert(table_header_size == 41);

    assert(key_size_max <= key_size_format_max);
    assert(level_count <= level_count_format_max);

    // An edit is the payload of one log record.
    assert(edit_size_max <= wal.payload_size_format_max);
}

/// The first bytes of every edit, as they are in the file.
const EditHeader = extern struct {
    added_count: u32,
    removed_count: u32,
    log_number: u64,
    file_number_next: u64,
    op_flushed: u64,
    sequence_flushed: u64,

    fn fromBytes(bytes: *const [edit_header_size]u8) EditHeader {
        return std.mem.bytesToValue(EditHeader, bytes);
    }

    fn toBytes(header: *const EditHeader) *const [edit_header_size]u8 {
        return std.mem.asBytes(header);
    }
};

/// The first bytes of every added table, as they are in the file. The two
/// keys follow.
///
/// The fields are marked `align(1)` so that the struct has no padding.
const TableHeader = extern struct {
    file_number: u64 align(1),
    file_size: u64 align(1),
    sequence_min: u64 align(1),
    sequence_max: u64 align(1),
    checksum: u32 align(1),
    key_min_len: u16 align(1),
    key_max_len: u16 align(1),
    level: u8,

    fn fromBytes(bytes: *const [table_header_size]u8) TableHeader {
        return std.mem.bytesToValue(TableHeader, bytes);
    }

    fn toBytes(header: *const TableHeader) *const [table_header_size]u8 {
        return std.mem.asBytes(header);
    }
};

/// What the manifest records about one table file.
pub const Table = struct {
    /// Names the file. Never zero.
    file_number: u64,
    /// 0 for a table written from the memtable.
    level: u8,
    /// The length of the file in bytes.
    file_size: u64,
    /// The table's footer checksum, as `sstable.Writer.finish` reported it.
    checksum: u32,
    /// The smallest and largest sequence numbers of the table's entries.
    sequence_min: u64,
    sequence_max: u64,
    /// The smallest and largest keys in the table.
    key_min: []const u8,
    key_max: []const u8,
};

/// One change to the set of tables, to be written to the manifest.
pub const Edit = struct {
    /// Tables to add. Applied after the removals.
    added: []const Table,
    /// File numbers of tables to remove.
    removed: []const u64,
    /// The number of the log file that holds the writes newer than every
    /// table, once this edit is applied. Never zero.
    log_number: u64,
    /// A number greater than that of any file the store has had.
    file_number_next: u64,
    /// The last log op whose writes are in tables. The log named by
    /// `log_number` begins with the op after it.
    op_flushed: u64,
    /// The last sequence number whose write is in tables. The first write
    /// in the log named by `log_number` takes the number after it.
    sequence_flushed: u64,
};

/// Writes `edit` into `buffer` in the manifest's encoding and returns the
/// bytes written. `buffer` must be at least `edit_size_max` long, and the
/// edit must be one `validate` accepts.
pub fn encode(edit: Edit, buffer: []u8) []const u8 {
    assert(buffer.len >= edit_size_max);
    assert(edit.added.len <= tables_max);
    assert(edit.removed.len <= tables_max);

    const header: EditHeader = .{
        .added_count = @intCast(edit.added.len),
        .removed_count = @intCast(edit.removed.len),
        .log_number = edit.log_number,
        .file_number_next = edit.file_number_next,
        .op_flushed = edit.op_flushed,
        .sequence_flushed = edit.sequence_flushed,
    };
    @memcpy(buffer[0..edit_header_size], header.toBytes());
    var offset: usize = edit_header_size;

    for (edit.added) |table| {
        assert(table.key_min.len <= key_size_max);
        assert(table.key_max.len <= key_size_max);

        const table_header: TableHeader = .{
            .file_number = table.file_number,
            .file_size = table.file_size,
            .sequence_min = table.sequence_min,
            .sequence_max = table.sequence_max,
            .checksum = table.checksum,
            .key_min_len = @intCast(table.key_min.len),
            .key_max_len = @intCast(table.key_max.len),
            .level = table.level,
        };
        @memcpy(buffer[offset..][0..table_header_size], table_header.toBytes());
        offset += table_header_size;

        @memcpy(buffer[offset..][0..table.key_min.len], table.key_min);
        offset += table.key_min.len;
        @memcpy(buffer[offset..][0..table.key_max.len], table.key_max);
        offset += table.key_max.len;
    }

    for (edit.removed) |file_number| {
        std.mem.writeInt(u64, buffer[offset..][0..file_number_size], file_number, .little);
        offset += file_number_size;
    }

    const bytes = buffer[0..offset];
    validate(bytes) catch unreachable;
    return bytes;
}

/// Checks that `bytes` are a well-formed edit: the counts are within the
/// store's limits, every table is whole and makes sense on its own, and
/// nothing follows the last removed file number.
///
/// This does not check the edit against the tables a store already has;
/// `TableSet.check` does that.
pub fn validate(bytes: []const u8) error{InvalidEdit}!void {
    if (bytes.len < edit_header_size) {
        return error.InvalidEdit;
    }
    if (bytes.len > edit_size_max) {
        return error.InvalidEdit;
    }
    const header = EditHeader.fromBytes(bytes[0..edit_header_size]);
    if (header.added_count > tables_max) {
        return error.InvalidEdit;
    }
    if (header.removed_count > tables_max) {
        return error.InvalidEdit;
    }
    // Every file has a number below the next one, and no file is number 0.
    if (header.file_number_next == 0) {
        return error.InvalidEdit;
    }
    if (header.log_number == 0) {
        return error.InvalidEdit;
    }
    if (header.log_number >= header.file_number_next) {
        return error.InvalidEdit;
    }

    var offset: usize = edit_header_size;
    var added: u32 = 0;
    while (added < header.added_count) {
        const decoded = try decodeTable(bytes[offset..]);
        if (decoded.table.file_number >= header.file_number_next) {
            return error.InvalidEdit;
        }
        // A table holds only writes that have been flushed.
        if (decoded.table.sequence_max > header.sequence_flushed) {
            return error.InvalidEdit;
        }
        offset += decoded.size;
        added += 1;
    }

    const removed_size = @as(usize, header.removed_count) * file_number_size;
    if (bytes.len - offset != removed_size) {
        return error.InvalidEdit;
    }
    var removed: u32 = 0;
    while (removed < header.removed_count) {
        const file_number = std.mem.readInt(u64, bytes[offset..][0..file_number_size], .little);
        if (file_number == 0) {
            return error.InvalidEdit;
        }
        if (file_number >= header.file_number_next) {
            return error.InvalidEdit;
        }
        offset += file_number_size;
        removed += 1;
    }
}

/// A table read from the front of some bytes, and how many bytes it took.
/// The table's keys point into those bytes.
const DecodedTable = struct {
    table: Table,
    size: usize,
};

/// Reads the added table at the front of `bytes`. Fails if the bytes do not
/// start with a whole table that makes sense on its own.
fn decodeTable(bytes: []const u8) error{InvalidEdit}!DecodedTable {
    if (bytes.len < table_header_size) {
        return error.InvalidEdit;
    }
    const header = TableHeader.fromBytes(bytes[0..table_header_size]);
    const key_min_len: usize = header.key_min_len;
    const key_max_len: usize = header.key_max_len;

    if (header.file_number == 0) {
        return error.InvalidEdit;
    }
    if (header.level >= level_count) {
        return error.InvalidEdit;
    }
    if (header.sequence_min > header.sequence_max) {
        return error.InvalidEdit;
    }
    if (key_min_len > key_size_max) {
        return error.InvalidEdit;
    }
    if (key_max_len > key_size_max) {
        return error.InvalidEdit;
    }

    const size = table_header_size + key_min_len + key_max_len;
    if (size > bytes.len) {
        return error.InvalidEdit;
    }
    const key_min_start = table_header_size;
    const key_max_start = key_min_start + key_min_len;
    const key_min = bytes[key_min_start..key_max_start];
    const key_max = bytes[key_max_start..size];
    if (std.mem.order(u8, key_min, key_max) == .gt) {
        return error.InvalidEdit;
    }

    const table: Table = .{
        .file_number = header.file_number,
        .level = header.level,
        .file_size = header.file_size,
        .checksum = header.checksum,
        .sequence_min = header.sequence_min,
        .sequence_max = header.sequence_max,
        .key_min = key_min,
        .key_max = key_max,
    };
    return .{ .table = table, .size = size };
}

/// A well-formed edit in its encoding, for reading. The bytes must have
/// passed `validate`, or have come from `encode`.
pub const EncodedEdit = struct {
    bytes: []const u8,

    pub fn init(valid_bytes: []const u8) EncodedEdit {
        return .{ .bytes = valid_bytes };
    }

    fn header(self: EncodedEdit) EditHeader {
        return EditHeader.fromBytes(self.bytes[0..edit_header_size]);
    }

    pub fn logNumber(self: EncodedEdit) u64 {
        return self.header().log_number;
    }

    pub fn fileNumberNext(self: EncodedEdit) u64 {
        return self.header().file_number_next;
    }

    pub fn opFlushed(self: EncodedEdit) u64 {
        return self.header().op_flushed;
    }

    pub fn sequenceFlushed(self: EncodedEdit) u64 {
        return self.header().sequence_flushed;
    }

    pub fn addedCount(self: EncodedEdit) usize {
        return self.header().added_count;
    }

    pub fn removedCount(self: EncodedEdit) usize {
        return self.header().removed_count;
    }

    /// Returns a cursor over the tables the edit adds, in the order they
    /// were given to `encode`.
    pub fn added(self: EncodedEdit) AddedIterator {
        return .{
            .bytes_left = self.bytes[edit_header_size..],
            .tables_left = self.header().added_count,
        };
    }

    /// Returns a cursor over the file numbers the edit removes.
    pub fn removed(self: EncodedEdit) RemovedIterator {
        const removed_count: usize = self.header().removed_count;
        const removed_size = removed_count * file_number_size;
        const removed_start = self.bytes.len - removed_size;
        return .{ .bytes_left = self.bytes[removed_start..] };
    }

    pub const AddedIterator = struct {
        bytes_left: []const u8,
        tables_left: u32,

        /// Returns the next added table, or `null` after the last one. Its
        /// keys point into the edit's bytes.
        pub fn next(self: *AddedIterator) ?Table {
            if (self.tables_left == 0) {
                return null;
            }
            // The edit is valid, so decoding cannot fail.
            const decoded = decodeTable(self.bytes_left) catch unreachable;
            self.bytes_left = self.bytes_left[decoded.size..];
            self.tables_left -= 1;
            return decoded.table;
        }
    };

    pub const RemovedIterator = struct {
        bytes_left: []const u8,

        /// Returns the next removed file number, or `null` after the last.
        pub fn next(self: *RemovedIterator) ?u64 {
            if (self.bytes_left.len == 0) {
                return null;
            }
            const file_number = std.mem.readInt(u64, self.bytes_left[0..file_number_size], .little);
            self.bytes_left = self.bytes_left[file_number_size..];
            return file_number;
        }
    };
};

/// The tables a store has: the result of applying a manifest's edits in
/// order. It has room for `tables_max` tables, allocated in `init`.
pub const TableSet = struct {
    slots: [tables_max]Slot,
    /// Holds every slot's two keys. A slot's keys are at a fixed place, so
    /// a table's keys stay where they are for as long as the table is here.
    key_storage: []u8,
    /// The number of the log file that holds the writes newer than every
    /// table. 0 until an edit has been applied.
    log_number: u64,
    /// A number greater than that of any file the store has had. 1 until an
    /// edit has been applied.
    file_number_next: u64,
    /// The last log op whose writes are in tables. The log named by
    /// `log_number` begins with the op after it.
    op_flushed: u64,
    /// The last sequence number whose write is in tables. The first write
    /// in the log named by `log_number` takes the number after it.
    sequence_flushed: u64,

    const Slot = struct {
        in_use: bool,
        /// Only meaningful while the slot is in use. Its keys point into
        /// `key_storage`.
        table: Table,
    };

    /// Allocates room for the keys of `tables_max` tables. `gpa` is not
    /// retained, and no other method allocates.
    pub fn init(gpa: Allocator) Allocator.Error!TableSet {
        const key_storage = try gpa.alloc(u8, tables_max * 2 * key_size_max);
        var slots: [tables_max]Slot = undefined;
        for (&slots) |*slot| {
            slot.in_use = false;
        }
        return .{
            .slots = slots,
            .key_storage = key_storage,
            .log_number = 0,
            .file_number_next = 1,
            .op_flushed = 0,
            .sequence_flushed = 0,
        };
    }

    /// `gpa` must be the allocator passed to `init`.
    pub fn deinit(self: *TableSet, gpa: Allocator) void {
        gpa.free(self.key_storage);
        self.* = undefined;
    }

    /// How many tables the set holds.
    pub fn count(self: *const TableSet) usize {
        var tables: usize = 0;
        for (self.slots) |slot| {
            if (slot.in_use) {
                tables += 1;
            }
        }
        return tables;
    }

    /// Returns the table with this file number, or `null` if the set does
    /// not hold it. The table is valid until the set is next changed.
    pub fn find(self: *const TableSet, file_number: u64) ?*const Table {
        for (&self.slots) |*slot| {
            if (slot.in_use and slot.table.file_number == file_number) {
                return &slot.table;
            }
        }
        return null;
    }

    /// Returns a cursor over the tables in the set, in no particular order.
    /// It is valid until the set is next changed.
    pub fn iterator(self: *const TableSet) Iterator {
        return .{ .set = self, .slot_next = 0 };
    }

    pub const Iterator = struct {
        set: *const TableSet,
        slot_next: usize,

        pub fn next(self: *Iterator) ?*const Table {
            while (self.slot_next < tables_max) {
                const slot = &self.set.slots[self.slot_next];
                self.slot_next += 1;
                if (slot.in_use) {
                    return &slot.table;
                }
            }
            return null;
        }
    };

    /// Checks that a well-formed edit can be applied to this set: every
    /// table it removes is here, none of the tables it adds is, the tables
    /// left afterwards fit, and its file numbers do not go backwards. A log
    /// number that differs from the set's must be one no file has had. The
    /// flushed op and flushed sequence number stay as they are while the
    /// log stays, and do not go down when the log changes. No two level 0
    /// tables hold the same sequence number.
    ///
    /// The store checks an edit with this before it writes it to the
    /// manifest, so that the manifest never holds an edit that cannot be
    /// applied.
    pub fn check(self: *const TableSet, edit: EncodedEdit) error{InvalidEdit}!void {
        if (edit.fileNumberNext() < self.file_number_next) {
            return error.InvalidEdit;
        }
        if (edit.logNumber() < self.log_number) {
            return error.InvalidEdit;
        }
        // A file number is never used twice, so a log that is not the log
        // the set already has must be new.
        if (edit.logNumber() != self.log_number) {
            if (edit.logNumber() < self.file_number_next) {
                return error.InvalidEdit;
            }
        }

        // The flushed op and sequence number say where the log begins, so
        // they move only when the log changes, and only forwards.
        if (edit.logNumber() == self.log_number) {
            if (edit.opFlushed() != self.op_flushed) {
                return error.InvalidEdit;
            }
            if (edit.sequenceFlushed() != self.sequence_flushed) {
                return error.InvalidEdit;
            }
        } else {
            if (edit.opFlushed() < self.op_flushed) {
                return error.InvalidEdit;
            }
            if (edit.sequenceFlushed() < self.sequence_flushed) {
                return error.InvalidEdit;
            }
        }

        var removed = edit.removed();
        var removed_index: usize = 0;
        while (removed.next()) |file_number| {
            if (self.find(file_number) == null) {
                return error.InvalidEdit;
            }
            if (isRemovedBefore(edit, file_number, removed_index)) {
                return error.InvalidEdit;
            }
            removed_index += 1;
        }

        var added = edit.added();
        var added_index: usize = 0;
        while (added.next()) |table| {
            // A file number is never used twice, so a table that is added
            // must be new, even if the same edit removes one.
            if (table.file_number < self.file_number_next) {
                return error.InvalidEdit;
            }
            if (isAddedBefore(edit, table.file_number, added_index)) {
                return error.InvalidEdit;
            }
            // The log is a file too, and has its own number.
            if (table.file_number == edit.logNumber()) {
                return error.InvalidEdit;
            }
            if (table.level == 0) {
                if (self.overlapsLevelZero(edit, table, added_index)) {
                    return error.InvalidEdit;
                }
            }
            added_index += 1;
        }

        const count_after_removals = self.count() - edit.removedCount();
        if (count_after_removals + edit.addedCount() > tables_max) {
            return error.InvalidEdit;
        }
    }

    /// Whether the sequence numbers of `table`, a level 0 table the edit
    /// adds at position `index`, overlap those of another level 0 table:
    /// one the set keeps once the edit's removals are made, or one the
    /// edit adds earlier.
    ///
    /// Each level 0 table is one flushed memtable, so no sequence number is
    /// in two of them. A reader relies on that to visit them from the
    /// newest to the oldest.
    fn overlapsLevelZero(self: *const TableSet, edit: EncodedEdit, table: Table, index: usize) bool {
        for (self.slots) |slot| {
            if (!slot.in_use) {
                continue;
            }
            if (slot.table.level != 0) {
                continue;
            }
            if (isRemovedBefore(edit, slot.table.file_number, edit.removedCount())) {
                continue;
            }
            if (sequencesOverlap(table, slot.table)) {
                return true;
            }
        }

        var added = edit.added();
        var position: usize = 0;
        while (position < index) {
            const earlier = added.next().?;
            if (earlier.level == 0 and sequencesOverlap(table, earlier)) {
                return true;
            }
            position += 1;
        }
        return false;
    }

    fn sequencesOverlap(a: Table, b: Table) bool {
        if (a.sequence_max < b.sequence_min) {
            return false;
        }
        if (b.sequence_max < a.sequence_min) {
            return false;
        }
        return true;
    }

    /// Whether the edit removes `file_number` earlier than at position
    /// `index` in its list of removals.
    fn isRemovedBefore(edit: EncodedEdit, file_number: u64, index: usize) bool {
        var removed = edit.removed();
        var position: usize = 0;
        while (position < index) {
            if (removed.next().? == file_number) {
                return true;
            }
            position += 1;
        }
        return false;
    }

    /// Whether the edit adds a table numbered `file_number` earlier than at
    /// position `index` in its list of added tables.
    fn isAddedBefore(edit: EncodedEdit, file_number: u64, index: usize) bool {
        var added = edit.added();
        var position: usize = 0;
        while (position < index) {
            if (added.next().?.file_number == file_number) {
                return true;
            }
            position += 1;
        }
        return false;
    }

    /// Applies an edit that `check` has accepted: removes its removed
    /// tables, then adds its added tables, copying their keys.
    pub fn apply(self: *TableSet, edit: EncodedEdit) void {
        self.check(edit) catch unreachable;

        var removed = edit.removed();
        while (removed.next()) |file_number| {
            for (&self.slots) |*slot| {
                if (slot.in_use and slot.table.file_number == file_number) {
                    slot.in_use = false;
                }
            }
        }

        var added = edit.added();
        while (added.next()) |table| {
            const slot_index = self.freeSlotIndex();
            const keys = self.slotKeyStorage(slot_index);
            const key_min = keys[0..table.key_min.len];
            const key_max = keys[key_size_max..][0..table.key_max.len];
            @memcpy(key_min, table.key_min);
            @memcpy(key_max, table.key_max);

            var stored = table;
            stored.key_min = key_min;
            stored.key_max = key_max;
            self.slots[slot_index] = .{ .in_use = true, .table = stored };
        }

        self.log_number = edit.logNumber();
        self.file_number_next = edit.fileNumberNext();
        self.op_flushed = edit.opFlushed();
        self.sequence_flushed = edit.sequenceFlushed();
    }

    /// The index of a slot that holds no table. `check` has made sure there
    /// is one.
    fn freeSlotIndex(self: *const TableSet) usize {
        for (self.slots, 0..) |slot, slot_index| {
            if (!slot.in_use) {
                return slot_index;
            }
        }
        unreachable;
    }

    /// The part of `key_storage` that belongs to one slot: room for its
    /// smallest key, then room for its largest.
    fn slotKeyStorage(self: *TableSet, slot_index: usize) []u8 {
        const slot_storage_size = 2 * key_size_max;
        const start = slot_index * slot_storage_size;
        return self.key_storage[start..][0..slot_storage_size];
    }
};

/// Appends edits to a store's manifest. An edit is durable once `append`
/// returns.
pub const Writer = struct {
    log: wal.Writer,

    pub const CreateError = wal.Writer.CreateError;
    pub const OpenError = wal.Writer.OpenError;
    pub const AppendError = Io.File.WritePositionalError || Io.File.SyncError;

    /// Creates a new, empty manifest in `dir`, and syncs it. Fails if the
    /// file already exists.
    pub fn create(io: Io, dir: Io.Dir) CreateError!Writer {
        const log = try wal.Writer.create(io, dir, file_name, edit_size_max, .none);
        return .{ .log = log };
    }

    /// Opens an existing manifest to append after its valid edits. `end`
    /// must come from `Reader.end` after that reader reached the end of the
    /// same file.
    pub fn open(io: Io, dir: Io.Dir, end: wal.End) OpenError!Writer {
        const log = try wal.Writer.open(io, dir, file_name, edit_size_max, end);
        return .{ .log = log };
    }

    pub fn close(self: *Writer) void {
        self.log.close();
        self.* = undefined;
    }

    /// Appends one edit and syncs the file. `edit_bytes` must be a
    /// well-formed edit, from `encode`, that the store's `TableSet` has
    /// checked.
    ///
    /// After an error the state of the file is unknown, and the writer must
    /// not be used again.
    pub fn append(self: *Writer, edit_bytes: []const u8) AppendError!void {
        assert(edit_bytes.len <= edit_size_max);
        _ = self.log.append(edit_bytes) catch |err| switch (err) {
            // An edit is never longer than the limit the log was given.
            error.PayloadTooLarge => unreachable,
            else => |other| return other,
        };
    }
};

/// Reads the edits of a store's manifest in the order they were appended.
pub const Reader = struct {
    log: wal.Reader,

    pub const OpenError = wal.Reader.OpenError;

    pub const NextError = error{
        /// A record of the manifest is not a well-formed edit.
        InvalidEdit,
    } || wal.Reader.NextError;

    /// Opens the manifest in `dir`. `buffer` holds one edit at a time, and
    /// must be at least `edit_size_max` long.
    pub fn open(io: Io, dir: Io.Dir, buffer: []u8) OpenError!Reader {
        assert(buffer.len >= edit_size_max);
        const log = try wal.Reader.open(io, dir, file_name, buffer);
        return .{ .log = log };
    }

    pub fn close(self: *Reader) void {
        self.log.close();
        self.* = undefined;
    }

    /// Returns the next edit, or `null` at the end of the manifest. The
    /// edit is well-formed, and is valid until the next call to `next`.
    pub fn next(self: *Reader) NextError!?EncodedEdit {
        const record = try self.log.next();
        if (record == null) {
            return null;
        }
        const edit_bytes = record.?.payload;
        try validate(edit_bytes);
        return EncodedEdit.init(edit_bytes);
    }

    /// Where the edits returned so far end. Once `next` has returned `null`,
    /// this is where a `Writer` should resume.
    pub fn end(self: *const Reader) wal.End {
        return self.log.end();
    }
};

/// What a numbered file holds.
pub const FileKind = enum {
    /// A write-ahead log.
    log,
    /// A sorted table.
    table,
};

/// The longest name `fileName` produces: the 20 digits of the largest file
/// number, a dot, and a three-letter ending.
pub const file_name_size_max = 20 + 1 + 3;

/// Writes the name of file number `file_number` into `buffer` and returns
/// it: the number in at least six digits, then `.log` or `.sst`.
pub fn fileName(buffer: *[file_name_size_max]u8, kind: FileKind, file_number: u64) []const u8 {
    assert(file_number > 0);
    const ending = switch (kind) {
        .log => "log",
        .table => "sst",
    };
    return std.fmt.bufPrint(buffer, "{d:0>6}.{s}", .{ file_number, ending }) catch unreachable;
}

/// A numbered file's kind and number, as its name gives them.
pub const ParsedFileName = struct {
    kind: FileKind,
    file_number: u64,
};

/// Reads a name that `fileName` produced. Returns `null` for any other
/// name, so a file the store did not name is never taken for one of its own.
pub fn parseFileName(name: []const u8) ?ParsedFileName {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    if (dot == null) {
        return null;
    }
    const digits = name[0..dot.?];
    const ending = name[dot.? + 1 ..];

    var kind: FileKind = undefined;
    if (std.mem.eql(u8, ending, "log")) {
        kind = .log;
    } else if (std.mem.eql(u8, ending, "sst")) {
        kind = .table;
    } else {
        return null;
    }

    const file_number = std.fmt.parseInt(u64, digits, 10) catch {
        return null;
    };
    if (file_number == 0) {
        return null;
    }

    // Only the exact name `fileName` gives the number counts. That rules
    // out a sign, missing zeros, and extra zeros.
    var buffer: [file_name_size_max]u8 = undefined;
    const expected = fileName(&buffer, kind, file_number);
    if (!std.mem.eql(u8, expected, name)) {
        return null;
    }
    return .{ .kind = kind, .file_number = file_number };
}

const testing = std.testing;

/// The flushed op and flushed sequence number that the tests' edits carry,
/// unless a test is about those numbers. The sequence number is larger than
/// any that `testTable` gives a table.
const test_op_flushed: u64 = 100;
const test_sequence_flushed: u64 = 1000;

/// A table description for tests, with every field filled from its file
/// number so that a test can tell tables apart.
fn testTable(file_number: u64, key_min: []const u8, key_max: []const u8) Table {
    return .{
        .file_number = file_number,
        .level = 0,
        .file_size = 1000 + file_number,
        .checksum = @intCast(0xabc0 + file_number),
        .sequence_min = 10 * file_number,
        .sequence_max = 10 * file_number + 9,
        .key_min = key_min,
        .key_max = key_max,
    };
}

fn expectTable(expected: Table, actual: ?Table) !void {
    try testing.expect(actual != null);
    try testing.expectEqual(expected.file_number, actual.?.file_number);
    try testing.expectEqual(expected.level, actual.?.level);
    try testing.expectEqual(expected.file_size, actual.?.file_size);
    try testing.expectEqual(expected.checksum, actual.?.checksum);
    try testing.expectEqual(expected.sequence_min, actual.?.sequence_min);
    try testing.expectEqual(expected.sequence_max, actual.?.sequence_max);
    try testing.expectEqualSlices(u8, expected.key_min, actual.?.key_min);
    try testing.expectEqualSlices(u8, expected.key_max, actual.?.key_max);
}

test "an edit is read back as it was written" {
    var buffer: [edit_size_max]u8 = undefined;
    const tables = [_]Table{
        testTable(7, "apple", "mango"),
        testTable(8, "", "zebra"),
    };
    const removed = [_]u64{ 3, 5 };
    const bytes = encode(.{
        .added = &tables,
        .removed = &removed,
        .log_number = 9,
        .file_number_next = 10,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer);

    try validate(bytes);
    const edit: EncodedEdit = .init(bytes);
    try testing.expectEqual(@as(u64, 9), edit.logNumber());
    try testing.expectEqual(@as(u64, 10), edit.fileNumberNext());
    try testing.expectEqual(test_op_flushed, edit.opFlushed());
    try testing.expectEqual(test_sequence_flushed, edit.sequenceFlushed());
    try testing.expectEqual(@as(usize, 2), edit.addedCount());
    try testing.expectEqual(@as(usize, 2), edit.removedCount());

    var added = edit.added();
    try expectTable(tables[0], added.next());
    try expectTable(tables[1], added.next());
    try testing.expect(added.next() == null);

    var removed_numbers = edit.removed();
    try testing.expectEqual(@as(?u64, 3), removed_numbers.next());
    try testing.expectEqual(@as(?u64, 5), removed_numbers.next());
    try testing.expect(removed_numbers.next() == null);
}

test "an edit that changes no tables is an edit" {
    var buffer: [edit_size_max]u8 = undefined;
    const bytes = encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 2,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer);
    try testing.expectEqual(@as(usize, edit_header_size), bytes.len);

    const edit: EncodedEdit = .init(bytes);
    var added = edit.added();
    try testing.expect(added.next() == null);
    var removed = edit.removed();
    try testing.expect(removed.next() == null);
}

test "the encoding of a small edit, byte for byte" {
    var buffer: [edit_size_max]u8 = undefined;
    const table: Table = .{
        .file_number = 2,
        .level = 1,
        .file_size = 0x0102,
        .checksum = 0xaabbccdd,
        .sequence_min = 3,
        .sequence_max = 4,
        .key_min = "a",
        .key_max = "bc",
    };
    const tables = [_]Table{table};
    // One table added and two removed, so that the two counts differ.
    const removed = [_]u64{ 1, 3 };
    const bytes = encode(.{
        .added = &tables,
        .removed = &removed,
        .log_number = 7,
        .file_number_next = 8,
        .op_flushed = 5,
        .sequence_flushed = 6,
    }, &buffer);

    const expected = [_]u8{
        1, 0, 0, 0, // tables added
        2, 0, 0, 0, // tables removed
        7, 0, 0, 0, 0, 0, 0, 0, // log number
        8, 0, 0, 0, 0, 0, 0, 0, // next file number
        5, 0, 0, 0, 0, 0, 0, 0, // flushed op
        6, 0, 0, 0, 0, 0, 0, 0, // flushed sequence number
        2, 0, 0, 0, 0, 0, 0, 0, // file number
        2, 1, 0, 0, 0, 0, 0, 0, // file size
        3, 0, 0, 0, 0, 0, 0, 0, // smallest sequence number
        4, 0, 0, 0, 0, 0, 0, 0, // largest sequence number
        0xdd, 0xcc, 0xbb, 0xaa, // checksum
        1, 0, // smallest key length
        2, 0, // largest key length
        1, // level
        'a', // smallest key
        'b', 'c', // largest key
        1, 0, 0, 0, 0, 0, 0, 0, // removed file number
        3, 0, 0, 0, 0, 0, 0, 0, // removed file number
    };
    try testing.expectEqualSlices(u8, &expected, bytes);
}

test "validate rejects an edit cut short or with bytes after it" {
    var buffer: [edit_size_max]u8 = undefined;
    const tables = [_]Table{testTable(4, "a", "m")};
    const removed = [_]u64{2};
    const whole = encode(.{
        .added = &tables,
        .removed = &removed,
        .log_number = 5,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer);

    for (0..whole.len) |len| {
        try testing.expectError(error.InvalidEdit, validate(whole[0..len]));
    }
    try validate(whole);

    var longer: [edit_size_max]u8 = undefined;
    @memcpy(longer[0..whole.len], whole);
    longer[whole.len] = 0;
    try testing.expectError(error.InvalidEdit, validate(longer[0 .. whole.len + 1]));
}

/// Writes an edit's bytes with whatever header, tables and removed file
/// numbers it is given, bypassing `encode`, which refuses to write an edit
/// that is not well-formed.
fn encodeRaw(buffer: []u8, header: EditHeader, tables: []const Table, removed: []const u64) []const u8 {
    @memcpy(buffer[0..edit_header_size], header.toBytes());
    var offset: usize = edit_header_size;

    for (tables) |table| {
        const table_header: TableHeader = .{
            .file_number = table.file_number,
            .file_size = table.file_size,
            .sequence_min = table.sequence_min,
            .sequence_max = table.sequence_max,
            .checksum = table.checksum,
            .key_min_len = @intCast(table.key_min.len),
            .key_max_len = @intCast(table.key_max.len),
            .level = table.level,
        };
        @memcpy(buffer[offset..][0..table_header_size], table_header.toBytes());
        offset += table_header_size;
        @memcpy(buffer[offset..][0..table.key_min.len], table.key_min);
        offset += table.key_min.len;
        @memcpy(buffer[offset..][0..table.key_max.len], table.key_max);
        offset += table.key_max.len;
    }

    for (removed) |file_number| {
        std.mem.writeInt(u64, buffer[offset..][0..file_number_size], file_number, .little);
        offset += file_number_size;
    }
    return buffer[0..offset];
}

/// Encodes an edit that adds `table` and nothing else, bypassing `encode`.
fn encodeUnchecked(buffer: []u8, header: EditHeader, table: Table) []const u8 {
    const tables = [_]Table{table};
    return encodeRaw(buffer, header, &tables, &.{});
}

test "validate rejects a removed file number that does not make sense" {
    var buffer: [edit_size_max]u8 = undefined;
    const header: EditHeader = .{
        .added_count = 0,
        .removed_count = 1,
        .log_number = 5,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };

    // The largest number a file can have had.
    try validate(encodeRaw(&buffer, header, &.{}, &.{5}));
    // No file is number 0.
    try testing.expectError(error.InvalidEdit, validate(encodeRaw(&buffer, header, &.{}, &.{0})));
    // No file has had the next number yet.
    try testing.expectError(error.InvalidEdit, validate(encodeRaw(&buffer, header, &.{}, &.{6})));

    // Every removed number is checked, not only the first.
    var two_removed = header;
    two_removed.removed_count = 2;
    try validate(encodeRaw(&buffer, two_removed, &.{}, &.{ 2, 3 }));
    try testing.expectError(error.InvalidEdit, validate(encodeRaw(&buffer, two_removed, &.{}, &.{ 2, 0 })));
    try testing.expectError(error.InvalidEdit, validate(encodeRaw(&buffer, two_removed, &.{}, &.{ 2, 6 })));
}

test "validate rejects more tables than a store holds, however well-formed they are" {
    const buffer = try testing.allocator.alloc(u8, 2 * edit_size_max);
    defer testing.allocator.free(buffer);

    // One table and one removed number more than the limit, each of them
    // whole and valid, so that only the count is wrong.
    var tables: [tables_max + 1]Table = undefined;
    var removed: [tables_max + 1]u64 = undefined;
    for (&tables, &removed, 0..) |*table, *removed_number, index| {
        table.* = testTable(2 + index, "a", "z");
        removed_number.* = 2 + index;
    }
    const file_number_next = 2 + tables.len;

    const too_many_added: EditHeader = .{
        .added_count = tables_max + 1,
        .removed_count = 0,
        .log_number = 1,
        .file_number_next = file_number_next,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };
    try testing.expectError(error.InvalidEdit, validate(encodeRaw(buffer, too_many_added, &tables, &.{})));

    const too_many_removed: EditHeader = .{
        .added_count = 0,
        .removed_count = tables_max + 1,
        .log_number = 1,
        .file_number_next = file_number_next,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };
    try testing.expectError(error.InvalidEdit, validate(encodeRaw(buffer, too_many_removed, &.{}, &removed)));

    // Exactly the limit of each is accepted.
    const at_the_limit: EditHeader = .{
        .added_count = tables_max,
        .removed_count = tables_max,
        .log_number = 1,
        .file_number_next = file_number_next,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };
    try validate(encodeRaw(buffer, at_the_limit, tables[0..tables_max], removed[0..tables_max]));
}

test "the largest edit fills a buffer of edit_size_max exactly, and is applied" {
    const buffer = try testing.allocator.alloc(u8, edit_size_max);
    defer testing.allocator.free(buffer);
    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);

    // A full set, with the log as file 1 and the tables numbered from 2.
    var file_number: u64 = 2;
    while (file_number < 2 + tables_max) {
        try applyEdit(&set, .{
            .added = &.{testTable(file_number, "a", "z")},
            .removed = &.{},
            .log_number = 1,
            .file_number_next = file_number + 1,
            .op_flushed = test_op_flushed,
            .sequence_flushed = test_sequence_flushed,
        });
        file_number += 1;
    }

    // Every table removed, and as many added, each with two keys of the
    // longest size.
    const longest_key: [key_size_max]u8 = @splat('k');
    var removed: [tables_max]u64 = undefined;
    var added: [tables_max]Table = undefined;
    for (&removed, &added, 0..) |*removed_number, *added_table, index| {
        removed_number.* = 2 + index;
        added_table.* = testTable(2 + tables_max + index, &longest_key, &longest_key);
    }
    const bytes = encode(.{
        .added = &added,
        .removed = &removed,
        .log_number = 1,
        .file_number_next = 2 + 2 * tables_max,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, buffer);
    try testing.expectEqual(@as(usize, edit_size_max), bytes.len);
    try validate(bytes);

    const edit: EncodedEdit = .init(bytes);
    try set.check(edit);
    set.apply(edit);
    try testing.expectEqual(@as(usize, tables_max), set.count());
    const last = set.find(2 + 2 * tables_max - 1).?;
    try testing.expectEqualSlices(u8, &longest_key, last.key_min);
    try testing.expectEqualSlices(u8, &longest_key, last.key_max);
}

test "a table's level is read back and kept" {
    // The test needs a level other than the one `testTable` gives.
    try testing.expect(level_count > 1);
    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);

    var table = testTable(2, "a", "m");
    table.level = level_count - 1;
    const tables = [_]Table{table};

    var buffer: [edit_size_max]u8 = undefined;
    const edit: EncodedEdit = .init(encode(.{
        .added = &tables,
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 3,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));

    var added = edit.added();
    try testing.expectEqual(@as(u8, level_count - 1), added.next().?.level);

    try set.check(edit);
    set.apply(edit);
    try testing.expectEqual(@as(u8, level_count - 1), set.find(2).?.level);
}

test "check rejects level 0 tables whose sequence numbers overlap" {
    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);
    // testTable gives table 2 the sequence numbers 20 to 29.
    try applyEdit(&set, .{
        .added = &.{testTable(2, "a", "m")},
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 3,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    });

    var buffer: [edit_size_max]u8 = undefined;

    // A new table that shares one sequence number with a table in the set.
    var shares_last = testTable(3, "n", "z");
    shares_last.sequence_min = 29;
    shares_last.sequence_max = 35;
    const overlaps_set: EncodedEdit = .init(encode(.{
        .added = &.{shares_last},
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 4,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(overlaps_set));

    var shares_first = testTable(3, "n", "z");
    shares_first.sequence_min = 15;
    shares_first.sequence_max = 20;
    const overlaps_set_below: EncodedEdit = .init(encode(.{
        .added = &.{shares_first},
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 4,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(overlaps_set_below));

    // The same table is fine once the edit removes the one it overlaps.
    const replaces: EncodedEdit = .init(encode(.{
        .added = &.{shares_last},
        .removed = &.{2},
        .log_number = 1,
        .file_number_next = 4,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try set.check(replaces);

    // Two new tables that overlap each other.
    var first = testTable(3, "a", "m");
    first.sequence_min = 40;
    first.sequence_max = 50;
    var second = testTable(4, "n", "z");
    second.sequence_min = 50;
    second.sequence_max = 60;
    const overlap_each_other: EncodedEdit = .init(encode(.{
        .added = &.{ first, second },
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 5,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(overlap_each_other));

    // Tables whose sequence numbers are next to each other do not overlap.
    second.sequence_min = 51;
    const side_by_side: EncodedEdit = .init(encode(.{
        .added = &.{ first, second },
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 5,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try set.check(side_by_side);

    // Above level 0 the rule does not apply: a merged table covers the
    // sequence numbers of everything that went into it.
    if (level_count > 1) {
        var merged = shares_last;
        merged.level = 1;
        const overlaps_at_level_one: EncodedEdit = .init(encode(.{
            .added = &.{merged},
            .removed = &.{},
            .log_number = 1,
            .file_number_next = 4,
            .op_flushed = test_op_flushed,
            .sequence_flushed = test_sequence_flushed,
        }, &buffer));
        try set.check(overlaps_at_level_one);
    }
}

test "validate rejects a table that does not make sense" {
    var buffer: [edit_size_max]u8 = undefined;
    const header: EditHeader = .{
        .added_count = 1,
        .removed_count = 0,
        .log_number = 5,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };
    const good = testTable(4, "a", "m");
    try validate(encodeUnchecked(&buffer, header, good));

    var file_number_zero = good;
    file_number_zero.file_number = 0;
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, header, file_number_zero)));

    var file_number_not_below_next = good;
    file_number_not_below_next.file_number = 6;
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, header, file_number_not_below_next)));

    var level_too_high = good;
    level_too_high.level = level_count;
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, header, level_too_high)));

    var sequences_backwards = good;
    sequences_backwards.sequence_min = good.sequence_max + 1;
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, header, sequences_backwards)));

    var sequence_not_flushed = good;
    sequence_not_flushed.sequence_max = header.sequence_flushed + 1;
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, header, sequence_not_flushed)));

    // A table may hold the last flushed write.
    var sequence_last_flushed = good;
    sequence_last_flushed.sequence_max = header.sequence_flushed;
    try validate(encodeUnchecked(&buffer, header, sequence_last_flushed));

    var keys_backwards = good;
    keys_backwards.key_min = "n";
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, header, keys_backwards)));

    // A table whose smallest and largest keys are the same holds one key.
    var one_key = good;
    one_key.key_max = "a";
    try validate(encodeUnchecked(&buffer, header, one_key));
}

test "validate rejects a header that does not make sense" {
    var buffer: [edit_size_max]u8 = undefined;
    const table = testTable(4, "a", "m");

    const too_many_added: EditHeader = .{
        .added_count = tables_max + 1,
        .removed_count = 0,
        .log_number = 5,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, too_many_added, table)));

    const too_many_removed: EditHeader = .{
        .added_count = 1,
        .removed_count = tables_max + 1,
        .log_number = 5,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, too_many_removed, table)));

    const log_number_not_below_next: EditHeader = .{
        .added_count = 1,
        .removed_count = 0,
        .log_number = 6,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, log_number_not_below_next, table)));

    const log_number_zero: EditHeader = .{
        .added_count = 0,
        .removed_count = 0,
        .log_number = 0,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };
    try testing.expectError(error.InvalidEdit, validate(std.mem.asBytes(&log_number_zero)));

    const next_number_zero: EditHeader = .{
        .added_count = 0,
        .removed_count = 0,
        .log_number = 0,
        .file_number_next = 0,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };
    try testing.expectError(error.InvalidEdit, validate(std.mem.asBytes(&next_number_zero)));
}

test "validate accepts keys of the longest size and rejects longer ones" {
    var buffer: [edit_size_max + 2]u8 = undefined;
    const header: EditHeader = .{
        .added_count = 1,
        .removed_count = 0,
        .log_number = 5,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    };
    const longest_key: [key_size_max]u8 = @splat('k');
    const too_long_key: [key_size_max + 1]u8 = @splat('k');

    const longest = testTable(4, &longest_key, &longest_key);
    try validate(encodeUnchecked(&buffer, header, longest));

    const too_long = testTable(4, &longest_key, &too_long_key);
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, header, too_long)));

    // The smallest key is held to the same limit. "z" sorts after it, so
    // only its length is wrong.
    const too_long_min = testTable(4, &too_long_key, "z");
    try testing.expectError(error.InvalidEdit, validate(encodeUnchecked(&buffer, header, too_long_min)));
}

/// Encodes `edit` and applies it to `set`, as a store does once it has
/// written the edit to the manifest.
fn applyEdit(set: *TableSet, edit: Edit) !void {
    var buffer: [edit_size_max]u8 = undefined;
    const encoded: EncodedEdit = .init(encode(edit, &buffer));
    try set.check(encoded);
    set.apply(encoded);
}

test "a new table set is empty" {
    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), set.count());
    try testing.expect(set.find(1) == null);
    var it = set.iterator();
    try testing.expect(it.next() == null);
}

test "applying edits adds and removes tables" {
    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);

    try applyEdit(&set, .{
        .added = &.{testTable(2, "a", "m")},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 4,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    });
    try applyEdit(&set, .{
        .added = &.{testTable(4, "b", "z")},
        .removed = &.{},
        .log_number = 5,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    });
    try testing.expectEqual(@as(usize, 2), set.count());
    try testing.expectEqual(@as(u64, 5), set.log_number);
    try testing.expectEqual(@as(u64, 6), set.file_number_next);
    try expectTable(testTable(2, "a", "m"), set.find(2).?.*);
    try expectTable(testTable(4, "b", "z"), set.find(4).?.*);

    // A compaction: both tables out, one in, in one edit.
    try applyEdit(&set, .{
        .added = &.{testTable(6, "a", "z")},
        .removed = &.{ 2, 4 },
        .log_number = 5,
        .file_number_next = 7,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    });
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expect(set.find(2) == null);
    try testing.expect(set.find(4) == null);
    try expectTable(testTable(6, "a", "z"), set.find(6).?.*);

    var it = set.iterator();
    try testing.expectEqual(@as(u64, 6), it.next().?.file_number);
    try testing.expect(it.next() == null);
}

test "a table set keeps its own copy of each table's keys" {
    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);

    var key_min = [_]u8{ 'a', 'b' };
    var key_max = [_]u8{ 'y', 'z' };
    try applyEdit(&set, .{
        .added = &.{testTable(2, &key_min, &key_max)},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 4,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    });

    // The caller's keys change. The set's do not.
    key_min[0] = 'X';
    key_max[0] = 'X';
    const table = set.find(2).?;
    try testing.expectEqualSlices(u8, "ab", table.key_min);
    try testing.expectEqualSlices(u8, "yz", table.key_max);
}

test "a full table set can have every table replaced by one edit" {
    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);

    // The log is file 1, and the tables are numbered from 2.
    const table_number_first: u64 = 2;
    var file_number: u64 = table_number_first;
    while (file_number < table_number_first + tables_max) {
        try applyEdit(&set, .{
            .added = &.{testTable(file_number, "a", "z")},
            .removed = &.{},
            .log_number = 1,
            .file_number_next = file_number + 1,
            .op_flushed = test_op_flushed,
            .sequence_flushed = test_sequence_flushed,
        });
        file_number += 1;
    }
    try testing.expectEqual(@as(usize, tables_max), set.count());

    // The cursor gives every table of a full set, each once.
    var seen: [tables_max]bool = @splat(false);
    var tables = set.iterator();
    var tables_given: usize = 0;
    while (tables.next()) |table| {
        const index: usize = @intCast(table.file_number - table_number_first);
        try testing.expect(!seen[index]);
        seen[index] = true;
        tables_given += 1;
    }
    try testing.expectEqual(@as(usize, tables_max), tables_given);

    // One more table does not fit.
    var buffer: [edit_size_max]u8 = undefined;
    const one_more: EncodedEdit = .init(encode(.{
        .added = &.{testTable(file_number, "a", "z")},
        .removed = &.{},
        .log_number = 1,
        .file_number_next = file_number + 1,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(one_more));
    try testing.expectEqual(@as(usize, tables_max), set.count());

    // Removing every table and adding as many new ones does.
    var removed: [tables_max]u64 = undefined;
    var added: [tables_max]Table = undefined;
    for (&removed, &added, 0..) |*removed_number, *added_table, index| {
        removed_number.* = table_number_first + index;
        added_table.* = testTable(file_number + index, "a", "z");
    }
    try applyEdit(&set, .{
        .added = &added,
        .removed = &removed,
        .log_number = 1,
        .file_number_next = file_number + tables_max,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    });
    try testing.expectEqual(@as(usize, tables_max), set.count());
    try testing.expect(set.find(table_number_first) == null);
    try testing.expect(set.find(file_number) != null);
}

test "check rejects an edit that does not fit the tables the set has" {
    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);
    try applyEdit(&set, .{
        .added = &.{ testTable(2, "a", "m"), testTable(3, "n", "z") },
        .removed = &.{},
        .log_number = 4,
        .file_number_next = 5,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    });

    var buffer: [edit_size_max]u8 = undefined;

    // Removes a table the set does not hold.
    const removes_unknown: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{1},
        .log_number = 4,
        .file_number_next = 5,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(removes_unknown));

    // Removes the same table twice.
    const removes_twice: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{ 2, 2 },
        .log_number = 4,
        .file_number_next = 5,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(removes_twice));

    // Adds a table under a number that has been used, even one it removes.
    const reuses_number: EncodedEdit = .init(encode(.{
        .added = &.{testTable(2, "a", "m")},
        .removed = &.{2},
        .log_number = 4,
        .file_number_next = 5,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(reuses_number));

    // Adds a table under a number an earlier file had, though no table in
    // the set has it now.
    const reuses_old_number: EncodedEdit = .init(encode(.{
        .added = &.{testTable(1, "a", "m")},
        .removed = &.{},
        .log_number = 4,
        .file_number_next = 5,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(reuses_old_number));

    // Adds two tables under one number.
    const adds_twice: EncodedEdit = .init(encode(.{
        .added = &.{ testTable(5, "a", "m"), testTable(5, "n", "z") },
        .removed = &.{},
        .log_number = 4,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(adds_twice));

    // Moves the next file number backwards.
    const next_number_backwards: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 4,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(next_number_backwards));

    // Moves the log number backwards.
    const log_number_backwards: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 5,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(log_number_backwards));

    // Gives a table the number of the log.
    const table_shares_log_number: EncodedEdit = .init(encode(.{
        .added = &.{testTable(5, "a", "m")},
        .removed = &.{},
        .log_number = 5,
        .file_number_next = 6,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(table_shares_log_number));

    // None of those changed the set.
    try testing.expectEqual(@as(usize, 2), set.count());
    try testing.expectEqual(@as(u64, 4), set.log_number);
    try testing.expectEqual(@as(u64, 5), set.file_number_next);
}

test "check rejects a log number that a file has already had" {
    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);
    try applyEdit(&set, .{
        .added = &.{ testTable(2, "a", "m"), testTable(5, "n", "z") },
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 10,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    });

    var buffer: [edit_size_max]u8 = undefined;

    // The number of a table the set holds.
    const table_number: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 5,
        .file_number_next = 10,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(table_number));

    // A number below the next one, which was handed out earlier.
    const used_number: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 7,
        .file_number_next = 10,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(used_number));

    // A new log takes a number no file has had, and the old one is kept
    // when the log does not change.
    const new_log: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 10,
        .file_number_next = 11,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try set.check(new_log);
    const same_log: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 10,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try set.check(same_log);

    // With the log kept, the next file number still may not go backwards.
    const same_log_next_backwards: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 9,
        .op_flushed = test_op_flushed,
        .sequence_flushed = test_sequence_flushed,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(same_log_next_backwards));
}

test "the flushed numbers move only with the log, and only forwards" {
    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), set.op_flushed);
    try testing.expectEqual(@as(u64, 0), set.sequence_flushed);

    // A new store: the first log, and nothing flushed.
    try applyEdit(&set, .{
        .added = &.{},
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 2,
        .op_flushed = 0,
        .sequence_flushed = 0,
    });

    // A flush: a table, a new log, and the numbers the old log reached.
    try applyEdit(&set, .{
        .added = &.{testTable(2, "a", "m")},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 4,
        .op_flushed = 20,
        .sequence_flushed = 50,
    });
    try testing.expectEqual(@as(u64, 20), set.op_flushed);
    try testing.expectEqual(@as(u64, 50), set.sequence_flushed);

    var buffer: [edit_size_max]u8 = undefined;

    // The log stays, so the numbers must stay. A compaction is like this.
    const same_log_same_numbers: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{2},
        .log_number = 3,
        .file_number_next = 4,
        .op_flushed = 20,
        .sequence_flushed = 50,
    }, &buffer));
    try set.check(same_log_same_numbers);

    const same_log_new_op: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 4,
        .op_flushed = 21,
        .sequence_flushed = 50,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(same_log_new_op));

    const same_log_new_sequence: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 4,
        .op_flushed = 20,
        .sequence_flushed = 51,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(same_log_new_sequence));

    const same_log_op_backwards: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 4,
        .op_flushed = 19,
        .sequence_flushed = 50,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(same_log_op_backwards));

    const same_log_sequence_backwards: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 3,
        .file_number_next = 4,
        .op_flushed = 20,
        .sequence_flushed = 49,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(same_log_sequence_backwards));

    // The log changes, so the numbers may rise, but not fall.
    const new_log_op_backwards: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 4,
        .file_number_next = 5,
        .op_flushed = 19,
        .sequence_flushed = 50,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(new_log_op_backwards));

    const new_log_sequence_backwards: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 4,
        .file_number_next = 5,
        .op_flushed = 20,
        .sequence_flushed = 49,
    }, &buffer));
    try testing.expectError(error.InvalidEdit, set.check(new_log_sequence_backwards));

    const new_log_numbers_forwards: EncodedEdit = .init(encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 4,
        .file_number_next = 5,
        .op_flushed = 21,
        .sequence_flushed = 51,
    }, &buffer));
    try set.check(new_log_numbers_forwards);

    // None of the rejected edits changed the set.
    try testing.expectEqual(@as(u64, 3), set.log_number);
    try testing.expectEqual(@as(u64, 20), set.op_flushed);
    try testing.expectEqual(@as(u64, 50), set.sequence_flushed);
}

/// Reads the whole manifest in `dir` into `set`, and returns where it ends.
fn readManifest(dir: Io.Dir, set: *TableSet) !wal.End {
    var buffer: [edit_size_max]u8 = undefined;
    var reader: Reader = try .open(testing.io, dir, &buffer);
    defer reader.close();

    while (try reader.next()) |edit| {
        try set.check(edit);
        set.apply(edit);
    }
    return reader.end();
}

test "edits written to a manifest rebuild the same tables when it is read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [edit_size_max]u8 = undefined;

    {
        var writer: Writer = try .create(testing.io, tmp.dir);
        defer writer.close();
        try writer.append(encode(.{
            .added = &.{testTable(2, "a", "m")},
            .removed = &.{},
            .log_number = 3,
            .file_number_next = 4,
            .op_flushed = test_op_flushed,
            .sequence_flushed = test_sequence_flushed,
        }, &buffer));
        try writer.append(encode(.{
            .added = &.{testTable(4, "b", "z")},
            .removed = &.{},
            .log_number = 5,
            .file_number_next = 6,
            .op_flushed = test_op_flushed,
            .sequence_flushed = test_sequence_flushed,
        }, &buffer));
    }

    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);
    const end = try readManifest(tmp.dir, &set);
    try testing.expectEqual(@as(usize, 2), set.count());
    try testing.expectEqual(@as(u64, 5), set.log_number);
    try testing.expectEqual(@as(u64, 6), set.file_number_next);

    // More edits are appended after the ones already there.
    {
        var writer: Writer = try .open(testing.io, tmp.dir, end);
        defer writer.close();
        try writer.append(encode(.{
            .added = &.{testTable(6, "a", "z")},
            .removed = &.{ 2, 4 },
            .log_number = 5,
            .file_number_next = 7,
            .op_flushed = test_op_flushed,
            .sequence_flushed = test_sequence_flushed,
        }, &buffer));
    }

    var reopened: TableSet = try .init(testing.allocator);
    defer reopened.deinit(testing.allocator);
    _ = try readManifest(tmp.dir, &reopened);
    try testing.expectEqual(@as(usize, 1), reopened.count());
    try expectTable(testTable(6, "a", "z"), reopened.find(6).?.*);
    try testing.expectEqual(@as(u64, 7), reopened.file_number_next);
    try testing.expectEqual(test_op_flushed, reopened.op_flushed);
    try testing.expectEqual(test_sequence_flushed, reopened.sequence_flushed);
}

test "an edit that a crash left half-written is ignored" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [edit_size_max]u8 = undefined;

    var len_after_first: u64 = 0;
    {
        var writer: Writer = try .create(testing.io, tmp.dir);
        defer writer.close();
        try writer.append(encode(.{
            .added = &.{testTable(2, "a", "m")},
            .removed = &.{},
            .log_number = 3,
            .file_number_next = 4,
            .op_flushed = test_op_flushed,
            .sequence_flushed = test_sequence_flushed,
        }, &buffer));

        const file = try tmp.dir.openFile(testing.io, file_name, .{ .mode = .read_only });
        len_after_first = try file.length(testing.io);
        file.close(testing.io);

        try writer.append(encode(.{
            .added = &.{testTable(4, "b", "z")},
            .removed = &.{},
            .log_number = 5,
            .file_number_next = 6,
            .op_flushed = test_op_flushed,
            .sequence_flushed = test_sequence_flushed,
        }, &buffer));
    }

    // Cut the file partway through the second edit.
    {
        const file = try tmp.dir.openFile(testing.io, file_name, .{ .mode = .write_only });
        defer file.close(testing.io);
        try file.setLength(testing.io, len_after_first + 10);
    }

    var set: TableSet = try .init(testing.allocator);
    defer set.deinit(testing.allocator);
    _ = try readManifest(tmp.dir, &set);
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expect(set.find(2) != null);
    try testing.expect(set.find(4) == null);
}

test "a manifest record that is not an edit is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var log: wal.Writer = try .create(testing.io, tmp.dir, file_name, edit_size_max, .none);
        defer log.close();
        _ = try log.append("not an edit");
    }

    var buffer: [edit_size_max]u8 = undefined;
    var reader: Reader = try .open(testing.io, tmp.dir, &buffer);
    defer reader.close();
    try testing.expectError(error.InvalidEdit, reader.next());
}

test "file names are the number in at least six digits and an ending" {
    var buffer: [file_name_size_max]u8 = undefined;
    try testing.expectEqualSlices(u8, "000001.log", fileName(&buffer, .log, 1));
    try testing.expectEqualSlices(u8, "000042.sst", fileName(&buffer, .table, 42));
    try testing.expectEqualSlices(u8, "1234567.sst", fileName(&buffer, .table, 1234567));

    const largest = fileName(&buffer, .log, std.math.maxInt(u64));
    try testing.expectEqualSlices(u8, "18446744073709551615.log", largest);
    try testing.expectEqual(@as(usize, file_name_size_max), largest.len);
}

test "a file name is read back as the kind and number it was made from" {
    var buffer: [file_name_size_max]u8 = undefined;
    const numbers = [_]u64{ 1, 42, 999999, 1000000, std.math.maxInt(u64) };
    for (numbers) |file_number| {
        const log = parseFileName(fileName(&buffer, .log, file_number)).?;
        try testing.expectEqual(FileKind.log, log.kind);
        try testing.expectEqual(file_number, log.file_number);

        const table = parseFileName(fileName(&buffer, .table, file_number)).?;
        try testing.expectEqual(FileKind.table, table.kind);
        try testing.expectEqual(file_number, table.file_number);
    }
}

test "a name that fileName does not produce is not a numbered file" {
    const names = [_][]const u8{
        "",
        "MANIFEST",
        "LOCK",
        "000001",
        "000001.",
        ".log",
        "000001.txt",
        "000001.log.tmp",
        "000000.log", // no file is number 0
        "1.log", // too few digits
        "0000001.log", // an extra zero
        "+00001.log",
        "-00001.log",
        "00001a.sst",
        "000001.LOG",
        "18446744073709551616.log", // one more than the largest number
    };
    for (names) |name| {
        try testing.expect(parseFileName(name) == null);
    }
}
