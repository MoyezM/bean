//! A real Storage on a directory, for tests.

const std = @import("std");
const Io = std.Io;

const async_io = @import("../async_io.zig");
const storage = @import("../storage.zig");

/// An event loop and a Storage over it. The storage holds a pointer to the
/// event loop, so this is set up in place and must not be moved.
pub const RealStorage = struct {
    event_loop: async_io.AsyncIo,
    storage: storage.Storage,

    pub fn init(self: *RealStorage, dir: Io.Dir) !void {
        self.event_loop = try .init();
        self.storage = .init(&self.event_loop, std.testing.io, dir);
    }

    pub fn deinit(self: *RealStorage) void {
        self.storage.deinit();
        self.event_loop.deinit();
    }
};
