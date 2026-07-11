/// 8192
pub const MAX_CONTAINER_SIZE = @sizeOf(root.Bitset);
/// 4096
pub const DEFAULT_MAX_SIZE = @divExact(MAX_CONTAINER_SIZE, @sizeOf(u16));
/// 1<<16, 65536, 0x10000
pub const MAX_KEY_CARDINALITY = MAX_CONTAINER_SIZE * 8;
pub const MAX_CONTAINERS = MAX_KEY_CARDINALITY;
pub const MAX_VALUE_CARDINALITY = MAX_KEY_CARDINALITY * MAX_KEY_CARDINALITY;

/// Length in bytes of a Block. Same as `@sizeOf(root.Block)`.
/// 32 with avx2.
pub const BLOCK_SIZE = @min(@max(
    std.simd.suggestVectorLength(u8) orelse @sizeOf(usize),
    @sizeOf(root.Word),
), 32);
pub const BLOCK_ALIGN = @alignOf(root.Block);
pub const BLOCK_ALIGNMENT: std.mem.Alignment = .fromByteUnits(BLOCK_ALIGN);
/// 256 with avx2.
pub const BITSET_BLOCKS = @divExact(MAX_CONTAINER_SIZE, @sizeOf(root.Block));
pub const BITSET_CONTAINER_SIZE_IN_WORDS = @typeInfo(root.Bitset).array.len;
/// length of a block of u16s, 16 with avx2.
pub const BLOCK_LEN16 = @divExact(BLOCK_SIZE, @sizeOf(u16));
/// length of a block of u32s (or Rle16s), 8 with avx2.
pub const BLOCK_LEN32 = @divExact(BLOCK_SIZE, @sizeOf(u32));
/// length of a block of u64s, 4 with avx2.
pub const BLOCK_LEN64 = @divExact(BLOCK_SIZE, @sizeOf(u64));
pub const MAX_CONTAINER_BLOCKS = BITSET_BLOCKS;

pub const SERIALIZATION_ARRAY_UINT32 = 1;
pub const SERIALIZATION_CONTAINER = 2;
pub const NO_OFFSET_THRESHOLD = 4;
pub const BITSET_UNKNOWN_CARDINALITY = std.math.maxInt(root.Container.Cardinality);
pub const OR_BITSET_CONVERSION_TO_FULL = false; // TODO build option
/// whether lazy container-container operations force a bitset conversion
pub const LAZY_OR_BITSET_CONVERSION_TO_FULL = false; // TODO build option
pub const LAZY_OR_BITSET_CONVERSION = true; // TODO build option
pub const ARRAY_LAZY_LOWERBOUND = 1024;

pub const CONTAINER_DATA_SIZE = BLOCK_ALIGNMENT.forward(@sizeOf(root.Container.Data));

pub const IS_X86 = builtin.cpu.arch.isX86();
pub const IS_X64 = builtin.cpu.arch == .x86_64;
pub const HAS_AVX2 = if (IS_X86)
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)
else
    false;

comptime {
    assert(DEFAULT_MAX_SIZE == @divExact(MAX_KEY_CARDINALITY, 16));
    assert(MAX_KEY_CARDINALITY == 1 << 16);
}

const std = @import("std");
const assert = std.debug.assert;
const root = @import("root.zig");
const builtin = @import("builtin");
