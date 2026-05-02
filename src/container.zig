/// Usually describes storage of an array, bitset or run container.
/// Also used to describe `Bitmap`.header, an `Array`.
/// In that case `blockoffset` is used to store num blocks since
/// `nblocks_minus1` is too small and the blockoffset, always 1, isn't needed.
pub const Container = packed struct(u64) {
    /// container cardinality / nruns.
    cardinality: u30,
    /// usually an offset into blocks where container data starts.
    /// when `Bitmap`.header, an `Array`: total number of blocks.
    blockoffset: u24, // 0..C.MAX_BLOCKS
    /// number of blocks in the array, bitset or run container minus one.
    nblocks_minus1: u8, // 0..255 => 1..256
    typecode: root.Typecode,

    pub const Id = enum(u32) { _ }; // TODO remove? doesn't seem necessary.
    /// FIXME: safety: use max value instead of 0 here: @bitCast(@as(u64, std.math.maxInt(u64)));
    pub const uninit: Container = @bitCast(@as(u64, 0)); // mem.zeroes(Container);
    pub const Cardinality = @FieldType(Container, "cardinality");
    /// used to identify a header Array
    pub const MAX_CARDINALITY = std.math.maxInt(Cardinality);
    pub const Element = union(root.Typecode) {
        shared: void,
        bitset: []align(C.BLOCK_ALIGN) u64,
        array: []align(C.BLOCK_ALIGN) u16,
        run: []align(C.BLOCK_ALIGN) root.Rle16,
    };

    /// TODO strat for reusing old blocks
    pub fn deinit(c: *Container, allocator: mem.Allocator, r: *Bitmap) void {
        _ = allocator; // autofix

        const blocks = c.get_blocks(r);
        @memset(blocks, @splat(0xFF));
        c.* = .uninit;
    }
    pub fn slice(c: Container, T: type, blocks: []align(C.BLOCK_ALIGN) Block) []align(C.BLOCK_ALIGN) T {
        return mem.bytesAsSlice(T, mem.sliceAsBytes(blocks[c.blockoffset..][0..c.nblocks()]));
    }
    pub fn nblocks(c: Container) u16 {
        return @as(u16, c.nblocks_minus1) + 1;
    }
    pub fn is_full(c: Container) bool {
        return switch (c.typecode) {
            .array => c.cardinality == c.nblocks() * C.BLOCK_LEN16,
            .bitset => unreachable,
            .run => unreachable,
            .shared => unreachable,
        };
    }
    pub fn get_blocks(c: Container, r: *const Bitmap) []Block {
        return r.blocks.items.ptr[c.blockoffset..][0..c.nblocks()];
    }
    /// return container blocks as aligned slice of u16 when typecode == .array etc.
    /// ignores container.cardinality.
    pub fn blocks_as(c: Container, comptime typecode: root.Typecode, r: *const Bitmap) @FieldType(Element, @tagName(typecode)) {
        // trace(@src(), "header={} c={}", .{ r.header, c });
        return @ptrCast(c.get_blocks(r));
    }
    pub fn get_cardinality(c: Container, r: *const Bitmap) u32 {
        return switch (c.typecode) {
            .bitset, .array => c.cardinality,
            .run => c.compute_cardinality(r),
            .shared => unreachable,
        };
    }

    // adapted from grow_capacity
    fn array_grow_nblocks(numblocks: u32) u32 {
        return if (numblocks == 0)
            0
        else if (numblocks < 4) // 64 / 16
            numblocks * 2
        else if (numblocks < 64) // 1024 / 16
            numblocks * 3 / 2
        else
            numblocks * 5 / 4;
    }

    pub fn array_container_grow(c: *Container, allocator: mem.Allocator, r: *Bitmap, minnblocks: u16, preserve: bool) !void {
        _ = allocator;
        // trace(@src(), "c={} nblocks(min={} max={})", .{ c, minnblocks, C.MAX_CONTAINER_BLOCKS });
        const newnblocks = std.math.clamp(array_grow_nblocks(c.nblocks()), minnblocks, C.MAX_CONTAINER_BLOCKS);

        if (preserve) {
            if (r.blocks.items.len + newnblocks <= r.blocks.capacity) {
                const blockoffset = r.blocks.items.len;
                const newblocks = r.blocks.addManyAsSliceAssumeCapacity(newnblocks);
                // trace(@src(), "newnblocks={} blocks.len={} c.blockoffset={}", .{ newnblocks, blockoffset, c.blockoffset });
                // trace(@src(), "\nnewblocks={any}\nc.blocks={any}", .{ newblocks, c.get_blocks(r) });
                @memcpy(newblocks[0..c.nblocks()], c.get_blocks(r));
                @memset(c.get_blocks(r), @splat(0xff));
                c.blockoffset = @intCast(blockoffset);
                c.nblocks_minus1 = @intCast(newnblocks - 1);
            } else {
                unreachable; // more blocks needed
            }
            //     container->array =
            //         (uint16_t *)roaring_realloc(array, new_capacity * sizeof(uint16_t));
            //     if (container->array == NULL) roaring_free(array);
        } else {
            unreachable;
            //     roaring_free(array);
            //     container->array =
            //         (uint16_t *)roaring_malloc(new_capacity * sizeof(uint16_t));
        }

        // if realloc fails, we have container->array == NULL.
    }

    pub fn append(c: *Container, allocator: mem.Allocator, r: *Bitmap, value: u16) !void {
        switch (c.typecode) {
            .array => {
                if (c.is_full()) {
                    try c.array_container_grow(allocator, r, c.nblocks() + 1, true);
                }

                const array = c.blocks_as(.array, r);
                array[c.cardinality] = value;
                c.cardinality += 1;
                // trace(@src(), "{any}", .{array[0..c.cardinality]});
            },
            .bitset => unreachable,
            .run => unreachable,
            .shared => unreachable,
        }
    }

    /// Add value to the set if final cardinality doesn't exceed max_cardinality.
    ///
    /// Return code:
    ///  * 1  -- value was added
    ///  * 0  -- value was already present
    ///  * -1 -- value was not added because cardinality would exceed max_cardinality
    pub fn try_add_array(ac: *Container, allocator: mem.Allocator, r: *Bitmap, value: u16, maxcard: u32) !i32 {
        // trace(@src(), "{}", .{ac});
        const array = ac.blocks_as(.array, r)[0..ac.cardinality];
        // best case, we can append.
        if ((ac.cardinality == 0 or value > array[ac.cardinality - 1]) and ac.cardinality < maxcard) {
            try ac.append(allocator, r, value);
            return 1;
        }

        const loc = misc.binarySearch(array, value);
        if (loc >= 0) {
            return 0;
        } else if (ac.cardinality < maxcard) {
            if (ac.is_full()) {
                try ac.array_container_grow(allocator, r, ac.nblocks() + 1, true);
            }
            const insertidx: u32 = @intCast(-loc - 1);
            const array1 = ac.blocks_as(.array, r);
            @memmove(array1.ptr + insertidx + 1, array1[insertidx..]);
            array1[insertidx] = value;
            ac.cardinality += 1;
            return 1;
        } else {
            return -1;
        }
    }
    const Words = @FieldType(Element, "bitset");
    /// Set the ith bit.
    pub fn bitset_container_set(bc: *Container, pos: u16, words: Words) void {
        const old_word = words[pos >> 6];
        const index: u6 = @truncate(pos & 63);
        const new_word = old_word | (@as(u64, 1) << index);
        bc.cardinality += @intCast((old_word ^ new_word) >> index);
        words[pos >> 6] = new_word;
    }

    /// convert ac to a bitset in place.
    pub fn bitset_container_from_array(
        ac: *Container,
        allocator: mem.Allocator,
        r: *Bitmap,
    ) !Container {
        var bc: Container = .{
            .typecode = .bitset,
            .nblocks_minus1 = C.BITSET_BLOCKS - 1,
            .blockoffset = ac.blockoffset,
            .cardinality = 0,
        };

        // copy ac to temporary
        assert(ac.nblocks() == C.BITSET_BLOCKS);
        var ac1 = ac.*;
        ac1.blockoffset = @intCast(r.blocks.items.len);
        _ = try r.blocks.addManyAsSlice(allocator, C.BITSET_BLOCKS);
        @memcpy(ac1.get_blocks(r), ac.get_blocks(r));

        const words = bc.blocks_as(.bitset, r);
        @memset(bc.get_blocks(r), @splat(0));
        for (ac1.blocks_as(.array, r)) |v| {
            bc.bitset_container_set(v, words);
        }
        // trace(@src(), "bcard/acard={}-{}/{}", .{ bc.compute_cardinality(r), bc.cardinality, ac.cardinality });
        assert(bc.compute_cardinality(r) == bc.cardinality);

        r.blocks.items.len = ac1.blockoffset; // recycle ac1

        return bc;
    }

    /// Note: when an array container becomes full, it is converted to a bitset in place.
    pub fn add(c: *Container, allocator: mem.Allocator, r: *Bitmap, value: u16) !Container {
        // TODO // c = c.get_writable_copy_if_shared();
        switch (c.typecode) {
            .bitset => {
                c.bitset_container_set(value, c.blocks_as(.bitset, r));
                return c.*;
            },
            .array => {
                const addres = try c.try_add_array(allocator, r, value, C.DEFAULT_MAX_SIZE);
                if (addres != -1) {
                    return c.*;
                } else {
                    var bitset = try c.bitset_container_from_array(allocator, r);
                    assert(bitset.cardinality == c.cardinality);
                    bitset.bitset_container_set(value, c.blocks_as(.bitset, r));
                    return bitset;
                }
            },
            .run => unreachable,
            .shared => unreachable,
        }
    }

    pub fn serialized_size_in_bytes(c: Container) u32 {
        return switch (c.typecode) {
            .array => @sizeOf(u16) * c.cardinality,
            .run => @sizeOf(u16) + @sizeOf(root.Rle16) * c.cardinality,
            .bitset => @sizeOf(root.Bitset),
            .shared => unreachable,
        };
    }
    pub const size_in_bytes = serialized_size_in_bytes;

    pub fn equals(c1: Container, c2: Container, r1: *const Bitmap, r2: *const Bitmap) bool {
        if (c1 == c2) return true;
        const card1 = c1.cardinality;
        if (c1.typecode != c2.typecode or card1 != c2.cardinality)
            return false;

        return switch (c1.typecode) {
            .array => mem.eql(
                u16,
                c1.blocks_as(.array, r1)[0..card1],
                c2.blocks_as(.array, r2)[0..card1],
            ),
            .run => mem.eql(
                u32,
                @ptrCast(c1.blocks_as(.run, r1)[0..card1]),
                @ptrCast(c2.blocks_as(.run, r2)[0..card1]),
            ),
            .bitset => mem.eql(
                u64,
                c1.blocks_as(.bitset, r1),
                c2.blocks_as(.bitset, r2),
            ),
            .shared => unreachable,
        };
    }

    pub fn compute_cardinality(v: Container, r: *const Bitmap) u30 {
        var ret: u30 = undefined;
        switch (v.typecode) {
            .bitset => {
                ret = 0;
                for (v.blocks_as(.bitset, r)) |word| {
                    ret += @popCount(word);
                }
            },
            .array => ret = @intCast(v.cardinality),
            .run => {
                ret = v.cardinality; // init with nruns
                for (v.blocks_as(.run, r)[0..v.cardinality]) |run| {
                    ret += run.length;
                }
            },
            .shared => unreachable,
        }
        return ret;
    }

    pub fn internal_validate(v: Container, reason: *?[]const u8, r: *const Bitmap) bool {
        // Not using container_unwrap_shared because it asserts if shared containers
        // are nested
        switch (v.typecode) {
            .shared => {
                unreachable; // TODO
                // const shared_container_t *shared_container =
                //     const_CAST_shared(container);
                // if (croaring_refcount_get(&shared_container.counter) == 0) {
                //     reason.* = "shared container has zero refcount";
                //     return false;
                // }
                // if (shared_container.typecode == shared) {
                //     reason.* = "shared container is nested";
                //     return false;
                // }
                // if (shared_container.container.is_null()) {
                //     reason.* = "shared container has NULL container";
                //     return false;
                // }
                // container = shared_container.container;
                // typecode = shared_container.typecode;
            },
            .bitset => {
                if (!(0 < v.cardinality and v.cardinality <= C.DEFAULT_MAX_SIZE * 2)) { // <= 8192
                    reason.* = "bitset cardinality";
                    return false;
                }
                const cc = v.compute_cardinality(r);
                if (v.cardinality != cc) {
                    trace(@src(), "{} != {}", .{ v.cardinality, cc });
                    reason.* = "bitset cardinality is incorrect";
                    return false;
                }
                if (v.cardinality <= C.DEFAULT_MAX_SIZE) {
                    reason.* = "cardinality is too small for a bitmap container";
                    return false;
                }

                // Attempt to forcibly load the first and last words, hopefully causing
                // a segfault or an address sanitizer error if words is not allocated.
                mem.doNotOptimizeAway(r.blocks.items[v.blockoffset]);
                mem.doNotOptimizeAway(r.blocks.items[v.blockoffset + C.BITSET_BLOCKS - 1]);
                return true;
            },
            .array => {
                if (!(v.cardinality <= v.nblocks() * C.BLOCK_BYTES / @sizeOf(u16))) {
                    reason.* = "array cardinality";
                    return false;
                }
                if (v.cardinality > C.DEFAULT_MAX_SIZE) {
                    reason.* = "cardinality exceeds DEFAULT_MAX_SIZE";
                    return false;
                }
                if (v.cardinality == 0) {
                    reason.* = "zero cardinality";
                    return false;
                }

                const array = v.blocks_as(.array, r);
                var prev = array[0];
                for (1..v.cardinality) |i| {
                    if (prev >= array[i]) {
                        reason.* = "array elements not strictly increasing";
                        return false;
                    }
                    prev = array[i];
                }

                return true;
            },
            .run => {
                unreachable;
            },
            // .array => return c.payload.internal_validate(reason, r),
            // .run => return c.payload.run.internal_validate(reason, r),
            // return container.validate(reason),
            //     bitset =>
            //         return bitset_container_validate(const_CAST_bitset(container),
            //                                          reason);
            // array =>
            //         return array_container_validate(const_CAST_array(container),
            //                                         reason);
            //         run =>
            //         return run_container_validate(const_CAST_run(container), reason);
            // _ => { // TODO?
            //     reason.* = "invalid typecode";
            //     return false;
            // },
        }
    }

    // assumes that container has adequate space.  Run from [s,e] (inclusive)
    pub fn add_run(rc: *Container, s: u16, e: u16, r: *const Bitmap) void {
        const runs = rc.blocks_as(.run, r);
        runs[rc.cardinality].value = s;
        runs[rc.cardinality].length = e - s;
        rc.cardinality += 1;
    }
};

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const root = @import("root.zig");
const Block = root.Block;
const Typecode = root.Typecode;
const Bitmap = root.Bitmap;
const C = @import("constants.zig");
const misc = @import("misc.zig");
const trace = misc.trace;
