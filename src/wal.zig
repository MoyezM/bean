//! The write-ahead log: an append-only file of checksummed records.
//!
//! The log does not interpret what it stores. A record's payload is opaque
//! bytes, and the layer above decides what they mean.
//!
//! File layout, with all integers little-endian:
//!
//!     file header:    magic (8 bytes)
//!                     previous op (u64)
//!                     previous checksum (u32)
//!                     header checksum (u32)
//!     record header:  header checksum (u32)
//!                     previous checksum (u32)
//!                     op (u64)
//!                     payload length (u32)
//!                     payload checksum (u32)
//!     payload
//!     record header, payload, ...
//!
//! Records are numbered and chained, so that the log can later be replicated:
//!
//! - Each record has an operation number, `op`, one more than the record
//!   before it.
//! - Each record stores the header checksum of the record before it.
//! - The file header stores the op and checksum of the record that came
//!   before this file's first record, so the chain carries on from one log
//!   file to the next. Both are zero for a brand-new log, whose first record
//!   has op 1.
//!
//! Checksums are CRC-32C. A record has two:
//!
//! - The header checksum covers the rest of the record header, which
//!   includes the payload checksum. It is checked before the payload length
//!   is used, and it identifies the record in the chain.
//! - The payload checksum covers the payload.
//!
//! The file header's checksum covers the rest of the file header.
//!
//! Recovery policy. The log ends, without an error, at the first of:
//!
//! - the end of the file, or too few bytes left to hold a record header,
//! - a record header that is all zeros,
//! - a record header that fails its checksum and is the last thing in the
//!   file,
//! - a record with a valid header whose payload runs past the end of the
//!   file, or
//! - a record with a valid header whose payload fails its checksum and ends
//!   exactly at the end of the file.
//!
//! Those are the states a crash during an append can leave. Anything else
//! that is wrong is reported as corruption: a damaged header or payload with
//! more data after it, or a record with a valid header that does not
//! continue the chain. When in doubt the reader fails, so that it never
//! silently drops a record that was reported as durable.
//!
//! Writing and reading are separate types. On startup a `Reader` replays the
//! file and reports where its valid records end; a `Writer` then resumes from
//! that point.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const file_header_size = 24;
pub const record_header_size = 24;

const magic = "beanwal1";

/// Identifies one record in the chain.
pub const RecordId = struct {
    op: u64,
    /// The record's header checksum.
    checksum: u32,

    /// What a brand-new log continues from: no record at all.
    pub const none: RecordId = .{ .op = 0, .checksum = 0 };
};

/// Where the valid records of a log file end.
pub const End = struct {
    /// The length in bytes of the file header plus every valid record.
    valid_len: u64,
    /// The last valid record, or the file header's previous record if the
    /// file holds no records.
    last: RecordId,
};

const FileHeader = struct {
    previous: RecordId,

    fn encode(header: FileHeader) [file_header_size]u8 {
        var bytes: [file_header_size]u8 = undefined;
        @memcpy(bytes[0..8], magic);
        std.mem.writeInt(u64, bytes[8..16], header.previous.op, .little);
        std.mem.writeInt(u32, bytes[16..20], header.previous.checksum, .little);
        std.mem.writeInt(u32, bytes[20..24], Crc32c.hash(bytes[0..20]), .little);
        return bytes;
    }

    /// Returns `null` if `bytes` is not a valid file header.
    fn decode(bytes: *const [file_header_size]u8) ?FileHeader {
        if (!std.mem.eql(u8, bytes[0..8], magic)) {
            return null;
        }
        const checksum = std.mem.readInt(u32, bytes[20..24], .little);
        if (checksum != Crc32c.hash(bytes[0..20])) {
            return null;
        }
        return .{
            .previous = .{
                .op = std.mem.readInt(u64, bytes[8..16], .little),
                .checksum = std.mem.readInt(u32, bytes[16..20], .little),
            },
        };
    }
};

const RecordHeader = struct {
    header_checksum: u32,
    previous_checksum: u32,
    op: u64,
    payload_len: u32,
    payload_checksum: u32,

    fn encode(header: RecordHeader) [record_header_size]u8 {
        var bytes: [record_header_size]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], header.header_checksum, .little);
        std.mem.writeInt(u32, bytes[4..8], header.previous_checksum, .little);
        std.mem.writeInt(u64, bytes[8..16], header.op, .little);
        std.mem.writeInt(u32, bytes[16..20], header.payload_len, .little);
        std.mem.writeInt(u32, bytes[20..24], header.payload_checksum, .little);
        return bytes;
    }

    fn decode(bytes: *const [record_header_size]u8) RecordHeader {
        return .{
            .header_checksum = std.mem.readInt(u32, bytes[0..4], .little),
            .previous_checksum = std.mem.readInt(u32, bytes[4..8], .little),
            .op = std.mem.readInt(u64, bytes[8..16], .little),
            .payload_len = std.mem.readInt(u32, bytes[16..20], .little),
            .payload_checksum = std.mem.readInt(u32, bytes[20..24], .little),
        };
    }

    /// The header checksum these fields must carry. It covers every field
    /// except `header_checksum` itself.
    fn expectedHeaderChecksum(header: RecordHeader) u32 {
        const bytes = header.encode();
        return Crc32c.hash(bytes[4..]);
    }
};

/// Syncs a directory, so that a file just created in it survives a crash.
fn syncDir(io: Io, dir: Io.Dir) Io.File.SyncError!void {
    const dir_as_file: Io.File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    try dir_as_file.sync(io);
}

/// Appends records to a log file. A record is durable once `append` returns.
pub const Writer = struct {
    io: Io,
    file: Io.File,
    payload_size_max: u32,
    /// Where in the file the next record will be written.
    offset: u64,
    /// The last record in the log. The next record chains from it.
    last: RecordId,
    /// Set when a write or sync has failed and the file's state is unknown.
    broken: bool,

    pub const CreateError = Io.File.OpenError || Io.File.WritePositionalError || Io.File.SyncError;

    pub const OpenError = Io.File.OpenError || Io.File.SetLengthError || Io.File.SyncError;

    pub const AppendError = error{
        /// The payload is longer than the `payload_size_max` given at creation.
        PayloadTooLarge,
    } || Io.File.WritePositionalError || Io.File.SyncError;

    /// Creates a new, empty log named `name` in `dir`, and syncs it. Fails if
    /// the file already exists.
    ///
    /// `previous` is the record this log continues from: the last record of
    /// the log file before it, or `RecordId.none` for a brand-new log.
    pub fn create(
        io: Io,
        dir: Io.Dir,
        name: []const u8,
        payload_size_max: u32,
        previous: RecordId,
    ) CreateError!Writer {
        const file = try dir.createFile(io, name, .{ .exclusive = true });
        errdefer file.close(io);

        const header: FileHeader = .{ .previous = previous };
        const header_bytes = header.encode();
        try file.writePositionalAll(io, &header_bytes, 0);
        try file.sync(io);
        try syncDir(io, dir);

        return .{
            .io = io,
            .file = file,
            .payload_size_max = payload_size_max,
            .offset = file_header_size,
            .last = previous,
            .broken = false,
        };
    }

    /// Opens an existing log to append after its valid records, and discards
    /// anything beyond them. `end` must come from `Reader.end` after that
    /// reader reached the end of the same file.
    pub fn open(
        io: Io,
        dir: Io.Dir,
        name: []const u8,
        payload_size_max: u32,
        end: End,
    ) OpenError!Writer {
        assert(end.valid_len >= file_header_size);

        const file = try dir.openFile(io, name, .{ .mode = .write_only });
        errdefer file.close(io);

        // Remove a damaged final record, if there is one, so that it can
        // never be mistaken for part of the log later.
        try file.setLength(io, end.valid_len);
        try file.sync(io);

        return .{
            .io = io,
            .file = file,
            .payload_size_max = payload_size_max,
            .offset = end.valid_len,
            .last = end.last,
            .broken = false,
        };
    }

    pub fn close(self: *Writer) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// Appends one record, gives it the next op, and syncs the file. Returns
    /// the new record's op and checksum. When this returns without an error,
    /// the record survives a crash.
    ///
    /// After any error other than `PayloadTooLarge` the state of the file is
    /// unknown, and the writer must not be used again.
    pub fn append(self: *Writer, payload: []const u8) AppendError!RecordId {
        assert(!self.broken);
        if (payload.len > self.payload_size_max) {
            return error.PayloadTooLarge;
        }

        var header: RecordHeader = .{
            .header_checksum = 0,
            .previous_checksum = self.last.checksum,
            .op = self.last.op + 1,
            .payload_len = @intCast(payload.len),
            .payload_checksum = Crc32c.hash(payload),
        };
        header.header_checksum = header.expectedHeaderChecksum();
        const header_bytes = header.encode();

        // From here on, a failure leaves the file in an unknown state.
        errdefer self.broken = true;

        const payload_offset = self.offset + record_header_size;
        try self.file.writePositionalAll(self.io, &header_bytes, self.offset);
        try self.file.writePositionalAll(self.io, payload, payload_offset);

        // TODO: On macOS, `Io.File.sync` calls `fsync`, which does not make
        // the drive flush its write cache, so a record can be lost on power
        // failure. Use `fcntl` with `F_FULLFSYNC` there. Until then, use
        // `Io.File.sync` on every platform.
        try self.file.sync(self.io);

        self.offset = payload_offset + payload.len;
        self.last = .{ .op = header.op, .checksum = header.header_checksum };
        return self.last;
    }
};

/// Reads the records of a log file in the order they were appended.
pub const Reader = struct {
    io: Io,
    file: Io.File,
    /// Holds the payload of the record most recently returned.
    buffer: []u8,
    /// The length of the file when it was opened.
    file_len: u64,
    /// Where in the file the next record starts.
    offset: u64,
    /// The last record returned, or the file header's previous record.
    last: RecordId,
    /// Set once the end of the log has been reached.
    done: bool,

    pub const Record = struct {
        op: u64,
        /// Valid until the next call to `next`.
        payload: []const u8,
    };

    pub const OpenError = error{
        /// The file does not start with a valid log file header.
        NotALog,
    } || Io.File.OpenError || Io.File.LengthError || Io.File.ReadPositionalError;

    pub const NextError = error{
        /// The log is damaged in a way a crash during an append cannot
        /// explain. See the recovery policy at the top of this file. Also
        /// returned for a record that is longer than `buffer`.
        Corrupt,
    } || Io.File.ReadPositionalError;

    /// Opens the log named `name` in `dir`. `buffer` holds one payload at a
    /// time, so it must be at least as long as the largest payload in the
    /// file.
    pub fn open(io: Io, dir: Io.Dir, name: []const u8, buffer: []u8) OpenError!Reader {
        const file = try dir.openFile(io, name, .{ .mode = .read_only });
        errdefer file.close(io);

        const file_len = try file.length(io);

        var header_bytes: [file_header_size]u8 = undefined;
        const header_read = try file.readPositionalAll(io, &header_bytes, 0);
        if (header_read < file_header_size) {
            return error.NotALog;
        }
        const header = FileHeader.decode(&header_bytes);
        if (header == null) {
            return error.NotALog;
        }

        return .{
            .io = io,
            .file = file,
            .buffer = buffer,
            .file_len = file_len,
            .offset = file_header_size,
            .last = header.?.previous,
            .done = false,
        };
    }

    pub fn close(self: *Reader) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// Returns the next record, or `null` at the end of the log.
    ///
    /// A damaged final record is what a crash during `Writer.append` leaves
    /// behind. It was never reported as durable, so it is treated as the end
    /// of the log. This cannot tell a torn write apart from later corruption
    /// of a final record that was durable; a replica will be able to repair
    /// that case from its peers.
    pub fn next(self: *Reader) NextError!?Record {
        if (self.done) {
            return null;
        }

        // The end of the file, or too few bytes left to hold a header.
        const bytes_left = self.file_len - self.offset;
        if (bytes_left < record_header_size) {
            self.done = true;
            return null;
        }

        var header_bytes: [record_header_size]u8 = undefined;
        const header_read = try self.file.readPositionalAll(self.io, &header_bytes, self.offset);
        if (header_read < record_header_size) {
            self.done = true;
            return null;
        }

        // Zeros are what unwritten space in a file reads as.
        if (std.mem.allEqual(u8, &header_bytes, 0)) {
            self.done = true;
            return null;
        }

        const header = RecordHeader.decode(&header_bytes);
        const payload_offset = self.offset + record_header_size;

        // Nothing in the header can be trusted until its checksum is checked.
        if (header.header_checksum != header.expectedHeaderChecksum()) {
            const header_is_last_in_file = payload_offset == self.file_len;
            if (header_is_last_in_file) {
                self.done = true;
                return null;
            }
            return error.Corrupt;
        }

        // The header is intact, so it was written by a writer. A writer only
        // ever appends the next record in the chain.
        const continues_chain = header.previous_checksum == self.last.checksum and
            header.op == self.last.op + 1;
        if (!continues_chain) {
            return error.Corrupt;
        }

        // The payload was cut short.
        const record_end = payload_offset + header.payload_len;
        if (record_end > self.file_len) {
            self.done = true;
            return null;
        }

        if (header.payload_len > self.buffer.len) {
            return error.Corrupt;
        }
        const payload = self.buffer[0..header.payload_len];
        const payload_read = try self.file.readPositionalAll(self.io, payload, payload_offset);
        if (payload_read < payload.len) {
            self.done = true;
            return null;
        }

        if (header.payload_checksum != Crc32c.hash(payload)) {
            const record_is_last_in_file = record_end == self.file_len;
            if (record_is_last_in_file) {
                self.done = true;
                return null;
            }
            return error.Corrupt;
        }

        self.offset = record_end;
        self.last = .{ .op = header.op, .checksum = header.header_checksum };
        return .{ .op = header.op, .payload = payload };
    }

    /// Where the records returned so far end. Once `next` has returned
    /// `null`, this is where a `Writer` should resume.
    pub fn end(self: *const Reader) End {
        return .{ .valid_len = self.offset, .last = self.last };
    }
};

const testing = std.testing;
const test_name = "test.wal";
const test_payload_size_max = 1024;

/// Creates a brand-new log holding `payloads`.
fn writeLog(dir: Io.Dir, payloads: []const []const u8) !void {
    var writer: Writer = try .create(testing.io, dir, test_name, test_payload_size_max, .none);
    defer writer.close();
    for (payloads) |payload| {
        _ = try writer.append(payload);
    }
}

/// Reads the log to its end, checks that it holds exactly `payloads` with
/// ops counting up from 1, and returns where it ends.
fn expectLog(dir: Io.Dir, payloads: []const []const u8) !End {
    var buffer: [test_payload_size_max]u8 = undefined;
    var reader: Reader = try .open(testing.io, dir, test_name, &buffer);
    defer reader.close();

    for (payloads, 1..) |payload, op| {
        const record = try reader.next();
        try testing.expect(record != null);
        try testing.expectEqual(@as(u64, op), record.?.op);
        try testing.expectEqualSlices(u8, payload, record.?.payload);
    }
    try testing.expect(try reader.next() == null);
    try testing.expect(try reader.next() == null);
    return reader.end();
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

/// Inverts the bits of one byte of the file.
fn flipByte(dir: Io.Dir, offset: u64) !void {
    const file = try dir.openFile(testing.io, test_name, .{ .mode = .read_write });
    defer file.close(testing.io);
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try file.readPositionalAll(testing.io, &byte, offset));
    byte[0] = ~byte[0];
    try file.writePositionalAll(testing.io, &byte, offset);
}

test "an empty log has no records" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{});

    const end = try expectLog(tmp.dir, &.{});
    try testing.expectEqual(@as(u64, file_header_size), end.valid_len);
    try testing.expectEqual(RecordId.none, end.last);
}

test "records are read back in order with consecutive ops" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "first", "second", "third" });

    const end = try expectLog(tmp.dir, &.{ "first", "second", "third" });
    try testing.expectEqual(try fileLength(tmp.dir), end.valid_len);
    try testing.expectEqual(@as(u64, 3), end.last.op);
}

test "append returns the op and checksum of the new record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer: Writer = try .create(testing.io, tmp.dir, test_name, test_payload_size_max, .none);
    const first = try writer.append("first");
    const second = try writer.append("second");
    writer.close();

    try testing.expectEqual(@as(u64, 1), first.op);
    try testing.expectEqual(@as(u64, 2), second.op);

    const end = try expectLog(tmp.dir, &.{ "first", "second" });
    try testing.expectEqual(second, end.last);
}

test "an empty payload is a record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "", "after", "" });

    _ = try expectLog(tmp.dir, &.{ "", "after", "" });
}

test "create fails if the file exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{"kept"});

    const result = Writer.create(testing.io, tmp.dir, test_name, test_payload_size_max, .none);
    try testing.expectError(error.PathAlreadyExists, result);
    _ = try expectLog(tmp.dir, &.{"kept"});
}

test "a payload over the limit is rejected and the writer stays usable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer: Writer = try .create(testing.io, tmp.dir, test_name, 4, .none);
    _ = try writer.append("1234");
    try testing.expectError(error.PayloadTooLarge, writer.append("12345"));
    _ = try writer.append("ok");
    writer.close();

    _ = try expectLog(tmp.dir, &.{ "1234", "ok" });
}

test "a writer resumes after the last record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "first", "second" });
    const end = try expectLog(tmp.dir, &.{ "first", "second" });

    var writer: Writer = try .open(testing.io, tmp.dir, test_name, test_payload_size_max, end);
    const third = try writer.append("third");
    writer.close();

    try testing.expectEqual(@as(u64, 3), third.op);
    _ = try expectLog(tmp.dir, &.{ "first", "second", "third" });
}

test "a log continues the chain of the log before it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const previous: RecordId = .{ .op = 41, .checksum = 0xabcd1234 };
    var writer: Writer = try .create(testing.io, tmp.dir, test_name, test_payload_size_max, previous);
    const first = try writer.append("first");
    writer.close();
    try testing.expectEqual(@as(u64, 42), first.op);

    var buffer: [test_payload_size_max]u8 = undefined;
    var reader: Reader = try .open(testing.io, tmp.dir, test_name, &buffer);
    defer reader.close();
    try testing.expectEqual(previous, reader.end().last);
    const record = try reader.next();
    try testing.expectEqual(@as(u64, 42), record.?.op);
    try testing.expect(try reader.next() == null);
    try testing.expectEqual(first, reader.end().last);
}

test "a final record cut short at any point ends the log" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "first", "second" });
    const len_before = try fileLength(tmp.dir);
    {
        const end = try expectLog(tmp.dir, &.{ "first", "second" });
        var writer: Writer = try .open(testing.io, tmp.dir, test_name, test_payload_size_max, end);
        _ = try writer.append("third");
        writer.close();
    }
    const len_after = try fileLength(tmp.dir);

    // Remove one more byte of the third record each time round.
    var len = len_after - 1;
    while (len >= len_before) {
        try setFileLength(tmp.dir, len);
        const end = try expectLog(tmp.dir, &.{ "first", "second" });
        try testing.expectEqual(len_before, end.valid_len);
        len -= 1;
    }
}

test "a writer overwrites a record that was cut short" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "first", "second", "torn" });
    try setFileLength(tmp.dir, try fileLength(tmp.dir) - 2);
    const end = try expectLog(tmp.dir, &.{ "first", "second" });

    var writer: Writer = try .open(testing.io, tmp.dir, test_name, test_payload_size_max, end);
    const third = try writer.append("third");
    writer.close();

    try testing.expectEqual(@as(u64, 3), third.op);
    _ = try expectLog(tmp.dir, &.{ "first", "second", "third" });
}

test "a final record whose payload fails its checksum ends the log" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "first", "second", "third" });
    try flipByte(tmp.dir, try fileLength(tmp.dir) - 1);

    _ = try expectLog(tmp.dir, &.{ "first", "second" });
}

test "an earlier record whose payload fails its checksum is corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "first", "second", "third" });
    // The last byte of the first record's payload.
    try flipByte(tmp.dir, file_header_size + record_header_size + "first".len - 1);

    var buffer: [test_payload_size_max]u8 = undefined;
    var reader: Reader = try .open(testing.io, tmp.dir, test_name, &buffer);
    defer reader.close();
    try testing.expectError(error.Corrupt, reader.next());
}

test "damage to any byte of an earlier record is corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "first", "second" });
    const first_record_len = record_header_size + "first".len;

    for (0..first_record_len) |index| {
        const offset = file_header_size + index;
        try flipByte(tmp.dir, offset);

        var buffer: [test_payload_size_max]u8 = undefined;
        var reader: Reader = try .open(testing.io, tmp.dir, test_name, &buffer);
        try testing.expectError(error.Corrupt, reader.next());
        reader.close();

        try flipByte(tmp.dir, offset);
    }
    _ = try expectLog(tmp.dir, &.{ "first", "second" });
}

test "a final record with a damaged header and a payload after it is corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "first", "second", "third" });
    const third_record_len = record_header_size + "third".len;
    const third_record_offset = try fileLength(tmp.dir) - third_record_len;

    for (0..record_header_size) |index| {
        const offset = third_record_offset + index;
        try flipByte(tmp.dir, offset);

        var buffer: [test_payload_size_max]u8 = undefined;
        var reader: Reader = try .open(testing.io, tmp.dir, test_name, &buffer);
        _ = try reader.next();
        _ = try reader.next();
        try testing.expectError(error.Corrupt, reader.next());
        reader.close();

        try flipByte(tmp.dir, offset);
    }
    _ = try expectLog(tmp.dir, &.{ "first", "second", "third" });
}

test "a damaged header that is the last thing in the file ends the log" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The third record has no payload, so its header ends the file.
    try writeLog(tmp.dir, &.{ "first", "second", "" });
    const len = try fileLength(tmp.dir);

    for (0..record_header_size) |index| {
        const offset = len - record_header_size + index;
        try flipByte(tmp.dir, offset);
        const end = try expectLog(tmp.dir, &.{ "first", "second" });
        try testing.expectEqual(len - record_header_size, end.valid_len);
        try flipByte(tmp.dir, offset);
    }
    _ = try expectLog(tmp.dir, &.{ "first", "second", "" });
}

test "a record that does not continue the chain is corrupt" {
    // One record, so that the broken link is on the final record, and two,
    // so that it is on an earlier one. Both must be reported.
    const logs = [_][]const []const u8{
        &.{"only"},
        &.{ "first", "second" },
    };
    for (logs) |payloads| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeLog(tmp.dir, payloads);

        // Rewrite the file header so that it names a different previous
        // record. Its own checksum is valid, but the first record no longer
        // follows it.
        const header: FileHeader = .{ .previous = .{ .op = 7, .checksum = 99 } };
        const header_bytes = header.encode();
        const file = try tmp.dir.openFile(testing.io, test_name, .{ .mode = .write_only });
        try file.writePositionalAll(testing.io, &header_bytes, 0);
        file.close(testing.io);

        var buffer: [test_payload_size_max]u8 = undefined;
        var reader: Reader = try .open(testing.io, tmp.dir, test_name, &buffer);
        defer reader.close();
        try testing.expectError(error.Corrupt, reader.next());
    }
}

test "zeros after the last record end the log" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "first", "second" });
    const len = try fileLength(tmp.dir);
    try setFileLength(tmp.dir, len + 4096);

    const end = try expectLog(tmp.dir, &.{ "first", "second" });
    try testing.expectEqual(len, end.valid_len);
}

test "a record longer than the buffer is corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLog(tmp.dir, &.{ "first", "a longer second record" });

    var buffer: [8]u8 = undefined;
    var reader: Reader = try .open(testing.io, tmp.dir, test_name, &buffer);
    defer reader.close();
    const first = try reader.next();
    try testing.expectEqualSlices(u8, "first", first.?.payload);
    try testing.expectError(error.Corrupt, reader.next());
}

test "a file that is not a log is rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [test_payload_size_max]u8 = undefined;

    // Too short to hold a file header.
    {
        const file = try tmp.dir.createFile(testing.io, test_name, .{});
        try file.writePositionalAll(testing.io, "short", 0);
        file.close(testing.io);
        const result = Reader.open(testing.io, tmp.dir, test_name, &buffer);
        try testing.expectError(error.NotALog, result);
    }

    // Long enough, but with the wrong magic bytes.
    {
        const file = try tmp.dir.createFile(testing.io, test_name, .{});
        const junk: [64]u8 = @splat('x');
        try file.writePositionalAll(testing.io, &junk, 0);
        file.close(testing.io);
        const result = Reader.open(testing.io, tmp.dir, test_name, &buffer);
        try testing.expectError(error.NotALog, result);
    }
}

test "a damaged file header is rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [test_payload_size_max]u8 = undefined;

    try writeLog(tmp.dir, &.{"first"});
    for (0..file_header_size) |offset| {
        try flipByte(tmp.dir, offset);
        const result = Reader.open(testing.io, tmp.dir, test_name, &buffer);
        try testing.expectError(error.NotALog, result);
        try flipByte(tmp.dir, offset);
    }
    _ = try expectLog(tmp.dir, &.{"first"});
}
