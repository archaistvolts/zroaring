const T = u32;
// TODO build option or generic?
pub const DEFAULT_MAX_SIZE = 4096; // MAX_CONTAINERS / 16
pub const MAX_CONTAINERS = 65536; // DEFAULT_MAX_SIZE * 16
pub const MAX_CARDINALITY = MAX_CONTAINERS;

pub const SERIALIZATION_ARRAY_UINT32 = 1;
pub const SERIALIZATION_CONTAINER = 2;
pub const NO_OFFSET_THRESHOLD = 4;

comptime {
    assert(DEFAULT_MAX_SIZE == @divExact(MAX_CONTAINERS, 16));
    assert(MAX_CONTAINERS == 1 << 16);
}

const std = @import("std");
const assert = std.debug.assert;
