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
pub const key_size_max = 1024;

/// The longest value the store accepts, in bytes.
pub const value_size_max = 1024 * 1024;

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
