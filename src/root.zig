const zroaring = @This();
pub const Array = @import("Array.zig");
pub const Bitmap = @import("Bitmap.zig");
const ctr = @import("container.zig");
pub const Container = ctr.Container;
pub const ArrayContainer = @import("ArrayContainer.zig");
pub const BitsetContainer = ctr.BitsetContainer;
pub const RunContainer = ctr.RunContainer;
pub const Rle16 = RunContainer.Rle16;
pub const SharedContainer = ctr.SharedContainer;
const types = @import("types.zig");
pub const Typecode = types.Typecode;
pub const Cookie = types.Cookie;

test {
    _ = Container;
    _ = Array;
    _ = ArrayContainer;
    _ = Bitmap;
    _ = BitsetContainer;
    _ = RunContainer;
    _ = SharedContainer;
    _ = @import("validate.zig");
}
