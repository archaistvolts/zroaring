const word_types = &.{ u1024, u512, u256, u128, u64, u32, u16, u8 };

/// a bitset which stores integers as offsets relative to `MIN`
/// * `MIN`, `max`: smallest and largest integers the bitset can represent.
/// * `Word`: a integer word type such as u64.
///
// TODO simplify to non generic?
pub fn WordBitset(options: struct {
    MIN: comptime_int = 0,
    MAX: comptime_int = 65535,
    /// integer word size
    Word: type = u64,
}) type {
    return struct {
        /// bitset stored as words with length padded to `words_len_padded`
        words: WordsPtrAligned,
        /// cached count of set bits in all words
        cardinality: u32,
        //                                                       example: MIN = 0
        //                                                                max = 65535
        //                                                               Word = u64
        /// a integer type for MIN and max.
        pub const Value = std.math.IntFittingRange(options.MIN, options.MAX); //u16
        /// positive difference between MIN and max
        pub const MAX_DIFFERENCE = options.MAX - options.MIN; //                65535
        const MAX_CARDINALITY = MAX_DIFFERENCE + 1; //                          65536
        const ValueCardinality = std.math.IntFittingRange(0, MAX_DIFFERENCE); //u17
        const Word = options.Word;
        const MIN = options.MIN;
        const MAX = options.MAX;
        const WORD_BITSIZE: usize = @typeInfo(Word).int.bits; //                64
        /// number of words without padding to block len                        1024
        pub const SIZE_IN_WORDS = std.math.divCeil(usize, MAX_CARDINALITY, WORD_BITSIZE) catch unreachable;
        pub const SIZE_IN_BYTES = SIZE_IN_WORDS * @sizeOf(Word); //             8192
        /// number of words with padding to block len                           1024
        const SIZE_IN_WORDS_PADDED: usize = mem.alignForward(usize, SIZE_IN_WORDS, block_len);
        const WordsPtrAligned = [*]align(block_align) Word; //                  [*]align(32)u64
        const WordsSliceAligned = []align(block_align) Word;
        const WordIndex = std.math.Log2Int(Word); //                            u6

        // blocks
        /// suggested vector length for `Word` or else largest suggested from `block_types`.
        const block_len = std.simd.suggestVectorLength(Word) orelse
            for (word_types) |T| {
                if (std.simd.suggestVectorLength(T)) |len|
                    break len;
            } else null; // unsupported. TODO. workaround with a smaller `Word` type?
        const Block = @Vector(@min(SIZE_IN_WORDS_PADDED, block_len), Word);
        const BlockArray = [@min(SIZE_IN_WORDS_PADDED, block_len)]Word;
        const block_align = @alignOf(Block);
        const blocks_count = @divExact(SIZE_IN_WORDS_PADDED, block_len);
        const words_per_block = @divExact(SIZE_IN_WORDS_PADDED, blocks_count);
        const BlockMask = std.meta.Int(.unsigned, @sizeOf(Block) * 8);

        const Self = @This();

        pub fn init(words: WordsSliceAligned) Self {
            @memset(words, 0);
            return .{ .words = words.ptr, .cardinality = 0 };
        }

        pub fn initBatch(words: WordsSliceAligned, values: []const Value) Self {
            var ret = init(words);
            return ret.setBatch(values).*;
        }

        pub fn deinit(b: *const Self, allocator: mem.Allocator) void {
            // std.debug.print("{*}", .{b});
            allocator.free(b.slice());
        }

        pub fn create(allocator: mem.Allocator) !Self {
            const words_slice = try allocator.alignedAlloc(Word, .fromByteUnits(block_align), SIZE_IN_WORDS_PADDED);
            return init(words_slice[0..SIZE_IN_WORDS_PADDED]);
        }

        pub fn createBatch(allocator: mem.Allocator, values: []const Value) !Self {
            const words_slice = try allocator.alignedAlloc(Word, .fromByteUnits(block_align), SIZE_IN_WORDS_PADDED);
            return initBatch(words_slice[0..SIZE_IN_WORDS_PADDED], values);
        }

        pub fn size_in_bytes(b: Self) usize {
            _ = b;
            return @sizeOf(Word) * SIZE_IN_WORDS;
        }

        pub fn write(b: Self, w: *Io.Writer) !usize {
            try w.writeSliceEndian(u64, b.slice(), .little);
            return b.size_in_bytes();
        }

        pub fn set(self: *Self, value: Value) *Self {

            // TODO optimize like roaring?
            // uint64_t shift = 6;
            // uint64_t offset;
            // uint64_t p = pos;
            // ASM_SHIFT_RIGHT(p, shift, offset);
            // uint64_t load = bitset->words[offset];
            // ASM_SET_BIT_INC_WAS_CLEAR(load, p, bitset->count);
            // bitset->words[offset] = load;
            // std.debug.print("set({}) MIN {}\n", .{ v2, MIN });

            const offset = value - MIN;
            const word_idx = offset / WORD_BITSIZE;
            // std.log.debug("{f}", .{self.*});
            // std.debug.print("value/offset {}/{} word_idx {}/{}\n", .{ value, offset, word_idx, max_words });
            const bit_idx: WordIndex = @intCast(offset % WORD_BITSIZE);
            const word = &self.words[word_idx];
            const is_unset = 1 - @as(u1, @intCast((word.* >> bit_idx) & 1));
            self.cardinality += is_unset;
            // std.debug.print("{} {}\n", .{ self.count, max_count });
            assert(self.cardinality <= MAX_CARDINALITY);
            word.* |= (@as(Word, 1) << @intCast(bit_idx));
            return self;
        }

        pub fn setBatch(self: *Self, values: []const Value) *Self {
            for (values) |v| _ = self.set(v);
            return self;
        }

        pub fn unset(self: *Self, v2: Value) *Self {
            const value = v2 - MIN;
            const word_idx = value / WORD_BITSIZE;
            const bit_idx = value % WORD_BITSIZE;
            self.words[word_idx] &= ~(@as(Word, 1) << @intCast(bit_idx));
            return self;
        }

        pub fn contains(self: Self, v2: Value) bool {
            // std.debug.print("WordBitset.contains({})\n", .{v2});
            const value = v2 - MIN;
            const word_idx = value / WORD_BITSIZE;
            const bit_idx = value % WORD_BITSIZE;
            // std.debug.print("--\n{} {} {}\n{b:0>64}\n{b:0>64}\n", .{ value, word_idx, bit_idx, self.words[word_idx], @as(Word, 1) << @intCast(bit_idx) });
            return (self.words[word_idx] & (@as(Word, 1) << @intCast(bit_idx))) != 0;
        }

        pub fn containsBatch(self: Self, values: []const Value) bool {
            for (values) |v| if (!self.contains(v)) return false;
            return true;
        }

        pub const word_zero: Word = 0;

        pub fn add_range(self: *Self, min: u32, max: u32, step: u16) void {
            var cur: u16 = @intCast(min);
            while (cur < max) : (cur += step) {
                _ = self.set(cur);
            }
        }

        ///
        /// Find the cardinality of the bitset in [begin,begin+lenminusone]
        ///
        pub fn lenrange_cardinality(words: WordsPtrAligned, start: u32, lenminusone: u32) u32 {
            const firstword = start / 64;
            const endword = (start + lenminusone) / 64;
            if (firstword == endword) {
                return @popCount(words[firstword] &
                    ((~word_zero) >> @intCast((63 - lenminusone) % 64)) << @intCast(start % 64));
            }
            var answer =
                @popCount(words[firstword] & ((~word_zero) << @intCast(start % 64)));
            for (firstword + 1..endword) |i| {
                answer += @popCount(words[i]);
            }
            answer += @popCount(words[endword] &
                (~word_zero) >>
                    @intCast(((~start + 1) - lenminusone - 1) % 64));
            return answer;
        }

        ///
        /// Set all bits in indexes [begin,begin+lenminusone] to true.
        ///
        pub fn set_lenrange(words: WordsPtrAligned, start: u32, lenminusone: u32) void {
            const firstword = start / 64;
            const endword = (start + lenminusone) / 64;
            if (firstword == endword) {
                words[firstword] |= ((~word_zero) >> @intCast((63 - lenminusone) % 64)) << @intCast(start % 64);
                return;
            }
            const temp = words[endword];
            words[firstword] |= (~word_zero) << @intCast(start % 64);
            var i = firstword + 1;
            while (i < endword) : (i += 2)
                words[i..][0..2].* = @splat(~word_zero);
            words[endword] =
                temp | (~word_zero) >> @intCast(((~start + 1) - lenminusone - 1) % 64);
        }

        // fn calcCount(self: Self) VCount {
        //     var count: VCount = 0;
        //     for (self.words) |word| count += @intCast(@popCount(word));
        //     return count;
        // }

        pub const Op = enum { @"|", @"&", @"&~", @"^" };

        // TODO benchmark, test this is faster than per-word ops
        /// perform `op` on blocks at once instead of individual words.
        fn blockOp(dest: *Self, src: Self, comptime op: Op) *Self {
            assert(blocks_count > 0);
            dest.cardinality = 0;
            for (0..blocks_count) |blocki| {
                const d: *BlockArray = @ptrCast(dest.words[blocki * words_per_block ..][0..words_per_block]);
                const s: *BlockArray = @ptrCast(src.words[blocki * words_per_block ..][0..words_per_block]);
                var dv: Block = d.*;
                const sv: Block = s.*;
                dv = switch (op) {
                    .@"|" => dv | sv,
                    .@"&" => dv & sv,
                    .@"&~" => dv & ~sv,
                    .@"^" => dv ^ sv,
                };
                d.* = dv;
                dest.cardinality += @intCast(@popCount(@as(BlockMask, @bitCast(dv))));
            }
            return dest;
        }

        pub const unionWith = unionWithBlock; // TODO fallback to words
        fn unionWithWords(self: *Self, other: Self) *Self {
            self.cardinality = 0;
            for (self.words, other.words) |*s, *o| {
                s.* |= o.*;
                self.cardinality += @intCast(@popCount(s.*));
            }
            return self;
        }
        fn unionWithBlock(self: *Self, other: Self) *Self {
            return self.blockOp(other, .@"|");
        }

        pub const intersectWith = intersectWithBlock; // TODO fallback to words
        fn intersectWithWords(self: *Self, other: Self) *Self {
            self.cardinality = 0;
            for (self.words, other.words) |*s, *o| { // TODO bench and compare
                s.* &= o.*;
                self.cardinality += @intCast(@popCount(s.*));
            }
            return self;
        }
        fn intersectWithBlock(self: *Self, other: Self) *Self {
            return self.blockOp(other, .@"&");
        }

        pub fn clear(self: *Self) *Self {
            @memset(self.words[0..self.cardinality], 0);
            self.cardinality = 0;
            return self;
        }

        pub const differenceWith = differenceWithBlock; // TODO fallback to words
        fn differenceWithWords(self: *Self, other: Self) *Self {
            self.cardinality = 0;
            for (self.words, other.words) |*s, *o| { // TODO bench and compare
                s.* &= ~o.*;
                self.cardinality += @intCast(@popCount(s.*));
            }
            return self;
        }
        fn differenceWithBlock(self: *Self, other: Self) *Self {
            return self.blockOp(other, .@"&~");
        }

        pub const xorWith = xorWithBlock; // TODO fallback to words
        fn xorWithWords(self: *Self, other: Self) *Self {
            self.cardinality = 0;
            for (self.words, other.words) |*s, *o| { // TODO bench and compare
                s.* ^= o.*;
                self.cardinality += @intCast(@popCount(s.*));
            }
            return self;
        }
        fn xorWithBlock(self: *Self, other: Self) *Self {
            return self.blockOp(other, .@"^");
        }

        pub fn isEmpty(self: Self) bool {
            return self.cardinality == 0;
        }

        pub fn slice(self: Self) WordsSliceAligned {
            return self.words[0..SIZE_IN_WORDS_PADDED];
        }

        pub fn equals(self: *const Self, other: *const Self) bool {
            for (self.slice(), other.slice()) |s, o| { // TODO optimize?
                if (s != o) return false;
            }
            return true;
        }

        pub fn copy(self: *Self, other: Self) *Self {
            for (self.slice(), other.slice()) |*s, *o| { // TODO optimize?
                s.* = o.*;
            }
            self.cardinality = other.cardinality;
            return self;
        }

        ///
        /// Reads the instance from buf, outputs how many bytes were read.
        /// This is meant to be byte-by-byte compatible with the Java and Go versions of
        /// Roaring.
        /// The number of bytes read should be bitset_container_size_in_bytes(container).
        /// You need to provide the (known) cardinality.
        ///
        pub fn read(
            c: *Self,
            r: *Io.Reader,
            cardinality: u32,
        ) !void {
            try r.readSliceEndian(u64, c.slice(), .little);
            c.cardinality = cardinality;
        }

        /// this may be a large struct and likely shouldn't be copied
        pub const Builder = struct {
            words: [SIZE_IN_WORDS_PADDED]Word align(block_align),
            bitset: Self,

            pub fn init(b: *Builder) Self {
                b.bitset = .init(&b.words);
                return b.bitset;
            }
            pub fn initBatch(b: *Builder, values: []const Value) Self {
                b.bitset = .initBatch(&b.words, values);
                return b.bitset;
            }
        };

        pub fn format(self: Self, w: *std.Io.Writer) !void {
            try w.print("{}", .{self.cardinality});
            if (build_options.trace) {
                try w.print(
                    " Bitmap({: <4}{: <6}{: <5}) value types: {: <3} {: <3} words (needed: {: <5} padded: {: <5} size_in_bytes: {: <5}) block: {s: <6} mask: {} blocks {}",
                    .{ MIN, MAX, Word, Value, ValueCardinality, SIZE_IN_WORDS, SIZE_IN_WORDS_PADDED, self.size_in_bytes(), @typeName(Word) ++ std.fmt.comptimePrint("x{}", .{block_len}), BlockMask, blocks_count },
                );
            }
        }

        test {
            _ = TestNs(MIN, MAX, Word);
        }
    };
}

/// internal namespace of tests
// TODO how to make these tests show up in zig docs?  moved here in attempt of that.
fn TestNs(MIN: comptime_int, MAX: comptime_int, Word: type) type {
    return struct {
        const B = WordBitset(.{ .MIN = MIN, .MAX = MAX, .Word = Word });
        const Builder = B.Builder;

        test Builder {
            var b: Builder = undefined;
            try testing.expectEqual(b.init().cardinality, 0);
            try testing.expectEqual(b.initBatch(&.{ MIN, MIN + 1 }).cardinality, 2);
        }

        const format = B.format;
        test format {
            var b: Builder = undefined;
            if (!build_options.trace) {
                try testing.expectFmt("0\n", "{f}\n", .{b.init()});
                try testing.expectFmt("2\n", "{f}\n", .{b.initBatch(&.{ MIN, MIN + 1 })});
            } else {
                // std.debug.print("{f}\n", .{b.init()});
                // std.debug.print("{f}\n", .{b.initBatch(&.{ MIN, MIN + 1 })});
            }
        }

        const init = B.init;
        test init {
            var b: Builder = undefined;
            try testing.expectEqual(b.init().cardinality, 0);
        }

        const create = B.create;
        test create {
            const c = try create(testing.allocator);
            defer c.deinit(testing.allocator);
            try testing.expectEqual(c.cardinality, 0);
        }

        const createBatch = B.createBatch;
        test createBatch {
            const c = try createBatch(testing.allocator, &.{ MIN, MAX });
            defer c.deinit(testing.allocator);
            try testing.expectEqual(c.cardinality, 2);
        }

        const va = MIN + B.MAX_DIFFERENCE / 8 - 1;
        const vb = MIN + B.MAX_DIFFERENCE / 8;

        const put = B.set;
        test put {
            var b: Builder = undefined;
            var container = b.initBatch(&.{ MIN, va, vb, MAX - 1 });
            try testing.expect(container.containsBatch(&.{ MIN, va, vb, MAX - 1 }));
        }

        const unset = B.unset;
        test unset {
            var b: Builder = undefined;
            const n = MIN + B.MAX_DIFFERENCE / 2;
            var c = b.initBatch(&.{n});
            try testing.expect(!c.unset(n).contains(n));
        }

        test "count" {
            var b: Builder = undefined;
            var container = b.init();
            try testing.expectEqual(1, container.set(MIN + 10).cardinality);
            try testing.expectEqual(2, container.set(MIN + 20).cardinality);
            try testing.expectEqual(2, container.set(MIN + 10).cardinality);
        }

        const unionWith = B.unionWith;
        test unionWith {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            var c1 = b.initBatch(&.{ MIN + 5, MIN + 10 });
            const c2 = b2.initBatch(&.{ MIN + 10, MIN + 15 });
            try testing.expect(c1.unionWith(c2).containsBatch(&.{ MIN + 5, MIN + 10, MIN + 15 }));
            try testing.expectEqual(3, c1.cardinality);
        }

        const intersectWith = B.intersectWith;
        test intersectWith {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            var c1 = b.initBatch(&.{ MIN + 5, MIN + 10, MIN + 15 });
            const c2 = b2.initBatch(&.{ MIN + 10, MIN + 15, MIN + 20 });
            _ = c1.intersectWith(c2);
            try testing.expect(!c1.containsBatch(&.{ MIN + 5, MIN + 20 }));
            try testing.expect(c1.containsBatch(&.{ MIN + 10, MIN + 15 }));
            try testing.expectEqual(2, c1.cardinality);
        }

        const clear = B.clear;
        test clear {
            var b: Builder = undefined;
            var container = b.initBatch(&.{ MIN + 5, MIN + B.MAX_DIFFERENCE / 3, MIN + B.MAX_DIFFERENCE - 1 });
            try testing.expectEqual(container.cardinality, 3);
            try testing.expectEqual(container.clear().cardinality, 0);
            try testing.expect(!container.contains(MIN + 5));
        }

        test "word boundaries" {
            var b: Builder = undefined;
            var container = b.initBatch(&.{ va, vb });
            try testing.expect(container.containsBatch(&.{ va, vb }));
            try testing.expectEqual(container.cardinality, 2);
        }

        test "large values" {
            var b: Builder = undefined;
            const container = b.initBatch(&.{ MAX - 1, MAX - 2 });
            try testing.expect(container.contains(MAX - 1));
            try testing.expect(container.contains(MAX - 2));
            try testing.expectEqual(container.cardinality, 2);
        }

        const differenceWith = B.differenceWith;
        test differenceWith {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            var c1 = b.initBatch(&.{ MIN + 5, MIN + 10, MIN + 15 });
            _ = c1.differenceWith(b2.initBatch(&.{ MIN + 10, MIN + 15, MIN + 20 }));
            try testing.expect(c1.contains(MIN + 5));
            try testing.expect(!c1.containsBatch(&.{ MIN + 10, MIN + 15, MIN + 20 }));
            try testing.expectEqual(c1.cardinality, 1);
        }

        const xorWith = B.xorWith;
        test xorWith {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            var c1 = b.initBatch(&.{ MIN + 5, MIN + 10, MIN + 15 });
            _ = c1.xorWith(b2.initBatch(&.{ MIN + 10, MIN + 15, MIN + 20 }));
            try testing.expect(c1.contains(MIN + 5));
            try testing.expect(!c1.contains(MIN + 10));
            try testing.expect(!c1.contains(MIN + 15));
            try testing.expect(c1.contains(MIN + 20));
            try testing.expectEqual(c1.cardinality, 2);
        }

        const isEmpty = B.isEmpty;
        test isEmpty {
            var b: Builder = undefined;
            var container = b.init();
            try testing.expect(container.isEmpty());
            try testing.expect(!container.set(MIN + B.MAX_DIFFERENCE / 3).isEmpty());
        }

        const equals = B.equals;
        test equals {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            const c1 = b.initBatch(&.{ MIN + 5, MIN + 10 });
            var c2 = b2.initBatch(&.{ MIN + 5, MIN + 10 });
            try testing.expect(c1.equals(&c2));
            try testing.expect(!c1.equals(c2.set(MIN + 15)));
        }

        const copy = B.copy;
        test copy {
            var bsrc: Builder = undefined;
            var bdst: Builder = undefined;
            var dst = bdst.init();
            _ = dst.copy(bsrc.initBatch(&.{ MIN + 5, MIN + B.MAX_DIFFERENCE / 3, MIN + B.MAX_DIFFERENCE - 1 }));
            try testing.expect(dst.contains(MIN + 5));
            try testing.expect(dst.contains(MIN + B.MAX_DIFFERENCE / 3));
            try testing.expect(dst.contains(MIN + B.MAX_DIFFERENCE - 1));
            try testing.expectEqual(dst.cardinality, 3);
        }

        test "dense region" {
            var b: Builder = undefined;
            var container = b.init();
            const n = @min(MAX + 1, MIN + B.MAX_DIFFERENCE / 9);
            for (MIN..n) |i| _ = container.set(@intCast(i));
            try testing.expectEqual(n - MIN, @as(usize, container.cardinality));
            for (MIN..n) |i| try testing.expect(container.contains(@intCast(i)));
        }

        test "sparse region" {
            var b: Builder = undefined;
            const vs = &.{ MIN, MIN + B.MAX_DIFFERENCE / 3, MIN + B.MAX_DIFFERENCE / 2, MIN + B.MAX_DIFFERENCE - 1 };
            const container = b.initBatch(vs);
            try testing.expectEqual(4, container.cardinality);
            try testing.expect(container.containsBatch(vs));
        }

        test "alternating pattern" {
            var b: Builder = undefined;
            var container = b.init();
            const n = @min(MAX, MIN + (B.MAX_DIFFERENCE - 1) / 8);
            for (MIN..n) |i| {
                if (i % 2 == 0) _ = container.set(@intCast(i));
            }
            try testing.expectEqual((n - MIN) / 2 + (n & 1), container.cardinality);
            for (MIN..n) |i| {
                const expected = i % 2 == 0;
                try testing.expectEqual(expected, container.contains(@intCast(i)));
            }
        }

        test "multiple unions" {
            var b1: Builder = undefined;
            var b2: Builder = undefined;
            var b3: Builder = undefined;
            var c1 = b1.initBatch(&.{MIN + 5});
            _ = c1.unionWith(b2.initBatch(&.{MIN + 10}))
                .unionWith(b3.initBatch(&.{MIN + 15}));
            try testing.expectEqual(3, c1.cardinality);
            try testing.expect(c1.containsBatch(&.{ MIN + 5, MIN + 10, MIN + 15 }));
        }

        test "intersection with empty" {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            var c1 = b.initBatch(&.{ MIN + 5, MIN + 10 });
            try testing.expectEqual(0, c1.intersectWith(b2.init()).cardinality);
        }
    };
}

/// returns an empty bitset backed by `words`
pub fn bitset(
    min: comptime_int,
    max: comptime_int,
    Word: type,
    words: WordBitset(min, max, Word).WordsPtrAligned,
) WordBitset(min, max, Word) {
    return .init(words);
}

/// returns a bitset backed by `words` with the given batch of values
pub fn bitmapBatch(
    min: comptime_int,
    max: comptime_int,
    Word: type,
    words: WordBitset(min, max, Word).WordsPtrAligned,
    values: []const WordBitset(min, max, Word).Value,
) WordBitset(min, max, Word) {
    return .initBatch(words, values);
}

/// causes tests inside Bitmap(min, max, W) to be analyzed and run
fn testBitmap(min: comptime_int, max: comptime_int, W: type) !void {
    const Map = WordBitset(.{ .MIN = min, .MAX = max, .Word = W });
    var b: Map.Builder = undefined;
    _ = b.init();
    _ = b.initBatch(&.{});
}

test bitset {
    try testBitmap(0, 65535, u32);
    try testBitmap(0, 65536, u32);
    try testBitmap(0, 65535, u64);
    try testBitmap(0, 65536, u64);
    try testBitmap(0, 65535 / 2, u64);
    try testBitmap(0, 127, u64);
    try testBitmap(128, 255, u64);

    try testBitmap(0, 65535, u128);
    try testBitmap(0, 255, u128);

    try testBitmap(0, 65535, u256);
    try testBitmap(0, 255, u256);

    inline for (word_types) |word_type|
        try testBitmap(0, 65535, word_type);
}

test "small range - a...z" {
    const B = WordBitset(.{ .MIN = 'a', .MAX = 'z', .Word = u64 });
    var b: B.Builder = undefined;
    try testing.expect(b.initBatch(&.{ 'a', 'z' }).containsBatch(&.{ 'a', 'z' }));
    for ('b'..'z') |c| {
        try testing.expect(!b.bitset.contains(@intCast(c)));
    }
    try testing.expectEqual(2, b.bitset.cardinality);
}

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Io = std.Io;
const assert = std.debug.assert;
const build_options = @import("build-options");
