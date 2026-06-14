/// A generic container stored as blocks.
///
/// Describes storage of an array, bitset or run container.
pub const Container = packed struct(u64) {
    /// cached container cardinality or nruns. u30 (or u29 when -Dcpu=baseline)
    cardinality: Cardinality,
    /// an offset into Bitmap blocks. u24 (or u25 when -Dcpu=baseline). [0, C.MAX_BLOCKS).
    blockoffset: BlockOffset,
    /// number of blocks in the array, bitset or run container minus one.  u8.  [0, C.BITSET_BLOCKS).
    /// 0..255 => 1..256
    nblocks_minus1: BlockIndex,
    typecode: root.Typecode,

    pub const uninit: Container = @bitCast(@as(u64, std.math.maxInt(u64)));
    pub const Cardinality = @Int(.unsigned, 64 - @bitSizeOf(BlockOffset) - @bitSizeOf(BlockIndex) - @bitSizeOf(Typecode));
    pub const ICardinality = @Int(.signed, @bitSizeOf(Cardinality));
    pub const BlockOffset = std.math.IntFittingRange(0, C.MAX_BLOCKS - 1);
    pub const BlockIndex = std.math.IntFittingRange(0, C.BITSET_BLOCKS - 1);
    pub const Element = union(root.Typecode) {
        shared: void,
        bitset: []align(C.BLOCK_ALIGN) u64,
        array: []align(C.BLOCK_ALIGN) u16,
        run: []align(C.BLOCK_ALIGN) root.Rle16,
    };

    /// TODO reclaim in shrink_to_fit()
    pub fn deinit(c: *Container, r: Bitmap) void {
        if (c.* == uninit) return;
        r.remove_at_index(@intCast(c - r.array.ptr(.containers)));
    }

    pub fn deinit_blocks(c: Container, r: Bitmap) void {
        @memset(c.get_blocks(r), @splat(0xFF));
    }

    pub fn slice(c: Container, T: type, blocks: []align(C.BLOCK_ALIGN) Block) []align(C.BLOCK_ALIGN) T {
        return mem.bytesAsSlice(T, mem.sliceAsBytes(blocks[c.blockoffset..][0..c.nblocks()]));
    }

    pub fn nblocks(c: Container) u16 {
        return @as(u16, c.nblocks_minus1) + 1;
    }

    pub fn is_at_capacity(c: Container) bool {
        return switch (c.typecode) {
            .array, .run => c.cardinality == c.calc_capacity(),
            .bitset => unreachable, // nonsense. bitset is always at capacity.
            .shared => unreachable,
        };
    }

    pub fn get_blocks(c: Container, r: Bitmap) []Block {
        return r.array.ptr(.blocks)[c.blockoffset..][0..c.nblocks()];
    }

    /// return container blocks as aligned slice of u16 when typecode == .array etc.
    /// ignores container.cardinality.
    pub fn blocks_as(
        c: Container,
        comptime typecode: root.Typecode,
        r: Bitmap,
    ) @FieldType(Element, @tagName(typecode)) {
        // FIXME: check for stack pointers or when c isn't parented in r
        // if ((builtin.is_test or builtin.mode == .Debug))
        //     assert(c.nblocks() + c.blockoffset <= r.array.ptr(.blockslen).*);
        return @ptrCast(c.get_blocks(r));
    }

    pub fn get_cardinality(c: Container, r: Bitmap) Cardinality {
        return switch (c.typecode) {
            .bitset, .array => c.cardinality,
            .run => run_container_cardinality(c, c.blocks_as(.run, r).ptr),
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
            trace(@src(), "{f}", .{c.fmtLong(r, c.get_key(r))});
            unreachable;
        }
    }

    /// modify conatiner so it can hold additional moreblocks.
    ///
    /// moves all blocks after c's blocks forward and modifies all affected
    /// container blockoffsets.
    fn add_container_blocks(
        r: *Bitmap,
        allocator: Allocator,
        c: *Container,
        moreblocks: u32,
    ) !void {
        assert(moreblocks != 0);
        // TODO move this logic to ensure_unused_capacity?
        const cid = c - r.array.ptr(.containers);
        const blockslen = r.array.ptr(.blockslen).*;
        if (blockslen + moreblocks >= r.array.ptr(.blockscapacity).*) {
            try r.ensure_unused_capacity(allocator, 0, moreblocks);
        }
        // move blocks and update blocks info
        const blocks = r.slice(.blocks, .blockscapacity);
        const c2 = &r.array.ptr(.containers)[cid];
        const rest = blocks[c2.blockoffset + c2.nblocks() .. blockslen];
        @memmove(rest.ptr + moreblocks, rest);
        c2.nblocks_minus1 += @intCast(moreblocks);
        r.array.ptr(.blockslen).* += moreblocks;

        // update blockoffsets of containers with moved blocks
        for (r.slice(.containers, .len)) |*c3| {
            // consider limiting loop and remove .uninit check w/out a noisy len param.
            if (c3.blockoffset <= c2.blockoffset or c3.* == uninit)
                continue;
            c3.blockoffset += @intCast(moreblocks);
        }
    }

    /// add enough blocks to container to hold mincapacity.
    ///
    /// mincapacity: number of array container values.
    ///
    /// preserve: preserve block contents. when true use add_container_blocks().
    /// when false, deinit blocks and extend array.
    pub fn array_container_grow(
        ac: *Container,
        allocator: Allocator,
        r: *Bitmap,
        mincapacity: u32,
        preserve: bool,
    ) !void {
        const max: u32 = if (mincapacity <= C.DEFAULT_MAX_SIZE)
            C.DEFAULT_MAX_SIZE
        else
            C.MAX_CONTAINERS;
        const cap = ac.calc_capacity();
        const newcap = std.math.clamp(grow_capacity(cap), mincapacity, max);
        const morecap = newcap - cap;
        const moreblocks = misc.numGroupsOfSize(morecap, C.BLOCK_LEN16);
        if (preserve) {
            try add_container_blocks(r, allocator, ac, moreblocks);
        } else if (moreblocks != 0) {
            // move container blocks to the end of blocks without copying contents
            ac.deinit_blocks(r.*);
            const acid = ac - r.array.ptr(.containers);
            try r.ensure_unused_capacity(allocator, 0, ac.nblocks() + moreblocks);
            const ac1 = &r.array.ptr(.containers)[acid];
            ac1.blockoffset = @intCast(r.array.ptr(.blockslen).*);
            ac1.nblocks_minus1 += @intCast(moreblocks);
            r.array.ptr(.blockslen).* += ac1.nblocks();
        }
    }

    // min: (n_runs) is clamped from [0,C.BITSET_BLOCKS).
    //
    // asserts that `rc` needs to grow to hold `min` runs.
    pub fn run_container_grow(
        rc: *Container,
        allocator: Allocator,
        min: u32,
        copy: bool,
        r: *Bitmap,
    ) !void {
        const runcap = rc.calc_capacity();
        assert(runcap < min);
        const newcap = @max(min, if (runcap == 0)
            0
        else if (runcap < 64)
            runcap * 2
        else if (runcap < 1024)
            runcap * 3 / 2
        else
            runcap * 5 / 4);
        const morecap = newcap - runcap;
        const moreblocks = @min(
            C.BITSET_BLOCKS - rc.nblocks(),
            misc.numGroupsOfSize(morecap, C.BLOCK_LEN32),
        );

        if (rc.* == uninit) {
            rc.* = try run_container_create_given_capacity(allocator, newcap, r);
        } else if (moreblocks != 0) { // moreblocks might be 0 if already at capacity.
            if (copy) {
                try add_container_blocks(r, allocator, rc, moreblocks);
            } else { // move container blocks to the end of blocks without copying contents
                rc.deinit_blocks(r.*);
                const rcid = rc - r.array.ptr(.containers);
                try r.ensure_unused_capacity(allocator, 0, rc.nblocks() + moreblocks);
                const rc1 = &r.array.ptr(.containers)[rcid];
                rc1.blockoffset = @intCast(r.array.ptr(.blockslen).*);
                rc1.nblocks_minus1 += @intCast(moreblocks);
                r.array.ptr(.blockslen).* += rc1.nblocks();
            }
        }
    }

    pub fn append(c: *Container, allocator: Allocator, r: *Bitmap, value: u16) !void {
        switch (c.typecode) {
            .array => {
                const cid = c - r.array.ptr(.containers);
                if (c.is_at_capacity()) {
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
    pub fn array_container_try_add(
        ac: *Container,
        allocator: Allocator,
        r: *Bitmap,
        value: u16,
        maxcard: u32,
    ) !i32 {
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
            if (ac.is_at_capacity()) {
                try ac.array_container_grow(allocator, r, ac.cardinality + 1, true);
            }

            const ac2 = &r.array.ptr(.containers)[acid];
            const array2 = ac2.blocks_as(.array, r.*)[0..ac2.cardinality];
            const insertidx: u32 = @intCast(-loc - 1);
            // trace(@src(), "inserting value={} at index {} array={any}", .{ value, insertidx, array });
            @memmove(array2.ptr + insertidx + 1, array2[insertidx..]);
            array2[insertidx] = value;
            ac2.cardinality += 1;
            ac2.assert_valid(r.*);
            return 1;
        }
        return -1;
    }

    const Words = @FieldType(Element, "bitset");

    /// Set the ith bit.  increments cardinality if pos not found.
    fn bitset_container_set(bc: *Container, pos: u16, words: Words) void {
        const old_word = words[pos >> 6];
        const index: u6 = @truncate(pos & 63);
        const new_word = old_word | (@as(u64, 1) << index);
        bc.cardinality += @intCast((old_word ^ new_word) >> index);
        words[pos >> 6] = new_word;
    }

    /// Add `pos' to `bitset'. Returns true if `pos' was not present. Might be slower
    /// than bitset_container_set.
    fn bitset_container_add(bc: *Container, pos: u16, words: Words) bool {
        const old_word = words[pos >> 6];
        const index: u6 = @truncate(pos & 63);
        const new_word = old_word | (@as(u64, 1) << index);
        const increment = (old_word | new_word) >> index;
        bc.cardinality += @intCast(increment);
        words[pos >> 6] = new_word;
        return increment > 0;
    }

    /// Moves the data so that we can write data at index
    fn makeRoomAtIndex(run: *Container, allocator: Allocator, r: *Bitmap, index: u16) !void {
        // This function calls realloc + memmove sequentially to move by one index.
        // Potentially copying the array twice.
        const cindex = run - r.array.ptr(.containers);
        if (run.cardinality + 1 > run.calc_capacity())
            try run.run_container_grow(allocator, run.cardinality + 1, true, r);

        const run2 = &r.array.ptr(.containers)[cindex];
        const runs = run2.blocks_as(.run, r.*).ptr;
        @memmove(runs + 1 + index, (runs + index)[0 .. run2.cardinality - index]);
        run2.cardinality += 1;
    }

    /// Add all values in range [min, max] using hint.
    pub fn run_container_add_range_nruns(
        run: *Container,
        allocator: Allocator,
        r: *Bitmap,
        min: u32,
        max: u32,
        nruns_less: u32,
        nruns_greater: u32,
    ) !void {
        const nruns_common = run.cardinality - nruns_less - nruns_greater;
        if (nruns_common == 0) {
            const cid = run - r.array.ptr(.containers);
            try run.makeRoomAtIndex(allocator, r, @truncate(nruns_less));
            const run2 = r.array.ptr(.containers)[cid];
            const runs = run2.blocks_as(.run, r.*)[0..run2.cardinality];
            runs.ptr[nruns_less] = .{
                .value = @truncate(min),
                .length = @truncate(max - min),
            };
        } else {
            const runs = run.blocks_as(.run, r.*)[0..run.cardinality];
            const common_min = runs[nruns_less].value;
            const common_max = runs[nruns_less + nruns_common - 1].value +
                runs[nruns_less + nruns_common - 1].length;
            const result_min = if (common_min < min) common_min else min;
            const result_max = if (common_max > max) common_max else max;

            runs[nruns_less].value = @truncate(result_min);
            runs[nruns_less].length = @truncate((result_max - result_min));

            @memmove(
                runs.ptr + nruns_less + 1,
                runs[run.cardinality - nruns_greater ..][0..nruns_greater],
            );
            run.cardinality = @intCast(nruns_less + 1 + nruns_greater);
        }
    }

    pub fn run_container_add(
        run: *Container,
        allocator: Allocator,
        pos: u16,
        r: *Bitmap,
    ) !bool {
        const runs = run.blocks_as(.run, r.*)[0..run.cardinality];
        const cindex = run - r.array.ptr(.containers);
        var mindex = misc.interleavedBinarySearch(runs, pos);
        if (mindex >= 0) return false; // already there
        mindex = -mindex - 2; // points to preceding value, possibly -1
        const index: u32 = @bitCast(mindex);
        if (mindex >= 0) { // possible match
            const offset: i32 = pos - runs[index].value;
            const le: i32 = runs[index].length;
            if (offset <= le) return false; // already there
            if (offset == le + 1) {
                // we may need to fuse
                if (index + 1 < run.cardinality) {
                    if (runs[index + 1].value == pos + 1) {
                        // indeed fusion is needed
                        runs[index].length = runs[index + 1].value +
                            runs[index + 1].length -
                            runs[index].value;
                        r.recoverRoomAtIndex(run, @intCast(index + 1));
                        return true;
                    }
                }
                runs[index].length += 1;
                return true;
            }
            if (index + 1 < run.cardinality) {
                // we may need to fuse
                if (runs[index + 1].value == pos + 1) {
                    // indeed fusion is needed
                    runs[index + 1].value = pos;
                    runs[index + 1].length = runs[index + 1].length + 1;
                    return true;
                }
            }
        }
        if (mindex == -1) {
            // we may need to extend the first run
            if (run.cardinality > 0) {
                if (runs[0].value == pos + 1) {
                    runs[0].length += 1;
                    runs[0].value -= 1;
                    return true;
                }
            }
        }
        // trace(@src(), "index={} cindex={} {f}", .{ mindex, cindex, run.fmt(r.*) });
        try run.makeRoomAtIndex(allocator, r, @intCast(index +% 1));
        const run2 = &r.array.ptr(.containers)[cindex];
        const runs2 = run2.blocks_as(.run, r.*);
        runs2[index +% 1] = .{ .value = pos, .length = 0 };
        return true;
    }

    pub fn get_key(c: *Container, r: Bitmap) u16 {
        return r.array.ptr(.keys)[c - r.array.ptr(.containers)];
    }

    pub fn bitset_container_number_of_runs(words: [*]align(C.BLOCK_ALIGN) u64) u32 {
        // TODO: use the fast lower bound, also
        var num_runs: u32 = 0;
        var next_word = words[0];

        for (0..C.BITSET_CONTAINER_SIZE_IN_WORDS - 1) |i| {
            const word = next_word;
            next_word = words[i + 1];
            num_runs += @intCast(@popCount((~word) & (word << 1)) + ((word >> 63) & ~next_word));
        }

        const word = next_word;
        num_runs += @popCount((~word) & (word << 1));
        if ((word & 0x8000000000000000) != 0)
            num_runs += 1;
        return num_runs;
    }

    /// convert ac to a bitset in r.  assumes ac is in r.
    pub fn bitset_container_from_array(
        ac: Container,
        allocator: Allocator,
        r: *Bitmap,
    ) !Container {
        var ans = try bitset_container_create(allocator, r);
        const array = ac.blocks_as(.array, r.*);
        const words = ans.blocks_as(.bitset, r.*);
        const limit = ac.cardinality;
        for (array[0..limit]) |v| bitset_container_set(&ans, v, words);
        return ans;
    }

    /// convert ac to a bitset in dst.  ac is in r.
    pub fn bitset_container_from_array2(
        ac: *const Container,
        allocator: Allocator,
        r: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        const limit = ac.cardinality;
        const acid = ac - r.array.ptr(.containers);
        var ans = try bitset_container_create(allocator, dstr);
        const ac1 = r.array.ptr(.containers)[acid];
        const array = ac1.blocks_as(.array, r.*);
        const words = ans.blocks_as(.bitset, dstr.*);
        for (array[0..limit]) |v| bitset_container_set(&ans, v, words);
        return ans;
    }

    /// Note: when an array container becomes full, it is converted to a bitset in place.
    pub fn add(c: *Container, allocator: Allocator, r: *Bitmap, value: u16) !Container {
        // TODO // c = c.get_writable_copy_if_shared();
        const cid = c - r.array.ptr(.containers);
        switch (c.typecode) {
            .bitset => {
                c.bitset_container_set(value, c.blocks_as(.bitset, r.*));
                return c.*;
            },
            .array => {
                const add_res = try c.array_container_try_add(allocator, r, value, C.DEFAULT_MAX_SIZE);
                const c2 = &r.array.ptr(.containers)[cid];
                if (add_res != -1) {
                    return c2.*;
                }
                var bitset = try c2.bitset_container_from_array(allocator, r);
                bitset.bitset_container_set(value, bitset.blocks_as(.bitset, r.*));
                return bitset;
            },
            .run => {
                _ = try c.run_container_add(allocator, value, r);
                return r.array.ptr(.containers)[cid];
            },
            .shared => unreachable,
        }
    }

    pub fn run_container_serialized_size_in_bytes(cardinality: u32) u32 {
        return @sizeOf(u16) + @sizeOf(root.Rle16) * cardinality;
    }

    pub fn serialized_size_in_bytes(c: Container) u32 {
        return switch (c.typecode) {
            .array => @sizeOf(u16) * c.cardinality,
            .run => run_container_serialized_size_in_bytes(c.cardinality),
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

    pub fn compute_cardinality(v: Container, r: Bitmap) Cardinality {
        if (v == uninit) return 0;
        return switch (v.typecode) {
            .bitset => bitset_container_compute_cardinality(v.blocks_as(.bitset, r).ptr),
            .array => v.cardinality,
            .run => run_container_cardinality(v, v.blocks_as(.run, r).ptr),
            .shared => unreachable,
        };
    }

    pub fn internal_validate(v: Container, reason: *?[]const u8, r: Bitmap) bool {
        if (v == uninit) return true; // FIXME
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
                if (v.cardinality != C.BITSET_UNKNOWN_CARDINALITY) {
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
                        reason.* = "cardinality is too small for a bitset container";
                        return false;
                    }
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
                        trace(@src(), "[{}]={} >= [{}]={}", .{ i - 1, prev, i, array[i] });
                        return false;
                    }
                    prev = array[i];
                }

                return true;
            },
            .run => {
                if (v.cardinality < 0) {
                    reason.* = "negative run count";
                    return false;
                }
                if (v.calc_capacity() < v.cardinality) {
                    reason.* = "capacity less than run count";
                    return false;
                }

                if (v.cardinality == 0) {
                    reason.* = "zero run count";
                    return false;
                }

                // Use u32 to avoid overflow issues on ranges that contain UINT16_MAX.
                var last_end: u32 = 0;
                for (v.blocks_as(.run, r)[0..v.cardinality]) |run| {
                    const start: u32 = run.value;
                    const end: u32 = start + run.length + 1;
                    if (end <= start) {
                        reason.* = "run start + length overflow";
                        return false;
                    }
                    if (end > C.MAX_KEY_CARDINALITY) {
                        reason.* = "run start + length too large";
                        return false;
                    }
                    if (start < last_end) {
                        reason.* = "run start less than last end";
                        return false;
                    }
                    if (start == last_end and last_end != 0) {
                        reason.* = "run start equal to last end, should have combined";
                        return false;
                    }
                    last_end = end;
                }
                return true;
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
    pub fn bitset_container_get(words: [*]align(C.BLOCK_ALIGN) root.Word, pos: u16) bool {
        const word = words[pos >> 6];
        return (word >> @truncate(pos & 63)) & 1 != 0;
    }

    /// Returns the index of x , if not exsist return -1
    pub fn bitset_container_get_index(container: Container, x: u16, r: Bitmap) i32 {
        const words = container.blocks_as(.bitset, r);
        if (bitset_container_get(words.ptr, x)) {
            // credit: aqrit
            var sum: i32 = 0;
            var i: u32 = 0;
            const end = x / 64;
            while (i < end) : (i += 1) {
                sum += @popCount(words[i]);
            }
            const lastword = words[i];
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

    /// Check whether `pos` is present in `runs`.
    pub fn run_container_contains(runs: []align(C.BLOCK_ALIGN) root.Rle16, pos: u16) bool {
        var index = misc.interleavedBinarySearch(runs, pos);
        if (index >= 0) return true;
        index = -index - 2; // points to preceding value, possibly -1
        if (index != -1) { // possible match
            const run = runs[@intCast(index)];
            const offset = pos - run.value;
            if (offset <= run.length) return true;
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
        // c = c.container_unwrap_shared(); // TODO
        return switch (c.typecode) {
            .bitset => c.bitset_container_get_index(x, r),
            .array => c.array_container_get_index(x, r),
            .run => c.run_container_get_index(x, r),
            .shared => unreachable,
        };
    }

    fn bitset_container_contains(c: Container, val: u16, r: Bitmap) bool {
        return bitset_container_get(c.blocks_as(.bitset, r).ptr, val);
    }

    /// Check whether a value is in a container
    pub fn contains(c: Container, val: u16, r: Bitmap) bool {
        // c = c.container_unwrap_shared(); // TODO
        return switch (c.typecode) {
            .bitset => c.bitset_container_contains(val, r),
            .array => misc.binarySearchFallbackLinear(c.blocks_as(.array, r)[0..c.cardinality], val) >= 0,
            .run => run_container_contains(c.blocks_as(.run, r)[0..c.cardinality], val),
            .shared => unreachable,
        };
    }

    pub const fmt = Fmt.init;
    pub const fmtLong = Fmt.initLong;
    pub const Fmt = struct {
        r: Bitmap,
        c: Container,
        mode: enum { short, long } = .short,
        key: u16,

        const Rle = struct {
            rle: ?root.Rle16,
            key: u16,
            pub fn format(rf: Rle, w: *std.Io.Writer) !void {
                if (rf.rle) |rle| {
                    const hi = @as(u32, rf.key) << 16;
                    const value: u32 = hi | rle.value;
                    try w.print("[{},{}]", .{ value, value + rle.length });
                } else try w.writeAll("null");
            }
        };

        pub fn format(f: Fmt, w: *std.Io.Writer) !void {
            const c = f.c;
            if (c == uninit) {
                try w.writeAll("uninit");
                return;
            }
            const hi = @as(u32, f.key) << 16;
            const unknown = "unknown";

            switch (c.typecode) {
                .array => {
                    try w.print("{t: <6} #:{: <7} @{: <3}-{: <3} {s: <7}: ", .{ c.typecode, c.get_cardinality(f.r), c.blockoffset, c.blockoffset + f.c.nblocks_minus1, "" });
                    const vals0 = c.blocks_as(.array, f.r);
                    const vals = if (c.cardinality <= vals0.len) vals0[0..c.cardinality] else &.{};
                    switch (f.mode) {
                        .short => try w.print("[{?}..{?}]", .{
                            if (vals.len > 0) hi | vals[0] else null,
                            if (vals.len > 1) hi | vals[vals.len - 1] else null,
                        }),
                        .long => { // format [1,2,3,5,6,7] as [1..3,5..7]
                            if (vals.len == 0) { // defensive, shouldn't happen
                                try w.writeAll("[]");
                                return;
                            }

                            try w.writeByte('[');
                            try w.print("{}", .{hi | vals[0]});
                            var run_start = vals[0];
                            for (vals[1..], 1..vals.len) |v, i| {
                                if (v != vals[i - 1] and v != vals[i - 1] + 1) {
                                    if (vals[i - 1] != run_start)
                                        try w.print("..{}", .{hi | vals[i - 1]});
                                    try w.print(",{}", .{hi | v});
                                    run_start = v;
                                }
                            }
                            if (vals[vals.len - 1] != run_start)
                                try w.print("..{}", .{hi | vals[vals.len - 1]});
                            try w.writeByte(']');
                        },
                    }
                },
                .run => {
                    try w.print("{t: <6} #:{: <7} @{: <3}-{: <3} runs:{: <5}: ", .{ c.typecode, c.get_cardinality(f.r), c.blockoffset, c.blockoffset + f.c.nblocks_minus1, c.cardinality });
                    const vals0 = c.blocks_as(.run, f.r);
                    const vals = if (c.cardinality <= vals0.len) vals0[0..c.cardinality] else &.{};
                    switch (f.mode) {
                        .short => try w.print("{f}..{f}", .{
                            Rle{ .rle = if (vals.len > 0) vals[0] else null, .key = f.key },
                            Rle{ .rle = if (vals.len > 1) vals[vals.len - 1] else null, .key = f.key },
                        }),
                        .long => {
                            for (vals, 0..) |rle, i| {
                                if (i != 0) try w.writeByte(',');
                                try w.print("{f}", .{Rle{ .rle = rle, .key = f.key }});
                            }
                        },
                    }
                },
                .bitset => {
                    if (c.cardinality == C.BITSET_UNKNOWN_CARDINALITY)
                        try w.print("{t: <6} #:{s: <7} @{: <3}-{: <3}", .{ c.typecode, unknown, c.blockoffset, c.blockoffset + f.c.nblocks_minus1 })
                    else
                        try w.print("{t: <6} #:{: <7} @{: <3}-{: <3}", .{ c.typecode, c.get_cardinality(f.r), c.blockoffset, c.blockoffset + f.c.nblocks_minus1 });
                },
                .shared => {
                    try w.writeAll("TODO: shared");
                },
            }
        }
        pub fn init(c: Container, r: Bitmap, key: u16) Fmt {
            return .{ .c = c, .r = r, .key = key, .mode = .short };
        }
        pub fn initLong(c: Container, r: Bitmap, key: u16) Fmt {
            return .{ .c = c, .r = r, .key = key, .mode = .long };
        }
    };

    /// returns bytes saved by shrinking c.
    ///
    /// does not move blocks. modifies c if it has extra blocks to minimum
    /// blocks needed or deinit when cardinality is 0.
    pub fn shrink_to_fit(c: *Container, r: Bitmap) !usize {
        const blocksneeded = switch (c.typecode) {
            .bitset => return 0, // no shrinking possible
            .array => misc.numGroupsOfSize(c.cardinality, C.BLOCK_LEN16),
            .run => misc.numGroupsOfSize(c.cardinality, C.BLOCK_LEN32),
            .shared => unreachable,
        };
        const cblocks = c.nblocks();
        if (c.cardinality == 0) {
            c.deinit(r);
            return cblocks * C.BLOCK_SIZE;
        } else if (blocksneeded < c.nblocks()) {
            c.nblocks_minus1 = @intCast(blocksneeded - 1);
        }
        return (cblocks - c.nblocks()) * C.BLOCK_SIZE;
    }

    /// total number of elements an array or run container can hold given its
    /// allocated number of blocks.
    ///
    /// nblocks() * C.BLOCK_LEN<N> where N=16 for array containers and 32 for runs.
    pub fn calc_capacity(c: Container) u32 {
        return if (c == uninit)
            0
        else
            @as(u32, c.nblocks()) *
                @as(u32, switch (c.typecode) {
                    .array => C.BLOCK_LEN16,
                    .run => C.BLOCK_LEN32,
                    .bitset => unreachable,
                    .shared => unreachable,
                });
    }

    pub fn array_container_create_given_capacity(
        allocator: Allocator,
        capacity: u32,
        r: *Bitmap,
    ) !Container {
        const numblocks = misc.numGroupsOfSize(capacity * @sizeOf(u16), C.BLOCK_SIZE);
        try r.ensure_unused_capacity(allocator, 1, numblocks);
        defer r.array.ptr(.blockslen).* += numblocks;
        return .{
            .typecode = .array,
            .cardinality = 0,
            .blockoffset = @intCast(r.array.ptr(.blockslen).*),
            .nblocks_minus1 = @intCast(numblocks - 1),
        };
    }

    pub fn run_container_create_given_capacity(
        allocator: Allocator,
        nruns_capacity: u32,
        r: *Bitmap,
    ) !Container {
        const numblocks = @min(
            C.BITSET_BLOCKS,
            misc.numGroupsOfSize(nruns_capacity * @sizeOf(root.Rle16), C.BLOCK_SIZE),
        );
        try r.ensure_unused_capacity(allocator, 1, numblocks);
        defer r.array.ptr(.blockslen).* += numblocks;
        return .{
            .typecode = .run,
            .cardinality = 0,
            .blockoffset = @intCast(r.array.ptr(.blockslen).*),
            .nblocks_minus1 = @intCast(numblocks - 1),
        };
    }

    pub fn bitset_container_clear(bc: Container, r: Bitmap) void {
        @memset(bc.get_blocks(r), @splat(0));
    }

    pub fn bitset_container_create(
        allocator: Allocator,
        r: *Bitmap,
    ) !Container {
        try r.ensure_unused_capacity(allocator, 1, C.BITSET_BLOCKS);
        defer r.array.ptr(.blockslen).* += C.BITSET_BLOCKS;
        const bc = Container{
            .typecode = .bitset,
            .cardinality = 0,
            .blockoffset = @intCast(r.array.ptr(.blockslen).*),
            .nblocks_minus1 = C.BITSET_BLOCKS - 1,
        };
        bitset_container_clear(bc, r.*);
        return bc;
    }

    /// Check whether this bitset is empty,
    pub fn bitset_container_empty(bitset: Container, r: Bitmap) bool {
        return if (bitset.cardinality == C.BITSET_UNKNOWN_CARDINALITY)
            for (bitset.blocks_as(.bitset, r)) |word| {
                if (word != 0) break false;
            } else true
        else
            bitset.cardinality == 0;
    }

    /// Checks whether a container is not empty, requires a  typecode
    pub fn nonzero_cardinality(c: Container, r: Bitmap) bool {
        // TODO // c = c.container_unwrap_shared();
        return c != uninit and switch (c.typecode) {
            .bitset => !c.bitset_container_empty(r),
            .array, .run => c.cardinality != 0,
            else => unreachable,
        };
    }

    /// Remove `pos' from `bitset'. Returns true if `pos' was present.  Might be
    /// slower than bitset_container_unset.
    fn bitset_container_remove(bitset: *Container, pos: u16, r: Bitmap) bool {
        const words = bitset.blocks_as(.bitset, r);
        const old_word = words[pos >> 6];
        const index: u6 = @truncate(pos & 63);
        const new_word = old_word & (~(@as(u64, 1) << index));
        const increment = (old_word ^ new_word) >> index;
        bitset.cardinality -= @intCast(increment);
        words[pos >> 6] = new_word;
        return increment > 0;
    }

    /// Remove x from the set. Returns true if x was present.
    fn array_container_remove(arr: *Container, pos: u16, r: Bitmap) bool {
        const array = arr.blocks_as(.array, r)[0..arr.cardinality];
        const idx = misc.binarySearch(array, pos);
        const is_present = idx >= 0;
        if (is_present) {
            const idxu: u32 = @bitCast(idx);
            @memmove(array.ptr + idxu, (array.ptr + idxu + 1)[0 .. arr.cardinality - idxu - 1]);
            arr.cardinality -= 1;
        }

        return is_present;
    }

    /// Remove `pos' from `run'. Returns true if `pos' was present.
    fn run_container_remove(run: *Container, allocator: Allocator, pos: u16, r: *Bitmap) !bool {
        const runs = run.blocks_as(.run, r.*)[0..run.cardinality];
        var mindex = misc.interleavedBinarySearch(runs, pos);
        if (mindex >= 0) {
            const indexu: u32 = @bitCast(mindex);
            if (runs[indexu].length == 0) {
                r.recoverRoomAtIndex(run, @intCast(indexu));
            } else {
                runs[indexu].value += 1;
                runs[indexu].length -= 1;
            }
            return true;
        }
        mindex = -mindex - 2; // points to preceding value, possibly -1
        if (mindex >= 0) { // possible match
            const index: u32 = @bitCast(mindex);
            const offset = @as(i32, pos) - runs[index].value;
            const runlength: i32 = runs[index].length;
            if (offset < runlength) {
                // break in two, insert
                const newvalue = pos + 1;
                const newlength: i32 = runlength - offset - 1;
                const cid = run - r.array.ptr(.containers);
                try run.makeRoomAtIndex(allocator, r, @intCast(mindex + 1));
                const run2 = r.array.ptr(.containers)[cid];
                const runs2 = run2.blocks_as(.run, r.*);
                runs2[index].length = @intCast(offset - 1);
                runs2.ptr[index + 1] = .{
                    .value = newvalue,
                    .length = @intCast(newlength),
                };
                return true;
            } else if (offset == runlength) {
                runs[index].length -= 1;
                return true;
            }
        }
        // no match
        return false;
    }

    /// Given a bitset of "words", write out the position of all the set bits to
    /// "out", values start at "base" (can be set to zero).
    ///
    /// The "out" pointer should be sufficient to store the actual number of bits
    /// set.
    ///
    /// Returns how many values were actually decoded.
    pub fn bitset_extract_setbits_uint16(
        words: [*]align(C.BLOCK_ALIGN) u64,
        out: []align(C.BLOCK_ALIGN) u16,
        base: u16,
    ) usize {
        var outpos: usize = 0;
        var base1 = base;
        for (words[0..C.BITSET_CONTAINER_SIZE_IN_WORDS]) |w0| {
            var w = w0;
            while (w != 0) {
                out[outpos] = @ctz(w) + base1;
                outpos += 1;
                w &= (w - 1);
            }
            base1 +%= 64;
        }
        return outpos;
    }

    pub fn array_container_from_bitset(
        bc: *const Container,
        allocator: Allocator,
        r: *Bitmap,
    ) !Container {
        const card = bc.cardinality;
        if (card == 0)
            return uninit;

        const bo = bc.blockoffset;
        var result = try array_container_create_given_capacity(allocator, card, r);
        result.cardinality = card;
        // TODO avx512 version?
        // sse version ends up being slower here because of the sparsity of the data
        assert(card == bitset_extract_setbits_uint16(
            @ptrCast(r.array.ptr(.blocks)[bo..][0..C.BITSET_BLOCKS].ptr),
            result.blocks_as(.array, r.*)[0..card],
            0,
        ));
        return result;
    }

    fn array_number_of_runs(c: Container, r: Bitmap) u32 {
        // Can SIMD work here?
        var nr_runs: u32 = 0;
        var prev: i32 = -2;
        const start: [*]u16 = @ptrCast(&r.array.ptr(.blocks)[c.blockoffset]);
        var p = start;
        const card = c.cardinality;
        while (p != start + card) : (p += 1) {
            if (p[0] != prev + 1) nr_runs += 1;
            prev = p[0];
        }
        return nr_runs;
    }

    /// once converted, the original container is disposed here.
    ///
    // TODO: split into run- array- and bitset- subfunctions for sanity;
    // a few function calls won't really matter.
    pub fn convert_run_optimize(cid: u32, allocator: Allocator, r: *Bitmap) !Container {
        const c = r.array.ptr(.containers)[cid];
        if (c.typecode == .run) {
            const newc = try c.convert_run_to_efficient_container(allocator, r);
            if (newc != c) r.array.ptr(.containers)[cid].deinit_blocks(r.*);
            return newc;
        } else if (c.typecode == .array) {
            // it might need to be converted to a run container.
            const nruns = c.array_number_of_runs(r.*);
            const nrunblocks = misc.numGroupsOfSize(nruns * @sizeOf(root.Rle16), C.BLOCK_SIZE);
            var rc: Container = .{
                .typecode = .run,
                .cardinality = @intCast(nruns),
                .nblocks_minus1 = @intCast(nrunblocks - 1),
                .blockoffset = @intCast(r.array.ptr(.blockslen).*),
            };
            const size_as_run_container = run_container_serialized_size_in_bytes(nruns);
            const size_as_array_container = c.serialized_size_in_bytes();
            trace(@src(), "array. arraysize={} runsize={}", .{ size_as_array_container, size_as_run_container });
            if (size_as_array_container <= size_as_run_container) {
                return c;
            }
            // convert array to run container
            try r.ensure_unused_capacity(allocator, 0, nrunblocks);

            var prev: i32 = -2;
            var run_start: i32 = -1;
            const ac = &r.array.ptr(.containers)[cid];
            const card = ac.cardinality;
            rc.cardinality = 0;
            assert(card > 0);
            const array = ac.blocks_as(.array, r.*)[0..ac.cardinality];
            var i: u32 = 0;
            while (i < card) : (i += 1) {
                const cur_val = array[i];
                if (cur_val != prev + 1) {
                    // new run starts; flush old one, if any
                    if (run_start != -1) rc.add_run(@intCast(run_start), @intCast(prev), r.*);
                    run_start = cur_val;
                }
                prev = array[i];
            }
            assert(run_start >= 0);
            // now prev is the last seen value
            rc.add_run(@intCast(run_start), @intCast(prev), r.*);
            ac.deinit_blocks(r.*);
            r.array.ptr(.blockslen).* += nrunblocks;
            return rc;
        } else if (c.typecode == .bitset) { // run conversions on bitset
            // does bitset need conversion to run?
            const nruns = bitset_container_number_of_runs(c.blocks_as(.bitset, r.*).ptr);
            const size_as_run_container = run_container_serialized_size_in_bytes(nruns);
            if (size_as_run_container >= @sizeOf(root.Bitset)) // no conversion needed.
                return c;

            // bitset to runcontainer (ported from Java RunContainer(BitmapContainer bc, int nbrRuns))
            assert(nruns > 0); // no empty bitmaps
            var answer = try run_container_create_given_capacity(
                allocator,
                nruns,
                r,
            );

            const words = r.array.ptr(.containers)[cid].blocks_as(.bitset, r.*);
            var long_ctr: u32 = 0;
            var cur_word = words[0];
            while (true) {
                while (cur_word == 0 and
                    long_ctr < C.BITSET_CONTAINER_SIZE_IN_WORDS - 1)
                {
                    long_ctr += 1;
                    cur_word = words[long_ctr];
                }

                if (cur_word == 0) {
                    r.array.ptr(.containers)[cid].deinit_blocks(r.*);
                    return answer;
                }

                const local_run_start = @ctz(cur_word);
                const run_start = local_run_start + 64 * long_ctr;
                var cur_word_with_1s = cur_word | (cur_word - 1);

                var run_end: u32 = 0;
                while (cur_word_with_1s == std.math.maxInt(u64) and
                    long_ctr < C.BITSET_CONTAINER_SIZE_IN_WORDS - 1)
                {
                    long_ctr += 1;
                    cur_word_with_1s = words[long_ctr];
                }

                if (cur_word_with_1s == std.math.maxInt(u64)) {
                    run_end = 64 + long_ctr * 64; // exclusive, I guess
                    answer.add_run(@intCast(run_start), @intCast(run_end - 1), r.*);
                    r.array.ptr(.containers)[cid].deinit_blocks(r.*);
                    return answer;
                }
                const local_run_end = @ctz(~cur_word_with_1s);
                run_end = local_run_end + long_ctr * 64;
                answer.add_run(@intCast(run_start), @intCast(run_end - 1), r.*);
                cur_word = cur_word_with_1s & (cur_word_with_1s + 1);
            }
            return answer;
        } else {
            unreachable;
        }
    }

    /// Remove a value from a container return (possibly different) container.
    /// This function may allocate a new container, and caller is responsible for
    /// memory deallocation
    ///
    /// Returned container may not be valid.  caller must ensure bitmap is valid.
    pub fn remove(c: *Container, allocator: Allocator, val: u16, r: *Bitmap) !Container {
        c.assert_valid(r.*);
        const cid = c - r.array.ptr(.containers);
        trace(@src(), "{}", .{val});
        // TODO // c = get_writable_copy_if_shared(c, &typecode);
        switch (c.typecode) {
            .bitset => {
                if (c.bitset_container_remove(val, r.*)) {
                    if (c.cardinality <= C.DEFAULT_MAX_SIZE) {
                        return try c.array_container_from_bitset(allocator, r);
                    }
                }
            },
            .array => {
                _ = c.array_container_remove(val, r.*);
            },
            .run => {
                // per Java, no container type adjustments are done (revisit?)
                _ = try c.run_container_remove(allocator, val, r);
            },
            else => unreachable,
        }
        return r.array.ptr(.containers)[cid];
    }

    /// Simple CSA over Block
    fn CSA(h: *Block, l: *Block, a: Block, b: Block, c: Block) void {
        const u = a ^ b;
        h.* = (a & b) | (u & c);
        l.* = u ^ c;
    }

    fn popcount256(v: Block) root.Block64 {
        const lookuppos: Block = .{
            4 + 0, 4 + 1, 4 + 1, 4 + 2, 4 + 1, 4 + 2, 4 + 2, 4 + 3,
            4 + 1, 4 + 2, 4 + 2, 4 + 3, 4 + 2, 4 + 3, 4 + 3, 4 + 4,
            4 + 0, 4 + 1, 4 + 1, 4 + 2, 4 + 1, 4 + 2, 4 + 2, 4 + 3,
            4 + 1, 4 + 2, 4 + 2, 4 + 3, 4 + 2, 4 + 3, 4 + 3, 4 + 4,
        };

        const lookupneg: Block = .{
            4 - 0, 4 - 1, 4 - 1, 4 - 2, 4 - 1, 4 - 2, 4 - 2, 4 - 3,
            4 - 1, 4 - 2, 4 - 2, 4 - 3, 4 - 2, 4 - 3, 4 - 3, 4 - 4,
            4 - 0, 4 - 1, 4 - 1, 4 - 2, 4 - 1, 4 - 2, 4 - 2, 4 - 3,
            4 - 1, 4 - 2, 4 - 2, 4 - 3, 4 - 2, 4 - 3, 4 - 3, 4 - 4,
        };

        const low_mask: Block = @splat(0x0f);
        const shift_amt: Block = @splat(4);
        const lo = v & low_mask;
        const hi = (v >> shift_amt) & low_mask;
        const popcnt1 = misc.pshufb(lookuppos, lo);
        const popcnt2 = misc.pshufb(lookupneg, hi);
        const sad_result = misc.psadbw(popcnt1, popcnt2);
        return @bitCast(sad_result);
    }

    /// Fast Harley-Seal AVX population count function
    fn avx2_harley_seal_popcount(data: []root.Block) u64 {
        var total: root.Block64 = @splat(0);
        var ones: Block = @splat(0);
        var twos: Block = @splat(0);
        var fours: Block = @splat(0);
        var eights: Block = @splat(0);
        var sixteens: Block = @splat(0);
        var twosA: Block = undefined;
        var twosB: Block = undefined;
        var foursA: Block = undefined;
        var foursB: Block = undefined;
        var eightsA: Block = undefined;
        var eightsB: Block = undefined;
        const size = data.len;
        const limit = size - size % 16;
        var i: u64 = 0;

        while (i < limit) : (i += 16) {
            CSA(&twosA, &ones, ones, data[i], data[i + 1]);
            CSA(&twosB, &ones, ones, data[i + 2], data[i + 3]);
            CSA(&foursA, &twos, twos, twosA, twosB);
            CSA(&twosA, &ones, ones, data[i + 4], data[i + 5]);
            CSA(&twosB, &ones, ones, data[i + 6], data[i + 7]);
            CSA(&foursB, &twos, twos, twosA, twosB);
            CSA(&eightsA, &fours, fours, foursA, foursB);
            CSA(&twosA, &ones, ones, data[i + 8], data[i + 9]);
            CSA(&twosB, &ones, ones, data[i + 10], data[i + 11]);
            CSA(&foursA, &twos, twos, twosA, twosB);
            CSA(&twosA, &ones, ones, data[i + 12], data[i + 13]);
            CSA(&twosB, &ones, ones, data[i + 14], data[i + 15]);
            CSA(&foursB, &twos, twos, twosA, twosB);
            CSA(&eightsB, &fours, fours, foursA, foursB);
            CSA(&sixteens, &eights, eights, eightsA, eightsB);

            total += popcount256(sixteens);
        }

        total <<= @splat(4); // *= 16
        total += popcount256(eights) << @splat(3); // += 8 * ...
        total += popcount256(fours) << @splat(2); // += 4 * ...
        total += popcount256(twos) << @splat(1); // += 2 * ...
        total += popcount256(ones);
        while (i < size) : (i += 1)
            total += popcount256(data[i]);

        return @reduce(.Add, total);
    }

    const ReduceOp = enum { And, Or, Xor, AndNot };
    fn op_methods(comptime op: ReduceOp) type {
        return struct {
            fn bitset_container_op(
                src1: [*]align(C.BLOCK_ALIGN) const u64,
                src2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: *Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) Cardinality {
                dstc.cardinality = @intCast(if (C.HAS_AVX2)
                    avx2_harley_seal_popcount_op_store(
                        @ptrCast(src1),
                        @ptrCast(src2),
                        @ptrCast(dst),
                        C.BITSET_BLOCKS,
                    )
                else
                    _scalar_bitset_container_op(src1, src2, dstc, dst));
                return dstc.cardinality;
            }

            fn _scalar_bitset_container_op(
                words1: [*]align(C.BLOCK_ALIGN) const u64,
                words2: [*]align(C.BLOCK_ALIGN) const u64,
                dst: *Container,
                out: [*]align(C.BLOCK_ALIGN) u64,
            ) Cardinality {
                var sum: Cardinality = 0;
                var i: usize = 0;
                while (i < C.BITSET_CONTAINER_SIZE_IN_WORDS) : (i += 2) {
                    const word1 = avx_intrinsic(words1[i], words2[i]);
                    const word2 = avx_intrinsic(words1[i + 1], words2[i + 1]);
                    out[i] = word1;
                    out[i + 1] = word2;
                    sum += @popCount(word1);
                    sum += @popCount(word2);
                }
                dst.cardinality = sum;
                return sum;
            }

            fn bitset_container_op_nocard(
                src1: [*]align(C.BLOCK_ALIGN) const u64,
                src2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: *Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) Cardinality {
                return if (C.HAS_AVX2)
                    _avx2_bitset_container_op_nocard(src1, src2, dstc, dst)
                else
                    _scalar_bitset_container_op_nocard(src1, src2, dstc, dst);
            }

            pub fn bitset_container_op_justcard(
                src1: [*]align(C.BLOCK_ALIGN) const u64,
                src2: [*]align(C.BLOCK_ALIGN) const u64,
            ) u32 {
                return if (C.HAS_AVX2)
                    _avx2_bitset_container_op_justcard(src1, src2)
                else
                    _scalar_bitset_container_op_justcard(src1, src2);
            }

            fn _scalar_bitset_container_op_justcard(
                words1: [*]align(C.BLOCK_ALIGN) const u64,
                words2: [*]align(C.BLOCK_ALIGN) const u64,
            ) Cardinality {
                var sum: Cardinality = 0;
                var i: usize = 0;
                while (i < C.BITSET_CONTAINER_SIZE_IN_WORDS) : (i += 2) {
                    const word1 = avx_intrinsic(words1[i], words2[i]);
                    const word2 = avx_intrinsic(words1[i + 1], words2[i + 1]);
                    sum += @popCount(word1);
                    sum += @popCount(word2);
                }
                return sum;
            }

            fn _avx2_bitset_container_op_justcard(
                data1: [*]align(C.BLOCK_ALIGN) const u64,
                data2: [*]align(C.BLOCK_ALIGN) const u64,
            ) Cardinality {
                return @intCast(avx2_harley_seal_popcount_op(
                    @ptrCast(data1),
                    @ptrCast(data2),
                    C.BITSET_BLOCKS,
                ));
            }

            const avx_intrinsic = perform_op;
            fn perform_op(a: anytype, b: anytype) @TypeOf(a) {
                return switch (op) {
                    .And => a & b,
                    .Or => a | b,
                    .Xor => a ^ b,
                    .AndNot => a & ~b,
                };
            }

            fn avx2_harley_seal_popcount_op(
                data1: [*]const Block,
                data2: [*]const Block,
                size: u64,
            ) u64 {
                var total: root.Block64 = @splat(0);
                var ones: Block = @splat(0);
                var twos: Block = @splat(0);
                var fours: Block = @splat(0);
                var eights: Block = @splat(0);
                var sixteens: Block = @splat(0);
                var twosA: Block = undefined;
                var twosB: Block = undefined;
                var foursA: Block = undefined;
                var foursB: Block = undefined;
                var eightsA: Block = undefined;
                var eightsB: Block = undefined;
                var A1: Block = undefined;
                var A2: Block = undefined;
                const limit = size - size % 16;
                var i: usize = 0;
                while (i < limit) : (i += 16) {
                    A1 = avx_intrinsic((data1 + i)[0], (data2 + i)[0]);
                    A2 = avx_intrinsic((data1 + i + 1)[0], (data2 + i + 1)[0]);
                    CSA(&twosA, &ones, ones, A1, A2);
                    A1 = avx_intrinsic((data1 + i + 2)[0], (data2 + i + 2)[0]);
                    A2 = avx_intrinsic((data1 + i + 3)[0], (data2 + i + 3)[0]);
                    CSA(&twosB, &ones, ones, A1, A2);
                    CSA(&foursA, &twos, twos, twosA, twosB);
                    A1 = avx_intrinsic((data1 + i + 4)[0], (data2 + i + 4)[0]);
                    A2 = avx_intrinsic((data1 + i + 5)[0], (data2 + i + 5)[0]);
                    CSA(&twosA, &ones, ones, A1, A2);
                    A1 = avx_intrinsic((data1 + i + 6)[0], (data2 + i + 6)[0]);
                    A2 = avx_intrinsic((data1 + i + 7)[0], (data2 + i + 7)[0]);
                    CSA(&twosB, &ones, ones, A1, A2);
                    CSA(&foursB, &twos, twos, twosA, twosB);
                    CSA(&eightsA, &fours, fours, foursA, foursB);
                    A1 = avx_intrinsic((data1 + i + 8)[0], (data2 + i + 8)[0]);
                    A2 = avx_intrinsic((data1 + i + 9)[0], (data2 + i + 9)[0]);
                    CSA(&twosA, &ones, ones, A1, A2);
                    A1 = avx_intrinsic((data1 + i + 10)[0], (data2 + i + 10)[0]);
                    A2 = avx_intrinsic((data1 + i + 11)[0], (data2 + i + 11)[0]);
                    CSA(&twosB, &ones, ones, A1, A2);
                    CSA(&foursA, &twos, twos, twosA, twosB);
                    A1 = avx_intrinsic((data1 + i + 12)[0], (data2 + i + 12)[0]);
                    A2 = avx_intrinsic((data1 + i + 13)[0], (data2 + i + 13)[0]);
                    CSA(&twosA, &ones, ones, A1, A2);
                    A1 = avx_intrinsic((data1 + i + 14)[0], (data2 + i + 14)[0]);
                    A2 = avx_intrinsic((data1 + i + 15)[0], (data2 + i + 15)[0]);
                    CSA(&twosB, &ones, ones, A1, A2);
                    CSA(&foursB, &twos, twos, twosA, twosB);
                    CSA(&eightsB, &fours, fours, foursA, foursB);
                    CSA(&sixteens, &eights, eights, eightsA, eightsB);
                    total += popcount256(sixteens);
                }
                total <<= @splat(4); // *= 16
                total += popcount256(eights) << @splat(3);
                total += popcount256(fours) << @splat(2);
                total += popcount256(twos) << @splat(1);
                total += popcount256(ones);
                while (i < size) : (i += 1) {
                    A1 = avx_intrinsic((data1 + i)[0], (data2 + i)[0]);
                    total += popcount256(A1);
                }
                return @reduce(.Add, total);
            }

            fn avx2_harley_seal_popcount_op_store(
                data1: [*]const Block,
                data2: [*]const Block,
                out: [*]Block,
                size: u64,
            ) u64 {
                var total: root.Block64 = @splat(0);
                var ones: Block = @splat(0);
                var twos: Block = @splat(0);
                var fours: Block = @splat(0);
                var eights: Block = @splat(0);
                var sixteens: Block = @splat(0);
                var twosA: Block = undefined;
                var twosB: Block = undefined;
                var foursA: Block = undefined;
                var foursB: Block = undefined;
                var eightsA: Block = undefined;
                var eightsB: Block = undefined;
                var A1: Block = undefined;
                var A2: Block = undefined;
                const limit = size - size % 16;
                var i: usize = 0;
                while (i < limit) : (i += 16) {
                    A1 = avx_intrinsic(data1[i + 0], data2[i + 0]);
                    out[i] = A1;
                    A2 = avx_intrinsic(data1[i + 1], data2[i + 1]);
                    out[i + 1] = A2;
                    CSA(&twosA, &ones, ones, A1, A2);
                    A1 = avx_intrinsic(data1[i + 2], data2[i + 2]);
                    out[i + 2] = A1;
                    A2 = avx_intrinsic(data1[i + 3], data2[i + 3]);
                    out[i + 3] = A2;
                    CSA(&twosB, &ones, ones, A1, A2);
                    CSA(&foursA, &twos, twos, twosA, twosB);
                    A1 = avx_intrinsic(data1[i + 4], data2[i + 4]);
                    out[i + 4] = A1;
                    A2 = avx_intrinsic(data1[i + 5], data2[i + 5]);
                    out[i + 5] = A2;
                    CSA(&twosA, &ones, ones, A1, A2);
                    A1 = avx_intrinsic(data1[i + 6], data2[i + 6]);
                    out[i + 6] = A1;
                    A2 = avx_intrinsic(data1[i + 7], data2[i + 7]);
                    out[i + 7] = A2;
                    CSA(&twosB, &ones, ones, A1, A2);
                    CSA(&foursB, &twos, twos, twosA, twosB);
                    CSA(&eightsA, &fours, fours, foursA, foursB);
                    A1 = avx_intrinsic(data1[i + 8], data2[i + 8]);
                    out[i + 8] = A1;
                    A2 = avx_intrinsic(data1[i + 9], data2[i + 9]);
                    out[i + 9] = A2;
                    CSA(&twosA, &ones, ones, A1, A2);
                    A1 = avx_intrinsic(data1[i + 10], data2[i + 10]);
                    out[i + 10] = A1;
                    A2 = avx_intrinsic(data1[i + 11], data2[i + 11]);
                    out[i + 11] = A2;
                    CSA(&twosB, &ones, ones, A1, A2);
                    CSA(&foursA, &twos, twos, twosA, twosB);
                    A1 = avx_intrinsic(data1[i + 12], data2[i + 12]);
                    out[i + 12] = A1;
                    A2 = avx_intrinsic(data1[i + 13], data2[i + 13]);
                    out[i + 13] = A2;
                    CSA(&twosA, &ones, ones, A1, A2);
                    A1 = avx_intrinsic(data1[i + 14], data2[i + 14]);
                    out[i + 14] = A1;
                    A2 = avx_intrinsic(data1[i + 15], data2[i + 15]);
                    out[i + 15] = A2;
                    CSA(&twosB, &ones, ones, A1, A2);
                    CSA(&foursB, &twos, twos, twosA, twosB);
                    CSA(&eightsB, &fours, fours, foursA, foursB);
                    CSA(&sixteens, &eights, eights, eightsA, eightsB);
                    total += popcount256(sixteens);
                }
                total <<= @splat(4);
                total += popcount256(eights) << @splat(3);
                total += popcount256(fours) << @splat(2);
                total += popcount256(twos) << @splat(1);
                total += popcount256(ones);
                while (i < size) : (i += 1) {
                    A1 = avx_intrinsic((data1 + i)[0], (data2 + i)[0]);
                    total += popcount256(A1);
                }
                return @reduce(.Add, total);
            }

            fn _scalar_bitset_container_op_nocard(
                words1: [*]align(C.BLOCK_ALIGN) const u64,
                words2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: *Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) Cardinality {
                for (0..C.BITSET_CONTAINER_SIZE_IN_WORDS) |i| {
                    dst[i] = avx_intrinsic(words1[i], words2[i]);
                }
                dstc.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
                return dstc.cardinality;
            }

            fn _avx2_bitset_container_op_nocard(
                words1: [*]align(C.BLOCK_ALIGN) const u64,
                words2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: *Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) Cardinality {
                const innerloop = 8;
                var blocks1: [*]const root.Block64 = @ptrCast(words1);
                var blocks2: [*]const root.Block64 = @ptrCast(words2);
                var blocksout: [*]root.Block64 = @ptrCast(dst);
                const blocksend = dst + C.BITSET_CONTAINER_SIZE_IN_WORDS;
                while (@intFromPtr(blocksout) < @intFromPtr(blocksend)) {
                    inline for (
                        blocksout[0..innerloop],
                        blocks2[0..innerloop],
                        blocks1[0..innerloop],
                    ) |*bo, b2, b1| {
                        bo.* = avx_intrinsic(b2, b1);
                    }
                    blocksout += innerloop;
                    blocks1 += innerloop;
                    blocks2 += innerloop;
                }
                assert(@intFromPtr(blocksout) == @intFromPtr(dst + C.BITSET_CONTAINER_SIZE_IN_WORDS));
                dstc.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
                return dstc.cardinality;
            }
        };
    }

    /// Computes the intersection of bitsets `src1' and `src2'  and return the
    /// cardinality.
    fn bitset_container_and_justcard(
        src1: [*]align(C.BLOCK_ALIGN) const u64,
        src2: [*]align(C.BLOCK_ALIGN) const u64,
    ) Cardinality {
        return @intCast(op_methods(.And).bitset_container_op_justcard(src1, src2));
    }

    /// Computes the intersection of bitsets `src1' and `src2' into `dst', but does
    /// not update the cardinality. Provided to optimize chained operations.
    fn bitset_container_and_nocard(
        data1: [*]align(C.BLOCK_ALIGN) const u64,
        data2: [*]align(C.BLOCK_ALIGN) const u64,
        dstc: *Container,
        dst: [*]align(C.BLOCK_ALIGN) u64,
    ) Cardinality {
        return op_methods(.And).bitset_container_op_nocard(data1, data2, dstc, dst);
    }

    /// Compute the intersection between src1 and src2 and write the result
    /// to dst. If the return function is true, the result is a bitset_container_t
    /// otherwise is a array_container_t.
    fn bitset_bitset_container_intersection(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const newCardinality = bitset_container_and_justcard(
            src1.blocks_as(.bitset, x1.*).ptr,
            src2.blocks_as(.bitset, x2.*).ptr,
        );
        if (newCardinality > C.DEFAULT_MAX_SIZE) {
            dst.* = try bitset_container_create(allocator, dstr);
            _ = bitset_container_and_nocard(
                src1.blocks_as(.bitset, x1.*).ptr,
                src2.blocks_as(.bitset, x2.*).ptr,
                dst,
                dst.blocks_as(.bitset, dstr.*).ptr,
            );
            dst.cardinality = newCardinality;
            return;
        }
        if (newCardinality == 0)
            return;
        dst.* = try array_container_create_given_capacity(allocator, newCardinality, dstr);
        dst.cardinality = newCardinality;
        _ = bitset_extract_intersection_setbits_uint16(
            src1.blocks_as(.bitset, x1.*),
            src2.blocks_as(.bitset, x2.*),
            dst.blocks_as(.array, dstr.*),
            0,
        );
    }

    /// Same as bitset_bitset_container_intersection except that if the output
    /// is to be a bitset container, then src1 is modified and no allocation
    /// is made. If the output is to be an array container, then caller is
    /// responsible to free the container. In all cases, the result is in dst.
    fn bitset_bitset_container_intersection_inplace(
        src1: Container,
        src2: Container,
        r: Bitmap,
    ) Container {
        const newCardinality = bitset_container_and_justcard(src1, src2);
        if (newCardinality > C.DEFAULT_MAX_SIZE) {
            var bc = src1;
            bitset_container_and_nocard(src1, src2, src1);
            bc.cardinality = newCardinality;
            return bc;
        }
        var ac = try array_container_create_given_capacity(newCardinality);
        ac.cardinality = newCardinality;
        bitset_extract_intersection_setbits_uint16(src1.words, src2.words, C.BITSET_CONTAINER_SIZE_IN_WORDS, ac.blocks_as(.array, r), 0);

        return ac; // not a bitset
    }

    /// computes the intersection of array1 and array2 and return the result in dst.
    fn array_container_intersection(
        ac1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        ac2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const card1 = ac1.cardinality;
        const card2 = ac2.cardinality;
        const min_card = @min(card1, card2);
        const threshold = 64; // subject to tuning

        if (dst.calc_capacity() < min_card)
            try dst.array_container_grow(allocator, dstr, min_card, false);

        dst.nblocks_minus1 = @intCast(misc.numGroupsOfSize(min_card, C.BLOCK_LEN16) - 1);

        if (card1 * threshold < card2) {
            dst.cardinality = @intCast(misc.intersect_skewed_uint16(
                ac1.blocks_as(.array, x1.*)[0..card1],
                ac2.blocks_as(.array, x2.*)[0..card2],
                dst.blocks_as(.array, dstr.*),
            ));
        } else if (card2 * threshold < card1) {
            dst.cardinality = @intCast(misc.intersect_skewed_uint16(
                ac2.blocks_as(.array, x2.*)[0..card2],
                ac1.blocks_as(.array, x1.*)[0..card1],
                dst.blocks_as(.array, dstr.*),
            ));
        } else {
            if (C.HAS_AVX2) {
                // TODO use intersect_vector16() when HAS_AVX2
            }
            dst.cardinality = @intCast(misc.intersect_uint16(
                ac1.blocks_as(.array, x1.*)[0..card1],
                ac2.blocks_as(.array, x2.*)[0..card2],
                dst.blocks_as(.array, dstr.*),
            ));
        }

        if (dst.cardinality == 0)
            dst.deinit_blocks(dstr.*)
        else
            dst.assert_valid(dstr.*);
        // if (ac1.equals(ac2, x1, x2)) assert(dst.equals(ac1, dstr.*, x1));
    }

    /// Copy one container into another. We assume that they are distinct.
    fn array_container_copy(
        src: Container,
        allocator: Allocator,
        dst: *Container,
        srcarray: [*]align(C.BLOCK_ALIGN) const u16,
        dstr: *Bitmap,
    ) !void {
        const cardinality = src.cardinality;
        if (cardinality > dst.calc_capacity()) {
            try array_container_grow(dst, allocator, dstr, cardinality, false);
        }
        dst.cardinality = cardinality;
        @memcpy(dst.blocks_as(.array, dstr.*)[0..cardinality], srcarray);
    }

    /// returns the computed intersection of src1 and src2
    fn run_container_intersection(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const if1 = run_container_is_full(src1.*, x1.*);
        const if2 = run_container_is_full(src2.*, x2.*);
        if (if1 or if2) {
            if (if1) {
                try src2.run_container_copy(allocator, dst, src2.blocks_as(.run, x2.*).ptr, dstr);
                return;
            }
            if (if2) {
                try src1.run_container_copy(allocator, dst, src1.blocks_as(.run, x1.*).ptr, dstr);
                return;
            }
        }
        // TODO: this could be a lot more efficient, could use SIMD optimizations
        const neededcapacity = src1.cardinality + src2.cardinality;
        if (dst.calc_capacity() < neededcapacity)
            try run_container_grow(dst, allocator, neededcapacity, false, dstr);
        dst.cardinality = 0;
        var rlepos: u32 = 0;
        var xrlepos: u32 = 0;
        const src1_runs = src1.blocks_as(.run, x1.*);
        const src2_runs = src2.blocks_as(.run, x2.*);
        const dst_runs = dst.blocks_as(.run, dstr.*);
        var start: u32 = src1_runs[rlepos].value;
        var end: u32 = start + src1_runs[rlepos].length + 1;
        var xstart: u32 = src2_runs[xrlepos].value;
        var xend: u32 = xstart + src2_runs[xrlepos].length + 1;
        while (rlepos < src1.cardinality and xrlepos < src2.cardinality) {
            if (end <= xstart) {
                rlepos += 1;
                if (rlepos < src1.cardinality) {
                    start = src1_runs[rlepos].value;
                    end = start + src1_runs[rlepos].length + 1;
                }
            } else if (xend <= start) {
                xrlepos += 1;
                if (xrlepos < src2.cardinality) {
                    xstart = src2_runs[xrlepos].value;
                    xend = xstart + src2_runs[xrlepos].length + 1;
                }
            } else { // they overlap
                const lateststart: u32 = if (start > xstart) start else xstart;
                var earliestend: u32 = undefined;
                if (end == xend) { // improbable
                    earliestend = end;
                    rlepos += 1;
                    xrlepos += 1;
                    if (rlepos < src1.cardinality) {
                        start = src1_runs[rlepos].value;
                        end = start + src1_runs[rlepos].length + 1;
                    }
                    if (xrlepos < src2.cardinality) {
                        xstart = src2_runs[xrlepos].value;
                        xend = xstart + src2_runs[xrlepos].length + 1;
                    }
                } else if (end < xend) {
                    earliestend = end;
                    rlepos += 1;
                    if (rlepos < src1.cardinality) {
                        start = src1_runs[rlepos].value;
                        end = start + src1_runs[rlepos].length + 1;
                    }
                } else { // end > xend
                    earliestend = xend;
                    xrlepos += 1;
                    if (xrlepos < src2.cardinality) {
                        xstart = src2_runs[xrlepos].value;
                        xend = xstart + src2_runs[xrlepos].length + 1;
                    }
                }
                dst_runs[dst.cardinality].value = @truncate(lateststart);
                dst_runs[dst.cardinality].length =
                    @truncate(earliestend - lateststart - 1);
                dst.cardinality += 1;
            }
        }
    }

    /// Copy one container into another. We assume that they are distinct.
    fn run_container_copy(
        src: Container,
        allocator: Allocator,
        dst: *Container,
        srcruns: [*]align(C.BLOCK_ALIGN) root.Rle16,
        dstr: *Bitmap,
    ) !void {
        const n_runs = src.cardinality;
        if (src.cardinality > dst.calc_capacity())
            try run_container_grow(dst, allocator, n_runs, false, dstr);
        dst.cardinality = n_runs;
        @memcpy(dst.blocks_as(.run, dstr.*)[0..n_runs], srcruns);
    }

    /// Compute the intersection of src1 and src2 and write the result to dst.
    fn array_bitset_container_intersection(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        if (dst.calc_capacity() < src1.cardinality)
            try array_container_grow(dst, allocator, dstr, src1.cardinality, false);
        var newcard: Cardinality = 0; // dst could be src1
        const origcard = src1.cardinality;
        const src1array = src1.blocks_as(.array, x1.*);
        const dstarray = dst.blocks_as(.array, dstr.*);
        for (0..origcard) |i| {
            const key = src1array[i];
            // this branchless approach is much faster...
            dstarray[newcard] = key;

            newcard += @intFromBool(bitset_container_get(src2.blocks_as(.bitset, x2.*).ptr, key));
            // we could do it this way instead...
            // if (bitset_container_contains(src2, key)) {
            //     dst.array[newcard++] = key;
            // }
            // but if the result is unpredictible, the processor generates
            // many mispredicted branches.
            // Difference can be huge (from 3 cycles when predictible all the way
            // to 16 cycles when unpredictible.
            // See
            // https://github.com/lemire/Code-used-on-Daniel-Lemire-s-blog/blob/master/extra/bitset/c/arraybitsetintersection.c
        }
        dst.cardinality = newcard;
    }

    /// Get the cardinality of `run'. Requires an actual computation.
    fn _avx2_run_container_cardinality(
        run: Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
    ) Cardinality {
        const n_runs = run.cardinality;

        // by initializing with n_runs, we omit counting the +1 for each pair.
        var sum = n_runs;
        var k: u32 = 0;
        const step = C.BLOCK_LEN32;
        if (n_runs > step) {
            var total: root.Block32 = @splat(0);
            while (k + step <= n_runs) : (k += step) {
                const ymm1: root.Block32 = @bitCast((runs + k)[0..C.BLOCK_LEN32].*);
                const justlengths = ymm1 >> @splat(16);
                total += justlengths;
            }
            // a store might be faster than extract?
            sum += @intCast((total[0] + total[1]) + (total[2] + total[3]) +
                (total[4] + total[5]) + (total[6] + total[7]));
        }
        for (runs[k..n_runs]) |r| {
            sum += r.length;
        }

        return sum;
    }

    /// Get the cardinality of `run'. Requires an actual computation.
    fn _scalar_run_container_cardinality(
        run: Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
    ) Cardinality {
        const n_runs = run.cardinality;
        // by initializing with n_runs, we omit counting the +1 for each pair.
        var sum = n_runs;
        for (runs[0..n_runs]) |r| {
            sum += r.length;
        }
        return sum;
    }

    fn run_container_cardinality(run: Container, runs: [*]align(C.BLOCK_ALIGN) root.Rle16) Cardinality {
        // Empirically AVX-512 is not always faster than AVX2
        // TODO? _avx512_run_container_cardinality;
        return if (C.HAS_AVX2)
            _avx2_run_container_cardinality(run, runs)
        else
            _scalar_run_container_cardinality(run, runs);
    }

    /// Set all bits in indexes [begin,end) to false.
    fn bitset_reset_range(
        words: [*]align(C.BLOCK_ALIGN) u64,
        start: u32,
        end: u32,
    ) void {
        if (start == end) return;
        const firstword = start / 64;
        const endword = (end - 1) / 64;
        if (firstword == endword) {
            words[firstword] &= ~(((~@as(u64, 0)) << @truncate(start % 64)) &
                ((~@as(u64, 0)) >> @truncate((~end + 1) % 64)));
            return;
        }
        words[firstword] &= ~((~@as(u64, 0)) << @truncate(start % 64));
        @memset(words[firstword + 1 .. endword], 0);
        words[endword] &= ~((~@as(u64, 0)) >> @truncate((~end + 1) % 64));
    }

    /// Get the number of bits set (force computation)
    fn _scalar_bitset_container_compute_cardinality(
        words: [*]align(C.BLOCK_ALIGN) u64,
    ) Cardinality {
        var sum: Cardinality = 0;
        var i: u32 = 0;
        while (i < C.BITSET_CONTAINER_SIZE_IN_WORDS) : (i += 4) {
            sum += @popCount(words[i]);
            sum += @popCount(words[i + 1]);
            sum += @popCount(words[i + 2]);
            sum += @popCount(words[i + 3]);
        }
        return sum;
    }

    /// Get the number of bits set (force computation)
    fn bitset_container_compute_cardinality(words: [*]align(C.BLOCK_ALIGN) u64) Cardinality {
        // TODO avx512_vpopcount
        const x = words[0..C.BITSET_CONTAINER_SIZE_IN_WORDS];
        if (C.HAS_AVX2) {
            return @intCast(avx2_harley_seal_popcount(@ptrCast(x)));
        } else {
            return _scalar_bitset_container_compute_cardinality(x);
        }
    }

    /// Compute the intersection of src1 and src2 and write the result to
    /// dst. If dst == src2, an in-place processing is attempted.
    fn run_bitset_container_intersection(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        if (run_container_is_full(src1.*, x1.*)) {
            if (dst != src2)
                dst.* = try bitset_container_clone(src2, allocator, x2, dstr);
            return;
        }
        const src1runs = src1.blocks_as(.run, x1.*)[0..src1.cardinality];
        const src2words = src2.blocks_as(.bitset, x2.*);
        var card = run_container_cardinality(src1.*, src1runs.ptr);
        trace(@src(), "card={}", .{card});

        if (card <= C.DEFAULT_MAX_SIZE) {
            // result can only be an array (assuming that we never make a RunContainer)
            if (card > src2.cardinality) {
                card = src2.cardinality;
            }
            dst.* = try array_container_create_given_capacity(allocator, card, dstr);
            const dstarray = dst.blocks_as(.array, dstr.*);

            for (0..src1.cardinality) |rlepos| {
                const rle = src1runs[rlepos];
                const endofrun = @as(u32, rle.value) + rle.length;
                for (rle.value..endofrun + 1) |runValue| {
                    dstarray[dst.cardinality] = @truncate(runValue);
                    dst.cardinality += @intFromBool(bitset_container_get(src2words.ptr, @truncate(runValue)));
                }
            }
            return;
        }
        if (dst == src2) { // we attempt in-place
            var start: u32 = 0;
            for (0..src1.cardinality) |rlepos| {
                const rle = src1runs[rlepos];
                const end: u32 = rle.value;
                bitset_reset_range(src2words.ptr, start, end);
                start = end + rle.length + 1;
            }
            bitset_reset_range(src2words.ptr, start, C.MAX_KEY_CARDINALITY);
            dst.cardinality = bitset_container_compute_cardinality(dst.blocks_as(.bitset, dstr.*).ptr);
            if (src2.cardinality > C.DEFAULT_MAX_SIZE) {
                return;
            } else {
                dst.* = try array_container_from_bitset(src2, allocator, dstr);
                return;
            }
        } else { // no inplace
            // we expect the answer to be a bitmap (if we are lucky)
            dst.* = try bitset_container_clone(src2, allocator, x2, dstr);
            const dstwords = dst.blocks_as(.bitset, dstr.*).ptr;
            var start: u32 = 0;
            for (0..src1.cardinality) |rlepos| {
                const rle = src1runs[rlepos];
                const end: u32 = rle.value;
                bitset_reset_range(dstwords, start, end);
                start = end + rle.length + 1;
            }
            bitset_reset_range(dstwords, start, C.MAX_KEY_CARDINALITY);
            dst.cardinality = bitset_container_compute_cardinality(dstwords);

            if (dst.cardinality == 0 or dst.cardinality > C.DEFAULT_MAX_SIZE)
                return;

            const answer = try array_container_from_bitset(dst, allocator, dstr);
            dst.deinit_blocks(dstr.*);
            dst.* = answer;
        }
    }

    /// Compute the intersection of src1 and src2 and write the result to
    /// dst. It is allowed for dst to be equal to src1. We assume that dst is a
    /// valid container.
    fn array_run_container_intersection(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        assert(src1.cardinality > 0 and src2.cardinality > 0);
        dst.nblocks_minus1 = @intCast(misc.numGroupsOfSize(src1.cardinality, C.BLOCK_LEN16) - 1);
        if (run_container_is_full(src2.*, x2.*)) {
            if (dst != src1)
                try src1.array_container_copy(allocator, dst, src1.blocks_as(.array, x1.*).ptr, dstr);
            return;
        }
        if (dst.calc_capacity() < src1.cardinality)
            try array_container_grow(dst, allocator, dstr, src1.cardinality, false);
        if (src2.cardinality == 0)
            return;

        var rlepos: u32 = 0;
        var arraypos: u32 = 0;
        const src2runs = src2.blocks_as(.run, x2.*);
        var rle = src2runs[rlepos];
        var newcard: Cardinality = 0;
        const src1array = src1.blocks_as(.array, x1.*);
        const dstarray = dst.blocks_as(.array, dstr.*);
        while (arraypos < src1.cardinality) {
            const arrayval = src1array[arraypos];
            while (rle.value +% rle.length < arrayval) { // this will frequently be false
                rlepos += 1;
                if (rlepos == src2.cardinality) {
                    dst.cardinality = newcard;
                    return; // we are done
                }
                rle = src2runs[rlepos];
            }
            if (rle.value > arrayval) {
                arraypos = misc.advanceUntil(src1array[0..src1.cardinality], arraypos, rle.value);
            } else {
                dstarray[newcard] = arrayval;
                newcard += 1;
                arraypos += 1;
            }
        }
        dst.cardinality = newcard;
    }

    /// Converts a run container to either an array or a bitset, IF it saves space.
    ///
    /// If a conversion occurs, the caller is responsible to free the original
    /// container and he becomes responsible to free the new one.
    pub fn convert_run_to_efficient_container(
        c: Container,
        allocator: Allocator,
        r: *Bitmap,
    ) !Container {
        assert(c.typecode == .run);
        const runsize = c.serialized_size_in_bytes();
        const card = c.compute_cardinality(r.*);
        const arraysize = card * @sizeOf(u16);
        const min_size_non_run = @min(@sizeOf(root.Bitset), arraysize);
        if (c.cardinality == 0 or runsize <= min_size_non_run) { // no conversion
            return c;
        }
        assert(card != 0);

        if (card <= C.DEFAULT_MAX_SIZE) {
            // to array
            const cnblocks = misc.numGroupsOfSize(card * @sizeOf(u16), C.BLOCK_SIZE);
            var answer: Container = .{
                .blockoffset = @intCast(r.array.ptr(.blockslen).*),
                .cardinality = 0,
                .nblocks_minus1 = @intCast(cnblocks - 1),
                .typecode = .array,
            };
            try r.ensure_unused_capacity(allocator, 0, cnblocks);
            r.array.ptr(.blockslen).* += cnblocks;
            const array = answer.blocks_as(.array, r.*);
            const runs = c.blocks_as(.run, r.*);
            for (0..c.cardinality) |rlepos| {
                const run_start: u32 = runs[rlepos].value;
                const run_end = run_start + runs[rlepos].length;

                var run_value: u32 = @truncate(run_start);
                while (run_value <= run_end) : (run_value += 1) {
                    array[answer.cardinality] = @intCast(run_value);
                    answer.cardinality += 1;
                }
            }
            c.deinit_blocks(r.*);
            return answer;
        }
        unreachable; // TODO
        // // else to bitset
        // var answer = try BitsetContainer.create(allocator);

        // for (0..c.cardinality) |rlepos| {
        //     const start = c.runs[rlepos].value;
        //     const end = start + c.runs[rlepos].length;
        //     BitsetContainer.set_range(answer.words, start, end + 1);
        // }
        // answer.cardinality = card;
        // return .create(allocator, answer);
    }

    // like convert_run_to_efficient_container but frees the old result if needed
    fn convert_run_to_efficient_container_and_free(
        c: Container,
        allocator: Allocator,
        r: *Bitmap,
    ) !Container {
        const answer = try c.convert_run_to_efficient_container(allocator, r);
        if (answer != c) c.deinit_blocks(r.*);
        return answer;
    }

    /// Compute intersection between two containers, generate a new container.
    /// This allocates new memory, caller is responsible for deallocation.
    pub fn intersect(
        c1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        c2: *const Container,
        x2: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        // TODO // c1 = container_unwrap_shared(c1);
        // TODO // c2 = container_unwrap_shared(c2);

        var result: Container = .uninit;
        switch (misc.pair(c1.typecode, c2.typecode)) {
            misc.pair(.bitset, .bitset) => {
                try bitset_bitset_container_intersection(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.array, .array) => {
                result = try array_container_create_given_capacity(allocator, @min(c1.cardinality, c2.cardinality), dstr);
                try array_container_intersection(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.run, .run) => {
                try run_container_intersection(c1, allocator, x1, c2, x2, &result, dstr);
                return try result.convert_run_to_efficient_container_and_free(allocator, dstr);
            },
            misc.pair(.bitset, .array) => {
                result = try array_container_create_given_capacity(allocator, c2.cardinality, dstr);
                try array_bitset_container_intersection(c2, allocator, x2, c1, x1, &result, dstr);
            },
            misc.pair(.array, .bitset) => {
                result = try array_container_create_given_capacity(allocator, c1.cardinality, dstr);
                try array_bitset_container_intersection(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.bitset, .run) => {
                try run_bitset_container_intersection(c2, allocator, x2, c1, x1, &result, dstr);
            },
            misc.pair(.run, .bitset) => {
                try run_bitset_container_intersection(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.array, .run) => {
                result = try array_container_create_given_capacity(allocator, c1.cardinality, dstr);
                try array_run_container_intersection(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.run, .array) => {
                result = try array_container_create_given_capacity(allocator, c2.cardinality, dstr);
                try array_run_container_intersection(c2, allocator, x2, c1, x1, &result, dstr);
            },
            else => unreachable,
        }
        return result;
    }

    fn bitset_container_or_justcard(
        src1: [*]align(C.BLOCK_ALIGN) const u64,
        src2: [*]align(C.BLOCK_ALIGN) const u64,
    ) Cardinality {
        return @intCast(op_methods(.Or).bitset_container_op_justcard(src1, src2));
    }

    fn bitset_container_or_nocard(
        data1: [*]align(C.BLOCK_ALIGN) const u64,
        data2: [*]align(C.BLOCK_ALIGN) const u64,
        dstc: *Container,
        dst: [*]align(C.BLOCK_ALIGN) u64,
    ) Cardinality {
        return op_methods(.Or).bitset_container_op_nocard(data1, data2, dstc, dst);
    }

    fn bitset_container_or(
        src1: *const Container,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) void {
        _ = op_methods(.Or).bitset_container_op(
            src1.blocks_as(.bitset, x1.*).ptr,
            src2.blocks_as(.bitset, x2.*).ptr,
            dst,
            dst.blocks_as(.bitset, dstr.*).ptr,
        );
    }

    /// Merge two sorted array containers into one sorted array.
    fn array_container_union(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const card1 = src1.cardinality;
        const card2 = src2.cardinality;
        const max_card = card1 + card2;
        const c1id = src1 - x1.array.ptr(.containers);
        const c2id = src2 - x2.array.ptr(.containers);
        if (dst.calc_capacity() < max_card)
            try dst.array_container_grow(allocator, dstr, max_card, false);

        dst.cardinality = @intCast(misc.fast_union_uint16(
            x1.array.ptr(.containers)[c1id].blocks_as(.array, x1.*)[0..card1],
            x2.array.ptr(.containers)[c2id].blocks_as(.array, x2.*)[0..card2],
            dst.blocks_as(.array, dstr.*),
        ));
    }

    /// Compute the union of two array containers.
    /// Writes result into dst. Returns true if result is a bitset.
    fn array_array_container_union(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const card1 = src1.cardinality;
        const card2 = src2.cardinality;
        const totalCardinality = card1 + card2;

        if (totalCardinality <= C.DEFAULT_MAX_SIZE) {
            dst.* = try array_container_create_given_capacity(allocator, totalCardinality, dstr);
            try array_container_union(src1, allocator, x1, src2, x2, dst, dstr);
            return;
        }

        dst.* = try bitset_container_create(allocator, dstr);
        const dstwords = dst.blocks_as(.bitset, dstr.*);
        for (src1.blocks_as(.array, x1.*)[0..card1]) |v|
            dst.bitset_container_set(v, dstwords);
        for (src2.blocks_as(.array, x2.*)[0..card2]) |v|
            dst.bitset_container_set(v, dstwords);

        if (dst.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst, allocator, dstr);
            dst.deinit_blocks(dstr.*);
            dst.* = answer;
        }
    }

    /// Append run vl to a run container, merging if overlapping/adjacent.
    ///
    /// It is assumed that the run would be inserted at the end of the container, no
    /// check is made.
    /// It is assumed that the run container has the necessary capacity: caller is
    /// responsible for checking memory capacity.
    ///
    /// This is not a safe function, it is meant for performance: use with care.
    fn run_container_append(
        run: *Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
        vl: root.Rle16,
        previousrl: *root.Rle16,
    ) void {
        const previousend = @as(u32, previousrl.value) + previousrl.length;
        if (vl.value > previousend + 1) { // we add a new one
            runs[run.cardinality] = vl;
            run.cardinality += 1;
            previousrl.* = vl;
        } else {
            const newend = @as(u32, vl.value) + vl.length + 1;
            if (newend > previousend) { // we merge
                previousrl.length = @truncate(newend - 1 - previousrl.value);
                runs[run.cardinality - 1] = previousrl.*;
            }
        }
    }

    /// Like run_container_append but it is assumed that the content of run is empty.
    fn run_container_append_first(
        run: *Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
        vl: root.Rle16,
    ) root.Rle16 {
        runs[run.cardinality] = vl;
        run.cardinality += 1;
        return vl;
    }

    fn run_container_union(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const if1 = run_container_is_full(src1.*, x1.*);
        const if2 = run_container_is_full(src2.*, x2.*);
        if (if1 or if2) {
            if (if1) {
                try src1.run_container_copy(allocator, dst, src1.blocks_as(.run, x1.*).ptr, dstr);
                return;
            }
            if (if2) {
                try src2.run_container_copy(allocator, dst, src2.blocks_as(.run, x2.*).ptr, dstr);
                return;
            }
        }

        const neededcapacity = src1.cardinality + src2.cardinality;
        if (dst.calc_capacity() < neededcapacity)
            try run_container_grow(dst, allocator, neededcapacity, false, dstr);

        dst.cardinality = 0;
        var rlepos: u32 = 0;
        var xrlepos: u32 = 0;
        const src1runs = src1.blocks_as(.run, x1.*);
        const src2runs = src2.blocks_as(.run, x2.*);
        const dstruns = dst.blocks_as(.run, dstr.*);

        var previousrle: root.Rle16 = .{ .value = 0, .length = 0 };
        if (src1runs[rlepos].value <= src2runs[xrlepos].value) {
            previousrle = run_container_append_first(dst, dstruns.ptr, src1runs[rlepos]);
            rlepos += 1;
        } else {
            previousrle = run_container_append_first(dst, dstruns.ptr, src2runs[xrlepos]);
            xrlepos += 1;
        }

        while (xrlepos < src2.cardinality and rlepos < src1.cardinality) {
            const newrl = if (src1runs[rlepos].value <= src2runs[xrlepos].value) rl: {
                defer rlepos += 1;
                break :rl src1runs[rlepos];
            } else rl: {
                defer xrlepos += 1;
                break :rl src2runs[xrlepos];
            };
            run_container_append(dst, dstruns.ptr, newrl, &previousrle);
        }
        while (xrlepos < src2.cardinality) {
            run_container_append(dst, dstruns.ptr, src2runs[xrlepos], &previousrle);
            xrlepos += 1;
        }
        while (rlepos < src1.cardinality) {
            run_container_append(dst, dstruns.ptr, src1runs[rlepos], &previousrle);
            rlepos += 1;
        }
    }

    /// unlike croaring which uses memcpy, src and dst aren't assumed distinct
    /// here.
    ///
    /// Note: memmove is necessary to avoid panics due to aliasing.
    fn bitset_container_copy(dst: *Container, dstr: *Bitmap, src: Container, x: Bitmap) void {
        dst.cardinality = src.cardinality;
        @memmove(dst.blocks_as(.bitset, dstr.*), src.blocks_as(.bitset, x));
    }

    fn bitset_set_list_withcard(
        words: []align(C.BLOCK_ALIGN) u64,
        card: u64,
        list: []align(C.BLOCK_ALIGN) const u16,
    ) u64 {
        if (C.HAS_AVX2) {
            // TODO _asm_bitset_set_list_withcard
        }
        // _scalar_bitset_set_list_withcard
        var card_out = card;
        for (list) |pos| {
            const offset = pos >> 6;
            const index: u6 = @truncate(pos & 63);
            const load = words[offset];
            const newload = load | (@as(u64, 1) << index);
            card_out += @intCast((load ^ newload) >> index);
            words[offset] = newload;
        }
        return card_out;
    }

    fn array_bitset_container_union(
        src1: *const Container,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) void {
        bitset_container_copy(dst, dstr, src2.*, x2.*);
        dst.cardinality = @intCast(bitset_set_list_withcard(
            dst.blocks_as(.bitset, dstr.*),
            dst.cardinality,
            src1.blocks_as(.array, x1.*)[0..src1.cardinality],
        ));
    }

    fn run_container_append_value(
        run: *Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
        val: u16,
        previousrl: *root.Rle16,
    ) void {
        const prev_end = @as(u32, previousrl.value) + previousrl.length;
        if (val > prev_end + 1) {
            const newrle = root.Rle16{ .value = val, .length = 0 };
            runs[run.cardinality] = newrle;
            run.cardinality += 1;
            previousrl.* = newrle;
        } else if (val == prev_end + 1) {
            previousrl.length += 1;
            runs[run.cardinality - 1] = previousrl.*;
        }
    }

    fn run_container_append_value_first(
        run: *Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
        val: u16,
    ) root.Rle16 {
        const newrle = root.Rle16{ .value = val, .length = 0 };
        runs[run.cardinality] = newrle;
        run.cardinality += 1;
        return newrle;
    }

    fn array_run_container_union(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        if (run_container_is_full(src2.*, x2.*)) {
            try run_container_copy(src2.*, allocator, dst, src2.blocks_as(.run, x2.*).ptr, dstr);
            return;
        }

        const card1 = src1.cardinality;
        const card2 = src2.cardinality;
        const src1id = src1 - x1.array.ptr(.containers);
        const src2id = src2 - x2.array.ptr(.containers);
        if (dst.calc_capacity() < 2 * (card1 + card2))
            try run_container_grow(dst, allocator, 2 * (card1 + card2), false, dstr);
        const src1b = &x1.array.ptr(.containers)[src1id];
        const src2b = &x2.array.ptr(.containers)[src2id];
        const arr = src1b.blocks_as(.array, x1.*);
        const srcruns = src2b.blocks_as(.run, x2.*);
        const dstruns = dst.blocks_as(.run, dstr.*);
        var rp: u32 = 0;
        var ap: u32 = 0;
        var prev: root.Rle16 = undefined;

        if (srcruns[rp].value <= arr[ap]) {
            prev = run_container_append_first(dst, dstruns.ptr, srcruns[rp]);
            rp += 1;
        } else {
            prev = run_container_append_value_first(dst, dstruns.ptr, arr[ap]);
            ap += 1;
        }
        while (rp < card2 and ap < card1) {
            if (srcruns[rp].value <= arr[ap]) {
                run_container_append(dst, dstruns.ptr, srcruns[rp], &prev);
                rp += 1;
            } else {
                run_container_append_value(dst, dstruns.ptr, arr[ap], &prev);
                ap += 1;
            }
        }
        while (ap < card1) {
            run_container_append_value(dst, dstruns.ptr, arr[ap], &prev);
            ap += 1;
        }
        while (rp < card2) {
            run_container_append(dst, dstruns.ptr, srcruns[rp], &prev);
            rp += 1;
        }
    }

    /// TODO: write smart_append_exclusive version to match the overloaded 1 param
    /// Java version (or  is it even used?)
    ///
    /// follows the Java implementation closely
    /// length is the rle-value.  Ie, run [10,12) uses a length value 1.
    fn run_container_smart_append_exclusive(
        src: *Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
        start: u16,
        length: u16,
    ) void {
        var old_end: u32 = undefined;
        const last_run = if (src.cardinality != 0) runs + (src.cardinality - 1) else undefined;
        const appended_last_run = runs + src.cardinality;

        if (src.cardinality == 0 or
            (start > blk: {
                old_end = @as(u32, last_run[0].value) + last_run[0].length + 1;
                break :blk old_end;
            }))
        {
            appended_last_run[0] = .{ .value = start, .length = length };
            src.cardinality += 1;
            return;
        }
        if (old_end == start) { // we merge
            last_run[0].length += (length + 1);
            return;
        }
        const new_end = @as(u32, start) + length + 1;

        if (start == last_run[0].value) { // wipe out previous
            if (new_end < old_end) {
                last_run[0] = .{
                    .value = @intCast(new_end),
                    .length = @intCast(old_end - new_end - 1),
                };
                return;
            } else if (new_end > old_end) {
                last_run[0] = .{
                    .value = @intCast(old_end),
                    .length = @intCast(new_end - old_end - 1),
                };
                return;
            } else {
                src.cardinality -= 1;
                return;
            }
        }
        last_run[0].length = start - last_run[0].value - 1;
        if (new_end < old_end) {
            appended_last_run[0] = .{
                .value = @intCast(new_end),
                .length = @intCast(old_end - new_end - 1),
            };
            src.cardinality += 1;
        } else if (new_end > old_end) {
            appended_last_run[0] = .{
                .value = @intCast(old_end),
                .length = @intCast(new_end - old_end - 1),
            };
            src.cardinality += 1;
        }
    }

    fn run_bitset_container_union(
        src1: *const Container,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) void {
        assert(!run_container_is_full(src1.*, x1.*)); // catch this case upstream
        if (src2 != dst) bitset_container_copy(dst, dstr, src2.*, x2.*);
        const runs = src1.blocks_as(.run, x1.*);
        const dwords = dst.blocks_as(.bitset, dstr.*);
        for (runs[0..src1.cardinality]) |rle| {
            misc.bitset_set_lenrange(dwords.ptr, rle.value, rle.length);
        }
        dst.cardinality = @intCast(dst.compute_cardinality(dstr.*));
    }

    pub fn append_first(c: *Container, r: Bitmap, container_value: anytype) void {
        switch (@TypeOf(container_value)) {
            Rle16 => {
                assert(c.typecode == .run);
                const runs = c.blocks_as(.run, r);
                runs[c.cardinality] = container_value;
                c.cardinality += 1;
            },
            u16 => {
                assert(c.typecode == .array);
                const array = c.blocks_as(.array, r);
                array[c.cardinality] = container_value;
                c.cardinality += 1;
            },
            else => unreachable, // unsupported type
        }
    }

    /// The new container consists of a single run [start,stop).
    /// It is required that stop>start, the caller is responsability for this check.
    /// It is required that stop <= (1<<16), the caller is responsability for this
    /// check. The cardinality of the created container is stop - start.
    pub fn run_container_create_range(
        allocator: Allocator,
        start: u32,
        stop: u32,
        r: *Bitmap,
    ) !Container {
        var rc = try Container.run_container_create_given_capacity(allocator, 1, r);
        rc.append_first(r.*, root.Rle16{
            .value = @intCast(start),
            .length = @intCast(stop - start - 1),
        });
        return rc;
    }

    /// Compute the union of src1 and src2 and write the result to src1
    fn run_container_union_inplace(
        src1: *Container,
        allocator: Allocator,
        x1: *Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
    ) !void {
        // TODO: this could be a lot more efficient

        // we start out with inexpensive checks
        const if1 = run_container_is_full(src1.*, x1.*);
        const if2 = run_container_is_full(src2.*, x2.*);
        if (if1 or if2) {
            if (if1) return;
            if (if2) {
                try run_container_copy(src2.*, allocator, src1, src2.blocks_as(.run, x2.*).ptr, x1);
                return;
            }
        }
        // we move the data to the end of the current array
        const maxoutput: u32 = src1.cardinality + src2.cardinality;
        const neededcapacity = maxoutput + src1.cardinality;
        const src1id = src1 - x1.array.ptr(.containers);
        const src2id = src2 - x2.array.ptr(.containers);
        if (src1.calc_capacity() < neededcapacity)
            try run_container_grow(src1, allocator, neededcapacity, true, x1);
        const src1b = &x1.array.ptr(.containers)[src1id];
        const src1runs = src1b.blocks_as(.run, x1.*);
        const inputsrc1 = src1runs.ptr + maxoutput;
        @memmove(inputsrc1, src1runs[0..src1b.cardinality]);
        const input1nruns = src1b.cardinality;
        src1b.cardinality = 0;
        var rlepos: u32 = 0;
        var xrlepos: u32 = 0;

        var previousrle: Rle16 = undefined;
        const src2b = &x2.array.ptr(.containers)[src2id];
        const src2runs = src2b.blocks_as(.run, x2.*);
        if (inputsrc1[rlepos].value <= src2runs[xrlepos].value) {
            previousrle = run_container_append_first(src1b, src1runs.ptr, inputsrc1[rlepos]);
            rlepos += 1;
        } else {
            previousrle = run_container_append_first(src1b, src1runs.ptr, src2runs[xrlepos]);
            xrlepos += 1;
        }
        while ((xrlepos < src2b.cardinality) and (rlepos < input1nruns)) {
            var newrl: Rle16 = undefined;
            if (inputsrc1[rlepos].value <= src2runs[xrlepos].value) {
                newrl = inputsrc1[rlepos];
                rlepos += 1;
            } else {
                newrl = src2runs[xrlepos];
                xrlepos += 1;
            }
            run_container_append(src1b, src1runs.ptr, newrl, &previousrle);
        }
        while (xrlepos < src2b.cardinality) {
            run_container_append(src1b, src1runs.ptr, src2runs[xrlepos], &previousrle);
            xrlepos += 1;
        }
        while (rlepos < input1nruns) {
            run_container_append(src1b, src1runs.ptr, inputsrc1[rlepos], &previousrle);
            rlepos += 1;
        }
    }

    /// Merge src1's array values into src2's runs in place.
    fn array_run_container_inplace_union(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *Container,
        x2: *Bitmap,
    ) !void {
        if (run_container_is_full(src2.*, x2.*)) return;
        const maxoutput = src1.cardinality + src2.cardinality;
        const neededcapacity = maxoutput + src2.cardinality;
        assert(neededcapacity < C.MAX_RUN_SIZE);
        const src1id = src1 - x1.array.ptr(.containers);
        const src2id = src2 - x2.array.ptr(.containers);
        if (src2.calc_capacity() < neededcapacity)
            try run_container_grow(src2, allocator, neededcapacity, true, x2);

        const src1b = &x1.array.ptr(.containers)[src1id];
        const src2b = &x2.array.ptr(.containers)[src2id];
        const src2runs = src2b.blocks_as(.run, x2.*);
        const src1arr = src1b.blocks_as(.array, x1.*);

        const inputsrc2 = src2runs.ptr + maxoutput;
        @memmove(inputsrc2, src2runs[0..src2b.cardinality]);

        var rlepos: u32 = 0;
        var arraypos: u32 = 0;
        const src2nruns = src2b.cardinality;
        src2b.cardinality = 0;

        var previousrle: root.Rle16 = undefined;
        if (inputsrc2[rlepos].value <= src1arr[arraypos]) {
            previousrle = run_container_append_first(src2b, src2runs.ptr, inputsrc2[rlepos]);
            rlepos += 1;
        } else {
            previousrle = run_container_append_value_first(src2b, src2runs.ptr, src1arr[arraypos]);
            arraypos += 1;
        }

        while (rlepos < src2nruns and arraypos < src1b.cardinality) {
            if (inputsrc2[rlepos].value <= src1arr[arraypos]) {
                run_container_append(src2b, src2runs.ptr, inputsrc2[rlepos], &previousrle);
                rlepos += 1;
            } else {
                run_container_append_value(src2b, src2runs.ptr, src1arr[arraypos], &previousrle);
                arraypos += 1;
            }
        }
        if (arraypos < src1b.cardinality) {
            while (arraypos < src1.cardinality) {
                run_container_append_value(src2b, src2runs.ptr, src1arr[arraypos], &previousrle);
                arraypos += 1;
            }
        } else {
            while (rlepos < src2nruns) {
                run_container_append(src2b, src2runs.ptr, inputsrc2[rlepos], &previousrle);
                rlepos += 1;
            }
        }
    }

    /// create bitset, union with run/array containers c1 and c2, then run
    /// optimize. this is a workaround from croaring due to nblocks_minus1 limit
    /// [0, C.BITSET_BLOCKS).
    // TODO can we do better than this?
    fn run_array_conatiner_inplace_union(
        c1: *Container,
        allocator: Allocator,
        x1: *Bitmap,
        c2: *const Container,
        x2: *const Bitmap,
    ) !Container {
        const c1id = c1 - x1.array.ptr(.containers);
        const tmpcid = x1.array.ptr(.len).*;
        var result = try bitset_container_create(allocator, x1);
        errdefer result.deinit(x1.*);
        array_bitset_container_union(c2, x2, &result, x1, &result, x1);
        run_bitset_container_union(&x1.array.ptr(.containers)[c1id], x1, &result, x1, &result, x1);

        // temporarily insert result into containers for convert_run_optimize
        try x1.insert_new_key_value_at(allocator, undefined, result, tmpcid);
        defer x1.array.ptr(.len).* -= 1;
        return try convert_run_optimize(tmpcid, allocator, x1);
    }

    fn array_array_container_inplace_union(
        src1: *Container,
        allocator: Allocator,
        x1: *Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const totalCardinality = src1.cardinality + src2.cardinality;
        dst.* = uninit;
        var src1array = src1.blocks_as(.array, x1.*)[0..src1.cardinality];
        var src2array = src2.blocks_as(.array, x2.*)[0..src2.cardinality];
        const src1id = src1 - x1.array.ptr(.containers);
        const src2id = src2 - x2.array.ptr(.containers);
        if (totalCardinality <= C.DEFAULT_MAX_SIZE) {
            if (src1.calc_capacity() < totalCardinality) {
                dst.* = try array_container_create_given_capacity(
                    allocator,
                    @min(C.DEFAULT_MAX_SIZE, 2 * totalCardinality), // be purposefully generous
                    dstr,
                );
                try array_container_union( // zig fmt: off
                    &x1.array.ptr(.containers)[src1id], allocator, x1,
                    &x2.array.ptr(.containers)[src2id], x2,
                    dst, dstr,
                );// zig fmt: on
                return;
            } else {
                @memmove(src1array.ptr + src2.cardinality, src1array);
                // In theory, we could use fast_union_uint16, but it is unsafe. It
                // fails with Intel compilers in particular.
                // https://github.com/RoaringBitmap/CRoaring/pull/452
                // See report https://github.com/RoaringBitmap/CRoaring/issues/476
                src1array.len = src1.calc_capacity();
                src1.cardinality = @intCast(misc.union_uint16(
                    src1array[src2.cardinality..][0..src1.cardinality],
                    src2array,
                    src1array,
                ));
                return;
            }
        }

        dst.* = try bitset_container_create(allocator, dstr);
        var src1b = &x1.array.ptr(.containers)[src1id];
        const src2b = &x2.array.ptr(.containers)[src2id];
        var dstcopy = dst.*;
        {
            const dstcopywords = dstcopy.blocks_as(.bitset, dstr.*);
            const src1barray = src1b.blocks_as(.array, x1.*)[0..src1b.cardinality];
            src2array = src2b.blocks_as(.array, x2.*)[0..src2b.cardinality];
            misc.bitset_set_list(dstcopywords.ptr, src1barray);
            dstcopy.cardinality = @intCast(bitset_set_list_withcard(
                dstcopywords,
                src1b.cardinality,
                src2array,
            ));
        }
        dst.* = dstcopy;

        if (dstcopy.cardinality <= C.DEFAULT_MAX_SIZE) {
            // need to convert!
            if (src1b.calc_capacity() < dstcopy.cardinality) {
                try array_container_grow(src1b, allocator, x1, dstcopy.cardinality, false);
            }
            src1b = &x1.array.ptr(.containers)[src1id];
            src1array = src1b.blocks_as(.array, x1.*);
            const dstcopywords = dstcopy.blocks_as(.bitset, dstr.*);
            _ = bitset_extract_setbits_uint16(dstcopywords.ptr, src1array, 0);
            src1b.cardinality = dstcopy.cardinality;
            dst.* = src1b.*;
            dstcopy.deinit_blocks(dstr.*);
        }
    }

    /// In-place union. Modifies c1 when possible, otherwise allocates new
    /// container in x1. Returns the resulting container. Caller must free c1's
    /// old blocks when blockoffset differs from original.
    pub fn ior(
        c1: *Container,
        allocator: Allocator,
        x1: *Bitmap,
        c2: *const Container,
        x2: *const Bitmap,
    ) !Container {
        // TODO // c1 = get_writable_copy_if_shared(c1);
        // TODO // c2 = container_unwrap_shared(c2);
        // trace(@src(), "{t} {t}", .{ c1.typecode, c2.typecode });
        switch (misc.pair(c1.typecode, c2.typecode)) {
            misc.pair(.bitset, .bitset) => {
                bitset_container_or(c1, x1, c2, x2, c1, x1);
                if (C.OR_BITSET_CONVERSION_TO_FULL and
                    c1.cardinality == C.MAX_KEY_CARDINALITY)
                {
                    return try run_container_create_range(allocator, 0, C.MAX_KEY_CARDINALITY, x1);
                }
                return c1.*;
            },
            misc.pair(.array, .array) => {
                var result: Container = .uninit;
                const c1id = c1 - x1.array.ptr(.containers);
                try array_array_container_inplace_union(c1, allocator, x1, c2, x2, &result, x1);
                const c1b = x1.array.ptr(.containers)[c1id];
                if (result == uninit and c1b.typecode == .array)
                    return c1b; // the computation was done in-place!
                return result;
            },
            misc.pair(.run, .run) => {
                const c1id = c1 - x1.array.ptr(.containers);
                try run_container_union_inplace(c1, allocator, x1, c2, x2);
                return try x1.array.ptr(.containers)[c1id].convert_run_to_efficient_container(allocator, x1);
            },
            misc.pair(.bitset, .array) => {
                array_bitset_container_union(c2, x2, c1, x1, c1, x1);
                return c1.*;
            },
            misc.pair(.array, .bitset) => {
                // c1 is an array, so no in-place possible
                const c1id = c1 - x1.array.ptr(.containers);
                var result = try bitset_container_create(allocator, x1);
                array_bitset_container_union(&x1.array.ptr(.containers)[c1id], x1, c2, x2, &result, x1);
                return result;
            },
            misc.pair(.bitset, .run) => {
                if (run_container_is_full(c2.*, x2.*)) {
                    var result = try run_container_create_given_capacity(allocator, 1, x1);
                    try c2.run_container_copy(allocator, &result, c2.blocks_as(.run, x2.*).ptr, x1);
                    return result;
                }
                run_bitset_container_union(c2, x2, c1, x1, c1, x1);
                return c1.*;
            },
            misc.pair(.run, .bitset) => {
                if (run_container_is_full(c1.*, x1.*)) return c1.*;
                const c1id = c1 - x1.array.ptr(.containers);
                var result = try bitset_container_create(allocator, x1);
                run_bitset_container_union(&x1.array.ptr(.containers)[c1id], x1, c2, x2, &result, x1);
                return result;
            },
            misc.pair(.array, .run) => {
                var result: Container = .uninit;
                try array_run_container_union(c1, allocator, x1, c2, x2, &result, x1);
                result = try result.convert_run_to_efficient_container_and_free(allocator, x1);
                return result;
            },
            misc.pair(.run, .array) => {
                // limit blocks to [0, C.BITSET_BLOCKS). in croaring this branch isn't needed.
                if (c1.cardinality + 2 * c2.cardinality <= C.MAX_RUN_SIZE) {
                    const c1id = c1 - x1.array.ptr(.containers);
                    try array_run_container_inplace_union(c2, allocator, x2, c1, x1);
                    return try x1.array.ptr(.containers)[c1id]
                        .convert_run_to_efficient_container(allocator, x1);
                }
                return try run_array_conatiner_inplace_union(c1, allocator, x1, c2, x2);
            },
            else => unreachable,
        }
    }

    /// perform an 'or' operation (union) on the container.
    pub fn merge(
        c1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        c2: *const Container,
        x2: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        var result: Container = .uninit;
        switch (misc.pair(c1.typecode, c2.typecode)) {
            misc.pair(.bitset, .bitset) => {
                result = try bitset_container_create(allocator, dstr);
                bitset_container_or(c1, x1, c2, x2, &result, dstr);
            },
            misc.pair(.array, .array) => {
                try array_array_container_union(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.run, .run) => {
                try run_container_union(c1, allocator, x1, c2, x2, &result, dstr);
                result = try result.convert_run_to_efficient_container_and_free(allocator, dstr);
            },
            misc.pair(.bitset, .array) => {
                result = try bitset_container_create(allocator, dstr);
                array_bitset_container_union(c2, x2, c1, x1, &result, dstr);
            },
            misc.pair(.array, .bitset) => {
                result = try bitset_container_create(allocator, dstr);
                array_bitset_container_union(c1, x1, c2, x2, &result, dstr);
            },
            misc.pair(.bitset, .run) => {
                if (run_container_is_full(c2.*, x2.*)) {
                    try run_container_copy(c2.*, allocator, &result, c2.blocks_as(.run, x2.*).ptr, dstr);
                } else {
                    result = try bitset_container_create(allocator, dstr);
                    run_bitset_container_union(c2, x2, c1, x1, &result, dstr);
                }
            },
            misc.pair(.run, .bitset) => {
                if (run_container_is_full(c1.*, x1.*)) {
                    try c1.run_container_copy(allocator, &result, c1.blocks_as(.run, x1.*).ptr, dstr);
                } else {
                    result = try bitset_container_create(allocator, dstr);
                    run_bitset_container_union(c1, x1, c2, x2, &result, dstr);
                }
            },
            misc.pair(.array, .run) => {
                try array_run_container_union(c1, allocator, x1, c2, x2, &result, dstr);
                result = try result.convert_run_to_efficient_container_and_free(allocator, dstr);
            },
            misc.pair(.run, .array) => {
                try array_run_container_union(c2, allocator, x2, c1, x1, &result, dstr);
                result = try result.convert_run_to_efficient_container_and_free(allocator, dstr);
            },
            else => unreachable,
        }
        return result;
    }

    fn bitset_container_xor(
        src1: *const Container,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) void {
        _ = op_methods(.Xor).bitset_container_op(
            src1.blocks_as(.bitset, x1.*).ptr,
            src2.blocks_as(.bitset, x2.*).ptr,
            dst,
            dst.blocks_as(.bitset, dstr.*).ptr,
        );
    }

    fn bitset_bitset_container_xor(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        dst.* = try bitset_container_create(allocator, dstr);
        bitset_container_xor(src1, x1, src2, x2, dst, dstr);
        if (dst.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst, allocator, dstr);
            dst.deinit_blocks(dstr.*);
            dst.* = answer;
        }
    }

    fn array_container_xor(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const card1 = src1.cardinality;
        const card2 = src2.cardinality;
        const max_card = card1 + card2;
        if (dst.calc_capacity() < max_card)
            try dst.array_container_grow(allocator, dstr, max_card, false);

        if (C.HAS_AVX2) {
            // TODO xor_vector16()
        }
        dst.cardinality = @intCast(misc.xor_uint16(
            src1.blocks_as(.array, x1.*)[0..card1],
            src2.blocks_as(.array, x2.*)[0..card2],
            dst.blocks_as(.array, dstr.*),
        ));
    }

    /// Compute the xor of src1 and src2 and write the result to dst (which
    /// has no container initially).
    fn array_bitset_container_xor(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        assert(dst.* == uninit);
        dst.* = try bitset_container_create(allocator, dstr);
        bitset_container_copy(dst, dstr, src2.*, x2.*);
        dst.cardinality = @intCast(misc.bitset_flip_list_withcard(
            dst.blocks_as(.bitset, dstr.*).ptr,
            dst.cardinality,
            src1.blocks_as(.array, x1.*)[0..src1.cardinality],
        ));
        if (dst.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst, allocator, dstr);
            dst.deinit_blocks(dstr.*);
            dst.* = answer;
        }
    }

    fn array_array_container_xor(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const card1 = src1.cardinality;
        const card2 = src2.cardinality;
        const totalCardinality = card1 + card2;

        if (totalCardinality <= C.DEFAULT_MAX_SIZE) {
            const src1id = src1 - x1.array.ptr(.containers);
            dst.* = try array_container_create_given_capacity(allocator, totalCardinality, dstr);
            try array_container_xor(&x1.array.ptr(.containers)[src1id], allocator, x1, src2, x2, dst, dstr);
            return;
        }

        dst.* = try bitset_container_from_array2(src1, allocator, x1, dstr);
        const dstwords = dst.blocks_as(.bitset, dstr.*);
        dst.cardinality = @intCast(misc.bitset_flip_list_withcard(
            dstwords.ptr,
            dst.cardinality,
            src2.blocks_as(.array, x2.*)[0..card2],
        ));

        if (dst.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst, allocator, dstr);
            dst.deinit_blocks(dstr.*);
            dst.* = answer;
        }
    }

    /// Compute the xor of src1 and src2 and write the result to dst. Result
    /// may be either a bitset or an array container. dst does not initially
    /// have any container.
    fn run_bitset_container_xor(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        assert(dst.* == uninit);
        dst.* = try bitset_container_create(allocator, dstr);
        bitset_container_copy(dst, dstr, src2.*, x2.*);
        const runs = src1.blocks_as(.run, x1.*);
        const dwords = dst.blocks_as(.bitset, dstr.*);
        for (runs[0..src1.cardinality]) |rle| {
            misc.bitset_flip_range(dwords.ptr, rle.value, @as(u32, rle.value) + rle.length + 1);
        }
        dst.cardinality = dst.compute_cardinality(dstr.*);
        if (dst.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst, allocator, dstr);
            dst.deinit_blocks(dstr.*);
            dst.* = answer;
        }
    }

    fn run_run_container_xor(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        try run_container_xor(src1, allocator, x1, src2, x2, dst, dstr);
        dst.* = try convert_run_to_efficient_container_and_free(dst.*, allocator, dstr);
    }

    /// Compute the symmetric difference of `src1` and `src2` and write the
    /// result to `dst`. It is assumed that `dst` is distinct from both `src1`
    /// and `src2`.
    fn run_container_xor(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const nruns1 = src1.cardinality;
        const nruns2 = src2.cardinality;
        const neededcapacity = nruns1 + nruns2;
        if (dst.calc_capacity() < neededcapacity)
            try run_container_grow(dst, allocator, neededcapacity, false, dstr);
        dst.cardinality = 0;

        const src1runs = src1.blocks_as(.run, x1.*);
        const src2runs = src2.blocks_as(.run, x2.*);
        const dstruns = dst.blocks_as(.run, dstr.*);

        var pos1: u32 = 0;
        var pos2: u32 = 0;
        while (pos1 < nruns1 and pos2 < nruns2) {
            if (src1runs[pos1].value <= src2runs[pos2].value) {
                run_container_smart_append_exclusive(dst, dstruns.ptr, src1runs[pos1].value, src1runs[pos1].length);
                pos1 += 1;
            } else {
                run_container_smart_append_exclusive(dst, dstruns.ptr, src2runs[pos2].value, src2runs[pos2].length);
                pos2 += 1;
            }
        }
        while (pos1 < nruns1) {
            run_container_smart_append_exclusive(dst, dstruns.ptr, src1runs[pos1].value, src1runs[pos1].length);
            pos1 += 1;
        }
        while (pos2 < nruns2) {
            run_container_smart_append_exclusive(dst, dstruns.ptr, src2runs[pos2].value, src2runs[pos2].length);
            pos2 += 1;
        }
    }

    fn array_run_container_lazy_xor(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        if (dst.calc_capacity() < src1.cardinality + src2.cardinality)
            try run_container_grow(dst, allocator, src1.cardinality + src2.cardinality, false, dstr);
        dst.cardinality = 0;

        const dstruns = dst.blocks_as(.run, dstr.*);
        const src2runs = src2.blocks_as(.run, x2.*);
        const src1array = src1.blocks_as(.array, x1.*);
        var rlepos: u32 = 0;
        var arraypos: u32 = 0;
        while (rlepos < src2.cardinality and arraypos < src1.cardinality) {
            if (src2runs[rlepos].value <= src1array[arraypos]) {
                run_container_smart_append_exclusive(
                    dst,
                    dstruns.ptr,
                    src2runs[rlepos].value,
                    src2runs[rlepos].length,
                );
                rlepos += 1;
            } else {
                run_container_smart_append_exclusive(dst, dstruns.ptr, src1array[arraypos], 0);
                arraypos += 1;
            }
        }
        while (arraypos < src1.cardinality) {
            run_container_smart_append_exclusive(dst, dstruns.ptr, src1array[arraypos], 0);
            arraypos += 1;
        }
        while (rlepos < src2.cardinality) {
            run_container_smart_append_exclusive(
                dst,
                dstruns.ptr,
                src2runs[rlepos].value,
                src2runs[rlepos].length,
            );
            rlepos += 1;
        }
    }

    fn array_container_from_run(
        run: *const Container,
        allocator: Allocator,
        runr: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        const runcard = run_container_cardinality(run.*, run.blocks_as(.run, runr.*).ptr);
        var answer = try array_container_create_given_capacity(allocator, runcard, dstr);
        answer.cardinality = 0;
        const runs = run.blocks_as(.run, runr.*);
        const array = answer.blocks_as(.array, dstr.*);
        for (0..run.cardinality) |rlepos| {
            const run_start: u32 = runs[rlepos].value;
            const run_end = run_start + runs[rlepos].length;
            for (run_start..run_end + 1) |run_value| {
                array[answer.cardinality] = @truncate(run_value);
                answer.cardinality += 1;
            }
        }
        return answer;
    }

    fn bitset_container_from_run(
        run: *const Container,
        allocator: Allocator,
        runr: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        const runid = run - runr.array.ptr(.containers);
        const runs = run.blocks_as(.run, runr.*);
        const card = run_container_cardinality(run.*, runs.ptr);
        var answer = try bitset_container_create(allocator, dstr);
        const words = answer.blocks_as(.bitset, dstr.*);
        const run2 = runr.array.ptr(.containers)[runid];
        for (run2.blocks_as(.run, runr.*)[0..run2.cardinality]) |rle| {
            misc.bitset_set_lenrange(words.ptr, rle.value, rle.length);
        }
        answer.cardinality = card;
        return answer;
    }

    /// Compute the xor of src1 and src2 and write the result to
    /// dst (which has no container initially).  It will modify src1
    /// to be dst if the result is a bitset.  Otherwise, it will
    /// free src1 and dst will be a new array container.  In both
    /// cases, the caller is responsible for deallocating dst.
    fn bitset_array_container_ixor(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        dst.* = try bitset_container_clone(src1, allocator, x1, dstr);
        const src2array = src2.blocks_as(.array, x2.*);
        dst.cardinality = @intCast(misc.bitset_flip_list_withcard(
            dst.blocks_as(.bitset, dstr.*).ptr,
            src1.cardinality,
            src2array[0..src2.cardinality],
        ));

        if (dst.cardinality <= C.DEFAULT_MAX_SIZE) {
            const ans = try array_container_from_bitset(dst, allocator, dstr);
            dst.deinit_blocks(dstr.*);
            dst.* = ans;
        }
    }

    /// dst does not indicate a valid container initially.  Eventually it
    /// can become any kind of container.
    fn array_run_container_xor(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        // semi following Java XOR implementation as of May 2016
        // the C OR implementation works quite differently and can return a run
        // container
        // TODO could optimize for full run containers.

        // use of lazy following Java impl.
        const arbitrary_threshold = 32;
        if (src1.cardinality < arbitrary_threshold) {
            var ans = try run_container_create_given_capacity(allocator, src1.cardinality + src2.cardinality, dstr);
            try array_run_container_lazy_xor(src1, allocator, x1, src2, x2, &ans, dstr); // keeps runs.
            dst.* = try convert_run_to_efficient_container_and_free(ans, allocator, dstr);
            return;
        }

        const card = run_container_cardinality(src2.*, src2.blocks_as(.run, x2.*).ptr);
        if (card <= C.DEFAULT_MAX_SIZE) {
            // Java implementation works with the array, xoring the run elements via
            // iterator

            const temp = try array_container_from_run(src2, allocator, x2, dstr);
            // avoid using stack pointer: temporarily insert temp into dstr containers
            const tmpcid = dstr.array.ptr(.len).*;
            try dstr.insert_new_key_value_at(allocator, undefined, temp, tmpcid);
            try array_array_container_xor(&dstr.array.ptr(.containers)[tmpcid], allocator, dstr, src1, x1, dst, dstr);
            dstr.remove_at_index(tmpcid);
        } else { // guess that it will end up as a bitset
            const result = try bitset_container_from_run(src2, allocator, x2, dstr);
            try bitset_array_container_ixor(&result, allocator, dstr, src1, x1, dst, dstr);
            // any necessary type conversion has been done by the ixor
        }
    }

    fn bitset_container_andnot(
        src1: *const Container,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) u32 {
        return op_methods(.AndNot).bitset_container_op(
            src1.blocks_as(.bitset, x1.*).ptr,
            src2.blocks_as(.bitset, x2.*).ptr,
            dst,
            dst.blocks_as(.bitset, dstr.*).ptr,
        );
    }

    /// Compute the andnot of src1 and src2 and write the result to dst.
    /// dst does not initially have any container.
    fn bitset_bitset_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        assert(dst.* == uninit);
        dst.* = try bitset_container_create(allocator, dstr);
        const card = bitset_container_andnot(src1, x1, src2, x2, dst, dstr);

        if (card <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst, allocator, dstr);
            dst.deinit_blocks(dstr.*);
            dst.* = answer;
        }
    }

    /// Computes the difference of arrays src1 and src2 and write the result to
    /// array dst. Array dst does not need to be distinct from src1
    fn array_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const card1 = src1.cardinality;
        const card2 = src2.cardinality;
        if (dst.calc_capacity() < card1)
            try dst.array_container_grow(allocator, dstr, card1, false);
        dst.cardinality = @intCast(misc.difference_uint16(
            src1.blocks_as(.array, x1.*)[0..card1],
            src2.blocks_as(.array, x2.*)[0..card2],
            dst.blocks_as(.array, dstr.*),
        ));
    }

    /// dst is a valid array container and may be the same as src1
    fn array_array_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        dst.* = try array_container_create_given_capacity(allocator, src1.cardinality, dstr);
        try array_container_andnot(src1, allocator, x1, src2, x2, dst, dstr);
    }

    /// Compute the andnot of src1 and src2 and write the result to dst, which
    /// starts uninit.
    fn bitset_array_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        assert(dst.* == uninit);
        dst.* = try bitset_container_create(allocator, dstr);
        bitset_container_copy(dst, dstr, src1.*, x1.*);
        dst.cardinality = @truncate(misc.bitset_clear_list(
            dst.blocks_as(.bitset, dstr.*).ptr,
            dst.cardinality,
            src2.blocks_as(.array, x2.*)[0..src2.cardinality],
        ));
        if (dst.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst, allocator, dstr);
            dst.deinit_blocks(dstr.*);
            dst.* = answer;
        }
    }

    /// Compute the andnot of src1 and src2 and write the result to
    /// dst, a valid array container that could be the same as dst.
    fn array_bitset_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        assert(dst.* == uninit);
        const card1 = src1.cardinality;
        dst.* = try array_container_create_given_capacity(allocator, card1, dstr);
        const src1array = src1.blocks_as(.array, x1.*);
        const dstarray = dst.blocks_as(.array, dstr.*);
        const src2bitset = src2.blocks_as(.bitset, x2.*);
        var newcard: Cardinality = 0;
        for (src1array[0..card1]) |key| {
            dstarray[newcard] = key;
            newcard += 1 - @intFromBool(bitset_container_get(src2bitset.ptr, key));
        }
        dst.cardinality = newcard;
    }

    /// Compute the andnot of src1 and src2 and write the result to dst. Result
    /// may be either a bitset or an array container. dst starts uninit.
    fn bitset_run_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        assert(dst.* == uninit);
        dst.* = try bitset_container_create(allocator, dstr);
        bitset_container_copy(dst, dstr, src1.*, x1.*);
        const src2runs = src2.blocks_as(.run, x2.*);
        const dstwords = dst.blocks_as(.bitset, dstr.*);
        for (src2runs[0..src2.cardinality]) |rle| {
            bitset_reset_range(dstwords.ptr, rle.value, @as(u32, rle.value) + rle.length + 1);
        }
        dst.cardinality = dst.compute_cardinality(dstr.*);
        if (dst.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst, allocator, dstr);
            dst.deinit_blocks(dstr.*);
            dst.* = answer;
        }
    }

    fn run_bitset_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        // follows the Java implementation as of June 2016
        assert(dst.* == uninit);
        const srccard = run_container_cardinality(src1.*, src1.blocks_as(.run, x1.*).ptr);
        if (srccard <= C.DEFAULT_MAX_SIZE) { // must be an array
            dst.* = try array_container_create_given_capacity(allocator, srccard, dstr);
            dst.cardinality = 0;
            const src1runs = src1.blocks_as(.run, x1.*);
            const dstarray = dst.blocks_as(.array, dstr.*);
            for (src1runs[0..src1.cardinality]) |rle| {
                const run_start: u32 = rle.value;
                const run_end = run_start + rle.length;
                var run_value: u32 = run_start;
                while (run_value <= run_end) : (run_value += 1) {
                    if (!bitset_container_contains(src2.*, @truncate(run_value), x2.*)) {
                        dstarray[dst.cardinality] = @truncate(run_value);
                        dst.cardinality += 1;
                    }
                }
            }
        } else { // we guess it will be a bitset, have to check guess when done
            var answer = try bitset_container_clone(src2, allocator, x2, dstr);

            const src1runs = src1.blocks_as(.run, x1.*);
            const answords = answer.blocks_as(.bitset, dstr.*);
            var last_pos: u32 = 0;
            for (src1runs[0..src1.cardinality]) |rle| {
                const start: u32 = rle.value;
                const end = start + rle.length + 1;
                bitset_reset_range(answords.ptr, last_pos, start);
                misc.bitset_flip_range(answords.ptr, start, end);
                last_pos = end;
            }
            bitset_reset_range(answords.ptr, last_pos, C.MAX_KEY_CARDINALITY);
            answer.cardinality = bitset_container_compute_cardinality(answords.ptr);

            if (answer.cardinality <= C.DEFAULT_MAX_SIZE) {
                dst.* = try array_container_from_bitset(&answer, allocator, dstr);
                answer.deinit_blocks(dstr.*);
                return;
            }
            dst.* = answer;
        }
    }

    /// dst must be a valid array container, allowed to be src1
    fn array_run_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        // basically following Java impl as of June 2016
        const card1 = src1.cardinality;
        assert(dst.* == uninit);
        dst.* = try array_container_create_given_capacity(allocator, card1, dstr);
        const src1array = src1.blocks_as(.array, x1.*);
        const src2runs = src2.blocks_as(.run, x2.*);
        const dstarray = dst.blocks_as(.array, dstr.*);

        if (src2.cardinality == 0) {
            @memcpy(dstarray[0..card1], src1array);
            dst.cardinality = card1;
            return;
        }

        var run_start: u32 = src2runs[0].value;
        var run_end: u32 = run_start + src2runs[0].length;
        var which_run: u32 = 0;
        var dest_card: Cardinality = 0;
        var valp: [*]const u16 = src1array.ptr;
        const end = @intFromPtr(src1array.ptr + card1);
        while (@intFromPtr(valp) < end) : (valp += 1) {
            const val = valp[0];
            if (val < run_start) {
                dstarray[dest_card] = val;
                dest_card += 1;
            } else if (val <= run_end) {
                // omitted
            } else {
                while (true) {
                    which_run += 1;
                    if (which_run < src2.cardinality) {
                        run_start = src2runs[which_run].value;
                        run_end = run_start + src2runs[which_run].length;
                    } else {
                        run_start = C.MAX_KEY_CARDINALITY + 1;
                        run_end = C.MAX_KEY_CARDINALITY + 1;
                    }
                    if (val <= run_end) break;
                }
                valp -= 1;
            }
        }
        dst.cardinality = dest_card;
    }

    /// dst must be a valid array container with adequate capacity.
    fn run_array_array_subtract(
        src1: *const Container,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) Cardinality {
        const src1runs = src1.blocks_as(.run, x1.*);
        const src2array = src2.blocks_as(.array, x2.*);
        const dstarray = dst.blocks_as(.array, dstr.*);
        var out_card: Cardinality = 0;
        var in_array_pos: u32 = std.math.maxInt(u32); // -1, use wrapping math
        for (src1runs[0..src1.cardinality]) |rle| {
            const start: u32 = rle.value;
            const end = start + rle.length + 1;
            const min = rle.value;
            in_array_pos = misc.advanceUntil(src2array[0..src2.cardinality], in_array_pos, min);
            if (in_array_pos >= src2.cardinality) {
                var i = start;
                while (i < end) : (i += 1) {
                    dstarray[out_card] = @intCast(i);
                    out_card += 1;
                }
            } else {
                var next_nonincluded = src2array[in_array_pos];
                if (next_nonincluded >= end) {
                    var i = start;
                    while (i < end) : (i += 1) {
                        dstarray[out_card] = @intCast(i);
                        out_card += 1;
                    }
                    in_array_pos -%= 1;
                } else {
                    var i = start;
                    while (i < end) : (i += 1) {
                        if (i != next_nonincluded) {
                            dstarray[out_card] = @intCast(i);
                            out_card += 1;
                        } else {
                            next_nonincluded = if (in_array_pos + 1 >= src2.cardinality)
                                0
                            else blk: {
                                in_array_pos += 1;
                                break :blk src2array[in_array_pos];
                            };
                        }
                    }
                    in_array_pos -%= 1;
                }
            }
        }
        return out_card;
    }

    /// Compute the andnot of src1 and src2 and write the result to
    /// dst (which has no container initially).  It will modify src1
    /// to be dst if the result is a bitset.  Otherwise, it will
    /// free src1 and dst will be a new array container.  In both
    /// cases, the caller is responsible for deallocating dst.
    fn bitset_array_container_iandnot(
        src1: *Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        src1.cardinality = @truncate(misc.bitset_clear_list(
            src1.blocks_as(.bitset, x1.*).ptr,
            src1.cardinality,
            src2.blocks_as(.array, x2.*)[0..src2.cardinality],
        ));
        if (src1.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(src1, allocator, dstr);
            src1.deinit_blocks(x1.*);
            dst.* = answer;
        } else {
            dst.* = src1.*;
        }
    }

    /// dst does not indicate a valid container initially.  Eventually it
    /// can become any type of container.
    fn run_array_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        assert(dst.* == uninit);
        const card = run_container_cardinality(src1.*, src1.blocks_as(.run, x1.*).ptr);
        const arbitrary_threshold = 32;

        if (card <= arbitrary_threshold) {
            if (src2.cardinality == 0) {
                dst.* = try run_container_clone(src1, allocator, x1, dstr);
                return;
            }
            var ans = try run_container_create_given_capacity(allocator, card + src2.cardinality, dstr);
            ans.cardinality = 0;

            const src1runs = src1.blocks_as(.run, x1.*);
            const src2array = src2.blocks_as(.array, x2.*);
            const ansruns = ans.blocks_as(.run, dstr.*);

            var rlepos: u32 = 0;
            var xrlepos: u32 = 0;
            const rle = src1runs[rlepos];
            var start: u32 = rle.value;
            var end: u32 = start + rle.length + 1;
            var xstart: u32 = src2array[xrlepos];
            while (rlepos < src1.cardinality and xrlepos < src2.cardinality) {
                if (end <= xstart) { // output the first run
                    ansruns[ans.cardinality] = .{
                        .value = @intCast(start),
                        .length = @intCast(end - start - 1),
                    };
                    ans.cardinality += 1;
                    rlepos += 1;
                    if (rlepos < src1.cardinality) {
                        start = src1runs[rlepos].value;
                        end = start + src1runs[rlepos].length + 1;
                    }
                } else if (xstart + 1 <= start) { // exit the second run
                    xrlepos += 1;
                    if (xrlepos < src2.cardinality)
                        xstart = src2array[xrlepos];
                } else {
                    if (start < xstart) {
                        ansruns[ans.cardinality] = .{
                            .value = @intCast(start),
                            .length = @intCast(xstart - start - 1),
                        };
                        ans.cardinality += 1;
                    }
                    if (xstart + 1 < end)
                        start = xstart + 1
                    else {
                        rlepos += 1;
                        if (rlepos < src1.cardinality) {
                            start = src1runs[rlepos].value;
                            end = start + src1runs[rlepos].length + 1;
                        }
                    }
                }
            }
            if (rlepos < src1.cardinality) {
                ansruns[ans.cardinality] = .{
                    .value = @truncate(start),
                    .length = @truncate(end - start - 1),
                };
                ans.cardinality += 1;
                rlepos += 1;
                if (rlepos < src1.cardinality) {
                    const remaining = src1runs[rlepos..src1.cardinality];
                    @memcpy(ansruns[ans.cardinality..].ptr, remaining);
                    ans.cardinality += @intCast(remaining.len);
                }
            }

            dst.* = try convert_run_to_efficient_container_and_free(ans, allocator, dstr);
            if (ans != dst.*) ans.deinit_blocks(dstr.*);
            return;
        }

        // else it's a bitmap or array
        if (card <= C.DEFAULT_MAX_SIZE) {
            dst.* = try array_container_create_given_capacity(allocator, card, dstr);
            // nb Java code used a generic iterator-based merge to compute
            // difference
            dst.cardinality = run_array_array_subtract(src1, x1, src2, x2, dst, dstr);
            return;
        }
        var ans = try bitset_container_from_run(src1, allocator, x1, dstr);
        try bitset_array_container_iandnot(&ans, allocator, dstr, src2, x2, dst, dstr);
    }

    /// dst starts uninit and can become any kind of container.
    fn run_run_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        assert(dst.* == uninit);
        try run_container_andnot(src1, allocator, x1, src2, x2, dst, dstr);
        dst.* = try convert_run_to_efficient_container_and_free(dst.*, allocator, dstr);
    }

    /// Run-level andnot operation on run containers.
    fn run_container_andnot(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const nruns1 = src1.cardinality;
        const nruns2 = src2.cardinality;
        const needed_capacity = nruns1 + nruns2;
        if (dst.calc_capacity() < needed_capacity)
            try dst.run_container_grow(allocator, needed_capacity, false, dstr);
        dst.cardinality = 0;

        const src1runs = src1.blocks_as(.run, x1.*);
        const src2runs = src2.blocks_as(.run, x2.*);
        const dstruns = dst.blocks_as(.run, dstr.*);

        var rlepos1: u32 = 0;
        var rlepos2: u32 = 0;
        var start: u32 = src1runs[rlepos1].value;
        var end: u32 = start + src1runs[rlepos1].length + 1;
        var start2: u32 = src2runs[rlepos2].value;
        var end2: u32 = start2 + src2runs[rlepos2].length + 1;

        while (rlepos1 < nruns1 and rlepos2 < nruns2) {
            if (end <= start2) {
                dstruns[dst.cardinality] = .{
                    .value = @intCast(start),
                    .length = @intCast(end - start - 1),
                };
                dst.cardinality += 1;
                rlepos1 += 1;
                if (rlepos1 < nruns1) {
                    start = src1runs[rlepos1].value;
                    end = start + src1runs[rlepos1].length + 1;
                }
            } else if (end2 <= start) {
                rlepos2 += 1;
                if (rlepos2 < nruns2) {
                    start2 = src2runs[rlepos2].value;
                    end2 = start2 + src2runs[rlepos2].length + 1;
                }
            } else {
                if (start < start2) {
                    dstruns[dst.cardinality] = .{
                        .value = @intCast(start),
                        .length = @intCast(start2 - start - 1),
                    };
                    dst.cardinality += 1;
                }
                if (end2 < end) {
                    start = end2;
                } else {
                    rlepos1 += 1;
                    if (rlepos1 < nruns1) {
                        start = src1runs[rlepos1].value;
                        end = start + src1runs[rlepos1].length + 1;
                    }
                }
            }
        }

        if (rlepos1 < nruns1) {
            dstruns[dst.cardinality] = .{
                .value = @intCast(start),
                .length = @intCast(end - start - 1),
            };
            dst.cardinality += 1;
            rlepos1 += 1;
            if (rlepos1 < nruns1) {
                const remaining = src1runs[rlepos1..nruns1];
                @memcpy(dstruns[dst.cardinality..][0..remaining.len], remaining);
                dst.cardinality += @intCast(remaining.len);
            }
        }
    }

    pub fn xor(
        c1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        c2: *const Container,
        x2: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        var result: Container = .uninit;
        switch (misc.pair(c1.typecode, c2.typecode)) {
            misc.pair(.bitset, .bitset) => {
                try bitset_bitset_container_xor(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.array, .array) => {
                try array_array_container_xor(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.run, .run) => {
                try run_run_container_xor(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.bitset, .array) => {
                try array_bitset_container_xor(c2, allocator, x2, c1, x1, &result, dstr);
            },
            misc.pair(.array, .bitset) => {
                try array_bitset_container_xor(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.bitset, .run) => {
                try run_bitset_container_xor(c2, allocator, x2, c1, x1, &result, dstr);
            },
            misc.pair(.run, .bitset) => {
                try run_bitset_container_xor(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.array, .run) => {
                try array_run_container_xor(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.run, .array) => {
                try array_run_container_xor(c2, allocator, x2, c1, x1, &result, dstr);
            },
            else => unreachable,
        }
        return result;
    }

    /// Compute andnot (difference) between two containers, return a new
    /// container. This allocates new memory, caller is responsible for
    /// deallocation.
    pub fn andnot(
        c1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        c2: *const Container,
        x2: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        var result: Container = .uninit;
        switch (misc.pair(c1.typecode, c2.typecode)) {
            misc.pair(.bitset, .bitset) => {
                try bitset_bitset_container_andnot(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.array, .array) => {
                try array_array_container_andnot(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.run, .run) => {
                if (run_container_is_full(c2.*, x2.*)) return result;
                try run_run_container_andnot(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.bitset, .array) => {
                try bitset_array_container_andnot(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.array, .bitset) => {
                try array_bitset_container_andnot(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.bitset, .run) => {
                if (run_container_is_full(c2.*, x2.*)) return result;
                try bitset_run_container_andnot(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.run, .bitset) => {
                try run_bitset_container_andnot(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.array, .run) => {
                if (run_container_is_full(c2.*, x2.*)) return result;
                try array_run_container_andnot(c1, allocator, x1, c2, x2, &result, dstr);
            },
            misc.pair(.run, .array) => {
                try run_array_container_andnot(c1, allocator, x1, c2, x2, &result, dstr);
            },
            else => unreachable,
        }
        return result;
    }

    /// Create an copy of a c and it's blocks allocated in dstr.
    pub fn get_copy_of_container(
        c: Container,
        allocator: Allocator,
        x: *const Bitmap,
        dstr: *Bitmap,
        copy_on_write: bool,
    ) !Container {
        if (copy_on_write) {
            unreachable; // TODO
        }
        // TODO c = container_unwrap_shared(c);
        return clone(c, allocator, x, dstr);
    }

    fn array_container_clone(
        c: Container,
        allocator: Allocator,
        x: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        var newc = try array_container_create_given_capacity(allocator, c.cardinality, dstr);
        newc.cardinality = c.cardinality;
        @memcpy(
            newc.blocks_as(.array, dstr.*)[0..c.cardinality],
            c.blocks_as(.array, x.*)[0..c.cardinality],
        );
        return newc;
    }

    fn run_container_clone(
        c: *const Container,
        allocator: Allocator,
        x: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        var newc = try run_container_create_given_capacity(allocator, c.cardinality, dstr);
        newc.cardinality = c.cardinality;
        @memcpy(
            newc.blocks_as(.run, dstr.*)[0..c.cardinality],
            c.blocks_as(.run, x.*)[0..c.cardinality],
        );
        return newc;
    }

    fn bitset_container_clone(
        c: *const Container,
        allocator: Allocator,
        x: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        try dstr.ensure_unused_capacity(allocator, 0, C.BITSET_BLOCKS);
        var bc = Container{
            .typecode = .bitset,
            .cardinality = c.cardinality,
            .blockoffset = @intCast(dstr.array.ptr(.blockslen).*),
            .nblocks_minus1 = @intCast(C.BITSET_BLOCKS - 1),
        };
        dstr.array.ptr(.blockslen).* += C.BITSET_BLOCKS;
        @memcpy(bc.get_blocks(dstr.*), c.get_blocks(x.*));
        return bc;
    }

    pub fn clone(c: Container, allocator: Allocator, x: *const Bitmap, dstr: *Bitmap) !Container {
        return switch (c.typecode) {
            .array => c.array_container_clone(allocator, x, dstr),
            .run => c.run_container_clone(allocator, x, dstr),
            .bitset => c.bitset_container_clone(allocator, x, dstr),
            .shared => unreachable,
        };
    }

    /// returns true if a container is known to be full. Note that a lazy bitset
    /// container might be full without us knowing.
    ///
    /// Note: array cardinality 65536 doesn't seem correct but is needed for
    /// croaring compatibility
    pub fn is_full(c: Container, r: Bitmap) bool {
        return switch (c.typecode) {
            .bitset, .array => c.cardinality == C.MAX_KEY_CARDINALITY,
            .run => run_container_is_full(c, r),
            else => unreachable,
        };
    }

    /// Check whether the container spans the whole chunk (cardinality = 1<<16).
    /// This check can be done in constant time (inexpensive).
    fn run_container_is_full(run: Container, r: Bitmap) bool {
        const vl = run.blocks_as(.run, r)[0];
        return (run.cardinality == 1) and (vl.value == 0) and (vl.length == 0xFFFF);
    }

    fn bitset_extract_intersection_setbits_uint16(
        words1: []align(C.BLOCK_ALIGN) const u64,
        words2: []align(C.BLOCK_ALIGN) const u64,
        out: []align(C.BLOCK_ALIGN) u16,
        base: u16,
    ) usize {
        var outpos: u32 = 0;
        var base1: u32 = base;
        for (words1, words2) |w1, w2| {
            var w = w1 & w2;
            while (w != 0) {
                const r = @ctz(w);
                out[outpos] = @truncate(r + base1);
                outpos += 1;
                w &= (w - 1);
            }
            base1 += 64;
        }
        return outpos;
    }

    /// Returns the smallest value (assumes not empty)
    pub fn bitset_container_minimum(words: [*]align(C.BLOCK_ALIGN) const u64) u16 {
        for (words[0..C.BITSET_CONTAINER_SIZE_IN_WORDS]) |*w| {
            if (w.* != 0) {
                const r = @ctz(w.*);
                return r + @as(u16, @intCast(w - words)) * 64;
            }
        }
        return std.math.maxInt(u16);
    }

    /// Returns the smallest value (assumes not empty)
    pub fn bitset_container_maximum(words: [*]align(C.BLOCK_ALIGN) const u64) u16 {
        var i: u16 = C.BITSET_CONTAINER_SIZE_IN_WORDS;
        while (true) {
            i -= 1;
            const w = words[i];
            if (w != 0) {
                const r = @clz(w);
                return i * 64 + 63 - r;
            }
        }
        return 0;
    }

    /// Returns the smallest value (assumes not empty)
    pub fn array_container_minimum(arr: Container, array: [*]align(C.BLOCK_ALIGN) const u16) u16 {
        if (arr.cardinality == 0) return 0;
        return array[0];
    }

    /// Returns the largest value (assumes not empty)
    pub fn array_container_maximum(arr: Container, array: [*]align(C.BLOCK_ALIGN) const u16) u16 {
        if (arr.cardinality == 0) return 0;
        return array[arr.cardinality - 1];
    }

    /// Returns the smallest value (assumes not empty)
    pub fn run_container_minimum(run: Container, runs: [*]align(C.BLOCK_ALIGN) const Rle16) u16 {
        if (run.cardinality == 0) return 0;
        return runs[0].value;
    }

    /// Returns the largest value (assumes not empty)
    pub fn run_container_maximum(run: Container, runs: [*]align(C.BLOCK_ALIGN) const Rle16) u16 {
        if (run.cardinality == 0) return 0;
        return runs[run.cardinality - 1].value + runs[run.cardinality - 1].length;
    }

    pub fn minimum(c: Container, r: Bitmap) u16 {
        // TODO // c = container_unwrap_shared(c);
        return switch (c.typecode) {
            .bitset => bitset_container_minimum(c.blocks_as(.bitset, r).ptr),
            .array => return c.array_container_minimum(c.blocks_as(.array, r).ptr),
            .run => return c.run_container_minimum(c.blocks_as(.run, r).ptr),
            else => unreachable,
        };
    }

    pub fn maximum(c: Container, r: Bitmap) u16 {
        // TODO // c = container_unwrap_shared(c);
        return switch (c.typecode) {
            .bitset => bitset_container_maximum(c.blocks_as(.bitset, r).ptr),
            .array => return c.array_container_maximum(c.blocks_as(.array, r).ptr),
            .run => return c.run_container_maximum(c.blocks_as(.run, r).ptr),
            else => unreachable,
        };
    }

    /// Returns the number of integers that are smaller or equal to x.
    fn array_container_rank(c: Container, x: u16, r: Bitmap) u32 {
        const array = c.blocks_as(.array, r)[0..c.cardinality];
        const idx = misc.binarySearch(array, x);
        return @bitCast(if (idx >= 0) idx + 1 else -idx - 1);
    }

    /// Returns the number of values equal or smaller than x
    fn bitset_container_rank(c: Container, x: u16, r: Bitmap) u32 {
        // credit: aqrit
        const words = c.blocks_as(.bitset, r);
        var sum: u32 = 0;
        var i: u32 = 0;
        const end = x / 64;
        while (i < end) : (i += 1) {
            sum += @popCount(words[i]);
        }
        const lastword = words[i];
        const lastpos = @as(u64, 1) << @truncate(x % 64);
        const mask = lastpos +% lastpos -% 1; // smear right
        sum += @popCount(lastword & mask);
        return sum;
    }

    fn run_container_rank(c: Container, x: u16, r: Bitmap) u32 {
        const runs = c.blocks_as(.run, r)[0..c.cardinality];
        var sum: u32 = 0;
        const x32: u32 = x;
        for (runs) |run| {
            const startpoint: u32 = run.value;
            const length = run.length;
            const endpoint = startpoint + length;
            if (x <= endpoint) {
                if (x < startpoint) break;
                return sum + (x32 - startpoint) + 1;
            } else {
                sum += length + 1;
            }
        }
        return sum;
    }

    pub fn rank(c: Container, x: u16, r: Bitmap) u32 {
        return switch (c.typecode) {
            .bitset => c.bitset_container_rank(x, r),
            .array => c.array_container_rank(x, r),
            .run => c.run_container_rank(x, r),
            .shared => unreachable,
        };
    }

    /// If the element of given rank is in this container, supposing that the
    /// first element has rank start_rank, then return element. Otherwise, it
    /// returns null and updates start_rank.
    fn array_container_select(
        c: Container,
        start_rank: *u32,
        target_rank: u32,
        r: Bitmap,
    ) ?u32 {
        const card = c.cardinality;
        if (start_rank.* + card <= target_rank) {
            start_rank.* += card;
            return null;
        } else {
            const array = c.blocks_as(.array, r);
            return array[target_rank - start_rank.*];
        }
    }

    /// If the element of given rank is in this container, supposing that the first
    /// element has rank start_rank, then the function returns element accordingly.
    /// Otherwise, it returns null and updates start_rank.
    fn bitset_container_select(c: Container, start_rank: *u32, target_rank: u32, r: Bitmap) ?u32 {
        const card = c.cardinality;
        if (target_rank >= start_rank.* + card) {
            start_rank.* += card;
            return null;
        }
        const words = c.blocks_as(.bitset, r);
        for (0..C.BITSET_CONTAINER_SIZE_IN_WORDS) |i| {
            const size = @popCount(words[i]);
            if (target_rank <= start_rank.* + size) {
                var w = words[i];
                const base: u16 = @truncate(i * 64);
                while (w != 0) {
                    const rpos = @ctz(w);
                    if (start_rank.* == target_rank) {
                        return rpos + base;
                    }
                    w &= (w - 1);
                    start_rank.* += 1;
                }
            } else {
                start_rank.* += size;
            }
        }
        unreachable;
    }

    fn run_container_select(
        c: Container,
        start_rank: *u32,
        target_rank: u32,
        r: Bitmap,
    ) ?u32 {
        const runs = c.blocks_as(.run, r)[0..c.cardinality];
        for (runs) |run| {
            const length: u32 = run.length;
            if (target_rank <= start_rank.* + length) {
                return @as(u32, run.value) + target_rank - start_rank.*;
            } else {
                start_rank.* += length + 1;
            }
        }
        return null;
    }

    pub fn select(c: Container, start_rank: *u32, target_rank: u32, r: Bitmap) ?u32 {
        return switch (c.typecode) {
            .bitset => c.bitset_container_select(start_rank, target_rank, r),
            .array => c.array_container_select(start_rank, target_rank, r),
            .run => c.run_container_select(start_rank, target_rank, r),
            .shared => unreachable,
        };
    }

    fn array_container_is_subset(c1: Container, r1: Bitmap, c2: Container, r2: Bitmap) bool {
        if (c1.cardinality > c2.cardinality) return false;
        const array1 = c1.blocks_as(.array, r1)[0..c1.cardinality];
        const array2 = c2.blocks_as(.array, r2)[0..c2.cardinality];
        var idx1: u32 = 0;
        var idx2: u32 = 0;
        while (idx1 < array1.len and idx2 < array2.len) {
            if (array1[idx1] == array2[idx2]) {
                idx1 += 1;
                idx2 += 1;
            } else if (array1[idx1] > array2[idx2]) {
                idx2 += 1;
            } else {
                return false;
            }
        }
        return idx1 == array1.len;
    }

    fn bitset_container_is_subset(c1: Container, r1: Bitmap, c2: Container, r2: Bitmap) bool {
        if (c1.cardinality != C.BITSET_UNKNOWN_CARDINALITY and
            c2.cardinality != C.BITSET_UNKNOWN_CARDINALITY and
            c1.cardinality > c2.cardinality) return false;
        const words1 = c1.blocks_as(.bitset, r1);
        const words2 = c2.blocks_as(.bitset, r2);
        for (
            words1[0..C.BITSET_CONTAINER_SIZE_IN_WORDS],
            words2[0..C.BITSET_CONTAINER_SIZE_IN_WORDS],
        ) |w1, w2| {
            if ((w1 & w2) != w1) return false;
        }
        return true;
    }

    fn run_container_is_subset(c1: Container, r1: Bitmap, c2: Container, r2: Bitmap) bool {
        const runs1 = c1.blocks_as(.run, r1)[0..c1.cardinality];
        const runs2 = c2.blocks_as(.run, r2)[0..c2.cardinality];
        var idx1: u32 = 0;
        var idx2: u32 = 0;
        while (idx1 < runs1.len and idx2 < runs2.len) {
            const start1: u32 = runs1[idx1].value;
            const stop1: u32 = start1 + runs1[idx1].length;
            const start2: u32 = runs2[idx2].value;
            const stop2: u32 = start2 + runs2[idx2].length;
            if (start1 < start2) {
                return false;
            } else if (stop1 < stop2) {
                idx1 += 1;
            } else if (stop1 == stop2) {
                idx1 += 1;
                idx2 += 1;
            } else {
                idx2 += 1;
            }
        }
        return idx1 == runs1.len;
    }

    fn array_container_is_subset_bitset(c1: Container, r1: Bitmap, c2: Container, r2: Bitmap) bool {
        if (c2.cardinality < c1.cardinality)
            return false;
        const array1 = c1.blocks_as(.array, r1)[0..c1.cardinality];
        const words2 = c2.blocks_as(.bitset, r2);
        for (array1) |val| {
            if (!bitset_container_get(words2.ptr, val)) return false;
        }
        return true;
    }

    fn array_container_is_subset_run(c1: Container, r1: Bitmap, c2: Container, r2: Bitmap) bool {
        const runs2 = c2.blocks_as(.run, r2)[0..c2.cardinality];
        if (c1.cardinality > c2.run_container_cardinality(runs2.ptr))
            return false;
        const array1 = c1.blocks_as(.array, r1)[0..c1.cardinality];
        var iarray: u32 = 0;
        var irun: u32 = 0;
        while (iarray < array1.len and irun < runs2.len) {
            const start: u32 = runs2[irun].value;
            const stop: u32 = start + runs2[irun].length;
            if (array1[iarray] < start) {
                return false;
            } else if (array1[iarray] > stop) {
                irun += 1;
            } else {
                iarray += 1;
            }
        }
        return iarray == array1.len;
    }

    fn run_container_is_subset_array(c1: Container, r1: Bitmap, c2: Container, r2: Bitmap) bool {
        const runs1 = c1.blocks_as(.run, r1);
        if (c1.run_container_cardinality(runs1.ptr) > c2.cardinality)
            return false;
        const array2 = c2.blocks_as(.array, r2)[0..c2.cardinality];
        var start_pos: u32 = std.math.maxInt(u32);
        var stop_pos: u32 = std.math.maxInt(u32);
        for (runs1[0..c1.cardinality]) |run| {
            const start: u32 = run.value;
            const stop: u32 = start + run.length;
            start_pos = misc.advanceUntil(array2, start_pos, @intCast(start));
            stop_pos = misc.advanceUntil(array2, stop_pos, @intCast(stop));
            if (stop_pos == c2.cardinality)
                return false;
            if (stop_pos - start_pos != stop - start or
                array2[start_pos] != start or
                array2[stop_pos] != stop)
                return false;
        }
        return true;
    }

    fn run_container_is_subset_bitset(c1: Container, r1: Bitmap, c2: Container, r2: Bitmap) bool {
        // todo: this code could be much faster
        const runs1 = c1.blocks_as(.run, r1);
        const words2 = c2.blocks_as(.bitset, r2);
        if (c2.cardinality != C.BITSET_UNKNOWN_CARDINALITY) {
            if (c2.cardinality < c1.run_container_cardinality(runs1.ptr))
                return false;
        } else {
            const card = bitset_container_compute_cardinality(words2.ptr); // modify container2?
            if (card < c1.run_container_cardinality(runs1.ptr)) {
                return false;
            }
        }
        for (runs1[0..c1.cardinality]) |run| {
            const start: u32 = run.value;
            const end = start + run.length;
            var j = start;
            while (j <= end) : (j += 1) {
                if (!bitset_container_get(words2.ptr, @intCast(j)))
                    return false;
            }
        }
        return true;
    }

    fn bitset_container_is_subset_run(c1: Container, r1: Bitmap, c2: Container, r2: Bitmap) bool {
        // todo: this code could be much faster
        const words1 = c1.blocks_as(.bitset, r1);
        const runs2 = c2.blocks_as(.run, r2)[0..c2.cardinality];
        if (c1.cardinality != C.BITSET_UNKNOWN_CARDINALITY) {
            if (c1.cardinality > c2.run_container_cardinality(runs2.ptr))
                return false;
        }
        var ibitset: u32 = 0;
        var irun: u32 = 0;
        while (ibitset < C.BITSET_CONTAINER_SIZE_IN_WORDS and irun < runs2.len) {
            var w = words1[ibitset];
            while (w != 0 and irun < runs2.len) {
                const start: u32 = runs2[irun].value;
                const stop: u32 = start + runs2[irun].length;
                const t = w & (~w + 1);
                const rpos = ibitset * 64 + @ctz(w);
                if (rpos < start) {
                    return false;
                } else if (rpos > stop) {
                    irun += 1;
                } else {
                    w ^= t;
                }
            }
            if (w == 0) {
                ibitset += 1;
            } else {
                return false;
            }
        }
        while (ibitset < C.BITSET_CONTAINER_SIZE_IN_WORDS) : (ibitset += 1) {
            if (words1[ibitset] != 0)
                return false;
        }
        return true;
    }

    pub fn is_subset(c1: Container, r1: Bitmap, c2: Container, r2: Bitmap) bool {
        return switch (misc.pair(c1.typecode, c2.typecode)) {
            misc.pair(.array, .array) => array_container_is_subset(c1, r1, c2, r2),
            misc.pair(.array, .bitset) => array_container_is_subset_bitset(c1, r1, c2, r2),
            misc.pair(.array, .run) => array_container_is_subset_run(c1, r1, c2, r2),
            misc.pair(.array, .shared) => unreachable,
            misc.pair(.bitset, .array) => false,
            misc.pair(.bitset, .bitset) => bitset_container_is_subset(c1, r1, c2, r2),
            misc.pair(.bitset, .run) => bitset_container_is_subset_run(c1, r1, c2, r2),
            misc.pair(.bitset, .shared) => unreachable,
            misc.pair(.run, .array) => run_container_is_subset_array(c1, r1, c2, r2),
            misc.pair(.run, .bitset) => run_container_is_subset_bitset(c1, r1, c2, r2),
            misc.pair(.run, .run) => run_container_is_subset(c1, r1, c2, r2),
            misc.pair(.run, .shared) => unreachable,
            else => unreachable,
        };
    }

    /// no matter what the initial container was, convert it to a bitset if a
    /// new container is produced, caller responsible for freeing the previous
    /// one container should not be a shared container
    ///
    /// c is allocated in r. returned container is allocated in dstr.
    pub fn to_bitset(c: *const Container, allocator: Allocator, r: *const Bitmap, dstr: *Bitmap) !Container {
        return switch (c.typecode) {
            .bitset => c.*,
            .array => try c.bitset_container_from_array2(allocator, r, dstr),
            .run => try c.bitset_container_from_run(allocator, r, dstr),
            .shared => unreachable,
        };
    }

    /// Compute the union between two containers, with result in the first container.
    /// If the returned container is identical to c1, then the container has been
    /// modified.
    ///
    /// If the returned container is different from c1, then a new container has been
    /// created and the caller is responsible for freeing it.
    /// The type of the first container may change. Returns the modified
    /// (and possibly new) container
    ///
    /// This lazy version delays some operations such as the maintenance of the
    /// cardinality. It requires repair later on the generated containers.
    pub fn lazy_ior(
        c1: *Container,
        allocator: Allocator,
        x1: *Bitmap,
        c2: *const Container,
        x2: *const Bitmap,
    ) !Container {
        assert(c1.typecode != .shared);
        // c1 = get_writable_copy_if_shared(c1,&type1);
        // TODO // c2 = container_unwrap_shared(c2, &type2);
        var result: Container = .uninit;
        const c1id = c1 - x1.array.ptr(.containers);
        const c2id = c2 - x2.array.ptr(.containers);
        switch (misc.pair(c1.typecode, c2.typecode)) {
            misc.pair(.bitset, .bitset) => {
                if (C.LAZY_OR_BITSET_CONVERSION_TO_FULL) {
                    // if we have two bitsets, we might as well compute the cardinality
                    bitset_container_or(c1, x1, c2, x2, c1, x1);
                    // it is possible that two bitsets can lead to a full container
                    if (c1.cardinality == C.MAX_KEY_CARDINALITY) { // we convert
                        return try run_container_create_range(allocator, 0, C.MAX_KEY_CARDINALITY, x1);
                    }
                } else {
                    const c1words = c1.blocks_as(.bitset, x1.*).ptr;
                    const c2words = c2.blocks_as(.bitset, x2.*).ptr;
                    _ = bitset_container_or_nocard(c1words, c2words, c1, c1words);
                }
                return c1.*;
            },
            misc.pair(.array, .array) => {
                try array_array_container_lazy_inplace_union(c1, allocator, x1, c2, x2, &result, x1);
                const c1b = x1.array.ptr(.containers)[c1id];
                if (result == uninit and c1b.typecode == .array)
                    return c1b; // the computation was done in-place!
                return result;
            },
            misc.pair(.run, .run) => {
                try run_container_union_inplace(c1, allocator, x1, c2, x2);
                return try convert_run_to_efficient_container(x1.array.ptr(.containers)[c1id], allocator, x1);
            },
            misc.pair(.bitset, .array) => {
                array_bitset_container_lazy_union(c2, x2, c1, x1, c1, x1); // is lazy
                return c1.*;
            },
            misc.pair(.array, .bitset) => {
                // c1 is an array, so no in-place possible
                result = try bitset_container_create(allocator, x1);
                const c1b = &x1.array.ptr(.containers)[c1id];
                const c2b = &x2.array.ptr(.containers)[c2id];
                array_bitset_container_lazy_union(c1b, x1, c2b, x2, &result, x1); // is lazy
                return result;
            },
            misc.pair(.bitset, .run) => {
                if (run_container_is_full(c2.*, x2.*)) {
                    result = try run_container_create_given_capacity(allocator, c2.cardinality, x1);
                    const c2b = x2.array.ptr(.containers)[c2id];
                    try run_container_copy(c2b, allocator, &result, c2b.blocks_as(.run, x2.*).ptr, x1);
                    return result;
                }
                run_bitset_container_lazy_union(c2, x2, c1, x1, c1, x1); // allowed //  lazy
                return c1.*;
            },
            misc.pair(.run, .bitset) => {
                if (run_container_is_full(c1.*, x1.*)) {
                    return c1.*;
                }
                result = try bitset_container_create(allocator, x1);
                const c1b = &x1.array.ptr(.containers)[c1id];
                const c2b = &x2.array.ptr(.containers)[c2id];
                run_bitset_container_lazy_union(c1b, x1, c2b, x2, &result, x1); //  lazy
                return result;
            },
            misc.pair(.array, .run) => {
                result = try run_container_create_given_capacity(allocator, c2.cardinality, x1);
                const c1b = &x1.array.ptr(.containers)[c1id];
                const c2b = &x2.array.ptr(.containers)[c2id];
                try array_run_container_union(c1b, allocator, x1, c2b, x2, &result, x1);
                // skip convert_run_to_efficient_container since we are lazy
                return result;
            },
            misc.pair(.run, .array) => {
                try array_run_container_inplace_union(c2, allocator, x2, c1, x1);
                // skip convert_run_to_efficient_container since we are lazy
                return x1.array.ptr(.containers)[c1id];
            },
            else => unreachable,
        }
    }

    fn array_array_container_lazy_inplace_union(
        src1: *Container,
        allocator: Allocator,
        x1: *Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const totalCardinality = src1.cardinality + src2.cardinality;
        assert(dst.* == uninit);
        trace(@src(), "totalCardinality={} src1.calc_capacity()={}", .{ totalCardinality, src1.calc_capacity() });
        if (totalCardinality <= C.ARRAY_LAZY_LOWERBOUND) {
            if (src1.calc_capacity() < totalCardinality) {
                // be purposefully generous
                dst.* = try array_container_create_given_capacity(allocator, 2 * totalCardinality, dstr);
                try array_container_union(src1, allocator, x1, src2, x2, dst, dstr);
                return;
            } else {
                const arr1 = src1.blocks_as(.array, x1.*);
                const arr2 = src2.blocks_as(.array, x2.*)[0..src2.cardinality];
                @memmove(arr1.ptr + src2.cardinality, arr1[0..src1.cardinality]);
                src1.cardinality = @intCast(misc.fast_union_uint16(
                    arr1[src2.cardinality..][0..src1.cardinality],
                    arr2,
                    arr1[0..src1.cardinality],
                ));
                return;
            }
        }
        dst.* = try bitset_container_create(allocator, x1);
        const dstwords = dst.blocks_as(.bitset, x1.*);
        misc.bitset_set_list(dstwords.ptr, src1.blocks_as(.array, x1.*)[0..src1.cardinality]);
        misc.bitset_set_list(dstwords.ptr, src2.blocks_as(.array, x2.*)[0..src2.cardinality]);
        dst.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
    }

    fn array_array_container_lazy_union(
        src1: *const Container,
        allocator: Allocator,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const totalCardinality = src1.cardinality + src2.cardinality;
        //
        // We assume that operations involving bitset containers will be faster than
        // operations involving solely array containers, except maybe when array
        // containers are small. Indeed, for example, it is cheap to compute the
        // union between an array and a bitset container, generally more so than
        // between a large array and another array. So it is advantageous to favour
        // bitset containers during the computation. Of course, if we convert array
        // containers eagerly to bitset containers, we may later need to revert the
        // bitset containers to array containerr to satisfy the Roaring format
        // requirements, but such one-time conversions at the end may not be overly
        // expensive. We arrived to this design based on extensive benchmarking.
        //
        const src1id = src1 - x1.array.ptr(.containers);
        const src2id = src2 - x2.array.ptr(.containers);
        if (totalCardinality <= C.ARRAY_LAZY_LOWERBOUND) {
            dst.* = try array_container_create_given_capacity(allocator, totalCardinality, dstr);
            const src1b = &x1.array.ptr(.containers)[src1id];
            const src2b = &x2.array.ptr(.containers)[src2id];
            try array_container_union(src1b, allocator, x1, src2b, x2, dst, dstr);
            return;
        }

        dst.* = try bitset_container_create(allocator, dstr);
        const dstwords = dst.blocks_as(.bitset, dstr.*);
        misc.bitset_set_list(dstwords.ptr, src1.blocks_as(.array, x1.*)[0..src1.cardinality]);
        misc.bitset_set_list(dstwords.ptr, src2.blocks_as(.array, x2.*)[0..src2.cardinality]);
        dst.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
    }

    /// Compute the union of src1 and src2 and write the result to
    /// dst. It is allowed for src2 to be dst.  This version does not
    /// update the cardinality of dst (it is set to BITSET_UNKNOWN_CARDINALITY).
    fn array_bitset_container_lazy_union(
        src1: *const Container,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) void {
        if (src2 != dst) bitset_container_copy(dst, dstr, src2.*, x2.*);
        const dstwords = dst.blocks_as(.bitset, dstr.*);
        misc.bitset_set_list(dstwords.ptr, src1.blocks_as(.array, x1.*)[0..src1.cardinality]);
        dst.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
    }

    fn run_bitset_container_lazy_union(
        src1: *const Container,
        x1: *const Bitmap,
        src2: *const Container,
        x2: *const Bitmap,
        dst: *Container,
        dstr: *Bitmap,
    ) void {
        if (src2 != dst) bitset_container_copy(dst, dstr, src2.*, x2.*);
        const runs = src1.blocks_as(.run, x1.*)[0..src1.cardinality];
        const dstwords = dst.blocks_as(.bitset, dstr.*);
        for (runs) |rle| {
            misc.bitset_set_lenrange(dstwords.ptr, rle.value, rle.length);
        }
        dst.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
    }

    /// Compute union between two containers, generate a new container. This
    /// allocates new memory, caller is responsible for deallocation.
    ///
    /// This lazy version delays some operations such as the maintenance of the
    /// cardinality. It requires repair later on the generated containers.
    pub fn lazy_or(
        c1: *Container,
        allocator: Allocator,
        x1: *Bitmap,
        c2: *const Container,
        x2: *const Bitmap,
        dstr: *Bitmap,
    ) !Container {
        assert(c1.typecode != .shared);
        // c1 = get_writable_copy_if_shared(c1,&type1);
        // TODO // c2 = container_unwrap_shared(c2, &type2);
        var result: Container = .uninit;
        const c1id = c1 - x1.array.ptr(.containers);
        const c2id = c2 - x2.array.ptr(.containers);
        switch (misc.pair(c1.typecode, c2.typecode)) {
            misc.pair(.bitset, .bitset) => {
                result = try bitset_container_create(allocator, dstr);
                _ = bitset_container_or_nocard(
                    c1.blocks_as(.bitset, x1.*).ptr,
                    c2.blocks_as(.bitset, x2.*).ptr,
                    &result,
                    result.blocks_as(.bitset, dstr.*).ptr,
                );
                return result;
            },
            misc.pair(.array, .array) => {
                try array_array_container_lazy_union(c1, allocator, x1, c2, x2, &result, dstr);
                if (result == uninit and c1.typecode == .array)
                    return x1.array.ptr(.containers)[c1id]; // the computation was done in-place!
                return result;
            },
            misc.pair(.run, .run) => {
                result = try run_container_create_given_capacity(
                    allocator,
                    @max(c1.cardinality, c2.cardinality),
                    dstr,
                );
                try run_container_union(c1, allocator, x1, c2, x2, &result, dstr);
                return try convert_run_to_efficient_container_and_free(result, allocator, dstr);
            },
            misc.pair(.bitset, .array) => {
                result = try bitset_container_create(allocator, dstr);
                array_bitset_container_lazy_union(c2, x2, c1, x1, &result, dstr); // is lazy
                return result;
            },
            misc.pair(.array, .bitset) => {
                // c1 is an array, so no in-place possible
                result = try bitset_container_create(allocator, dstr);
                array_bitset_container_lazy_union(c1, x1, c2, x2, &result, dstr); // is lazy
                return result;
            },
            misc.pair(.bitset, .run) => {
                if (run_container_is_full(c2.*, x2.*)) {
                    result = try run_container_create_given_capacity(allocator, c2.cardinality, dstr);
                    const c2b = x2.array.ptr(.containers)[c2id];
                    const c2runs = c2b.blocks_as(.run, x2.*).ptr;
                    try run_container_copy(c2b, allocator, &result, c2runs, dstr);
                    return result;
                }
                result = try bitset_container_create(allocator, dstr);
                const c1b = &x1.array.ptr(.containers)[c1id];
                const c2b = &x2.array.ptr(.containers)[c2id];
                run_bitset_container_lazy_union(c2b, x2, c1b, x1, &result, dstr); // is lazy
                return result;
            },
            misc.pair(.run, .bitset) => {
                if (run_container_is_full(c1.*, x1.*)) {
                    result = try run_container_create_given_capacity(allocator, c1.cardinality, dstr);
                    const c1b = x1.array.ptr(.containers)[c1id];
                    const c1runs = c1b.blocks_as(.run, x1.*).ptr;
                    try run_container_copy(c1b, allocator, &result, c1runs, dstr);
                    return result;
                }
                result = try bitset_container_create(allocator, dstr);
                run_bitset_container_lazy_union(c1, x1, c2, x2, &result, dstr); //  lazy
                return result;
            },
            misc.pair(.array, .run) => {
                result = try run_container_create_given_capacity(allocator, 2 * (c1.cardinality + c2.cardinality), dstr);
                try array_run_container_union(c1, allocator, x1, c2, x2, &result, dstr);
                // skip convert_run_to_efficient_container since we are lazy
                return result;
            },
            misc.pair(.run, .array) => {
                result = try run_container_create_given_capacity(allocator, 2 * (c1.cardinality + c2.cardinality), dstr);
                try array_run_container_union(c2, allocator, x2, c1, x1, &result, dstr);
                // skip convert_run_to_efficient_container since we are lazy
                return result;
            },
            else => unreachable,
        }
    }

    /// "repair" the container after lazy operations.
    pub fn repair_after_lazy(c: *Container, allocator: Allocator, r: *Bitmap) !Container {
        return switch (c.typecode) {
            .bitset => bc: {
                c.cardinality = bitset_container_compute_cardinality(c.blocks_as(.bitset, r.*).ptr);
                if (c.cardinality <= C.DEFAULT_MAX_SIZE) {
                    const cid = c - r.array.ptr(.containers);
                    const bc = try c.array_container_from_bitset(allocator, r);
                    r.array.ptr(.containers)[cid].deinit_blocks(r.*);
                    break :bc bc;
                }
                break :bc c.*;
            },
            .array => c.*,
            .run => try c.convert_run_to_efficient_container_and_free(allocator, r),
            else => unreachable,
        };
    }

    fn shared_container_extract_copy(sc: Container, allocator: Allocator, r: Bitmap) !Container {
        _ = sc;
        _ = r;
        _ = allocator;
        unreachable;
    }

    pub fn get_writable_copy_if_shared(c1: Container, allocator: Allocator, x1: Bitmap) !Container {
        return if (c1.typecode == .shared)
            try c1.shared_container_extract_copy(allocator, x1)
        else
            c1;
    }

    /// Check whether a range of bits from position `pos_start' (included) to
    /// `pos_end' (excluded) is present in the bitset container.
    fn bitset_container_get_range(c: Container, pos_start: u32, pos_end: u32, r: Bitmap) bool {
        const start = pos_start >> 6;
        const end = pos_end >> 6;

        const first = ~((@as(u64, 1) << @truncate(pos_start)) - 1);
        const last = (@as(u64, 1) << @truncate(pos_end)) - 1;

        const words = c.blocks_as(.bitset, r);
        if (start == end)
            return (words[end] & first & last == first & last);
        if (words[start] & first != first)
            return false;

        if (end < C.BITSET_CONTAINER_SIZE_IN_WORDS and
            words[end] & last != last)
            return false;

        var i = start + 1;
        while (i < C.BITSET_CONTAINER_SIZE_IN_WORDS and i < end) : (i += 1) {
            if (words[i] != ~@as(u64, 0))
                return false;
        }

        return true;
    }

    /// Check whether a range of values from [range_start, range_end) is present.
    fn array_container_contains_range(c: Container, range_start: u32, range_end: u32, r: Bitmap) bool {
        const range_count = range_end - range_start;
        const rs_included: u16 = @truncate(range_start);
        const re_included: u16 = @truncate(range_end - 1);
        if (range_count == 0) // Empty range is always included
            return true;
        if (range_count > c.cardinality)
            return false;

        const array = c.blocks_as(.array, r)[0..c.cardinality];
        const start = misc.binarySearch(array, rs_included);
        const startu: u32 = @bitCast(start);
        // If this sorted array contains all items in the range:
        // * the start item must be found
        // * the last item in range range_count must exist, and be the expected end value
        return start >= 0 and
            c.cardinality >= startu + range_count and
            array[startu + range_count - 1] == re_included;
    }

    /// Check whether all positions in a range of positions from
    /// [pos_start, pos_end) is present in `run`.
    fn run_container_contains_range(run: Container, pos_start: u32, pos_end: u32, r: Bitmap) bool {
        const runs = run.blocks_as(.run, r)[0..run.cardinality];
        var count: u32 = 0;
        var index = misc.interleavedBinarySearch(runs, @truncate(pos_start));
        if (index < 0) {
            index = -index - 2;
            if (index == -1 or
                pos_start - runs[@intCast(index)].value > runs[@intCast(index)].length)
            {
                return false;
            }
        }
        var i: u32 = @bitCast(index);
        while (i < run.cardinality) : (i += 1) {
            const stop = runs[i].value + runs[i].length;
            if (runs[i].value >= pos_end)
                break;
            if (stop >= pos_end) {
                const diff = pos_end - runs[i].value;
                count += diff * @intFromBool(diff > 0);
                break;
            }
            const diff = stop - pos_start;
            const min = diff * @intFromBool(diff > 0);
            count += if (min < runs[i].length)
                min
            else
                runs[i].length;
        }

        return count >= (pos_end - pos_start - 1);
    }

    /// Check whether the range of values from [range_start, range_end) is present in the container.
    pub fn contains_range(c: Container, range_start: u32, range_end: u32, r: Bitmap) bool {
        return switch (c.typecode) {
            .bitset => c.bitset_container_get_range(range_start, range_end, r),
            .array => c.array_container_contains_range(range_start, range_end, r),
            .run => c.run_container_contains_range(range_start, range_end, r),
            .shared => unreachable,
        };
    }

    /// computes the size of the intersection of array1 and array2
    fn array_container_intersection_cardinality(
        c1: Container,
        x1: Bitmap,
        c2: Container,
        x2: Bitmap,
    ) Cardinality {
        const card_1 = c1.cardinality;
        const card_2 = c2.cardinality;
        const threshold = 64; // subject to tuning
        const c1array = c1.blocks_as(.array, x1)[0..card_1];
        const c2array = c2.blocks_as(.array, x2)[0..card_2];
        return @intCast(if (card_1 * threshold < card_2)
            misc.intersect_skewed_uint16_cardinality(c1array, c2array)
        else if (card_2 * threshold < card_1)
            misc.intersect_skewed_uint16_cardinality(c2array, c1array)
        else if (C.IS_X64)
            // TODO // if (C.HAS_AVX2)
            //     misc.intersect_vector16_cardinality(c1array, c2array)
            // else
            misc.intersect_uint16_cardinality(c1array, c2array)
        else
            misc.intersect_uint16_cardinality(c1array, c2array));
    }

    /// Compute the size of the intersection between src1 and src2
    fn array_run_container_intersection_cardinality(src1: Container, x1: Bitmap, src2: Container, x2: Bitmap) u32 {
        if (src2.run_container_is_full(x2))
            return src1.cardinality;
        if (src2.cardinality == 0)
            return 0;

        var rlepos: u32 = 0;
        var arraypos: u32 = 0;
        const src2runs = src2.blocks_as(.run, x2);
        var rle = src2runs[rlepos];
        var newcard: u32 = 0;
        const src1array = src1.blocks_as(.array, x1);
        while (arraypos < src1.cardinality) {
            const arrayval = src1array[arraypos];
            while (rle.value + rle.length < arrayval) {
                // this will frequently be false
                @branchHint(.unlikely); // TODO bench
                rlepos += 1;
                if (rlepos == src2.cardinality)
                    return newcard;
                rle = src2runs[rlepos];
            }
            if (rle.value > arrayval) {
                arraypos = misc.advanceUntil(src1array.ptr[0..arraypos], src1.cardinality, rle.value);
            } else {
                newcard += 1;
                arraypos += 1;
            }
        }
        return newcard;
    }

    /// Compute the size of the intersection of src1 and src2
    fn run_container_intersection_cardinality(src1: Container, x1: Bitmap, src2: Container, x2: Bitmap) u32 {
        const if1 = src1.run_container_is_full(x1);
        const if2 = src2.run_container_is_full(x2);
        const src1runs = src1.blocks_as(.run, x1)[0..src1.cardinality];
        const src2runs = src2.blocks_as(.run, x2)[0..src2.cardinality];
        if (if1 or if2) {
            if (if1)
                return src2.run_container_cardinality(src2runs.ptr);

            if (if2)
                return run_container_cardinality(src1, src1runs.ptr);
        }
        var answer: u32 = 0;
        var xrlepos: u32 = 0;
        var rlepos: u32 = 0;
        var start: u32 = src1runs[rlepos].value;
        var end: u32 = start + src1runs[rlepos].length + 1;
        var xstart: u32 = src2runs[xrlepos].value;
        var xend: u32 = xstart + src2runs[xrlepos].length + 1;
        while (rlepos < src1.cardinality and xrlepos < src2.cardinality) {
            if (end <= xstart) {
                rlepos += 1;
                if (rlepos < src1.cardinality) {
                    start = src1runs[rlepos].value;
                    end = start + src1runs[rlepos].length + 1;
                }
            } else if (xend <= start) {
                xrlepos += 1;
                if (xrlepos < src2.cardinality) {
                    xstart = src2runs[xrlepos].value;
                    xend = xstart + src2runs[xrlepos].length + 1;
                }
            } else { // they overlap
                const lateststart = @max(start, xstart);
                var earliestend: u32 = undefined;
                if (end == xend) { // improbable
                    @branchHint(.unlikely);
                    earliestend = end;
                    rlepos += 1;
                    xrlepos += 1;
                    if (rlepos < src1.cardinality) {
                        start = src1runs[rlepos].value;
                        end = start + src1runs[rlepos].length + 1;
                    }
                    if (xrlepos < src2.cardinality) {
                        xstart = src2runs[xrlepos].value;
                        xend = xstart + src2runs[xrlepos].length + 1;
                    }
                } else if (end < xend) {
                    earliestend = end;
                    rlepos += 1;
                    if (rlepos < src1.cardinality) {
                        start = src1runs[rlepos].value;
                        end = start + src1runs[rlepos].length + 1;
                    }
                } else { // end > xend
                    earliestend = xend;
                    xrlepos += 1;
                    if (xrlepos < src2.cardinality) {
                        xstart = src2runs[xrlepos].value;
                        xend = xstart + src2runs[xrlepos].length + 1;
                    }
                }
                answer += earliestend - lateststart;
            }
        }
        return answer;
    }

    /// Compute the size of the intersection of src1 and src2.
    fn array_bitset_container_intersection_cardinality(src1: Container, x1: Bitmap, src2: Container, x2: Bitmap) u32 {
        var newcard: u32 = 0;
        const origcard = src1.cardinality;
        const src1array = src1.blocks_as(.array, x1);
        for (0..origcard) |i| {
            const key = src1array[i];
            newcard += @intFromBool(src2.bitset_container_contains(key, x2));
        }
        return newcard;
    }

    /// Compute the intersection  between src1 and src2
    fn run_bitset_container_intersection_cardinality(src1: Container, x1: Bitmap, src2: Container, x2: Bitmap) u32 {
        if (run_container_is_full(src1, x1))
            return src2.cardinality;

        var answer: u32 = 0;
        const src1runs = src1.blocks_as(.run, x1)[0..src1.cardinality];
        const src2words = src2.blocks_as(.bitset, x2);
        for (0..src1.cardinality) |rlepos| {
            const rle = src1runs[rlepos];
            answer += misc.bitset_lenrange_cardinality(src2words.ptr, rle.value, rle.length);
        }
        return answer;
    }

    /// Compute the size of the intersection between two containers.
    pub fn and_cardinality(c1: Container, x1: Bitmap, c2: Container, x2: Bitmap) u32 {
        // TODO // c1 = container_unwrap_shared(c1, &type1);
        // TODO // c2 = container_unwrap_shared(c2, &type2);
        return switch (misc.pair(c1.typecode, c2.typecode)) {
            misc.pair(.bitset, .bitset) => bitset_container_and_justcard(
                c1.blocks_as(.bitset, x1).ptr,
                c2.blocks_as(.bitset, x2).ptr,
            ),
            misc.pair(.array, .array),
            => array_container_intersection_cardinality(c1, x1, c2, x2),
            misc.pair(.run, .run),
            => run_container_intersection_cardinality(c1, x1, c2, x2),
            misc.pair(.bitset, .array),
            => array_bitset_container_intersection_cardinality(c2, x2, c1, x1),
            misc.pair(.array, .bitset),
            => array_bitset_container_intersection_cardinality(c1, x1, c2, x2),
            misc.pair(.bitset, .run),
            => run_bitset_container_intersection_cardinality(c2, x2, c1, x1),
            misc.pair(.run, .bitset),
            => run_bitset_container_intersection_cardinality(c1, x1, c2, x2),
            misc.pair(.array, .run),
            => array_run_container_intersection_cardinality(c1, x1, c2, x2),
            misc.pair(.run, .array),
            => array_run_container_intersection_cardinality(c2, x2, c1, x1),
            else => unreachable,
        };
    }
};

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const root = @import("root.zig");
const Block = root.Block;
const Typecode = root.Typecode;
const Bitmap = root.Bitmap;
const Rle16 = root.Rle16;
const C = @import("constants.zig");
const misc = @import("misc.zig");
const trace = misc.trace;
const builtin = @import("builtin");
