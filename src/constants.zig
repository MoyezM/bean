//! The store's limits, in one place.
//!
//! These are fixed when the program is built. Nothing reads them at run time
//! to decide how to behave; they size buffers and bound what the public
//! interface accepts.
//!
//! Only numbers that are free choices live here. A size that follows from
//! another one is never written down a second time: the module that needs it
//! works it out from these at compile time. That way two sizes that have to
//! agree cannot be set to values that disagree.
//!
//! No module other than this one spells out a shared limit. A module that
//! depends on one declares its own constant, named for what the number means
//! in that module, takes the value from here on one line, and then uses its
//! own constant everywhere:
//!
//!     pub const key_size_max = constants.key_size_max;
//!
//! A module also checks, at compile time, that it can honour the limit. For
//! example, a file format with a 16-bit key length asserts that
//! `key_size_max` fits in 16 bits. A combination of choices that cannot work
//! does not compile.

/// The longest key the store accepts, in bytes.
///
/// This is sized for a SQL layer whose keys are an encoded table, index and
/// column values. Postgres allows 2,704 bytes of indexed columns; 4 KiB
/// leaves room for the encoding and for the primary key that follows them
/// in a secondary index entry.
///
/// A table's index currently holds the full last key of every block and is
/// kept in memory, so a long key limit makes its worst case large. The plan
/// is to replace it with a tree of index blocks that hold fixed-size key
/// prefixes and are read through a block cache, so that memory no longer
/// depends on key length.
pub const key_size_max = 4 * 1024;

/// The longest value the store accepts, in bytes.
///
/// A value is stored inline in a table block, and every buffer that holds a
/// block has to be long enough for the largest one, so this is kept modest.
/// Larger values can be split into chunks by the layer above. If they turn
/// out to be common, the plan is a separate append-only file of values (a
/// value heap), with the table holding a pointer to each, so that compaction
/// does not rewrite them.
pub const value_size_max = 64 * 1024;

/// The size of the memtable's buffer, in bytes. When the memtable is full it
/// is flushed to one table, so this also bounds how large a table gets.
pub const memtable_size = 64 * 1024 * 1024;

/// The size a table's data blocks are filled up to, in bytes. A block is
/// only longer than this when it holds a single entry that is larger than a
/// block.
pub const block_size = 16 * 1024;

/// The size of a write batch's buffer, in bytes: the most encoded operations
/// one batch holds. A batch is the payload of one log record, so this is
/// also the largest record payload.
pub const batch_size_max = 2 * 1024 * 1024;

/// How many bytes of a memtable that is being written to a table each write
/// flushes, for every byte the write may add to the other memtable.
///
/// A store has two memtables. When the one taking writes is full, it is
/// frozen and the other takes over, and the frozen one is written out a
/// little at a time by the writes that follow. At 2 or more, the frozen one
/// is on disk before the other is full.
pub const flush_pace = 2;

/// The most table files a store holds at once.
///
/// This is small because, for now, every table keeps its whole index in
/// memory, and a store has no way to merge tables. Once it has, and once
/// indexes are read through a block cache, the number of tables will stop
/// being what limits a store's size.
pub const tables_max = 8;

/// The number of levels tables are arranged in. A table written from the
/// memtable is at level 0.
pub const level_count = 2;
