const root = @import("root.zig");

pub const Typecode = enum(u8) {
    array,
    bitset,
    run,
    shared,

    pub fn Type(comptime tc: Typecode) type {
        return switch (tc) {
            inline else => |typecode| @FieldType(Container, @tagName(typecode)),
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

pub const Magic = enum(u16) {
    SERIAL_COOKIE_NO_RUNCONTAINER = 12346,
    SERIAL_COOKIE = 12347,
    _,
};

/// # Cookie header
/// The cookie header spans either 64 bits or 32 bits followed by a variable number of bytes.
/// Magic cookie value that identifies the type of Roaring Bitmap format.
/// 12346 (SERIAL_COOKIE_NO_RUNCONTAINER) means no run containers are used.
/// 12347 (SERIAL_COOKIE) means run containers may be present.
pub const Cookie = extern struct { magic: Magic, cardinality_minus1: u16 };

/// Result of adding a value to a set
pub const AddResult = enum {
    /// the value was added to the set
    added,
    /// the value was already present
    already_present,
    /// not added because cardinality would exceed max_cardinality
    not_added,
};
