//! The key-value store: an ordered map from byte-string keys to byte-string
//! values that survives a crash.
//!
//! A `Store` lives in one directory. Every write goes to the write-ahead log
//! and is synced before it is applied to the memtable, so a write that
//! returned without an error is durable. Opening a store replays its log.
//!
//! Writes are grouped into a `WriteBatch`, which is applied as a unit: after
//! a crash either every operation in it is present or none is. A batch
//! becomes exactly one record in the log.
//!
//! The store is not safe to use from more than one thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const MemTable = @import("memtable.zig").MemTable;
const sstable = @import("sstable.zig");
const wal = @import("wal.zig");
const write_batch = @import("write_batch.zig");
const WriteBatch = write_batch.WriteBatch;

comptime {
    // A flushed memtable must fit in one table. `sstable.table_size_max` is
    // the memtable's size, which holds as long as an entry takes no more
    // room in a table than it does in the memtable.
    std.debug.assert(MemTable.buffer_size_max <= sstable.table_size_max);
    std.debug.assert(sstable.entry_overhead <= MemTable.entry_overhead_min);

    // A batch is the payload of one log record.
    std.debug.assert(write_batch.size_max <= wal.payload_size_format_max);

    // Any batch fits in an empty memtable, so a batch can always be applied
    // after a flush. Each operation takes at most the memtable's largest
    // overhead beyond its own bytes in the batch, and a batch holds the most
    // operations when every one of them is the smallest.
    const overhead_max = MemTable.entrySizeMax(0, 0) - write_batch.operation_size_min;
    const batch_memtable_size_max = write_batch.size_max + write_batch.operation_count_max * overhead_max;
    std.debug.assert(batch_memtable_size_max <= MemTable.buffer_size_max - MemTable.buffer_size_min);
}

pub const Options = struct {
    /// Create the store if `dir` does not hold one yet.
    create_if_missing: bool = true,
};

pub const Store = struct {
    pub const OpenError = error{
        /// `dir` holds no store and `create_if_missing` is false.
        StoreNotFound,
        /// The log holds a record that is not a valid batch.
        InvalidBatch,
        /// The log holds more than fits in the memtable.
        LogTooLargeForMemtable,
    } || Allocator.Error ||
        wal.Reader.OpenError || wal.Reader.NextError ||
        wal.Writer.CreateError || wal.Writer.OpenError;

    pub const WriteError = error{
        /// The memtable has no room for the batch. Until the store can flush
        /// memtables to files, this means the store is full.
        StoreFull,
    } || wal.Writer.AppendError;

    /// `put` also rejects a key or value over the limit.
    pub const PutError = error{
        /// The key is longer than `write_batch.key_size_max`.
        KeyTooLarge,
        /// The value is longer than `write_batch.value_size_max`.
        ValueTooLarge,
    } || WriteError;

    /// `delete` also rejects a key over the limit.
    pub const DeleteError = error{
        /// The key is longer than `write_batch.key_size_max`.
        KeyTooLarge,
    } || WriteError;

    /// Reads cannot fail yet. They will once they can touch files, so
    /// callers handle an error from the start.
    pub const ReadError = error{};

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// A forward-only cursor over the store's live entries in key order.
    /// Deleted keys are skipped. The cursor, and every slice it returned,
    /// is valid until the next write to the store.
    pub const Iterator = struct {
        /// Positions the cursor at the first entry.
        pub fn seekToFirst(self: *Iterator) void {
            _ = self;
            @panic("TODO");
        }

        /// Positions the cursor at the first entry whose key is >= `key`.
        pub fn seek(self: *Iterator, key: []const u8) void {
            _ = self;
            _ = key;
            @panic("TODO");
        }

        /// Returns the entry at the cursor and advances past it.
        pub fn next(self: *Iterator) ReadError!?Entry {
            _ = self;
            @panic("TODO");
        }
    };

    /// Opens the store in `dir`, replaying its log. `gpa` is used only here,
    /// to allocate everything the store will need, and is not retained.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, options: Options) OpenError!Store {
        _ = gpa;
        _ = io;
        _ = dir;
        _ = options;
        @panic("TODO");
    }

    /// `gpa` must be the allocator passed to `open`.
    pub fn close(self: *Store, gpa: Allocator) void {
        _ = self;
        _ = gpa;
        @panic("TODO");
    }

    /// Applies `batch` as a unit. When this returns without an error, the
    /// batch is durable.
    ///
    /// `batch` must hold at least one operation.
    ///
    /// After any error from the log the store must not be written to again.
    /// `StoreFull` is reported before anything is written, and leaves the
    /// store unchanged and usable.
    pub fn write(self: *Store, batch: *const WriteBatch) WriteError!void {
        _ = self;
        _ = batch;
        @panic("TODO");
    }

    /// Writes a batch holding one put.
    pub fn put(self: *Store, key: []const u8, value: []const u8) PutError!void {
        _ = self;
        _ = key;
        _ = value;
        @panic("TODO");
    }

    /// Writes a batch holding one delete. Deleting a key that is not present
    /// is not an error.
    pub fn delete(self: *Store, key: []const u8) DeleteError!void {
        _ = self;
        _ = key;
        @panic("TODO");
    }

    /// Returns the value for `key`, or `null` if the key is not present. The
    /// value is valid until the next write to the store.
    pub fn get(self: *Store, key: []const u8) ReadError!?[]const u8 {
        _ = self;
        _ = key;
        @panic("TODO");
    }

    /// Returns a cursor positioned at the first entry.
    pub fn iterator(self: *Store) Iterator {
        _ = self;
        @panic("TODO");
    }

    /// The op number of the last batch written, or 0 if there has been none.
    /// Each batch is given the next op number.
    pub fn opLatest(self: *const Store) u64 {
        _ = self;
        @panic("TODO");
    }
};
