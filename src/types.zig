const root = @import("root.zig");
pub const Typecode = enum(u8) {
    array,
    bitset,
    run,
    shared,

    pub fn Type(comptime tc: Typecode) type {
        return switch (tc) {
            inline else => |t| @FieldType(Container, @tagName(t)),
        };
    }

    pub fn fromType(comptime T: type) Typecode {
        inline for (@typeInfo(Typecode).@"enum".fields) |f| {
            if (T == @FieldType(Container, f.name)) return @enumFromInt(f.value);
        }
        @compileError("fromType() unexpected type: '" ++ @typeName(T) ++ "'");
    }

    /// an int with t1 in lo, t2 in hi bits
    pub fn pair(t1: Typecode, t2: Typecode) u16 {
        return @as(u16, @intFromEnum(t2)) << 8 | @intFromEnum(t1);
    }
};

const Container = union(Typecode) {
    array: root.ArrayContainer,
    bitset: root.BitsetContainer,
    run: root.RunContainer,
    shared: root.SharedContainer,
};
