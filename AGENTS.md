# Working in this codebase

Bean is a durable key-value storage engine written in Zig 0.17.1. It is a
learning project, so the code should be easy to read and every design choice
should be explainable.

## Commands

Zig comes from the nix flake. With direnv the shell already has it; otherwise
prefix commands with `nix develop -c`.

    zig build test      run every test
    zig build bench     run the benchmarks (always built optimized)
    zig fmt src/        format

## Limits come from `src/constants.zig`

The store's limits, such as the longest key and the longest value, are
compile-time constants defined once in `src/constants.zig`.

A module that depends on a limit follows three rules:

1. **Declare your own constant and take its value from `constants` on one
   line.** Name it for what the number means in this module, and give it a
   doc comment that says so. The sstable calls the memtable's size
   `table_size_max`, because that is what it bounds there.

       const constants = @import("constants.zig");

       /// The longest key a table stores.
       pub const key_size_max = constants.key_size_max;

2. **Use your own constant everywhere else in the module.** `constants.` must
   not appear anywhere except on those declaration lines. If a constant is
   renamed or restructured, each module changes one line.

3. **Check at compile time that the module can honour the limit.** A limit
   that a file format or a struct field cannot represent must fail to
   compile. Name the module's own ceiling separately from the shared limit.

       /// The longest key the format can represent. The key length is a u16
       /// on disk.
       const key_size_format_max = std.math.maxInt(u16);

       comptime {
           assert(key_size_max <= key_size_format_max);
       }

`src/constants.zig` holds only free choices. A value that follows from a
limit, such as the size of a buffer that holds the largest entry, is never
written down as a second number. It is worked out at compile time, as a named
constant in the module that needs it, next to the limit it comes from.

The aim is that an impossible configuration cannot be represented. Two sizes
that must agree come from one constant. A relation between modules that must
hold is a `comptime` assert in the module that depends on both, so a
combination that cannot work does not compile.

The public interface rejects input over a limit with an error. Internal
modules treat it as a bug in their caller and assert.

Do not write a shared limit as a literal number anywhere outside
`src/constants.zig`, including in tests. Tests that need a value at or over a
limit build it from the module's constant.

## On-disk layouts are `extern struct`s

Every header that is written to a file is an `extern struct` whose fields are
the bytes on disk, in order. The struct is the definition of the layout.

- **Sizes come from the struct.** Write `const block_header_size =
  @sizeOf(BlockHeader);`, not a number.
- **Pin each size with a `comptime` assert**, such as
  `assert(block_header_size == 20);`. The number there is a check, not the
  source: it makes a change to the struct fail to build until the change to
  the file format is acknowledged.
- **No padding.** Order the fields so that none is needed, or mark fields
  `align(1)` where the layout cannot be naturally aligned.
- **Read and write through `fromBytes` and `toBytes`** on the struct. Do not
  write fields one at a time at hand-counted offsets.
- **Kinds and flags are enums** with an explicit integer type and a final
  `_`, so that any number from a damaged file can be held and then rejected.
- **The formats are little-endian.** Each file with on-disk structs asserts
  at compile time that the target is little-endian.
- **A range covered by a checksum is found with `@offsetOf`**, not with a
  byte count.
