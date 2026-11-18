//! The write-ahead log, in whole sectors, in a file of fixed size.
//!
//! This is the log the store writes its batches to, and the layout of the
//! manifest (`manifest.zig`), whose records are edits. It replaces the
//! format in `wal.zig`, which the store no longer uses; the log benchmark
//! in `bench.zig` still does.
//!
//! Why it differs from `wal.zig`. A durable write is cheap when it changes
//! nothing but data, and expensive when the file system also has to record
//! that the file grew or that space was used for the first time. So:
//!
//! - The file is written out to its full size, with zeros, when it is
//!   created. An append then overwrites space that already holds data.
//! - A record starts on a sector boundary and is padded with zeros to the
//!   next one. An append is one write of whole sectors from one buffer,
//!   which is what direct I/O needs, and it never touches a sector that
//!   holds a record written before it. A crash during an append can
//!   therefore damage only the record being appended, which was never
//!   reported as durable.
//!
//! File layout, with all integers little-endian:
//!
//!     sector 0:       file header, then zeros
//!                       magic (8 bytes)
//!                       file size (u64)
//!                       previous op (u64)
//!                       previous checksum (u32)
//!                       header checksum (u32)
//!     sector 1 on:    records, each a whole number of sectors
//!                       record header:  header checksum (u32)
//!                                       previous checksum (u32)
//!                                       op (u64)
//!                                       payload length (u32)
//!                                       payload checksum (u32)
//!                       payload
//!                       zeros up to the next sector boundary
//!
//! Records are numbered and chained exactly as in `wal.zig`: each has an
//! op one more than the record before it and stores that record's header
//! checksum, and the file header says which record the first one follows.
//!
//! Creating a log. The file is created, written out with zeros and synced,
//! the directory is synced, and only then is the file header written. A
//! file with a valid header is therefore complete and durably named. A
//! crash before the header leaves a file of zeros, possibly short, which
//! holds no records and is reported as `IncompleteLog`. A file with no
//! valid header that holds anything but zeros, however short, is reported
//! as `NotALog`.
//!
//! Where the log ends. The file's length says nothing, so the reader walks
//! the records. At each sector boundary it expects the next record of the
//! chain, complete and with both checksums right. The first place that
//! does not hold one is the end of the log, provided nothing that follows
//! it shows the log went further. What can follow is checked in a window
//! one largest record long: if any sector boundary in it holds a record
//! header with a right checksum and a higher op, a record in between has
//! been damaged and the log is reported as corrupt. Only one append is ever
//! in flight, so a crash leaves at most one damaged record, and it is the
//! last; a later record after a damaged one cannot be a crash's doing.
//!
//! A record header at the expected place that has a right checksum but does
//! not continue the chain, or gives a length that cannot be, was written by
//! a writer and is not something a crash produces. That is corruption too.
//!
//! Known limit. A payload is the client's bytes. If a value happens to hold
//! the image of a record header with a higher op at a sector boundary, and
//! a crash then tears the record before it, the reader takes the image for
//! a later record and reports corruption where there was only a torn
//! append. Nothing durable is lost, but the store will not open until the
//! log is repaired. A checksum seeded with a secret of the store would
//! close this; it is left for later.
//!
//! When a reader finds a problem it cannot explain by a crash, it fails. It
//! never silently drops a record that was reported as durable.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const constants = @import("constants.zig");
const crc32c = @import("checksum.zig").crc32c;
const wal = @import("wal.zig");
const BlockingType = @import("storage_blocking.zig").BlockingType;

/// The unit the log is written in.
pub const sector_size = constants.sector_size;

/// How long one turn of the event loop may block while a blocking append
/// waits for its record to be durable. The loop returns as soon as any
/// operation ends.
const blocking_wait_ns = 100 * std.time.ns_per_ms;

pub const file_header_size = @sizeOf(FileHeader);
pub const record_header_size = @sizeOf(RecordHeader);

/// Identifies one record in the chain. The type is the one `wal.zig`
/// defines, which numbers and chains its records the same way.
pub const RecordId = wal.RecordId;

/// Where the valid records of a log file end.
pub const End = struct {
    /// The offset in the file where the next record goes. A multiple of
    /// the sector size.
    offset: u64,
    /// The last valid record, or the file header's previous record if the
    /// file holds no records.
    last: RecordId,
};

const magic: [8]u8 = "beanlog2".*;

/// The longest payload the format can represent. The payload length is a u32
/// on disk.
pub const payload_size_format_max = std.math.maxInt(u32);

comptime {
    // The structs are written to the file exactly as they are in memory,
    // and the format is little-endian.
    assert(builtin.cpu.arch.endian() == .little);

    // These sizes are part of the format.
    assert(file_header_size == 32);
    assert(record_header_size == 24);

    // Both headers must fit in the first sector of what they head.
    assert(file_header_size <= sector_size);
    assert(record_header_size <= sector_size);
}

/// The first bytes of a log file, as they are in the file.
const FileHeader = extern struct {
    magic: [8]u8,
    /// The length of the file in bytes.
    file_size: u64,
    /// The op of the record this file's first record follows.
    previous_op: u64,
    /// The header checksum of that record.
    previous_checksum: u32,
    /// Covers the rest of the header.
    checksum: u32,

    fn init(file_size: u64, previous_record: RecordId) FileHeader {
        var header: FileHeader = .{
            .magic = magic,
            .file_size = file_size,
            .previous_op = previous_record.op,
            .previous_checksum = previous_record.checksum,
            .checksum = 0,
        };
        header.checksum = header.expectedChecksum();
        return header;
    }

    /// Returns `null` if `bytes` is not a valid file header.
    fn fromBytes(bytes: *const [file_header_size]u8) ?FileHeader {
        const header = std.mem.bytesToValue(FileHeader, bytes);
        if (!std.mem.eql(u8, &header.magic, &magic)) {
            return null;
        }
        if (header.checksum != header.expectedChecksum()) {
            return null;
        }
        return header;
    }

    fn toBytes(header: *const FileHeader) *const [file_header_size]u8 {
        return std.mem.asBytes(header);
    }

    /// The checksum these fields must carry. It covers every field before
    /// `checksum`.
    fn expectedChecksum(header: *const FileHeader) u32 {
        const bytes = header.toBytes();
        const covered_end = @offsetOf(FileHeader, "checksum");
        return crc32c(bytes[0..covered_end]);
    }

    fn previous(header: *const FileHeader) RecordId {
        return .{ .op = header.previous_op, .checksum = header.previous_checksum };
    }
};

/// The first bytes of every record, as they are in the file. The payload
/// follows.
const RecordHeader = extern struct {
    /// Covers the rest of the header.
    header_checksum: u32,
    /// The header checksum of the record before this one.
    previous_checksum: u32,
    op: u64,
    payload_len: u32,
    /// Covers the payload.
    payload_checksum: u32,

    fn fromBytes(bytes: *const [record_header_size]u8) RecordHeader {
        return std.mem.bytesToValue(RecordHeader, bytes);
    }

    fn toBytes(header: *const RecordHeader) *const [record_header_size]u8 {
        return std.mem.asBytes(header);
    }

    /// The header checksum these fields must carry. It covers every field
    /// after `header_checksum`.
    fn expectedHeaderChecksum(header: *const RecordHeader) u32 {
        const bytes = header.toBytes();
        const covered_start = @offsetOf(RecordHeader, "previous_checksum");
        return crc32c(bytes[covered_start..]);
    }

    fn isValid(header: *const RecordHeader) bool {
        return header.header_checksum == header.expectedHeaderChecksum();
    }
};

/// How many bytes of the file a record with a payload of `payload_len`
/// bytes takes: its header and payload, rounded up to whole sectors.
pub fn recordSize(payload_len: usize) usize {
    const unpadded = record_header_size + payload_len;
    return std.mem.alignForward(usize, unpadded, sector_size);
}

/// The length of the buffer a writer or a reader needs to hold one record
/// whose payload is at most `payload_size_max` bytes.
pub fn bufferSize(payload_size_max: usize) usize {
    return recordSize(payload_size_max);
}

/// The smallest file that can hold the file header and one record with a
/// payload of `payload_size_max` bytes.
pub fn fileSizeMin(payload_size_max: usize) u64 {
    return sector_size + recordSize(payload_size_max);
}

/// The longest payload a buffer of `buffer_len` bytes can hold a record
/// for.
fn payloadSizeMax(buffer_len: usize) usize {
    return buffer_len - record_header_size;
}

fn assertBuffer(buffer: []align(sector_size) u8) void {
    assert(buffer.len >= sector_size);
    assert(buffer.len % sector_size == 0);
    assert(payloadSizeMax(buffer.len) <= payload_size_format_max);
}

fn assertFileSize(file_size: u64, buffer_len: usize) void {
    assert(file_size % sector_size == 0);
    // The header's sector, and room for one record as long as the buffer.
    assert(file_size >= sector_size + buffer_len);
}

pub fn LogType(comptime Storage: type) type {
    return struct {
        const Blocking = BlockingType(Storage);

        /// Appends records to a log file. A record is durable once `append`
        /// returns.
        pub const Writer = struct {
            storage: *Storage,
            file: Storage.File,
            file_size: u64,
            /// Holds the record being appended: header, payload and
            /// padding. The caller owns it.
            buffer: []align(sector_size) u8,
            /// Where in the file the next record will be written.
            offset: u64,
            /// The last record in the log. The next record chains from it.
            last: RecordId,
            /// Set when a write has failed and the file's state is unknown.
            broken: bool,
            /// Whether an append is in flight.
            appending: bool,

            pub const CreateError = Storage.CreateError || Storage.WriteError ||
                Storage.SyncError || Storage.SyncDirError;

            pub const OpenError = Storage.OpenError || Storage.SyncError ||
                Storage.ReadError || Storage.WriteError;

            pub const AppendError = error{
                /// The payload is longer than the writer's buffer can hold.
                PayloadTooLarge,
                /// The file has no room left for a record of this size. The
                /// log is unchanged.
                LogFull,
            } || Storage.WriteError;

            /// Creates a new, empty log named `name`, `file_size` bytes
            /// long, and makes it durable. Fails if the file already
            /// exists.
            ///
            /// `buffer` is used to write the file out and, afterwards, to
            /// hold each record on its way to the file. The longest payload
            /// the writer accepts is the buffer's length less a record
            /// header. `file_size` must be a multiple of the sector size
            /// and leave room for the file header and one record as long
            /// as the buffer.
            ///
            /// If this fails, the file is removed again. If the process
            /// dies partway through, a file of zeros can be left behind,
            /// which `Reader.open` reports as `IncompleteLog`.
            ///
            /// `previous` is the record this log continues from: the last
            /// record of the log file before it, or `RecordId.none` for a
            /// brand-new log.
            pub fn create(
                storage: *Storage,
                name: []const u8,
                file_size: u64,
                buffer: []align(sector_size) u8,
                previous: RecordId,
            ) CreateError!Writer {
                assertBuffer(buffer);
                assertFileSize(file_size, buffer.len);
                assert(previous.op < std.math.maxInt(u64));

                const file = try storage.createFile(name, .{ .direct = true });
                // The create succeeded, so this call made the file and may
                // remove it. Without this, a failed create would block the
                // next one.
                errdefer storage.deleteFile(name) catch {};
                errdefer storage.closeFile(file);

                // Write the whole file out, so that appends later overwrite
                // space that already holds data.
                @memset(buffer, 0);
                var offset: u64 = 0;
                while (offset < file_size) {
                    const len: usize = @intCast(@min(buffer.len, file_size - offset));
                    try Blocking.writeAll(storage, file, buffer[0..len], offset, .unsynced);
                    offset += len;
                }
                try Blocking.syncFile(storage, file);
                try storage.syncDir();

                // The header goes last. Once it is durable, the file is
                // complete, and its name is durable too.
                const header: FileHeader = .init(file_size, previous);
                @memcpy(buffer[0..file_header_size], header.toBytes());
                try Blocking.writeAll(storage, file, buffer[0..sector_size], 0, .durable);

                return .{
                    .storage = storage,
                    .file = file,
                    .file_size = file_size,
                    .buffer = buffer,
                    .offset = sector_size,
                    .last = previous,
                    .broken = false,
                    .appending = false,
                };
            }

            /// Opens an existing log to append after its valid records.
            /// `end` must come from `Reader.end` after that reader reached
            /// the end of the same file, and `file_size` from the reader
            /// too.
            ///
            /// The remains of a torn append at `end` are wiped, and the file
            /// is synced, before this returns. A record that the
            /// reader found may have been written just before the process
            /// was killed, and never synced. The reader's caller has
            /// treated it as part of the log, so it must be durable before
            /// anything is built on it.
            pub fn open(
                storage: *Storage,
                name: []const u8,
                file_size: u64,
                buffer: []align(sector_size) u8,
                end: End,
            ) OpenError!Writer {
                assertBuffer(buffer);
                assertFileSize(file_size, buffer.len);
                assert(end.offset >= sector_size);
                assert(end.offset % sector_size == 0);
                assert(end.offset <= file_size);
                assert(end.last.op < std.math.maxInt(u64));

                const file = try storage.openFile(name, .read_write, .{ .direct = true });
                errdefer storage.closeFile(file);
                try Blocking.syncFile(storage, file);

                // What a torn append left where the next record goes is
                // wiped. If its header stayed, a later append of a
                // different record with the same tail, torn the other way,
                // would complete it, and a write that was never
                // acknowledged, and was seen to be absent, would appear.
                // One sector is enough: a record is only ever found through
                // the header in its first sector.
                if (end.offset < file_size) {
                    const sector = buffer[0..sector_size];
                    const sector_read = try Blocking.readAll(storage, file, sector, end.offset);
                    assert(sector_read == sector_size);
                    if (!std.mem.allEqual(u8, sector, 0)) {
                        @memset(sector, 0);
                        try Blocking.writeAll(storage, file, sector, end.offset, .durable);
                    }
                }

                return .{
                    .storage = storage,
                    .file = file,
                    .file_size = file_size,
                    .buffer = buffer,
                    .offset = end.offset,
                    .last = end.last,
                    .broken = false,
                    .appending = false,
                };
            }

            /// No append may be in flight.
            pub fn close(self: *Writer) void {
                assert(!self.appending);
                self.storage.closeFile(self.file);
                self.* = undefined;
            }

            /// The longest payload `append` accepts.
            pub fn payloadSizeLimit(self: *const Writer) usize {
                return payloadSizeMax(self.buffer.len);
            }

            /// Whether the file has room for a record with a payload of
            /// `payload_len` bytes.
            pub fn hasRoomFor(self: *const Writer, payload_len: usize) bool {
                const room = self.file_size - self.offset;
                return recordSize(payload_len) <= room;
            }

            /// How many bytes of the file are left for records.
            pub fn roomLeft(self: *const Writer) u64 {
                return self.file_size - self.offset;
            }

            /// Starts appending one record. The record is given the next op.
            /// `callback` runs later, from the storage's event loop, when
            /// the record is durable or the append has failed; the outcome
            /// is in `request.result`.
            ///
            /// The payload is copied before this returns. `request` is the
            /// caller's and must not move until the callback has run. Only
            /// one append may be in flight at a time, and the writer must
            /// not move while one is.
            ///
            /// The caller has checked that the payload fits: it is no
            /// longer than `payloadSizeLimit`, and `hasRoomFor` it is true.
            ///
            /// After an error the state of the file is unknown, and the
            /// writer must not be used again.
            pub fn appendStart(
                self: *Writer,
                request: *Append,
                callback: *const fn (request: *Append) void,
                payload: []const u8,
            ) void {
                assert(!self.broken);
                assert(!self.appending);
                assert(self.last.op < std.math.maxInt(u64));
                assert(payload.len <= self.payloadSizeLimit());
                assert(self.hasRoomFor(payload.len));

                var header: RecordHeader = .{
                    .header_checksum = 0,
                    .previous_checksum = self.last.checksum,
                    .op = self.last.op + 1,
                    .payload_len = @intCast(payload.len),
                    .payload_checksum = crc32c(payload),
                };
                header.header_checksum = header.expectedHeaderChecksum();

                // The record is put together in the buffer and written in
                // one piece: header, payload, zeros to the sector boundary.
                const record_size = recordSize(payload.len);
                const record = self.buffer[0..record_size];
                const payload_end = record_header_size + payload.len;
                @memcpy(record[0..record_header_size], header.toBytes());
                @memcpy(record[record_header_size..payload_end], payload);
                @memset(record[payload_end..], 0);

                request.* = .{
                    .writer = self,
                    .callback = callback,
                    .record_size = record_size,
                    .id = .{ .op = header.op, .checksum = header.header_checksum },
                };
                self.appending = true;
                self.storage.write(&request.operation, onAppendWritten, self.file, record, self.offset, .durable);
            }

            fn onAppendWritten(operation: *Storage.Write) void {
                const request: *Append = @fieldParentPtr("operation", operation);
                const self = request.writer;
                assert(self.appending);
                self.appending = false;

                if (operation.result) |_| {
                    self.offset += request.record_size;
                    self.last = request.id;
                    request.result = request.id;
                } else |err| {
                    // The file's state is unknown from here on.
                    self.broken = true;
                    request.result = err;
                }
                request.callback(request);
            }

            /// Appends one record, gives it the next op, and makes it
            /// durable, blocking until that is done. Returns the new
            /// record's op and checksum. When this returns without an
            /// error, the record survives a crash.
            ///
            /// After any error other than `PayloadTooLarge` and `LogFull`
            /// the state of the file is unknown, and the writer must not be
            /// used again.
            pub fn append(self: *Writer, payload: []const u8) AppendError!RecordId {
                assert(!self.broken);
                if (payload.len > self.payloadSizeLimit()) {
                    return error.PayloadTooLarge;
                }
                if (!self.hasRoomFor(payload.len)) {
                    return error.LogFull;
                }

                var state: BlockingAppend = .{};
                self.appendStart(&state.request, BlockingAppend.onDone, payload);
                while (!state.done) {
                    self.storage.wait(blocking_wait_ns);
                }
                return state.request.result;
            }

            const BlockingAppend = struct {
                request: Append = .{},
                done: bool = false,

                fn onDone(request: *Append) void {
                    const state: *BlockingAppend = @fieldParentPtr("request", request);
                    state.done = true;
                }
            };
        };

        /// One append, from `Writer.appendStart` until its callback runs.
        /// Create one with `.{}`.
        pub const Append = struct {
            operation: Storage.Write = .{},
            writer: *Writer = undefined,
            callback: *const fn (request: *Append) void = undefined,
            /// How many bytes of the file the record takes.
            record_size: usize = undefined,
            /// The op and checksum the record will have.
            id: RecordId = undefined,

            /// Set when the callback runs: the record's op and checksum.
            result: Storage.WriteError!RecordId = undefined,
        };

        /// Reads the records of a log file in the order they were appended.
        pub const Reader = struct {
            storage: *Storage,
            file: Storage.File,
            /// Holds the record most recently returned. The caller owns it.
            buffer: []align(sector_size) u8,
            /// The length of the file, from its header.
            file_size: u64,
            /// Where in the file the next record starts.
            offset: u64,
            /// The last record returned, or the file header's previous
            /// record.
            last: RecordId,
            /// Set once the end of the log has been reached.
            done: bool,

            pub const Record = struct {
                op: u64,
                /// Valid until the next call to `next`.
                payload: []const u8,
            };

            pub const OpenError = error{
                /// The file is all zeros, of any length, or empty. A crash
                /// while the log was being created leaves this. Such a file
                /// holds no records, so it is safe to delete and create
                /// again.
                IncompleteLog,
                /// The file does not start with a valid log file header,
                /// and is not all zeros either. It may hold something.
                NotALog,
                /// The file's length is not the length its header gives.
                WrongFileSize,
            } || Storage.OpenError || Storage.SizeError || Storage.ReadError;

            pub const NextError = error{
                /// The log is damaged in a way a crash during an append
                /// cannot explain. See the top of this file. Also returned
                /// for a record that is longer than `buffer`.
                Corrupt,
            } || Storage.ReadError;

            /// Opens the log named `name`. `buffer` holds one record at a
            /// time, so it must be at least as long as the largest record
            /// in the file; see `bufferSize`.
            pub fn open(storage: *Storage, name: []const u8, buffer: []align(sector_size) u8) OpenError!Reader {
                assertBuffer(buffer);

                const file = try storage.openFile(name, .read_only, .{ .direct = true });
                errdefer storage.closeFile(file);

                const file_len = try storage.fileSize(file);

                const sector = buffer[0..sector_size];
                const header_read = try Blocking.readAll(storage, file, sector, 0);
                if (header_read < sector_size) {
                    // Too short to hold a header. Zeros are what a crash
                    // during `Writer.create` leaves. Anything else was put
                    // there by something other than this code, and is not
                    // taken for a file that is safe to delete.
                    const short_is_zeros = std.mem.allEqual(u8, sector[0..header_read], 0);
                    if (!short_is_zeros) {
                        return error.NotALog;
                    }
                    return error.IncompleteLog;
                }
                const header = FileHeader.fromBytes(sector[0..file_header_size]);
                if (header == null) {
                    // A file of nothing but zeros is what a crash during
                    // `Writer.create` leaves, and holds no records. A file
                    // with anything else in it might, and must not be
                    // taken for one that is safe to delete.
                    const header_is_zeros = std.mem.allEqual(u8, sector, 0);
                    if (!header_is_zeros) {
                        return error.NotALog;
                    }
                    const rest_is_zeros = try restIsZeros(storage, file, file_len, buffer);
                    if (!rest_is_zeros) {
                        return error.NotALog;
                    }
                    return error.IncompleteLog;
                }
                if (header.?.file_size != file_len) {
                    return error.WrongFileSize;
                }

                return .{
                    .storage = storage,
                    .file = file,
                    .buffer = buffer,
                    .file_size = file_len,
                    .offset = sector_size,
                    .last = header.?.previous(),
                    .done = false,
                };
            }

            pub fn close(self: *Reader) void {
                self.storage.closeFile(self.file);
                self.* = undefined;
            }

            /// Returns the next record, or `null` at the end of the log.
            pub fn next(self: *Reader) NextError!?Record {
                if (self.done) {
                    return null;
                }

                // No room for another record: the log is full.
                if (self.offset == self.file_size) {
                    self.done = true;
                    return null;
                }

                const sector = self.buffer[0..sector_size];
                const sector_read = try Blocking.readAll(self.storage, self.file, sector, self.offset);
                assert(sector_read == sector_size);
                const header = RecordHeader.fromBytes(sector[0..record_header_size]);

                if (!header.isValid()) {
                    // Zeros, or the remains of a torn append. This is the
                    // end, unless the log goes on beyond it.
                    return self.endOrCorrupt();
                }

                // The header is intact, so it was written by a writer. A
                // writer only ever appends the next record in the chain,
                // and only one that fits.
                if (self.last.op == std.math.maxInt(u64)) {
                    return error.Corrupt;
                }
                const continues_chain = header.previous_checksum == self.last.checksum and
                    header.op == self.last.op + 1;
                if (!continues_chain) {
                    return error.Corrupt;
                }
                const record_size = recordSize(header.payload_len);
                if (record_size > self.buffer.len) {
                    return error.Corrupt;
                }
                if (record_size > self.file_size - self.offset) {
                    return error.Corrupt;
                }

                // The rest of the record, if it is longer than a sector.
                if (record_size > sector_size) {
                    const rest = self.buffer[sector_size..record_size];
                    const rest_read = try Blocking.readAll(
                        self.storage,
                        self.file,
                        rest,
                        self.offset + sector_size,
                    );
                    assert(rest_read == rest.len);
                }

                const payload = self.buffer[record_header_size..][0..header.payload_len];
                if (header.payload_checksum != crc32c(payload)) {
                    // The header reached the disk and some of the payload
                    // did not: a torn append, unless the log goes on.
                    return self.endOrCorrupt();
                }

                self.offset += record_size;
                self.last = .{ .op = header.op, .checksum = header.header_checksum };
                return .{ .op = header.op, .payload = payload };
            }

            /// Called when the place the next record should be does not
            /// hold a whole one. Ends the log there, unless a later record
            /// shows that the log went further, which means a record that
            /// was durable has been damaged.
            fn endOrCorrupt(self: *Reader) NextError!?Record {
                // A record after the damaged one starts within one largest
                // record of it, on a sector boundary.
                const window_start = self.offset + sector_size;
                const window_len: usize = @intCast(@min(self.buffer.len, self.file_size - window_start));
                if (window_len > 0) {
                    const window = self.buffer[0..window_len];
                    const window_read = try Blocking.readAll(self.storage, self.file, window, window_start);
                    assert(window_read == window_len);

                    var position: usize = 0;
                    while (position < window_len) : (position += sector_size) {
                        const header = RecordHeader.fromBytes(window[position..][0..record_header_size]);
                        if (header.isValid() and header.op > self.last.op) {
                            return error.Corrupt;
                        }
                    }
                }
                self.done = true;
                return null;
            }

            /// Where the records returned so far end. Once `next` has
            /// returned `null`, this is where a `Writer` should resume.
            pub fn end(self: *const Reader) End {
                return .{ .offset = self.offset, .last = self.last };
            }
        };

        /// Whether every byte of the file after its first sector is zero.
        fn restIsZeros(
            storage: *Storage,
            file: Storage.File,
            file_len: u64,
            buffer: []align(sector_size) u8,
        ) Storage.ReadError!bool {
            var offset: u64 = sector_size;
            while (offset < file_len) {
                const bytes_read = try Blocking.readAll(storage, file, buffer, offset);
                if (bytes_read == 0) {
                    // The file is shorter than it was when it was opened.
                    return true;
                }
                if (!std.mem.allEqual(u8, buffer[0..bytes_read], 0)) {
                    return false;
                }
                offset += bytes_read;
            }
            return true;
        }
    };
}

const testing = std.testing;
const async_io = @import("async_io.zig");
const real_storage = @import("storage.zig");
const simulated_storage = @import("testing/storage.zig");

const Simulated = simulated_storage.Storage;
const SimulatedLog = LogType(Simulated);
const SimulatedBlocking = BlockingType(Simulated);

const test_name = "test.log";

/// Test records have payloads of up to three sectors, so a record is up to
/// four sectors long.
const test_payload_size_max = 3 * sector_size;
const test_buffer_size = bufferSize(test_payload_size_max);

/// Room for the file header and sixteen one-sector records.
const test_file_size = 17 * sector_size;

comptime {
    assert(test_file_size >= fileSizeMin(test_payload_size_max));
}

const TestBuffer = [test_buffer_size]u8;

/// A real Storage on a fresh directory. It holds pointers into itself, so
/// it is set up in place and must not be moved.
const RealFixture = struct {
    const Storage = real_storage.Storage;

    tmp: testing.TmpDir,
    io: async_io.AsyncIo,
    storage: real_storage.Storage,

    fn init(self: *RealFixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.io = try .init();
        self.storage = .init(&self.io, testing.io, self.tmp.dir);
    }

    fn deinit(self: *RealFixture) void {
        self.storage.deinit();
        self.io.deinit();
        self.tmp.cleanup();
    }
};

const SimulatedFixture = struct {
    const Storage = Simulated;

    storage: Simulated,

    fn init(self: *SimulatedFixture) !void {
        self.storage = .init(testing.allocator, .{ .seed = 11 });
    }

    fn deinit(self: *SimulatedFixture) void {
        self.storage.deinit();
    }
};

const fixtures = .{ RealFixture, SimulatedFixture };

/// Creates a brand-new log holding `payloads`.
fn writeLog(comptime Storage: type, storage: *Storage, payloads: []const []const u8) !void {
    const Log = LogType(Storage);
    var buffer: TestBuffer align(sector_size) = undefined;
    var writer: Log.Writer = try .create(storage, test_name, test_file_size, &buffer, .none);
    defer writer.close();
    for (payloads, 1..) |payload, op| {
        const id = try writer.append(payload);
        try testing.expectEqual(@as(u64, op), id.op);
    }
}

/// Reads the log and checks that it holds exactly `payloads`, with ops from
/// 1. Returns where the log ends.
fn expectLog(comptime Storage: type, storage: *Storage, payloads: []const []const u8) !End {
    const Log = LogType(Storage);
    var buffer: TestBuffer align(sector_size) = undefined;
    var reader: Log.Reader = try .open(storage, test_name, &buffer);
    defer reader.close();
    for (payloads, 1..) |payload, op| {
        const record = (try reader.next()).?;
        try testing.expectEqual(@as(u64, op), record.op);
        try testing.expectEqualSlices(u8, payload, record.payload);
    }
    try testing.expectEqual(null, try reader.next());
    // Asking again at the end keeps giving null.
    try testing.expectEqual(null, try reader.next());
    return reader.end();
}

/// Appends `payloads` after the log's valid records.
fn appendToLog(comptime Storage: type, storage: *Storage, end: End, payloads: []const []const u8) !void {
    const Log = LogType(Storage);
    var buffer: TestBuffer align(sector_size) = undefined;
    var writer: Log.Writer = try .open(storage, test_name, test_file_size, &buffer, end);
    defer writer.close();
    for (payloads) |payload| {
        _ = try writer.append(payload);
    }
}

test "record sizes are whole sectors" {
    try testing.expectEqual(@as(usize, sector_size), recordSize(0));
    try testing.expectEqual(@as(usize, sector_size), recordSize(1));
    const fills_one = sector_size - record_header_size;
    try testing.expectEqual(@as(usize, sector_size), recordSize(fills_one));
    try testing.expectEqual(@as(usize, 2 * sector_size), recordSize(fills_one + 1));
    try testing.expectEqual(@as(usize, 4 * sector_size), recordSize(test_payload_size_max));
}

test "an empty log holds no records" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();

        try writeLog(Fixture.Storage, &fixture.storage, &.{});
        const end = try expectLog(Fixture.Storage, &fixture.storage, &.{});
        try testing.expectEqual(@as(u64, sector_size), end.offset);
        try testing.expectEqual(RecordId.none, end.last);
        try testing.expectEqual(@as(u64, test_file_size), try fileLength(Fixture.Storage, &fixture.storage));
    }
}

fn fileLength(comptime Storage: type, storage: *Storage) !u64 {
    const file = try storage.openFile(test_name, .read_only, .{ .direct = false });
    defer storage.closeFile(file);
    return storage.fileSize(file);
}

test "records come back in order, whatever their length" {
    const fills_one: [sector_size - record_header_size]u8 = @splat('a');
    const one_more: [sector_size - record_header_size + 1]u8 = @splat('b');
    const largest: [test_payload_size_max]u8 = @splat('c');
    const payloads = [_][]const u8{ "first", "", "x", &fills_one, &one_more, &largest, "last" };

    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();

        try writeLog(Fixture.Storage, &fixture.storage, &payloads);
        const end = try expectLog(Fixture.Storage, &fixture.storage, &payloads);
        // Five one-sector records, one of two sectors and one of four,
        // after the header's sector.
        try testing.expectEqual(@as(u64, 12 * sector_size), end.offset);
        try testing.expectEqual(@as(u64, payloads.len), end.last.op);
    }
}

test "a log that is reopened carries on where it ended" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const Storage = Fixture.Storage;

        try writeLog(Storage, &fixture.storage, &.{ "one", "two" });
        const end = try expectLog(Storage, &fixture.storage, &.{ "one", "two" });
        try appendToLog(Storage, &fixture.storage, end, &.{ "three", "four" });
        const end_after = try expectLog(Storage, &fixture.storage, &.{ "one", "two", "three", "four" });
        try testing.expectEqual(@as(u64, 4), end_after.last.op);
    }
}

test "a log's first record follows the record the log was created after" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const Log = LogType(Fixture.Storage);

        const previous: RecordId = .{ .op = 41, .checksum = 0xabcd };
        var buffer: TestBuffer align(sector_size) = undefined;
        {
            var writer: Log.Writer = try .create(&fixture.storage, test_name, test_file_size, &buffer, previous);
            defer writer.close();
            const id = try writer.append("after forty-one");
            try testing.expectEqual(@as(u64, 42), id.op);
        }
        var reader: Log.Reader = try .open(&fixture.storage, test_name, &buffer);
        defer reader.close();
        try testing.expectEqual(previous, reader.end().last);
        const record = (try reader.next()).?;
        try testing.expectEqual(@as(u64, 42), record.op);
        try testing.expectEqualStrings("after forty-one", record.payload);
    }
}

test "a full log refuses a record and is otherwise unharmed" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const Storage = Fixture.Storage;
        const Log = LogType(Storage);

        var buffer: TestBuffer align(sector_size) = undefined;
        var writer: Log.Writer = try .create(&fixture.storage, test_name, test_file_size, &buffer, .none);
        // Fifteen one-sector records leave room for exactly one more.
        var count: u32 = 0;
        while (count < 15) : (count += 1) {
            _ = try writer.append("small");
        }
        try testing.expectEqual(@as(u64, sector_size), writer.roomLeft());
        try testing.expect(writer.hasRoomFor(sector_size - record_header_size));
        try testing.expect(!writer.hasRoomFor(sector_size - record_header_size + 1));

        const too_long: [sector_size]u8 = @splat('z');
        try testing.expectError(error.LogFull, writer.append(&too_long));
        // The refusal did not break the writer: a record that fits goes in.
        _ = try writer.append("the last one");
        try testing.expectEqual(@as(u64, 0), writer.roomLeft());
        try testing.expectError(error.LogFull, writer.append(""));
        writer.close();

        var reader: Log.Reader = try .open(&fixture.storage, test_name, &buffer);
        defer reader.close();
        var read: u32 = 0;
        while (try reader.next()) |_| {
            read += 1;
        }
        try testing.expectEqual(@as(u32, 16), read);
        try testing.expectEqual(@as(u64, test_file_size), reader.end().offset);
    }
}

test "a payload longer than the buffer holds is refused" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const Log = LogType(Fixture.Storage);

        var buffer: TestBuffer align(sector_size) = undefined;
        var writer: Log.Writer = try .create(&fixture.storage, test_name, test_file_size, &buffer, .none);
        defer writer.close();
        const limit = writer.payloadSizeLimit();
        try testing.expectEqual(@as(usize, test_buffer_size - record_header_size), limit);

        const too_long = try testing.allocator.alloc(u8, limit + 1);
        defer testing.allocator.free(too_long);
        @memset(too_long, 'q');
        try testing.expectError(error.PayloadTooLarge, writer.append(too_long));
        _ = try writer.append(too_long[0..limit]);
    }
}

test "creating a log that exists fails and leaves it alone" {
    inline for (fixtures) |Fixture| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const Storage = Fixture.Storage;
        const Log = LogType(Storage);

        try writeLog(Storage, &fixture.storage, &.{"kept"});
        var buffer: TestBuffer align(sector_size) = undefined;
        try testing.expectError(
            error.PathAlreadyExists,
            Log.Writer.create(&fixture.storage, test_name, test_file_size, &buffer, .none),
        );
        _ = try expectLog(Storage, &fixture.storage, &.{"kept"});
    }
}

// From here on the tests need to damage files or crash, so they run on the
// simulated storage only.

/// Opens the log and reads it to its end. Returns how many records it
/// holds, or the error that reading it gave.
fn countRecords(storage: *Simulated) !u32 {
    var buffer: TestBuffer align(sector_size) = undefined;
    var reader: SimulatedLog.Reader = try .open(storage, test_name, &buffer);
    defer reader.close();
    var count: u32 = 0;
    while (try reader.next()) |_| {
        count += 1;
    }
    return count;
}

/// Creates a file named like the log, holding `bytes`.
fn writeRawFile(storage: *Simulated, bytes: []const u8) !void {
    const file = try storage.createFile(test_name, .{ .direct = false });
    defer storage.closeFile(file);
    if (bytes.len > 0) {
        try SimulatedBlocking.writeAll(storage, file, bytes, 0, .durable);
    }
}

fn openError(storage: *Simulated) !void {
    var buffer: TestBuffer align(sector_size) = undefined;
    var reader: SimulatedLog.Reader = try .open(storage, test_name, &buffer);
    reader.close();
}

test "a file of zeros, or a short one, is an incomplete log" {
    const zeros: [test_file_size]u8 = @splat(0);
    const lengths = [_]usize{ 0, 1, sector_size - 1, sector_size, 5 * sector_size, test_file_size };
    for (lengths) |len| {
        var storage: Simulated = .init(testing.allocator, .{});
        defer storage.deinit();
        try writeRawFile(&storage, zeros[0..len]);
        try testing.expectError(error.IncompleteLog, openError(&storage));
    }
}

test "a file with a zero header that still holds something is not taken for incomplete" {
    // Deleting an incomplete log is safe. Deleting this one would throw
    // away a record, so it must be reported differently.
    var storage: Simulated = .init(testing.allocator, .{});
    defer storage.deinit();
    try writeLog(Simulated, &storage, &.{"a record that was durable"});

    const zeros: [sector_size]u8 = @splat(0);
    storage.setBytes(test_name, 0, &zeros);
    try testing.expectError(error.NotALog, openError(&storage));
}

test "a short file that holds something is not taken for incomplete" {
    const lengths = [_]usize{ 1, 200, sector_size - 1 };
    for (lengths) |len| {
        var storage: Simulated = .init(testing.allocator, .{});
        defer storage.deinit();
        var bytes: [sector_size]u8 = @splat(0);
        bytes[len - 1] = 1;
        try writeRawFile(&storage, bytes[0..len]);
        try testing.expectError(error.NotALog, openError(&storage));
    }
}

test "a file that does not start with a log header is not a log" {
    var storage: Simulated = .init(testing.allocator, .{});
    defer storage.deinit();
    try writeLog(Simulated, &storage, &.{});

    // One damaged byte anywhere in the header.
    var position: usize = 0;
    while (position < file_header_size) : (position += 1) {
        storage.corruptByte(test_name, position);
        try testing.expectError(error.NotALog, openError(&storage));
        storage.corruptByte(test_name, position);
    }
    try openError(&storage);
}

test "a log whose file is not the length its header gives is refused" {
    var storage: Simulated = .init(testing.allocator, .{});
    defer storage.deinit();
    try writeLog(Simulated, &storage, &.{"record"});

    // A sector more than the header says.
    const file = try storage.openFile(test_name, .read_write, .{ .direct = false });
    const extra: [sector_size]u8 = @splat(0);
    try SimulatedBlocking.writeAll(&storage, file, &extra, test_file_size, .durable);
    storage.closeFile(file);
    try testing.expectError(error.WrongFileSize, openError(&storage));
}

test "a torn final record ends the log, whichever of its sectors reached the disk" {
    // The last record is three sectors long. A crash while it was being
    // appended can leave any subset of the three on disk.
    const long: [2 * sector_size + 100]u8 = @splat('L');
    comptime assert(recordSize(long.len) == 3 * sector_size);
    const record_start = 2 * sector_size;

    var mask: u8 = 0;
    while (mask < 8) : (mask += 1) {
        var storage: Simulated = .init(testing.allocator, .{});
        defer storage.deinit();
        try writeLog(Simulated, &storage, &.{ "short", &long });

        // Put back zeros, which is what was there before the append, over
        // the sectors that did not make it.
        const zeros: [sector_size]u8 = @splat(0);
        for (0..3) |sector| {
            const landed = (mask >> @intCast(sector)) & 1 == 1;
            if (!landed) {
                storage.setBytes(test_name, record_start + sector * sector_size, &zeros);
            }
        }

        if (mask == 7) {
            _ = try expectLog(Simulated, &storage, &.{ "short", &long });
            continue;
        }
        const end = try expectLog(Simulated, &storage, &.{"short"});
        try testing.expectEqual(@as(u64, record_start), end.offset);

        // The log carries on from there, and what is left of the torn
        // record does not confuse a later read.
        try appendToLog(Simulated, &storage, end, &.{"after"});
        _ = try expectLog(Simulated, &storage, &.{ "short", "after" });
    }
}

test "a damaged record with a record after it is corruption" {
    const long: [sector_size + 10]u8 = @splat('M');
    const payloads = [_][]const u8{ "first", &long, "third" };
    // First record: sector 1. Second: sectors 2 and 3. Third: sector 4.
    const damage_offsets = [_]u64{
        // The first record's header, then its payload.
        sector_size + 2,
        sector_size + record_header_size + 1,
        // The second record's header, its payload in its first sector, and
        // its payload in its second sector.
        2 * sector_size + 9,
        2 * sector_size + record_header_size + 5,
        3 * sector_size + 3,
    };
    for (damage_offsets) |offset| {
        var storage: Simulated = .init(testing.allocator, .{});
        defer storage.deinit();
        try writeLog(Simulated, &storage, &payloads);
        storage.corruptByte(test_name, offset);
        try testing.expectError(error.Corrupt, countRecords(&storage));
    }
}

test "damage to the last record cannot be told from a torn append" {
    // This is the one case where a record that was durable is dropped
    // without an error. Nothing in a single log file can tell it from a
    // crash; a replica will be able to repair it from its peers.
    var storage: Simulated = .init(testing.allocator, .{});
    defer storage.deinit();
    try writeLog(Simulated, &storage, &.{ "first", "second" });
    storage.corruptByte(test_name, 2 * sector_size + record_header_size);
    _ = try expectLog(Simulated, &storage, &.{"first"});
}

/// Overwrites the sector at `offset` with a record header made of these
/// fields and a right checksum, and no payload.
fn writeForgedHeader(storage: *Simulated, offset: u64, previous_checksum: u32, op: u64, payload_len: u32) void {
    var header: RecordHeader = .{
        .header_checksum = 0,
        .previous_checksum = previous_checksum,
        .op = op,
        .payload_len = payload_len,
        .payload_checksum = crc32c(""),
    };
    header.header_checksum = header.expectedHeaderChecksum();
    var sector: [sector_size]u8 = @splat(0);
    @memcpy(sector[0..record_header_size], header.toBytes());
    storage.setBytes(test_name, offset, &sector);
}

test "a record that does not continue the chain is corruption" {
    var storage: Simulated = .init(testing.allocator, .{});
    defer storage.deinit();
    try writeLog(Simulated, &storage, &.{"first"});
    const end = try expectLog(Simulated, &storage, &.{"first"});

    // The right previous checksum, the wrong op.
    writeForgedHeader(&storage, end.offset, end.last.checksum, end.last.op + 2, 0);
    try testing.expectError(error.Corrupt, countRecords(&storage));

    // The right op, the wrong previous checksum.
    writeForgedHeader(&storage, end.offset, end.last.checksum +% 1, end.last.op + 1, 0);
    try testing.expectError(error.Corrupt, countRecords(&storage));

    // Both right: this is simply the next record.
    writeForgedHeader(&storage, end.offset, end.last.checksum, end.last.op + 1, 0);
    try testing.expectEqual(@as(u32, 2), try countRecords(&storage));
}

test "a record whose length cannot be is corruption" {
    var storage: Simulated = .init(testing.allocator, .{});
    defer storage.deinit();
    try writeLog(Simulated, &storage, &.{"first"});
    const end = try expectLog(Simulated, &storage, &.{"first"});

    // Longer than the reader's buffer.
    const too_long = test_buffer_size - record_header_size + 1;
    writeForgedHeader(&storage, end.offset, end.last.checksum, end.last.op + 1, too_long);
    try testing.expectError(error.Corrupt, countRecords(&storage));
}

test "a record that would run past the end of the file is corruption" {
    var storage: Simulated = .init(testing.allocator, .{});
    defer storage.deinit();

    var buffer: TestBuffer align(sector_size) = undefined;
    var writer: SimulatedLog.Writer = try .create(&storage, test_name, test_file_size, &buffer, .none);
    var count: u32 = 0;
    while (count < 15) : (count += 1) {
        _ = try writer.append("small");
    }
    const last = writer.last;
    const offset = writer.offset;
    writer.close();

    // One sector is left, and this record claims two.
    writeForgedHeader(&storage, offset, last.checksum, last.op + 1, sector_size);
    try testing.expectError(error.Corrupt, countRecords(&storage));
}

test "a later record beyond a gap of zeros is corruption" {
    // Zeros where a record should be, and a valid later record after them:
    // a durable record has been wiped out.
    var storage: Simulated = .init(testing.allocator, .{});
    defer storage.deinit();
    try writeLog(Simulated, &storage, &.{ "first", "second", "third" });
    const zeros: [sector_size]u8 = @splat(0);
    storage.setBytes(test_name, 2 * sector_size, &zeros);
    try testing.expectError(error.Corrupt, countRecords(&storage));
}

test "no acknowledged record is lost, whenever the crash comes" {
    // A writer appends records until a crash stops it. Whatever the crash
    // did, a restart must find every record whose append had returned, in
    // order, and at most the one that was in flight besides.
    const two_sectors: [sector_size + 500]u8 = @splat('2');
    const three_sectors: [2 * sector_size + 500]u8 = @splat('3');
    const payloads = [_][]const u8{ "one", &two_sectors, "three", &three_sectors, "five", "six" };
    const kinds = [_]simulated_storage.CrashKind{ .power_loss, .process_kill };

    var seed: u64 = 0;
    while (seed < 30) : (seed += 1) {
        for (kinds) |kind| {
            // Creating the log takes several operations; the crash is put
            // after it, at each operation of the appends in turn.
            var crash_after: u64 = 1;
            while (crash_after <= payloads.len) : (crash_after += 1) {
                var storage: Simulated = .init(testing.allocator, .{ .seed = seed });
                defer storage.deinit();

                var buffer: TestBuffer align(sector_size) = undefined;
                var writer: SimulatedLog.Writer = try .create(&storage, test_name, test_file_size, &buffer, .none);
                storage.crashAfterOperations(crash_after, kind);
                var acknowledged: u32 = 0;
                for (payloads) |payload| {
                    _ = writer.append(payload) catch break;
                    acknowledged += 1;
                }
                writer.close();
                try testing.expectEqual(@as(u32, @intCast(crash_after - 1)), acknowledged);
                storage.restart();

                const found = try countRecords(&storage);
                try testing.expect(found >= acknowledged);
                try testing.expect(found <= acknowledged + 1);
                const end = try expectLog(Simulated, &storage, payloads[0..found]);

                // The store would now treat what it found as the log, so
                // it has to stay: opening the writer makes it durable, and
                // a power loss straight after changes nothing.
                var resumed: SimulatedLog.Writer = try .open(&storage, test_name, test_file_size, &buffer, end);
                resumed.close();
                storage.crash(.power_loss);
                storage.restart();
                _ = try expectLog(Simulated, &storage, payloads[0..found]);
            }
        }
    }
}

test "a crash while a log is being created leaves nothing that looks like a log with records" {
    const kinds = [_]simulated_storage.CrashKind{ .power_loss, .process_kill };
    var seed: u64 = 0;
    while (seed < 20) : (seed += 1) {
        for (kinds) |kind| {
            var crash_after: u64 = 1;
            while (true) : (crash_after += 1) {
                var storage: Simulated = .init(testing.allocator, .{ .seed = seed });
                defer storage.deinit();

                storage.crashAfterOperations(crash_after, kind);
                var buffer: TestBuffer align(sector_size) = undefined;
                var created = SimulatedLog.Writer.create(&storage, test_name, test_file_size, &buffer, .none);
                if (created) |*writer| {
                    // The crash was planned for after the last operation
                    // of the create: every crash point has been tried.
                    writer.close();
                    break;
                } else |err| {
                    try testing.expectEqual(error.InputOutput, err);
                }
                storage.restart();

                // The file is gone, or incomplete, or a complete empty log.
                const count = countRecords(&storage) catch |err| {
                    switch (err) {
                        error.FileNotFound, error.IncompleteLog => continue,
                        else => return err,
                    }
                };
                try testing.expectEqual(@as(u32, 0), count);
            }
        }
    }
}

test "the remains of a torn append cannot be completed by a later one" {
    // Two different records with the same tail. The first is torn so that
    // only its first sector lands. After a restart the second is appended
    // in the same place, and torn so that only its tail lands. Together the
    // two halves would make the first record whole.
    const tail: [2 * sector_size]u8 = @splat('t');
    var first_payload: [tail.len + 8]u8 = undefined;
    var second_payload: [tail.len + 8]u8 = undefined;
    @memcpy(first_payload[0..8], "first---");
    @memcpy(first_payload[8..], &tail);
    @memcpy(second_payload[0..8], "second--");
    @memcpy(second_payload[8..], &tail);
    comptime assert(recordSize(first_payload.len) == 3 * sector_size);
    const record_offset = 2 * sector_size;
    const zeros: [sector_size]u8 = @splat(0);

    var storage: Simulated = .init(testing.allocator, .{});
    defer storage.deinit();

    // The whole second record, as it would be on disk, taken from a log
    // where it was appended after the same first record.
    var second_record: [3 * sector_size]u8 = undefined;
    {
        try writeLog(Simulated, &storage, &.{ "short", &second_payload });
        @memcpy(&second_record, storage.contents(test_name)[record_offset..][0..second_record.len]);
        try storage.deleteFile(test_name);
    }

    // The first record, torn: only its first sector landed.
    try writeLog(Simulated, &storage, &.{ "short", &first_payload });
    storage.setBytes(test_name, record_offset + sector_size, &zeros);
    storage.setBytes(test_name, record_offset + 2 * sector_size, &zeros);
    const end = try expectLog(Simulated, &storage, &.{"short"});
    try testing.expectEqual(@as(u64, record_offset), end.offset);

    // The restart opens the log for writing.
    var buffer: TestBuffer align(sector_size) = undefined;
    var writer: SimulatedLog.Writer = try .open(&storage, test_name, test_file_size, &buffer, end);
    writer.close();

    // The second record, torn the other way: only its last two sectors
    // landed.
    storage.setBytes(test_name, record_offset + sector_size, second_record[sector_size..]);

    // Neither record was ever whole, so neither is in the log.
    _ = try expectLog(Simulated, &storage, &.{"short"});
}
