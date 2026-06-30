//!
//! A Roaring Bitmap implementation inspired by CRoaring.
//!  * https://github.com/RoaringBitmap/CRoaring
//!  * https://github.com/RoaringBitmap/RoaringFormatSpec
//!

pub const zroaring = @This();

pub const Bitmap = @import("Bitmap.zig");
pub const Word = u64;
pub const Bitset = [1024]Word;
pub const Block = @Vector(constants.BLOCK_SIZE, u8);
pub const Block32 = @Vector(constants.BLOCK_LEN32, u32);
pub const Block64 = @Vector(constants.BLOCK_LEN64, u64);
pub const BlockMask = @Int(.unsigned, constants.BLOCK_SIZE);
pub const u8x32 = @Vector(32, u8);
pub const u64x4 = @Vector(4, u64);
pub const constants = @import("constants.zig");
pub const container = @import("container.zig");
pub const Container = container.Container;
pub const Iterator = @import("Iterator.zig");

pub const Magic = enum(u16) {
    /// no run containers are used
    SERIAL_COOKIE_NO_RUNCONTAINER = 12346,
    /// run containers may be present
    SERIAL_COOKIE = 12347,
    FROZEN_COOKIE = 13766,
    _,
};

/// # Cookie header
/// The cookie header spans either 64 bits or 32 bits followed by a variable number of bytes.
/// Magic cookie value that identifies the type of Roaring Bitmap format.
/// 12346 (SERIAL_COOKIE_NO_RUNCONTAINER) means no run containers are used.
/// 12347 (SERIAL_COOKIE) means run containers may be present.
pub const Cookie = extern struct {
    magic: Magic,
    cardinality_minus1: u16,
};

pub const Typecode = enum(u2) { shared, bitset, array, run };
pub const Rle16 = extern struct { value: u16, length: u16 };
pub const KeyCard = extern struct { key: u16, cardinality_minus1: u16 };
/// a bitset of u8 which can represent MAX_CONTAINERS: `[8192]u8`. answers which
/// containers are run containers.
pub const RunFlags = [constants.MAX_CONTAINERS / 8]u8;

test {
    _ = Bitmap;
    _ = @import("validate.zig");
    _ = @import("fuzz.zig");
}
