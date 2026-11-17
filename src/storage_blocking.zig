//! Blocking calls on top of a Storage, for the parts of the store that have
//! not been made asynchronous yet.
//!
//! Each call starts one operation and runs the storage's event loop until
//! that operation's callback has run. Other operations that end meanwhile
//! have their callbacks run too.

const std = @import("std");
const assert = std.debug.assert;

/// How long one turn of the event loop may block while a call waits for
/// its operation. The loop returns as soon as any operation ends, so this
/// only bounds how long a turn with nothing to report can take.
const wait_ns = 100 * std.time.ns_per_ms;

pub fn BlockingType(comptime Storage: type) type {
    return struct {
        const ReadState = struct {
            operation: Storage.Read = .{},
            done: bool = false,

            fn onDone(operation: *Storage.Read) void {
                const state: *ReadState = @fieldParentPtr("operation", operation);
                state.done = true;
            }
        };

        /// Reads into `buffer` from `offset` and returns how many bytes
        /// were read: `buffer.len` unless the file ended first.
        pub fn readAll(
            storage: *Storage,
            file: Storage.File,
            buffer: []u8,
            offset: u64,
        ) Storage.ReadError!usize {
            if (buffer.len == 0) {
                // Nothing to read. An operation must transfer something.
                return 0;
            }
            var state: ReadState = .{};
            storage.read(&state.operation, ReadState.onDone, file, buffer, offset);
            while (!state.done) {
                storage.wait(wait_ns);
            }
            return state.operation.result;
        }

        const WriteState = struct {
            operation: Storage.Write = .{},
            done: bool = false,

            fn onDone(operation: *Storage.Write) void {
                const state: *WriteState = @fieldParentPtr("operation", operation);
                state.done = true;
            }
        };

        /// Writes all of `buffer` at `offset`.
        pub fn writeAll(
            storage: *Storage,
            file: Storage.File,
            buffer: []const u8,
            offset: u64,
            durability: Storage.Durability,
        ) Storage.WriteError!void {
            // An operation must transfer something. Nothing in the store
            // writes an empty buffer.
            assert(buffer.len > 0);
            var state: WriteState = .{};
            storage.write(&state.operation, WriteState.onDone, file, buffer, offset, durability);
            while (!state.done) {
                storage.wait(wait_ns);
            }
            return state.operation.result;
        }

        const SyncState = struct {
            operation: Storage.Sync = .{},
            done: bool = false,

            fn onDone(operation: *Storage.Sync) void {
                const state: *SyncState = @fieldParentPtr("operation", operation);
                state.done = true;
            }
        };

        /// Makes everything written to the file so far durable.
        pub fn syncFile(storage: *Storage, file: Storage.File) Storage.SyncError!void {
            var state: SyncState = .{};
            storage.sync(&state.operation, SyncState.onDone, file);
            while (!state.done) {
                storage.wait(wait_ns);
            }
            return state.operation.result;
        }
    };
}
