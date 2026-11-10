pub const MemTable = @import("memtable.zig").MemTable;
pub const wal = @import("wal.zig");

test {
    _ = @import("memtable.zig");
    _ = @import("wal.zig");
}
