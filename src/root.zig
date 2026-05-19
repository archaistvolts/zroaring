//!
//! A Roaring Bitmap implementation inspired by CRoaring.
//!  * https://github.com/RoaringBitmap/CRoaring
//!  * https://github.com/RoaringBitmap/RoaringFormatSpec
//!

pub const zroaring = @This();

pub const Bitmap = @import("Bitmap.zig");
pub const Bitset = [1024]u64;
pub const Block = @Vector(constants.BLOCK_SIZE, u8);
pub const constants = @import("constants.zig");
pub const container = @import("container.zig");
pub const Container = container.Container;

pub const Magic = enum(u16) {
    SERIAL_COOKIE_NO_RUNCONTAINER = 12346,
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
/// a bitset of u8 which can represent MAX_CONTAINERS. answers which containers are
/// run containers: `[8192]u8`.
pub const RunFlags = [constants.MAX_CONTAINERS / 8]u8;

test {
    _ = Bitmap;
    _ = @import("validate.zig");
    _ = @import("fuzz.zig");
    _ = @import("flexible_struct");
}
