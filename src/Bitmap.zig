/// a bitmap which stores integers as offsets relative to `min`
/// * `min`, `max`: smallest and largest integers the bitmap can represent.
/// * `W`: a integer word type such as u64.
pub fn Bitmap(min: comptime_int, max: comptime_int, W: type) type {
    return struct {
        /// cached population count of set bits in all words
        cardinality: VCount,
        /// bitset storage as words
        words: WordsPtrAligned,

        //                                               example: min = 0
        //                                                        max = 65535
        //                                                          W = u64
        /// a integer type from min to max.
        pub const V = std.math.IntFittingRange(min, max); //            u16
        /// distance between min and max
        pub const max_offset = max - min; //                            65535
        const VCount = std.math.IntFittingRange(0, max_cardinality); // u17
        const max_cardinality: comptime_int = max_offset + 1; //        65536
        const W_bits: usize = @typeInfo(W).int.bits; //                 64
        /// number of words without padding                             1024
        const words_len = std.math.divCeil(usize, max_cardinality, W_bits) catch unreachable;
        /// number of words with padding                                1024
        const words_len_padded: usize = mem.alignForward(usize, words_len, block_len);
        const WordsPtrAligned = *align(block_align) [words_len_padded]W;
        pub const size_in_bytes = words_len_padded * @sizeOf(W); //            8192
        const WIndex = std.math.Log2Int(W); //                          u6

        // blocks
        const block_len = std.simd.suggestVectorLength(W).?;
        const Block = @Vector(@min(words_len_padded, block_len), W);
        const BlockA = [@min(words_len_padded, block_len)]W;
        const block_align = @alignOf(Block);
        const num_blocks = words_len_padded / block_len;
        const block_word_count = words_len_padded / num_blocks; // words per block
        const BlockMask = std.meta.Int(.unsigned, @sizeOf(Block) * 8);

        const Self = @This();
        pub fn init(words: WordsPtrAligned) Self {
            words.* = @splat(0);
            return .{ .words = words, .cardinality = 0 };
        }

        pub fn initValues(words: WordsPtrAligned, values: []const V) Self {
            var ret = init(words);
            return ret.setValues(values).*;
        }

        pub fn create(allocator: mem.Allocator) !Self {
            const words_slice = try allocator.alignedAlloc(W, .fromByteUnits(block_align), words_len_padded);
            return init(words_slice[0..words_len_padded]);
        }

        pub fn createValues(allocator: mem.Allocator, values: []const V) !Self {
            const words_slice = try allocator.alignedAlloc(W, .fromByteUnits(block_align), words_len_padded);
            return initValues(words_slice[0..words_len_padded], values);
        }

        pub fn destroy(self: Self, allocator: mem.Allocator) void {
            return allocator.destroy(self.words);
        }

        pub fn set(self: *Self, value: V) *Self {

            // TODO optimize like roaring?
            // uint64_t shift = 6;
            // uint64_t offset;
            // uint64_t p = pos;
            // ASM_SHIFT_RIGHT(p, shift, offset);
            // uint64_t load = bitset->words[offset];
            // ASM_SET_BIT_INC_WAS_CLEAR(load, p, bitset->cardinality);
            // bitset->words[offset] = load;
            // std.debug.print("set({}) min {}\n", .{ v2, min });

            const offset = value - min;
            const word_idx = offset / W_bits;
            // std.log.debug("{f}", .{self.*});
            // std.debug.print("value/offset {}/{} word_idx {}/{}\n", .{ value, offset, word_idx, max_words });
            const bit_idx: WIndex = @intCast(offset % W_bits);
            const word = &self.words[word_idx];
            const is_unset = 1 - @as(u1, @intCast((word.* >> bit_idx) & 1));
            self.cardinality += is_unset;
            // std.debug.print("{} {}\n", .{ self.cardinality, max_cardinality });
            assert(self.cardinality <= max_cardinality);
            word.* |= (@as(W, 1) << @intCast(bit_idx));
            return self;
        }

        pub fn setValues(self: *Self, values: []const V) *Self {
            for (values) |v| _ = self.set(v);
            return self;
        }

        pub fn unset(self: *Self, v2: V) *Self {
            const value = v2 - min;
            const word_idx = value / W_bits;
            const bit_idx = value % W_bits;
            self.words[word_idx] &= ~(@as(W, 1) << @intCast(bit_idx));
            return self;
        }

        pub fn contains(self: Self, v2: V) bool {
            const value = v2 - min;
            const word_idx = value / W_bits;
            const bit_idx = value % W_bits;
            // std.debug.print("--\n{} {} {}\n{b:0>64}\n{b:0>64}\n", .{ value, word_idx, bit_idx, self.words[word_idx], @as(W, 1) << @intCast(bit_idx) });
            return (self.words[word_idx] & (@as(W, 1) << @intCast(bit_idx))) != 0;
        }

        pub fn containsValues(self: Self, values: []const V) bool {
            for (values) |v| if (!self.contains(v)) return false;
            return true;
        }

        pub fn calcCardinality(self: Self) VCount {
            var count: VCount = 0;
            for (self.words) |word| count += @intCast(@popCount(word));
            return count;
        }

        // pub fn blocksMut(self: *Self) *[num_blocks]Block {
        //     // @compileLog(Block, @FieldType(Self, "words"));
        //     // const bs: *[num_blocks]Block = @ptrCast(self.words);
        //     // return bs;
        //     return @ptrCast(self.words);
        // }

        // pub fn blocksConst(self: *const Self) *const [num_blocks]Block {
        //     return @ptrCast(self.words);
        //     // // @compileLog(Block, @FieldType(Self, "words"));
        //     // const bs: *const [num_blocks]Block = @ptrCast(@alignCast(self.words));
        //     // // std.debug.print("bs {any}\n", .{bs});
        //     // // unreachable;
        //     // return bs;
        // }

        pub const unionWith = unionWithSimd;

        fn unionWithSimple(self: *Self, other: Self) *Self {
            self.cardinality = 0;
            for (self.words, other.words) |*s, *o| {
                s.* |= o.*;
                self.cardinality += @intCast(@popCount(s.*));
            }
            return self;
        }

        fn unionWithSimd(self: *Self, other: Self) *Self {
            return self.blockOp(other, .@"|");
        }

        // TODO more ops, use elsewhere
        // TODO benchmark, test this is faster than per-word ops
        /// perform `op` with blocks instead of individual words.
        fn blockOp(self: *Self, other: Self, comptime op: enum { @"|" }) *Self {
            assert(num_blocks > 0);
            self.cardinality = 0;
            for (0..num_blocks) |blocki| {
                const s: *BlockA = @ptrCast(self.words[blocki * block_word_count ..][0..block_word_count]);
                const o: *BlockA = @ptrCast(other.words[blocki * block_word_count ..][0..block_word_count]);
                var sv: Block = s.*;
                const ov: Block = o.*;
                sv = switch (op) {
                    .@"|" => sv | ov,
                };
                s.* = sv;
                self.cardinality += @intCast(@popCount(@as(BlockMask, @bitCast(sv))));
            }
            return self;
        }

        pub fn intersectWith(self: *Self, other: Self) *Self {
            self.cardinality = 0;
            for (self.words, other.words) |*s, *o| { // TODO optimize?
                s.* &= o.*;
                self.cardinality += @intCast(@popCount(s.*));
            }
            return self;
        }

        pub fn clear(self: *Self) *Self {
            self.words.* = @splat(0);
            self.cardinality = 0;
            return self;
        }

        pub fn differenceWith(self: *Self, other: Self) *Self {
            self.cardinality = 0;
            for (self.words, other.words) |*s, *o| { // TODO optimize?
                s.* &= ~o.*;
                self.cardinality += @intCast(@popCount(s.*));
            }
            return self;
        }

        pub fn xorWith(self: *Self, other: Self) *Self {
            self.cardinality = 0;
            for (self.words, other.words) |*s, *o| { // TODO optimize?
                s.* ^= o.*;
                self.cardinality += @intCast(@popCount(s.*));
            }
            return self;
        }

        pub fn andNotWith(self: *Self, other: Self) *Self {
            self.cardinality = 0;
            for (self.words, other.words) |*s, *o| { // TODO optimize?
                s.* &= ~o.*;
                self.cardinality += @intCast(@popCount(s.*));
            }
            return self;
        }

        pub fn isEmpty(self: Self) bool {
            return self.cardinality == 0;
        }

        pub fn equals(self: *const Self, other: *const Self) bool {
            for (self.words, other.words) |*s, *o| { // TODO optimize?
                if (s.* != o.*) return false;
            }
            return true;
        }

        pub fn copy(self: *Self, other: Self) *Self {
            for (self.words, other.words) |*s, *o| { // TODO optimize?
                s.* = o.*;
            }
            self.cardinality = other.cardinality;
            return self;
        }

        // pub fn flipRange(self: SelfContainer, start: V, end: V) SelfContainer {
        //     var i = start;
        //     while (i < end) : (i += 1) {
        //         const word_idx = i / W_bits;
        //         const bit_idx = i % W_bits;
        //         self.words[word_idx] ^= (@as(W, 1) << @intCast(bit_idx));
        //     }
        //     return self;
        // }

        /// this may be a large struct and likely shouldn't be copied
        pub const Builder = struct {
            words: [words_len_padded]W align(block_align),
            bitmap: Self,

            pub fn init(b: *Builder) void {
                b.bitmap = .init(&b.words);
            }
            pub fn initValues(b: *Builder, values: []const V) void {
                b.bitmap = .initValues(&b.words, values);
            }
        };

        test Builder {
            var b: Builder = undefined;
            b.init();
            try testing.expectEqual(b.bitmap.cardinality, 0);
            b.initValues(&.{ min, min + 1 });
            try testing.expectEqual(b.bitmap.cardinality, 2);
        }

        pub fn format(self: Self, w: *std.Io.Writer) !void {
            try w.print("{}", .{self.cardinality});
            if (build_options.trace) {
                try w.print(" min/max/W: {}/{}/{} types: {} {} words: {} bytes: {} block_len: {}", .{ min, max, W, V, VCount, words_len_padded, size_in_bytes, block_len });
            }
        }

        test format {
            var words: [words_len_padded]W align(block_align) = undefined;
            if (!build_options.trace) {
                try testing.expectFmt("0\n", "{f}\n", .{init(&words)});
                try testing.expectFmt("2\n", "{f}\n", .{initValues(&words, &.{ min, min + 1 })});
            } else {
                std.debug.print("{f}\n", .{init(&words)});
                // std.debug.print("{f}\n", .{initValues(&words, &.{ min, min + 1 })});
            }
        }

        test init {
            var words: [words_len_padded]W align(block_align) = undefined;
            try testing.expectEqual(init(&words).cardinality, 0);
        }

        test create {
            const c = try create(testing.allocator);
            defer c.destroy(testing.allocator);
            try testing.expectEqual(c.cardinality, 0);
        }

        test createValues {
            const c = try createValues(testing.allocator, &.{ min, max });
            defer c.destroy(testing.allocator);
            try testing.expectEqual(c.cardinality, 2);
        }

        const va = min + max_offset / 8 - 1;
        const vb = min + max_offset / 8;

        test set {
            var words: [words_len_padded]W align(block_align) = undefined;
            var container = initValues(&words, &.{ min, va, vb, max - 1 });
            try testing.expect(container.containsValues(&.{ min, va, vb, max - 1 }));
        }

        test unset {
            var words: [words_len_padded]W align(block_align) = undefined;
            const n = min + max_offset / 2;
            var c = initValues(&words, &.{n});
            try testing.expect(!c.unset(n).contains(n));
        }

        test "cardinality" {
            var words: [words_len_padded]W align(block_align) = undefined;
            var container = init(&words);
            try testing.expectEqual(1, container.set(min + 10).cardinality);
            try testing.expectEqual(2, container.set(min + 20).cardinality);
            try testing.expectEqual(2, container.set(min + 10).cardinality);
        }

        test unionWith {
            var words: [words_len_padded]W align(block_align) = undefined;
            var words2: [words_len_padded]W align(block_align) = undefined;
            var c1 = initValues(&words, &.{ min + 5, min + 10 });
            const c2 = initValues(&words2, &.{ min + 10, min + 15 });
            try testing.expect(c1.unionWith(c2).containsValues(&.{ min + 5, min + 10, min + 15 }));
            try testing.expectEqual(3, c1.cardinality);
        }

        test intersectWith {
            var words: [words_len_padded]W align(block_align) = undefined;
            var words2: [words_len_padded]W align(block_align) = undefined;
            var c1 = initValues(&words, &.{ min + 5, min + 10, min + 15 });
            const c2 = initValues(&words2, &.{ min + 10, min + 15, min + 20 });
            _ = c1.intersectWith(c2);
            try testing.expect(!c1.containsValues(&.{ min + 5, min + 20 }));
            try testing.expect(c1.containsValues(&.{ min + 10, min + 15 }));
            try testing.expectEqual(2, c1.cardinality);
        }

        test clear {
            var words: [words_len_padded]W align(block_align) = undefined;
            var container = initValues(&words, &.{ min + 5, min + max_offset / 3, min + max_offset - 1 });
            try testing.expectEqual(container.cardinality, 3);
            try testing.expectEqual(container.clear().cardinality, 0);
            try testing.expect(!container.contains(min + 5));
        }

        test "word boundaries" {
            var words: [words_len_padded]W align(block_align) = undefined;
            var container = initValues(&words, &.{ va, vb });
            try testing.expect(container.containsValues(&.{ va, vb }));
            try testing.expectEqual(container.cardinality, 2);
        }

        test "large values" {
            var words: [words_len_padded]W align(block_align) = undefined;
            const container = initValues(&words, &.{ max - 1, max - 2 });
            try testing.expect(container.contains(max - 1));
            try testing.expect(container.contains(max - 2));
            try testing.expectEqual(container.cardinality, 2);
        }

        test differenceWith {
            var words: [words_len_padded]W align(block_align) = undefined;
            var words2: [words_len_padded]W align(block_align) = undefined;
            var c1 = initValues(&words, &.{ min + 5, min + 10, min + 15 });
            _ = c1.differenceWith(initValues(&words2, &.{ min + 10, min + 15, min + 20 }));
            try testing.expect(c1.contains(min + 5));
            try testing.expect(!c1.containsValues(&.{ min + 10, min + 15, min + 20 }));
            try testing.expectEqual(c1.cardinality, 1);
        }

        test xorWith {
            var words: [words_len_padded]W align(block_align) = undefined;
            var words2: [words_len_padded]W align(block_align) = undefined;
            var c1 = initValues(&words, &.{ min + 5, min + 10, min + 15 });
            _ = c1.xorWith(initValues(&words2, &.{ min + 10, min + 15, min + 20 }));
            try testing.expect(c1.contains(min + 5));
            try testing.expect(!c1.contains(min + 10));
            try testing.expect(!c1.contains(min + 15));
            try testing.expect(c1.contains(min + 20));
            try testing.expectEqual(c1.cardinality, 2);
        }

        test andNotWith {
            var words: [words_len_padded]W align(block_align) = undefined;
            var words2: [words_len_padded]W align(block_align) = undefined;
            var c1 = initValues(&words, &.{ min + 5, min + 10, min + 15 });
            _ = c1.andNotWith(initValues(&words2, &.{ min + 10, min + 15, min + 20 }));
            try testing.expect(c1.contains(min + 5));
            try testing.expect(!c1.contains(min + 10));
            try testing.expect(!c1.contains(min + 15));
            try testing.expectEqual(c1.cardinality, 1);
        }

        test isEmpty {
            var words: [words_len_padded]W align(block_align) = undefined;
            var container = init(&words);
            try testing.expect(container.isEmpty());
            try testing.expect(!container.set(min + max_offset / 3).isEmpty());
        }

        test equals {
            var words: [words_len_padded]W align(block_align) = undefined;
            var words2: [words_len_padded]W align(block_align) = undefined;
            const c1 = initValues(&words, &.{ min + 5, min + 10 });
            var c2 = initValues(&words2, &.{ min + 5, min + 10 });
            try testing.expect(c1.equals(&c2));
            try testing.expect(!c1.equals(c2.set(min + 15)));
        }

        test copy {
            var words: [words_len_padded]W align(block_align) = undefined;
            var words2: [words_len_padded]W align(block_align) = undefined;
            var c1 = init(&words2);
            _ = c1.copy(initValues(&words, &.{ min + 5, min + max_offset / 3, min + max_offset - 1 }));
            try testing.expect(c1.contains(min + 5));
            try testing.expect(c1.contains(min + max_offset / 3));
            try testing.expect(c1.contains(min + max_offset - 1));
            try testing.expectEqual(c1.cardinality, 3);
        }

        // test flipRange {
        //     var words: [size_in_words]W = undefined;
        //     const container = initValues(&words, &.{ 5, 10 }).flipRange(0, 15);
        //     try testing.expect(!container.contains(5));
        //     try testing.expect(!container.contains(10));
        //     try testing.expect(container.contains(0));
        //     try testing.expect(container.contains(14));
        // }

        test "dense region" {
            var words: [words_len_padded]W align(block_align) = undefined;
            var container = init(&words);
            const n = @min(max + 1, min + max_offset / 9);
            for (min..n) |i| _ = container.set(@intCast(i));
            try testing.expectEqual(n - min, @as(usize, container.cardinality));
            for (min..n) |i| try testing.expect(container.contains(@intCast(i)));
        }

        test "sparse region" {
            var words: [words_len_padded]W align(block_align) = undefined;
            const vs = &.{ min, min + max_offset / 3, min + max_offset / 2, min + max_offset - 1 };
            const container = initValues(&words, vs);
            try testing.expectEqual(4, container.cardinality);
            try testing.expect(container.containsValues(vs));
        }

        test "alternating pattern" {
            var words: [words_len_padded]W align(block_align) = undefined;
            var container = init(&words);
            const n = @min(max, min + (max_offset - 1) / 8);
            for (min..n) |i| {
                if (i % 2 == 0) _ = container.set(@intCast(i));
            }
            try testing.expectEqual((n - min) / 2 + (n & 1), container.cardinality);
            for (min..n) |i| {
                const expected = i % 2 == 0;
                try testing.expectEqual(expected, container.contains(@intCast(i)));
            }
        }

        test "multiple unions" {
            var words1: [words_len_padded]W align(block_align) = undefined;
            var words2: [words_len_padded]W align(block_align) = undefined;
            var words3: [words_len_padded]W align(block_align) = undefined;
            var c1 = initValues(&words1, &.{min + 5});
            _ = c1.unionWith(initValues(&words2, &.{min + 10}))
                .unionWith(initValues(&words3, &.{min + 15}));
            try testing.expectEqual(3, c1.cardinality);
            try testing.expect(c1.containsValues(&.{ min + 5, min + 10, min + 15 }));
        }

        test "intersection with empty" {
            var words: [words_len_padded]W align(block_align) = undefined;
            var words2: [words_len_padded]W align(block_align) = undefined;
            var c1 = initValues(&words, &.{ min + 5, min + 10 });
            try testing.expectEqual(0, c1.intersectWith(init(&words2)).cardinality);
        }
    };
}

/// returns an empty bitmap backed by `words`
pub fn bitmap(
    min: comptime_int,
    max: comptime_int,
    W: type,
    words: Bitmap(min, max, W).WordsPtrAligned,
) Bitmap(min, max, W) {
    return .init(words);
}

/// returns a bitmap backed by `words` with the given initial values
pub fn bitmapValues(
    min: comptime_int,
    max: comptime_int,
    W: type,
    words: Bitmap(min, max, W).WordsPtrAligned,
    init_values: []const Bitmap(min, max, W).V,
) Bitmap(min, max, W) {
    return .initValues(words, init_values);
}

/// causes tests inside Bitmap(min, max, W) to be analyzed and run
fn testBitmap(min: comptime_int, max: comptime_int, W: type) !void {
    const B = Bitmap(min, max, W);
    var words: [B.words_len_padded]W align(B.block_align) = undefined;
    _ = bitmap(min, max, W, &words);
    _ = bitmapValues(min, max, W, &words, &.{});
}

test bitmap {
    try testBitmap(0, 65535, u32);
    // testing.log_level = .debug;
    try testBitmap(0, 65535, u64);
    try testBitmap(0, 65536, u64);
    try testBitmap(0, 65535 / 2, u64);
    try testBitmap(0, 127, u64);
    try testBitmap(128, 255, u64);

    try testBitmap(0, 65535, u128);
    try testBitmap(0, 255, u128);

    // try testBitmap(0, 65535, u256); // FIXME: simd.suggestVectorLength doesn't like u256
    // try testBitmap(0, 255, u256);
}

test "small range - a...z" {
    const B = Bitmap('a', 'z', u64);
    var b: B.Builder = undefined;
    b.initValues(&.{ 'a', 'z' });
    try testing.expect(b.bitmap.containsValues(&.{ 'a', 'z' }));
    for ('b'..'z') |c| {
        try testing.expect(!b.bitmap.contains(@intCast(c)));
    }
    try testing.expectEqual(2, b.bitmap.cardinality);
}

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;
const build_options = @import("build-options");
