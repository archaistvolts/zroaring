/// 8192
pub const MAX_CONTAINER_SIZE = @sizeOf(root.Bitset);
pub const DEFAULT_MAX_SIZE = @divExact(MAX_CONTAINER_SIZE, @sizeOf(u16)); // MAX_CONTAINER_SIZE / @sizeOf(u16), 4096
pub const MAX_KEY_CARDINALITY = MAX_CONTAINER_SIZE * 8; // DEFAULT_MAX_SIZE * 16, 65536
pub const MAX_CONTAINERS = MAX_KEY_CARDINALITY;
pub const MAX_VALUE_CARDINALITY = MAX_KEY_CARDINALITY * MAX_KEY_CARDINALITY;

/// Length in bytes of a Block. Same as `@sizeOf(root.Block)`.
/// 32 with avx2.
pub const BLOCK_SIZE = std.simd.suggestVectorLength(u8).?;
pub const BLOCK_ALIGN = @alignOf(root.Block);
pub const BLOCK_ALIGNMENT: std.mem.Alignment = .fromByteUnits(BLOCK_ALIGN);
/// 256 with avx2.
pub const BITSET_BLOCKS = @divExact(MAX_CONTAINER_SIZE, @sizeOf(root.Block));
/// length of a block of u16s, 16 with avx2.
pub const BLOCK_LEN16 = @divExact(BLOCK_SIZE, @sizeOf(u16));
pub const MAX_CONTAINER_BLOCKS = BITSET_BLOCKS;
/// Bitmap.blocks should never actually get this big.
pub const MAX_BLOCKS = MAX_CONTAINERS * MAX_CONTAINER_BLOCKS; // 1<<16 * 1<<8 = 1<<24
/// blocks needed by an `Array`.  1.
// pub const HEADER_BLOCKS = @divExact(@sizeOf(root.Array), @sizeOf(root.Block));

pub const SERIALIZATION_ARRAY_UINT32 = 1;
pub const SERIALIZATION_CONTAINER = 2;
pub const NO_OFFSET_THRESHOLD = 4;
pub const BITSET_UNKNOWN_CARDINALITY = MAX_VALUE_CARDINALITY - 1; // 0xffff_ffff

comptime {
    assert(DEFAULT_MAX_SIZE == @divExact(MAX_KEY_CARDINALITY, 16));
    assert(MAX_KEY_CARDINALITY == 1 << 16);
}

const std = @import("std");
const assert = std.debug.assert;
const root = @import("root.zig");
