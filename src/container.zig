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
        allocator: mem.Allocator,
        c: *Container,
        moreblocks: u32,
    ) !void {
        assert(moreblocks != 0);
        // TODO move this logic to extend_array?
        const cid = c - r.array.ptr(.containers);
        // trace(@src(), "moreblocks={} c={}", .{ moreblocks, c });
        const blockslen = r.array.ptr(.blockslen).*;
        if (blockslen + c.nblocks() + moreblocks >= r.array.ptr(.blockscapacity).*) {
            try r.extend_array(allocator, 0, moreblocks);
        }
        // move blocks and update blocks info
        const blocks = r.slice(.blocks, .blockscapacity);
        const c2 = &r.array.ptr(.containers)[cid];
        // trace(@src(), "blocks.len={} c2.blockoffset={} c2.nblocks()={} blockslen={} r.array.ptr(.blockslen)={}", .{ blocks.len, c2.blockoffset, c2.nblocks(), blockslen, r.array.ptr(.blockslen).* });
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
    /// preserve: true
    pub fn array_container_grow(
        ac: *Container,
        allocator: mem.Allocator,
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
        // trace(@src(), "mincapacity={} newcap={} morecap={} moreblocks={}", .{ mincapacity, newcap, morecap, moreblocks });
        // trace(@src(), "c={}", .{c});
        if (preserve) {
            try add_container_blocks(r, allocator, ac, moreblocks);
        } else {
            ac.deinit_blocks(r.*);
            try r.extend_array(allocator, 0, moreblocks);
            ac.blockoffset = @intCast(r.array.ptr(.blockslen).*);
            ac.nblocks_minus1 += @intCast(moreblocks);
            r.array.ptr(.blockslen).* += ac.nblocks();
        }
    }

    pub fn run_container_grow(
        rc: *Container,
        allocator: mem.Allocator,
        min: u32,
        copy: bool,
        r: *Bitmap,
    ) !void {
        const run_cap = rc.calc_capacity();
        var capacity = run_cap;
        const newCapacity = @max(min, if (capacity == 0)
            0
        else if (capacity < 64)
            capacity * 2
        else if (capacity < 1024)
            capacity * 3 / 2
        else
            capacity * 5 / 4);
        capacity = newCapacity;
        const morecap = capacity - run_cap;
        const moreblocks = misc.numGroupsOfSize(morecap, C.BLOCK_LEN32);

        if (copy) {
            try add_container_blocks(r, allocator, rc, moreblocks);
        } else if (rc.* == uninit) {
            rc.* = try run_container_create_given_capacity(allocator, capacity, r);
        } else {
            rc.deinit_blocks(r.*);
            try r.extend_array(allocator, 0, moreblocks);
            rc.blockoffset = @intCast(r.array.ptr(.blockslen).*);
            rc.nblocks_minus1 += @intCast(moreblocks);
            r.array.ptr(.blockslen).* += rc.nblocks();
        }
    }

    pub fn append(c: *Container, allocator: mem.Allocator, r: *Bitmap, value: u16) !void {
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
        allocator: mem.Allocator,
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

    /// Set the ith bit.
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

    pub fn run_container_add(
        run: *Container,
        allocator: mem.Allocator,
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
        try r.makeRoomAtIndex(allocator, run, @intCast(index +% 1));
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

    /// convert ac to a bitset.
    pub fn bitset_container_from_array(
        ac: *Container,
        allocator: mem.Allocator,
        r: *Bitmap,
    ) !Container {
        // copy ac to temporary.
        //
        // TODO remove large stack array. allocate in blocks.  as is, this simplifies
        // blockoffset bookeeping when called by container_add_range().
        var tmpac: [C.BITSET_BLOCKS]Block = undefined; // TODO
        const l = misc.numGroupsOfSize(ac.cardinality * @sizeOf(u16), C.BLOCK_SIZE);
        @memcpy(tmpac[0..l], ac.get_blocks(r.*)[0..l]);

        const acid = ac - r.array.ptr(.containers);
        if (ac.nblocks() < C.BITSET_BLOCKS)
            try add_container_blocks(r, allocator, ac, C.BITSET_BLOCKS - ac.nblocks());
        const bc = &r.array.ptr(.containers)[acid];
        @memset(bc.get_blocks(r.*), @splat(0));
        const words = bc.blocks_as(.bitset, r.*);
        const card = bc.cardinality;
        bc.cardinality = 0;
        for (misc.asSlice([]align(C.BLOCK_ALIGN) u16, &tmpac)[0..card]) |v| {
            bc.bitset_container_set(v, words);
        }
        bc.typecode = .bitset;
        assert(bc.cardinality == card);
        return bc.*;
    }

    /// Note: when an array container becomes full, it is converted to a bitset in place.
    pub fn add(c: *Container, allocator: mem.Allocator, r: *Bitmap, value: u16) !Container {
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

    pub fn compute_cardinality(v: Container, r: Bitmap) u30 {
        if (v == uninit) return 0;
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
                    if (end > (1 << 16)) {
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

    /// Check whether a value is in a container
    pub fn contains(c: Container, val: u16, r: Bitmap) bool {
        // c = c.container_unwrap_shared(); // TODO
        return switch (c.typecode) {
            .bitset => bitset_container_get(c.blocks_as(.bitset, r).ptr, val),
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
            try w.print("{t: <6} #{: <5} @{: <3} - {: <3} n{: <4}:", .{ c.typecode, c.get_cardinality(f.r), c.blockoffset, c.blockoffset + f.c.nblocks_minus1, c.cardinality });
            switch (c.typecode) {
                .array => {
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
                                if (v != vals[i - 1] + 1) {
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
                .bitset => {},
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
        const nblocksneeded = switch (c.typecode) {
            .bitset => return 0, // no shrinking possible
            .array => misc.numGroupsOfSize(c.cardinality, C.BLOCK_LEN16),
            .run => misc.numGroupsOfSize(c.cardinality, C.BLOCK_LEN32),
            .shared => unreachable,
        };
        const nblocks0 = c.nblocks();
        trace(@src(), "nblocksneeded={} nblocks={} src={}", .{ nblocksneeded, nblocks0, c });

        if (c.cardinality == 0) {
            c.deinit(r);
            return nblocks0 * C.BLOCK_SIZE;
        } else if (nblocksneeded < c.nblocks()) {
            c.nblocks_minus1 = @intCast(nblocksneeded - 1);
        }
        return (nblocks0 - c.nblocks()) * C.BLOCK_SIZE;
    }

    pub fn calc_capacity(c: Container) u32 {
        return if (c == uninit)
            0
        else
            @as(u32, c.nblocks()) *
                @as(u32, switch (c.typecode) {
                    .bitset => C.BLOCK_SIZE,
                    .array => C.BLOCK_LEN16,
                    .run => C.BLOCK_LEN32,
                    .shared => unreachable,
                });
    }

    pub fn array_container_create_given_capacity(
        allocator: mem.Allocator,
        capacity: u32,
        r: *Bitmap,
    ) !Container {
        trace(@src(), "capacity={}", .{capacity});
        const numblocks = misc.numGroupsOfSize(capacity * @sizeOf(u16), C.BLOCK_SIZE);
        try r.extend_array(allocator, 1, numblocks);
        defer r.array.ptr(.blockslen).* += numblocks;
        return .{
            .typecode = .array,
            .cardinality = 0,
            .blockoffset = @intCast(r.array.ptr(.blockslen).*),
            .nblocks_minus1 = @intCast(numblocks - 1),
        };
    }

    pub fn run_container_create_given_capacity(
        allocator: mem.Allocator,
        nruns_capacity: u32,
        r: *Bitmap,
    ) !Container {
        trace(@src(), "nruns={}", .{nruns_capacity});
        const numblocks = misc.numGroupsOfSize(nruns_capacity * @sizeOf(root.Rle16), C.BLOCK_SIZE);
        try r.extend_array(allocator, 1, numblocks);
        defer r.array.ptr(.blockslen).* += numblocks;
        return .{
            .typecode = .run,
            .cardinality = 0,
            .blockoffset = @intCast(r.array.ptr(.blockslen).*),
            .nblocks_minus1 = @intCast(numblocks - 1),
        };
    }

    pub fn bitset_container_create(
        allocator: mem.Allocator,
        r: *Bitmap,
    ) !Container {
        try r.extend_array(allocator, 1, C.BITSET_BLOCKS);
        defer r.array.ptr(.blockslen).* += C.BITSET_BLOCKS;
        return .{
            .typecode = .bitset,
            .cardinality = 0,
            .blockoffset = @intCast(r.array.ptr(.blockslen).*),
            .nblocks_minus1 = C.BITSET_BLOCKS - 1,
        };
    }

    /// Check whether this bitset is empty,
    pub fn bitset_container_empty(bitset: Container, r: Bitmap) bool {
        if (bitset.cardinality == C.BITSET_UNKNOWN_CARDINALITY) {
            const words = bitset.blocks_as(.bitset, r);
            for (0..C.BITSET_CONTAINER_SIZE_IN_WORDS) |i| {
                if ((words[i]) != 0) return false;
            }
            return true;
        }
        return bitset.cardinality == 0;
    }

    /// Checks whether a container is not empty, requires a  typecode
    pub fn nonzero_cardinality(c: Container, r: Bitmap) bool {
        // TODO // c = c.container_unwrap_shared();
        return switch (c.typecode) {
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
    fn run_container_remove(run: *Container, allocator: mem.Allocator, pos: u16, r: *Bitmap) !bool {
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
                try r.makeRoomAtIndex(allocator, run, @intCast(mindex + 1));
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
    pub fn bitset_extract_setbits_u16(
        words: [*]align(C.BLOCK_ALIGN) u64,
        out: []align(C.BLOCK_ALIGN) u16,
        base: u16,
    ) usize {
        var outpos: usize = 0;
        var base1 = base;
        for (words[0..C.BITSET_CONTAINER_SIZE_IN_WORDS]) |w0| {
            var w = w0;
            while (w != 0) {
                out[outpos] = (@ctz(w) + base1);
                outpos += 1;
                w &= (w - 1);
            }
            base1 +%= 64;
        }
        return outpos;
    }

    pub fn array_container_from_bitset(
        bits: *Container,
        allocator: mem.Allocator,
        r: *Bitmap,
    ) !Container {
        const cid = bits - r.array.ptr(.containers);
        var result = try array_container_create_given_capacity(allocator, bits.cardinality, r);
        const bits2 = r.array.ptr(.containers)[cid];
        result.cardinality = bits2.cardinality;
        // TODO avx512 version?
        // sse version ends up being slower here because of the sparsity of the data
        _ = bitset_extract_setbits_u16(bits2.blocks_as(.bitset, r.*).ptr, result.blocks_as(.array, r.*), 0);
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
    pub fn convert_run_optimize(cid: u32, allocator: mem.Allocator, r: *Bitmap) !Container {
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
            try r.extend_array(allocator, 0, nrunblocks);

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
    pub fn remove(c: *Container, allocator: mem.Allocator, val: u16, r: *Bitmap) !Container {
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

    fn op_methods(comptime op: std.builtin.ReduceOp) type {
        return struct {
            fn bitset_container_op(
                src1: [*]align(C.BLOCK_ALIGN) const u64,
                src2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: *Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) u32 {
                return if (C.HAS_AVX2)
                    _avx2_bitset_container_op(src1, src2, dstc, dst)
                else
                    _scalar_bitset_container_op(src1, src2, dstc, dst);
            }

            fn _scalar_bitset_container_op(
                src1: [*]align(C.BLOCK_ALIGN) const u64,
                src2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: *Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) u30 {
                _ = src1;
                _ = src2;
                _ = dstc;
                _ = dst;
                unreachable;
                // var sum: u30 = 0;
                // var i: usize = 0;
                // while (i < C.BITSET_CONTAINER_SIZE_IN_WORDS) : (i += 2) {
                //     const word1 = opsymbol(words1[i], words2[i]);
                //     const word2 = opsymbol(words1[i + 1], words2[i + 1]);
                //     sum += @popCount(word1);
                //     sum += @popCount(word2);
                // }
                // return sum;
            }
            fn _avx2_bitset_container_op(
                src1: [*]align(C.BLOCK_ALIGN) const u64,
                src2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: *Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) u30 {
                _ = dstc;
                _ = dst;
                if (true) unreachable;
                return @intCast(avx2_harley_seal_popcount_op(
                    @ptrCast(src1),
                    @ptrCast(src2),
                    C.BITSET_CONTAINER_SIZE_IN_WORDS / (C.BLOCK_SIZE),
                ));
            }

            fn bitset_container_op_nocard(
                src1: [*]align(C.BLOCK_ALIGN) const u64,
                src2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: *Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) u30 {
                if (C.HAS_AVX2) {
                    const a = _avx2_bitset_container_op_nocard(src1, src2, dstc, dst);
                    const b = _scalar_bitset_container_op_nocard(src1, src2, dstc, dst);
                    if (a != b) {
                        trace(@src(), "avx nocard {} != scalar nocard {}", .{ a, b });
                        unreachable;
                    }
                    return a;
                } else _scalar_bitset_container_op_nocard(src1, src2, dstc, dst);
            }
            pub fn bitset_container_op_justcard(
                src1: [*]align(C.BLOCK_ALIGN) const u64,
                src2: [*]align(C.BLOCK_ALIGN) const u64,
            ) u32 {
                return if (C.HAS_AVX2) {
                    const a = _avx2_bitset_container_op_justcard(src1, src2);
                    const b = _scalar_bitset_container_op_justcard(src1, src2);
                    if (a != b) {
                        trace(@src(), "avx justcard {} != scalar justcard {}", .{ a, b });
                        unreachable;
                    }
                    return a;
                } else _scalar_bitset_container_op_justcard(src1, src2);
            }

            fn _scalar_bitset_container_op_justcard(
                words1: [*]align(C.BLOCK_ALIGN) const u64,
                words2: [*]align(C.BLOCK_ALIGN) const u64,
            ) u30 {
                var sum: u30 = 0;
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
            ) u30 {
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
                    else => unreachable,
                };
            }

            /// Simple CSA over Block
            pub fn CSA(h: *Block, l: *Block, a: Block, b: Block, c: Block) void {
                const u = a ^ b;
                h.* = (a & b) | (u & c);
                l.* = u ^ c;
            }

            /// Fast Harley-Seal AVX population count function
            pub fn avx2_harley_seal_popcount(data: []root.Block) u64 {
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
                    CSA(&twosA, &ones, ones, (data + i)[0..@sizeOf(Block)].*, (data + i + 1)[0..@sizeOf(Block)].*);
                    CSA(&twosB, &ones, ones, (data + i + 2)[0..@sizeOf(Block)].*, (data + i + 3)[0..@sizeOf(Block)].*);
                    CSA(&foursA, &twos, twos, twosA, twosB);
                    CSA(&twosA, &ones, ones, (data + i + 4)[0..@sizeOf(Block)].*, (data + i + 5)[0..@sizeOf(Block)].*);
                    CSA(&twosB, &ones, ones, (data + i + 6)[0..@sizeOf(Block)].*, (data + i + 7)[0..@sizeOf(Block)].*);
                    CSA(&foursB, &twos, twos, twosA, twosB);
                    CSA(&eightsA, &fours, fours, foursA, foursB);
                    CSA(&twosA, &ones, ones, (data + i + 8)[0..@sizeOf(Block)].*, (data + i + 9)[0..@sizeOf(Block)].*);
                    CSA(&twosB, &ones, ones, (data + i + 10)[0..@sizeOf(Block)].*, (data + i + 11)[0..@sizeOf(Block)].*);
                    CSA(&foursA, &twos, twos, twosA, twosB);
                    CSA(&twosA, &ones, ones, (data + i + 12)[0..@sizeOf(Block)].*, (data + i + 13)[0..@sizeOf(Block)].*);
                    CSA(&twosB, &ones, ones, (data + i + 14)[0..@sizeOf(Block)].*, (data + i + 15)[0..@sizeOf(Block)].*);
                    CSA(&foursB, &twos, twos, twosA, twosB);
                    CSA(&eightsB, &fours, fours, foursA, foursB);
                    CSA(&sixteens, &eights, eights, eightsA, eightsB);

                    total = total + @as(Block, @splat(popcount256(sixteens)));
                }

                total <<= 4; // *= 16
                total += popcount256(eights) << 3; // += 8 * ...
                total += popcount256(fours) << 2; // += 4 * ...
                total += popcount256(twos) << 1; // += 2 * ...
                total += popcount256(ones);
                while (i < size) : (i += 1)
                    total += popcount256((data + i)[0..@sizeOf(Block).*]);

                return @reduce(.Add, total);
            }

            pub inline fn popcount256(v: Block) root.Block64 {
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
            ) u30 {
                for (0..C.BITSET_CONTAINER_SIZE_IN_WORDS) |i| {
                    dst[i] = avx_intrinsic(words1[i], words2[i]);
                }
                dstc.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
                return dstc.cardinality;
            }

            fn _avx2_bitset_container_op_nocard(
                words_1: [*]align(C.BLOCK_ALIGN) const u64,
                words_2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: *Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) u30 {
                const innerloop = 8;
                var words1: [*]const root.Block64 = @ptrCast(words_1);
                var words2: [*]const root.Block64 = @ptrCast(words_2);
                var wordsout: [*]root.Block64 = @ptrCast(dst);
                var i: usize = 0;
                while (i < C.BITSET_BLOCKS / innerloop) : (i += innerloop) {
                    inline for (0..innerloop) |j| {
                        wordsout[i + j] = avx_intrinsic(words2[j], words1[j]);
                        words1 += 1;
                        words2 += 1;
                    }
                }
                dstc.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
                return C.BITSET_UNKNOWN_CARDINALITY;
            }
        };
    }

    /// Computes the intersection of bitsets `src1' and `src2'  and return the
    /// cardinality.
    fn bitset_container_and_justcard(
        src1: [*]align(C.BLOCK_ALIGN) const u64,
        src2: [*]align(C.BLOCK_ALIGN) const u64,
    ) u30 {
        return @intCast(op_methods(.And).bitset_container_op_justcard(src1, src2));
    }

    /// Computes the intersection of bitsets `src1' and `src2' into `dst', but does
    /// not update the cardinality. Provided to optimize chained operations.
    fn bitset_container_and_nocard(
        data1: [*]align(C.BLOCK_ALIGN) const u64,
        data2: [*]align(C.BLOCK_ALIGN) const u64,
        dstc: *Container,
        dst: [*]align(C.BLOCK_ALIGN) u64,
    ) u30 {
        return op_methods(.And).bitset_container_op_nocard(data1, data2, dstc, dst);
    }

    /// Compute the intersection between src1 and src2 and write the result
    /// to *dst. If the return function is true, the result is a bitset_container_t
    /// otherwise is a array_container_t.
    fn bitset_bitset_container_intersection(
        dst: *Container,
        allocator: mem.Allocator,
        dstr: *Bitmap,
        src1: Container,
        x1: Bitmap,
        src2: Container,
        x2: Bitmap,
    ) !void {
        const newCardinality = bitset_container_and_justcard(
            src1.blocks_as(.bitset, x1).ptr,
            src2.blocks_as(.bitset, x2).ptr,
        );
        if (newCardinality > C.DEFAULT_MAX_SIZE) {
            dst.* = try bitset_container_create(allocator, dstr);
            _ = bitset_container_and_nocard(
                src1.blocks_as(.bitset, x1).ptr,
                src2.blocks_as(.bitset, x2).ptr,
                dst,
                dst.blocks_as(.bitset, dstr.*).ptr,
            );
            dst.cardinality = newCardinality;
            return;
        }
        if (newCardinality == 0) return;
        dst.* = try array_container_create_given_capacity(allocator, newCardinality, dstr);
        dst.cardinality = newCardinality;
        _ = bitset_extract_intersection_setbits_uint16(
            src1.blocks_as(.bitset, x1),
            src2.blocks_as(.bitset, x2),
            dst.blocks_as(.array, dstr.*),
            0,
        );
    }

    /// Same as bitset_bitset_container_intersection except that if the output
    /// is to be a bitset container, then src1 is modified and no allocation
    /// is made. If the output is to be an array container, then caller is
    /// responsible to free the container. In all cases, the result is in *dst.
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
        dst: *Container,
        allocator: mem.Allocator,
        dstr: *Bitmap,
        ac1: Container,
        x1: Bitmap,
        ac2: Container,
        x2: Bitmap,
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
                ac1.blocks_as(.array, x1)[0..card1],
                ac2.blocks_as(.array, x2)[0..card2],
                dst.blocks_as(.array, dstr.*),
            ));
        } else if (card2 * threshold < card1) {
            dst.cardinality = @intCast(misc.intersect_skewed_uint16(
                ac2.blocks_as(.array, x2)[0..card2],
                ac1.blocks_as(.array, x1)[0..card1],
                dst.blocks_as(.array, dstr.*),
            ));
        } else {
            if (C.HAS_AVX2) {
                // TODO use intersect_vector16() when HAS_AVX2
            }
            dst.cardinality = @intCast(misc.intersect_uint16(
                ac1.blocks_as(.array, x1)[0..card1],
                ac2.blocks_as(.array, x2)[0..card2],
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
        allocator: mem.Allocator,
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
        dst: *Container,
        allocator: mem.Allocator,
        dstr: *Bitmap,
        src1: Container,
        x1: Bitmap,
        src2: Container,
        x2: Bitmap,
    ) !void {
        const if1 = run_container_is_full(src1, x1);
        const if2 = run_container_is_full(src2, x2);
        if (if1 or if2) {
            if (if1) {
                try src2.run_container_copy(allocator, dst, src2.blocks_as(.run, x2).ptr, dstr);
                return;
            }
            if (if2) {
                try src1.run_container_copy(allocator, dst, src1.blocks_as(.run, x1).ptr, dstr);
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
        const src1_runs = src1.blocks_as(.run, x1);
        const src2_runs = src2.blocks_as(.run, x2);
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
        allocator: mem.Allocator,
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
        dst: *Container,
        allocator: mem.Allocator,
        dstr: *Bitmap,
        src1: Container,
        x1: Bitmap,
        src2: Container,
        x2: Bitmap,
    ) !void {
        if (dst.calc_capacity() < src1.cardinality)
            try array_container_grow(dst, allocator, dstr, src1.cardinality, false);
        var newcard: u30 = 0; // dst could be src1
        const origcard = src1.cardinality;
        const src1array = src1.blocks_as(.array, x1);
        const dstarray = dst.blocks_as(.array, dstr.*);
        for (0..origcard) |i| {
            const key = src1array[i];
            // this branchless approach is much faster...
            dstarray[newcard] = key;

            newcard += @intFromBool(bitset_container_get(src2.blocks_as(.bitset, x2).ptr, key));
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

    /// Compute the intersection of src1 and src2 and write the result to
    /// dst. It is allowed for dst to be equal to src1. We assume that dst is a
    /// valid container.
    fn array_run_container_intersection(
        dst: *Container,
        allocator: mem.Allocator,
        dstr: *Bitmap,
        src1: Container,
        x1: Bitmap,
        src2: Container,
        x2: Bitmap,
    ) !void {
        assert(src1.cardinality > 0 and src2.cardinality > 0);
        dst.nblocks_minus1 = @intCast(misc.numGroupsOfSize(src1.cardinality, C.BLOCK_LEN16) - 1);
        if (run_container_is_full(src2, x2)) {
            if (dst.* != src1)
                try src1.array_container_copy(allocator, dst, src1.blocks_as(.array, x1).ptr, dstr);
            return;
        }
        if (dst.calc_capacity() < src1.cardinality)
            try array_container_grow(dst, allocator, dstr, src1.cardinality, false);
        if (src2.cardinality == 0)
            return;

        var rlepos: u32 = 0;
        var arraypos: u32 = 0;
        const src2runs = src2.blocks_as(.run, x2);
        var rle = src2runs[rlepos];
        var newcard: u30 = 0;
        const src1array = src1.blocks_as(.array, x1);
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
        allocator: mem.Allocator,
        r: *Bitmap,
    ) !Container {
        assert(c.typecode == .run);
        const runsize = c.serialized_size_in_bytes();
        const card = c.compute_cardinality(r.*);
        const arraysize = card * @sizeOf(u16);
        const min_size_non_run = @min(@sizeOf(root.Bitset), arraysize);
        trace(@src(), "arraysize={} runsize={} min_size_non_run={}", .{ arraysize, runsize, min_size_non_run });
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
            try r.extend_array(allocator, 0, cnblocks);
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
        allocator: mem.Allocator,
        r: *Bitmap,
    ) !Container {
        const answer = try c.convert_run_to_efficient_container(allocator, r);
        if (answer != c) c.deinit_blocks(r.*);
        return answer;
    }

    /// Compute intersection between two containers, generate a new container.
    /// This allocates new memory, caller is responsible for deallocation.
    pub fn intersect(
        c1: Container,
        allocator: mem.Allocator,
        c2: Container,
        x1: Bitmap,
        x2: Bitmap,
        dstr: *Bitmap,
    ) !Container {
        // TODO // c1 = container_unwrap_shared(c1);
        // TODO // c2 = container_unwrap_shared(c2);

        var result: Container = .uninit;
        trace(@src(), "c1=    {}", .{c1});
        trace(@src(), "c2=    {}", .{c2});
        defer trace(@src(), "result={}", .{result});
        switch (misc.pair(c1.typecode, c2.typecode)) {
            else => |p| std.debug.panic("TODO {any}\n", .{misc.pairFromInt(p)}),
            misc.pair(.bitset, .bitset) => {
                try bitset_bitset_container_intersection(&result, allocator, dstr, c1, x1, c2, x2);
            },
            misc.pair(.array, .array) => {
                result = try array_container_create_given_capacity(allocator, @min(c1.cardinality, c2.cardinality), dstr);
                try array_container_intersection(&result, allocator, dstr, c1, x1, c2, x2);
            },
            misc.pair(.run, .run) => {
                try run_container_intersection(&result, allocator, dstr, c1, x1, c2, x2);
                return try result.convert_run_to_efficient_container_and_free(allocator, dstr);
            },
            misc.pair(.bitset, .array) => {
                result = try array_container_create_given_capacity(allocator, c2.cardinality, dstr);
                try array_bitset_container_intersection(&result, allocator, dstr, c2, x2, c1, x1);
            },
            misc.pair(.array, .bitset) => {
                result = try array_container_create_given_capacity(allocator, c1.cardinality, dstr);
                try array_bitset_container_intersection(&result, allocator, dstr, c1, x1, c2, x2);
            },
            //     misc.pair(.bitset, .run) => {
            //         return run_bitset_container_intersection(c2, c1, &result);
            //     },
            //     misc.pair(.run, .bitset) => {
            //         return run_bitset_container_intersection(c1, c2, &result);
            //     },
            misc.pair(.array, .run) => {
                result = try array_container_create_given_capacity(allocator, c1.cardinality, dstr);
                try array_run_container_intersection(&result, allocator, dstr, c1, x1, c2, x2);
            },
            misc.pair(.run, .array) => {
                result = try array_container_create_given_capacity(allocator, c2.cardinality, dstr);
                try array_run_container_intersection(&result, allocator, dstr, c2, x2, c1, x1);
            },
        }
        return result;
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
        var base1 = base;
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
