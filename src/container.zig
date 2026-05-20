/// A generic container stored as blocks.
///
/// Describes storage of an array, bitset or run container.
pub const Container = packed struct(u64) {
    /// cached container cardinality or nruns.
    cardinality: u30,
    /// a `Container` offset into Bitmap blocks.  [0, C.MAX_BLOCKS).
    blockoffset: u24,
    /// number of blocks in the array, bitset or run container minus one.
    /// 0..255 => 1..256
    nblocks_minus1: u8,
    typecode: root.Typecode,

    pub const uninit: Container = @bitCast(@as(u64, std.math.maxInt(u64)));
    pub const Cardinality = @FieldType(Container, "cardinality");
    pub const Element = union(root.Typecode) {
        shared: void,
        bitset: []align(C.BLOCK_ALIGN) u64,
        array: []align(C.BLOCK_ALIGN) u16,
        run: []align(C.BLOCK_ALIGN) root.Rle16,
    };

    /// TODO strat for reusing old blocks
    pub fn deinit(c: *Container, allocator: mem.Allocator, r: *Bitmap) void {
        _ = allocator; // autofix

        const blocks = c.get_blocks(r.*);
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
            .bitset => c.cardinality == C.MAX_KEY_CARDINALITY,
            .run => unreachable,
            .shared => unreachable,
        };
    }

    pub fn get_blocks(c: Container, r: Bitmap) []Block {
        return r.array.ptr(.blocks)[c.blockoffset..][0..c.nblocks()];
    }

    /// return container blocks as aligned slice of u16 when typecode == .array etc.
    /// ignores container.cardinality.
    pub fn blocks_as(c: Container, comptime typecode: root.Typecode, r: Bitmap) @FieldType(Element, @tagName(typecode)) {
        return @ptrCast(c.get_blocks(r));
    }

    pub fn get_cardinality(c: Container, r: Bitmap) u32 {
        return switch (c.typecode) {
            .bitset, .array => c.cardinality,
            .run => c.compute_cardinality(r),
            .shared => unreachable,
        };
    }

    fn grow_capacity(capacity: u32) u32 {
        return if (capacity == 0)
            0
        else if (capacity < 64)
            capacity * 2
        else if (capacity < 1024)
            capacity * 3 / 2
        else
            capacity * 5 / 4;
    }

    fn assert_valid(c: *Container, r: Bitmap) void {
        if (!(builtin.is_test or builtin.mode == .Debug)) return;
        var reason: ?[]const u8 = null;
        if (!c.internal_validate(&reason, r)) {
            trace(@src(), "{s}", .{reason.?});
            trace(@src(), "{f}", .{c.fmt(r)});
            switch (c.typecode) {
                .array => trace(@src(), "{any}", .{c.blocks_as(.array, r)[0..c.cardinality]}),
                .bitset => {},
                .run => {},
                .shared => {},
            }

            unreachable;
        }
    }

    /// add blocks to a container: extend, move following blocks forward, update
    /// affected container blockoffsets
    pub fn array_container_grow(c: *Container, allocator: mem.Allocator, r: *Bitmap, mincapacity: u32, preserve: bool) !void {
        const max: u32 = if (mincapacity <= C.DEFAULT_MAX_SIZE) C.DEFAULT_MAX_SIZE else C.MAX_CONTAINERS;
        const newcap = std.math.clamp(grow_capacity(c.cardinality), mincapacity, max);
        const morecap = newcap - c.cardinality;
        const moreblocks = morecap / C.BLOCK_LEN16;

        const cid = c - r.array.ptr(.containers);
        // trace(@src(), "newcap={} morecap={} moreblocks={} cid={}", .{ newcap, morecap, moreblocks, cid });
        if (preserve) {
            // TODO move this logic to extend_array?
            if (r.array.ptr(.blockslen).* + c.nblocks() + moreblocks >=
                r.array.ptr(.blockscapacity).*)
            {
                try r.extend_array(allocator, 0, moreblocks);
            }
            // move blocks and update blocks info
            const blocks = r.slice(.blocks, .blockscapacity);
            const c2 = &r.array.ptr(.containers)[cid];
            const rest = blocks[c2.blockoffset + c2.nblocks() ..];
            @memmove(rest.ptr + moreblocks, rest);
            c2.nblocks_minus1 += @intCast(moreblocks);
            r.array.ptr(.blockslen).* += moreblocks;

            // update blockoffsets of containers with moved blocks
            for (r.slice(.containers, .len)) |*c3| {
                if (c3.blockoffset <= c2.blockoffset) continue;
                c3.blockoffset += @intCast(moreblocks);
            }
        } else {
            unreachable; // TODO !preserve
        }
    }

    pub fn append(c: *Container, allocator: mem.Allocator, r: *Bitmap, value: u16) !void {
        switch (c.typecode) {
            .array => {
                const cid = c - r.array.ptr(.containers);
                if (c.is_full()) {
                    try c.array_container_grow(allocator, r, c.cardinality + 1, true);
                }

                const c2 = &r.array.ptr(.containers)[cid];
                const array = c2.blocks_as(.array, r.*);
                array[c2.cardinality] = value;
                c2.cardinality += 1;
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
        const array = ac.blocks_as(.array, r.*)[0..ac.cardinality];
        // best case, we can append.
        if ((ac.cardinality == 0 or value > array[ac.cardinality - 1]) and ac.cardinality < maxcard) {
            try ac.append(allocator, r, value);
            return 1;
        }
        const loc = misc.binarySearch(array, value);
        if (loc >= 0) {
            return 0;
        } else if (ac.cardinality < maxcard) {
            const acid = ac - r.array.ptr(.containers);
            if (ac.is_full()) {
                try ac.array_container_grow(allocator, r, ac.cardinality + 1, true);
            }

            const ac2 = &r.array.ptr(.containers)[acid];
            const array1 = ac2.blocks_as(.array, r.*)[0..ac2.cardinality];
            // trace(@src(), "inserting value={} at index {} array={any}", .{ value, insertidx, array });

            const insertidx: u32 = @intCast(-loc - 1);
            @memmove(array1.ptr + insertidx + 1, array1[insertidx..]);
            array1[insertidx] = value;
            ac2.cardinality += 1;
            assert_valid(ac2, r.*);
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
        const acid = ac - r.array.ptr(.containers);
        ac1.blockoffset = @intCast(r.array.ptr(.blockslen).*);
        try r.extend_array(allocator, 1, C.BITSET_BLOCKS);
        const blocks = ac1.get_blocks(r.*);
        @memcpy(blocks, r.array.ptr(.containers)[acid].get_blocks(r.*));

        const words = bc.blocks_as(.bitset, r.*);
        @memset(bc.get_blocks(r.*), @splat(0));
        for (ac1.blocks_as(.array, r.*)) |v| {
            bc.bitset_container_set(v, words);
        }
        // trace(@src(), "bcard/acard={}-{}/{}", .{ bc.compute_cardinality(r), bc.cardinality, ac.cardinality });
        assert(bc.compute_cardinality(r.*) == bc.cardinality);

        r.array.ptr(.blockslen).* = ac1.blockoffset; // recycle ac1

        return bc;
    }

    /// Note: when an array container becomes full, it is converted to a bitset in place.
    pub fn add(c: *Container, allocator: mem.Allocator, r: *Bitmap, value: u16) !Container {
        // TODO // c = c.get_writable_copy_if_shared();
        switch (c.typecode) {
            .bitset => {
                c.bitset_container_set(value, c.blocks_as(.bitset, r.*));
                return c.*;
            },
            .array => {
                const cid = c - r.array.ptr(.containers);
                const add_res = try c.try_add_array(allocator, r, value, C.DEFAULT_MAX_SIZE);
                if (add_res != -1) {
                    return r.array.ptr(.containers)[cid];
                } else {
                    var bitset = try c.bitset_container_from_array(allocator, r);
                    assert(bitset.cardinality == r.array.ptr(.containers)[cid].cardinality);
                    bitset.bitset_container_set(value, r.array.ptr(.containers)[cid].blocks_as(.bitset, r.*));
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

    pub fn equals(c1: Container, c2: Container, r1: Bitmap, r2: Bitmap) bool {
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

    pub fn compute_cardinality(v: Container, r: Bitmap) u30 {
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

    pub fn internal_validate(v: Container, reason: *?[]const u8, r: Bitmap) bool {
        if (v.cardinality == 0) {
            reason.* = "container is empty";
            return false;
        }

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
                if (!(0 < v.cardinality and v.cardinality <= C.MAX_KEY_CARDINALITY)) { // <= 65536
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
                mem.doNotOptimizeAway(r.array.ptr(.blocks)[v.blockoffset]);
                mem.doNotOptimizeAway(r.array.ptr(.blocks)[v.blockoffset + C.BITSET_BLOCKS - 1]);
                return true;
            },
            .array => {
                if (!(v.cardinality <= v.nblocks() * C.BLOCK_LEN16)) {
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
                        trace(@src(), "array elements: {any}", .{array[0..v.cardinality]});
                        return false;
                    }
                    prev = array[i];
                }

                return true;
            },
            .run => {
                unreachable;
            },
        }
    }

    // assumes that container has adequate space.  Run from [s,e] (inclusive)
    pub fn add_run(rc: *Container, s: u16, e: u16, r: Bitmap) void {
        const runs = rc.blocks_as(.run, r);
        runs[rc.cardinality].value = s;
        runs[rc.cardinality].length = e - s;
        rc.cardinality += 1;
    }

    /// Get the value of the ith bit.
    pub fn bitset_container_get(words: [*]root.Word, pos: u16) bool {
        const word = words[pos >> 6];
        return (word >> @truncate(pos & 63)) & 1 != 0;
    }

    /// Returns the index of x , if not exsist return -1
    pub fn bitset_container_get_index(container: Container, x: u16, r: Bitmap) i32 {
        const words = container.blocks_as(.bitset, r);
        if (bitset_container_get(words.ptr, x)) {
            // credit: aqrit
            var sum: i32 = 0;
            var i: i32 = 0;
            const end = x / 64;
            while (i < end) : (i += 1) {
                sum += @popCount(words[@intCast(i)]);
            }
            const lastword = words[@intCast(i)];
            const lastpos = @as(u64, 1) << @truncate(x % 64);
            const mask = lastpos + lastpos - 1; // smear right
            sum += @popCount(lastword & mask);
            return sum - 1;
        } else {
            return -1;
        }
    }

    /// Returns the index of x , if not exsist return -1
    pub fn array_container_get_index(arr: Container, x: u16, r: Bitmap) i32 {
        const array = arr.blocks_as(.array, r)[0..arr.cardinality];
        const idx = misc.binarySearch(array, x);
        return if (idx >= 0) idx else -1;
    }

    /// Check whether `pos' is present in `runs'.
    pub fn run_container_contains(runs: []align(C.BLOCK_ALIGN) root.Rle16, pos: u16) bool {
        var index = misc.interleavedBinarySearch(runs, pos);
        if (index >= 0) return true;
        index = -index - 2; // points to preceding value, possibly -1
        if (index != -1) { // possible match
            const run = runs[@intCast(index)];
            const offset: i32 = pos - run.value;
            const le: i32 = run.length;
            if (offset <= le) return true;
        }
        return false;
    }

    pub fn run_container_get_index(container: Container, x: u16, r: Bitmap) i32 {
        const runs = container.blocks_as(.run, r)[0..container.cardinality];
        if (run_container_contains(runs, x)) {
            var sum: i32 = 0;
            const x32: u32 = x;
            for (0..container.cardinality) |i| {
                const startpoint: u32 = runs[i].value;
                const length: u32 = runs[i].length;
                const endpoint: u32 = length + startpoint;
                if (x <= endpoint) {
                    if (x < startpoint) break;
                    return sum + @as(i32, @intCast(x32 - startpoint));
                } else {
                    sum += @intCast(length + 1);
                }
            }
            return sum - 1;
        } else {
            return -1;
        }
    }

    // return the index of x, if not exsist return -1
    pub fn get_index(c: Container, x: u16, r: Bitmap) i32 {
        // c = container_unwrap_shared(c, &type); // TODO
        return switch (c.typecode) {
            .bitset => c.bitset_container_get_index(x, r),
            .array => c.array_container_get_index(x, r),
            .run => c.run_container_get_index(x, r),
            .shared => unreachable,
        };
    }

    /// Check whether a value is in a container
    pub fn contains(c: Container, val: u16, r: Bitmap) bool {
        // c = container_unwrap_shared(c, &typecode); // TODO
        return switch (c.typecode) {
            .bitset => bitset_container_get(c.blocks_as(.bitset, r).ptr, val),
            .array => misc.binarySearch2(c.blocks_as(.array, r)[0..c.cardinality], val) >= 0,
            .run => run_container_contains(c.blocks_as(.run, r)[0..c.cardinality], val),
            .shared => unreachable,
        };
    }

    pub const fmt = Fmt.init;
    pub const Fmt = struct {
        r: Bitmap,
        c: Container,

        pub fn format(f: Fmt, w: *std.Io.Writer) !void {
            if (f.c == Container.uninit) {
                try w.writeAll("uninit");
                return;
            }
            switch (f.c.typecode) {
                inline .array, .run => |typecode| {
                    const vals0 = f.c.blocks_as(typecode, f.r);
                    const vals = if (f.c.cardinality <= vals0.len) vals0[0..f.c.cardinality] else &.{};
                    try w.print("{t} {?}..{?} : {}", .{
                        typecode,
                        if (vals.len > 0) vals[0] else null,
                        if (vals.len > 1) vals[vals.len - 1] else null,
                        vals.len,
                    });
                },
                .bitset => {
                    try w.print("bitset cardinality={}", .{f.c.cardinality});
                },
                .shared => {
                    try w.writeAll("TODO: shared");
                },
            }
        }
        pub fn init(c: Container, r: Bitmap) Fmt {
            return .{ .c = c, .r = r };
        }
    };
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
const builtin = @import("builtin");
