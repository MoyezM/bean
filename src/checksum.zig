//! The checksum used by every file format in the store: CRC-32C.
//!
//! On ARM this uses the CPU's CRC instructions, which are about twenty times
//! faster than the standard library's table lookup. Everywhere else it calls
//! the standard library, which already uses the CPU's instructions on x86.
//! Both paths give the same value for the same bytes.

const std = @import("std");
const builtin = @import("builtin");

const StdCrc32c = std.hash.crc.@"CRC-32/ISCSI";

/// Whether this build computes checksums with ARM's CRC instructions. It is
/// decided when the program is compiled, from the CPU features of the target.
pub const uses_arm_instructions = builtin.cpu.has(.aarch64, .crc);

/// Returns the CRC-32C checksum of `bytes`.
pub fn crc32c(bytes: []const u8) u32 {
    if (uses_arm_instructions) {
        return crc32cArm(bytes);
    }
    return StdCrc32c.hash(bytes);
}

fn crc32cArm(bytes: []const u8) u32 {
    // CRC-32C starts from all ones and inverts the result at the end.
    var crc: u32 = 0xffffffff;
    var index: usize = 0;

    // Eight bytes at a time for as long as eight remain.
    while (bytes.len - index >= 8) {
        const word = std.mem.readInt(u64, bytes[index..][0..8], .little);
        crc = armCrc32cWord(crc, word);
        index += 8;
    }

    // Then the last few bytes one at a time.
    while (index < bytes.len) {
        crc = armCrc32cByte(crc, bytes[index]);
        index += 1;
    }

    return ~crc;
}

/// Feeds eight bytes into a running CRC with the `crc32cx` instruction.
fn armCrc32cWord(crc: u32, word: u64) u32 {
    return asm ("crc32cx %[result:w], %[crc:w], %[word]"
        : [result] "=r" (-> u32),
        : [crc] "r" (crc),
          [word] "r" (word),
    );
}

/// Feeds one byte into a running CRC with the `crc32cb` instruction.
fn armCrc32cByte(crc: u32, byte: u8) u32 {
    const byte_as_u32: u32 = byte;
    return asm ("crc32cb %[result:w], %[crc:w], %[byte:w]"
        : [result] "=r" (-> u32),
        : [crc] "r" (crc),
          [byte] "r" (byte_as_u32),
    );
}

const testing = std.testing;

test "crc32c matches the published check values" {
    // The standard check value for CRC-32C, and the value for no bytes.
    try testing.expectEqual(@as(u32, 0xe3069283), crc32c("123456789"));
    try testing.expectEqual(@as(u32, 0x00000000), crc32c(""));

    // Test vectors from RFC 3720, appendix B.4.
    const zeros: [32]u8 = @splat(0x00);
    const ones: [32]u8 = @splat(0xff);
    try testing.expectEqual(@as(u32, 0x8a9136aa), crc32c(&zeros));
    try testing.expectEqual(@as(u32, 0x62a8ab43), crc32c(&ones));
}

test "crc32c matches the standard library at every length and alignment" {
    var bytes: [512]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0xc5c);
    prng.random().bytes(&bytes);

    // Starting at each of the first 16 offsets covers every alignment of the
    // eight-byte steps. Every length covers every size of leftover tail.
    for (0..16) |start| {
        for (0..bytes.len - start + 1) |len| {
            const slice = bytes[start..][0..len];
            try testing.expectEqual(StdCrc32c.hash(slice), crc32c(slice));
        }
    }
}
