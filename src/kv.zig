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
//!     000003.log    a write-ahead log (`sector_log.zig`)
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

const async_io = @import("async_io.zig");
const bloom = @import("bloom.zig");
const AsyncIo = async_io.AsyncIo;
const constants = @import("constants.zig");
const manifest = @import("manifest.zig");
const MemTable = @import("memtable.zig").MemTable;
const sector_log = @import("sector_log.zig");
const sstable = @import("sstable.zig");
const DiskStorage = @import("storage.zig").Storage;
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

/// The longest payload the store's logs accept: one batch.
const log_payload_size_max: u32 = write_batch.size_max;

/// The length of the buffer that holds one log record on its way to or
/// from a log file.
const log_buffer_size = sector_log.bufferSize(log_payload_size_max);

/// The length of each log file a store creates.
const log_file_size = constants.log_file_size;

/// The unit logs are written in.
const sector_size = sector_log.sector_size;

/// How long one turn of the event loop may block while a blocking write
/// waits for its batch to be durable. The loop returns as soon as any
/// operation ends.
const blocking_wait_ns = 100 * std.time.ns_per_ms;

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
    assert(write_batch.size_max <= sector_log.payload_size_format_max);

    // A log file is whole sectors, and an empty one has room for the
    // largest batch, so a batch can always be logged once a new log has
    // been started.
    assert(log_file_size % sector_size == 0);
    assert(log_file_size >= sector_log.fileSizeMin(log_payload_size_max));

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

/// A store on a real disk.
pub const DiskStore = StoreType(DiskStorage);

/// A store whose files are kept by a `Storage`: the real one in
/// `storage.zig`, or the simulated one in `testing/storage.zig`.
pub fn StoreType(comptime Storage: type) type {
    return struct {
        const Store = @This();

        /// The store's write-ahead logs.
        const Log = sector_log.LogType(Storage);

        /// The writer and the reader of the store's manifest.
        const ManifestWriter = manifest.WriterType(Storage);
        const ManifestReader = manifest.ReaderType(Storage);

        /// The writer and the reader of the store's table files.
        const TableWriter = sstable.WriterType(Storage);
        const TableReader = sstable.ReaderType(Storage);

        /// Where the store's files are. The store holds its lock from `open`
        /// to `close`. Operations in flight hold pointers to the storage, so it
        /// does not move.
        storage: *Storage,
        /// The event loop under the storage, when `open` made both and the
        /// store owns them. `null` when the caller gave the store its storage.
        event_loop_owned: ?*AsyncIo,

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
        log: Log.Writer,
        /// Holds one log record: the one being appended, or the one being
        /// replayed in `open`. Creating a log also writes the file out from it.
        log_buffer: []align(sector_size) u8,
        /// The length of each log file this store creates.
        log_file_size: u64,
        /// The file number of that log.
        log_number: u64,
        /// The next file number to hand out. It runs ahead of the manifest's,
        /// which only learns of a number when an edit is written.
        file_number_next: u64,

        /// The tables the store has, as the manifest records them.
        tables: manifest.TableSet,
        manifest_writer: ManifestWriter,
        /// One open table file for each table in `tables`.
        slots: [tables_max]TableSlot,
        /// The flush in progress, if there is one.
        flushing: ?Flush,

        /// A batch for `put` and `delete` to build their one operation in. Its
        /// buffer also holds each record while a log is replayed in `open`.
        scratch: WriteBatch,
        /// Holds one manifest edit while it is put together, before it is
        /// handed to the manifest's writer.
        edit_buffer: []u8,
        /// Holds one manifest edit as it is in the file, on its way there or
        /// back. `manifest.buffer_size` bytes.
        manifest_buffer: manifest.Buffer,
        /// Room for the index of every table: `tables_max` parts of
        /// `sstable.index_size_max` bytes, one for each slot.
        index_storage: []u8,
        /// Room for the filter of every table: `tables_max` parts of
        /// `filter_size` bytes, one for each slot.
        filter_storage: []u8,
        /// The length of each table's filter. It has `bloom.bits_per_key`
        /// bits for each entry of the largest table this store writes.
        filter_size: usize,
        /// Holds the data block a flush is filling.
        flush_block_buffer: []u8,
        /// Holds the data block `get` is reading.
        get_block_buffer: []u8,

        /// The writes that have been started and are waiting their turn,
        /// oldest first.
        write_queue_head: ?*Write,
        write_queue_tail: ?*Write,
        /// The write whose batch is being appended to the log, if any.
        write_logging: ?*Write,
        /// The log's part of that append. The storage holds a pointer to
        /// it while the append is in flight, which is why the store must
        /// not be moved then.
        append: Log.Append,
        /// Set by the log when that append has ended, and cleared when
        /// `advance` has dealt with it.
        append_ended: bool,
        /// Whether `advance` is running. A write's callback runs inside it,
        /// and must not call `poll`, `wait`, `close`, `flush` or a blocking
        /// write. It may read, and may start further writes.
        advancing: bool,

        /// Set when a write to a file has failed. The state of the files is
        /// then unknown, so every later write is refused.
        broken: bool,
        /// How many times a lookup has read a table file. A lookup reads
        /// none for a key the memtables hold, and none for a table whose
        /// filter rules the key out.
        table_reads: u64,
        /// How many times the memtables or the set of tables may have
        /// changed: a write was handed to the log, a batch went into the
        /// memtable, or a flush was asked for. A scan
        /// remembers this number, to tell that nothing has changed under it.
        write_count: u64,

        /// One table file, open for reading.
        const TableSlot = struct {
            in_use: bool,
            /// Only meaningful while the slot is in use.
            file_number: u64,
            reader: TableReader,
            /// Which keys the table holds, more or less. A lookup asks it
            /// before reading the table. It is not stored in the file: a
            /// flush fills it as it writes the table, and `open` fills it
            /// by reading the table through.
            filter: bloom.Filter,
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
            writer: TableWriter,
            /// The filter of the table being written, in that slot's part
            /// of `filter_storage`. Each entry written is added to it.
            filter: bloom.Filter,
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
            summary: TableWriter.Summary,
        };

        /// What a flush can report.
        pub const FlushError = error{
            /// The table that was just written does not read back as written.
            Corrupt,
            /// The manifest has no room to record the table. The store checks
            /// for room before it freezes a memtable and reports `StoreFull`
            /// then, so a flush does not get here. If one did, the store
            /// would be broken, and would report this each time it was opened,
            /// because opening runs the flush again and nothing rewrites the
            /// manifest yet.
            ManifestFull,
        } || Storage.CreateError || Storage.OpenError || Storage.WriteError || Storage.SyncError ||
            Storage.SizeError || Storage.ReadError || Storage.SyncDirError || Storage.DeleteError;

        /// What `open` can report. Opening a log can also report
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
        } || Allocator.Error || FlushError || Storage.ListError ||
            Storage.LockError || async_io.InitError;

        /// What writing a batch that holds at least one operation can report.
        pub const CommitError = error{
            /// The active memtable or its log has no room for the batch, and
            /// the memtable cannot be flushed to make room: every table slot
            /// is taken, or the manifest has no room to record another table.
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
        pub const ReadError = TableReader.ReadError;

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
                table: TableReader.Iterator,
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
        /// `gpa` is used here, to allocate everything the store will need, and
        /// again in `close`. `dir` must stay open until the store is closed.
        ///
        /// This is for a store on a real disk. The store makes its own event
        /// loop and storage on `dir`, and frees them in `close`.
        pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, options: Options) OpenError!Store {
            return openWithSizes(gpa, io, dir, options, MemTable.buffer_size_max, log_file_size);
        }

        /// `open`, with logs of the short length the tests use. A store always
        /// has logs of the length in `constants`; writing one of those out
        /// for every test would take far too long. This is for tests in
        /// other files, which cannot reach `openWithSizes`.
        pub fn openForTest(gpa: Allocator, io: Io, dir: Io.Dir, options: Options) OpenError!Store {
            return openWithSizes(gpa, io, dir, options, MemTable.buffer_size_max, test_log_file_size);
        }

        /// Opens the store whose files `storage` keeps, creating it if it is
        /// not there and `options` allow that. `storage` must outlive the store
        /// and must not move.
        pub fn openOnStorage(gpa: Allocator, storage: *Storage, options: Options) OpenError!Store {
            return openOnStorageWithSizes(gpa, storage, options, MemTable.buffer_size_max, log_file_size);
        }

        /// `open`, with memtables of `memtable_size` bytes each and new logs of
        /// `log_size` bytes each. A store always has memtables and logs of the
        /// sizes in `constants`; tests use small ones so that a flush takes few
        /// writes and creating a log is quick. A batch must fit in an empty
        /// memtable and in an empty log.
        fn openWithSizes(
            gpa: Allocator,
            io: Io,
            dir: Io.Dir,
            options: Options,
            memtable_size: usize,
            log_size: u64,
        ) OpenError!Store {
            const event_loop = try gpa.create(AsyncIo);
            errdefer gpa.destroy(event_loop);
            event_loop.* = try .init();
            errdefer event_loop.deinit();
            const storage = try gpa.create(Storage);
            errdefer gpa.destroy(storage);
            storage.* = .init(event_loop, io, dir);
            errdefer storage.deinit();

            var store = try openOnStorageWithSizes(gpa, storage, options, memtable_size, log_size);
            store.event_loop_owned = event_loop;
            return store;
        }

        /// `openOnStorage`, with memtables of `memtable_size` bytes each and
        /// new logs of `log_size` bytes each.
        fn openOnStorageWithSizes(
            gpa: Allocator,
            storage: *Storage,
            options: Options,
            memtable_size: usize,
            log_size: u64,
        ) OpenError!Store {
            assert(log_size % sector_size == 0);
            assert(log_size >= sector_log.fileSizeMin(log_payload_size_max));

            // The lock comes first: opening a store can delete files and
            // overwrite parts of them, which must not happen under a store
            // that is already open.
            storage.lock() catch |err| switch (err) {
                error.AlreadyLocked => return error.StoreAlreadyOpen,
                else => |other| return other,
            };
            errdefer storage.unlock();

            const log_buffer = try gpa.alignedAlloc(u8, .fromByteUnits(sector_size), log_buffer_size);
            errdefer gpa.free(log_buffer);

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
            const manifest_buffer = try gpa.alignedAlloc(u8, .fromByteUnits(sector_size), manifest.buffer_size);
            errdefer gpa.free(manifest_buffer);
            const index_storage = try gpa.alloc(u8, tables_max * sstable.index_size_max);
            errdefer gpa.free(index_storage);
            // A table is one memtable written out, and every entry took at
            // least this much of the memtable.
            const table_entries_max = memtable_size / MemTable.entry_overhead_min;
            const filter_size = bloom.sizeFor(table_entries_max);
            const filter_storage = try gpa.alloc(u8, tables_max * filter_size);
            errdefer gpa.free(filter_storage);
            const flush_block_buffer = try gpa.alloc(u8, sstable.block_size_max);
            errdefer gpa.free(flush_block_buffer);
            const get_block_buffer = try gpa.alloc(u8, sstable.block_size_max);
            errdefer gpa.free(get_block_buffer);

            var slots: [tables_max]TableSlot = undefined;
            for (&slots) |*slot| {
                slot.in_use = false;
            }

            var store: Store = .{
                .storage = storage,
                .event_loop_owned = null,
                .memtables = memtables,
                .active_index = 0,
                .sequence_last = 0,
                // The log and the manifest are opened by `recover`.
                .log = undefined,
                .log_buffer = log_buffer,
                .log_file_size = log_size,
                .log_number = 0,
                .file_number_next = 0,
                .tables = tables,
                .manifest_writer = undefined,
                .slots = slots,
                .flushing = null,
                .scratch = scratch,
                .edit_buffer = edit_buffer,
                .manifest_buffer = manifest_buffer,
                .index_storage = index_storage,
                .filter_storage = filter_storage,
                .filter_size = filter_size,
                .flush_block_buffer = flush_block_buffer,
                .get_block_buffer = get_block_buffer,
                .write_queue_head = null,
                .write_queue_tail = null,
                .write_logging = null,
                .append = .{},
                .append_ended = false,
                .advancing = false,
                .broken = false,
                .table_reads = 0,
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
            assert(!self.advancing);
            assert(!self.hasWritesInFlight());
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
            gpa.free(self.manifest_buffer);
            gpa.free(self.index_storage);
            gpa.free(self.filter_storage);
            gpa.free(self.flush_block_buffer);
            gpa.free(self.get_block_buffer);
            gpa.free(self.log_buffer);

            self.storage.unlock();
            if (self.event_loop_owned) |event_loop| {
                self.storage.deinit();
                gpa.destroy(self.storage);
                event_loop.deinit();
                gpa.destroy(event_loop);
            }
            self.* = undefined;
        }

        /// One write, from `writeStart` until its callback runs. The caller
        /// owns it. It and its batch must not be moved, changed or freed
        /// until the callback has run. Create one with `.{}`.
        pub const Write = struct {
            callback: *const fn (write: *Write) void = undefined,
            batch: *const WriteBatch = undefined,
            /// Whether the write has been started and not yet called back.
            in_flight: bool = false,
            /// The next write waiting its turn.
            next: ?*Write = null,

            /// Set when the callback runs. Without an error, the batch is
            /// durable and reads see it.
            result: CommitError!void = undefined,
        };

        /// What `writeStart` reports at once, before the write is queued.
        pub const WriteStartError = error{
            /// The batch holds no operations.
            EmptyBatch,
            /// An earlier write failed, and the store must be closed and
            /// opened again before it is written to.
            StoreBroken,
        };

        /// Starts applying `batch` as a unit, and returns at once. `callback`
        /// runs later, from `poll` or `wait`, with the outcome in
        /// `operation.result`. Until then the batch is not visible to reads.
        ///
        /// Writes are carried out in the order they were started, one log
        /// record at a time. While a batch is on its way to the disk the
        /// caller is free: it can read, start further writes, and do
        /// anything else. The store must not be moved or closed while a
        /// write is in flight.
        ///
        /// `StoreFull` is reported to the callback and leaves the store
        /// usable. After any other error there, the batch may or may not be
        /// in the log: it can appear when the store is next opened. Every
        /// write queued behind it, and every later one, gets `StoreBroken`
        /// until the store is closed and opened again.
        pub fn writeStart(
            self: *Store,
            operation: *Write,
            callback: *const fn (write: *Write) void,
            batch: *const WriteBatch,
        ) WriteStartError!void {
            assert(!operation.in_flight);
            // An empty batch is never logged: replay rejects an empty record.
            if (batch.count() == 0) {
                return error.EmptyBatch;
            }
            if (self.broken) {
                return error.StoreBroken;
            }
            operation.* = .{
                .callback = callback,
                .batch = batch,
                .in_flight = true,
            };
            if (self.write_queue_tail) |tail| {
                tail.next = operation;
            } else {
                self.write_queue_head = operation;
            }
            self.write_queue_tail = operation;
        }

        /// Whether any write has been started and not yet called back.
        pub fn hasWritesInFlight(self: *const Store) bool {
            return self.write_logging != null or self.write_queue_head != null;
        }

        /// Carries the writes in flight forward as far as they can go
        /// without waiting, and runs the callbacks of those that have ended.
        pub fn poll(self: *Store) void {
            self.storage.poll();
            self.advance();
        }

        /// Like `poll`, but when nothing has ended yet, blocks until
        /// something does or until `timeout_ns` has passed.
        pub fn wait(self: *Store, timeout_ns: u64) void {
            // A write that has not been handed to the log yet has nothing
            // on the disk to wait for, so it is moved on first.
            self.advance();
            if (self.write_logging == null) {
                // Nothing is on its way to the disk. Whatever could end
                // has ended.
                return;
            }
            if (!self.append_ended) {
                // Nothing has ended yet, so there is something to wait for.
                self.storage.wait(timeout_ns);
            }
            self.advance();
        }

        /// The log's callback when the append in flight has ended. It only
        /// notes that: the rest is done by `advance`, outside the storage's
        /// event loop, because it may do blocking I/O of its own.
        fn onAppendEnded(request: *Log.Append) void {
            const self: *Store = @fieldParentPtr("append", request);
            assert(self.write_logging != null);
            assert(!self.append_ended);
            self.append_ended = true;
        }

        /// Moves the writes on: finishes the one whose record has become
        /// durable, and hands the next one to the log.
        ///
        /// The next write's record is started before the finished write is
        /// applied to the memtable, so that the disk is busy with one batch
        /// while the processor is busy with the batch before it. The
        /// exception is when the next write has to freeze the memtable
        /// first: the finished batch belongs in the memtable being frozen,
        /// so it goes in before the freeze.
        fn advance(self: *Store) void {
            assert(!self.advancing);
            self.advancing = true;
            defer self.advancing = false;

            // The write whose record was in flight, if it has ended.
            var ended: ?*Write = null;
            if (self.append_ended) {
                self.append_ended = false;
                const logged = self.write_logging.?;
                self.write_logging = null;
                if (self.append.result) |_| {
                    ended = logged;
                } else |err| {
                    self.broken = true;
                    self.finishWrite(logged, err);
                }
            }
            var ended_is_applied = false;

            while (self.write_logging == null and self.write_queue_head != null) {
                if (self.broken) {
                    // Callbacks run in the order the writes were started,
                    // so the write that ended goes first.
                    self.finishEnded(&ended, ended_is_applied);
                    self.finishWrite(self.dequeueWrite(), error.StoreBroken);
                    continue;
                }
                const next = self.write_queue_head.?;
                const batch_bytes = next.batch.bytes();

                // The finished batch is not in the memtable yet, but its
                // room there is spoken for.
                var memtable_reserved: usize = 0;
                if (ended != null and !ended_is_applied) {
                    memtable_reserved = memtableSizeMax(ended.?.batch.bytes());
                }
                const memtable_needed = memtableSizeMax(batch_bytes) + memtable_reserved;
                const memtable_is_full = memtable_needed > self.activeMemtable().bytesFree();
                const log_is_full = !self.log.hasRoomFor(batch_bytes.len);
                const must_make_room = memtable_is_full or log_is_full;
                if (must_make_room and ended != null and !ended_is_applied) {
                    self.applyWrite(ended.?);
                    ended_is_applied = true;
                    continue;
                }

                _ = self.dequeueWrite();
                self.logWrite(next, must_make_room) catch |err| {
                    // The write that ended is told so before this one is
                    // told it failed: callbacks run in start order.
                    self.finishEnded(&ended, ended_is_applied);
                    self.finishWrite(next, err);
                };
            }

            self.finishEnded(&ended, ended_is_applied);
        }

        /// Finishes the write whose record became durable, if it has not
        /// been finished yet: puts its batch in the memtable unless that
        /// has been done, runs its callback, and clears `ended` so that it
        /// is not finished twice.
        fn finishEnded(self: *Store, ended: *?*Write, ended_is_applied: bool) void {
            if (ended.* == null) {
                return;
            }
            const operation = ended.*.?;
            ended.* = null;
            if (!ended_is_applied) {
                self.applyWrite(operation);
            }
            self.finishWrite(operation, {});
        }

        /// Takes the oldest waiting write off the queue.
        fn dequeueWrite(self: *Store) *Write {
            const operation = self.write_queue_head.?;
            self.write_queue_head = operation.next;
            if (self.write_queue_head == null) {
                self.write_queue_tail = null;
            }
            operation.next = null;
            return operation;
        }

        /// Does this write's share of a flush in progress, makes room for
        /// its batch if there is none, and starts appending the batch to
        /// the log. On an error nothing has been logged.
        fn logWrite(self: *Store, operation: *Write, must_make_room: bool) CommitError!void {
            self.write_count += 1;
            const batch_bytes = operation.batch.bytes();
            const batch_memtable_size = memtableSizeMax(batch_bytes);

            // The share comes before the batch is logged, so that an error
            // from the flush leaves the batch unwritten.
            if (self.flushing != null) {
                try self.flushStep(flush_pace * self.flushShare(batch_bytes.len, batch_memtable_size));
            }

            // The batch goes to the log only if all of it can then be
            // applied, and only if the log has room for it. Whichever of
            // the memtable and the log fills first, the memtable is frozen
            // and a new log is started.
            if (must_make_room) {
                try self.makeRoom();
                assert(batch_memtable_size <= self.activeMemtable().bytesFree());
                assert(self.log.hasRoomFor(batch_bytes.len));
            }

            self.write_logging = operation;
            self.log.appendStart(&self.append, onAppendEnded, batch_bytes);
        }

        /// Puts a batch whose record is durable into the active memtable,
        /// where reads see it.
        fn applyWrite(self: *Store, operation: *Write) void {
            const memtable = self.activeMemtable();
            self.sequence_last = applyBatch(memtable, operation.batch.bytes(), self.sequence_last + 1);
            // The memtable has changed under any scan that is open.
            self.write_count += 1;
        }

        fn finishWrite(self: *Store, operation: *Write, result: CommitError!void) void {
            _ = self;
            assert(operation.in_flight);
            operation.in_flight = false;
            operation.result = result;
            operation.callback(operation);
        }

        /// A write that blocks: started, then waited for.
        const BlockingWrite = struct {
            operation: Write = .{},
            done: bool = false,

            fn onDone(operation: *Write) void {
                const state: *BlockingWrite = @fieldParentPtr("operation", operation);
                state.done = true;
            }
        };

        /// Applies `batch` as a unit, and blocks until that is done. When
        /// this returns without an error, the batch is durable.
        ///
        /// `EmptyBatch`, `StoreFull` and `StoreBroken` are reported before the
        /// batch is written anywhere. `EmptyBatch` and `StoreFull` leave the
        /// store usable.
        ///
        /// After any other error the batch may or may not be in the log: it can
        /// appear when the store is next opened. Every later write returns
        /// `StoreBroken` until the store is closed and opened again.
        pub fn write(self: *Store, batch: *const WriteBatch) WriteError!void {
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
            self.commit(&self.scratch) catch |err| switch (err) {
                // The batch holds one operation.
                error.EmptyBatch => unreachable,
                else => |other| return other,
            };
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
            self.commit(&self.scratch) catch |err| switch (err) {
                // The batch holds one operation.
                error.EmptyBatch => unreachable,
                else => |other| return other,
            };
        }

        /// Starts a write and runs the event loop until it has ended.
        fn commit(self: *Store, batch: *const WriteBatch) WriteError!void {
            var state: BlockingWrite = .{};
            try self.writeStart(&state.operation, BlockingWrite.onDone, batch);
            while (!state.done) {
                self.wait(blocking_wait_ns);
            }
            return state.operation.result;
        }

        /// How many bytes of a frozen memtable a write should see flushed,
        /// before `flush_pace` is applied, so that the flush is over before the
        /// next freeze.
        ///
        /// The next freeze comes when the active memtable or its log is full,
        /// whichever is first. A write uses up some part of each. The larger of
        /// the two parts is the part of the way to the next freeze that this
        /// write covers, and the write flushes that part of a whole memtable.
        fn flushShare(self: *const Store, batch_len: usize, batch_memtable_size: usize) usize {
            const memtable_size = self.activeMemtable().arena.buffer.len;
            const log_room: u64 = self.log.file_size - sector_size;
            const record_size: u64 = sector_log.recordSize(batch_len);
            // The record's part of the log, as bytes of a memtable.
            const log_share: usize = @intCast(record_size * memtable_size / log_room);
            return @max(batch_memtable_size, log_share);
        }

        /// Freezes the active memtable, which is full or whose log is full, so
        /// that the other one, which is empty, takes the writes.
        fn makeRoom(self: *Store) CommitError!void {
            // The shares that writes do are sized so that a flush is over
            // before the active memtable fills again. The store does not depend
            // on that: a flush that is still going is finished here.
            if (self.flushing != null) {
                try self.flushComplete();
            }
            // The frozen memtable needs a table slot to be flushed into, and
            // the manifest needs room to record the table.
            if (self.tables.count() == tables_max) {
                return error.StoreFull;
            }
            if (!self.manifest_writer.hasRoomForFlush()) {
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
        /// `StoreFull` means every table slot is taken, or the manifest has no
        /// room to record another table, and the active memtable was left as
        /// it is. After any error but `StoreFull` and `StoreBroken`,
        /// every later write returns `StoreBroken` until the store is closed and
        /// opened again.
        pub fn flush(self: *Store) CommitError!void {
            assert(!self.advancing);
            assert(!self.hasWritesInFlight());
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
            if (!self.manifest_writer.hasRoomForFlush()) {
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
            // an entry for the key has the newest one. A table is read only
            // if the key lies in its range of keys and its filter does not
            // rule the key out.
            const key_hash = bloom.hash(key);
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
                if (!slot.filter.mayContain(key_hash)) {
                    continue;
                }
                self.table_reads += 1;
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

        /// The part of `filter_storage` that belongs to one table slot, as
        /// a filter.
        fn slotFilter(self: *const Store, slot_index: usize) bloom.Filter {
            const start = slot_index * self.filter_size;
            return .init(self.filter_storage[start..][0..self.filter_size]);
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
            // The current log is not being appended to, so the buffer the two
            // share is free for the new one to be written out from.
            var log_new = try Log.Writer.create(
                self.storage,
                log_name,
                self.log_file_size,
                self.log_buffer,
                self.log.last,
            );
            errdefer {
                log_new.close();
                self.storage.deleteFile(log_name) catch {};
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

            const filter = self.slotFilter(slot_index);
            filter.clear();
            const writer = try TableWriter.create(self.storage, table_name, .{}, .{
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
                .filter = filter,
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

                flushing.filter.add(bloom.hash(entry.key));

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

            try self.storage.syncDir();
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
            var reader = TableReader.open(self.storage, table_name, index_buffer) catch |err| switch (err) {
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
                .filter = flushing.filter,
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
            try self.storage.deleteFile(log_name);

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
            //
            // The manifest is opened for writing first. That wipes an edit
            // a crash left half-written and syncs the file, so that every
            // edit read above, which the deletions below rely on, is durable
            // before a file is deleted on its say-so.
            self.manifest_writer = try ManifestWriter.open(self.storage, self.manifest_buffer, manifest_end.?);
            errdefer self.manifest_writer.close();

            try self.removeStrayFiles();
            if (newer_is_incomplete) {
                var name_buffer: [manifest.file_name_size_max]u8 = undefined;
                const log_name = manifest.fileName(&name_buffer, .log, log_number_newer);
                try self.storage.deleteFile(log_name);
            }
            // The directory as it now is must be durable before anything is
            // appended to a log. A file whose deletion was lost with the
            // power would come back beside a log that has since moved on:
            // a newer log left by a freeze that failed would then follow a
            // record that is no longer the named log's last.
            try self.storage.syncDir();

            self.active_index = 0;
            self.sequence_last = named.sequence_last;
            self.log_number = log_number_named;
            self.file_number_next = self.tables.file_number_next;
            var log_end = named.end;
            var log_file_len = named.file_size;

            if (newer != null) {
                self.active_index = 1;
                self.sequence_last = newer.?.sequence_last;
                self.log_number = log_number_newer;
                self.file_number_next = log_number_newer + 1;
                log_end = newer.?.end;
                log_file_len = newer.?.file_size;
            }

            // The log is opened for writing before the flush is run again.
            // Opening it syncs it. The flush will make the manifest name
            // this log and delete the one before it, so this log's header
            // and records must be durable by then, and a crash may have
            // left them written but not synced.
            var name_buffer: [manifest.file_name_size_max]u8 = undefined;
            const log_name = manifest.fileName(&name_buffer, .log, self.log_number);
            self.log = try Log.Writer.open(self.storage, log_name, log_file_len, self.log_buffer, log_end);
            errdefer self.log.close();

            if (newer != null) {
                // Run the interrupted flush again, from the start.
                try self.flushBegin(
                    0,
                    log_number_named,
                    named.end.last.op,
                    named.sequence_last,
                );
                try self.flushComplete();
            }
        }

        /// Reads the manifest and applies its edits to `tables`. Returns where
        /// the manifest ends, or `null` if the directory holds no store: there
        /// is no manifest, or a crash while the store was being created left
        /// one with no edits in it.
        fn readManifest(self: *Store) OpenError!?manifest.End {
            var reader = ManifestReader.open(self.storage, self.manifest_buffer) catch |err| switch (err) {
                error.FileNotFound => return null,
                // The file is all zeros, of whatever length: a crash came
                // while it was being created. It holds no edits.
                error.IncompleteLog => return null,
                // The header is intact, and the file is not the length a
                // manifest is.
                error.WrongFileSize => return error.Corrupt,
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
            self.log = try Log.Writer.create(self.storage, log_name, self.log_file_size, self.log_buffer, .none);
            errdefer self.log.close();

            self.manifest_writer = try ManifestWriter.create(self.storage, self.manifest_buffer);
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
                var listing = try self.storage.list();

                defer listing.close();
                while (true) {
                    const name = try listing.next();
                    if (name == null) {
                        break;
                    }
                    const parsed = manifest.parseFileName(name.?);
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
            var reader_or_error = Log.Reader.open(self.storage, log_name, self.log_buffer);
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
                // The header is intact and the file is not the length it gives.
                error.WrongFileSize => return error.Corrupt,
                else => |other| return other,
            }
            if (log_is_there) {
                try self.storage.deleteFile(log_name);
            }

            self.storage.deleteFile(manifest.file_name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |other| return other,
            };
        }

        /// Looks in the directory for a log newer than the one the manifest
        /// names, and returns its file number. There is at most one: the log a
        /// flush started before a crash. Nothing is changed.
        fn findNewerLog(self: *Store) OpenError!?u64 {
            var log_number_newer: ?u64 = null;

            var listing = try self.storage.list();

            defer listing.close();
            while (true) {
                const name = try listing.next();
                if (name == null) {
                    return log_number_newer;
                }
                const parsed = manifest.parseFileName(name.?);
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
                    var listing = try self.storage.list();

                    defer listing.close();
                    while (true) {
                        const name = try listing.next();
                        if (name == null) {
                            break;
                        }
                        const parsed = manifest.parseFileName(name.?);
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
                    try self.storage.deleteFile(name);
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
                var reader = TableReader.open(self.storage, name, index_buffer) catch |err| switch (err) {
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

                // The filter is not in the file. Read the table through to
                // fill it. No flush is running yet, so its block buffer is
                // free.
                const filter = self.slotFilter(slot_index);
                filter.clear();
                var entries = reader.iterator(self.flush_block_buffer);
                while (true) {
                    const entry = try entries.next();
                    if (entry == null) {
                        break;
                    }
                    filter.add(bloom.hash(entry.?.key));
                }

                self.slots[slot_index] = .{
                    .in_use = true,
                    .file_number = table.file_number,
                    .reader = reader,
                    .filter = filter,
                };
            }
        }

        /// What `replayLog` learned about a log.
        const ReplayedLog = struct {
            /// The record the log carries on from, as its file header says.
            previous: sector_log.RecordId,
            /// Where the log's valid records end.
            end: sector_log.End,
            /// The length of the log's file.
            file_size: u64,
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

            // No log is being appended to yet, so the log buffer is free to
            // hold the records being replayed.
            var reader = Log.Reader.open(self.storage, log_name, self.log_buffer) catch |err| switch (err) {
                // The header is intact and the file is not the length it gives.
                error.WrongFileSize => return error.Corrupt,
                else => |other| return other,
            };
            defer reader.close();
            const previous = reader.end().last;
            // A log this store wrote has room for the largest batch. One that
            // has not could not be appended to.
            if (reader.file_size < sector_log.fileSizeMin(log_payload_size_max)) {
                return error.Corrupt;
            }
            // A log is whole sectors. One that is not was not written by a
            // store, and records could not be appended to it.
            if (reader.file_size % sector_size != 0) {
                return error.Corrupt;
            }

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
                .file_size = reader.file_size,
                .sequence_last = sequence_last,
            };
        }
    };
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

// The tests below run a store on a real disk, in a temporary directory.
const DiskLog = DiskStore.Log;
const DiskTableWriter = DiskStore.TableWriter;
const DiskManifestWriter = DiskStore.ManifestWriter;
const DiskManifestReader = DiskStore.ManifestReader;

/// The memory a test gives a manifest writer or reader.
const TestManifestBuffer = [manifest.buffer_size]u8;
const RealStorage = @import("testing/real_storage.zig").RealStorage;
/// The layout the log and the manifest had before `sector_log.zig`. Only
/// the tests use it, to make files that earlier code wrote.
const wal = @import("wal.zig");

/// The size of each memtable in the tests that need a memtable to fill
/// after a few dozen writes.
const test_memtable_size = 64 * 1024;

/// The length of the values those tests write.
const test_value_size = 1000;

/// The length of each log file in the tests. Writing a log of the real
/// size out for every test would take far too long.
///
/// It is large enough that the small memtables of `openSmallStore` and the
/// model tests always fill before their log does, whatever the tests
/// write. A store from `openStore` has memtables of the full size, and its
/// log can fill first. A memtable of
/// `test_memtable_size` bytes holds at most this many entries, and each
/// entry was logged in a record of at least one sector.
const test_log_file_size = sector_size * (2 + test_log_records_max) + log_buffer_size;
const test_log_records_max = test_memtable_size / MemTable.entry_overhead_min;

comptime {
    assert(test_log_file_size % sector_size == 0);
    assert(test_log_file_size >= sector_log.fileSizeMin(log_payload_size_max));
    assert(model_memtable_size <= test_memtable_size);
}

fn openStore(dir: Io.Dir) !DiskStore {
    return DiskStore.openWithSizes(
        testing.allocator,
        testing.io,
        dir,
        .{},
        MemTable.buffer_size_max,
        test_log_file_size,
    );
}

fn openSmallStore(dir: Io.Dir) !DiskStore {
    return DiskStore.openWithSizes(
        testing.allocator,
        testing.io,
        dir,
        .{},
        test_memtable_size,
        test_log_file_size,
    );
}

/// A Storage on a directory, for the tests that make or read log files by
/// hand. It holds pointers into itself, so it is set up in place and must
/// not be moved.
const TestLogs = struct {
    event_loop: AsyncIo,
    storage: DiskStorage,
    buffer: []align(sector_size) u8,

    fn init(self: *TestLogs, dir: Io.Dir) !void {
        self.event_loop = try .init();
        errdefer self.event_loop.deinit();
        self.storage = .init(&self.event_loop, testing.io, dir);
        self.buffer = try testing.allocator.alignedAlloc(u8, .fromByteUnits(sector_size), log_buffer_size);
    }

    fn deinit(self: *TestLogs) void {
        testing.allocator.free(self.buffer);
        self.storage.deinit();
        self.event_loop.deinit();
    }
};

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

/// Reads `buffer.len` bytes of a log file from `offset`.
fn readLogBytes(dir: Io.Dir, log_number: u64, buffer: []u8, offset: u64) !void {
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    const file = try dir.openFile(testing.io, logName(&name_buffer, log_number), .{ .mode = .read_only });
    defer file.close(testing.io);
    const count = try file.readPositionalAll(testing.io, buffer, offset);
    try testing.expectEqual(buffer.len, count);
}

/// Overwrites part of a log file.
fn writeLogBytes(dir: Io.Dir, log_number: u64, bytes: []const u8, offset: u64) !void {
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    const file = try dir.openFile(testing.io, logName(&name_buffer, log_number), .{ .mode = .read_write });
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, bytes, offset);
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
fn makeLogReadOnly(store: *DiskStore, dir: Io.Dir) !void {
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    const name = logName(&name_buffer, store.log_number);
    const read_only = try dir.openFile(testing.io, name, .{ .mode = .read_only });
    store.log.file.handle.close(testing.io);
    store.log.file.handle = read_only;
}

/// Appends one record to the end of a log file of a store that is closed.
fn appendToLog(dir: Io.Dir, log_number: u64, payload: []const u8) !void {
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    const name = logName(&name_buffer, log_number);

    var logs: TestLogs = undefined;
    try logs.init(dir);
    defer logs.deinit();

    var reader: DiskLog.Reader = try .open(&logs.storage, name, logs.buffer);
    while (try reader.next()) |_| {}
    const end = reader.end();
    const file_size = reader.file_size;
    reader.close();

    var writer: DiskLog.Writer = try .open(&logs.storage, name, file_size, logs.buffer, end);
    defer writer.close();
    _ = try writer.append(payload);
}

/// Where the valid records of a log file of a store that is closed end.
fn logEnd(dir: Io.Dir, log_number: u64) !sector_log.End {
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    const name = logName(&name_buffer, log_number);

    var logs: TestLogs = undefined;
    try logs.init(dir);
    defer logs.deinit();

    var reader: DiskLog.Reader = try .open(&logs.storage, name, logs.buffer);
    defer reader.close();
    while (try reader.next()) |_| {}
    return reader.end();
}

/// Writes zeros over a log file from `offset` to its end, which is what
/// the file held there before anything was appended.
fn zeroLogFrom(dir: Io.Dir, log_number: u64, offset: u64) !void {
    var name_buffer: [manifest.file_name_size_max]u8 = undefined;
    const file = try dir.openFile(testing.io, logName(&name_buffer, log_number), .{ .mode = .read_write });
    defer file.close(testing.io);
    const len = try file.length(testing.io);
    const zeros: [sector_size]u8 = @splat(0);
    var position = offset;
    while (position < len) {
        const chunk: usize = @intCast(@min(zeros.len, len - position));
        try file.writePositionalAll(testing.io, zeros[0..chunk], position);
        position += chunk;
    }
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

fn expectValue(store: *DiskStore, key: []const u8, value: []const u8) !void {
    var buffer: [value_size_max]u8 = undefined;
    const found = try store.get(key, &buffer);
    try testing.expect(found != null);
    try testing.expectEqualSlices(u8, value, found.?);
}

fn expectAbsent(store: *DiskStore, key: []const u8) !void {
    var buffer: [value_size_max]u8 = undefined;
    const found = try store.get(key, &buffer);
    try testing.expect(found == null);
}

fn expectEntry(entry: ?DiskStore.Entry, key: []const u8, value: []const u8) !void {
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

fn putNumbered(store: *DiskStore, number: u64) !void {
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    try store.put(numberedKey(&key_buffer, number), numberedValue(&value_buffer, number));
}

fn expectNumbered(store: *DiskStore, number: u64) !void {
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    try expectValue(store, numberedKey(&key_buffer, number), numberedValue(&value_buffer, number));
}

/// Checks that a scan of the store gives exactly the numbered entries from
/// 0 to `count - 1`, in order.
fn expectNumberedScan(store: *DiskStore, count: u64) !void {
    var buffers: DiskStore.IteratorBuffers = try .init(testing.allocator);
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
    var buffers: DiskStore.IteratorBuffers = try .init(testing.allocator);
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
    var buffers: DiskStore.IteratorBuffers = try .init(testing.allocator);
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
    var buffers: DiskStore.IteratorBuffers = try .init(testing.allocator);
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
    try testing.expectEqual(DiskStore.FlushStage.writing, store.flushing.?.stage);
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
fn expectAfterCrash(store: *DiskStore, point: CrashPoint) !void {
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
    // A crash while a freeze was creating the second log leaves a file of
    // zeros, too short to be a log.
    const short_zeros: [5]u8 = @splat(0);
    try writeFile(tmp.dir, "000002.log", &short_zeros);

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
        try createLogAfter(tmp.dir, "000002.log", .none);
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
        try createLogAfter(tmp.dir, "000002.log", .none);
    }
    {
        try createLogAfter(tmp.dir, "000003.log", .none);
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

    var real: RealStorage = undefined;
    try real.init(dir);
    defer real.deinit();
    var writer: DiskTableWriter = try .create(&real.storage, "000003.sst", .{}, .{
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
        // Cut short, the log has lost part of its header's sector. What is
        // left is not zeros, so it is not taken for a log that was never
        // finished.
        try setLogLength(tmp.dir, log_number_first, sector_size - 1);
        try testing.expectError(error.NotALog, openStore(tmp.dir));
    }
    {
        // Nothing but zeros, which is what a log that was never finished
        // looks like. The manifest names this log, so it was finished.
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            var store = try openStore(tmp.dir);
            defer store.close(testing.allocator);
            try store.put("a", "1");
        }
        try zeroLogFrom(tmp.dir, log_number_first, 0);
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
        try createLogAfter(tmp.dir, "000002.log", .none);
    }
    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "a first log left too short by a crash while the store was created is replaced" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // What such a crash leaves: zeros, and not many of them.
    const short_zeros: [5]u8 = @splat(0);
    try writeFile(tmp.dir, "000001.log", &short_zeros);

    // Without leave to create a store, there is none to open.
    const options: Options = .{ .create_if_missing = false };
    const result = DiskStore.open(testing.allocator, testing.io, tmp.dir, options);
    try testing.expectError(error.StoreNotFound, result);
    // The refused open left the short log as it was.
    try testing.expectEqual(@as(u64, short_zeros.len), try logLength(tmp.dir, log_number_first));

    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, 0), store.opLatest());
    try store.put("a", "1");
    try expectValue(&store, "a", "1");
}

test "a first log left as zeros by a crash is created again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The file was being written out, and the crash came before its header.
    const zeros: [3 * sector_size]u8 = @splat(0);
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
        try createLogAfter(tmp.dir, "000001.log", .none);
        var real: RealStorage = undefined;
        try real.init(tmp.dir);
        defer real.deinit();
        var manifest_buffer: TestManifestBuffer align(sector_size) = undefined;
        var manifest_writer: DiskManifestWriter = try .create(&real.storage, &manifest_buffer);
        manifest_writer.close();
    }

    const options: Options = .{ .create_if_missing = false };
    const result = DiskStore.open(testing.allocator, testing.io, tmp.dir, options);
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

test "a manifest whose header is damaged is reported, and nothing is deleted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
    }

    // Put bytes that are not a log header where the manifest's header is.
    {
        const file = try tmp.dir.openFile(testing.io, manifest.file_name, .{ .mode = .write_only });
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, "not this", 0);
    }

    try testing.expectError(error.NotALog, openStore(tmp.dir));
    try testing.expect(try fileExists(tmp.dir, manifest.file_name));
    try testing.expect(try fileExists(tmp.dir, "000001.log"));
}

/// Replaces the manifest in `dir` with one in the layout earlier code wrote
/// (`wal.zig`), holding `edit_count` edits. With one edit the file is far
/// shorter than a sector.
fn writeOldLayoutManifest(dir: Io.Dir, edit_count: u64) !void {
    try dir.deleteFile(testing.io, manifest.file_name);

    var edit_buffer: [manifest.edit_size_max]u8 = undefined;
    const edit_bytes = manifest.encode(.{
        .added = &.{},
        .removed = &.{},
        .log_number = 1,
        .file_number_next = 2,
        .op_flushed = 0,
        .sequence_flushed = 0,
    }, &edit_buffer);

    var real: RealStorage = undefined;
    try real.init(dir);
    defer real.deinit();
    var old_writer: wal.WriterType(DiskStorage) = try .create(
        &real.storage,
        manifest.file_name,
        manifest.edit_size_max,
        .none,
    );
    defer old_writer.close();
    var appended: u64 = 0;
    while (appended < edit_count) : (appended += 1) {
        _ = try old_writer.append(edit_bytes);
    }
}

test "a manifest in the layout earlier code wrote is reported, and nothing is deleted" {
    // One edit makes a manifest shorter than a sector. A hundred make one
    // longer than a sector.
    const edit_counts = [_]u64{ 1, 100 };
    for (edit_counts) |edit_count| {
        // Beside a first log that holds a write, and beside one that holds
        // nothing, which is what a store that was never written to has.
        const log_holds_write = [_]bool{ true, false };
        for (log_holds_write) |holds_write| {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            {
                var store = try openStore(tmp.dir);
                defer store.close(testing.allocator);
                if (holds_write) {
                    try store.put("a", "1");
                }
            }
            try writeOldLayoutManifest(tmp.dir, edit_count);

            try testing.expectError(error.NotALog, openStore(tmp.dir));
            try testing.expect(try fileExists(tmp.dir, manifest.file_name));
            try testing.expect(try fileExists(tmp.dir, "000001.log"));
        }
    }
}

test "a manifest of the wrong length is reported, and nothing is deleted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
    }

    // A whole log with a right header, one sector longer than a manifest.
    try tmp.dir.deleteFile(testing.io, manifest.file_name);
    {
        const manifest_buffer = try testing.allocator.alignedAlloc(
            u8,
            .fromByteUnits(sector_size),
            manifest.buffer_size,
        );
        defer testing.allocator.free(manifest_buffer);
        var real: RealStorage = undefined;
        try real.init(tmp.dir);
        defer real.deinit();
        var log: DiskLog.Writer = try .create(
            &real.storage,
            manifest.file_name,
            manifest.file_size + sector_size,
            manifest_buffer,
            .none,
        );
        log.close();
    }

    try testing.expectError(error.Corrupt, openStore(tmp.dir));
    try testing.expect(try fileExists(tmp.dir, manifest.file_name));
    try testing.expect(try fileExists(tmp.dir, "000001.log"));
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

        var manifest_buffer: TestManifestBuffer align(sector_size) = undefined;
        var real: RealStorage = undefined;
        try real.init(tmp.dir);
        defer real.deinit();
        var reader: DiskManifestReader = try .open(&real.storage, &manifest_buffer);
        while (try reader.next()) |_| {}
        const end = reader.end();
        reader.close();

        var writer: DiskManifestWriter = try .open(&real.storage, &manifest_buffer, end);
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
        const previous: sector_log.RecordId = .{ .op = op_before_largest, .checksum = 0 };
        var logs: TestLogs = undefined;
        try logs.init(tmp.dir);
        defer logs.deinit();
        var log: DiskLog.Writer = try .create(&logs.storage, "000001.log", test_log_file_size, logs.buffer, previous);
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
        var real: RealStorage = undefined;
        try real.init(tmp.dir);
        defer real.deinit();
        var manifest_buffer: TestManifestBuffer align(sector_size) = undefined;
        var writer: DiskManifestWriter = try .create(&real.storage, &manifest_buffer);
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
fn fillFirstMemtable(store: *DiskStore) !u64 {
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

/// The length of the logs in the test of batches of small operations. It
/// has room for more full batches than a memtable can take, so that the
/// memtable is what fills.
const small_operations_log_size = sector_size +
    small_operations_batches_max * sector_log.recordSize(write_batch.size_max);

/// Two more full batches than fit in a memtable. An operation takes at
/// least as many bytes in the memtable as it does in its batch, so a
/// memtable holds no more full batches than its size divided by a batch's.
const small_operations_batches_max = MemTable.buffer_size_max / write_batch.size_max + 2;

comptime {
    assert(small_operations_log_size % sector_size == 0);
    assert(small_operations_log_size >= sector_log.fileSizeMin(log_payload_size_max));
}

fn openSmallOperationsStore(dir: Io.Dir) !DiskStore {
    return DiskStore.openWithSizes(
        testing.allocator,
        testing.io,
        dir,
        .{},
        MemTable.buffer_size_max,
        small_operations_log_size,
    );
}

test "batches of small operations fill a memtable, and both logs replay" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var batch: WriteBatch = try .init(testing.allocator);
    defer batch.deinit(testing.allocator);

    var key_number: u64 = 0;
    var batches: u64 = 0;
    {
        var store = try openSmallOperationsStore(tmp.dir);
        defer store.close(testing.allocator);

        // A small operation takes far more room in the memtable than it
        // does in the batch, so the memtable fills long before the log is
        // as large. Stop at the batch that froze it.
        while (store.log_number == log_number_first) {
            key_number = try fillBatchWithSmallOperations(&batch, key_number);

            // It is the memtable that fills, never the log.
            const memtable_is_full = memtableSizeMax(batch.bytes()) > store.activeMemtable().bytesFree();
            try testing.expect(store.log.hasRoomFor(batch.bytes().len));

            try store.write(&batch);
            batches += 1;
            const froze = store.log_number != log_number_first;
            try testing.expectEqual(memtable_is_full, froze);
        }
        try testing.expect(batches > 1);
        try testing.expectEqual(batches, store.opLatest());
    }

    // The first log fits in one memtable again and is flushed; the second
    // log's one batch fits in the other.
    var store = try openSmallOperationsStore(tmp.dir);
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
        store.flushing.?.writer.file.handle.close(testing.io);
        store.flushing.?.writer.file.handle = read_only;

        try testing.expectError(error.NotOpenForWriting, store.flush());
        try testing.expectEqual(DiskStore.FlushStage.failed, store.flushing.?.stage);

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
fn fillWithFlushStillGoing(store: *DiskStore, count_before: u64) !u64 {
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
    try testing.expectEqual(DiskStore.FlushStage.writing, store.flushing.?.stage);
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
    var buffers: DiskStore.IteratorBuffers = try .init(testing.allocator);
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
    var buffers: DiskStore.IteratorBuffers = try .init(testing.allocator);
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
    try testing.expectEqual(DiskStore.FlushStage.table_written, store.flushing.?.stage);
    try testing.expectEqual(@as(usize, 0), store.tables.count());
    try testing.expect(try fileExists(tmp.dir, "000001.log"));
}

test "open deletes nothing when the manifest has lost its last edit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeStoreWithOneTable(tmp.dir);

    // Damage a byte of the manifest's last edit. The edit that recorded
    // the flush no longer counts, so the manifest names the first log,
    // which the flush deleted, and holds no table.
    //
    // The manifest holds two edits of one sector each, after its header's
    // sector: the one that created the store, and the flush's.
    const flush_edit_offset = 2 * sector_size;
    const manifest_before = try testing.allocator.alloc(u8, manifest.file_size);
    defer testing.allocator.free(manifest_before);
    {
        const file = try tmp.dir.openFile(testing.io, manifest.file_name, .{ .mode = .read_write });
        defer file.close(testing.io);
        try testing.expectEqual(@as(u64, manifest.file_size), try file.length(testing.io));

        const damaged_offset = flush_edit_offset + sector_log.record_header_size;
        var byte: [1]u8 = undefined;
        _ = try file.readPositionalAll(testing.io, &byte, damaged_offset);
        // The edit is there: its first byte is the count of tables it adds.
        try testing.expectEqual(@as(u8, 1), byte[0]);
        byte[0] ^= 0xff;
        try file.writePositionalAll(testing.io, &byte, damaged_offset);

        _ = try file.readPositionalAll(testing.io, manifest_before, 0);
    }

    try testing.expectError(error.Corrupt, openStore(tmp.dir));

    // The table that holds the data is still there, and the manifest is as
    // it was: the damaged edit was not wiped.
    try expectNumberedFiles(tmp.dir, &.{ "000002.log", "000003.sst" });
    const manifest_after = try testing.allocator.alloc(u8, manifest.file_size);
    defer testing.allocator.free(manifest_after);
    const file = try tmp.dir.openFile(testing.io, manifest.file_name, .{ .mode = .read_only });
    defer file.close(testing.io);
    _ = try file.readPositionalAll(testing.io, manifest_after, 0);
    try testing.expect(std.mem.eql(u8, manifest_before, manifest_after));
}

/// Makes a store in `dir` that holds one write in its first log, closes
/// it, and returns the last record of that log.
fn makeStoreWithOneWrite(dir: Io.Dir) !sector_log.RecordId {
    var store = try openStore(dir);
    defer store.close(testing.allocator);
    try store.put("a", "1");
    return store.log.last;
}

/// Creates an empty log file that says it carries on from `previous`.
fn createLogAfter(dir: Io.Dir, name: []const u8, previous: sector_log.RecordId) !void {
    var logs: TestLogs = undefined;
    try logs.init(dir);
    defer logs.deinit();
    var log: DiskLog.Writer = try .create(&logs.storage, name, test_log_file_size, logs.buffer, previous);
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

    var last: sector_log.RecordId = undefined;
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

    var last: sector_log.RecordId = undefined;
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
fn makeStoreByHand(dir: Io.Dir, edit: manifest.Edit, manifest_previous: sector_log.RecordId) !void {
    try createLogAfter(dir, "000001.log", .{ .op = edit.op_flushed, .checksum = 0 });

    const edit_buffer = try testing.allocator.alloc(u8, manifest.edit_size_max);
    defer testing.allocator.free(edit_buffer);
    const edit_bytes = manifest.encode(edit, edit_buffer);

    const manifest_buffer = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(sector_size),
        manifest.buffer_size,
    );
    defer testing.allocator.free(manifest_buffer);

    var real: RealStorage = undefined;
    try real.init(dir);
    defer real.deinit();
    var log: DiskLog.Writer = try .create(
        &real.storage,
        manifest.file_name,
        manifest.file_size,
        manifest_buffer,
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
    var summary: DiskTableWriter.Summary = undefined;
    {
        var real: RealStorage = undefined;
        try real.init(tmp.dir);
        defer real.deinit();
        var writer: DiskTableWriter = try .create(
            &real.storage,
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

fn openModelStore(dir: Io.Dir) !DiskStore {
    return DiskStore.openWithSizes(
        testing.allocator,
        testing.io,
        dir,
        .{},
        model_memtable_size,
        test_log_file_size,
    );
}

/// Checks every key and a full scan of the store against the model. Entry
/// `i` of the model is the value of key number `i`, or `null` if that key is
/// not present.
fn expectModel(
    store: *DiskStore,
    buffers: *const DiskStore.IteratorBuffers,
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
    var buffers: DiskStore.IteratorBuffers = try .init(testing.allocator);
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
    const result = DiskStore.open(testing.allocator, testing.io, tmp.dir, options);
    try testing.expectError(error.StoreNotFound, result);

    // Once the store exists, the same options open it.
    var created = try openStore(tmp.dir);
    created.close(testing.allocator);
    var store: DiskStore = try .open(testing.allocator, testing.io, tmp.dir, options);
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
        const end_before = try logEnd(tmp.dir, log_number_first);

        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        try testing.expectError(error.EmptyBatch, store.write(&batch));

        // A batch that was cleared is empty again.
        try batch.put("b", "2");
        batch.clear();
        try testing.expectError(error.EmptyBatch, store.write(&batch));

        // The rejected writes used no op number and left no trace.
        try testing.expectEqual(@as(u64, 1), store.opLatest());
        try testing.expectEqual(end_before, try logEnd(tmp.dir, log_number_first));
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

    // The second batch's record is three sectors long.
    const long_value: [2 * sector_size]u8 = @splat('v');
    const record_size = 3 * sector_size;

    var record_offset: u64 = 0;
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
        record_offset = (try logEnd(tmp.dir, log_number_first)).offset;

        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        try batch.put("a", "changed");
        try batch.put("b", &long_value);
        try testing.expectEqual(@as(usize, record_size), sector_log.recordSize(batch.bytes().len));
        try store.write(&batch);
    }

    // With the log whole, the store opens with both operations of the batch.
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try testing.expectEqual(@as(u64, 2), store.opLatest());
        try expectValue(&store, "a", "changed");
        try expectValue(&store, "b", &long_value);
    }

    // A crash during the append can leave any of the record's sectors
    // unwritten, still holding the zeros the file was created with. Each
    // time, the store opens with the first write and nothing of the batch.
    var record: [record_size]u8 = undefined;
    try readLogBytes(tmp.dir, log_number_first, &record, record_offset);
    const zeros: [sector_size]u8 = @splat(0);

    var landed_mask: u8 = 0;
    while (landed_mask < 7) : (landed_mask += 1) {
        for (0..3) |sector| {
            const offset = record_offset + sector * sector_size;
            const landed = (landed_mask >> @intCast(sector)) & 1 == 1;
            if (landed) {
                try writeLogBytes(tmp.dir, log_number_first, record[sector * sector_size ..][0..sector_size], offset);
            } else {
                try writeLogBytes(tmp.dir, log_number_first, &zeros, offset);
            }
        }

        var store = try openStore(tmp.dir);
        try testing.expectEqual(@as(u64, 1), store.opLatest());
        try expectValue(&store, "a", "1");
        try expectAbsent(&store, "b");
        store.close(testing.allocator);
    }

    // The store carries on from there.
    var store = try openStore(tmp.dir);
    defer store.close(testing.allocator);
    try store.put("c", "3");
    try testing.expectEqual(@as(u64, 2), store.opLatest());
    try expectValue(&store, "c", "3");
}

test "a full log freezes the memtable, as a full memtable does" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A log with room for the largest batch and four sectors more, under
    // memtables of the full size: the log fills long before the memtable.
    const small_log_size = sector_log.fileSizeMin(log_payload_size_max) + 4 * sector_size;
    const records_per_log = (small_log_size - sector_size) / sector_size;
    const writes = 2 * records_per_log + 1;

    var key_buffer: [16]u8 = undefined;
    {
        var store = try DiskStore.openWithSizes(
            testing.allocator,
            testing.io,
            tmp.dir,
            .{},
            MemTable.buffer_size_max,
            small_log_size,
        );
        defer store.close(testing.allocator);

        var index: u64 = 0;
        while (index < writes) : (index += 1) {
            const key = try std.fmt.bufPrint(&key_buffer, "key{d:0>6}", .{index});
            try store.put(key, "value");
        }
        // Each of the first two logs filled, and each time the memtable
        // was frozen: the store is on its third log. A freeze takes two
        // file numbers, one for the new log and one for the table.
        try testing.expectEqual(log_number_first + 3, store.log_number);
        try testing.expect(store.tables.count() >= 1);
        try testing.expectEqual(writes, store.opLatest());
    }

    var store = try DiskStore.openWithSizes(
        testing.allocator,
        testing.io,
        tmp.dir,
        .{},
        MemTable.buffer_size_max,
        small_log_size,
    );
    defer store.close(testing.allocator);
    try testing.expectEqual(writes, store.opLatest());
    var index: u64 = 0;
    while (index < writes) : (index += 1) {
        const key = try std.fmt.bufPrint(&key_buffer, "key{d:0>6}", .{index});
        try expectValue(&store, key, "value");
    }
}

test "a newer log whose header is damaged is reported, not deleted" {
    // A newer log with no header is what a crash while it was being
    // created leaves, and is deleted. One that still holds something is a
    // log that has lost its header, and deleting it would lose writes.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const last = try makeStoreWithOneWrite(tmp.dir);
    try createLogAfter(tmp.dir, "000002.log", last);
    try appendToLog(tmp.dir, 2, "anything at all");

    const zeros: [sector_size]u8 = @splat(0);
    try writeLogBytes(tmp.dir, 2, &zeros, 0);
    try testing.expectError(error.NotALog, openStore(tmp.dir));
    try testing.expect(try fileExists(tmp.dir, "000002.log"));
}

test "a directory cannot be open in two stores at once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try openStore(tmp.dir);
    try first.put("a", "1");
    const end_before = try logEnd(tmp.dir, log_number_first);

    // A second open is refused, and leaves the log alone.
    try testing.expectError(error.StoreAlreadyOpen, openStore(tmp.dir));
    try testing.expectEqual(end_before, try logEnd(tmp.dir, log_number_first));

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

// From here on the tests run a store on the simulated storage, which can
// crash.

const simulated_storage = @import("testing/storage.zig");
const Simulated = simulated_storage.Storage;
const SimulatedStore = StoreType(Simulated);

/// The length of each log file in the crash tests: room for the largest
/// batch and a few dozen sectors more. The simulated storage keeps every
/// file in memory, twice, so the log is kept as short as a log can be.
const crash_log_file_size = sector_log.fileSizeMin(log_payload_size_max) + 48 * sector_size;

fn openSimulatedStore(storage: *Simulated) !SimulatedStore {
    return SimulatedStore.openOnStorageWithSizes(
        testing.allocator,
        storage,
        .{},
        test_memtable_size,
        crash_log_file_size,
    );
}

fn putNumberedSimulated(store: *SimulatedStore, number: u64) !void {
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    try store.put(numberedKey(&key_buffer, number), numberedValue(&value_buffer, number));
}

/// Whether the store holds the numbered entry. Fails if the store holds
/// the key with any other value.
fn hasNumberedSimulated(store: *SimulatedStore, number: u64) !bool {
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    var get_buffer: [test_value_size]u8 = undefined;
    const found = try store.get(numberedKey(&key_buffer, number), &get_buffer);
    if (found == null) {
        return false;
    }
    try testing.expectEqualSlices(u8, numberedValue(&value_buffer, number), found.?);
    return true;
}

/// How many writes the crash tests make when nothing stops them: enough
/// for the log to fill and the memtable to be frozen and flushed more than
/// once.
const crash_test_writes = 200;

/// Checks a store that was reopened after a crash. Writes `0` to
/// `acknowledged - 1` had returned before the crash and must all be there.
/// The write after them was in flight and may be there or not. Nothing
/// later may be there. Returns how many writes the store holds.
fn expectAfterSimulatedCrash(store: *SimulatedStore, acknowledged: u64) !u64 {
    var number: u64 = 0;
    while (number < acknowledged) : (number += 1) {
        try testing.expect(try hasNumberedSimulated(store, number));
    }
    var present = acknowledged;
    if (try hasNumberedSimulated(store, acknowledged)) {
        present += 1;
    }
    number = acknowledged + 1;
    while (number < crash_test_writes) : (number += 1) {
        try testing.expect(!try hasNumberedSimulated(store, number));
    }
    try testing.expectEqual(present, store.opLatest());
    return present;
}

test "simulated: a store is created, written, closed and opened" {
    var storage: Simulated = .init(testing.allocator, .{ .seed = 5 });
    defer storage.deinit();

    {
        var store = try openSimulatedStore(&storage);
        defer store.close(testing.allocator);
        var number: u64 = 0;
        while (number < crash_test_writes) : (number += 1) {
            try putNumberedSimulated(&store, number);
        }
        // The workload is long enough to freeze the memtable twice. A
        // freeze takes two file numbers, one for the new log and one for
        // the table.
        try testing.expect(store.log_number >= log_number_first + 3);
        try testing.expect(store.tables.count() >= 2);
    }

    var store = try openSimulatedStore(&storage);
    defer store.close(testing.allocator);
    try testing.expectEqual(@as(u64, crash_test_writes), store.opLatest());
    var number: u64 = 0;
    while (number < crash_test_writes) : (number += 1) {
        try testing.expect(try hasNumberedSimulated(&store, number));
    }
}

test "simulated: no acknowledged write is lost, whenever the crash comes" {
    // How many storage operations the whole workload takes, so that crash
    // points can be spread over all of it: the creation of the store, the
    // appends, the freezes and the flushes.
    var operations_total: u64 = 0;
    {
        var storage: Simulated = .init(testing.allocator, .{ .seed = 0 });
        defer storage.deinit();
        var store = try openSimulatedStore(&storage);
        defer store.close(testing.allocator);
        var number: u64 = 0;
        while (number < crash_test_writes) : (number += 1) {
            try putNumberedSimulated(&store, number);
        }
        operations_total = storage.operations_started;
    }

    const kinds = [_]simulated_storage.CrashKind{ .power_loss, .process_kill };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();

    var trial: u64 = 0;
    while (trial < 120) : (trial += 1) {
        const kind = kinds[trial % kinds.len];
        const crash_after = 1 + random.uintLessThan(u64, operations_total);

        var storage: Simulated = .init(testing.allocator, .{ .seed = trial });
        defer storage.deinit();
        storage.crashAfterOperations(crash_after, kind);

        // Write until the crash stops the store. The crash can come while
        // the store is still being created, in which case nothing was
        // written.
        var acknowledged: u64 = 0;
        var opened = openSimulatedStore(&storage);
        if (opened) |*store| {
            while (acknowledged < crash_test_writes) {
                putNumberedSimulated(store, acknowledged) catch break;
                acknowledged += 1;
            }
            store.close(testing.allocator);
        } else |_| {}
        if (!storage.crashed) {
            // The crash was planned for later than the workload ran.
            continue;
        }
        storage.restart();

        // The store opens, and holds every write that had returned.
        var present: u64 = 0;
        {
            var store = try openSimulatedStore(&storage);
            defer store.close(testing.allocator);
            present = try expectAfterSimulatedCrash(&store, acknowledged);
        }

        // Opening the store was the moment it took what it found as its
        // contents. A power loss straight afterwards must change nothing,
        // even one that loses everything that was not made durable.
        storage.crash(.power_loss_worst);
        storage.restart();
        {
            var store = try openSimulatedStore(&storage);
            defer store.close(testing.allocator);
            try testing.expectEqual(present, try expectAfterSimulatedCrash(&store, acknowledged));

            // And the store carries on.
            var number = present;
            while (number < present + 5) : (number += 1) {
                try putNumberedSimulated(&store, number);
            }
            try store.flush();
        }
        var store = try openSimulatedStore(&storage);
        defer store.close(testing.allocator);
        var number: u64 = 0;
        while (number < present + 5) : (number += 1) {
            try testing.expect(try hasNumberedSimulated(&store, number));
        }
    }
}

/// The key of wide test entry `number`: the number, then padding up to the
/// longest key the store takes. A table of such keys has a manifest edit
/// several sectors long.
fn wideKey(buffer: *[key_size_max]u8, number: u64) []const u8 {
    @memset(buffer, 'k');
    _ = std.fmt.bufPrint(buffer[0..8], "{d:0>8}", .{number}) catch unreachable;
    return buffer;
}

fn putWideSimulated(store: *SimulatedStore, number: u64) !void {
    var key_buffer: [key_size_max]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    try store.put(wideKey(&key_buffer, number), numberedValue(&value_buffer, number));
}

/// Whether the store holds the wide entry. Fails if the store holds the key
/// with any other value.
fn hasWideSimulated(store: *SimulatedStore, number: u64) !bool {
    var key_buffer: [key_size_max]u8 = undefined;
    var value_buffer: [test_value_size]u8 = undefined;
    var get_buffer: [test_value_size]u8 = undefined;
    const found = try store.get(wideKey(&key_buffer, number), &get_buffer);
    if (found == null) {
        return false;
    }
    try testing.expectEqualSlices(u8, numberedValue(&value_buffer, number), found.?);
    return true;
}

/// How many writes the wide-key crash test makes when nothing stops it:
/// enough for several flushes, and few enough that the store does not fill.
const wide_test_writes = 50;

/// The same check as `expectAfterSimulatedCrash`, for wide entries.
fn expectWideAfterSimulatedCrash(store: *SimulatedStore, acknowledged: u64) !u64 {
    var number: u64 = 0;
    while (number < acknowledged) : (number += 1) {
        try testing.expect(try hasWideSimulated(store, number));
    }
    var present = acknowledged;
    if (try hasWideSimulated(store, acknowledged)) {
        present += 1;
    }
    number = acknowledged + 1;
    while (number < wide_test_writes) : (number += 1) {
        try testing.expect(!try hasWideSimulated(store, number));
    }
    try testing.expectEqual(present, store.opLatest());
    return present;
}

test "simulated: a crash while a manifest edit of several sectors is written leaves a store that opens" {
    // With keys of the longest size, the edit that records a flush is
    // longer than two sectors. A power loss can keep some of the sectors
    // of an edit in flight and lose others. A process that is killed can
    // leave the whole edit written and not yet durable.
    //
    // First the workload is run with no crash, to learn which storage
    // operation is the write of each such edit. The store starts the same
    // operations in the same order every time, whatever the seed.
    var edit_operations: [tables_max]u64 = undefined;
    // Where in the manifest each of those edits goes.
    var edit_offsets: [tables_max]u64 = undefined;
    var edit_count: usize = 0;
    {
        var storage: Simulated = .init(testing.allocator, .{ .seed = 0 });
        defer storage.deinit();
        var store = try openSimulatedStore(&storage);
        defer store.close(testing.allocator);
        var number: u64 = 0;
        while (number < wide_test_writes) : (number += 1) {
            const tables_before = store.tables.count();
            const manifest_offset_before = store.manifest_writer.log.offset;
            try putWideSimulated(&store, number);
            if (store.tables.count() > tables_before) {
                // The edit is what this test says it is: several sectors.
                const edit_size = store.manifest_writer.log.offset - manifest_offset_before;
                try testing.expect(edit_size > 2 * sector_size);
                // Three sectors exactly, which the count of sectors that
                // survive a crash relies on below.
                try testing.expectEqual(@as(u64, 3 * sector_size), edit_size);
                edit_operations[edit_count] = storage.lastWriteOperation(manifest.file_name);
                edit_offsets[edit_count] = manifest_offset_before;
                edit_count += 1;
            }
        }
    }
    // The workload flushes several times.
    try testing.expect(edit_count >= 3);

    const kinds = [_]simulated_storage.CrashKind{ .power_loss, .process_kill };
    // In how many trials the crash left all of the edit's sectors in the
    // file, and in how many it left some and not others. Both must happen,
    // or the test did not test what it says.
    var edits_whole: u64 = 0;
    var edits_torn: u64 = 0;

    for (edit_operations[0..edit_count], 0..) |edit_operation, edit_index| {
        for (kinds) |kind| {
            var seed: u64 = 0;
            while (seed < 16) : (seed += 1) {
                var storage: Simulated = .init(testing.allocator, .{ .seed = seed });
                defer storage.deinit();
                // The crash comes with the edit's write in flight.
                storage.crashAfterOperations(edit_operation, kind);

                var acknowledged: u64 = 0;
                {
                    var store = try openSimulatedStore(&storage);
                    defer store.close(testing.allocator);
                    while (acknowledged < wide_test_writes) {
                        putWideSimulated(&store, acknowledged) catch break;
                        acknowledged += 1;
                    }
                }
                try testing.expect(storage.crashed);
                storage.restart();

                // Every sector of the edit holds something other than
                // zeros: a header or part of a key.
                var sectors_there: u64 = 0;
                var sector_index: u64 = 0;
                while (sector_index < 3) : (sector_index += 1) {
                    const sector_start: usize = @intCast(edit_offsets[edit_index] + sector_index * sector_size);
                    const sector = storage.contents(manifest.file_name)[sector_start..][0..sector_size];
                    if (!std.mem.allEqual(u8, sector, 0)) {
                        sectors_there += 1;
                    }
                }
                if (sectors_there == 3) {
                    edits_whole += 1;
                }
                if (sectors_there == 1 or sectors_there == 2) {
                    edits_torn += 1;
                }

                // In half the trials the machine crashes again while the
                // store is being opened, a few operations in.
                if (seed % 2 == 1) {
                    storage.crashAfterOperations(1 + seed, kind);
                    if (openSimulatedStore(&storage)) |opened| {
                        var store = opened;
                        store.close(testing.allocator);
                    } else |_| {}
                    if (storage.crashed) {
                        storage.restart();
                    } else {
                        // Opening took fewer operations than that.
                        storage.crash(kind);
                        storage.restart();
                    }
                }

                var present: u64 = 0;
                {
                    var store = try openSimulatedStore(&storage);
                    defer store.close(testing.allocator);
                    present = try expectWideAfterSimulatedCrash(&store, acknowledged);
                    // Opening the store runs an interrupted flush again,
                    // so the table is there whether the edit survived or
                    // was written a second time.
                    try testing.expect(store.tables.count() >= edit_index + 1);
                }

                // A power loss straight after the store was opened must
                // change nothing.
                storage.crash(.power_loss_worst);
                storage.restart();
                var store = try openSimulatedStore(&storage);
                defer store.close(testing.allocator);
                try testing.expectEqual(present, try expectWideAfterSimulatedCrash(&store, acknowledged));
            }
        }
    }
    try testing.expect(edits_whole > 0);
    try testing.expect(edits_torn > 0);
}

test "a first log that has lost its header, with no manifest, is reported, not deleted" {
    // With no manifest there is no store to open, and a first log that
    // holds nothing is a leftover to clear away. One that holds records is
    // not, even if its header is gone.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createLogAfter(tmp.dir, "000001.log", .none);
    try appendToLog(tmp.dir, log_number_first, "anything at all");
    const zeros: [sector_size]u8 = @splat(0);
    try writeLogBytes(tmp.dir, log_number_first, &zeros, 0);

    try testing.expectError(error.NotALog, openStore(tmp.dir));
    try testing.expect(try fileExists(tmp.dir, "000001.log"));
}

test "a log whose file is not the length its header gives is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try openStore(tmp.dir);
        defer store.close(testing.allocator);
        try store.put("a", "1");
    }
    // One sector more than the header says.
    try setLogLength(tmp.dir, log_number_first, test_log_file_size + sector_size);
    try testing.expectError(error.Corrupt, openStore(tmp.dir));
}

test "a flush keeps pace with a log that fills faster than its memtable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A log with room for the largest batch and four sectors more, under
    // memtables of the full size.
    const small_log_size = sector_log.fileSizeMin(log_payload_size_max) + 4 * sector_size;
    const records_per_log = (small_log_size - sector_size) / sector_size;

    var store = try DiskStore.openWithSizes(
        testing.allocator,
        testing.io,
        tmp.dir,
        .{},
        MemTable.buffer_size_max,
        small_log_size,
    );
    defer store.close(testing.allocator);

    // One large batch, so that the memtable to be frozen holds about a
    // megabyte.
    {
        var batch: WriteBatch = try .init(testing.allocator);
        defer batch.deinit(testing.allocator);
        var key_buffer: [8]u8 = undefined;
        var value_buffer: [test_value_size]u8 = undefined;
        var number: u64 = 0;
        while (number < 1000) : (number += 1) {
            try batch.put(numberedKey(&key_buffer, number), numberedValue(&value_buffer, number));
        }
        try store.write(&batch);
    }

    // Tiny writes fill the rest of the log, and the memtable is frozen.
    var key_buffer: [16]u8 = undefined;
    var index: u64 = 0;
    while (store.log_number == log_number_first) : (index += 1) {
        const key = try std.fmt.bufPrint(&key_buffer, "key{d:0>6}", .{index});
        try store.put(key, "value");
    }
    try testing.expect(store.flushing != null);
    const log_number_frozen = store.log_number;

    // Each tiny write uses a whole sector of the new log, and almost none
    // of the memtable. Paced by the memtable alone, the flush would still
    // be going when the log filled again. Paced by the log, it is over
    // well before that.
    var writes_during_flush: u64 = 0;
    while (store.flushing != null) : (index += 1) {
        const key = try std.fmt.bufPrint(&key_buffer, "key{d:0>6}", .{index});
        try store.put(key, "value");
        writes_during_flush += 1;
        try testing.expectEqual(log_number_frozen, store.log_number);
    }
    try testing.expect(writes_during_flush <= records_per_log / 2 + 2);
    try testing.expectEqual(@as(usize, 1), store.tables.count());
}

test "simulated: a newer log whose header was written but not synced does not strand the store" {
    // A freeze creates the new log and writes its header last. If the
    // process is killed after the header is written and before it is
    // synced, the restart finds a newer log with a header. It runs the
    // flush again, which makes the manifest name that log. The header must
    // be durable before that, or a power loss leaves the manifest naming a
    // file of zeros.
    // Which of the freeze's storage operations is the write of the new
    // log's header: after the writes that write the file out, and the sync
    // of them.
    const prewrite_writes = (crash_log_file_size + log_buffer_size - 1) / log_buffer_size;
    const freeze_header_operation = prewrite_writes + 2;

    // In how many seeds the header reached the disk without being synced,
    // which is the state this test is about.
    var header_landed: u64 = 0;

    var seed: u64 = 0;
    while (seed < 30) : (seed += 1) {
        var storage: Simulated = .init(testing.allocator, .{ .seed = seed });
        defer storage.deinit();

        // Fill the first memtable to just short of a freeze.
        var acknowledged: u64 = 0;
        {
            var store = try openSimulatedStore(&storage);
            defer store.close(testing.allocator);
            while (store.log_number == log_number_first) {
                var key_buffer: [8]u8 = undefined;
                var value_buffer: [test_value_size]u8 = undefined;
                const key = numberedKey(&key_buffer, acknowledged);
                const value = numberedValue(&value_buffer, acknowledged);
                // Stop before the write that would freeze.
                var batch: WriteBatch = try .init(testing.allocator);
                defer batch.deinit(testing.allocator);
                try batch.put(key, value);
                if (memtableSizeMax(batch.bytes()) > store.activeMemtable().bytesFree()) {
                    break;
                }
                try store.write(&batch);
                acknowledged += 1;
            }
            try testing.expectEqual(log_number_first, store.log_number);

            // The next write freezes. The freeze writes the new log out,
            // syncs it, and then writes its header. Kill the process with
            // the header's write in flight: in some seeds the header's
            // sector lands, and is then on the disk but not synced.
            storage.crashAfterOperations(freeze_header_operation, .process_kill);
            putNumberedSimulated(&store, acknowledged) catch {};
        }
        try testing.expect(storage.crashed);
        storage.restart();
        if (storage.contents("000002.log")[0] != 0) {
            header_landed += 1;
        }

        // Open the store, which may run the flush again, then lose power
        // in the worst way: everything that was not made durable is gone.
        {
            var store = try openSimulatedStore(&storage);
            store.close(testing.allocator);
        }
        storage.crash(.power_loss_worst);
        storage.restart();

        var store = try openSimulatedStore(&storage);
        defer store.close(testing.allocator);
        var number: u64 = 0;
        while (number < acknowledged) : (number += 1) {
            try testing.expect(try hasNumberedSimulated(&store, number));
        }
    }
    // The state was reached, so the test tested it.
    try testing.expect(header_landed > 0);
}

/// A numbered write that has been started and not waited for, with the
/// batch it holds.
const StartedWrite = struct {
    operation: SimulatedStore.Write = .{},
    batch: WriteBatch = undefined,
    ended: bool = false,
    /// The order in which the callbacks ran, counted across the test.
    ended_at: u64 = 0,

    var ended_count: u64 = 0;

    fn init(self: *StartedWrite, number: u64) !void {
        self.* = .{};
        self.batch = try .init(testing.allocator);
        var key_buffer: [8]u8 = undefined;
        var value_buffer: [test_value_size]u8 = undefined;
        try self.batch.put(numberedKey(&key_buffer, number), numberedValue(&value_buffer, number));
    }

    fn deinit(self: *StartedWrite) void {
        self.batch.deinit(testing.allocator);
    }

    fn onEnded(operation: *SimulatedStore.Write) void {
        const self: *StartedWrite = @fieldParentPtr("operation", operation);
        ended_count += 1;
        self.ended_at = ended_count;
        self.ended = true;
    }
};

test "simulated: a write that has been started is not seen by reads until it has ended" {
    var storage: Simulated = .init(testing.allocator, .{ .seed = 2 });
    defer storage.deinit();
    var store = try openSimulatedStore(&storage);
    defer store.close(testing.allocator);

    var started: StartedWrite = undefined;
    try started.init(0);
    defer started.deinit();
    StartedWrite.ended_count = 0;

    try store.writeStart(&started.operation, StartedWrite.onEnded, &started.batch);
    // Starting a write never runs its callback.
    try testing.expect(!started.ended);
    try testing.expect(store.hasWritesInFlight());

    // The store can be read while the batch is on its way to the disk, and
    // the batch is not there yet.
    var reads_meanwhile: u64 = 0;
    while (!started.ended) {
        try testing.expect(!try hasNumberedSimulated(&store, 0));
        reads_meanwhile += 1;
        store.poll();
    }
    try testing.expect(reads_meanwhile >= 1);
    try started.operation.result;
    try testing.expect(!store.hasWritesInFlight());
    try testing.expect(try hasNumberedSimulated(&store, 0));
    try testing.expectEqual(@as(u64, 1), store.opLatest());
}

test "simulated: writes started together end in the order they were started" {
    var storage: Simulated = .init(testing.allocator, .{ .seed = 4, .latency_ticks_max = 8 });
    defer storage.deinit();
    var store = try openSimulatedStore(&storage);
    defer store.close(testing.allocator);

    // Enough writes to freeze the memtable on the way.
    const count = 90;
    const writes = try testing.allocator.alloc(StartedWrite, count);
    defer testing.allocator.free(writes);
    for (writes, 0..) |*started, number| {
        try started.init(number);
    }
    defer for (writes) |*started| {
        started.deinit();
    };
    StartedWrite.ended_count = 0;

    for (writes) |*started| {
        try store.writeStart(&started.operation, StartedWrite.onEnded, &started.batch);
    }
    for (writes) |*started| {
        try testing.expect(!started.ended);
    }

    while (store.hasWritesInFlight()) {
        // Between turns of the event loop the store holds exactly the
        // writes whose callbacks have run: a batch goes into the memtable
        // and its callback runs in the same turn.
        var number: u64 = 0;
        while (number < count) : (number += 1) {
            const is_there = try hasNumberedSimulated(&store, number);
            try testing.expectEqual(writes[number].ended, is_there);
        }
        store.wait(0);
    }

    for (writes, 1..) |*started, order| {
        try started.operation.result;
        try testing.expectEqual(@as(u64, order), started.ended_at);
    }
    try testing.expectEqual(@as(u64, count), store.opLatest());
    try testing.expect(store.log_number > log_number_first);
}

test "simulated: a write that cannot be started is refused at once, with no callback" {
    var storage: Simulated = .init(testing.allocator, .{ .seed = 6 });
    defer storage.deinit();
    var store = try openSimulatedStore(&storage);
    defer store.close(testing.allocator);

    var started: StartedWrite = undefined;
    try started.init(0);
    defer started.deinit();

    var empty: WriteBatch = try .init(testing.allocator);
    defer empty.deinit(testing.allocator);
    try testing.expectError(
        error.EmptyBatch,
        store.writeStart(&started.operation, StartedWrite.onEnded, &empty),
    );
    try testing.expect(!store.hasWritesInFlight());

    // Break the store: its storage fails under a write.
    storage.crashAfterOperations(1, .process_kill);
    try testing.expectError(error.InputOutput, putNumberedSimulated(&store, 1));
    try testing.expectError(
        error.StoreBroken,
        store.writeStart(&started.operation, StartedWrite.onEnded, &started.batch),
    );
    try testing.expect(!started.ended);
    try testing.expect(!store.hasWritesInFlight());
}

test "simulated: with several writes in flight, a crash keeps a prefix that holds every acknowledged one" {
    const depth = 4;
    const kinds = [_]simulated_storage.CrashKind{ .power_loss, .process_kill };
    var prng: std.Random.DefaultPrng = .init(0xdeed);
    const random = prng.random();

    var trial: u64 = 0;
    while (trial < 80) : (trial += 1) {
        var storage: Simulated = .init(testing.allocator, .{ .seed = trial, .latency_ticks_max = 6 });
        defer storage.deinit();

        const writes = try testing.allocator.alloc(StartedWrite, crash_test_writes);
        defer testing.allocator.free(writes);
        for (writes, 0..) |*started, number| {
            try started.init(number);
        }
        defer for (writes) |*started| {
            started.deinit();
        };

        // Keep `depth` writes in flight until the crash, which comes at a
        // random storage operation after the store is open.
        var acknowledged: u64 = 0;
        {
            var store = try openSimulatedStore(&storage);
            defer store.close(testing.allocator);
            storage.crashAfterOperations(1 + random.uintLessThan(u64, 400), kinds[trial % kinds.len]);

            var started_count: u64 = 0;
            while (true) {
                while (started_count < crash_test_writes and started_count < acknowledged + depth) {
                    const started = &writes[started_count];
                    store.writeStart(&started.operation, StartedWrite.onEnded, &started.batch) catch break;
                    started_count += 1;
                }
                if (!store.hasWritesInFlight()) {
                    break;
                }
                store.wait(0);
                // Count the writes that ended without an error. They end in
                // order, so they are a prefix.
                while (acknowledged < started_count and writes[acknowledged].ended) {
                    writes[acknowledged].operation.result catch break;
                    acknowledged += 1;
                }
            }
            // Let every write that was started be called back.
            while (store.hasWritesInFlight()) {
                store.wait(0);
            }
        }
        if (!storage.crashed) {
            continue;
        }
        storage.restart();

        var store = try openSimulatedStore(&storage);
        defer store.close(testing.allocator);
        // Everything acknowledged is there, then possibly the one write
        // that was in the log when the crash came, then nothing.
        const present = try expectAfterSimulatedCrash(&store, acknowledged);
        try testing.expect(present <= acknowledged + 1);
    }
}

test "a lookup skips the tables whose filters rule the key out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Three tables, each holding every third number, so that all three
    // cover the same range of keys and only a filter can tell them apart.
    // A third of them fits in one of the tests' small memtables.
    const count = 150;
    {
        var store = try openSmallStore(tmp.dir);
        defer store.close(testing.allocator);
        var remainder: u64 = 0;
        while (remainder < 3) : (remainder += 1) {
            var number: u64 = remainder;
            while (number < count) : (number += 3) {
                try putNumbered(&store, 2 * number);
            }
            try store.flush();
        }
        try testing.expectEqual(@as(usize, 3), store.tables.count());

        // A key that is there is found by reading one table, give or take
        // the odd wrong "maybe" from another table's filter.
        store.table_reads = 0;
        var number: u64 = 0;
        while (number < count) : (number += 1) {
            try expectNumbered(&store, 2 * number);
        }
        try testing.expect(store.table_reads >= count);
        try testing.expect(store.table_reads <= count + count / 10);

        // A key that is in no table, but inside every table's range, reads
        // almost none: odd numbers were never written.
        store.table_reads = 0;
        var key_buffer: [8]u8 = undefined;
        number = 0;
        while (number < count - 1) : (number += 1) {
            try expectAbsent(&store, numberedKey(&key_buffer, 2 * number + 1));
        }
        try testing.expect(store.table_reads <= count / 10);
    }

    // The filters are not stored. Opening the store builds them again, and
    // they work the same.
    var store = try openSmallStore(tmp.dir);
    defer store.close(testing.allocator);
    store.table_reads = 0;
    var key_buffer: [8]u8 = undefined;
    var number: u64 = 0;
    while (number < count - 1) : (number += 1) {
        try expectAbsent(&store, numberedKey(&key_buffer, 2 * number + 1));
    }
    try testing.expect(store.table_reads <= count / 10);
    number = 0;
    while (number < count) : (number += 1) {
        try expectNumbered(&store, 2 * number);
    }
}
