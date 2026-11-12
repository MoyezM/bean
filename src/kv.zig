//! The key-value store: an ordered map from byte-string keys to byte-string
//! values that survives a crash.
//!
//! A `Store` lives in one directory. Every write goes to the write-ahead log
//! and is synced before it is applied to a memtable, so a write that
//! returned without an error is durable.
//!
//! Writes are grouped into a `WriteBatch`, which is applied as a unit: after
//! a crash either every operation in it is present or none is. A batch
//! becomes exactly one record in the log.
//!
//! ## The files
//!
//!     LOCK          held locked while the store is open
//!     MANIFEST      which tables the store has, and which log (`manifest.zig`)
//!     000003.log    a write-ahead log (`wal.zig`)
//!     000002.sst    a table (`sstable.zig`)
//!
//! Logs and tables are named by number, and each new file takes the next
//! number.
//!
//! ## Two memtables
//!
//! The store has two memtables. One is active and takes the writes. When a
//! write does not fit in it, the store freezes it: a new log is started, the
//! other memtable becomes the active one, and the frozen memtable is written
//! to a table. This is a flush.
//!
//! A flush does not hold up the write that started it. Every write after it
//! does a share of the work, in proportion to its own size, so the frozen
//! memtable is on disk well before the active one is full.
//!
//! The steps of a flush, in order:
//!
//!   1. Create the new log, and switch writes to it.
//!   2. Write the frozen memtable's entries to a new table file, a share at
//!      a time.
//!   3. Finish the table, and sync the file and the directory.
//!   4. Append an edit to the manifest that adds the table and names the new
//!      log. This is the step that makes the flush count.
//!   5. Delete the frozen memtable's log, and empty the frozen memtable.
//!
//! After a crash before step 4 the manifest still names the old log, and
//! the new log is there beside it. Opening the store replays both and
//! flushes the first again. After a crash from step 4 on, the manifest
//! names the new log, and the old one is deleted when the store is opened.
//!
//! A store holds at most `tables_max` tables, and nothing merges tables
//! yet. So a store whose active memtable is full while every table slot is
//! taken reports `StoreFull`.
//!
//! ## Reads
//!
//! A read looks in the active memtable, then the other one, then the tables
//! from the newest to the oldest, and takes the first entry it finds for
//! the key.
//!
//! ## One store per directory, one thread
//!
//! A directory is open in at most one `Store` at a time. `open` takes a lock
//! on the `LOCK` file and reports `StoreAlreadyOpen` if another store holds
//! it. The store is not safe to use from more than one thread.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const constants = @import("constants.zig");
const durable = @import("durable.zig");
const manifest = @import("manifest.zig");
const MemTable = @import("memtable.zig").MemTable;
const sstable = @import("sstable.zig");
const wal = @import("wal.zig");
const write_batch = @import("write_batch.zig");
const WriteBatch = write_batch.WriteBatch;

/// The longest key the store accepts.
pub const key_size_max = write_batch.key_size_max;

/// The longest value the store accepts. A buffer of this size holds any
/// value `Store.get` can return.
pub const value_size_max = write_batch.value_size_max;

/// The most tables a store holds at once.
pub const tables_max = manifest.tables_max;

/// How many bytes of the frozen memtable a write flushes for every byte it
/// may add to the active one.
const flush_pace = constants.flush_pace;

/// The name of the file a store holds locked for as long as it is open, so
/// that a directory is never open in two stores at once. The file is empty,
/// and is left in the directory when the store is closed or when `open`
/// fails: only the lock on it means anything.
const lock_file_name = "LOCK";

/// The longest payload the store's logs accept: one batch.
const log_payload_size_max: u32 = write_batch.size_max;

/// The file number of the log a new store starts with.
const log_number_first: u64 = 1;

/// The largest op, sequence number or file number that a store accepts
/// from its files when it is opened. A store that counted up from zero
/// cannot have reached it, and stopping here leaves all the room there
/// could ever be to count on without overflowing.
const number_recovered_max: u64 = std.math.maxInt(u64) / 2;

/// The most places a scan reads from: the two memtables and every table.
const sources_max = 2 + tables_max;

comptime {
    // A flushed memtable must fit in one table. `sstable.table_size_max` is
    // the memtable's size, which holds as long as an entry takes no more
    // room in a table than it does in the memtable.
    assert(MemTable.buffer_size_max <= sstable.table_size_max);
    assert(sstable.entry_overhead <= MemTable.entry_overhead_min);

    // A batch is the payload of one log record.
    assert(write_batch.size_max <= wal.payload_size_format_max);

    // Every key and value a batch accepts is one the memtable can hold, so
    // applying a valid batch never passes the memtable an oversized entry.
    assert(write_batch.key_size_max <= MemTable.key_size_max);
    assert(write_batch.value_size_max <= MemTable.value_size_max);

    // Any batch fits in an empty memtable, so a batch can always be applied
    // once the active memtable has been frozen. Each operation takes at most
    // the memtable's largest overhead beyond its own bytes in the batch, and
    // a batch holds the most operations when every one of them is the
    // smallest.
    const overhead_max = MemTable.entrySizeMax(0, 0) - write_batch.operation_size_min;
    const batch_memtable_size_max = write_batch.size_max + write_batch.operation_count_max * overhead_max;
    assert(batch_memtable_size_max <= MemTable.buffer_size_max - MemTable.buffer_size_min);

    // The writes that fill the active memtable flush more than a whole
    // frozen one between them, so a flush ends before the next one starts.
    assert(flush_pace >= 2);
}

pub const Options = struct {
    /// Create the store if `dir` does not hold one yet.
    create_if_missing: bool = true,
};

pub const Store = struct {
    io: Io,
    /// The store's directory. The caller keeps it open for as long as the
    /// store is.
    dir: Io.Dir,
    /// Held locked from `open` to `close`.
    lock_file: Io.File,

    /// The two memtables. They are allocated apart from the store so that a
    /// flush's cursor into one stays valid if the `Store` value is moved.
    memtables: *[2]MemTable,
    /// Which of the two takes the writes. The other one is empty, unless it
    /// is frozen and being flushed.
    active_index: usize,
    /// The sequence number of the last operation written, or 0 if there has
    /// been none.
    sequence_last: u64,

    /// The log the active memtable's writes go to.
    log: wal.Writer,
    /// The file number of that log.
    log_number: u64,
    /// The next file number to hand out. It runs ahead of the manifest's,
    /// which only learns of a number when an edit is written.
    file_number_next: u64,

    /// The tables the store has, as the manifest records them.
    tables: manifest.TableSet,
    manifest_writer: manifest.Writer,
    /// One open table file for each table in `tables`.
    slots: [tables_max]TableSlot,
    /// The flush in progress, if there is one.
    flushing: ?Flush,

    /// A batch for `put` and `delete` to build their one operation in. Its
    /// buffer also holds each record while a log is replayed in `open`.
    scratch: WriteBatch,
    /// Holds one manifest edit, while it is read or written.
    edit_buffer: []u8,
    /// Room for the index of every table: `tables_max` parts of
    /// `sstable.index_size_max` bytes, one for each slot.
    index_storage: []u8,
    /// Holds the data block a flush is filling.
    flush_block_buffer: []u8,
    /// Holds the data block `get` is reading.
    get_block_buffer: []u8,

    /// Set when a write to a file has failed. The state of the files is
    /// then unknown, so every later write is refused.
    broken: bool,
    /// How many times a write or a flush has been asked for. A scan
    /// remembers this number, to tell that nothing has changed under it.
    write_count: u64,

    /// One table file, open for reading.
    const TableSlot = struct {
        in_use: bool,
        /// Only meaningful while the slot is in use.
        file_number: u64,
        reader: sstable.Reader,
    };

    /// How far a flush has got.
    const FlushStage = enum {
        /// Entries are being written to the table file.
        writing,
        /// The table file is complete and synced.
        table_written,
        /// The manifest names the table and the new log.
        table_recorded,
        /// A step failed. The frozen memtable is kept for reads, and the
        /// flush is run again when the store is next opened.
        failed,
    };

    /// A flush in progress: the frozen memtable, and the table it is being
    /// written to.
    const Flush = struct {
        stage: FlushStage,
        /// Which memtable is frozen.
        memtable_index: usize,
        /// The file number of the frozen memtable's log, which is deleted
        /// when the flush is done.
        log_number_old: u64,
        /// The last op and the last sequence number in the frozen memtable.
        /// They were noted when it was frozen: by the time the flush ends,
        /// the store's own have moved on.
        op_flushed: u64,
        sequence_flushed: u64,

        /// The file number of the table being written.
        table_number: u64,
        /// The slot the table will be opened in. The writer builds the
        /// table's index in that slot's part of `index_storage`.
        slot_index: usize,
        /// Open while the stage is `writing`.
        writer: sstable.Writer,
        cursor: MemTable.Iterator,
        /// The entry to write next, or `null` once every entry is written.
        entry_next: ?MemTable.Entry,

        /// What the manifest will record about the table. The keys point
        /// into the frozen memtable.
        key_min: []const u8,
        key_max: []const u8,
        sequence_min: u64,
        sequence_max: u64,
        /// Set once the stage is past `writing`.
        summary: sstable.Writer.Summary,
    };

    /// What a flush can report.
    pub const FlushError = error{
        /// The table that was just written does not read back as written.
        Corrupt,
    } || Io.File.OpenError || Io.File.WritePositionalError || Io.File.SyncError ||
        Io.File.LengthError || Io.File.ReadPositionalError ||
        Io.Dir.OpenError || Io.Dir.DeleteFileError;

    /// What `open` can report. `wal.Reader.open` can also report
    /// `IncompleteLog`, which is not here: `open` handles it itself.
    pub const OpenError = error{
        /// `dir` holds no store and `create_if_missing` is false.
        StoreNotFound,
        /// Another store has `dir` open, in this process or another one.
        StoreAlreadyOpen,
        /// The manifest or a log does not start with a valid file header.
        NotALog,
        /// A file is missing or damaged in a way that a crash cannot
        /// explain.
        Corrupt,
        /// A log holds a record that is not a valid batch.
        InvalidBatch,
        /// The manifest holds a record that is not a valid edit, or an edit
        /// that does not fit the edits before it.
        InvalidEdit,
        /// A log holds more than fits in a memtable.
        LogTooLargeForMemtable,
        /// A table is of a format version this code does not read.
        UnsupportedVersion,
        /// A table's index is larger than any table this code writes.
        IndexTooLarge,
        /// A table has a data block longer than any this code writes.
        BlockTooLarge,
    } || Allocator.Error || FlushError || Io.File.SetLengthError || Io.Dir.Iterator.Error;

    /// What writing a batch that holds at least one operation can report.
    pub const CommitError = error{
        /// The active memtable has no room for the batch, and every table
        /// slot is taken, so the memtable cannot be flushed to make room.
        StoreFull,
        /// An earlier write failed, and the store must be closed and opened
        /// again before it is written to.
        StoreBroken,
    } || FlushError;

    /// `write` also rejects a batch with nothing in it.
    pub const WriteError = error{
        /// The batch holds no operations.
        EmptyBatch,
    } || CommitError;

    /// `put` also rejects a key or value over the limit.
    pub const PutError = error{
        /// The key is longer than `write_batch.key_size_max`.
        KeyTooLarge,
        /// The value is longer than `write_batch.value_size_max`.
        ValueTooLarge,
    } || CommitError;

    /// `delete` also rejects a key over the limit.
    pub const DeleteError = error{
        /// The key is longer than `write_batch.key_size_max`.
        KeyTooLarge,
    } || CommitError;

    /// What a read can report: a table's data block is damaged, or cannot
    /// be read.
    pub const ReadError = sstable.Reader.ReadError;

    /// What `get` can report.
    pub const GetError = error{
        /// The value is longer than the buffer given to `get`.
        BufferTooSmall,
    } || ReadError;

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// The memory one scan works in. The caller allocates it once and can
    /// use it for one scan after another, but only for one at a time.
    pub const IteratorBuffers = struct {
        /// Room for one data block of every table: `tables_max` parts of
        /// `sstable.block_size_max` bytes.
        blocks: []u8,
        /// Holds a copy of the key the scan returned last.
        key: []u8,

        pub fn init(gpa: Allocator) Allocator.Error!IteratorBuffers {
            const blocks = try gpa.alloc(u8, tables_max * sstable.block_size_max);
            errdefer gpa.free(blocks);
            const key = try gpa.alloc(u8, key_size_max);
            return .{ .blocks = blocks, .key = key };
        }

        /// `gpa` must be the allocator passed to `init`.
        pub fn deinit(self: *IteratorBuffers, gpa: Allocator) void {
            gpa.free(self.blocks);
            gpa.free(self.key);
            self.* = undefined;
        }

        /// The part of `blocks` that belongs to one table slot.
        fn block(self: *const IteratorBuffers, slot_index: usize) []u8 {
            const start = slot_index * sstable.block_size_max;
            return self.blocks[start..][0..sstable.block_size_max];
        }
    };

    /// A forward-only cursor over the store's live entries in key order.
    /// Deleted keys are skipped.
    ///
    /// An entry the cursor returned is valid until the next call on the
    /// cursor. The cursor itself is valid until the next write to the
    /// store, or the next `flush`.
    ///
    /// The cursor points at the store it came from, so the store must not be
    /// moved or closed while the cursor is in use.
    pub const Iterator = struct {
        store: *const Store,
        /// The store's `write_count` when the cursor was made.
        write_count: u64,
        sources: [sources_max]Source,
        source_count: usize,
        /// Holds a copy of the key returned last.
        key_buffer: []u8,
        /// The key returned last, in `key_buffer`, while the sources may
        /// still be standing on entries for it. `null` once they have all
        /// been moved past it.
        key_last: ?[]const u8,

        /// One place a scan reads from, and the entry it is standing on.
        const Source = struct {
            cursor: SourceCursor,
            /// Whether `current` has been read since the cursor last moved.
            loaded: bool,
            /// The entry the source is standing on, or `null` at its end.
            /// Only meaningful while `loaded` is true.
            current: ?Version,
        };

        const SourceCursor = union(enum) {
            memtable: MemTable.Iterator,
            table: sstable.Reader.Iterator,
        };

        /// One entry of one source. A `null` value is a tombstone.
        const Version = struct {
            key: []const u8,
            value: ?[]const u8,
            sequence: u64,
        };

        /// Positions the cursor at the first entry.
        pub fn seekToFirst(self: *Iterator) void {
            assert(self.store.write_count == self.write_count);
            for (self.sources[0..self.source_count]) |*source| {
                switch (source.cursor) {
                    .memtable => |*cursor| cursor.seekToFirst(),
                    .table => |*cursor| cursor.seekToFirst(),
                }
                source.loaded = false;
            }
            self.key_last = null;
        }

        /// Positions the cursor at the first entry whose key is >= `key`.
        /// If this fails, the cursor must be positioned again before it is
        /// read.
        pub fn seek(self: *Iterator, key: []const u8) ReadError!void {
            assert(self.store.write_count == self.write_count);
            for (self.sources[0..self.source_count]) |*source| {
                switch (source.cursor) {
                    .memtable => |*cursor| cursor.seek(key),
                    .table => |*cursor| try cursor.seek(key),
                }
                source.loaded = false;
            }
            self.key_last = null;
        }

        /// Returns the entry at the cursor and advances past it, or returns
        /// `null` after the last entry.
        pub fn next(self: *Iterator) ReadError!?Entry {
            assert(self.store.write_count == self.write_count);
            while (true) {
                try self.skipKeyLast();

                const found = try self.newestOfSmallestKey();
                if (found == null) {
                    return null;
                }
                const version = found.?;

                // The sources are left standing on this key, so that the
                // value stays valid until the next call. The key is copied
                // because moving a source past it can overwrite it.
                if (version.key.len > self.key_buffer.len) {
                    // No table the store wrote holds a key this long.
                    return error.Corrupt;
                }
                const key_copy = self.key_buffer[0..version.key.len];
                @memcpy(key_copy, version.key);
                self.key_last = key_copy;

                // A tombstone means the key was deleted.
                if (version.value == null) {
                    continue;
                }
                return .{ .key = key_copy, .value = version.value.? };
            }
        }

        /// Moves every source past the key returned last, if any source may
        /// still be standing on it. Older entries for that key, in any
        /// source, are passed over here.
        fn skipKeyLast(self: *Iterator) ReadError!void {
            if (self.key_last == null) {
                return;
            }
            const key = self.key_last.?;
            for (self.sources[0..self.source_count]) |*source| {
                while (true) {
                    try load(source);
                    if (source.current == null) {
                        break;
                    }
                    if (!std.mem.eql(u8, source.current.?.key, key)) {
                        break;
                    }
                    source.loaded = false;
                }
            }
            self.key_last = null;
        }

        /// Of the entries the sources are standing on, returns the one with
        /// the smallest key, and among those with that key the newest. No
        /// source is moved.
        fn newestOfSmallestKey(self: *Iterator) ReadError!?Version {
            var best: ?Version = null;
            for (self.sources[0..self.source_count]) |*source| {
                try load(source);
                if (source.current == null) {
                    continue;
                }
                const candidate = source.current.?;
                if (best == null) {
                    best = candidate;
                    continue;
                }
                if (sstable.sortsBefore(candidate.key, candidate.sequence, best.?.key, best.?.sequence)) {
                    best = candidate;
                }
            }
            return best;
        }

        /// Reads the entry a source is standing on, if it has not been read
        /// yet. Reading it moves the source's own cursor on to the next
        /// entry, which is why a source that is to move only has `loaded`
        /// cleared.
        fn load(source: *Source) ReadError!void {
            if (source.loaded) {
                return;
            }
            switch (source.cursor) {
                .memtable => |*cursor| {
                    const entry = cursor.next();
                    if (entry == null) {
                        source.current = null;
                    } else {
                        source.current = .{
                            .key = entry.?.key,
                            .value = entry.?.value,
                            .sequence = entry.?.sequence,
                        };
                    }
                },
                .table => |*cursor| {
                    const entry = try cursor.next();
                    if (entry == null) {
                        source.current = null;
                    } else {
                        source.current = .{
                            .key = entry.?.key,
                            .value = entry.?.value,
                            .sequence = entry.?.sequence,
                        };
                    }
                },
            }
            source.loaded = true;
        }
    };

    /// Opens the store in `dir`, creating it if it is not there and
    /// `options` allow that. A flush that a crash interrupted is run again
    /// here, and the logs are replayed.
    ///
    /// `gpa` is used only here, to allocate everything the store will need,
    /// and is not retained. `dir` must stay open until the store is closed.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, options: Options) OpenError!Store {
        return openWithMemtableSize(gpa, io, dir, options, MemTable.buffer_size_max);
    }

    /// `open`, with memtables of `memtable_size` bytes each. A store always
    /// has memtables of the largest size; tests use small ones so that a
    /// flush takes few writes. A batch must fit in an empty memtable.
    fn openWithMemtableSize(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        options: Options,
        memtable_size: usize,
    ) OpenError!Store {
        // The lock comes first: opening a store can delete and truncate
        // files, which must not happen under a store that is already open.
        const lock_file = try lockDir(io, dir);
        errdefer lock_file.close(io);

        const memtables = try gpa.create([2]MemTable);
        errdefer gpa.destroy(memtables);
        memtables[0] = try .init(gpa, memtable_size);
        errdefer memtables[0].deinit(gpa);
        memtables[1] = try .init(gpa, memtable_size);
        errdefer memtables[1].deinit(gpa);

        var tables: manifest.TableSet = try .init(gpa);
        errdefer tables.deinit(gpa);
        var scratch: WriteBatch = try .init(gpa);
        errdefer scratch.deinit(gpa);

        const edit_buffer = try gpa.alloc(u8, manifest.edit_size_max);
        errdefer gpa.free(edit_buffer);
        const index_storage = try gpa.alloc(u8, tables_max * sstable.index_size_max);
        errdefer gpa.free(index_storage);
        const flush_block_buffer = try gpa.alloc(u8, sstable.block_size_max);
        errdefer gpa.free(flush_block_buffer);
        const get_block_buffer = try gpa.alloc(u8, sstable.block_size_max);
        errdefer gpa.free(get_block_buffer);

        var slots: [tables_max]TableSlot = undefined;
        for (&slots) |*slot| {
            slot.in_use = false;
        }

        var store: Store = .{
            .io = io,
            .dir = dir,
            .lock_file = lock_file,
            .memtables = memtables,
            .active_index = 0,
            .sequence_last = 0,
            // The log and the manifest are opened by `recover`.
            .log = undefined,
            .log_number = 0,
            .file_number_next = 0,
            .tables = tables,
            .manifest_writer = undefined,
            .slots = slots,
            .flushing = null,
            .scratch = scratch,
            .edit_buffer = edit_buffer,
            .index_storage = index_storage,
            .flush_block_buffer = flush_block_buffer,
            .get_block_buffer = get_block_buffer,
            .broken = false,
            .write_count = 0,
        };
        try store.recover(options);
        return store;
    }

    /// Closes the store's files and frees its memory. Nothing is flushed:
    /// what the memtables hold is in the logs, and is replayed when the
    /// store is next opened.
    ///
    /// `gpa` must be the allocator passed to `open`.
    pub fn close(self: *Store, gpa: Allocator) void {
        if (self.flushing != null) {
            const flushing = &self.flushing.?;
            if (flushing.stage == .writing) {
                flushing.writer.close();
            }
        }
        self.closeTables();
        self.manifest_writer.close();
        self.log.close();

        self.memtables[0].deinit(gpa);
        self.memtables[1].deinit(gpa);
        gpa.destroy(self.memtables);
        self.tables.deinit(gpa);
        self.scratch.deinit(gpa);
        gpa.free(self.edit_buffer);
        gpa.free(self.index_storage);
        gpa.free(self.flush_block_buffer);
        gpa.free(self.get_block_buffer);

        // Closing the file releases the lock.
        self.lock_file.close(self.io);
        self.* = undefined;
    }

    /// Applies `batch` as a unit. When this returns without an error, the
    /// batch is durable.
    ///
    /// `EmptyBatch`, `StoreFull` and `StoreBroken` are reported before the
    /// batch is written anywhere. `EmptyBatch` and `StoreFull` leave the
    /// store usable.
    ///
    /// After any other error the batch may or may not be in the log: it can
    /// appear when the store is next opened. Every later write returns
    /// `StoreBroken` until the store is closed and opened again.
    pub fn write(self: *Store, batch: *const WriteBatch) WriteError!void {
        // An empty batch is never logged: replay rejects an empty record.
        if (batch.count() == 0) {
            return error.EmptyBatch;
        }
        try self.commit(batch);
    }

    /// Writes a batch holding one put. `StoreFull` and `StoreBroken` mean
    /// what they do for `write`.
    pub fn put(self: *Store, key: []const u8, value: []const u8) PutError!void {
        self.scratch.clear();
        self.scratch.put(key, value) catch |err| switch (err) {
            error.KeyTooLarge => return error.KeyTooLarge,
            error.ValueTooLarge => return error.ValueTooLarge,
            // One operation always fits in an empty batch.
            error.BatchFull => unreachable,
        };
        try self.commit(&self.scratch);
    }

    /// Writes a batch holding one delete. Deleting a key that is not present
    /// is not an error. `StoreFull` and `StoreBroken` mean what they do for
    /// `write`.
    pub fn delete(self: *Store, key: []const u8) DeleteError!void {
        self.scratch.clear();
        self.scratch.delete(key) catch |err| switch (err) {
            error.KeyTooLarge => return error.KeyTooLarge,
            // A delete has no value.
            error.ValueTooLarge => unreachable,
            // One operation always fits in an empty batch.
            error.BatchFull => unreachable,
        };
        try self.commit(&self.scratch);
    }

    /// Does this write's share of a flush in progress, makes room for
    /// `batch` if the active memtable has none, then logs the batch and
    /// applies it to the active memtable. `batch` must hold at least one
    /// operation.
    fn commit(self: *Store, batch: *const WriteBatch) CommitError!void {
        assert(batch.count() > 0);
        if (self.broken) {
            return error.StoreBroken;
        }
        self.write_count += 1;

        const batch_bytes = batch.bytes();
        const batch_memtable_size = memtableSizeMax(batch_bytes);

        // The share comes before the batch is logged, so that an error from
        // the flush leaves the batch unwritten.
        if (self.flushing != null) {
            try self.flushStep(flush_pace * batch_memtable_size);
        }

        // The batch goes to the log only if all of it can then be applied.
        if (batch_memtable_size > self.activeMemtable().bytesFree()) {
            try self.makeRoom();
            assert(batch_memtable_size <= self.activeMemtable().bytesFree());
        }

        _ = self.log.append(batch_bytes) catch |err| switch (err) {
            // A batch is never longer than the log's payload limit.
            error.PayloadTooLarge => unreachable,
            else => |other| {
                self.broken = true;
                return other;
            },
        };
        const memtable = self.activeMemtable();
        self.sequence_last = applyBatch(memtable, batch_bytes, self.sequence_last + 1);
    }

    /// Freezes the full active memtable, so that the other one, which is
    /// empty, takes the writes.
    fn makeRoom(self: *Store) CommitError!void {
        // The shares that writes do are sized so that a flush is over
        // before the active memtable fills again. The store does not depend
        // on that: a flush that is still going is finished here.
        if (self.flushing != null) {
            try self.flushComplete();
        }
        // The frozen memtable needs a table slot to be flushed into.
        if (self.tables.count() == tables_max) {
            return error.StoreFull;
        }
        self.freeze() catch |err| {
            self.broken = true;
            return err;
        };
    }

    /// Writes everything the memtables hold to tables, and returns once the
    /// tables are durable. The store does this by itself as memtables fill;
    /// this is for a caller that wants the logs emptied now.
    ///
    /// `StoreFull` means every table slot is taken and the active memtable
    /// was left as it is. After any error but `StoreFull` and `StoreBroken`,
    /// every later write returns `StoreBroken` until the store is closed and
    /// opened again.
    pub fn flush(self: *Store) CommitError!void {
        if (self.broken) {
            return error.StoreBroken;
        }
        self.write_count += 1;

        if (self.flushing != null) {
            try self.flushComplete();
        }
        // An empty memtable is never written to a table.
        if (self.activeMemtable().isEmpty()) {
            return;
        }
        if (self.tables.count() == tables_max) {
            return error.StoreFull;
        }
        self.freeze() catch |err| {
            self.broken = true;
            return err;
        };
        try self.flushComplete();
    }

    /// Copies the value for `key` into `buffer` and returns the part of
    /// `buffer` that holds it, or returns `null` if the key is not present.
    ///
    /// The bytes returned are the caller's own. Nothing the store does
    /// later changes them.
    ///
    /// A buffer of `value_size_max` bytes holds any value. With a shorter
    /// buffer, a value that does not fit is reported as `BufferTooSmall`,
    /// and nothing is copied.
    pub fn get(self: *Store, key: []const u8, buffer: []u8) GetError!?[]u8 {
        // The active memtable holds the newest writes, and the other one,
        // when it is frozen, the writes before those. Both are newer than
        // every table.
        const in_active = self.activeMemtable().get(key);
        switch (in_active) {
            .value => |value| return try copyValue(value, buffer),
            .tombstone => return null,
            .absent => {},
        }
        const in_other = self.otherMemtable().get(key);
        switch (in_other) {
            .value => |value| return try copyValue(value, buffer),
            .tombstone => return null,
            .absent => {},
        }

        // The tables, from the newest to the oldest. The first one that has
        // an entry for the key has the newest one.
        var sequence_limit: ?u64 = null;
        while (true) {
            const found = self.newestTableOlderThan(sequence_limit);
            if (found == null) {
                return null;
            }
            const slot = found.?;
            const table = self.tables.find(slot.file_number).?;
            sequence_limit = table.sequence_max;

            if (std.mem.order(u8, key, table.key_min) == .lt) {
                continue;
            }
            if (std.mem.order(u8, key, table.key_max) == .gt) {
                continue;
            }
            const in_table = try slot.reader.get(key, self.get_block_buffer);
            switch (in_table) {
                .value => |value| return try copyValue(value, buffer),
                .tombstone => return null,
                .absent => {},
            }
        }
    }

    /// Returns the open table with the largest sequence numbers among those
    /// whose sequence numbers are all below `sequence_limit`, or among all
    /// of them if `sequence_limit` is `null`. Tables written by flushes
    /// hold ranges of sequence numbers that do not overlap, so calling this
    /// with each table's largest number in turn visits them newest first.
    fn newestTableOlderThan(self: *const Store, sequence_limit: ?u64) ?*const TableSlot {
        var newest: ?*const TableSlot = null;
        var newest_sequence_max: u64 = 0;
        for (&self.slots) |*slot| {
            if (!slot.in_use) {
                continue;
            }
            const table = self.tables.find(slot.file_number).?;
            if (sequence_limit != null) {
                if (table.sequence_max >= sequence_limit.?) {
                    continue;
                }
            }
            if (newest == null or table.sequence_max > newest_sequence_max) {
                newest = slot;
                newest_sequence_max = table.sequence_max;
            }
        }
        return newest;
    }

    /// Returns a cursor positioned at the first entry. It works in
    /// `buffers`, which must stay valid, and be used by no other cursor,
    /// for as long as this one is in use.
    ///
    /// The cursor keeps a pointer to this store, so the store must not be
    /// moved or closed while the cursor is in use.
    pub fn iterator(self: *const Store, buffers: *const IteratorBuffers) Iterator {
        var it: Iterator = .{
            .store = self,
            .write_count = self.write_count,
            .sources = undefined,
            .source_count = 0,
            .key_buffer = buffers.key,
            .key_last = null,
        };

        for (self.memtables) |*memtable| {
            it.sources[it.source_count] = .{
                .cursor = .{ .memtable = memtable.iterator() },
                .loaded = false,
                .current = null,
            };
            it.source_count += 1;
        }
        for (&self.slots, 0..) |*slot, slot_index| {
            if (!slot.in_use) {
                continue;
            }
            it.sources[it.source_count] = .{
                .cursor = .{ .table = slot.reader.iterator(buffers.block(slot_index)) },
                .loaded = false,
                .current = null,
            };
            it.source_count += 1;
        }
        return it;
    }

    /// The op number of the last batch written, or 0 if there has been none.
    /// Each batch is given the next op number.
    pub fn opLatest(self: *const Store) u64 {
        return self.log.last.op;
    }

    /// The sequence number of the last operation written, or 0 if there has
    /// been none. Each operation of each batch is given the next sequence
    /// number, so a batch of three operations takes three of them.
    pub fn sequenceLatest(self: *const Store) u64 {
        return self.sequence_last;
    }

    /// The memtable that takes the writes.
    fn activeMemtable(self: *const Store) *MemTable {
        return &self.memtables[self.active_index];
    }

    /// The memtable that does not take the writes. It is empty unless it is
    /// frozen.
    fn otherMemtable(self: *const Store) *MemTable {
        return &self.memtables[1 - self.active_index];
    }

    /// The part of `index_storage` that belongs to one table slot.
    fn slotIndexBuffer(self: *const Store, slot_index: usize) []u8 {
        const start = slot_index * sstable.index_size_max;
        return self.index_storage[start..][0..sstable.index_size_max];
    }

    /// The index of a slot that holds no table, or `null` if every slot is
    /// taken.
    fn freeSlotIndex(self: *const Store) ?usize {
        for (self.slots, 0..) |slot, slot_index| {
            if (!slot.in_use) {
                return slot_index;
            }
        }
        return null;
    }

    /// Closes every open table file.
    fn closeTables(self: *Store) void {
        for (&self.slots) |*slot| {
            if (slot.in_use) {
                slot.reader.close();
                slot.in_use = false;
            }
        }
    }

    // ---- Flushing ----

    /// Step 1 of a flush. Starts a new log, begins writing the active
    /// memtable to a table, and makes the other memtable the active one.
    ///
    /// The caller has checked that no flush is in progress, that the active
    /// memtable holds something, and that a table slot is free. If this
    /// fails, the store is as it was.
    fn freeze(self: *Store) FlushError!void {
        assert(self.flushing == null);
        assert(self.otherMemtable().isEmpty());

        const log_number_new = self.file_number_next;
        self.file_number_next += 1;
        var name_buffer: [manifest.file_name_size_max]u8 = undefined;
        const log_name = manifest.fileName(&name_buffer, .log, log_number_new);

        // The new log carries on from the last record of the current one.
        var log_new = try wal.Writer.create(
            self.io,
            self.dir,
            log_name,
            log_payload_size_max,
            self.log.last,
        );
        errdefer {
            log_new.close();
            self.dir.deleteFile(self.io, log_name) catch {};
        }

        try self.flushBegin(
            self.active_index,
            self.log_number,
            self.log.last.op,
            self.sequence_last,
        );

        self.log.close();
        self.log = log_new;
        self.log_number = log_number_new;
        self.active_index = 1 - self.active_index;
    }

    /// Creates the table file that memtable `memtable_index` will be
    /// written to, and records the flush as in progress. `log_number_old`
    /// is the log that holds that memtable's writes, and `op_flushed` and
    /// `sequence_flushed` are the last op and sequence number in it.
    fn flushBegin(
        self: *Store,
        memtable_index: usize,
        log_number_old: u64,
        op_flushed: u64,
        sequence_flushed: u64,
    ) FlushError!void {
        assert(self.flushing == null);
        const memtable = &self.memtables[memtable_index];
        assert(!memtable.isEmpty());
        const slot_index = self.freeSlotIndex().?;

        const table_number = self.file_number_next;
        self.file_number_next += 1;
        var name_buffer: [manifest.file_name_size_max]u8 = undefined;
        const table_name = manifest.fileName(&name_buffer, .table, table_number);

        const writer = try sstable.Writer.create(self.io, self.dir, table_name, .{}, .{
            .block = self.flush_block_buffer,
            .index = self.slotIndexBuffer(slot_index),
        });

        var cursor = memtable.iterator();
        const entry_first = cursor.nextVersion().?;
        self.flushing = .{
            .stage = .writing,
            .memtable_index = memtable_index,
            .log_number_old = log_number_old,
            .op_flushed = op_flushed,
            .sequence_flushed = sequence_flushed,
            .table_number = table_number,
            .slot_index = slot_index,
            .writer = writer,
            .cursor = cursor,
            .entry_next = entry_first,
            .key_min = entry_first.key,
            .key_max = entry_first.key,
            .sequence_min = entry_first.sequence,
            .sequence_max = entry_first.sequence,
            .summary = undefined,
        };
    }

    /// Does one write's share of the flush in progress: writes entries to
    /// the table until `budget` bytes of the frozen memtable are done, and
    /// carries the flush through to its end if those were the last. On an
    /// error the store is marked broken.
    fn flushStep(self: *Store, budget: usize) FlushError!void {
        self.flushStepStages(budget) catch |err| {
            self.flushFailed();
            return err;
        };
    }

    fn flushStepStages(self: *Store, budget: usize) FlushError!void {
        if (self.flushing.?.stage == .writing) {
            try self.flushWriteEntries(budget);
            if (self.flushing.?.entry_next != null) {
                return;
            }
        }
        try self.flushCompleteStages();
    }

    /// Carries the flush in progress through to its end. On an error the
    /// store is marked broken.
    fn flushComplete(self: *Store) FlushError!void {
        self.flushCompleteStages() catch |err| {
            self.flushFailed();
            return err;
        };
    }

    fn flushCompleteStages(self: *Store) FlushError!void {
        if (self.flushing.?.stage == .writing) {
            try self.flushWriteEntries(std.math.maxInt(usize));
            try self.flushFinishTable();
        }
        if (self.flushing.?.stage == .table_written) {
            try self.flushRecordTable();
        }
        assert(self.flushing.?.stage == .table_recorded);
        try self.flushRetireLog();
    }

    /// Marks the store broken after a step of the flush failed. The frozen
    /// memtable is kept, so reads still see what it holds.
    fn flushFailed(self: *Store) void {
        self.broken = true;
        const flushing = &self.flushing.?;
        if (flushing.stage == .writing) {
            flushing.writer.close();
        }
        flushing.stage = .failed;
    }

    /// Step 2 of a flush. Writes entries of the frozen memtable to the
    /// table, in order, until `budget` bytes of the memtable are done or
    /// there are no more entries. Every entry is written: older entries for
    /// a key and tombstones too.
    fn flushWriteEntries(self: *Store, budget: usize) FlushError!void {
        const flushing = &self.flushing.?;
        assert(flushing.stage == .writing);

        var bytes_done: usize = 0;
        while (bytes_done < budget) {
            if (flushing.entry_next == null) {
                return;
            }
            const entry = flushing.entry_next.?;

            flushing.writer.add(entry.key, entry.value, entry.sequence) catch |err| switch (err) {
                // The writer's buffers are sized for any memtable.
                error.EntryTooLarge => unreachable,
                error.TableFull => unreachable,
                else => |other| return other,
            };

            // The entries come in key order, so the last one written has
            // the largest key so far.
            flushing.key_max = entry.key;
            flushing.sequence_min = @min(flushing.sequence_min, entry.sequence);
            flushing.sequence_max = @max(flushing.sequence_max, entry.sequence);

            bytes_done += memtableSizeMin(entry);
            flushing.entry_next = flushing.cursor.nextVersion();
        }
    }

    /// Step 3 of a flush. Completes the table file and makes it, and its
    /// name, durable.
    fn flushFinishTable(self: *Store) FlushError!void {
        const flushing = &self.flushing.?;
        assert(flushing.stage == .writing);
        assert(flushing.entry_next == null);

        flushing.summary = try flushing.writer.finish();
        flushing.writer.close();
        flushing.stage = .table_written;

        try durable.syncDir(self.io, self.dir);
    }

    /// Step 4 of a flush. Opens the new table for reading and appends the
    /// edit that adds it to the manifest. Once the edit is durable, the
    /// table holds the frozen memtable's writes for good, and the frozen
    /// memtable's log is no longer needed.
    fn flushRecordTable(self: *Store) FlushError!void {
        const flushing = &self.flushing.?;
        assert(flushing.stage == .table_written);

        var name_buffer: [manifest.file_name_size_max]u8 = undefined;
        const table_name = manifest.fileName(&name_buffer, .table, flushing.table_number);
        const index_buffer = self.slotIndexBuffer(flushing.slot_index);
        var reader = sstable.Reader.open(self.io, self.dir, table_name, index_buffer) catch |err| switch (err) {
            // The file was written a moment ago by this code.
            error.UnsupportedVersion => return error.Corrupt,
            error.IndexTooLarge => return error.Corrupt,
            else => |other| return other,
        };
        errdefer reader.close();
        if (reader.fileSize() != flushing.summary.file_size) {
            return error.Corrupt;
        }
        if (reader.checksum() != flushing.summary.checksum) {
            return error.Corrupt;
        }

        const table: manifest.Table = .{
            .file_number = flushing.table_number,
            .level = 0,
            .file_size = flushing.summary.file_size,
            .checksum = flushing.summary.checksum,
            .sequence_min = flushing.sequence_min,
            .sequence_max = flushing.sequence_max,
            .key_min = flushing.key_min,
            .key_max = flushing.key_max,
        };
        const tables_added = [_]manifest.Table{table};
        const edit_bytes = manifest.encode(.{
            .added = &tables_added,
            .removed = &.{},
            // The log that was started when the memtable was frozen.
            .log_number = self.log_number,
            .file_number_next = self.file_number_next,
            .op_flushed = flushing.op_flushed,
            .sequence_flushed = flushing.sequence_flushed,
        }, self.edit_buffer);
        const edit: manifest.EncodedEdit = .init(edit_bytes);
        // The store only builds edits that fit the tables it has.
        self.tables.check(edit) catch unreachable;

        try self.manifest_writer.append(edit_bytes);
        self.tables.apply(edit);
        self.slots[flushing.slot_index] = .{
            .in_use = true,
            .file_number = flushing.table_number,
            .reader = reader,
        };
        flushing.stage = .table_recorded;
    }

    /// Step 5 of a flush. Deletes the frozen memtable's log and empties the
    /// frozen memtable. The table has everything both of them held.
    fn flushRetireLog(self: *Store) FlushError!void {
        const flushing = &self.flushing.?;
        assert(flushing.stage == .table_recorded);

        var name_buffer: [manifest.file_name_size_max]u8 = undefined;
        const log_name = manifest.fileName(&name_buffer, .log, flushing.log_number_old);
        try self.dir.deleteFile(self.io, log_name);

        self.memtables[flushing.memtable_index].reset();
        self.flushing = null;
    }

    // ---- Opening ----

    /// Brings a store whose memory is allocated, and which holds no files
    /// but the lock, to the state its directory describes. If this fails,
    /// every file it opened is closed again.
    fn recover(self: *Store, options: Options) OpenError!void {
        const manifest_end = try self.readManifest();
        if (manifest_end == null) {
            if (!options.create_if_missing) {
                return error.StoreNotFound;
            }
            try self.create();
            return;
        }

        // First, everything the manifest says is checked against the
        // directory, and nothing in the directory is changed. A manifest
        // that has lost its last edits names files that are gone, and
        // would have the files that hold the data deleted as strays.
        const log_number_newer_found = try self.findNewerLog();

        errdefer self.closeTables();
        try self.openTables();

        // The log the manifest names holds the writes that are in no table.
        // It was created and synced before the manifest named it, so it is
        // there, and whole.
        const log_number_named = self.tables.log_number;
        const named = self.replayLog(
            log_number_named,
            &self.memtables[0],
            self.tables.sequence_flushed,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.Corrupt,
            error.IncompleteLog => return error.Corrupt,
            else => |other| return other,
        };
        if (named.previous.op != self.tables.op_flushed) {
            return error.Corrupt;
        }

        // A log newer than that one was started by a flush that a crash
        // interrupted. It holds the writes made after the first log's
        // memtable was frozen.
        var newer: ?ReplayedLog = null;
        var log_number_newer: u64 = 0;
        var newer_is_incomplete = false;
        if (log_number_newer_found != null) {
            log_number_newer = log_number_newer_found.?;
            // A log started after the manifest's last edit took a file
            // number the manifest had not handed out.
            if (log_number_newer < self.tables.file_number_next) {
                return error.Corrupt;
            }
            if (log_number_newer > number_recovered_max) {
                return error.Corrupt;
            }

            const replayed = self.replayLog(
                log_number_newer,
                &self.memtables[1],
                named.sequence_last,
            );
            if (replayed) |replayed_log| {
                newer = replayed_log;
            } else |err| switch (err) {
                // The crash came while the new log was being created. It
                // holds nothing, and nothing was frozen yet.
                error.IncompleteLog => newer_is_incomplete = true,
                else => |other| return other,
            }
        }

        if (newer != null) {
            // The newer log must carry on from the last record of the named
            // one.
            if (newer.?.previous.op != named.end.last.op) {
                return error.Corrupt;
            }
            if (newer.?.previous.checksum != named.end.last.checksum) {
                return error.Corrupt;
            }
            // A memtable is only frozen when it holds something and a table
            // slot is free for it.
            if (self.memtables[0].isEmpty()) {
                return error.Corrupt;
            }
            if (self.tables.count() == tables_max) {
                return error.Corrupt;
            }
        }

        // The directory is what the manifest describes. From here on files
        // are changed: strays are deleted, the manifest and the log lose a
        // record that a crash left half-written, and an interrupted flush
        // is run again.
        try self.removeStrayFiles();
        if (newer_is_incomplete) {
            var name_buffer: [manifest.file_name_size_max]u8 = undefined;
            const log_name = manifest.fileName(&name_buffer, .log, log_number_newer);
            try self.dir.deleteFile(self.io, log_name);
        }

        self.manifest_writer = try manifest.Writer.open(self.io, self.dir, manifest_end.?);
        errdefer self.manifest_writer.close();

        self.active_index = 0;
        self.sequence_last = named.sequence_last;
        self.log_number = log_number_named;
        self.file_number_next = self.tables.file_number_next;
        var log_end = named.end;

        if (newer != null) {
            self.active_index = 1;
            self.sequence_last = newer.?.sequence_last;
            self.log_number = log_number_newer;
            self.file_number_next = log_number_newer + 1;
            log_end = newer.?.end;

            // Run the interrupted flush again, from the start.
            try self.flushBegin(
                0,
                log_number_named,
                named.end.last.op,
                named.sequence_last,
            );
            try self.flushComplete();
        }

        var name_buffer: [manifest.file_name_size_max]u8 = undefined;
        const log_name = manifest.fileName(&name_buffer, .log, self.log_number);
        self.log = try wal.Writer.open(self.io, self.dir, log_name, log_payload_size_max, log_end);
    }

    /// Reads the manifest and applies its edits to `tables`. Returns where
    /// the manifest ends, or `null` if the directory holds no store: there
    /// is no manifest, or a crash while the store was being created left
    /// one with no edits in it.
    fn readManifest(self: *Store) OpenError!?wal.End {
        var reader = manifest.Reader.open(self.io, self.dir, self.edit_buffer) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.IncompleteLog => return null,
            else => |other| return other,
        };
        defer reader.close();

        var edit_count: u64 = 0;
        while (true) {
            const edit = try reader.next();
            if (edit == null) {
                break;
            }
            try self.tables.check(edit.?);
            self.tables.apply(edit.?);
            edit_count += 1;
        }
        if (edit_count == 0) {
            return null;
        }

        // The store counts on from each of these, so none may be so large
        // that counting on could overflow.
        const manifest_end = reader.end();
        if (manifest_end.last.op > number_recovered_max) {
            return error.Corrupt;
        }
        if (self.tables.op_flushed > number_recovered_max) {
            return error.Corrupt;
        }
        if (self.tables.sequence_flushed > number_recovered_max) {
            return error.Corrupt;
        }
        if (self.tables.file_number_next > number_recovered_max) {
            return error.Corrupt;
        }
        return manifest_end;
    }

    /// Creates a new store: its first log, then a manifest whose first edit
    /// names that log.
    fn create(self: *Store) OpenError!void {
        try self.removeCreationLeftovers();

        var name_buffer: [manifest.file_name_size_max]u8 = undefined;
        const log_name = manifest.fileName(&name_buffer, .log, log_number_first);
        self.log = try wal.Writer.create(self.io, self.dir, log_name, log_payload_size_max, .none);
        errdefer self.log.close();

        self.manifest_writer = try manifest.Writer.create(self.io, self.dir);
        errdefer self.manifest_writer.close();

        const edit_bytes = manifest.encode(.{
            .added = &.{},
            .removed = &.{},
            .log_number = log_number_first,
            .file_number_next = log_number_first + 1,
            .op_flushed = 0,
            .sequence_flushed = 0,
        }, self.edit_buffer);
        const edit: manifest.EncodedEdit = .init(edit_bytes);
        self.tables.check(edit) catch unreachable;
        try self.manifest_writer.append(edit_bytes);
        self.tables.apply(edit);

        self.active_index = 0;
        self.sequence_last = 0;
        self.log_number = log_number_first;
        self.file_number_next = log_number_first + 1;
    }

    /// Removes what a crash while a store was being created can leave: a
    /// manifest with no edits, and a first log with no records. A first log
    /// that holds records is not such a leftover, and is reported.
    fn removeCreationLeftovers(self: *Store) OpenError!void {
        // A store that was never fully created has no file but its first
        // log. Any other numbered file belongs to a store whose manifest
        // has been lost.
        {
            var listing = try self.dir.openDir(self.io, ".", .{ .iterate = true });
            defer listing.close(self.io);
            var entries = listing.iterate();
            while (true) {
                const entry = try entries.next(self.io);
                if (entry == null) {
                    break;
                }
                const parsed = manifest.parseFileName(entry.?.name);
                if (parsed == null) {
                    continue;
                }
                if (parsed.?.kind != .log) {
                    return error.Corrupt;
                }
                if (parsed.?.file_number != log_number_first) {
                    return error.Corrupt;
                }
            }
        }

        var name_buffer: [manifest.file_name_size_max]u8 = undefined;
        const log_name = manifest.fileName(&name_buffer, .log, log_number_first);

        var log_is_there = true;
        var reader_or_error = wal.Reader.open(self.io, self.dir, log_name, self.scratch.buffer);
        if (reader_or_error) |*reader| {
            defer reader.close();
            const record = try reader.next();
            if (record != null) {
                // Writes were made here, and there is no manifest to say
                // which tables go with them.
                return error.Corrupt;
            }
        } else |err| switch (err) {
            error.FileNotFound => log_is_there = false,
            error.IncompleteLog => {},
            else => |other| return other,
        }
        if (log_is_there) {
            try self.dir.deleteFile(self.io, log_name);
        }

        self.dir.deleteFile(self.io, manifest.file_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |other| return other,
        };
    }

    /// Looks in the directory for a log newer than the one the manifest
    /// names, and returns its file number. There is at most one: the log a
    /// flush started before a crash. Nothing is changed.
    fn findNewerLog(self: *Store) OpenError!?u64 {
        var log_number_newer: ?u64 = null;

        var listing = try self.dir.openDir(self.io, ".", .{ .iterate = true });
        defer listing.close(self.io);
        var entries = listing.iterate();
        while (true) {
            const entry = try entries.next(self.io);
            if (entry == null) {
                return log_number_newer;
            }
            const parsed = manifest.parseFileName(entry.?.name);
            if (parsed == null) {
                continue;
            }
            if (parsed.?.kind != .log) {
                continue;
            }
            if (parsed.?.file_number <= self.tables.log_number) {
                continue;
            }
            if (log_number_newer != null) {
                return error.Corrupt;
            }
            log_number_newer = parsed.?.file_number;
        }
    }

    /// Deletes the numbered files that the manifest does not account for: a
    /// table it does not hold, which a flush wrote before a crash, and a
    /// log older than the one it names, which a flush had finished with.
    ///
    /// A log newer than the one the manifest names is left alone: it holds
    /// writes. The caller has checked the manifest against the directory.
    fn removeStrayFiles(self: *Store) OpenError!void {
        while (true) {
            // File numbers are collected while the directory is listed and
            // the files deleted afterwards, a few at a time, so that
            // nothing is deleted from a directory while it is being read.
            var stray: [16]manifest.ParsedFileName = undefined;
            var stray_count: usize = 0;
            var stray_left_over = false;

            {
                var listing = try self.dir.openDir(self.io, ".", .{ .iterate = true });
                defer listing.close(self.io);
                var entries = listing.iterate();
                while (true) {
                    const entry = try entries.next(self.io);
                    if (entry == null) {
                        break;
                    }
                    const parsed = manifest.parseFileName(entry.?.name);
                    if (parsed == null) {
                        continue;
                    }
                    const file = parsed.?;

                    var is_stray = false;
                    switch (file.kind) {
                        .table => {
                            if (self.tables.find(file.file_number) == null) {
                                is_stray = true;
                            }
                        },
                        .log => {
                            if (file.file_number < self.tables.log_number) {
                                is_stray = true;
                            }
                        },
                    }
                    if (!is_stray) {
                        continue;
                    }
                    if (stray_count == stray.len) {
                        stray_left_over = true;
                        continue;
                    }
                    stray[stray_count] = file;
                    stray_count += 1;
                }
            }

            for (stray[0..stray_count]) |file| {
                var name_buffer: [manifest.file_name_size_max]u8 = undefined;
                const name = manifest.fileName(&name_buffer, file.kind, file.file_number);
                try self.dir.deleteFile(self.io, name);
            }
            if (!stray_left_over) {
                return;
            }
        }
    }

    /// Opens every table the manifest holds, and checks that each file is
    /// the one that was written.
    fn openTables(self: *Store) OpenError!void {
        var tables = self.tables.iterator();
        while (true) {
            const found = tables.next();
            if (found == null) {
                return;
            }
            const table = found.?;
            const slot_index = self.freeSlotIndex().?;

            var name_buffer: [manifest.file_name_size_max]u8 = undefined;
            const name = manifest.fileName(&name_buffer, .table, table.file_number);
            const index_buffer = self.slotIndexBuffer(slot_index);
            var reader = sstable.Reader.open(self.io, self.dir, name, index_buffer) catch |err| switch (err) {
                // The manifest only names a table once the file is durable.
                error.FileNotFound => return error.Corrupt,
                else => |other| return other,
            };
            errdefer reader.close();
            if (reader.fileSize() != table.file_size) {
                return error.Corrupt;
            }
            if (reader.checksum() != table.checksum) {
                return error.Corrupt;
            }
            // Reads go through buffers of this size.
            if (reader.blockSizeMax() > sstable.block_size_max) {
                return error.BlockTooLarge;
            }

            self.slots[slot_index] = .{
                .in_use = true,
                .file_number = table.file_number,
                .reader = reader,
            };
        }
    }

    /// What `replayLog` learned about a log.
    const ReplayedLog = struct {
        /// The record the log carries on from, as its file header says.
        previous: wal.RecordId,
        /// Where the log's valid records end.
        end: wal.End,
        /// The sequence number of the last operation in the log, or the
        /// number the log follows if it holds none.
        sequence_last: u64,
    };

    /// Reads every record of log number `log_number` and applies it to
    /// `memtable` as a batch. The operations are numbered from
    /// `sequence_before + 1` in the order the log holds them, which is how
    /// they were numbered when they were first written.
    fn replayLog(
        self: *Store,
        log_number: u64,
        memtable: *MemTable,
        sequence_before: u64,
    ) (OpenError || error{IncompleteLog})!ReplayedLog {
        var name_buffer: [manifest.file_name_size_max]u8 = undefined;
        const log_name = manifest.fileName(&name_buffer, .log, log_number);

        // Nothing is in the scratch batch yet, so its buffer is free to
        // hold the records being replayed.
        var reader: wal.Reader = try .open(self.io, self.dir, log_name, self.scratch.buffer);
        defer reader.close();
        const previous = reader.end().last;

        var sequence_last = sequence_before;
        while (true) {
            const record = try reader.next();
            if (record == null) {
                break;
            }
            const batch_bytes = record.?.payload;

            try write_batch.validate(batch_bytes);
            // `commit` makes the same check before it logs a batch. A
            // memtable fills the same way every time, whether it is new or
            // has been reset, so this only fails for a log the store did
            // not write.
            if (memtableSizeMax(batch_bytes) > memtable.bytesFree()) {
                return error.LogTooLargeForMemtable;
            }
            sequence_last = applyBatch(memtable, batch_bytes, sequence_last + 1);
        }
        return .{
            .previous = previous,
            .end = reader.end(),
            .sequence_last = sequence_last,
        };
    }
};

/// Takes the lock that marks `dir` as open in a store. The lock is held until
/// the returned file is closed, or the process ends.
fn lockDir(io: Io, dir: Io.Dir) Store.OpenError!Io.File {
    // The file is not truncated: it is always empty, and another store may
    // hold it locked.
    const lock_file = dir.createFile(io, lock_file_name, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.StoreAlreadyOpen,
        else => |other| return other,
    };
    return lock_file;
}

/// Copies `value` to the front of `buffer` and returns the copy.
fn copyValue(value: []const u8, buffer: []u8) error{BufferTooSmall}![]u8 {
    if (value.len > buffer.len) {
        return error.BufferTooSmall;
    }
    const copy = buffer[0..value.len];
    @memcpy(copy, value);
    return copy;
}

/// The most bytes of the memtable that applying a batch can take. If this is
/// no more than the memtable's free bytes, applying the batch cannot fail.
/// `valid_bytes` must be the bytes of a valid batch.
fn memtableSizeMax(valid_bytes: []const u8) usize {
    var size: usize = 0;
    var operations: write_batch.Iterator = .init(valid_bytes);
    while (operations.next()) |operation| {
        switch (operation) {
            .put => |put| {
                size += MemTable.entrySizeMax(put.key.len, put.value.len);
            },
            .delete => |delete| {
                size += MemTable.entrySizeMax(delete.key.len, 0);
            },
        }
    }
    return size;
}

/// The fewest bytes of a memtable that an entry can take. A flush counts
/// its progress in these, so it never counts more than the frozen memtable
/// holds.
fn memtableSizeMin(entry: MemTable.Entry) usize {
    var value_len: usize = 0;
    if (entry.value != null) {
        value_len = entry.value.?.len;
    }
    return MemTable.entry_overhead_min + entry.key.len + value_len;
}

/// Applies the operations of a batch to the memtable, in order. The first
/// operation is given the sequence number `sequence_first` and each one after
/// it the next number, so a later operation on a key is newer than an earlier
/// one. Returns the sequence number of the last operation.
///
/// The caller has checked with `memtableSizeMax` that the operations fit.
/// `valid_bytes` must be the bytes of a valid batch, which holds at least one
/// operation.
fn applyBatch(memtable: *MemTable, valid_bytes: []const u8, sequence_first: u64) u64 {
    var sequence = sequence_first;
    var operations: write_batch.Iterator = .init(valid_bytes);
    while (operations.next()) |operation| {
        switch (operation) {
            .put => |put| {
                memtable.put(put.key, put.value, sequence) catch unreachable;
            },
            .delete => |delete| {
                memtable.delete(delete.key, sequence) catch unreachable;
            },
        }
        sequence += 1;
    }
    assert(sequence > sequence_first);
    return sequence - 1;
}

const testing = std.testing;

/// The size of each memtable in the tests that need a memtable to fill
/// after a few dozen writes.
const test_memtable_size = 64 * 1024;

/// The length of the values those tests write.
const test_value_size = 1000;

fn openStore(dir: Io.Dir) !Store {
    return Store.open(testing.allocator, testing.io, dir, .{});
}

fn openSmallStore(dir: Io.Dir) !Store {
    return Store.openWithMemtableSize(testing.allocator, testing.io, dir, .{}, test_memtable_size);
}

fn logName(buffer: *[manifest.file_name_size_max]u8, log_number: u64) []const u8 {
    return manifest.fileName(buffer, .log, log_number);
}

fn tableName(buffer: *[manifest.file_name_size_max]u8, table_number: u64) []const u8 {
    return manifest.fileName(buffer, .table, table_number);
}

fn logLength(dir: Io.Dir, log_number: u64) !u64 {
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    const file = try dir.openFile(testing.io, logName(&name_buffer, log_number), .{ .mode = .read_only });
    defer file.close(testing.io);
    return try file.length(testing.io);
}

fn setLogLength(dir: Io.Dir, log_number: u64, len: u64) !void {
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    const file = try dir.openFile(testing.io, logName(&name_buffer, log_number), .{ .mode = .write_only });
    defer file.close(testing.io);
    try file.setLength(testing.io, len);
}

/// Swaps the file the store's log writes to for a read-only handle on the
/// same file, so that the next append fails with `NotOpenForWriting`. The
/// store closes the new handle when it is closed.
fn makeLogReadOnly(store: *Store, dir: Io.Dir) !void {
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    const name = logName(&name_buffer, store.log_number);
    const read_only = try dir.openFile(testing.io, name, .{ .mode = .read_only });
    store.log.file.close(testing.io);
    store.log.file = read_only;
}

/// Appends one record to the end of a log file of a store that is closed.
fn appendToLog(dir: Io.Dir, log_number: u64, payload: []const u8) !void {
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    const name = logName(&name_buffer, log_number);

    const buffer = try testing.allocator.alloc(u8, log_payload_size_max);
    defer testing.allocator.free(buffer);
    var reader: wal.Reader = try .open(testing.io, dir, name, buffer);
    while (try reader.next()) |_| {}
    const end = reader.end();
    reader.close();

    var writer: wal.Writer = try .open(testing.io, dir, name, log_payload_size_max, end);
    defer writer.close();
    _ = try writer.append(payload);
}

/// Creates a file that holds `contents`.
fn writeFile(dir: Io.Dir, name: []const u8, contents: []const u8) !void {
    const file = try dir.createFile(testing.io, name, .{});
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, contents, 0);
}

fn fileExists(dir: Io.Dir, name: []const u8) !bool {
    const file = dir.openFile(testing.io, name, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    file.close(testing.io);
    return true;
}

/// Checks that the logs and tables in `dir` are exactly the files named.
fn expectNumberedFiles(dir: Io.Dir, expected: []const []const u8) !void {
    var listing = try dir.openDir(testing.io, ".", .{ .iterate = true });
    defer listing.close(testing.io);

    var entries = listing.iterate();
    var count: usize = 0;
    while (try entries.next(testing.io)) |entry| {
        if (manifest.parseFileName(entry.name) == null) {
            continue;
        }
        count += 1;

        var is_expected = false;
        for (expected) |name| {
            if (std.mem.eql(u8, name, entry.name)) {
                is_expected = true;
            }
        }
        if (!is_expected) {
            std.debug.print("unexpected file: {s}\n", .{entry.name});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(expected.len, count);
}

fn expectValue(store: *Store, key: []const u8, value: []const u8) !void {
    var buffer: [value_size_max]u8 = undefined;
    const found = try store.get(key, &buffer);
    try testing.expect(found != null);
    try testing.expectEqualSlices(u8, value, found.?);
}

fn expectAbsent(store: *Store, key: []const u8) !void {
    var buffer: [value_size_max]u8 = undefined;
    const found = try store.get(key, &buffer);
    try testing.expect(found == null);
}

fn expectEntry(entry: ?Store.Entry, key: []const u8, value: []const u8) !void {
    try testing.expect(entry != null);
    try testing.expectEqualSlices(u8, key, entry.?.key);
    try testing.expectEqualSlices(u8, value, entry.?.value);
}

/// The key of numbered test entry `number`.
fn numberedKey(buffer: *[8]u8, number: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:0>8}", .{number}) catch unreachable;
}

/// The value of numbered test entry `number`: one letter, chosen by the
/// number, `test_value_size` times.
fn numberedValue(buffer: *[test_value_size]u8, number: u64) []const u8 {
    const letter: u8 = 'a' + @as(u8, @intCast(number % 26));
    @memset(buffer, letter);
    return buffer;
}

fn putNumbered(store: *Store, number: u64) !void {
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    try store.put(numberedKey(&key_buffer, number), numberedValue(&value_buffer, number));
}

fn expectNumbered(store: *Store, number: u64) !void {
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    try expectValue(store, numberedKey(&key_buffer, number), numberedValue(&value_buffer, number));
}

/// Checks that a scan of the store gives exactly the numbered entries from
/// 0 to `count - 1`, in order.
fn expectNumberedScan(store: *Store, count: u64) !void {
    var buffers: Store.IteratorBuffers = try .init(testing.allocator);
    defer buffers.deinit(testing.allocator);
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;

    var it = store.iterator(&buffers);
    var number: u64 = 0;
    while (number < count) {
        const key = numberedKey(&key_buffer, number);
        const value = numberedValue(&value_buffer, number);
        try expectEntry(try it.next(), key, value);
        number += 1;
    }
    try testing.expect(try it.next() == null);
}

test "a new store is empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    var buffers: Store.IteratorBuffers = try .init(testing.allocator);
    defer buffers.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 0), store.opLatest());
    try testing.expectEqual(@as(u64, 0), store.sequenceLatest());
    try expectAbsent(&store, "a");
    var it = store.iterator(&buffers);
    try testing.expect(try it.next() == null);

    // A new store is its first log and a manifest.
    try expectNumberedFiles(tmp.dir, &.{"000001.log"});
    try testing.expect(try fileExists(tmp.dir, manifest.file_name));
}

test "the iterator gives live entries in key order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    var buffers: Store.IteratorBuffers = try .init(testing.allocator);
    defer buffers.deinit(testing.allocator);

    try store.put("c", "3");
    try store.put("a", "old");
    try store.put("b", "2");
    try store.put("d", "4");
    try store.put("a", "1");
    try store.delete("b");

    var it = store.iterator(&buffers);
    try expectEntry(try it.next(), "a", "1");
    try expectEntry(try it.next(), "c", "3");
    try expectEntry(try it.next(), "d", "4");
    try testing.expect(try it.next() == null);
    try testing.expect(try it.next() == null);

    // A seek to a deleted key lands on the next live one.
    try it.seek("b");
    try expectEntry(try it.next(), "c", "3");

    try it.seek("d");
    try expectEntry(try it.next(), "d", "4");
    try testing.expect(try it.next() == null);

    try it.seek("e");
    try testing.expect(try it.next() == null);

    it.seekToFirst();
    try expectEntry(try it.next(), "a", "1");
}

test "flush writes the memtable to a table and starts a new log" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        try store.put("b", "2");
        try store.delete("a");
        try store.put("c", "3");

        try store.flush();

        // The flush is over: one table, both memtables empty, and the first
        // log gone.
        try testing.expect(store.flushing == null);
        try testing.expectEqual(@as(usize, 1), store.tables.count());
        try testing.expect(store.memtables[0].isEmpty());
        try testing.expect(store.memtables[1].isEmpty());
        try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });

        // The manifest records what the table holds and where the new log
        // begins.
        const table = store.tables.find(3).?;
        try testing.expectEqual(@as(u8, 0), table.level);
        try testing.expectEqual(@as(u64, 1), table.sequence_min);
        try testing.expectEqual(@as(u64, 4), table.sequence_max);
        try testing.expectEqualSlices(u8, "a", table.key_min);
        try testing.expectEqualSlices(u8, "c", table.key_max);
        try testing.expectEqual(@as(u64, 2), store.tables.log_number);
        try testing.expectEqual(@as(u64, 4), store.tables.op_flushed);
        try testing.expectEqual(@as(u64, 4), store.tables.sequence_flushed);

        // The table is read like the memtable was.
        try expectAbsent(&store, "a");
        try expectValue(&store, "b", "2");
        try expectValue(&store, "c", "3");

        // The numbering carries on.
        try testing.expectEqual(@as(u64, 4), store.opLatest());
        try testing.expectEqual(@as(u64, 4), store.sequenceLatest());
        try store.put("d", "4");
        try testing.expectEqual(@as(u64, 5), store.opLatest());
        try testing.expectEqual(@as(u64, 5), store.sequenceLatest());
    }

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(usize, 1), store.tables.count());
    try testing.expectEqual(@as(u64, 5), store.opLatest());
    try testing.expectEqual(@as(u64, 5), store.sequenceLatest());
    try expectAbsent(&store, "a");
    try expectValue(&store, "b", "2");
    try expectValue(&store, "c", "3");
    try expectValue(&store, "d", "4");
    try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });
}

test "a table holds every entry of the memtable, older ones and tombstones too" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("a", "oldest");
    try store.put("a", "old");
    try store.put("a", "new");
    try store.delete("b");
    try store.flush();

    const slot = store.newestTableOlderThan(null).?;
    const block_buffer = try testing.allocator.alloc(u8, sstable.block_size_max);
    defer testing.allocator.free(block_buffer);
    var entries = slot.reader.iterator(block_buffer);

    const first = try entries.next();
    try testing.expect(first != null);
    try testing.expectEqualSlices(u8, "a", first.?.key);
    try testing.expectEqualSlices(u8, "new", first.?.value.?);
    try testing.expectEqual(@as(u64, 3), first.?.sequence);

    const second = try entries.next();
    try testing.expect(second != null);
    try testing.expectEqualSlices(u8, "a", second.?.key);
    try testing.expectEqualSlices(u8, "old", second.?.value.?);
    try testing.expectEqual(@as(u64, 2), second.?.sequence);

    const third = try entries.next();
    try testing.expect(third != null);
    try testing.expectEqualSlices(u8, "a", third.?.key);
    try testing.expectEqualSlices(u8, "oldest", third.?.value.?);
    try testing.expectEqual(@as(u64, 1), third.?.sequence);

    const fourth = try entries.next();
    try testing.expect(fourth != null);
    try testing.expectEqualSlices(u8, "b", fourth.?.key);
    try testing.expect(fourth.?.value == null);
    try testing.expectEqual(@as(u64, 4), fourth.?.sequence);

    try testing.expect(try entries.next() == null);
}

test "flush with nothing to write does nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    try store.flush();
    try testing.expectEqual(@as(usize, 0), store.tables.count());
    try expectNumberedFiles(tmp.dir, &.{"000001.log"});

    try store.put("a", "1");
    try store.flush();
    try testing.expectEqual(@as(usize, 1), store.tables.count());

    // The memtable is empty again, so a second flush writes no table.
    try store.flush();
    try testing.expectEqual(@as(usize, 1), store.tables.count());
    try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });
}

test "after a flush the sequence numbers carry on when the store is opened again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        try batch.put("x", "old");
        try batch.put("y", "1");
        try batch.put("z", "1");
        try store.write(&batch);
        try store.flush();
    }

    // The log is empty, so only the manifest knows that one op and three
    // sequence numbers have been used.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 1), store.opLatest());
    try testing.expectEqual(@as(u64, 3), store.sequenceLatest());

    // A write made now is newer than the one in the table.
    try store.put("x", "new");
    try testing.expectEqual(@as(u64, 2), store.opLatest());
    try testing.expectEqual(@as(u64, 4), store.sequenceLatest());
    try expectValue(&store, "x", "new");

    // It still is once it has been flushed too.
    try store.flush();
    try expectValue(&store, "x", "new");
    const newest = store.newestTableOlderThan(null).?;
    const table = store.tables.find(newest.file_number).?;
    try testing.expectEqual(@as(u64, 4), table.sequence_min);
    try testing.expectEqual(@as(u64, 4), table.sequence_max);
}

test "a read takes the newest entry among the memtable and the tables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffers: Store.IteratorBuffers = try .init(testing.allocator);
    defer buffers.deinit(testing.allocator);

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);

        // The oldest table.
        try store.put("a", "1");
        try store.put("b", "1");
        try store.put("c", "1");
        try store.put("d", "1");
        try store.put("e", "1");
        try store.flush();

        // A newer table changes "a" and deletes "b".
        try store.put("a", "2");
        try store.delete("b");
        try store.put("f", "2");
        try store.flush();

        // The memtable changes "c", deletes "d", and brings "b" back.
        try store.put("c", "3");
        try store.delete("d");
        try store.put("b", "3");

        try testing.expectEqual(@as(usize, 2), store.tables.count());
        try expectValue(&store, "a", "2");
        try expectValue(&store, "b", "3");
        try expectValue(&store, "c", "3");
        try expectAbsent(&store, "d");
        try expectValue(&store, "e", "1");
        try expectValue(&store, "f", "2");
        try expectAbsent(&store, "g");

        var it = store.iterator(&buffers);
        try expectEntry(try it.next(), "a", "2");
        try expectEntry(try it.next(), "b", "3");
        try expectEntry(try it.next(), "c", "3");
        try expectEntry(try it.next(), "e", "1");
        try expectEntry(try it.next(), "f", "2");
        try testing.expect(try it.next() == null);

        // A seek to a key that is deleted in a newer place than it is
        // written lands on the next live key.
        try it.seek("d");
        try expectEntry(try it.next(), "e", "1");
        try it.seek("b");
        try expectEntry(try it.next(), "b", "3");
        it.seekToFirst();
        try expectEntry(try it.next(), "a", "2");
    }

    // The same after the store is opened again, and after everything is in
    // tables.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.flush();
    try testing.expectEqual(@as(usize, 3), store.tables.count());
    try expectValue(&store, "a", "2");
    try expectValue(&store, "b", "3");
    try expectValue(&store, "c", "3");
    try expectAbsent(&store, "d");
    try expectValue(&store, "e", "1");
    try expectValue(&store, "f", "2");

    var it = store.iterator(&buffers);
    try expectEntry(try it.next(), "a", "2");
    try expectEntry(try it.next(), "b", "3");
    try expectEntry(try it.next(), "c", "3");
    try expectEntry(try it.next(), "e", "1");
    try expectEntry(try it.next(), "f", "2");
    try testing.expect(try it.next() == null);
}

test "a tombstone in a newer table hides the value in an older one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("a", "1");
    try store.flush();
    try store.delete("a");
    try store.flush();
    try store.put("z", "unrelated");
    try store.flush();

    try testing.expectEqual(@as(usize, 3), store.tables.count());
    try expectAbsent(&store, "a");
}

test "a value from a table is copied into the caller's buffer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("a", "value");
    try store.flush();

    var small_buffer: [4]u8 = @splat('.');
    try testing.expectError(error.BufferTooSmall, store.get("a", &small_buffer));
    try testing.expectEqualSlices(u8, "....", &small_buffer);

    var buffer: [8]u8 = @splat('.');
    const found = try store.get("a", &buffer);
    try testing.expectEqualSlices(u8, "value", found.?);
    try testing.expectEqual(@as([*]u8, &buffer), found.?.ptr);

    // A later read from the table does not change what was returned.
    try store.put("b", "other");
    try store.flush();
    var other_buffer: [8]u8 = undefined;
    _ = try store.get("b", &other_buffer);
    try testing.expectEqualSlices(u8, "value", found.?);
}

test "a full memtable is frozen and flushed by the writes that follow" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openSmallStore(tmp.dir);
    defer store.close(testing.allocator);

    // Write until a put does not fit. That put freezes the memtable, starts
    // the second log, and goes into the other memtable.
    var count: u64 = 0;
    while (store.log_number == log_number_first) {
        try putNumbered(&store, count);
        count += 1;
    }
    const count_at_freeze = count;
    try testing.expect(count_at_freeze > 10);
    try testing.expect(store.flushing != null);
    try testing.expectEqual(@as(usize, 1), store.active_index);
    try testing.expectEqual(@as(usize, 0), store.tables.count());
    try testing.expectEqual(count, store.opLatest());

    // Nothing is in a table yet, and everything is readable: the frozen
    // memtable is still read.
    var number: u64 = 0;
    while (number < count) {
        try expectNumbered(&store, number);
        number += 1;
    }
    try expectNumberedScan(&store, count);

    // Each write that follows does a share of the flush.
    while (store.flushing != null) {
        try putNumbered(&store, count);
        count += 1;
        // The flush is over long before the active memtable fills again.
        try testing.expectEqual(@as(u64, 2), store.log_number);
    }
    const writes_during_flush = count - count_at_freeze;
    try testing.expect(writes_during_flush > 1);
    try testing.expect(writes_during_flush <= count_at_freeze / 2 + 2);

    try testing.expectEqual(@as(usize, 1), store.tables.count());
    try testing.expect(store.memtables[0].isEmpty());
    try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });

    number = 0;
    while (number < count) {
        try expectNumbered(&store, number);
        number += 1;
    }
    try expectNumberedScan(&store, count);

    // The memtables take turns: the next freeze makes the first one active
    // again.
    while (store.log_number == 2) {
        try putNumbered(&store, count);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 0), store.active_index);

    // A flush finishes the one in progress, then writes out the active
    // memtable, which holds the put that did not fit.
    try store.flush();
    try testing.expectEqual(@as(usize, 3), store.tables.count());
    try testing.expect(store.memtables[0].isEmpty());
    try testing.expect(store.memtables[1].isEmpty());
    try expectNumberedScan(&store, count);
}

/// How far a flush had got when the store was closed without finishing it,
/// which leaves the files as a crash at that point would.
const CrashPoint = enum {
    /// The new log exists, and nothing has been written to it or to the
    /// table.
    frozen,
    /// Writes have gone to the new log, and part of the table is written.
    writing,
    /// The table is complete, but the manifest does not name it.
    table_written,
    /// The manifest names the table, and the old log is still there.
    table_recorded,
    /// The flush is over.
    done,
};

/// The number of numbered entries `crashDuringFlush` writes before it
/// freezes the memtable.
const crash_entry_count = 20;

/// Writes numbered entries, freezes the memtable, and closes the store with
/// the flush at `point`. At every point but `frozen`, three more writes are
/// made after the freeze: entry 0 is changed, entry 1 is deleted, and entry
/// `crash_entry_count` is added.
fn crashDuringFlush(dir: Io.Dir, point: CrashPoint) !void {
    var store = try openSmallStore(dir);
    defer store.close(testing.allocator);

    var number: u64 = 0;
    while (number < crash_entry_count) {
        try putNumbered(&store, number);
        number += 1;
    }
    try testing.expectEqual(log_number_first, store.log_number);

    try store.freeze();
    if (point == .frozen) {
        return;
    }

    var key_buffer: [8]u8 = undefined;
    try store.put(numberedKey(&key_buffer, 0), "changed");
    try store.delete(numberedKey(&key_buffer, 1));
    try putNumbered(&store, crash_entry_count);

    // Those writes each did a share of the flush, but not all of it.
    try testing.expectEqual(Store.FlushStage.writing, store.flushing.?.stage);
    try testing.expect(store.flushing.?.entry_next != null);
    if (point == .writing) {
        return;
    }

    try store.flushWriteEntries(std.math.maxInt(usize));
    try store.flushFinishTable();
    if (point == .table_written) {
        return;
    }

    try store.flushRecordTable();
    if (point == .table_recorded) {
        return;
    }

    try store.flushRetireLog();
}

/// Checks that the store holds what `crashDuringFlush` wrote before closing
/// it at `point`.
fn expectAfterCrash(store: *Store, point: CrashPoint) !void {
    var key_buffer: [8]u8 = undefined;

    var number: u64 = 2;
    while (number < crash_entry_count) {
        try expectNumbered(store, number);
        number += 1;
    }

    if (point == .frozen) {
        try expectNumbered(store, 0);
        try expectNumbered(store, 1);
        try expectAbsent(store, numberedKey(&key_buffer, crash_entry_count));
    } else {
        try expectValue(store, numberedKey(&key_buffer, 0), "changed");
        try expectAbsent(store, numberedKey(&key_buffer, 1));
        try expectNumbered(store, crash_entry_count);
    }
}

/// How many writes `crashDuringFlush` made before closing the store at
/// `point`. Each was one batch of one operation, so this is both the last
/// op and the last sequence number.
fn writesBeforeCrash(point: CrashPoint) u64 {
    if (point == .frozen) {
        return crash_entry_count;
    }
    return crash_entry_count + 3;
}

test "a crash at any step of a flush loses nothing" {
    const points = [_]CrashPoint{ .frozen, .writing, .table_written, .table_recorded, .done };
    for (points) |point| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        try crashDuringFlush(tmp.dir, point);

        {
            var store = try openSmallStore(tmp.dir);
            defer store.close(testing.allocator);

            // Whatever the crash left, the flush has now been done: one
            // table, the new log, and nothing else.
            try testing.expect(store.flushing == null);
            try testing.expectEqual(@as(usize, 1), store.tables.count());
            try testing.expectEqual(@as(u64, 2), store.log_number);
            try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });

            // The table holds the writes made before the freeze, under the
            // sequence numbers they were written with.
            const table = store.tables.find(3).?;
            try testing.expectEqual(@as(u64, 1), table.sequence_min);
            try testing.expectEqual(@as(u64, crash_entry_count), table.sequence_max);
            try testing.expectEqual(@as(u64, crash_entry_count), store.tables.op_flushed);
            try testing.expectEqual(@as(u64, crash_entry_count), store.tables.sequence_flushed);

            try expectAfterCrash(&store, point);
            try testing.expectEqual(writesBeforeCrash(point), store.opLatest());
            try testing.expectEqual(writesBeforeCrash(point), store.sequenceLatest());

            // If the crash came before the manifest named the new log, the
            // new log was replayed into the second memtable, and that is
            // the one that takes the writes now.
            var active_index_expected: usize = 0;
            if (point == .frozen or point == .writing or point == .table_written) {
                active_index_expected = 1;
            }
            try testing.expectEqual(active_index_expected, store.active_index);
            try testing.expect(store.otherMemtable().isEmpty());

            // The store carries on from there.
            try store.put("zz", "after the crash");
            try testing.expectEqual(writesBeforeCrash(point) + 1, store.opLatest());
            try testing.expectEqual(writesBeforeCrash(point) + 1, store.sequenceLatest());

            // A flush writes out whichever memtable is active.
            try store.flush();
            try testing.expectEqual(@as(usize, 2), store.tables.count());
            try testing.expect(store.memtables[0].isEmpty());
            try testing.expect(store.memtables[1].isEmpty());
            try expectAfterCrash(&store, point);
            try expectValue(&store, "zz", "after the crash");
        }

        // And it opens again, this time with nothing to repair.
        var store = try openSmallStore(tmp.dir);
        defer store.close(testing.allocator);
        try expectAfterCrash(&store, point);
        try expectValue(&store, "zz", "after the crash");
        try testing.expectEqual(writesBeforeCrash(point) + 1, store.opLatest());
        try testing.expectEqual(writesBeforeCrash(point) + 1, store.sequenceLatest());
        try expectNumberedFiles(tmp.dir, &.{ "000003.sst", "000004.log", "000005.sst" });
    }
}

test "a new log that a crash left incomplete is removed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
    }
    // A crash while a freeze was creating the second log leaves a file too
    // short to be a log.
    try writeFile(tmp.dir, "000002.log", "short");

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try expectNumberedFiles(tmp.dir, &.{"000001.log"});
    try testing.expectEqual(@as(usize, 0), store.tables.count());
    try testing.expectEqual(@as(u64, 1), store.opLatest());
    try expectValue(&store, "a", "1");

    // The next flush takes that file number again.
    try store.flush();
    try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });
    try expectValue(&store, "a", "1");
}

test "a newer log that does not follow the manifest's log is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
    }
    // The first log ends on op 1, and this log claims to follow no record.
    {
        var log: wal.Writer = try .create(testing.io, tmp.dir, "000002.log", log_payload_size_max, .none);
        log.close();
    }
    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "two logs newer than the manifest's are reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
    }
    {
        var log: wal.Writer = try .create(testing.io, tmp.dir, "000002.log", log_payload_size_max, .none);
        log.close();
    }
    {
        var log: wal.Writer = try .create(testing.io, tmp.dir, "000003.log", log_payload_size_max, .none);
        log.close();
    }
    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "files the manifest does not account for are removed when the store is opened" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        try store.flush();
        try store.put("b", "2");
    }
    try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });

    // A log older than the manifest's, which a flush did not get to delete.
    try writeFile(tmp.dir, "000001.log", "an old log");
    // Tables the manifest does not hold, which flushes wrote before a
    // crash. There are more of them than are deleted in one pass.
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    var table_number: u64 = 100;
    while (table_number < 140) {
        try writeFile(tmp.dir, tableName(&name_buffer, table_number), "part of a table");
        table_number += 1;
    }
    // Files that are not the store's.
    try writeFile(tmp.dir, "notes.txt", "keep me");
    try writeFile(tmp.dir, "1.log", "not a name the store gives a log");

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });
    try testing.expect(try fileExists(tmp.dir, "notes.txt"));
    try testing.expect(try fileExists(tmp.dir, "1.log"));
    try expectValue(&store, "a", "1");
    try expectValue(&store, "b", "2");
}

/// Makes a store in `dir` with one table, file 000003.sst, that holds "a"
/// and "b", and closes it.
fn makeStoreWithOneTable(dir: Io.Dir) !void {
    var store = try openStore(dir);
    defer store.close(testing.allocator);
    try store.put("a", "1");
    try store.put("b", "2");
    try store.flush();
}

test "a table that is missing is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeStoreWithOneTable(tmp.dir);

    try tmp.dir.deleteFile(testing.io, "000003.sst");
    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "a table that was cut short is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeStoreWithOneTable(tmp.dir);

    const file = try tmp.dir.openFile(testing.io, "000003.sst", .{ .mode = .read_write });
    const len = try file.length(testing.io);
    try file.setLength(testing.io, len - 1);
    file.close(testing.io);
    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

/// Replaces file 000003.sst with a whole, valid table that holds the two
/// entries given.
fn replaceTable(dir: Io.Dir, key_a: []const u8, value_a: []const u8, key_b: []const u8, value_b: []const u8) !void {
    try dir.deleteFile(testing.io, "000003.sst");

    const block_buffer = try testing.allocator.alloc(u8, sstable.block_size_max);
    defer testing.allocator.free(block_buffer);
    const index_buffer = try testing.allocator.alloc(u8, sstable.indexSizeMax(2, key_size_max));
    defer testing.allocator.free(index_buffer);

    var writer: sstable.Writer = try .create(testing.io, dir, "000003.sst", .{}, .{
        .block = block_buffer,
        .index = index_buffer,
    });
    defer writer.close();
    try writer.add(key_a, value_a, 1);
    try writer.add(key_b, value_b, 2);
    _ = try writer.finish();
}

test "a table that is not the one the manifest recorded is reported" {
    // A valid table of the same length, with one byte of a value changed.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try makeStoreWithOneTable(tmp.dir);
        try replaceTable(tmp.dir, "a", "1", "b", "X");
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
    // A valid table of another length.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try makeStoreWithOneTable(tmp.dir);
        try replaceTable(tmp.dir, "a", "1", "b", "22");
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
    // The same table, written again, is accepted.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try makeStoreWithOneTable(tmp.dir);
        try replaceTable(tmp.dir, "a", "1", "b", "2");
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try expectValue(&store, "b", "2");
    }
}

test "a manifest whose log is missing or incomplete is reported" {
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            var store = try openStore(tmp.dir);
            defer store.close(testing.allocator);
            try store.put("a", "1");
        }
        try tmp.dir.deleteFile(testing.io, "000001.log");
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            var store = try openStore(tmp.dir);
            defer store.close(testing.allocator);
            try store.put("a", "1");
        }
        try setLogLength(tmp.dir, log_number_first, wal.file_header_size - 1);
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
}

test "a log that does not begin where the manifest says is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        try store.put("b", "2");
        try store.flush();
    }
    // The manifest says the second log begins after op 2. This one begins
    // after no op at all.
    try tmp.dir.deleteFile(testing.io, "000002.log");
    {
        var log: wal.Writer = try .create(testing.io, tmp.dir, "000002.log", log_payload_size_max, .none);
        log.close();
    }
    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "a first log left too short by a crash while the store was created is replaced" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "000001.log", "short");

    // Without leave to create a store, there is none to open.
    const options: Options = .{ .create_if_missing = false };
    const result = Store.open(testing.allocator, testing.io, tmp.dir, options);
    try testing.expectError(error.StoreNotFound, result);
    // The refused open left the short log as it was.
    try testing.expectEqual(@as(u64, "short".len), try logLength(tmp.dir, log_number_first));

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 0), store.opLatest());
    try store.put("a", "1");
    try expectValue(&store, "a", "1");
}

test "a first log left as a header of zeros by a crash is created again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const zeros: [wal.file_header_size]u8 = @splat(0);
    try writeFile(tmp.dir, "000001.log", &zeros);

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 0), store.opLatest());
    try store.put("a", "1");
    try expectValue(&store, "a", "1");
}

test "a store whose creation a crash cut off before the first edit is created again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The first log and the manifest exist, but the manifest has no edit.
    {
        var log: wal.Writer = try .create(testing.io, tmp.dir, "000001.log", log_payload_size_max, .none);
        log.close();
        var manifest_writer: manifest.Writer = try .create(testing.io, tmp.dir);
        manifest_writer.close();
    }

    const options: Options = .{ .create_if_missing = false };
    const result = Store.open(testing.allocator, testing.io, tmp.dir, options);
    try testing.expectError(error.StoreNotFound, result);

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
    }
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try expectValue(&store, "a", "1");
}

test "files of a store whose manifest is gone are not taken for a new store" {
    // A first log that holds writes.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            var store = try openStore(tmp.dir);
            defer store.close(testing.allocator);
            try store.put("a", "1");
        }
        try tmp.dir.deleteFile(testing.io, manifest.file_name);
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
        try testing.expect(try fileExists(tmp.dir, "000001.log"));
    }
    // A table and a later log.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try makeStoreWithOneTable(tmp.dir);
        try tmp.dir.deleteFile(testing.io, manifest.file_name);
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
        try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });
    }
}

test "a manifest edit that does not fit the edits before it is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
    }

    // An edit that removes a table the store never had.
    {
        var edit_buffer: [manifest.edit_size_max]u8 = undefined;
        const edit_bytes = manifest.encode(.{
            .added = &.{},
            .removed = &.{5},
            .log_number = 1,
            .file_number_next = 6,
            .op_flushed = 0,
            .sequence_flushed = 0,
        }, &edit_buffer);

        var read_buffer: [manifest.edit_size_max]u8 = undefined;
        var reader: manifest.Reader = try .open(testing.io, tmp.dir, &read_buffer);
        while (try reader.next()) |_| {}
        const end = reader.end();
        reader.close();

        var writer: manifest.Writer = try .open(testing.io, tmp.dir, end);
        defer writer.close();
        try writer.append(edit_bytes);
    }
    try testing.expectError(error.InvalidEdit, openStore(tmp.dir));
}

test "a log record that is not a batch is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
    }
    try appendToLog(tmp.dir, log_number_first, "this is not a batch");

    try testing.expectError(error.InvalidBatch, openStore(tmp.dir));
}

test "a manifest whose flushed op is too large to count on from is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A store made by hand, whose manifest says the first log begins one op
    // before the largest.
    const op_before_largest = std.math.maxInt(u64) - 1;
    {
        const previous: wal.RecordId = .{ .op = op_before_largest, .checksum = 0 };
        var log: wal.Writer = try .create(testing.io, tmp.dir, "000001.log", log_payload_size_max, previous);
        defer log.close();

        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        try batch.put("a", "1");
        _ = try log.append(batch.bytes());
    }
    {
        var edit_buffer: [manifest.edit_size_max]u8 = undefined;
        const edit_bytes = manifest.encode(.{
            .added = &.{},
            .removed = &.{},
            .log_number = 1,
            .file_number_next = 2,
            .op_flushed = op_before_largest,
            .sequence_flushed = 0,
        }, &edit_buffer);
        var writer: manifest.Writer = try .create(testing.io, tmp.dir);
        defer writer.close();
        try writer.append(edit_bytes);
    }

    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "a log that holds more than a memtable is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openSmallStore(tmp.dir);
        defer store.close(testing.allocator);
    }

    // Append batches of one put each, as the store would, but carry on
    // until the entries cannot fit in a memtable however little room each
    // one takes there.
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    var puts: u64 = 0;
    var memtable_size_min: usize = 0;
    while (memtable_size_min <= test_memtable_size) {
        const key = numberedKey(&key_buffer, puts);
        const value = numberedValue(&value_buffer, puts);
        batch.clear();
        try batch.put(key, value);
        try appendToLog(tmp.dir, log_number_first, batch.bytes());
        memtable_size_min += MemTable.entry_overhead_min + key.len + value.len;
        puts += 1;
    }

    try testing.expectError(error.LogTooLargeForMemtable, openSmallStore(tmp.dir));
}

/// Writes numbered entries to a new small store in `dir` until the next
/// one, with a value of `test_value_size` bytes, would not fit in the
/// active memtable. Returns how many were written.
fn fillFirstMemtable(store: *Store) !u64 {
    var count: u64 = 0;
    while (MemTable.entrySizeMax(8, test_value_size) <= store.activeMemtable().bytesFree()) {
        try putNumbered(store, count);
        count += 1;
    }
    try testing.expectEqual(log_number_first, store.log_number);
    return count;
}

test "a memtable is frozen only when a batch's estimate is over its free bytes" {
    const value: [test_value_size]u8 = @splat('v');
    var key_buffer: [8]u8 = undefined;

    // A put whose estimate is exactly the free bytes goes into the memtable.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try openSmallStore(tmp.dir);
        defer store.close(testing.allocator);

        const count = try fillFirstMemtable(&store);
        const key = numberedKey(&key_buffer, count);
        const free = store.activeMemtable().bytesFree();
        const value_len_exact = free - MemTable.entrySizeMax(key.len, 0);

        try store.put(key, value[0..value_len_exact]);
        try testing.expectEqual(log_number_first, store.log_number);
        try testing.expect(store.flushing == null);
        try expectValue(&store, key, value[0..value_len_exact]);
    }

    // One byte more, and the memtable is frozen first.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try openSmallStore(tmp.dir);
        defer store.close(testing.allocator);

        const count = try fillFirstMemtable(&store);
        const key = numberedKey(&key_buffer, count);
        const free = store.activeMemtable().bytesFree();
        const value_len_exact = free - MemTable.entrySizeMax(key.len, 0);

        try store.put(key, value[0 .. value_len_exact + 1]);
        try testing.expectEqual(@as(u64, 2), store.log_number);
        try testing.expect(store.flushing != null);
        try expectValue(&store, key, value[0 .. value_len_exact + 1]);
        try testing.expectEqual(count + 1, store.opLatest());
    }
}

test "a store with every table slot taken and a full memtable rejects a write, stays usable, and opens again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var key_buffer: [8]u8 = undefined;
    var count: u64 = 0;
    {
        var store = try openSmallStore(tmp.dir);
        defer store.close(testing.allocator);

        while (true) {
            putNumbered(&store, count) catch |err| {
                try testing.expectEqual(error.StoreFull, err);
                break;
            };
            count += 1;
        }
        try testing.expectEqual(@as(usize, tables_max), store.tables.count());
        try testing.expect(store.flushing == null);
        try testing.expect(!store.activeMemtable().isEmpty());

        // The rejected write used no op number and left no trace.
        try testing.expectEqual(count, store.opLatest());
        try expectAbsent(&store, numberedKey(&key_buffer, count));

        // A flush has nowhere to put a table either.
        try testing.expectError(error.StoreFull, store.flush());
        try testing.expectEqual(@as(usize, tables_max), store.tables.count());

        // Everything written before it is still readable.
        try expectNumberedScan(&store, count);
        try expectNumbered(&store, 0);
        try expectNumbered(&store, count / 2);
        try expectNumbered(&store, count - 1);

        // A write that fits in what is left of the memtable is accepted.
        try testing.expect(MemTable.entrySizeMax(5, 1) <= store.activeMemtable().bytesFree());
        try store.put("small", "1");
        try testing.expectEqual(count + 1, store.opLatest());
        try expectValue(&store, "small", "1");
    }

    var store = try openSmallStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(usize, tables_max), store.tables.count());
    try testing.expectEqual(count + 1, store.opLatest());
    // Every table was opened again: each key is read from the table that
    // holds it.
    var number: u64 = 0;
    while (number < count) {
        try expectNumbered(&store, number);
        number += 1;
    }
    try expectValue(&store, "small", "1");
}

test "batches of small operations fill a memtable, and both logs replay" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    var key_number: u64 = 0;
    var batches: u64 = 0;
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);

        // A small operation takes far more room in the memtable than it
        // does in the batch, so the memtable fills long before the log is
        // as large. Stop at the batch that froze it.
        while (store.log_number == log_number_first) {
            key_number = try fillBatchWithSmallOperations(&batch, key_number);
            try store.write(&batch);
            batches += 1;
        }
        try testing.expect(batches > 1);
        try testing.expectEqual(batches, store.opLatest());
    }

    // The first log fits in one memtable again and is flushed; the second
    // log's one batch fits in the other.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(batches, store.opLatest());
    try testing.expectEqual(key_number, store.sequenceLatest());
    try testing.expectEqual(@as(usize, 1), store.tables.count());

    // Even keys were put with an empty value, and odd keys deleted.
    var key_buffer: [8]u8 = undefined;
    try expectValue(&store, numberedKey(&key_buffer, 0), "");
    try expectAbsent(&store, numberedKey(&key_buffer, 1));
    try expectValue(&store, numberedKey(&key_buffer, key_number - 2), "");
}

test "a flush that cannot create its table breaks the store, which opens again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");

        // The flush will give its table file number 3.
        try writeFile(tmp.dir, "000003.sst", "in the way");
        try testing.expectError(error.PathAlreadyExists, store.flush());

        // Nothing was frozen, and the log the flush started is gone again.
        try testing.expect(store.flushing == null);
        try testing.expectEqual(log_number_first, store.log_number);
        try testing.expect(!try fileExists(tmp.dir, "000002.log"));

        try testing.expectError(error.StoreBroken, store.put("b", "2"));
        try testing.expectError(error.StoreBroken, store.flush());
        try expectValue(&store, "a", "1");
    }

    // Opening the store removes the file that was in the way.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try expectNumberedFiles(tmp.dir, &.{"000001.log"});
    try expectValue(&store, "a", "1");
    try store.flush();
    try expectValue(&store, "a", "1");
}

test "a flush that fails partway breaks the store, keeps it readable, and is redone when it opens" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var count: u64 = 0;
    {
        var store = try openSmallStore(tmp.dir);
        defer store.close(testing.allocator);
        while (count < 40) {
            try putNumbered(&store, count);
            count += 1;
        }
        try store.freeze();

        // Swap the table's file for a read-only handle, so that writing the
        // first data block fails.
        const read_only = try tmp.dir.openFile(testing.io, "000003.sst", .{ .mode = .read_only });
        store.flushing.?.writer.file.close(testing.io);
        store.flushing.?.writer.file = read_only;

        try testing.expectError(error.NotOpenForWriting, store.flush());
        try testing.expectEqual(Store.FlushStage.failed, store.flushing.?.stage);

        // Every later write is refused.
        try testing.expectError(error.StoreBroken, putNumbered(&store, count));
        try testing.expectError(error.StoreBroken, store.flush());

        // The frozen memtable is still read.
        try expectNumberedScan(&store, count);
        try expectNumbered(&store, 0);
        try expectNumbered(&store, count - 1);
    }

    var store = try openSmallStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expect(store.flushing == null);
    try testing.expectEqual(@as(usize, 1), store.tables.count());
    try testing.expectEqual(count, store.opLatest());
    try expectNumberedScan(&store, count);
    try putNumbered(&store, count);
    try expectNumbered(&store, count);
}

test "a store whose memtables have been used more than once opens again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;

    // Enough small writes to fill and reuse both memtables several times,
    // and to leave the last log nearly as full as a memtable gets.
    const put_count = 4378;
    {
        var store = try openSmallStore(tmp.dir);
        defer store.close(testing.allocator);
        var number: u64 = 0;
        while (number < put_count) {
            const value = numberedValue(&value_buffer, number)[0..40];
            try store.put(numberedKey(&key_buffer, number), value);
            number += 1;
        }
        // The active memtable has been through a reset.
        try testing.expect(store.tables.count() >= 4);
    }

    // The last log is replayed into a new memtable, where its writes must
    // take the room they took in the one that had been reset.
    var store = try openSmallStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, put_count), store.opLatest());
    try expectValue(&store, numberedKey(&key_buffer, 0), numberedValue(&value_buffer, 0)[0..40]);
    try expectValue(
        &store,
        numberedKey(&key_buffer, put_count - 1),
        numberedValue(&value_buffer, put_count - 1)[0..40],
    );
}

/// Fills `batch` with numbered puts, starting at `number_first`, until one
/// more would make it too large for an empty small memtable. Returns the
/// number after the last one.
fn fillBatchNearlyAMemtable(batch: *WriteBatch, number_first: u64) !u64 {
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    const room = test_memtable_size - MemTable.buffer_size_min;
    const put_size = MemTable.entrySizeMax(8, test_value_size);

    batch.clear();
    var number = number_first;
    var size: usize = 0;
    while (size + put_size <= room) {
        try batch.put(numberedKey(&key_buffer, number), numberedValue(&value_buffer, number));
        size += put_size;
        number += 1;
    }
    return number;
}

/// Brings a small store to the point where a flush is in progress and the
/// active memtable has no room for another numbered put. `count` numbered
/// entries have been written when this is called, and the new count is
/// returned.
fn fillWithFlushStillGoing(store: *Store, count_before: u64) !u64 {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    // Something for the flush to write.
    var count = count_before;
    const frozen_count = 40;
    while (count < count_before + frozen_count) {
        try putNumbered(store, count);
        count += 1;
    }
    const log_number_before = store.log_number;

    // One batch that fills most of an empty memtable. It does not fit, so
    // it freezes the memtable and goes into the other one. The write that
    // freezes a memtable does no share of the flush it starts.
    count = try fillBatchNearlyAMemtable(&batch, count);
    try store.write(&batch);
    try testing.expect(store.log_number != log_number_before);

    // A few more puts fill the active memtable. Their shares of the flush
    // are too small to finish it.
    while (MemTable.entrySizeMax(8, test_value_size) <= store.activeMemtable().bytesFree()) {
        try putNumbered(store, count);
        count += 1;
    }
    try testing.expect(store.flushing != null);
    try testing.expectEqual(Store.FlushStage.writing, store.flushing.?.stage);
    return count;
}

test "a flush still going when the active memtable fills is finished first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openSmallStore(tmp.dir);
    defer store.close(testing.allocator);

    var count = try fillWithFlushStillGoing(&store, 0);
    try testing.expectEqual(@as(usize, 0), store.tables.count());
    try testing.expectEqual(@as(u64, 2), store.log_number);

    // This put does not fit. The first flush is finished, the memtable is
    // frozen, and a second flush begins.
    try putNumbered(&store, count);
    count += 1;
    try testing.expectEqual(@as(usize, 1), store.tables.count());
    try testing.expect(store.flushing != null);
    try testing.expectEqual(@as(u64, 4), store.log_number);
    try expectNumberedScan(&store, count);

    try store.flush();
    try expectNumberedScan(&store, count);
}

test "a store is full only once the flush still going has taken its slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openSmallStore(tmp.dir);
    defer store.close(testing.allocator);

    // All but one of the table slots.
    var count: u64 = 0;
    while (store.tables.count() < tables_max - 1) {
        try putNumbered(&store, count);
        count += 1;
        try store.flush();
    }

    // A flush in progress will take the last slot.
    count = try fillWithFlushStillGoing(&store, count);
    try testing.expectEqual(@as(usize, tables_max - 1), store.tables.count());

    // The put that does not fit finishes that flush, and then has no slot
    // to freeze the active memtable into.
    try testing.expectError(error.StoreFull, putNumbered(&store, count));
    try testing.expectEqual(@as(usize, tables_max), store.tables.count());
    try testing.expect(store.flushing == null);
    try expectNumberedScan(&store, count);
}

test "a scan crosses blocks that hold one entry each" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    var buffers: Store.IteratorBuffers = try .init(testing.allocator);
    defer buffers.deinit(testing.allocator);

    // Two of these do not fit in one block, so every block holds one entry,
    // and each key is at the same place in its block. Reading the next
    // block overwrites the key the scan returned last.
    const value = try testing.allocator.alloc(u8, sstable.block_size / 2 + 1);
    defer testing.allocator.free(value);
    @memset(value, 'v');
    try store.put("k1", value);
    try store.put("k2", value);
    try store.put("k3", value);
    try store.put("k4", value);
    try store.flush();

    var it = store.iterator(&buffers);
    try expectEntry(try it.next(), "k1", value);
    try expectEntry(try it.next(), "k2", value);
    try expectEntry(try it.next(), "k3", value);
    try expectEntry(try it.next(), "k4", value);
    try testing.expect(try it.next() == null);
}

test "seekToFirst right after an entry gives that entry again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    var buffers: Store.IteratorBuffers = try .init(testing.allocator);
    defer buffers.deinit(testing.allocator);
    try store.put("a", "1");
    try store.put("b", "2");

    var it = store.iterator(&buffers);
    try expectEntry(try it.next(), "a", "1");
    it.seekToFirst();
    try expectEntry(try it.next(), "a", "1");
    try expectEntry(try it.next(), "b", "2");
}

test "a write whose freeze fails breaks the store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openSmallStore(tmp.dir);
    defer store.close(testing.allocator);

    const count = try fillFirstMemtable(&store);
    // The freeze will give its log file number 2 and its table number 3.
    try writeFile(tmp.dir, "000003.sst", "in the way");
    try testing.expectError(error.PathAlreadyExists, putNumbered(&store, count));
    try testing.expectError(error.StoreBroken, putNumbered(&store, count));
    try expectNumbered(&store, 0);
}

test "a flush does not record a table that is not the one it wrote" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("a", "1");
    try store.put("b", "2");

    try store.freeze();
    try store.flushWriteEntries(std.math.maxInt(usize));
    try store.flushFinishTable();

    // A whole table of the same length takes the file's place.
    try replaceTable(tmp.dir, "a", "1", "b", "X");

    try testing.expectError(error.Corrupt, store.flushRecordTable());
    try testing.expectEqual(Store.FlushStage.table_written, store.flushing.?.stage);
    try testing.expectEqual(@as(usize, 0), store.tables.count());
    try testing.expect(try fileExists(tmp.dir, "000001.log"));
}

test "open deletes nothing when the manifest has lost its last edit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeStoreWithOneTable(tmp.dir);

    // Damage the last byte of the manifest. The edit that recorded the
    // flush no longer counts, so the manifest names the first log, which
    // the flush deleted, and holds no table.
    {
        const file = try tmp.dir.openFile(testing.io, manifest.file_name, .{ .mode = .read_write });
        defer file.close(testing.io);
        const len = try file.length(testing.io);
        var last: [1]u8 = undefined;
        _ = try file.readPositionalAll(testing.io, &last, len - 1);
        last[0] ^= 0xff;
        try file.writePositionalAll(testing.io, &last, len - 1);
    }
    const manifest_len_before = blk: {
        const file = try tmp.dir.openFile(testing.io, manifest.file_name, .{ .mode = .read_only });
        defer file.close(testing.io);
        break :blk try file.length(testing.io);
    };

    try testing.expectError(error.Corrupt, openStore(tmp.dir));

    // The table that holds the data is still there, and so is all of the
    // manifest.
    try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });
    const file = try tmp.dir.openFile(testing.io, manifest.file_name, .{ .mode = .read_only });
    defer file.close(testing.io);
    try testing.expectEqual(manifest_len_before, try file.length(testing.io));
}

/// Makes a store in `dir` that holds one write in its first log, closes
/// it, and returns the last record of that log.
fn makeStoreWithOneWrite(dir: Io.Dir) !wal.RecordId {
    var store = try openStore(dir);
    defer store.close(testing.allocator);
    try store.put("a", "1");
    return store.log.last;
}

/// Creates an empty log file that says it carries on from `previous`.
fn createLogAfter(dir: Io.Dir, name: []const u8, previous: wal.RecordId) !void {
    var log: wal.Writer = try .create(testing.io, dir, name, log_payload_size_max, previous);
    log.close();
}

test "a newer log is accepted only if it carries on from the manifest's log" {
    // The right record: the store opens, and flushes the first log.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const last = try makeStoreWithOneWrite(tmp.dir);
        try createLogAfter(tmp.dir, "000002.log", last);

        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try testing.expectEqual(@as(usize, 1), store.tables.count());
        try expectValue(&store, "a", "1");
    }
    // The right checksum and the wrong op.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const last = try makeStoreWithOneWrite(tmp.dir);
        try createLogAfter(tmp.dir, "000002.log", .{ .op = last.op + 1, .checksum = last.checksum });
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
    // The right op and the wrong checksum.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const last = try makeStoreWithOneWrite(tmp.dir);
        try createLogAfter(tmp.dir, "000002.log", .{ .op = last.op, .checksum = last.checksum ^ 1 });
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
    // Two logs that both carry on from it.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const last = try makeStoreWithOneWrite(tmp.dir);
        try createLogAfter(tmp.dir, "000002.log", last);
        try createLogAfter(tmp.dir, "000003.log", last);
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
    // A file number too large to count on from.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const last = try makeStoreWithOneWrite(tmp.dir);
        try createLogAfter(tmp.dir, "18446744073709551615.log", last);
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
}

test "a newer log beside a log that holds nothing is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
    }
    // A memtable is only frozen when it holds something, so a first log
    // with no records never has a log after it.
    try createLogAfter(tmp.dir, "000002.log", .none);
    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "a newer log under a file number the manifest has handed out is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var last: wal.RecordId = undefined;
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        try store.flush();
        try store.put("b", "2");
        last = store.log.last;
        // The manifest's log is 2 and its table is 3.
        try testing.expectEqual(@as(u64, 4), store.tables.file_number_next);
    }
    try createLogAfter(tmp.dir, "000003.log", last);
    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "a newer log beside a store with every table slot taken is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var last: wal.RecordId = undefined;
    var log_number_next: u64 = 0;
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        var number: u64 = 0;
        while (store.tables.count() < tables_max) {
            try putNumbered(&store, number);
            number += 1;
            try store.flush();
        }
        try putNumbered(&store, number);
        last = store.log.last;
        log_number_next = store.file_number_next;
    }
    // A memtable is only frozen when a table slot is free for it.
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    try createLogAfter(tmp.dir, logName(&name_buffer, log_number_next), last);
    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "a later log with no manifest is not taken for a new store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try createLogAfter(tmp.dir, "000002.log", .none);

    try testing.expectError(error.Corrupt, openStore(tmp.dir));
    try expectNumberedFiles(tmp.dir, &.{"000002.log"});
}

/// Makes a store by hand: an empty first log, and a manifest that follows
/// `manifest_previous` and holds the one edit given.
fn makeStoreByHand(dir: Io.Dir, edit: manifest.Edit, manifest_previous: wal.RecordId) !void {
    try createLogAfter(dir, "000001.log", .{ .op = edit.op_flushed, .checksum = 0 });

    const edit_buffer = try testing.allocator.alloc(u8, manifest.edit_size_max);
    defer testing.allocator.free(edit_buffer);
    const edit_bytes = manifest.encode(edit, edit_buffer);

    var log: wal.Writer = try .create(
        testing.io,
        dir,
        manifest.file_name,
        manifest.edit_size_max,
        manifest_previous,
    );
    defer log.close();
    _ = try log.append(edit_bytes);
}

test "a manifest whose numbers are too large to count on from is reported" {
    const largest = std.math.maxInt(u64);
    const first_edit: manifest.Edit = .{
        .added = &.{},
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 2,
        .op_flushed = 0,
        .sequence_flushed = 0,
    };

    // The same store with ordinary numbers opens.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try makeStoreByHand(tmp.dir, first_edit, .none);
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        try expectValue(&store, "a", "1");
    }
    // The largest sequence number: the next write would have none.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var edit = first_edit;
        edit.sequence_flushed = largest;
        try makeStoreByHand(tmp.dir, edit, .none);
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
    // The largest file number: the next flush would have none.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var edit = first_edit;
        edit.file_number_next = largest;
        try makeStoreByHand(tmp.dir, edit, .none);
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
    // A manifest whose own last record has the largest op: the next edit
    // would have none.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try makeStoreByHand(tmp.dir, first_edit, .{ .op = largest - 1, .checksum = 0 });
        try testing.expectError(error.Corrupt, openStore(tmp.dir));
    }
}

test "a table with a block longer than the store's buffers is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A table as a build with a larger block size would write it: 200
    // entries in one block.
    const entry_count = 200;
    const block_size_large = 4 * sstable.block_size_max;
    const block_buffer = try testing.allocator.alloc(u8, block_size_large);
    defer testing.allocator.free(block_buffer);
    const index_buffer = try testing.allocator.alloc(u8, sstable.indexSizeMax(2, key_size_max));
    defer testing.allocator.free(index_buffer);

    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    var summary: sstable.Writer.Summary = undefined;
    {
        var writer: sstable.Writer = try .create(
            testing.io,
            tmp.dir,
            "000002.sst",
            .{ .block_size = block_size_large },
            .{ .block = block_buffer, .index = index_buffer },
        );
        defer writer.close();
        var number: u64 = 0;
        while (number < entry_count) {
            const key = numberedKey(&key_buffer, number);
            const value = numberedValue(&value_buffer, number);
            try writer.add(key, value, number + 1);
            number += 1;
        }
        summary = try writer.finish();
    }

    var key_min_buffer: [8]u8 = undefined;
    var key_max_buffer: [8]u8 = undefined;
    const table: manifest.Table = .{
        .file_number = 2,
        .level = 0,
        .file_size = summary.file_size,
        .checksum = summary.checksum,
        .sequence_min = 1,
        .sequence_max = entry_count,
        .key_min = numberedKey(&key_min_buffer, 0),
        .key_max = numberedKey(&key_max_buffer, entry_count - 1),
    };
    try makeStoreByHand(tmp.dir, .{
        .added = &.{table},
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 3,
        .op_flushed = 0,
        .sequence_flushed = entry_count,
    }, .none);

    try testing.expectError(error.BlockTooLarge, openStore(tmp.dir));
}

const model_key_count = 48;

/// The size of each memtable in the model test: small enough that the
/// test's writes fill it several times, and large enough that they fill it
/// fewer times than there are table slots.
const model_memtable_size = 32 * 1024;

fn openModelStore(dir: Io.Dir) !Store {
    return Store.openWithMemtableSize(testing.allocator, testing.io, dir, .{}, model_memtable_size);
}

/// Checks every key and a full scan of the store against the model. Entry
/// `i` of the model is the value of key number `i`, or `null` if that key is
/// not present.
fn expectModel(
    store: *Store,
    buffers: *const Store.IteratorBuffers,
    model: *const [model_key_count]?[]const u8,
) !void {
    var key_buffer: [3]u8 = undefined;

    var it = store.iterator(buffers);
    for (model, 0..) |expected, key_number| {
        const key = try std.fmt.bufPrint(&key_buffer, "k{d:0>2}", .{key_number});
        if (expected == null) {
            try expectAbsent(store, key);
        } else {
            try expectValue(store, key, expected.?);
            try expectEntry(try it.next(), key, expected.?);
        }
    }
    try testing.expect(try it.next() == null);

    // A seek to each key lands on that key, or on the next one present.
    for (model, 0..) |_, key_number| {
        const key = try std.fmt.bufPrint(&key_buffer, "k{d:0>2}", .{key_number});
        try it.seek(key);

        var expected_number = key_number;
        while (expected_number < model_key_count and model[expected_number] == null) {
            expected_number += 1;
        }
        if (expected_number == model_key_count) {
            try testing.expect(try it.next() == null);
        } else {
            var expected_key_buffer: [3]u8 = undefined;
            const expected_key = try std.fmt.bufPrint(&expected_key_buffer, "k{d:0>2}", .{expected_number});
            try expectEntry(try it.next(), expected_key, model[expected_number].?);
        }
    }
}

test "random writes, flushes and reopens match a model" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();

    var model: [model_key_count]?[]const u8 = @splat(null);
    var op_expected: u64 = 0;
    var sequence_expected: u64 = 0;
    var key_buffer: [3]u8 = undefined;

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    var buffers: Store.IteratorBuffers = try .init(testing.allocator);
    defer buffers.deinit(testing.allocator);

    var store = try openModelStore(tmp.dir);
    defer store.close(testing.allocator);

    for (0..600) |step| {
        // A batch of one to five operations on random keys.
        batch.clear();
        const operation_count = 1 + random.uintLessThan(usize, 5);
        for (0..operation_count) |_| {
            const key_number = random.uintLessThan(usize, model_key_count);
            const key = try std.fmt.bufPrint(&key_buffer, "k{d:0>2}", .{key_number});

            if (random.uintLessThan(u8, 4) == 0) {
                try batch.delete(key);
                model[key_number] = null;
            } else {
                const value = try arena.alloc(u8, random.uintAtMost(usize, 60));
                random.bytes(value);
                try batch.put(key, value);
                model[key_number] = value;
            }
        }
        try store.write(&batch);
        op_expected += 1;
        sequence_expected += operation_count;
        try testing.expectEqual(op_expected, store.opLatest());
        try testing.expectEqual(sequence_expected, store.sequenceLatest());

        // The store is checked at steps that fall while a flush is in
        // progress as well as between flushes.
        if (step % 20 == 19) {
            try expectModel(&store, &buffers, &model);
        }
        if (step % 50 == 49) {
            store.close(testing.allocator);
            store = try openModelStore(tmp.dir);
            try testing.expectEqual(op_expected, store.opLatest());
            try testing.expectEqual(sequence_expected, store.sequenceLatest());
            try expectModel(&store, &buffers, &model);
        }
        if (step == 299) {
            try store.flush();
            try expectModel(&store, &buffers, &model);
        }
    }

    // The writes filled a memtable more than once, so the store was read
    // from several tables.
    try testing.expect(store.tables.count() >= 3);
}

test "open fails when there is no store and it may not create one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const options: Options = .{ .create_if_missing = false };
    const result = Store.open(testing.allocator, testing.io, tmp.dir, options);
    try testing.expectError(error.StoreNotFound, result);

    // Once the store exists, the same options open it.
    var created = try openStore(tmp.dir);
    created.close(testing.allocator);
    var store: Store = try .open(testing.allocator, testing.io, tmp.dir, options);
    store.close(testing.allocator);
}

test "put, get and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    try store.put("a", "1");
    try store.put("b", "2");
    try expectValue(&store, "a", "1");
    try expectValue(&store, "b", "2");
    try expectAbsent(&store, "c");

    try store.put("a", "one");
    try expectValue(&store, "a", "one");

    try store.delete("a");
    try expectAbsent(&store, "a");
    try expectValue(&store, "b", "2");

    // Deleting a key that is not present is not an error.
    try store.delete("never");
    try expectAbsent(&store, "never");

    try store.put("a", "back");
    try expectValue(&store, "a", "back");
}

test "get copies the value into the caller's buffer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("a", "first");

    var buffer: [16]u8 = @splat('.');
    const found = try store.get("a", &buffer);
    try testing.expectEqualSlices(u8, "first", found.?);

    // The value is at the front of the caller's buffer, and the rest of
    // the buffer is untouched.
    try testing.expectEqual(@as([*]u8, &buffer), found.?.ptr);
    try testing.expectEqualSlices(u8, "first...........", &buffer);

    // Later writes to the store do not change what was returned.
    try store.put("a", "second");
    try store.delete("a");
    try testing.expectEqualSlices(u8, "first", found.?);
}

test "get reports a buffer that is too small and copies nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("a", "value");

    var small_buffer: [4]u8 = @splat('.');
    try testing.expectError(error.BufferTooSmall, store.get("a", &small_buffer));
    try testing.expectEqualSlices(u8, "....", &small_buffer);

    // A buffer of exactly the value's length is enough.
    var exact_buffer: [5]u8 = undefined;
    const found = try store.get("a", &exact_buffer);
    try testing.expectEqualSlices(u8, "value", found.?);

    // A key that is not present needs no room at all.
    var empty_buffer: [0]u8 = undefined;
    try testing.expect(try store.get("missing", &empty_buffer) == null);
}

test "get tells an empty value from a key that is not present" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("empty", "");

    var empty_buffer: [0]u8 = undefined;
    const found = try store.get("empty", &empty_buffer);
    try testing.expect(found != null);
    try testing.expectEqual(@as(usize, 0), found.?.len);

    try testing.expect(try store.get("missing", &empty_buffer) == null);
}

test "each batch is given the next op number" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    try store.put("a", "1");
    try testing.expectEqual(@as(u64, 1), store.opLatest());
    try store.delete("a");
    try testing.expectEqual(@as(u64, 2), store.opLatest());

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    try batch.put("b", "2");
    try batch.put("c", "3");
    try store.write(&batch);
    try testing.expectEqual(@as(u64, 3), store.opLatest());
}

test "each operation is given the next sequence number" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try testing.expectEqual(@as(u64, 0), store.sequenceLatest());

        try store.put("a", "1");
        try testing.expectEqual(@as(u64, 1), store.sequenceLatest());
        try store.delete("a");
        try testing.expectEqual(@as(u64, 2), store.sequenceLatest());

        // A batch of three operations takes three sequence numbers and one
        // op number.
        try batch.put("b", "2");
        try batch.put("c", "3");
        try batch.delete("b");
        try store.write(&batch);
        try testing.expectEqual(@as(u64, 5), store.sequenceLatest());
        try testing.expectEqual(@as(u64, 3), store.opLatest());

        // A rejected write takes none.
        batch.clear();
        try testing.expectError(error.EmptyBatch, store.write(&batch));
        try testing.expectEqual(@as(u64, 5), store.sequenceLatest());
    }

    // Opening the store again restores the last sequence number.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 5), store.sequenceLatest());
    try store.put("d", "4");
    try testing.expectEqual(@as(u64, 6), store.sequenceLatest());
}

test "the memtable holds each entry under the sequence number of its operation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    try batch.put("b", "old");
    try batch.put("a", "1");
    try batch.put("b", "new");
    try store.write(&batch);
    try store.delete("c");

    // The newest entry for each key, with the number of the operation that
    // wrote it: "a" was the second operation, "b" was last written by the
    // third, and "c" by the fourth.
    var entries = store.activeMemtable().iterator();
    const first = entries.next().?;
    try testing.expectEqualSlices(u8, "a", first.key);
    try testing.expectEqual(@as(u64, 2), first.sequence);
    const second = entries.next().?;
    try testing.expectEqualSlices(u8, "b", second.key);
    try testing.expectEqualSlices(u8, "new", second.value.?);
    try testing.expectEqual(@as(u64, 3), second.sequence);
    const third = entries.next().?;
    try testing.expectEqualSlices(u8, "c", third.key);
    try testing.expect(third.value == null);
    try testing.expectEqual(@as(u64, 4), third.sequence);
    try testing.expect(entries.next() == null);
}

test "replay gives each entry the sequence number it was written under" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);

        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        try batch.put("b", "old");
        try batch.put("a", "1");
        try batch.put("b", "new");
        try store.write(&batch);
        try store.delete("c");
    }

    // The log is replayed into a new memtable. Each entry has the number it
    // had before the store was closed.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    var entries = store.activeMemtable().iterator();
    const first = entries.next().?;
    try testing.expectEqualSlices(u8, "a", first.key);
    try testing.expectEqual(@as(u64, 2), first.sequence);
    const second = entries.next().?;
    try testing.expectEqualSlices(u8, "b", second.key);
    try testing.expectEqualSlices(u8, "new", second.value.?);
    try testing.expectEqual(@as(u64, 3), second.sequence);
    const third = entries.next().?;
    try testing.expectEqualSlices(u8, "c", third.key);
    try testing.expect(third.value == null);
    try testing.expectEqual(@as(u64, 4), third.sequence);
    try testing.expect(entries.next() == null);
}

test "a batch applies its operations in order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("gone", "before");

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    try batch.put("a", "first");
    try batch.put("a", "second");
    try batch.delete("gone");
    try batch.put("b", "kept");
    try batch.delete("c");
    try batch.put("c", "after the delete");
    try store.write(&batch);

    try expectValue(&store, "a", "second");
    try expectAbsent(&store, "gone");
    try expectValue(&store, "b", "kept");
    try expectValue(&store, "c", "after the delete");
}

test "put and delete do not carry over an earlier write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    // A delete after a put must not write the put again.
    try store.put("a", "1");
    try batch.put("a", "2");
    try store.write(&batch);
    try store.delete("b");
    try expectValue(&store, "a", "2");

    // A put after a delete must not write the delete again.
    try store.delete("c");
    batch.clear();
    try batch.put("c", "3");
    try store.write(&batch);
    try store.put("d", "4");
    try expectValue(&store, "c", "3");
}

test "an empty batch is rejected and nothing is written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        const len_before = try logLength(tmp.dir, log_number_first);

        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        try testing.expectError(error.EmptyBatch, store.write(&batch));

        // A batch that was cleared is empty again.
        try batch.put("b", "2");
        batch.clear();
        try testing.expectError(error.EmptyBatch, store.write(&batch));

        // The rejected writes used no op number and left no trace.
        try testing.expectEqual(@as(u64, 1), store.opLatest());
        try testing.expectEqual(len_before, try logLength(tmp.dir, log_number_first));
    }

    // The log holds no empty record, so the store opens again.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 1), store.opLatest());
    try expectValue(&store, "a", "1");
}

test "writes are still there after the store is closed and opened" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        try store.put("b", "2");
        try store.delete("a");
        try store.put("c", "3");
    }

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 4), store.opLatest());
    try expectAbsent(&store, "a");
    try expectValue(&store, "b", "2");
    try expectValue(&store, "c", "3");

    // New writes carry on from the last op.
    try store.put("d", "4");
    try testing.expectEqual(@as(u64, 5), store.opLatest());
}

test "a batch that was only partly written to the log is not there after a crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var len_before_last: u64 = 0;
    var len_after_last: u64 = 0;
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        len_before_last = try logLength(tmp.dir, log_number_first);

        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        try batch.put("a", "changed");
        try batch.put("b", "2");
        try store.write(&batch);
        len_after_last = try logLength(tmp.dir, log_number_first);
    }

    // With the log whole, the store opens with both operations of the batch.
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try testing.expectEqual(@as(u64, 2), store.opLatest());
        try expectValue(&store, "a", "changed");
        try expectValue(&store, "b", "2");
    }

    // Cut the log at every point inside the last record. Each time, the
    // store opens with the first write and nothing of the second batch.
    var len = len_before_last;
    while (len < len_after_last) {
        try setLogLength(tmp.dir, log_number_first, len);

        var store = try openStore(tmp.dir);
        try testing.expectEqual(@as(u64, 1), store.opLatest());
        try expectValue(&store, "a", "1");
        try expectAbsent(&store, "b");
        store.close(testing.allocator);

        len += 1;
    }

    // The store carries on from there.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("c", "3");
    try testing.expectEqual(@as(u64, 2), store.opLatest());
    try expectValue(&store, "c", "3");
}

test "a directory cannot be open in two stores at once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try openStore(tmp.dir);
    try first.put("a", "1");
    const len_before = try logLength(tmp.dir, log_number_first);

    // A second open is refused, and leaves the log alone.
    try testing.expectError(error.StoreAlreadyOpen, openStore(tmp.dir));
    try testing.expectEqual(len_before, try logLength(tmp.dir, log_number_first));

    // The first store still works.
    try first.put("b", "2");
    first.close(testing.allocator);

    // Closing the store released the directory.
    var second = try openStore(tmp.dir);
    defer second.close(testing.allocator);
    try testing.expectEqual(@as(u64, 2), second.opLatest());
    try expectValue(&second, "a", "1");
    try expectValue(&second, "b", "2");
}

test "a key or value over the limit is rejected and nothing is written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);

    const long_key: [write_batch.key_size_max + 1]u8 = @splat('k');
    const long_value = try testing.allocator.alloc(u8, write_batch.value_size_max + 1);
    defer testing.allocator.free(long_value);
    @memset(long_value, 'v');

    try testing.expectError(error.KeyTooLarge, store.put(&long_key, "1"));
    try testing.expectError(error.KeyTooLarge, store.delete(&long_key));
    try testing.expectError(error.ValueTooLarge, store.put("a", long_value));
    try testing.expectEqual(@as(u64, 0), store.opLatest());
    try expectAbsent(&store, "a");
}

test "memtableSizeMax is the sum of the largest size of each operation" {
    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    try batch.put("ab", "value");
    try batch.delete("abc");
    try batch.put("k", "");

    var expected: usize = 0;
    expected += MemTable.entrySizeMax("ab".len, "value".len);
    expected += MemTable.entrySizeMax("abc".len, 0);
    expected += MemTable.entrySizeMax("k".len, 0);
    try testing.expectEqual(expected, memtableSizeMax(batch.bytes()));
}

/// Fills `batch` with small puts and deletes until it has no room for another.
/// Each operation uses the next key number, which is returned for the next
/// call.
fn fillBatchWithSmallOperations(batch: *WriteBatch, key_number_first: u64) !u64 {
    var key_buffer: [8]u8 = undefined;
    var key_number = key_number_first;

    batch.clear();
    while (true) {
        const key = try std.fmt.bufPrint(&key_buffer, "{d:0>8}", .{key_number});
        if (key_number % 2 == 0) {
            batch.put(key, "") catch |err| {
                try testing.expectEqual(error.BatchFull, err);
                return key_number;
            };
        } else {
            batch.delete(key) catch |err| {
                try testing.expectEqual(error.BatchFull, err);
                return key_number;
            };
        }
        key_number += 1;
    }
}

test "a write that fails to reach the log is not applied" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("a", "1");

    try makeLogReadOnly(&store, tmp.dir);
    try testing.expectError(error.NotOpenForWriting, store.put("b", "2"));

    // The failed write is not readable and used no op number.
    try expectAbsent(&store, "b");
    try expectValue(&store, "a", "1");
    try testing.expectEqual(@as(u64, 1), store.opLatest());
}

test "after a failed write every later write is refused until the store is opened again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);
    try batch.put("c", "3");

    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");

        try makeLogReadOnly(&store, tmp.dir);
        try testing.expectError(error.NotOpenForWriting, store.put("b", "2"));

        // Every kind of write is refused from then on.
        try testing.expectError(error.StoreBroken, store.put("b", "2"));
        try testing.expectError(error.StoreBroken, store.delete("a"));
        try testing.expectError(error.StoreBroken, store.write(&batch));

        // Reads still work, and show nothing of the refused writes.
        try expectValue(&store, "a", "1");
        try expectAbsent(&store, "b");
        try expectAbsent(&store, "c");
        try testing.expectEqual(@as(u64, 1), store.opLatest());
    }

    // Opened again, the store accepts writes.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try expectValue(&store, "a", "1");
    try store.put("b", "2");
    try testing.expectEqual(@as(u64, 2), store.opLatest());
}
