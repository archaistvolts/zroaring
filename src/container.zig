/// An array, bitset or run container stored as simd blocks.
pub const Container = struct {
    data: *align(C.BLOCK_ALIGN) Data,

    pub const Data = struct {
        typecode: root.Typecode,
        /// cached container cardinality or nruns.
        cardinality: Cardinality,
        blocks_cap: u16,
        blocks: [*]Block,
    };
    const _uninit_data: [C.CONTAINER_DATA_SIZE]u8 align(C.BLOCK_ALIGN) = @splat(0xff);
    pub const uninit: Container = .{ .data = @ptrCast(@constCast(&_uninit_data)) };

    pub const Cardinality = u32;
    pub const ICardinality = i32;
    const Element = union(root.Typecode) {
        shared: void,
        bitset: [*]align(C.BLOCK_ALIGN) u64,
        array: [*]align(C.BLOCK_ALIGN) u16,
        run: [*]align(C.BLOCK_ALIGN) root.Rle16,
    };

    pub fn deinit(c: *Container, allocator: mem.Allocator) void {
        if (c.is_uninit()) return;
        c.destroy(allocator);
        c.* = uninit;
    }

    pub fn is_uninit(c: Container) bool {
        return c.data == uninit.data;
    }

    pub fn is_at_capacity(c: Container) bool {
        return switch (c.data.typecode) {
            .array, .run => c.data.cardinality == c.calc_capacity(),
            .bitset => unreachable, // nonsense. bitset is always at capacity.
            .shared => unreachable,
        };
    }

    /// return container blocks as aligned slice of u16 when typecode == .array etc.
    /// slices by capacity.
    pub inline fn blocks_as(
        c: Container,
        comptime typecode: root.Typecode,
    ) @FieldType(Element, @tagName(typecode)) {
        return @ptrCast(@constCast(c.data.blocks));
    }

    fn calc_size(blocks_cap: u16) usize {
        return C.CONTAINER_DATA_SIZE + @sizeOf(Block) * blocks_cap;
    }

    pub fn from_bytes(
        bytes: []align(C.BLOCK_ALIGN) u8,
        typecode: Typecode,
        cardinality: Cardinality,
        blocks_cap: u16,
    ) Container {
        const data: *align(C.BLOCK_ALIGN) Data = @ptrCast(bytes.ptr);
        data.* = .{
            .typecode = typecode,
            .cardinality = cardinality,
            .blocks_cap = blocks_cap,
            .blocks = @ptrCast(@alignCast(bytes.ptr + C.CONTAINER_DATA_SIZE)),
        };
        return .{ .data = data };
    }

    pub fn create(
        allocator: Allocator,
        typecode: Typecode,
        cardinality: Cardinality,
        blocks_cap: u16,
    ) !Container {
        const bytes = try allocator.alignedAlloc(
            u8,
            C.BLOCK_ALIGNMENT,
            C.CONTAINER_DATA_SIZE + @sizeOf(Block) * blocks_cap,
        );
        return from_bytes(bytes, typecode, cardinality, blocks_cap);
    }

    pub fn as_bytes(c: Container) [*]align(C.BLOCK_ALIGN) u8 {
        return @alignCast(mem.asBytes(c.data).ptr);
    }

    pub fn destroy(c: Container, allocator: Allocator) void {
        allocator.free(c.as_bytes()[0..calc_size(c.data.blocks_cap)]);
    }

    pub fn get_cardinality(c: Container) Cardinality {
        return switch (c.data.typecode) {
            .bitset, .array => c.data.cardinality,
            .run => run_container_cardinality(c, c.blocks_as(.run)),
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

    pub fn assert_valid(c: Container) void {
        if (!(builtin.is_test or builtin.mode == .Debug)) return;
        var reason: ?[]const u8 = null;
        if (!c.internal_validate(&reason)) {
            trace(@src(), "{s}", .{reason.?});
            unreachable;
        }
    }

    /// add enough blocks to container to hold mincapacity. use allocator.resize
    /// to avoid copying. fall back to alloc + copy (if preserve) + free.
    ///
    /// mincapacity: number of array container values.
    ///
    /// preserve: preserve (copy) block contents.
    pub fn array_container_grow(
        ac: *Container,
        allocator: Allocator,
        mincapacity: u32,
        preserve: bool,
    ) !void {
        const max: u32 = if (mincapacity <= C.DEFAULT_MAX_SIZE)
            C.DEFAULT_MAX_SIZE
        else
            C.MAX_CONTAINERS;
        const cap = ac.calc_capacity();
        const newcap = math.clamp(grow_capacity(cap), mincapacity, max);
        const morecap = newcap - cap;
        const moreblocks = misc.numGroupsOfSize(morecap, C.BLOCK_LEN16);
        assert(moreblocks > 0);
        const newsize = calc_size(@intCast(ac.data.blocks_cap + moreblocks));
        if (preserve) {
            const blocks = ac.data.blocks;
            const bytes = ac.as_bytes()[0..calc_size(ac.data.blocks_cap)];
            if (allocator.resize(bytes, newsize)) {
                ac.data.blocks_cap += @intCast(moreblocks);
                assert(ac.data.blocks == blocks);
                return;
            }
        }

        const newac = try create(
            allocator,
            .array,
            ac.data.cardinality,
            @intCast(ac.data.blocks_cap + moreblocks),
        );
        if (preserve)
            @memcpy(newac.data.blocks[0..ac.data.blocks_cap], ac.data.blocks);
        ac.destroy(allocator);
        ac.data = newac.data;
    }

    pub fn realloc_container(
        c: *Container,
        allocator: Allocator,
        typecode: Typecode,
        cardinality: Cardinality,
        blocks_cap: u16,
    ) !void {
        const newbytes = try allocator.realloc(
            c.as_bytes()[0..calc_size(c.data.blocks_cap)],
            calc_size(blocks_cap),
        );
        c.data = from_bytes(newbytes, typecode, cardinality, blocks_cap).data;
    }

    // if `copy` realloc.  else alloc + free.
    pub fn run_container_grow(
        rc: *Container,
        allocator: Allocator,
        min: u32,
        copy: bool,
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
        const moreblocks = misc.numGroupsOfSize(morecap, C.BLOCK_LEN32);
        assert(!rc.is_uninit());
        if (moreblocks != 0) { // moreblocks might be 0 if already at capacity.
            // benchmarks show this to be slightly (1 or 2%) faster than using
            // realloc_contaier when copy=true
            var rcold = rc.*;
            rc.* = try create(allocator, .run, rc.data.cardinality, @intCast(rc.data.blocks_cap + moreblocks));
            if (copy) {
                @memcpy(rc.data.blocks, rcold.data.blocks[0..rcold.data.blocks_cap]);
            }
            rcold.deinit(allocator);
        }
    }

    pub fn append(c: *Container, allocator: Allocator, value: u16) !void {
        assert(c.data.typecode == .array);
        if (c.is_at_capacity()) {
            try c.array_container_grow(allocator, c.data.cardinality + 1, true);
        }
        const array = c.blocks_as(.array);
        array[c.data.cardinality] = value;
        c.data.cardinality += 1;
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
        value: u16,
        maxcard: u32,
    ) !i32 {
        const cardinality = ac.data.cardinality;
        var array = ac.blocks_as(.array);
        // best case, we can append.
        if ((cardinality == 0 or value > array[cardinality - 1]) and cardinality < maxcard) {
            try ac.append(allocator, value);
            return 1;
        }
        const loc = misc.binarySearch(array[0..cardinality], value);
        if (loc >= 0) {
            return 0;
        } else if (cardinality < maxcard) {
            if (ac.is_at_capacity()) {
                try ac.array_container_grow(allocator, cardinality + 1, true);
            }
            array = ac.blocks_as(.array);
            const insertidx: u32 = @intCast(-loc - 1);
            // trace(@src(), "inserting value={} at index {} array={any}", .{ value, insertidx, array });
            @memmove(array + insertidx + 1, array[insertidx..cardinality]);
            array[insertidx] = value;
            ac.data.cardinality += 1;
            return 1;
        }
        return -1;
    }

    const Words = @FieldType(Element, "bitset");

    /// Set the ith bit.  increments cardinality if pos not found.
    fn bitset_container_set(bc: Container, pos: u16, words: Words) void {
        const old_word = words[pos >> 6];
        const index: u6 = @truncate(pos & 63);
        const new_word = old_word | (@as(u64, 1) << index);
        bc.data.cardinality += @intCast((old_word ^ new_word) >> index);
        words[pos >> 6] = new_word;
    }

    /// Add `pos' to `bitset'. Returns true if `pos' was not present. Might be slower
    /// than bitset_container_set.
    fn bitset_container_add(bc: Container, pos: u16, words: Words) bool {
        const old_word = words[pos >> 6];
        const index: u6 = @truncate(pos & 63);
        const new_word = old_word | (@as(u64, 1) << index);
        const increment = (old_word | new_word) >> index;
        bc.data.cardinality += @intCast(increment);
        words[pos >> 6] = new_word;
        return increment > 0;
    }

    /// Moves the data so that we can write data at index
    fn makeRoomAtIndex(run: *Container, allocator: Allocator, index: u16) !void {
        // This function calls realloc + memmove sequentially to move by one index.
        // Potentially copying the array twice.

        if (run.data.cardinality + 1 > run.calc_capacity()) {
            try run.run_container_grow(allocator, run.data.cardinality + 1, true);
        }

        const runs = run.blocks_as(.run);
        @memmove(runs + 1 + index, (runs + index)[0 .. run.data.cardinality - index]);
        run.data.cardinality += 1;
    }

    /// Add all values in range [min, max] using hint.
    pub fn run_container_add_range_nruns(
        run: *Container,
        allocator: Allocator,
        min: u32,
        max: u32,
        nruns_less: u32,
        nruns_greater: u32,
    ) !void {
        const nruns_common = run.data.cardinality - nruns_less - nruns_greater;
        if (nruns_common == 0) {
            try run.makeRoomAtIndex(allocator, @truncate(nruns_less));
            const runs = run.blocks_as(.run)[0..run.data.cardinality];
            runs.ptr[nruns_less] = .{
                .value = @truncate(min),
                .length = @truncate(max - min),
            };
        } else {
            const runs = run.blocks_as(.run)[0..run.data.cardinality];
            const common_min = runs[nruns_less].value;
            const common_max = runs[nruns_less + nruns_common - 1].value +
                runs[nruns_less + nruns_common - 1].length;
            const result_min = if (common_min < min) common_min else min;
            const result_max = if (common_max > max) common_max else max;

            runs[nruns_less].value = @truncate(result_min);
            runs[nruns_less].length = @truncate((result_max - result_min));

            @memmove(
                runs.ptr + nruns_less + 1,
                runs[run.data.cardinality - nruns_greater ..][0..nruns_greater],
            );
            run.data.cardinality = @intCast(nruns_less + 1 + nruns_greater);
        }
    }

    /// Effectively deletes the value at index index, repacking data.
    fn recoverRoomAtIndex(run: *Container, index: u16) void {
        const runs = run.blocks_as(.run)[0..run.data.cardinality].ptr;
        @memmove(runs + index, (runs + (1 + index))[0 .. run.data.cardinality - index - 1]);
        run.data.cardinality -= 1;
    }

    pub fn run_container_add(
        run: *Container,
        allocator: Allocator,
        pos: u16,
    ) !bool {
        var runs = run.blocks_as(.run);
        var mindex = misc.interleavedBinarySearch(runs[0..run.data.cardinality], pos);
        if (mindex >= 0) return false; // already there
        mindex = -mindex - 2; // points to preceding value, possibly -1
        const index: u32 = @bitCast(mindex);
        if (mindex >= 0) { // possible match
            const offset: i32 = pos - runs[index].value;
            const le: i32 = runs[index].length;
            if (offset <= le) return false; // already there
            if (offset == le + 1) {
                // we may need to fuse
                if (index + 1 < run.data.cardinality) {
                    if (runs[index + 1].value == pos + 1) {
                        // indeed fusion is needed
                        runs[index].length = runs[index + 1].value +
                            runs[index + 1].length -
                            runs[index].value;
                        run.recoverRoomAtIndex(@intCast(index + 1));
                        return true;
                    }
                }
                runs[index].length += 1;
                return true;
            }
            if (index + 1 < run.data.cardinality) {
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
            if (run.data.cardinality > 0) {
                if (runs[0].value == pos + 1) {
                    runs[0].length += 1;
                    runs[0].value -= 1;
                    return true;
                }
            }
        }
        // trace(@src(), "index={} cindex={} {f}", .{ mindex, cindex, run.fmt(r.*) });
        try run.makeRoomAtIndex(allocator, @intCast(index +% 1));
        runs = run.blocks_as(.run);
        runs[index +% 1] = .{ .value = pos, .length = 0 };
        return true;
    }

    pub fn get_key(c: [*]*Container, r: Bitmap) u16 {
        return r.array.keys[c - r.array.containers];
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
    pub fn bitset_container_from_array(ac: Container, allocator: Allocator) !Container {
        var ans = try bitset_container_create(allocator);
        const array = ac.blocks_as(.array);
        const words = ans.blocks_as(.bitset);
        const limit = ac.data.cardinality;
        for (array[0..limit]) |v| bitset_container_set(ans, v, words);
        return ans;
    }

    /// convert ac to a bitset in dst.  ac is in r.
    pub fn bitset_container_from_array_dst(ac: Container, allocator: Allocator) !Container {
        const limit = ac.data.cardinality;
        var ans = try bitset_container_create(allocator);
        for (ac.blocks_as(.array)[0..limit]) |v|
            bitset_container_set(ans, v, ans.blocks_as(.bitset));
        return ans;
    }

    /// Note: when an array container becomes full, it is converted to a bitset in place.
    pub fn add(c: *Container, allocator: Allocator, value: u16) !Container {
        // TODO // c = c.get_writable_copy_if_shared();
        switch (c.data.typecode) {
            .bitset => {
                c.bitset_container_set(value, c.blocks_as(.bitset));
                return c.*;
            },
            .array => {
                const add_res = try c.array_container_try_add(allocator, value, C.DEFAULT_MAX_SIZE);
                if (add_res != -1)
                    return c.*;

                const bitset = try c.bitset_container_from_array(allocator);
                bitset.bitset_container_set(value, bitset.blocks_as(.bitset));
                return bitset;
            },
            .run => {
                _ = try c.run_container_add(allocator, value);
                return c.*;
            },
            .shared => unreachable,
        }
    }

    pub fn run_container_serialized_size_in_bytes(cardinality: u32) u32 {
        return @sizeOf(u16) + @sizeOf(root.Rle16) * cardinality;
    }

    pub fn serialized_size_in_bytes(c: Container) u32 {
        return switch (c.data.typecode) {
            .array => @sizeOf(u16) * c.data.cardinality,
            .run => run_container_serialized_size_in_bytes(c.data.cardinality),
            .bitset => @sizeOf(root.Bitset),
            .shared => unreachable,
        };
    }
    pub const size_in_bytes = serialized_size_in_bytes;

    inline fn _avx2_bitset_container_equals(c1: Container, c2: Container) bool {
        for (c1.data.blocks[0..C.BITSET_BLOCKS], c2.data.blocks) |b1, b2| {
            const mask: root.BlockMask = @bitCast(b1 == b2);
            if (mask != math.maxInt(root.BlockMask))
                return false;
        }
        return true;
    }

    fn bitset_container_equals(c1: Container, c2: Container) bool {
        if (c1.data.cardinality != C.BITSET_UNKNOWN_CARDINALITY and
            c2.data.cardinality != C.BITSET_UNKNOWN_CARDINALITY)
        {
            if (c1.data.cardinality != c2.data.cardinality) return false;
            if (c1.data.cardinality == C.MAX_KEY_CARDINALITY) return true;
        }
        // TODO if(C.HAS_AVX512) ...
        return if (C.HAS_AVX2)
            _avx2_bitset_container_equals(c1, c2)
        else
            misc.memequals(
                @ptrCast(c1.blocks_as(.bitset)),
                @ptrCast(c2.blocks_as(.bitset)),
                C.BITSET_CONTAINER_SIZE_IN_WORDS * @sizeOf(u64),
            );
    }

    fn run_container_equals_bitset(c1: Container, c2: Container) bool {
        const run_card = run_container_cardinality(c1, c1.blocks_as(.run));
        const bitset_card = if (c2.data.cardinality != C.BITSET_UNKNOWN_CARDINALITY)
            c2.data.cardinality
        else
            bitset_container_compute_cardinality(c2.blocks_as(.bitset));
        if (bitset_card != run_card)
            return false;

        const runs = c1.blocks_as(.run)[0..c1.data.cardinality];
        for (runs) |run| {
            const begin: u32 = run.value;
            if (run.length != 0) {
                const end = begin + run.length + 1;
                if (!c2.bitset_container_get_range(begin, end))
                    return false;
            } else {
                if (!c2.bitset_container_contains(@truncate(begin)))
                    return false;
            }
        }
        return true;
    }

    fn array_container_equals_bitset(c1: Container, c2: Container) bool {
        if (c2.data.cardinality != C.BITSET_UNKNOWN_CARDINALITY and
            c2.data.cardinality != c1.data.cardinality)
            return false;

        const array = c1.blocks_as(.array)[0..c1.data.cardinality];
        const words = c2.blocks_as(.bitset)[0..C.BITSET_CONTAINER_SIZE_IN_WORDS];
        var pos: u32 = 0;
        for (words, 0..) |word, i| {
            var w = word;
            while (w != 0) {
                const t = w & -%w;
                const r: u16 = @intCast(i * 64 + @ctz(w));
                if (pos >= c1.data.cardinality) return false;
                if (array[pos] != r) return false;
                pos += 1;
                w ^= t;
            }
        }
        return pos == c1.data.cardinality;
    }

    fn run_container_equals_array(c1: Container, c2: Container) bool {
        const runs = c1.blocks_as(.run);
        if (run_container_cardinality(c1, runs) != c2.data.cardinality)
            return false;
        const array = c2.blocks_as(.array)[0..c2.data.cardinality];
        var pos: u32 = 0;
        for (runs[0..c1.data.cardinality]) |run| {
            const run_start: u32 = run.value;
            const le = run.length;
            if (array[pos] != run_start) return false;
            if (array[pos + le] != run_start + le) return false;
            pos += le + 1;
        }
        return true;
    }

    fn array_container_equals(c1: Container, c2: Container) bool {
        if (c1.data.cardinality != c2.data.cardinality)
            return false;
        return misc.memequals(
            @ptrCast(c1.data.blocks),
            @ptrCast(c2.data.blocks),
            c1.data.cardinality * @sizeOf(u16),
        );
    }

    fn run_container_equals(c1: Container, c2: Container) bool {
        if (c1.data.cardinality != c2.data.cardinality)
            return false;
        return misc.memequals(
            @ptrCast(c1.data.blocks),
            @ptrCast(c2.data.blocks),
            c1.data.cardinality * @sizeOf(Rle16),
        );
    }

    pub fn equals(c1: Container, c2: Container) bool {
        return switch (misc.pair(c1.data.typecode, c2.data.typecode)) { // zig fmt: off
misc.pair(.bitset, .bitset) =>       bitset_container_equals(c1, c2),
misc.pair(.array,  .array) =>         array_container_equals(c1, c2),
misc.pair(.run,    .run) =>             run_container_equals(c1, c2),
misc.pair(.bitset, .run) =>      run_container_equals_bitset(c2, c1),
misc.pair(.run,    .bitset) =>   run_container_equals_bitset(c1, c2),
misc.pair(.bitset, .array) =>  array_container_equals_bitset(c2, c1),
misc.pair(.array,  .bitset) => array_container_equals_bitset(c1, c2),
misc.pair(.array,  .run) =>       run_container_equals_array(c2, c1),
misc.pair(.run,    .array) =>     run_container_equals_array(c1, c2), // zig fmt: on
            else => unreachable,
        };
    }

    pub fn compute_cardinality(v: Container) Cardinality {
        if (v.is_uninit()) return 0;
        return switch (v.data.typecode) {
            .bitset => bitset_container_compute_cardinality(v.blocks_as(.bitset)),
            .array => v.data.cardinality,
            .run => run_container_cardinality(v, v.blocks_as(.run)),
            .shared => unreachable,
        };
    }

    pub fn internal_validate(v: Container, reason: *?[]const u8) bool {
        if (!(@import("builtin").is_test or @import("builtin").mode == .Debug))
            return;
        if (v.is_uninit()) return true; // FIXME
        if (v.data.cardinality == 0) {
            reason.* = "container is empty";
            return false;
        }

        // Not using container_unwrap_shared because it asserts if shared containers
        // are nested
        switch (v.data.typecode) {
            .shared => {
                unreachable; // TODO
                // const shared_container_t *shared_container =
                //     const_CAST_shared(container);
                // if (croaring_refcount_get(&shared_container.counter) == 0) {
                //     reason.* = "shared container has zero refcount";
                //     return false;
                // }
                // if (shared_container.data.typecode == shared) {
                //     reason.* = "shared container is nested";
                //     return false;
                // }
                // if (shared_container.container.is_null()) {
                //     reason.* = "shared container has NULL container";
                //     return false;
                // }
                // container = shared_container.container;
                // typecode = shared_container.data.typecode;
            },
            .bitset => {
                if (v.data.cardinality != C.BITSET_UNKNOWN_CARDINALITY) {
                    if (!(0 < v.data.cardinality and v.data.cardinality <= C.MAX_KEY_CARDINALITY)) { // <= 65536
                        reason.* = "bitset cardinality";
                        return false;
                    }
                    const cc = v.compute_cardinality();
                    if (v.data.cardinality != cc) {
                        trace(@src(), "{} != {}", .{ v.data.cardinality, cc });
                        reason.* = "bitset cardinality is incorrect";
                        return false;
                    }
                    if (v.data.cardinality <= C.DEFAULT_MAX_SIZE) {
                        reason.* = "cardinality is too small for a bitset container";
                        return false;
                    }
                }

                // Attempt to forcibly load the first and last words, hopefully causing
                // a segfault or an address sanitizer error if words is not allocated.
                mem.doNotOptimizeAway(v.data.blocks[0]);
                mem.doNotOptimizeAway(v.data.blocks[C.BITSET_BLOCKS - 1]);
                return true;
            },
            .array => {
                if (!(v.data.cardinality <= v.data.blocks_cap * C.BLOCK_LEN16)) {
                    reason.* = "array cardinality";
                    return false;
                }
                if (v.data.cardinality > C.DEFAULT_MAX_SIZE) {
                    reason.* = "cardinality exceeds DEFAULT_MAX_SIZE";
                    return false;
                }
                if (v.data.cardinality == 0) {
                    reason.* = "zero cardinality";
                    return false;
                }

                const array = v.blocks_as(.array);
                var prev = array[0];
                for (1..v.data.cardinality) |i| {
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
                if (v.data.cardinality < 0) {
                    reason.* = "negative run count";
                    return false;
                }
                if (v.calc_capacity() < v.data.cardinality) {
                    reason.* = "capacity less than run count";
                    return false;
                }

                if (v.data.cardinality == 0) {
                    reason.* = "zero run count";
                    return false;
                }

                // Use u32 to avoid overflow issues on ranges that contain UINT16_MAX.
                var last_end: u32 = 0;
                for (v.blocks_as(.run)[0..v.data.cardinality]) |run| {
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
    pub fn add_run(rc: *Container, s: u16, e: u16) void {
        const runs = rc.blocks_as(.run);
        runs[rc.data.cardinality].value = s;
        runs[rc.data.cardinality].length = e - s;
        rc.data.cardinality += 1;
    }

    /// Get the value of the ith bit.
    pub fn bitset_container_get(words: [*]align(C.BLOCK_ALIGN) root.Word, pos: u16) bool {
        const word = words[pos >> 6];
        return (word >> @truncate(pos & 63)) & 1 != 0;
    }

    /// Returns the index of x , if not exsist return -1
    pub fn bitset_container_get_index(container: Container, x: u16) i32 {
        const words = container.blocks_as(.bitset);
        if (bitset_container_get(words, x)) {
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
    pub fn array_container_get_index(arr: Container, x: u16) i32 {
        const array = arr.blocks_as(.array)[0..arr.data.cardinality];
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

    pub fn run_container_get_index(container: Container, x: u16) i32 {
        const runs = container.blocks_as(.run)[0..container.data.cardinality];
        if (run_container_contains(runs, x)) {
            var sum: i32 = 0;
            const x32: u32 = x;
            for (0..container.data.cardinality) |i| {
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
    pub fn get_index(c: Container, x: u16) i32 {
        // c = c.container_unwrap_shared(); // TODO
        return switch (c.data.typecode) {
            .bitset => c.bitset_container_get_index(x),
            .array => c.array_container_get_index(x),
            .run => c.run_container_get_index(x),
            .shared => unreachable,
        };
    }

    fn bitset_container_contains(c: Container, val: u16) bool {
        return bitset_container_get(c.blocks_as(.bitset), val);
    }

    /// Check whether a value is in a container
    pub fn contains(c: Container, val: u16) bool {
        // c = c.container_unwrap_shared(); // TODO
        return switch (c.data.typecode) {
            .bitset => c.bitset_container_contains(val),
            .array => misc.binarySearchFallbackLinear(c.blocks_as(.array)[0..c.data.cardinality], val) >= 0,
            .run => run_container_contains(c.blocks_as(.run)[0..c.data.cardinality], val),
            .shared => unreachable,
        };
    }

    pub const fmt = Fmt.init;
    pub const fmtLong = Fmt.initLong;
    pub const Fmt = struct {
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
            if (c.is_uninit()) {
                try w.writeAll("uninit");
                return;
            }
            const hi = @as(u32, f.key) << 16;
            const unknown = "unknown";

            switch (c.data.typecode) {
                .array => {
                    try w.print("{t: <6} #:{: <7} {s: <7}: ", .{ c.data.typecode, c.get_cardinality(), "" });
                    const vals0 = c.blocks_as(.array)[0..c.data.cardinality];
                    const vals = if (c.data.cardinality <= vals0.len) vals0[0..c.data.cardinality] else &.{};
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
                    try w.print("{t: <6} #:{: <7} n:{: <5}: ", .{ c.data.typecode, c.get_cardinality(), c.data.cardinality });
                    const vals0 = c.blocks_as(.run)[0..c.data.cardinality];
                    const vals = if (c.data.cardinality <= vals0.len) vals0[0..c.data.cardinality] else &.{};
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
                    if (c.data.cardinality == C.BITSET_UNKNOWN_CARDINALITY)
                        try w.print("{t: <6} #:{s: <7}", .{ c.data.typecode, unknown })
                    else
                        try w.print("{t: <6} #:{: <7}", .{ c.data.typecode, c.get_cardinality() });
                },
                .shared => {
                    try w.writeAll("TODO: shared");
                },
            }
        }
        pub fn init(c: Container, key: u16) Fmt {
            return .{ .c = c, .key = key, .mode = .short };
        }
        pub fn initLong(c: Container, key: u16) Fmt {
            return .{ .c = c, .key = key, .mode = .long };
        }
    };

    /// returns bytes saved by shrinking c.
    ///
    /// does not move blocks. modifies c if it has extra blocks to minimum
    /// blocks needed or deinit when cardinality is 0.
    pub fn shrink_to_fit(c: *Container, allocator: mem.Allocator) !usize {
        const blocksneeded = switch (c.data.typecode) {
            .bitset => return 0, // no shrinking possible
            .array => misc.numGroupsOfSize(c.data.cardinality, C.BLOCK_LEN16),
            .run => misc.numGroupsOfSize(c.data.cardinality, C.BLOCK_LEN32),
            .shared => unreachable,
        };
        const cblocks = c.data.blocks_cap;
        if (c.data.cardinality == 0) {
            c.deinit(allocator);
            return cblocks * C.BLOCK_SIZE;
        } else if (blocksneeded < c.data.blocks_cap) {
            try c.realloc_container(allocator, c.data.typecode, c.data.cardinality, @intCast(blocksneeded));
        }
        return (cblocks - c.data.blocks_cap) * C.BLOCK_SIZE;
    }

    /// total number of elements an array or run container can hold given its
    /// allocated number of blocks.
    pub fn calc_capacity(c: Container) u32 {
        return @as(u32, c.data.blocks_cap) *
            @as(u32, switch (c.data.typecode) {
                .array => C.BLOCK_LEN16,
                .run => C.BLOCK_LEN32,
                .bitset => unreachable,
                .shared => unreachable,
            });
    }

    pub fn array_container_create_given_capacity(allocator: Allocator, capacity: u32) !Container {
        const numblocks = misc.numGroupsOfSize(capacity * @sizeOf(u16), C.BLOCK_SIZE);
        return try create(allocator, .array, 0, @intCast(numblocks));
    }

    pub fn run_container_create_given_capacity(
        allocator: Allocator,
        nruns_capacity: u32,
    ) !Container {
        const numblocks =
            misc.numGroupsOfSize(nruns_capacity * @sizeOf(root.Rle16), C.BLOCK_SIZE);
        return try create(allocator, .run, 0, @intCast(numblocks));
    }

    pub fn bitset_container_clear(bc: Container) void {
        @memset(bc.data.blocks[0..C.BITSET_BLOCKS], @splat(0));
    }

    pub fn bitset_container_create_noinit(allocator: Allocator) !Container {
        return try create(allocator, .bitset, 0, C.BITSET_BLOCKS);
    }

    pub fn bitset_container_create(allocator: Allocator) !Container {
        const bc = try bitset_container_create_noinit(allocator);
        bitset_container_clear(bc);
        return bc;
    }

    /// Check whether this bitset is empty,
    pub fn bitset_container_empty(bitset: Container) bool {
        return if (bitset.data.cardinality == C.BITSET_UNKNOWN_CARDINALITY)
            for (bitset.blocks_as(.bitset)[0..C.BITSET_CONTAINER_SIZE_IN_WORDS]) |word| {
                if (word != 0) break false;
            } else true
        else
            bitset.data.cardinality == 0;
    }

    /// Checks whether a container is not empty, requires a  typecode
    pub fn nonzero_cardinality(c: Container) bool {
        // TODO // c = c.container_unwrap_shared();
        return !c.is_uninit() and switch (c.data.typecode) {
            .bitset => !c.bitset_container_empty(),
            .array, .run => c.data.cardinality != 0,
            else => unreachable,
        };
    }

    /// Remove `pos' from `bitset'. Returns true if `pos' was present.  Might be
    /// slower than bitset_container_unset.
    fn bitset_container_remove(bitset: Container, pos: u16) bool {
        const words = bitset.blocks_as(.bitset);
        const old_word = words[pos >> 6];
        const index: u6 = @truncate(pos & 63);
        const new_word = old_word & (~(@as(u64, 1) << index));
        const increment = (old_word ^ new_word) >> index;
        bitset.data.cardinality -= @intCast(increment);
        words[pos >> 6] = new_word;
        return increment > 0;
    }

    /// Remove x from the set. Returns true if x was present.
    fn array_container_remove(arr: Container, pos: u16) bool {
        const array = arr.blocks_as(.array)[0..arr.data.cardinality];
        const idx = misc.binarySearch(array, pos);
        const is_present = idx >= 0;
        if (is_present) {
            const idxu: u32 = @bitCast(idx);
            @memmove(array.ptr + idxu, (array.ptr + idxu + 1)[0 .. arr.data.cardinality - idxu - 1]);
            arr.data.cardinality -= 1;
        }

        return is_present;
    }

    /// Remove `pos' from `run'. Returns true if `pos' was present.
    fn run_container_remove(run: *Container, allocator: Allocator, pos: u16) !bool {
        const runs = run.blocks_as(.run)[0..run.data.cardinality];
        var mindex = misc.interleavedBinarySearch(runs, pos);
        if (mindex >= 0) {
            const indexu: u32 = @bitCast(mindex);
            if (runs[indexu].length == 0) {
                run.recoverRoomAtIndex(@intCast(indexu));
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
                try run.makeRoomAtIndex(allocator, @intCast(mindex + 1));
                const runs2 = run.blocks_as(.run);
                runs2[index].length = @intCast(offset - 1);
                runs2[index + 1] = .{
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

    pub fn array_container_from_bitset(bc: Container, allocator: Allocator) !Container {
        const card = bc.data.cardinality;
        if (card == 0)
            return uninit;

        var result = try array_container_create_given_capacity(allocator, card);
        result.data.cardinality = card;
        // TODO avx512 version?
        // sse version ends up being slower here because of the sparsity of the data
        assert(card == bitset_extract_setbits_uint16(
            @ptrCast(bc.data.blocks),
            result.blocks_as(.array)[0..card],
            0,
        ));
        return result;
    }

    fn array_number_of_runs(c: Container) u32 {
        // Can SIMD work here?
        var nr_runs: u32 = 0;
        var prev: i32 = -2;
        const start: [*]u16 = @ptrCast(c.data.blocks);
        var p = start;
        const card = c.data.cardinality;
        while (p != start + card) : (p += 1) {
            if (p[0] != prev + 1) nr_runs += 1;
            prev = p[0];
        }
        return nr_runs;
    }

    /// convert containers to and from runcontainers, as is most space efficient.
    /// once converted, the original container is disposed here.
    ///
    // TODO: split into run- array- and bitset- subfunctions for sanity;
    // a few function calls won't really matter.
    pub fn convert_run_optimize(cp: *Container, allocator: Allocator) !Container {
        const c = cp.*;
        if (c.data.typecode == .run) {
            const newc = try c.convert_run_to_efficient_container(allocator);
            if (newc.data != c.data)
                deinit(cp, allocator);
            return newc;
        } else if (c.data.typecode == .array) {
            // it might need to be converted to a run container.
            const nruns = c.array_number_of_runs();
            const nrunblocks = misc.numGroupsOfSize(nruns * @sizeOf(root.Rle16), C.BLOCK_SIZE);
            const size_as_run_container = run_container_serialized_size_in_bytes(nruns);
            const size_as_array_container = c.data.cardinality * @sizeOf(u16);
            trace(@src(), "array. arraysize={} runsize={}", .{ size_as_array_container, size_as_run_container });
            if (size_as_array_container <= size_as_run_container)
                return c;
            // convert array to run container
            var prev: i32 = -2;
            var run_start: i32 = -1;
            const card = c.data.cardinality;
            var rc = try create(allocator, .run, 0, @intCast(nrunblocks));
            errdefer rc.destroy(allocator);
            assert(card > 0);
            const array = c.blocks_as(.array)[0..c.data.cardinality];
            var i: u32 = 0;
            while (i < card) : (i += 1) {
                const cur_val = array[i];
                if (cur_val != prev + 1) {
                    // new run starts; flush old one, if any
                    if (run_start != -1) rc.add_run(@intCast(run_start), @intCast(prev));
                    run_start = cur_val;
                }
                prev = array[i];
            }
            assert(run_start >= 0);
            // now prev is the last seen value
            rc.add_run(@intCast(run_start), @intCast(prev));
            deinit(cp, allocator);
            return rc;
        } else if (c.data.typecode == .bitset) { // run conversions on bitset
            // does bitset need conversion to run?
            const nruns = bitset_container_number_of_runs(c.blocks_as(.bitset));
            const size_as_run_container = run_container_serialized_size_in_bytes(nruns);
            if (size_as_run_container >= @sizeOf(root.Bitset)) // no conversion needed.
                return c;

            // bitset to runcontainer (ported from Java RunContainer(BitmapContainer bc, int nbrRuns))
            assert(nruns > 0); // no empty bitmaps
            var answer = try run_container_create_given_capacity(allocator, nruns);

            const words = c.blocks_as(.bitset);
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
                    deinit(cp, allocator);
                    return answer;
                }

                const local_run_start = @ctz(cur_word);
                const run_start = local_run_start + 64 * long_ctr;
                var cur_word_with_1s = cur_word | (cur_word - 1);

                var run_end: u32 = 0;
                while (cur_word_with_1s == math.maxInt(u64) and
                    long_ctr < C.BITSET_CONTAINER_SIZE_IN_WORDS - 1)
                {
                    long_ctr += 1;
                    cur_word_with_1s = words[long_ctr];
                }

                if (cur_word_with_1s == math.maxInt(u64)) {
                    run_end = 64 + long_ctr * 64; // exclusive, I guess
                    answer.add_run(@intCast(run_start), @intCast(run_end - 1));
                    deinit(cp, allocator);
                    return answer;
                }
                const local_run_end = @ctz(~cur_word_with_1s);
                run_end = local_run_end + long_ctr * 64;
                answer.add_run(@intCast(run_start), @intCast(run_end - 1));
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
    pub fn remove(c: *Container, allocator: Allocator, val: u16) !Container {
        trace(@src(), "{}", .{val});
        // TODO // c = get_writable_copy_if_shared(c, &typecode);
        switch (c.data.typecode) {
            .bitset => {
                if (c.bitset_container_remove(val)) {
                    if (c.data.cardinality <= C.DEFAULT_MAX_SIZE) {
                        return try c.array_container_from_bitset(allocator);
                    }
                }
            },
            .array => {
                _ = c.array_container_remove(val);
            },
            .run => {
                // per Java, no container type adjustments are done (revisit?)
                _ = try c.run_container_remove(allocator, val);
            },
            else => unreachable,
        }
        return c.*;
    }

    /// Simple CSA over Block
    fn CSA(h: *u8x32, l: *u8x32, a: u8x32, b: u8x32, c: u8x32) void {
        const u = a ^ b;
        h.* = (a & b) | (u & c);
        l.* = u ^ c;
    }

    const u8x32 = root.u8x32;
    const u64x4 = root.u64x4;
    fn popcount256(v: u8x32) u64x4 {
        const lookuppos: u8x32 = .{
            4 + 0, 4 + 1, 4 + 1, 4 + 2, 4 + 1, 4 + 2, 4 + 2, 4 + 3,
            4 + 1, 4 + 2, 4 + 2, 4 + 3, 4 + 2, 4 + 3, 4 + 3, 4 + 4,
            4 + 0, 4 + 1, 4 + 1, 4 + 2, 4 + 1, 4 + 2, 4 + 2, 4 + 3,
            4 + 1, 4 + 2, 4 + 2, 4 + 3, 4 + 2, 4 + 3, 4 + 3, 4 + 4,
        };

        const lookupneg: u8x32 = .{
            4 - 0, 4 - 1, 4 - 1, 4 - 2, 4 - 1, 4 - 2, 4 - 2, 4 - 3,
            4 - 1, 4 - 2, 4 - 2, 4 - 3, 4 - 2, 4 - 3, 4 - 3, 4 - 4,
            4 - 0, 4 - 1, 4 - 1, 4 - 2, 4 - 1, 4 - 2, 4 - 2, 4 - 3,
            4 - 1, 4 - 2, 4 - 2, 4 - 3, 4 - 2, 4 - 3, 4 - 3, 4 - 4,
        };

        const low_mask: u8x32 = @splat(0x0f);
        const shift_amt: u8x32 = @splat(4);
        const lo = v & low_mask;
        const hi = (v >> shift_amt) & low_mask;
        const popcnt1 = misc.pshufb(lookuppos, lo);
        const popcnt2 = misc.pshufb(lookupneg, hi);
        const sad_result = misc.psadbw(popcnt1, popcnt2);
        return @bitCast(sad_result);
    }

    /// Fast Harley-Seal AVX population count function
    fn avx2_harley_seal_popcount(data: []root.u8x32) u64 {
        var total: u64x4 = @splat(0);
        var ones: u8x32 = @splat(0);
        var twos: u8x32 = @splat(0);
        var fours: u8x32 = @splat(0);
        var eights: u8x32 = @splat(0);
        var sixteens: u8x32 = @splat(0);
        var twosA: u8x32 = undefined;
        var twosB: u8x32 = undefined;
        var foursA: u8x32 = undefined;
        var foursB: u8x32 = undefined;
        var eightsA: u8x32 = undefined;
        var eightsB: u8x32 = undefined;
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

    pub const ReduceOp = enum { And, Or, Xor, AndNot };
    fn op_methods(comptime op: ReduceOp) type {
        return struct {
            fn bitset_container_op(
                src1: [*]align(C.BLOCK_ALIGN) const u64,
                src2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: *Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) Cardinality {
                dstc.data.cardinality = @intCast(if (C.HAS_AVX2)
                    avx2_harley_seal_popcount_op_store(
                        @ptrCast(src1),
                        @ptrCast(src2),
                        @ptrCast(dst),
                        C.BITSET_BLOCKS,
                    )
                else
                    _scalar_bitset_container_op(src1, src2, dstc, dst));
                return dstc.data.cardinality;
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
                dst.data.cardinality = sum;
                return sum;
            }

            fn bitset_container_op_nocard(
                src1: [*]align(C.BLOCK_ALIGN) const u64,
                src2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: Container,
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
                data1: [*]const u8x32,
                data2: [*]const u8x32,
                size: u64,
            ) u64 {
                var total: u64x4 = @splat(0);
                var ones: u8x32 = @splat(0);
                var twos: u8x32 = @splat(0);
                var fours: u8x32 = @splat(0);
                var eights: u8x32 = @splat(0);
                var sixteens: u8x32 = @splat(0);
                var twosA: u8x32 = undefined;
                var twosB: u8x32 = undefined;
                var foursA: u8x32 = undefined;
                var foursB: u8x32 = undefined;
                var eightsA: u8x32 = undefined;
                var eightsB: u8x32 = undefined;
                var A1: u8x32 = undefined;
                var A2: u8x32 = undefined;
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
                data1: [*]const u8x32,
                data2: [*]const u8x32,
                out: [*]u8x32,
                size: u64,
            ) u64 {
                var total: u64x4 = @splat(0);
                var ones: u8x32 = @splat(0);
                var twos: u8x32 = @splat(0);
                var fours: u8x32 = @splat(0);
                var eights: u8x32 = @splat(0);
                var sixteens: u8x32 = @splat(0);
                var twosA: u8x32 = undefined;
                var twosB: u8x32 = undefined;
                var foursA: u8x32 = undefined;
                var foursB: u8x32 = undefined;
                var eightsA: u8x32 = undefined;
                var eightsB: u8x32 = undefined;
                var A1: u8x32 = undefined;
                var A2: u8x32 = undefined;
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
                dstc: Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) Cardinality {
                for (0..C.BITSET_CONTAINER_SIZE_IN_WORDS) |i| {
                    dst[i] = avx_intrinsic(words1[i], words2[i]);
                }
                dstc.data.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
                return dstc.data.cardinality;
            }

            fn _avx2_bitset_container_op_nocard(
                words1: [*]align(C.BLOCK_ALIGN) const u64,
                words2: [*]align(C.BLOCK_ALIGN) const u64,
                dstc: Container,
                dst: [*]align(C.BLOCK_ALIGN) u64,
            ) Cardinality {
                const innerloop = 8;
                var blocks1: [*]const u64x4 = @ptrCast(words1);
                var blocks2: [*]const u64x4 = @ptrCast(words2);
                var blocksout: [*]u64x4 = @ptrCast(dst);
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
                dstc.data.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
                return dstc.data.cardinality;
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
        dstc: Container,
        dst: [*]align(C.BLOCK_ALIGN) u64,
    ) Cardinality {
        return op_methods(.And).bitset_container_op_nocard(data1, data2, dstc, dst);
    }

    /// Compute the intersection between src1 and src2 and write the result
    /// to dst. If the return function is true, the result is a bitset_container_t
    /// otherwise is a array_container_t.
    fn bitset_bitset_container_intersection(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        const newCardinality = bitset_container_and_justcard(
            src1.blocks_as(.bitset),
            src2.blocks_as(.bitset),
        );
        if (newCardinality > C.DEFAULT_MAX_SIZE) {
            dst.* = try bitset_container_create_noinit(allocator);
            _ = bitset_container_and_nocard(
                src1.blocks_as(.bitset),
                src2.blocks_as(.bitset),
                dst.*,
                dst.blocks_as(.bitset),
            );
            dst.data.cardinality = newCardinality;
            return;
        }
        if (newCardinality == 0)
            return;
        try dstr.ensure_unused_capacity(allocator, 1);
        dst.* = try array_container_create_given_capacity(allocator, newCardinality);
        dst.data.cardinality = newCardinality;
        _ = bitset_extract_intersection_setbits_uint16(
            src1.blocks_as(.bitset),
            src2.blocks_as(.bitset),
            dst.blocks_as(.array)[0..dst.data.cardinality],
            0,
        );
    }

    /// Same as bitset_bitset_container_intersection except that if the output
    /// is to be a bitset container, then src1 is modified and no allocation
    /// is made. If the output is to be an array container, then caller is
    /// responsible to free the container. In all cases, the result is in dst.
    fn bitset_bitset_container_intersection_inplace(
        src1: Container,
        allocator: Allocator,
        src2: Container,
    ) !Container {
        const src1words = src1.blocks_as(.bitset);
        const src2words = src2.blocks_as(.bitset);
        const newCardinality = bitset_container_and_justcard(src1words, src2words);
        if (newCardinality > C.DEFAULT_MAX_SIZE) {
            _ = bitset_container_and_nocard(src1words, src2words, src1, src1words);
            src1.data.cardinality = newCardinality;
            return src1;
        }
        if (newCardinality == 0) return uninit;
        var ac = try array_container_create_given_capacity(allocator, newCardinality);
        ac.data.cardinality = newCardinality;
        _ = bitset_extract_intersection_setbits_uint16(
            src1.blocks_as(.bitset),
            src2words,
            ac.blocks_as(.array)[0..ac.data.cardinality],
            0,
        );
        return ac;
    }

    /// computes the intersection of array1 and array2 and return the result in dst.
    fn array_container_intersection(
        ac1: Container,
        allocator: Allocator,
        ac2: Container,
        dst: *Container,
    ) !void {
        const card1 = ac1.data.cardinality;
        const card2 = ac2.data.cardinality;
        const min_card = @min(card1, card2);
        const threshold = 64; // subject to tuning
        if (dst.calc_capacity() < min_card) {
            try dst.array_container_grow(allocator, min_card, false);
        }

        if (card1 * threshold < card2) {
            dst.data.cardinality = @intCast(misc.intersect_skewed_uint16(
                ac1.blocks_as(.array)[0..card1],
                ac2.blocks_as(.array)[0..card2],
                dst.blocks_as(.array)[0 .. dst.data.blocks_cap * C.BLOCK_LEN16],
            ));
        } else if (card2 * threshold < card1) {
            dst.data.cardinality = @intCast(misc.intersect_skewed_uint16(
                ac2.blocks_as(.array)[0..card2],
                ac1.blocks_as(.array)[0..card1],
                dst.blocks_as(.array)[0 .. dst.data.blocks_cap * C.BLOCK_LEN16],
            ));
        } else {
            dst.data.cardinality = @intCast(if (C.HAS_AVX2)
                misc.intersect_vector16(
                    ac1.blocks_as(.array)[0..card1],
                    ac2.blocks_as(.array)[0..card2],
                    dst.blocks_as(.array)[0 .. dst.data.blocks_cap * C.BLOCK_LEN16],
                )
            else
                misc.intersect_uint16(
                    ac1.blocks_as(.array)[0..card1],
                    ac2.blocks_as(.array)[0..card2],
                    dst.blocks_as(.array)[0 .. dst.data.blocks_cap * C.BLOCK_LEN16],
                ));
        }

        if (dst.data.cardinality != 0)
            dst.assert_valid();
    }

    /// Copy one container into another. We assume that they are distinct.
    fn array_container_copy(
        src: Container,
        allocator: Allocator,
        dst: *Container,
        srcarray: [*]align(C.BLOCK_ALIGN) const u16,
    ) !void {
        const cardinality = src.data.cardinality;
        if (cardinality > dst.calc_capacity()) {
            try dst.array_container_grow(allocator, cardinality, false);
        }
        dst.data.cardinality = cardinality;
        @memcpy(dst.blocks_as(.array)[0..cardinality], srcarray);
    }

    /// returns the computed intersection of src1 and src2
    fn run_container_intersection(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dstp: *Container,
    ) !void {
        const if1 = run_container_is_full(src1);
        const if2 = run_container_is_full(src2);
        var dst = dstp.*;
        if (if1 or if2) {
            if (if1) {
                try src2.run_container_copy(allocator, dstp, src2.blocks_as(.run));
                return;
            }
            if (if2) {
                try src1.run_container_copy(allocator, dstp, src1.blocks_as(.run));
                return;
            }
        }
        // TODO: this could be a lot more efficient, could use SIMD optimizations
        const neededcapacity = src1.data.cardinality + src2.data.cardinality;
        if (dst.calc_capacity() < neededcapacity) {
            try run_container_grow(dstp, allocator, neededcapacity, false);
            dst = dstp.*;
        }
        dst.data.cardinality = 0;
        var rlepos: u32 = 0;
        var xrlepos: u32 = 0;
        const src1_runs = src1.blocks_as(.run);
        const src2_runs = src2.blocks_as(.run);
        const dst_runs = dst.blocks_as(.run);
        var start: u32 = src1_runs[rlepos].value;
        var end: u32 = start + src1_runs[rlepos].length + 1;
        var xstart: u32 = src2_runs[xrlepos].value;
        var xend: u32 = xstart + src2_runs[xrlepos].length + 1;
        while (rlepos < src1.data.cardinality and xrlepos < src2.data.cardinality) {
            if (end <= xstart) {
                rlepos += 1;
                if (rlepos < src1.data.cardinality) {
                    start = src1_runs[rlepos].value;
                    end = start + src1_runs[rlepos].length + 1;
                }
            } else if (xend <= start) {
                xrlepos += 1;
                if (xrlepos < src2.data.cardinality) {
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
                    if (rlepos < src1.data.cardinality) {
                        start = src1_runs[rlepos].value;
                        end = start + src1_runs[rlepos].length + 1;
                    }
                    if (xrlepos < src2.data.cardinality) {
                        xstart = src2_runs[xrlepos].value;
                        xend = xstart + src2_runs[xrlepos].length + 1;
                    }
                } else if (end < xend) {
                    earliestend = end;
                    rlepos += 1;
                    if (rlepos < src1.data.cardinality) {
                        start = src1_runs[rlepos].value;
                        end = start + src1_runs[rlepos].length + 1;
                    }
                } else { // end > xend
                    earliestend = xend;
                    xrlepos += 1;
                    if (xrlepos < src2.data.cardinality) {
                        xstart = src2_runs[xrlepos].value;
                        xend = xstart + src2_runs[xrlepos].length + 1;
                    }
                }
                dst_runs[dst.data.cardinality].value = @truncate(lateststart);
                dst_runs[dst.data.cardinality].length =
                    @truncate(earliestend - lateststart - 1);
                dst.data.cardinality += 1;
            }
        }
    }

    /// Copy one container into another. We assume that they are distinct.
    fn run_container_copy(
        src: Container,
        allocator: Allocator,
        dst: *Container,
        srcruns: [*]align(C.BLOCK_ALIGN) root.Rle16,
    ) !void {
        const n_runs = src.data.cardinality;
        if (src.data.cardinality > dst.calc_capacity()) {
            try dst.run_container_grow(allocator, n_runs, false);
        }
        dst.data.cardinality = n_runs;
        @memcpy(dst.blocks_as(.run)[0..n_runs], srcruns);
    }

    /// Compute the intersection of src1 and src2 and write the result to dst.
    fn array_bitset_container_intersection(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        if (dst.calc_capacity() < src1.data.cardinality) {
            try dst.array_container_grow(allocator, src1.data.cardinality, false);
        }
        var newcard: Cardinality = 0; // dst could be src1
        const origcard = src1.data.cardinality;
        const src1array = src1.blocks_as(.array);
        const dstarray = dst.blocks_as(.array);
        for (0..origcard) |i| {
            const key = src1array[i];
            // this branchless approach is much faster...
            dstarray[newcard] = key;

            newcard += @intFromBool(bitset_container_get(src2.blocks_as(.bitset), key));
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
        dst.data.cardinality = newcard;
    }

    /// Get the cardinality of `run'. Requires an actual computation.
    fn _avx2_run_container_cardinality(
        run: Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
    ) Cardinality {
        const n_runs = run.data.cardinality;

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
        const n_runs = run.data.cardinality;
        // by initializing with n_runs, we omit counting the +1 for each pair.
        var sum = n_runs;
        for (runs[0..n_runs]) |r| {
            sum += r.length;
        }
        return sum;
    }

    fn run_container_cardinality(
        run: Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
    ) Cardinality {
        // Empirically AVX-512 is not always faster than AVX2
        // TODO _avx512_run_container_cardinality;
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
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        if (run_container_is_full(src1)) {
            if (dst.data != src2.data)
                dst.* = try bitset_container_clone(src2, allocator);
            return;
        }
        var src1runs = src1.blocks_as(.run)[0..src1.data.cardinality];
        var src2words = src2.blocks_as(.bitset);
        var card = run_container_cardinality(src1, src1runs.ptr);
        if (card <= C.DEFAULT_MAX_SIZE) {
            // result can only be an array (assuming that we never make a RunContainer)
            if (card > src2.data.cardinality) {
                card = src2.data.cardinality;
            }
            dst.* = try array_container_create_given_capacity(allocator, card);
            const dstarray = dst.blocks_as(.array);
            src1runs = src1.blocks_as(.run)[0..src1.data.cardinality];
            src2words = src2.blocks_as(.bitset);
            for (0..src1.data.cardinality) |rlepos| {
                const rle = src1runs[rlepos];
                const endofrun = @as(u32, rle.value) + rle.length;
                for (rle.value..endofrun + 1) |runValue| {
                    dstarray[dst.data.cardinality] = @truncate(runValue);
                    dst.data.cardinality += @intFromBool(bitset_container_get(src2words, @truncate(runValue)));
                }
            }
            return;
        }
        if (dst.data == src2.data) { // we attempt in-place
            var start: u32 = 0;
            for (0..src1.data.cardinality) |rlepos| {
                const rle = src1runs[rlepos];
                const end: u32 = rle.value;
                bitset_reset_range(src2words, start, end);
                start = end + rle.length + 1;
            }
            bitset_reset_range(src2words, start, C.MAX_KEY_CARDINALITY);
            dst.data.cardinality = bitset_container_compute_cardinality(dst.blocks_as(.bitset));
            if (src2.data.cardinality <= C.DEFAULT_MAX_SIZE) {
                dst.* = try array_container_from_bitset(src2, allocator);
            }
            return;
        } else { // no inplace
            // we expect the answer to be a bitmap (if we are lucky)
            dst.* = try bitset_container_clone(src2, allocator);
            const dstwords = dst.blocks_as(.bitset);
            src1runs = src1.blocks_as(.run)[0..src1.data.cardinality];
            var start: u32 = 0;
            for (0..src1.data.cardinality) |rlepos| {
                const rle = src1runs[rlepos];
                const end: u32 = rle.value;
                bitset_reset_range(dstwords, start, end);
                start = end + rle.length + 1;
            }
            bitset_reset_range(dstwords, start, C.MAX_KEY_CARDINALITY);
            dst.data.cardinality = bitset_container_compute_cardinality(dstwords);

            if (dst.data.cardinality == 0 or dst.data.cardinality > C.DEFAULT_MAX_SIZE)
                return;

            const answer = try array_container_from_bitset(dst.*, allocator);
            dst.deinit(allocator);
            dst.* = answer;
        }
    }

    /// Compute the intersection of src1 and src2 and write the result to
    /// dst. It is allowed for dst to be equal to src1. We assume that dst is a
    /// valid container.
    fn array_run_container_intersection(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        assert(src1.data.cardinality > 0 and src2.data.cardinality > 0);
        if (run_container_is_full(src2)) {
            if (dst.data != src1.data)
                try src1.array_container_copy(allocator, dst, src1.blocks_as(.array));
            return;
        }
        if (dst.calc_capacity() < src1.data.cardinality) {
            try dst.array_container_grow(allocator, src1.data.cardinality, false);
        }
        if (src2.data.cardinality == 0)
            return;

        var rlepos: u32 = 0;
        var arraypos: u32 = 0;
        const src2runs = src2.blocks_as(.run);
        var rle = src2runs[rlepos];
        var newcard: Cardinality = 0;
        const src1array = src1.blocks_as(.array);
        const dstarray = dst.blocks_as(.array);
        while (arraypos < src1.data.cardinality) {
            const arrayval = src1array[arraypos];
            while (rle.value +% rle.length < arrayval) { // this will frequently be false
                rlepos += 1;
                if (rlepos == src2.data.cardinality) {
                    dst.data.cardinality = newcard;
                    return; // we are done
                }
                rle = src2runs[rlepos];
            }
            if (rle.value > arrayval) {
                arraypos = misc.advanceUntil(src1array[0..src1.data.cardinality], arraypos, rle.value);
            } else {
                dstarray[newcard] = arrayval;
                newcard += 1;
                arraypos += 1;
            }
        }
        dst.data.cardinality = newcard;
    }

    /// Converts a run container to either an array or a bitset, IF it saves space.
    ///
    /// If a conversion occurs, the caller is responsible to free the original
    /// container and he becomes responsible to free the new one.
    pub fn convert_run_to_efficient_container(c: Container, allocator: Allocator) !Container {
        assert(c.data.typecode == .run);
        const runsize = c.serialized_size_in_bytes();
        const card = c.compute_cardinality();
        const arraysize = card * @sizeOf(u16);
        const min_size_non_run = @min(@sizeOf(root.Bitset), arraysize);
        if (c.data.cardinality == 0 or runsize <= min_size_non_run) { // no conversion
            return c;
        }
        assert(card != 0);

        if (card <= C.DEFAULT_MAX_SIZE) {
            // to array
            const cnblocks = misc.numGroupsOfSize(card * @sizeOf(u16), C.BLOCK_SIZE);
            const answer = try create(allocator, .array, 0, @intCast(cnblocks));
            errdefer answer.destroy(allocator);
            const array = answer.blocks_as(.array);
            const runs = c.blocks_as(.run);
            for (0..c.data.cardinality) |rlepos| {
                const run_start: u32 = runs[rlepos].value;
                const run_end = run_start + runs[rlepos].length;

                var run_value: u32 = @truncate(run_start);
                while (run_value <= run_end) : (run_value += 1) {
                    array[answer.data.cardinality] = @intCast(run_value);
                    answer.data.cardinality += 1;
                }
            }
            return answer;
        }
        // else to bitset
        var answer = try bitset_container_create(allocator);
        const runs = c.blocks_as(.run)[0..c.data.cardinality];
        for (runs) |r| {
            const start: u32 = r.value;
            const end = start + r.length;
            misc.bitset_set_range(answer.blocks_as(.bitset), start, end + 1);
        }
        answer.data.cardinality = card;
        return answer;
    }

    // like convert_run_to_efficient_container but frees the old result if needed
    fn convert_run_to_efficient_container_and_free(c: *Container, allocator: Allocator) !Container {
        const answer = try c.convert_run_to_efficient_container(allocator);
        if (answer.data != c.data)
            c.deinit(allocator);
        return answer;
    }

    /// Compute intersection between two containers, generate a new container.
    /// This allocates new memory, caller is responsible for deallocation.
    pub fn intersect(
        c1: Container,
        allocator: Allocator,
        c2: Container,
        dstr: *Bitmap,
    ) !Container {
        // TODO // c1 = container_unwrap_shared(c1);
        // TODO // c2 = container_unwrap_shared(c2);

        var result = uninit;
        errdefer deinit(&result, allocator);
        switch (misc.pair(c1.data.typecode, c2.data.typecode)) {
            misc.pair(.bitset, .bitset) => {
                try bitset_bitset_container_intersection(c1, allocator, c2, &result, dstr);
            },
            misc.pair(.array, .array) => {
                try dstr.ensure_unused_capacity(allocator, 1);
                result = try array_container_create_given_capacity(allocator, @min(c1.data.cardinality, c2.data.cardinality));
                try array_container_intersection(c1, allocator, c2, &result);
            },
            misc.pair(.run, .run) => {
                try dstr.ensure_unused_capacity(allocator, 1);
                result = try run_container_create_given_capacity(allocator, c1.data.cardinality + c2.data.cardinality);
                try run_container_intersection(c1, allocator, c2, &result);
                return try convert_run_to_efficient_container_and_free(&result, allocator);
            },
            misc.pair(.bitset, .array) => {
                try dstr.ensure_unused_capacity(allocator, 1);
                result = try array_container_create_given_capacity(allocator, c2.data.cardinality);
                try array_bitset_container_intersection(c2, allocator, c1, &result);
            },
            misc.pair(.array, .bitset) => {
                try dstr.ensure_unused_capacity(allocator, 1);
                result = try array_container_create_given_capacity(allocator, c1.data.cardinality);
                try array_bitset_container_intersection(c1, allocator, c2, &result);
            },
            misc.pair(.bitset, .run) => {
                try run_bitset_container_intersection(c2, allocator, c1, &result);
            },
            misc.pair(.run, .bitset) => {
                try run_bitset_container_intersection(c1, allocator, c2, &result);
            },
            misc.pair(.array, .run) => {
                result = try array_container_create_given_capacity(allocator, c1.data.cardinality);
                try array_run_container_intersection(c1, allocator, c2, &result);
            },
            misc.pair(.run, .array) => {
                result = try array_container_create_given_capacity(allocator, c2.data.cardinality);
                try array_run_container_intersection(c2, allocator, c1, &result);
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
        dstc: Container,
        dst: [*]align(C.BLOCK_ALIGN) u64,
    ) Cardinality {
        return op_methods(.Or).bitset_container_op_nocard(data1, data2, dstc, dst);
    }

    fn bitset_container_or(
        src1: Container,
        src2: Container,
        dst: *Container,
    ) void {
        _ = op_methods(.Or).bitset_container_op(
            src1.blocks_as(.bitset),
            src2.blocks_as(.bitset),
            dst,
            dst.blocks_as(.bitset),
        );
    }

    /// Merge two sorted array containers into one sorted array.
    fn array_container_union(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        const card1 = src1.data.cardinality;
        const card2 = src2.data.cardinality;
        const max_card = card1 + card2;

        if (dst.calc_capacity() < max_card) {
            try dst.array_container_grow(allocator, max_card, false);
        }

        dst.data.cardinality = @intCast(misc.fast_union_uint16(
            src1.blocks_as(.array)[0..card1],
            src2.blocks_as(.array)[0..card2],
            dst.blocks_as(.array),
        ));
    }

    /// Compute the union of two array containers.
    /// Writes result into dst. Returns true if result is a bitset.
    fn array_array_container_union(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        const card1 = src1.data.cardinality;
        const card2 = src2.data.cardinality;
        const totalCardinality = card1 + card2;

        if (totalCardinality <= C.DEFAULT_MAX_SIZE) {
            assert(dst.is_uninit());
            dst.* = try array_container_create_given_capacity(allocator, totalCardinality);
            try array_container_union(src1, allocator, src2, dst);
            return;
        }

        dst.* = try bitset_container_create(allocator);
        const dstwords = dst.blocks_as(.bitset);
        for (src1.blocks_as(.array)[0..card1]) |v|
            dst.bitset_container_set(v, dstwords);
        for (src2.blocks_as(.array)[0..card2]) |v|
            dst.bitset_container_set(v, dstwords);

        if (dst.data.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst.*, allocator);
            dst.deinit(allocator);
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
            runs[run.data.cardinality] = vl;
            run.data.cardinality += 1;
            previousrl.* = vl;
        } else {
            const newend = @as(u32, vl.value) + vl.length + 1;
            if (newend > previousend) { // we merge
                previousrl.length = @truncate(newend - 1 - previousrl.value);
                runs[run.data.cardinality - 1] = previousrl.*;
            }
        }
    }

    /// Like run_container_append but it is assumed that the content of run is empty.
    fn run_container_append_first(
        run: *Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
        vl: root.Rle16,
    ) root.Rle16 {
        runs[run.data.cardinality] = vl;
        run.data.cardinality += 1;
        return vl;
    }

    fn run_container_union(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        const if1 = run_container_is_full(src1);
        const if2 = run_container_is_full(src2);

        if (if1 or if2) {
            if (if1) {
                try src1.run_container_copy(allocator, dst, src1.blocks_as(.run));
                return;
            }
            if (if2) {
                try src2.run_container_copy(allocator, dst, src2.blocks_as(.run));
                return;
            }
        }

        const neededcapacity = src1.data.cardinality + src2.data.cardinality;
        if (dst.calc_capacity() < neededcapacity) {
            try dst.run_container_grow(allocator, neededcapacity, false);
        }

        dst.data.cardinality = 0;
        var rlepos: u32 = 0;
        var xrlepos: u32 = 0;
        const src1runs = src1.blocks_as(.run);
        const src2runs = src2.blocks_as(.run);
        const dstruns = dst.blocks_as(.run);

        var previousrle: root.Rle16 = .{ .value = 0, .length = 0 };
        if (src1runs[rlepos].value <= src2runs[xrlepos].value) {
            previousrle = run_container_append_first(dst, dstruns, src1runs[rlepos]);
            rlepos += 1;
        } else {
            previousrle = run_container_append_first(dst, dstruns, src2runs[xrlepos]);
            xrlepos += 1;
        }

        while (xrlepos < src2.data.cardinality and rlepos < src1.data.cardinality) {
            const newrl = if (src1runs[rlepos].value <= src2runs[xrlepos].value) rl: {
                defer rlepos += 1;
                break :rl src1runs[rlepos];
            } else rl: {
                defer xrlepos += 1;
                break :rl src2runs[xrlepos];
            };
            run_container_append(dst, dstruns, newrl, &previousrle);
        }
        while (xrlepos < src2.data.cardinality) {
            run_container_append(dst, dstruns, src2runs[xrlepos], &previousrle);
            xrlepos += 1;
        }
        while (rlepos < src1.data.cardinality) {
            run_container_append(dst, dstruns, src1runs[rlepos], &previousrle);
            rlepos += 1;
        }
    }

    /// unlike croaring which uses memcpy, src and dst aren't assumed distinct
    /// here.
    ///
    /// Note: memmove is necessary to avoid panics due to aliasing.
    fn bitset_container_copy(dst: *Container, src: Container) void {
        dst.data.cardinality = src.data.cardinality;
        @memmove(dst.data.blocks[0..C.BITSET_BLOCKS], src.data.blocks);
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
        src1: Container,
        src2: Container,
        dst: *Container,
    ) void {
        bitset_container_copy(dst, src2);
        dst.data.cardinality = @intCast(bitset_set_list_withcard(
            dst.blocks_as(.bitset)[0..C.BITSET_CONTAINER_SIZE_IN_WORDS],
            dst.data.cardinality,
            src1.blocks_as(.array)[0..src1.data.cardinality],
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
            runs[run.data.cardinality] = newrle;
            run.data.cardinality += 1;
            previousrl.* = newrle;
        } else if (val == prev_end + 1) {
            previousrl.length += 1;
            runs[run.data.cardinality - 1] = previousrl.*;
        }
    }

    fn run_container_append_value_first(
        run: *Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
        val: u16,
    ) root.Rle16 {
        const newrle = root.Rle16{ .value = val, .length = 0 };
        runs[run.data.cardinality] = newrle;
        run.data.cardinality += 1;
        return newrle;
    }

    fn array_run_container_union(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        if (run_container_is_full(src2)) {
            try run_container_copy(src2, allocator, dst, src2.blocks_as(.run));
            return;
        }

        const card1 = src1.data.cardinality;
        const card2 = src2.data.cardinality;
        if (dst.calc_capacity() < 2 * (card1 + card2))
            try run_container_grow(dst, allocator, 2 * (card1 + card2), false);
        const arr = src1.blocks_as(.array);
        const srcruns = src2.blocks_as(.run);
        const dstruns = dst.blocks_as(.run);
        var rp: u32 = 0;
        var ap: u32 = 0;
        var prev: root.Rle16 = undefined;

        if (srcruns[rp].value <= arr[ap]) {
            prev = run_container_append_first(dst, dstruns, srcruns[rp]);
            rp += 1;
        } else {
            prev = dst.run_container_append_value_first(dstruns, arr[ap]);
            ap += 1;
        }
        while (rp < card2 and ap < card1) {
            if (srcruns[rp].value <= arr[ap]) {
                run_container_append(dst, dstruns, srcruns[rp], &prev);
                rp += 1;
            } else {
                dst.run_container_append_value(dstruns, arr[ap], &prev);
                ap += 1;
            }
        }
        while (ap < card1) {
            dst.run_container_append_value(dstruns, arr[ap], &prev);
            ap += 1;
        }
        while (rp < card2) {
            run_container_append(dst, dstruns, srcruns[rp], &prev);
            rp += 1;
        }
    }

    /// TODO: write smart_append_exclusive version to match the overloaded 1 param
    /// Java version (or  is it even used?)
    ///
    /// follows the Java implementation closely
    /// length is the rle-value.  Ie, run [10,12) uses a length value 1.
    fn run_container_smart_append_exclusive(
        src: Container,
        runs: [*]align(C.BLOCK_ALIGN) root.Rle16,
        start: u16,
        length: u16,
    ) void {
        var old_end: u32 = undefined;
        const last_run = if (src.data.cardinality != 0) runs + (src.data.cardinality - 1) else undefined;
        const appended_last_run = runs + src.data.cardinality;

        if (src.data.cardinality == 0 or
            (start > blk: {
                old_end = @as(u32, last_run[0].value) + last_run[0].length + 1;
                break :blk old_end;
            }))
        {
            appended_last_run[0] = .{ .value = start, .length = length };
            src.data.cardinality += 1;
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
                src.data.cardinality -= 1;
                return;
            }
        }
        last_run[0].length = start - last_run[0].value - 1;
        if (new_end < old_end) {
            appended_last_run[0] = .{
                .value = @intCast(new_end),
                .length = @intCast(old_end - new_end - 1),
            };
            src.data.cardinality += 1;
        } else if (new_end > old_end) {
            appended_last_run[0] = .{
                .value = @intCast(old_end),
                .length = @intCast(new_end - old_end - 1),
            };
            src.data.cardinality += 1;
        }
    }

    fn run_bitset_container_union(
        src1: Container,
        src2: Container,
        dst: *Container,
    ) void {
        assert(!run_container_is_full(src1)); // catch this case upstream
        if (src2.data != dst.data) bitset_container_copy(dst, src2);
        const runs = src1.blocks_as(.run);
        const dwords = dst.blocks_as(.bitset);
        for (runs[0..src1.data.cardinality]) |rle| {
            misc.bitset_set_lenrange(dwords, rle.value, rle.length);
        }
        dst.data.cardinality = @intCast(dst.compute_cardinality());
    }

    pub fn append_first(c: Container, container_value: anytype) void {
        switch (@TypeOf(container_value)) {
            Rle16 => {
                assert(c.data.typecode == .run);
                const runs = c.blocks_as(.run);
                runs[c.data.cardinality] = container_value;
                c.data.cardinality += 1;
            },
            u16 => {
                assert(c.data.typecode == .array);
                const array = c.blocks_as(.array);
                array[c.data.cardinality] = container_value;
                c.data.cardinality += 1;
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
    ) !Container {
        var rc = try run_container_create_given_capacity(allocator, 1);
        rc.append_first(root.Rle16{
            .value = @intCast(start),
            .length = @intCast(stop - start - 1),
        });
        return rc;
    }

    /// Compute the union of src1 and src2 and write the result to src1
    fn run_container_union_inplace(
        src1: *Container,
        allocator: Allocator,
        src2: Container,
    ) !void {
        // TODO: this could be a lot more efficient

        if (src1.data == src2.data)
            return;

        // we start out with inexpensive checks
        const if1 = run_container_is_full(src1.*);
        const if2 = run_container_is_full(src2);
        if (if1 or if2) {
            if (if1) return;
            if (if2) {
                try src2.run_container_copy(allocator, src1, src2.blocks_as(.run));
                return;
            }
        }
        // we move the data to the end of the current array
        const maxoutput: u32 = src1.data.cardinality + src2.data.cardinality;
        const neededcapacity = maxoutput + src1.data.cardinality;
        if (src1.calc_capacity() < neededcapacity) {
            try src1.run_container_grow(allocator, neededcapacity, true);
        }
        const src1runs = src1.blocks_as(.run);
        const inputsrc1 = src1runs + maxoutput;
        @memmove(inputsrc1, src1runs[0..src1.data.cardinality]);
        const input1nruns = src1.data.cardinality;
        src1.data.cardinality = 0;
        var rlepos: u32 = 0;
        var xrlepos: u32 = 0;

        var previousrle: Rle16 = undefined;
        const src2runs = src2.blocks_as(.run);
        if (inputsrc1[rlepos].value <= src2runs[xrlepos].value) {
            previousrle = run_container_append_first(src1, src1runs, inputsrc1[rlepos]);
            rlepos += 1;
        } else {
            previousrle = run_container_append_first(src1, src1runs, src2runs[xrlepos]);
            xrlepos += 1;
        }
        while (xrlepos < src2.data.cardinality and rlepos < input1nruns) {
            var newrl: Rle16 = undefined;
            if (inputsrc1[rlepos].value <= src2runs[xrlepos].value) {
                newrl = inputsrc1[rlepos];
                rlepos += 1;
            } else {
                newrl = src2runs[xrlepos];
                xrlepos += 1;
            }
            run_container_append(src1, src1runs, newrl, &previousrle);
        }
        while (xrlepos < src2.data.cardinality) {
            run_container_append(src1, src1runs, src2runs[xrlepos], &previousrle);
            xrlepos += 1;
        }
        while (rlepos < input1nruns) {
            run_container_append(src1, src1runs, inputsrc1[rlepos], &previousrle);
            rlepos += 1;
        }
    }

    /// Merge src1's array values into src2's runs in place.
    fn array_run_container_inplace_union(
        src1: Container,
        allocator: Allocator,
        src2: *Container,
    ) !void {
        if (run_container_is_full(src2.*)) return;
        const maxoutput = src1.data.cardinality + src2.data.cardinality;
        const neededcapacity = maxoutput + src2.data.cardinality;
        if (src2.calc_capacity() < neededcapacity) {
            try run_container_grow(src2, allocator, neededcapacity, true);
        }
        const src2runs = src2.blocks_as(.run);
        const src1arr = src1.blocks_as(.array);

        const inputsrc2 = src2runs + maxoutput;
        @memmove(inputsrc2, src2runs[0..src2.data.cardinality]);

        var rlepos: u32 = 0;
        var arraypos: u32 = 0;
        const src2nruns = src2.data.cardinality;
        src2.data.cardinality = 0;

        var previousrle: root.Rle16 = undefined;
        if (inputsrc2[rlepos].value <= src1arr[arraypos]) {
            previousrle = run_container_append_first(src2, src2runs, inputsrc2[rlepos]);
            rlepos += 1;
        } else {
            previousrle = run_container_append_value_first(src2, src2runs, src1arr[arraypos]);
            arraypos += 1;
        }

        while (rlepos < src2nruns and arraypos < src1.data.cardinality) {
            if (inputsrc2[rlepos].value <= src1arr[arraypos]) {
                run_container_append(src2, src2runs, inputsrc2[rlepos], &previousrle);
                rlepos += 1;
            } else {
                run_container_append_value(src2, src2runs, src1arr[arraypos], &previousrle);
                arraypos += 1;
            }
        }
        if (arraypos < src1.data.cardinality) {
            while (arraypos < src1.data.cardinality) {
                run_container_append_value(src2, src2runs, src1arr[arraypos], &previousrle);
                arraypos += 1;
            }
        } else {
            while (rlepos < src2nruns) {
                run_container_append(src2, src2runs, inputsrc2[rlepos], &previousrle);
                rlepos += 1;
            }
        }
    }

    fn array_array_container_inplace_union(
        src1: *Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        const totalCardinality = src1.data.cardinality + src2.data.cardinality;
        dst.* = uninit;
        var src1array = src1.blocks_as(.array)[0..src1.data.cardinality];
        var src2array = src2.blocks_as(.array)[0..src2.data.cardinality];
        if (totalCardinality <= C.DEFAULT_MAX_SIZE) {
            if (src1.calc_capacity() < totalCardinality) {
                dst.* = try array_container_create_given_capacity(
                    allocator,
                    @min(C.DEFAULT_MAX_SIZE, 2 * totalCardinality), // be purposefully generous
                );
                errdefer dst.deinit(allocator);
                try src1.array_container_union(allocator, src2, dst);
                return;
            } else {
                @memmove(src1array.ptr + src2.data.cardinality, src1array);
                // In theory, we could use fast_union_uint16, but it is unsafe. It
                // fails with Intel compilers in particular.
                // https://github.com/RoaringBitmap/CRoaring/pull/452
                // See report https://github.com/RoaringBitmap/CRoaring/issues/476
                src1array.len = src1.calc_capacity();
                src1.data.cardinality = @intCast(misc.union_uint16(
                    src1array[src2.data.cardinality..][0..src1.data.cardinality],
                    src2array,
                    src1array.ptr,
                ));
                return;
            }
        }

        dst.* = try bitset_container_create(allocator);
        const dstc = dst.*;
        {
            const dstcopywords = dstc.blocks_as(.bitset);
            src2array = src2.blocks_as(.array)[0..src2.data.cardinality];
            misc.bitset_set_list(dstcopywords, src1.blocks_as(.array)[0..src1.data.cardinality]);
            dstc.data.cardinality = @intCast(bitset_set_list_withcard(
                dstcopywords[0..C.BITSET_CONTAINER_SIZE_IN_WORDS],
                src1.data.cardinality,
                src2array,
            ));
        }

        if (dstc.data.cardinality <= C.DEFAULT_MAX_SIZE) {
            // need to convert!
            if (src1.calc_capacity() < dstc.data.cardinality) {
                try src1.array_container_grow(allocator, dstc.data.cardinality, false);
            }
            src1array = src1.blocks_as(.array)[0 .. src1.data.blocks_cap * C.BLOCK_LEN16];
            const dstcopywords = dstc.blocks_as(.bitset);
            _ = bitset_extract_setbits_uint16(dstcopywords, src1array, 0);
            src1.data.cardinality = dstc.data.cardinality;
            dst.deinit(allocator);
            dst.data = src1.data;
        }
    }

    /// In-place union. Modifies c1 when possible, otherwise allocates new
    /// container in x1. Returns the resulting container. Caller owns returned
    /// allocation.
    pub fn ior(
        c1: *Container,
        allocator: Allocator,
        c2: Container,
    ) !Container {
        // TODO // c1 = get_writable_copy_if_shared(c1);
        // TODO // c2 = container_unwrap_shared(c2);
        // trace(@src(), "{t} {t}", .{ c1.data.typecode, c2.data.typecode });
        var result = uninit;
        errdefer result.deinit(allocator);
        switch (misc.pair(c1.data.typecode, c2.data.typecode)) {
            misc.pair(.bitset, .bitset) => {
                bitset_container_or(c1.*, c2, c1);
                if (C.OR_BITSET_CONVERSION_TO_FULL and
                    c1.data.cardinality == C.MAX_KEY_CARDINALITY)
                {
                    return try run_container_create_range(allocator, 0, C.MAX_KEY_CARDINALITY);
                }
                return c1.*;
            },
            misc.pair(.array, .array) => {
                try array_array_container_inplace_union(c1, allocator, c2, &result);
                if (result.is_uninit() and c1.data.typecode == .array)
                    return c1.*; // the computation was done in-place!
                return result;
            },
            misc.pair(.run, .run) => {
                try run_container_union_inplace(c1, allocator, c2);
                return try c1.convert_run_to_efficient_container(allocator);
            },
            misc.pair(.bitset, .array) => {
                array_bitset_container_union(c2, c1.*, c1);
                return c1.*;
            },
            misc.pair(.array, .bitset) => {
                // c1 is an array, so no in-place possible
                result = try bitset_container_create_noinit(allocator);
                array_bitset_container_union(c1.*, c2, &result);
                return result;
            },
            misc.pair(.bitset, .run) => {
                if (run_container_is_full(c2)) {
                    result = try run_container_create_given_capacity(allocator, 1);
                    try c2.run_container_copy(allocator, &result, c2.blocks_as(.run));
                    return result;
                }
                run_bitset_container_union(c2, c1.*, c1);
                return c1.*;
            },
            misc.pair(.run, .bitset) => {
                if (run_container_is_full(c1.*)) return c1.*;
                result = try bitset_container_create_noinit(allocator);
                run_bitset_container_union(c1.*, c2, &result);
                return result;
            },
            misc.pair(.array, .run) => {
                result = try run_container_create_given_capacity(allocator, 1);
                try array_run_container_union(c1.*, allocator, c2, &result);
                return try convert_run_to_efficient_container_and_free(&result, allocator);
            },
            misc.pair(.run, .array) => {
                try array_run_container_inplace_union(c2, allocator, c1);
                return try c1.convert_run_to_efficient_container(allocator);
            },
            else => unreachable,
        }
    }

    /// perform an 'or' operation (union) on the container.
    pub fn merge(c1: Container, allocator: Allocator, c2: Container) !Container {
        var result = uninit;
        errdefer result.deinit(allocator);
        switch (misc.pair(c1.data.typecode, c2.data.typecode)) {
            misc.pair(.bitset, .bitset) => {
                result = try bitset_container_create_noinit(allocator);
                bitset_container_or(c1, c2, &result);
            },
            misc.pair(.array, .array) => {
                try array_array_container_union(c1, allocator, c2, &result);
            },
            misc.pair(.run, .run) => {
                result = try run_container_create_given_capacity(allocator, c1.data.cardinality + c2.data.cardinality);
                try run_container_union(c1, allocator, c2, &result);
                return try convert_run_to_efficient_container_and_free(&result, allocator);
            },
            misc.pair(.bitset, .array) => {
                result = try bitset_container_create_noinit(allocator);
                array_bitset_container_union(c2, c1, &result);
            },
            misc.pair(.array, .bitset) => {
                result = try bitset_container_create_noinit(allocator);
                array_bitset_container_union(c1, c2, &result);
            },
            misc.pair(.bitset, .run) => {
                if (run_container_is_full(c2)) {
                    result = try run_container_create_given_capacity(allocator, 1);
                    try run_container_copy(c2, allocator, &result, c2.blocks_as(.run));
                } else {
                    result = try bitset_container_create_noinit(allocator);
                    run_bitset_container_union(c2, c1, &result);
                }
            },
            misc.pair(.run, .bitset) => {
                if (run_container_is_full(c1)) {
                    result = try run_container_create_given_capacity(allocator, 1);
                    try c1.run_container_copy(allocator, &result, c1.blocks_as(.run));
                } else {
                    result = try bitset_container_create_noinit(allocator);
                    run_bitset_container_union(c1, c2, &result);
                }
            },
            misc.pair(.array, .run) => {
                result = try run_container_create_given_capacity(allocator, @max(c1.data.cardinality, c2.data.cardinality));
                try array_run_container_union(c1, allocator, c2, &result);
                return try convert_run_to_efficient_container_and_free(&result, allocator);
            },
            misc.pair(.run, .array) => {
                result = try run_container_create_given_capacity(allocator, @max(c1.data.cardinality, c2.data.cardinality));
                try array_run_container_union(c2, allocator, c1, &result);
                return try convert_run_to_efficient_container_and_free(&result, allocator);
            },
            else => unreachable,
        }
        return result;
    }

    fn bitset_container_xor(
        src1: Container,
        src2: Container,
        dst: *Container,
    ) void {
        _ = op_methods(.Xor).bitset_container_op(
            src1.blocks_as(.bitset),
            src2.blocks_as(.bitset),
            dst,
            dst.blocks_as(.bitset),
        );
    }

    fn bitset_bitset_container_xor(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        dst.* = try bitset_container_create_noinit(allocator);
        bitset_container_xor(src1, src2, dst);
        if (dst.data.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst.*, allocator);
            dst.deinit(allocator);
            dst.* = answer;
        }
    }

    fn array_container_xor(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        const card1 = src1.data.cardinality;
        const card2 = src2.data.cardinality;
        const max_card = card1 + card2;
        if (dst.calc_capacity() < max_card) {
            try dst.array_container_grow(allocator, max_card, false);
        }

        dst.data.cardinality = if (C.HAS_AVX2)
            @intCast(misc.xor_vector16(
                src1.blocks_as(.array)[0..card1],
                src2.blocks_as(.array)[0..card2],
                dst.blocks_as(.array),
            ))
        else
            @intCast(misc.xor_uint16(
                src1.blocks_as(.array)[0..card1],
                src2.blocks_as(.array)[0..card2],
                dst.blocks_as(.array),
            ));
    }

    /// Compute the xor of src1 and src2 and write the result to dst (which
    /// has no container initially).
    fn array_bitset_container_xor(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        assert(dst.is_uninit());
        dst.* = try bitset_container_create_noinit(allocator);
        dst.bitset_container_copy(src2);
        dst.data.cardinality = @intCast(misc.bitset_flip_list_withcard(
            dst.blocks_as(.bitset),
            dst.data.cardinality,
            src1.blocks_as(.array)[0..src1.data.cardinality],
        ));
        if (dst.data.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try dst.array_container_from_bitset(allocator);
            dst.deinit(allocator);
            dst.* = answer;
        }
    }

    fn array_array_container_xor(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        const card1 = src1.data.cardinality;
        const card2 = src2.data.cardinality;
        const totalCardinality = card1 + card2;

        if (totalCardinality <= C.DEFAULT_MAX_SIZE) {
            dst.* = try array_container_create_given_capacity(allocator, totalCardinality);
            try src1.array_container_xor(allocator, src2, dst);
            return;
        }

        dst.* = try bitset_container_from_array_dst(src1, allocator);
        const dstwords = dst.blocks_as(.bitset);
        dst.data.cardinality = @intCast(misc.bitset_flip_list_withcard(
            dstwords,
            dst.data.cardinality,
            src2.blocks_as(.array)[0..card2],
        ));

        if (dst.data.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try dst.array_container_from_bitset(allocator);
            dst.deinit(allocator);
            dst.* = answer;
        }
    }

    /// Compute the xor of src1 and src2 and write the result to dst. Result
    /// may be either a bitset or an array container. dst does not initially
    /// have any container.
    fn run_bitset_container_xor(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        assert(dst.is_uninit());
        dst.* = try bitset_container_create_noinit(allocator);
        bitset_container_copy(dst, src2);
        const runs = src1.blocks_as(.run);
        const dwords = dst.blocks_as(.bitset);
        for (runs[0..src1.data.cardinality]) |rle| {
            misc.bitset_flip_range(dwords, rle.value, @as(u32, rle.value) + rle.length + 1);
        }
        dst.data.cardinality = dst.compute_cardinality();
        if (dst.data.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst.*, allocator);
            dst.deinit(allocator);
            dst.* = answer;
        }
    }

    fn run_run_container_xor(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        dst.* = try run_container_create_given_capacity(allocator, src1.data.cardinality + src2.data.cardinality);
        try run_container_xor(src1, allocator, src2, dst);
        dst.* = try convert_run_to_efficient_container_and_free(dst, allocator);
    }

    /// Compute the symmetric difference of `src1` and `src2` and write the
    /// result to `dst`. It is assumed that `dst` is distinct from both `src1`
    /// and `src2`.
    fn run_container_xor(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dstp: *Container,
    ) !void {
        const nruns1 = src1.data.cardinality;
        const nruns2 = src2.data.cardinality;
        const neededcapacity = nruns1 + nruns2;
        var dst = dstp.*;
        if (dst.calc_capacity() < neededcapacity) {
            try run_container_grow(dstp, allocator, neededcapacity, false);
            dst = dstp.*;
        }
        dst.data.cardinality = 0;

        const src1runs = src1.blocks_as(.run);
        const src2runs = src2.blocks_as(.run);
        const dstruns = dst.blocks_as(.run);

        var pos1: u32 = 0;
        var pos2: u32 = 0;
        while (pos1 < nruns1 and pos2 < nruns2) {
            if (src1runs[pos1].value <= src2runs[pos2].value) {
                run_container_smart_append_exclusive(dst, dstruns, src1runs[pos1].value, src1runs[pos1].length);
                pos1 += 1;
            } else {
                run_container_smart_append_exclusive(dst, dstruns, src2runs[pos2].value, src2runs[pos2].length);
                pos2 += 1;
            }
        }
        while (pos1 < nruns1) {
            run_container_smart_append_exclusive(dst, dstruns, src1runs[pos1].value, src1runs[pos1].length);
            pos1 += 1;
        }
        while (pos2 < nruns2) {
            run_container_smart_append_exclusive(dst, dstruns, src2runs[pos2].value, src2runs[pos2].length);
            pos2 += 1;
        }
    }

    fn array_run_container_lazy_xor(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        if (dst.calc_capacity() < src1.data.cardinality + src2.data.cardinality) {
            try dst.run_container_grow(allocator, src1.data.cardinality + src2.data.cardinality, false);
        }
        dst.data.cardinality = 0;

        const dstruns = dst.blocks_as(.run);
        const src2runs = src2.blocks_as(.run);
        const src1array = src1.blocks_as(.array);
        var rlepos: u32 = 0;
        var arraypos: u32 = 0;
        while (rlepos < src2.data.cardinality and arraypos < src1.data.cardinality) {
            if (src2runs[rlepos].value <= src1array[arraypos]) {
                dst.run_container_smart_append_exclusive(
                    dstruns,
                    src2runs[rlepos].value,
                    src2runs[rlepos].length,
                );
                rlepos += 1;
            } else {
                dst.run_container_smart_append_exclusive(dstruns, src1array[arraypos], 0);
                arraypos += 1;
            }
        }
        while (arraypos < src1.data.cardinality) {
            dst.run_container_smart_append_exclusive(dstruns, src1array[arraypos], 0);
            arraypos += 1;
        }
        while (rlepos < src2.data.cardinality) {
            dst.run_container_smart_append_exclusive(
                dstruns,
                src2runs[rlepos].value,
                src2runs[rlepos].length,
            );
            rlepos += 1;
        }
    }

    fn array_container_from_run(
        run: Container,
        allocator: Allocator,
    ) !Container {
        const runcard = run_container_cardinality(run, run.blocks_as(.run));
        const answer = try array_container_create_given_capacity(allocator, runcard);
        answer.data.cardinality = 0;
        const runs = run.blocks_as(.run);
        const array = answer.blocks_as(.array);
        for (0..run.data.cardinality) |rlepos| {
            const run_start: u32 = runs[rlepos].value;
            const run_end = run_start + runs[rlepos].length;
            for (run_start..run_end + 1) |run_value| {
                array[answer.data.cardinality] = @truncate(run_value);
                answer.data.cardinality += 1;
            }
        }
        return answer;
    }

    fn bitset_container_from_run(run: Container, allocator: Allocator) !Container {
        const runs = run.blocks_as(.run);
        const card = run.run_container_cardinality(runs);
        var answer = try bitset_container_create(allocator);
        const words = answer.blocks_as(.bitset);
        for (run.blocks_as(.run)[0..run.data.cardinality]) |rle| {
            misc.bitset_set_lenrange(words, rle.value, rle.length);
        }
        answer.data.cardinality = card;
        return answer;
    }

    /// Compute the xor of src1 and src2 and write the result to
    /// dst (which has no container initially).  It will modify src1
    /// to be dst if the result is a bitset.  Otherwise, it will
    /// free src1 and dst will be a new array container.  In both
    /// cases, the caller is responsible for deallocating dst.
    fn bitset_array_container_ixor(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        dst.* = try bitset_container_clone(src1, allocator);
        const src2array = src2.blocks_as(.array);
        const d = dst.*;
        d.data.cardinality = @intCast(misc.bitset_flip_list_withcard(
            d.blocks_as(.bitset),
            src1.data.cardinality,
            src2array[0..src2.data.cardinality],
        ));

        if (d.data.cardinality <= C.DEFAULT_MAX_SIZE) {
            const ans = try d.array_container_from_bitset(allocator);
            dst.deinit(allocator);
            dst.* = ans;
        }
    }

    /// dst does not indicate a valid container initially.  Eventually it
    /// can become any kind of container.
    fn array_run_container_xor(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        // semi following Java XOR implementation as of May 2016
        // the C OR implementation works quite differently and can return a run
        // container
        // TODO could optimize for full run containers.

        // use of lazy following Java impl.
        const arbitrary_threshold = 32;
        if (src1.data.cardinality < arbitrary_threshold) {
            var ans = try run_container_create_given_capacity(allocator, src1.data.cardinality + src2.data.cardinality);
            errdefer ans.deinit(allocator);
            try array_run_container_lazy_xor(src1, allocator, src2, &ans); // keeps runs.
            dst.* = try convert_run_to_efficient_container_and_free(&ans, allocator);
            return;
        }

        const card = run_container_cardinality(src2, src2.blocks_as(.run));
        if (card <= C.DEFAULT_MAX_SIZE) {
            // Java implementation works with the array, xoring the run elements via
            // iterator
            var temp = try array_container_from_run(src2, allocator);
            defer temp.deinit(allocator);
            try array_array_container_xor(temp, allocator, src1, dst);
        } else { // guess that it will end up as a bitset
            var result = try bitset_container_from_run(src2, allocator);
            defer result.deinit(allocator);
            try result.bitset_array_container_ixor(allocator, src1, dst);
            // any necessary type conversion has been done by the ixor
        }
    }

    fn bitset_container_andnot(
        src1: Container,
        src2: Container,
        dst: *Container,
    ) u32 {
        return op_methods(.AndNot).bitset_container_op(
            src1.blocks_as(.bitset),
            src2.blocks_as(.bitset),
            dst,
            dst.blocks_as(.bitset),
        );
    }

    /// Compute the andnot of src1 and src2 and write the result to dst.
    /// dst does not initially have any container.
    fn bitset_bitset_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        assert(dst.is_uninit());
        dst.* = try bitset_container_create_noinit(allocator);
        const card = bitset_container_andnot(src1, src2, dst);

        if (card <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst.*, allocator);
            dst.deinit(allocator);
            dst.* = answer;
        }
    }

    /// Computes the difference of arrays src1 and src2 and write the result to
    /// array dst. Array dst does not need to be distinct from src1
    fn array_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        const card1 = src1.data.cardinality;
        const card2 = src2.data.cardinality;
        if (dst.calc_capacity() < card1) {
            try dst.array_container_grow(allocator, card1, false);
        }
        dst.data.cardinality = @intCast(misc.difference_uint16(
            src1.blocks_as(.array)[0..card1],
            src2.blocks_as(.array)[0..card2],
            dst.blocks_as(.array)[0 .. dst.data.blocks_cap * C.BLOCK_LEN16],
        ));
    }

    /// dst is a valid array container and may be the same as src1
    fn array_array_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        dst.* = try array_container_create_given_capacity(allocator, src1.data.cardinality);
        try array_container_andnot(src1, allocator, src2, dst);
    }

    /// Compute the andnot of src1 and src2 and write the result to dst, which
    /// starts uninit.
    fn bitset_array_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        assert(dst.is_uninit());
        dst.* = try bitset_container_create_noinit(allocator);
        bitset_container_copy(dst, src1);
        dst.data.cardinality = @truncate(misc.bitset_clear_list(
            dst.blocks_as(.bitset),
            dst.data.cardinality,
            src2.blocks_as(.array)[0..src2.data.cardinality],
        ));
        if (dst.data.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst.*, allocator);
            dst.deinit(allocator);
            dst.* = answer;
        }
    }

    /// Compute the andnot of src1 and src2 and write the result to
    /// dst, a valid array container that could be the same as dst.
    fn array_bitset_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        assert(dst.is_uninit());
        const card1 = src1.data.cardinality;
        dst.* = try array_container_create_given_capacity(allocator, card1);
        const d = dst.*;
        const src1array = src1.blocks_as(.array);
        const dstarray = d.blocks_as(.array);
        const src2bitset = src2.blocks_as(.bitset);
        var newcard: Cardinality = 0;
        for (src1array[0..card1]) |key| {
            dstarray[newcard] = key;
            newcard += 1 - @intFromBool(bitset_container_get(src2bitset, key));
        }
        d.data.cardinality = newcard;
    }

    /// Compute the andnot of src1 and src2 and write the result to dst. Result
    /// may be either a bitset or an array container. dst starts uninit.
    fn bitset_run_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        assert(dst.is_uninit());
        dst.* = try bitset_container_create_noinit(allocator);
        bitset_container_copy(dst, src1);
        const src2runs = src2.blocks_as(.run);
        const dstwords = dst.blocks_as(.bitset);
        for (src2runs[0..src2.data.cardinality]) |rle| {
            bitset_reset_range(dstwords, rle.value, @as(u32, rle.value) + rle.length + 1);
        }
        dst.data.cardinality = dst.compute_cardinality();
        if (dst.data.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(dst.*, allocator);
            dst.deinit(allocator);
            dst.* = answer;
        }
    }

    fn run_bitset_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {

        // follows the Java implementation as of June 2016
        assert(dst.is_uninit());
        const srccard = run_container_cardinality(src1, src1.blocks_as(.run));
        if (srccard <= C.DEFAULT_MAX_SIZE) { // must be an array
            dst.* = try array_container_create_given_capacity(allocator, srccard);
            const d = dst.*;
            d.data.cardinality = 0;
            const src1runs = src1.blocks_as(.run);
            const dstarray = d.blocks_as(.array);
            for (src1runs[0..src1.data.cardinality]) |rle| {
                const run_start: u32 = rle.value;
                const run_end = run_start + rle.length;
                var run_value: u32 = run_start;
                while (run_value <= run_end) : (run_value += 1) {
                    if (!bitset_container_contains(src2, @truncate(run_value))) {
                        dstarray[d.data.cardinality] = @truncate(run_value);
                        d.data.cardinality += 1;
                    }
                }
            }
        } else { // we guess it will be a bitset, have to check guess when done
            var answer = try bitset_container_clone(src2, allocator);
            errdefer answer.deinit(allocator);

            const src1runs = src1.blocks_as(.run);
            const answords = answer.blocks_as(.bitset);
            var last_pos: u32 = 0;
            for (src1runs[0..src1.data.cardinality]) |rle| {
                const start: u32 = rle.value;
                const end = start + rle.length + 1;
                bitset_reset_range(answords, last_pos, start);
                misc.bitset_flip_range(answords, start, end);
                last_pos = end;
            }
            bitset_reset_range(answords, last_pos, C.MAX_KEY_CARDINALITY);
            answer.data.cardinality = bitset_container_compute_cardinality(answords);

            if (answer.data.cardinality <= C.DEFAULT_MAX_SIZE) {
                dst.* = try answer.array_container_from_bitset(allocator);
                answer.deinit(allocator);
                return;
            }
            dst.* = answer;
        }
    }

    /// dst must be a valid array container, allowed to be src1
    fn array_run_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        // basically following Java impl as of June 2016
        const card1 = src1.data.cardinality;
        assert(dst.is_uninit());
        dst.* = try array_container_create_given_capacity(allocator, card1);
        const src1array = src1.blocks_as(.array);
        const src2runs = src2.blocks_as(.run);
        const d = dst.*;
        const dstarray = d.blocks_as(.array);

        if (src2.data.cardinality == 0) {
            @memcpy(dstarray[0..card1], src1array);
            d.data.cardinality = card1;
            return;
        }

        var run_start: u32 = src2runs[0].value;
        var run_end: u32 = run_start + src2runs[0].length;
        var which_run: u32 = 0;
        var dest_card: Cardinality = 0;
        var valp: [*]const u16 = src1array;
        const end = @intFromPtr(src1array + card1);
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
                    if (which_run < src2.data.cardinality) {
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
        d.data.cardinality = dest_card;
    }

    /// dst must be a valid array container with adequate capacity.
    fn run_array_array_subtract(
        src1: Container,
        src2: Container,
        dst: *Container,
    ) Cardinality {
        const src1runs = src1.blocks_as(.run);
        const src2array = src2.blocks_as(.array);
        const dstarray = dst.blocks_as(.array);
        var out_card: Cardinality = 0;
        var in_array_pos: u32 = math.maxInt(u32); // -1, use wrapping math
        for (src1runs[0..src1.data.cardinality]) |rle| {
            const start: u32 = rle.value;
            const end = start + rle.length + 1;
            const min = rle.value;
            in_array_pos = misc.advanceUntil(src2array[0..src2.data.cardinality], in_array_pos, min);
            if (in_array_pos >= src2.data.cardinality) {
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
                            next_nonincluded = if (in_array_pos + 1 >= src2.data.cardinality)
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
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        src1.data.cardinality = @truncate(misc.bitset_clear_list(
            src1.blocks_as(.bitset),
            src1.data.cardinality,
            src2.blocks_as(.array)[0..src2.data.cardinality],
        ));
        if (src1.data.cardinality <= C.DEFAULT_MAX_SIZE) {
            const answer = try array_container_from_bitset(src1, allocator);
            src1.destroy(allocator);
            dst.* = answer;
        } else {
            dst.* = src1;
        }
    }

    /// dst does not indicate a valid container initially.  Eventually it
    /// can become any type of container.
    fn run_array_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
        dstr: *Bitmap,
    ) !void {
        assert(dst.is_uninit());
        const card = run_container_cardinality(src1, src1.blocks_as(.run));
        const arbitrary_threshold = 32;

        if (card <= arbitrary_threshold) {
            if (src2.data.cardinality == 0) {
                try dstr.ensure_unused_capacity(allocator, 1);
                dst.* = try run_container_clone(src1, allocator);
                return;
            }
            var ans = try run_container_create_given_capacity(allocator, card + src2.data.cardinality);
            errdefer deinit(&ans, allocator);
            ans.data.cardinality = 0;

            const src1runs = src1.blocks_as(.run);
            const src2array = src2.blocks_as(.array);
            const ansruns = ans.blocks_as(.run);

            var rlepos: u32 = 0;
            var xrlepos: u32 = 0;
            const rle = src1runs[rlepos];
            var start: u32 = rle.value;
            var end: u32 = start + rle.length + 1;
            var xstart: u32 = src2array[xrlepos];
            while (rlepos < src1.data.cardinality and xrlepos < src2.data.cardinality) {
                if (end <= xstart) { // output the first run
                    ansruns[ans.data.cardinality] = .{
                        .value = @intCast(start),
                        .length = @intCast(end - start - 1),
                    };
                    ans.data.cardinality += 1;
                    rlepos += 1;
                    if (rlepos < src1.data.cardinality) {
                        start = src1runs[rlepos].value;
                        end = start + src1runs[rlepos].length + 1;
                    }
                } else if (xstart + 1 <= start) { // exit the second run
                    xrlepos += 1;
                    if (xrlepos < src2.data.cardinality)
                        xstart = src2array[xrlepos];
                } else {
                    if (start < xstart) {
                        ansruns[ans.data.cardinality] = .{
                            .value = @intCast(start),
                            .length = @intCast(xstart - start - 1),
                        };
                        ans.data.cardinality += 1;
                    }
                    if (xstart + 1 < end)
                        start = xstart + 1
                    else {
                        rlepos += 1;
                        if (rlepos < src1.data.cardinality) {
                            start = src1runs[rlepos].value;
                            end = start + src1runs[rlepos].length + 1;
                        }
                    }
                }
            }
            if (rlepos < src1.data.cardinality) {
                ansruns[ans.data.cardinality] = .{
                    .value = @truncate(start),
                    .length = @truncate(end - start - 1),
                };
                ans.data.cardinality += 1;
                rlepos += 1;
                if (rlepos < src1.data.cardinality) {
                    const remaining = src1runs[rlepos..src1.data.cardinality];
                    @memcpy(ansruns[ans.data.cardinality..], remaining);
                    ans.data.cardinality += @intCast(remaining.len);
                }
            }
            dst.* = try convert_run_to_efficient_container_and_free(&ans, allocator);
            return;
        }

        // else it's a bitmap or array
        if (card <= C.DEFAULT_MAX_SIZE) {
            dst.* = try array_container_create_given_capacity(allocator, card);
            // nb Java code used a generic iterator-based merge to compute
            // difference
            dst.data.cardinality = run_array_array_subtract(src1, src2, dst);
            return;
        }
        var ans = try bitset_container_from_run(src1, allocator);
        try ans.bitset_array_container_iandnot(allocator, src2, dst);
    }

    /// dst starts uninit and can become any kind of container.
    fn run_run_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        assert(dst.is_uninit());
        dst.* = try run_container_create_given_capacity(allocator, src1.data.cardinality + src2.data.cardinality);
        try run_container_andnot(src1, allocator, src2, dst);
        dst.* = try convert_run_to_efficient_container_and_free(dst, allocator);
    }

    /// Run-level andnot operation on run containers.
    fn run_container_andnot(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dstp: *Container,
    ) !void {
        const nruns1 = src1.data.cardinality;
        const nruns2 = src2.data.cardinality;
        const needed_capacity = nruns1 + nruns2;
        var dst = dstp.*;
        if (dst.calc_capacity() < needed_capacity) {
            try run_container_grow(dstp, allocator, needed_capacity, false);
            dst = dstp.*;
        }
        dst.data.cardinality = 0;

        const src1runs = src1.blocks_as(.run);
        const src2runs = src2.blocks_as(.run);
        const dstruns = dst.blocks_as(.run);

        var rlepos1: u32 = 0;
        var rlepos2: u32 = 0;
        var start: u32 = src1runs[rlepos1].value;
        var end: u32 = start + src1runs[rlepos1].length + 1;
        var start2: u32 = src2runs[rlepos2].value;
        var end2: u32 = start2 + src2runs[rlepos2].length + 1;

        while (rlepos1 < nruns1 and rlepos2 < nruns2) {
            if (end <= start2) {
                dstruns[dst.data.cardinality] = .{
                    .value = @intCast(start),
                    .length = @intCast(end - start - 1),
                };
                dst.data.cardinality += 1;
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
                    dstruns[dst.data.cardinality] = .{
                        .value = @intCast(start),
                        .length = @intCast(start2 - start - 1),
                    };
                    dst.data.cardinality += 1;
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
            dstruns[dst.data.cardinality] = .{
                .value = @intCast(start),
                .length = @intCast(end - start - 1),
            };
            dst.data.cardinality += 1;
            rlepos1 += 1;
            if (rlepos1 < nruns1) {
                const remaining = src1runs[rlepos1..nruns1];
                @memcpy(dstruns[dst.data.cardinality..][0..remaining.len], remaining);
                dst.data.cardinality += @intCast(remaining.len);
            }
        }
    }

    pub fn xor(
        c1: Container,
        allocator: Allocator,
        c2: Container,
    ) !Container {
        var result = uninit;
        errdefer deinit(&result, allocator);
        switch (misc.pair(c1.data.typecode, c2.data.typecode)) {
            misc.pair(.bitset, .bitset) => {
                try bitset_bitset_container_xor(c1, allocator, c2, &result);
            },
            misc.pair(.array, .array) => {
                try array_array_container_xor(c1, allocator, c2, &result);
            },
            misc.pair(.run, .run) => {
                try run_run_container_xor(c1, allocator, c2, &result);
            },
            misc.pair(.bitset, .array) => {
                try array_bitset_container_xor(c2, allocator, c1, &result);
            },
            misc.pair(.array, .bitset) => {
                try array_bitset_container_xor(c1, allocator, c2, &result);
            },
            misc.pair(.bitset, .run) => {
                try run_bitset_container_xor(c2, allocator, c1, &result);
            },
            misc.pair(.run, .bitset) => {
                try run_bitset_container_xor(c1, allocator, c2, &result);
            },
            misc.pair(.array, .run) => {
                try array_run_container_xor(c1, allocator, c2, &result);
            },
            misc.pair(.run, .array) => {
                try array_run_container_xor(c2, allocator, c1, &result);
            },
            else => unreachable,
        }
        return result;
    }

    /// Compute andnot (difference) between two containers, return a new
    /// container. This allocates new memory, caller is responsible for
    /// deallocation.
    pub fn andnot(
        c1: Container,
        allocator: Allocator,
        c2: Container,
        dstr: *Bitmap,
    ) !Container {
        var result = uninit;
        errdefer deinit(&result, allocator);
        switch (misc.pair(c1.data.typecode, c2.data.typecode)) {
            misc.pair(.bitset, .bitset) => {
                try bitset_bitset_container_andnot(c1, allocator, c2, &result);
            },
            misc.pair(.array, .array) => {
                try array_array_container_andnot(c1, allocator, c2, &result);
            },
            misc.pair(.run, .run) => {
                if (run_container_is_full(c2)) return result;
                try run_run_container_andnot(c1, allocator, c2, &result);
            },
            misc.pair(.bitset, .array) => {
                try bitset_array_container_andnot(c1, allocator, c2, &result);
            },
            misc.pair(.array, .bitset) => {
                try array_bitset_container_andnot(c1, allocator, c2, &result);
            },
            misc.pair(.bitset, .run) => {
                if (run_container_is_full(c2)) return result;
                try bitset_run_container_andnot(c1, allocator, c2, &result);
            },
            misc.pair(.run, .bitset) => {
                try run_bitset_container_andnot(c1, allocator, c2, &result);
            },
            misc.pair(.array, .run) => {
                if (run_container_is_full(c2)) return result;
                try array_run_container_andnot(c1, allocator, c2, &result);
            },
            misc.pair(.run, .array) => {
                try run_array_container_andnot(c1, allocator, c2, &result, dstr);
            },
            else => unreachable,
        }
        return result;
    }

    /// Create an copy of a c and it's blocks
    pub fn get_copy_of_container(
        c: Container,
        allocator: Allocator,
        copy_on_write: bool,
    ) !Container {
        if (copy_on_write) {
            unreachable; // TODO
        }
        // TODO c = container_unwrap_shared(c);

        return try clone(c, allocator);
    }

    fn array_container_clone(c: Container, allocator: Allocator) !Container {
        var newc = try array_container_create_given_capacity(allocator, c.data.cardinality);
        newc.data.cardinality = c.data.cardinality;
        @memcpy(
            newc.blocks_as(.array)[0..c.data.cardinality],
            c.blocks_as(.array)[0..c.data.cardinality],
        );
        return newc;
    }

    fn run_container_clone(
        c: Container,
        allocator: Allocator,
    ) !Container {
        var newc = try run_container_create_given_capacity(allocator, c.data.cardinality);
        newc.data.cardinality = c.data.cardinality;
        @memcpy(
            newc.blocks_as(.run)[0..c.data.cardinality],
            c.blocks_as(.run)[0..c.data.cardinality],
        );
        return newc;
    }

    fn bitset_container_clone(
        c1: Container,
        allocator: Allocator,
    ) !Container {
        assert(c1.data.typecode == .bitset);
        const bc = try bitset_container_create(allocator);
        bc.data.cardinality = c1.data.cardinality;
        @memcpy(bc.data.blocks[0..C.BITSET_BLOCKS], c1.data.blocks);
        return bc;
    }

    pub fn clone(c: Container, allocator: Allocator) !Container {
        return switch (c.data.typecode) {
            .array => c.array_container_clone(allocator),
            .run => c.run_container_clone(allocator),
            .bitset => c.bitset_container_clone(allocator),
            .shared => unreachable,
        };
    }

    /// returns true if a container is known to be full. Note that a lazy bitset
    /// container might be full without us knowing.
    ///
    /// Note: array cardinality 65536 doesn't seem correct but is needed for
    /// croaring compatibility
    pub fn is_full(c: Container) bool {
        return switch (c.data.typecode) {
            .bitset, .array => c.data.cardinality == C.MAX_KEY_CARDINALITY,
            .run => run_container_is_full(c),
            else => unreachable,
        };
    }

    /// Check whether the container spans the whole chunk (cardinality = 1<<16).
    /// This check can be done in constant time (inexpensive).
    fn run_container_is_full(run: Container) bool {
        const vl = run.blocks_as(.run)[0];
        return (run.data.cardinality == 1) and (vl.value == 0) and (vl.length == 0xFFFF);
    }

    fn bitset_extract_intersection_setbits_uint16(
        words1: [*]align(C.BLOCK_ALIGN) const u64,
        words2: [*]align(C.BLOCK_ALIGN) const u64,
        out: []align(C.BLOCK_ALIGN) u16,
        base: u16,
    ) usize {
        var outpos: u32 = 0;
        var base1: u32 = base;
        for (
            words1[0..C.BITSET_CONTAINER_SIZE_IN_WORDS],
            words2[0..C.BITSET_CONTAINER_SIZE_IN_WORDS],
        ) |w1, w2| {
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
        return math.maxInt(u16);
    }

    /// Returns the largest value (assumes not empty)
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
        if (arr.data.cardinality == 0) return 0;
        return array[0];
    }

    /// Returns the largest value (assumes not empty)
    pub fn array_container_maximum(arr: Container, array: [*]align(C.BLOCK_ALIGN) const u16) u16 {
        if (arr.data.cardinality == 0) return 0;
        return array[arr.data.cardinality - 1];
    }

    /// Returns the smallest value (assumes not empty)
    pub fn run_container_minimum(run: Container, runs: [*]align(C.BLOCK_ALIGN) const Rle16) u16 {
        if (run.data.cardinality == 0) return 0;
        return runs[0].value;
    }

    /// Returns the largest value (assumes not empty)
    pub fn run_container_maximum(run: Container, runs: [*]align(C.BLOCK_ALIGN) const Rle16) u16 {
        if (run.data.cardinality == 0) return 0;
        return runs[run.data.cardinality - 1].value + runs[run.data.cardinality - 1].length;
    }

    pub fn minimum(c: Container) u16 {
        // TODO // c = container_unwrap_shared(c);
        return switch (c.data.typecode) {
            .bitset => bitset_container_minimum(c.blocks_as(.bitset)),
            .array => return c.array_container_minimum(c.blocks_as(.array)),
            .run => return c.run_container_minimum(c.blocks_as(.run)),
            else => unreachable,
        };
    }

    pub fn maximum(c: Container) u16 {
        // TODO // c = container_unwrap_shared(c);
        return switch (c.data.typecode) {
            .bitset => bitset_container_maximum(c.blocks_as(.bitset)),
            .array => return c.array_container_maximum(c.blocks_as(.array)),
            .run => return c.run_container_maximum(c.blocks_as(.run)),
            else => unreachable,
        };
    }

    /// Returns the number of integers that are smaller or equal to x.
    fn array_container_rank(c: Container, x: u16) u32 {
        const array = c.blocks_as(.array)[0..c.data.cardinality];
        const idx = misc.binarySearch(array, x);
        return @bitCast(if (idx >= 0) idx + 1 else -idx - 1);
    }

    /// Returns the number of values equal or smaller than x
    fn bitset_container_rank(c: Container, x: u16) u32 {
        // credit: aqrit
        const words = c.blocks_as(.bitset);
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

    fn run_container_rank(c: Container, x: u16) u32 {
        const runs = c.blocks_as(.run)[0..c.data.cardinality];
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

    pub fn rank(c: Container, x: u16) u32 {
        return switch (c.data.typecode) {
            .bitset => c.bitset_container_rank(x),
            .array => c.array_container_rank(x),
            .run => c.run_container_rank(x),
            .shared => unreachable,
        };
    }

    /// If the element of given rank is in this container, supposing that the
    /// first element has rank start_rank, then return element. Otherwise, it
    /// returns null and updates start_rank.
    fn array_container_select(c: Container, start_rank: *u32, target_rank: u32) ?u32 {
        const card = c.data.cardinality;
        if (start_rank.* + card <= target_rank) {
            start_rank.* += card;
            return null;
        } else {
            const array = c.blocks_as(.array);
            return array[target_rank - start_rank.*];
        }
    }

    /// If the element of given rank is in this container, supposing that the first
    /// element has rank start_rank, then the function returns element accordingly.
    /// Otherwise, it returns null and updates start_rank.
    fn bitset_container_select(c: Container, start_rank: *u32, target_rank: u32) ?u32 {
        const card = c.data.cardinality;
        if (target_rank >= start_rank.* + card) {
            start_rank.* += card;
            return null;
        }
        const words = c.blocks_as(.bitset);
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

    fn run_container_select(c: Container, start_rank: *u32, target_rank: u32) ?u32 {
        const runs = c.blocks_as(.run)[0..c.data.cardinality];
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

    pub fn select(c: Container, start_rank: *u32, target_rank: u32) ?u32 {
        return switch (c.data.typecode) {
            .bitset => c.bitset_container_select(start_rank, target_rank),
            .array => c.array_container_select(start_rank, target_rank),
            .run => c.run_container_select(start_rank, target_rank),
            .shared => unreachable,
        };
    }

    fn array_container_is_subset(c1: Container, c2: Container) bool {
        if (c1.data.cardinality > c2.data.cardinality) return false;
        const array1 = c1.blocks_as(.array)[0..c1.data.cardinality];
        const array2 = c2.blocks_as(.array)[0..c2.data.cardinality];
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

    fn bitset_container_is_subset(c1: Container, c2: Container) bool {
        if (c1.data.cardinality != C.BITSET_UNKNOWN_CARDINALITY and
            c2.data.cardinality != C.BITSET_UNKNOWN_CARDINALITY and
            c1.data.cardinality > c2.data.cardinality) return false;
        const words1 = c1.blocks_as(.bitset);
        const words2 = c2.blocks_as(.bitset);
        for (
            words1[0..C.BITSET_CONTAINER_SIZE_IN_WORDS],
            words2[0..C.BITSET_CONTAINER_SIZE_IN_WORDS],
        ) |w1, w2| {
            if ((w1 & w2) != w1) return false;
        }
        return true;
    }

    fn run_container_is_subset(c1: Container, c2: Container) bool {
        const runs1 = c1.blocks_as(.run)[0..c1.data.cardinality];
        const runs2 = c2.blocks_as(.run)[0..c2.data.cardinality];
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

    fn array_container_is_subset_bitset(c1: Container, c2: Container) bool {
        if (c2.data.cardinality < c1.data.cardinality)
            return false;
        const array1 = c1.blocks_as(.array)[0..c1.data.cardinality];
        const words2 = c2.blocks_as(.bitset);
        for (array1) |val| {
            if (!bitset_container_get(words2, val)) return false;
        }
        return true;
    }

    fn array_container_is_subset_run(c1: Container, c2: Container) bool {
        const runs2 = c2.blocks_as(.run);
        if (c1.data.cardinality > c2.run_container_cardinality(runs2))
            return false;
        const array1 = c1.blocks_as(.array)[0..c1.data.cardinality];
        var iarray: u32 = 0;
        var irun: u32 = 0;
        while (iarray < array1.len and irun < c2.data.cardinality) {
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

    fn run_container_is_subset_array(c1: Container, c2: Container) bool {
        const runs1 = c1.blocks_as(.run);
        if (c1.run_container_cardinality(runs1) > c2.data.cardinality)
            return false;
        const array2 = c2.blocks_as(.array)[0..c2.data.cardinality];
        var start_pos: u32 = math.maxInt(u32);
        var stop_pos: u32 = math.maxInt(u32);
        for (runs1[0..c1.data.cardinality]) |run| {
            const start: u32 = run.value;
            const stop: u32 = start + run.length;
            start_pos = misc.advanceUntil(array2, start_pos, @intCast(start));
            stop_pos = misc.advanceUntil(array2, stop_pos, @intCast(stop));
            if (stop_pos == c2.data.cardinality)
                return false;
            if (stop_pos - start_pos != stop - start or
                array2[start_pos] != start or
                array2[stop_pos] != stop)
                return false;
        }
        return true;
    }

    fn run_container_is_subset_bitset(c1: Container, c2: Container) bool {
        // todo: this code could be much faster
        const runs1 = c1.blocks_as(.run);
        const words2 = c2.blocks_as(.bitset);
        if (c2.data.cardinality != C.BITSET_UNKNOWN_CARDINALITY) {
            if (c2.data.cardinality < c1.run_container_cardinality(runs1))
                return false;
        } else {
            const card = bitset_container_compute_cardinality(words2); // modify container2?
            if (card < c1.run_container_cardinality(runs1)) {
                return false;
            }
        }
        for (runs1[0..c1.data.cardinality]) |run| {
            const start: u32 = run.value;
            const end = start + run.length;
            var j = start;
            while (j <= end) : (j += 1) {
                if (!bitset_container_get(words2, @intCast(j)))
                    return false;
            }
        }
        return true;
    }

    fn bitset_container_is_subset_run(c1: Container, c2: Container) bool {
        // todo: this code could be much faster
        const words1 = c1.blocks_as(.bitset);
        const runs2 = c2.blocks_as(.run);
        if (c1.data.cardinality != C.BITSET_UNKNOWN_CARDINALITY) {
            if (c1.data.cardinality > c2.run_container_cardinality(runs2))
                return false;
        }
        var ibitset: u32 = 0;
        var irun: u32 = 0;
        while (ibitset < C.BITSET_CONTAINER_SIZE_IN_WORDS and irun < c2.data.cardinality) {
            var w = words1[ibitset];
            while (w != 0 and irun < c2.data.cardinality) {
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

    pub fn is_subset(c1: Container, c2: Container) bool {
        return switch (misc.pair(c1.data.typecode, c2.data.typecode)) {
            misc.pair(.array, .array) => array_container_is_subset(c1, c2),
            misc.pair(.array, .bitset) => array_container_is_subset_bitset(c1, c2),
            misc.pair(.array, .run) => array_container_is_subset_run(c1, c2),
            misc.pair(.array, .shared) => unreachable,
            misc.pair(.bitset, .array) => false,
            misc.pair(.bitset, .bitset) => bitset_container_is_subset(c1, c2),
            misc.pair(.bitset, .run) => bitset_container_is_subset_run(c1, c2),
            misc.pair(.bitset, .shared) => unreachable,
            misc.pair(.run, .array) => run_container_is_subset_array(c1, c2),
            misc.pair(.run, .bitset) => run_container_is_subset_bitset(c1, c2),
            misc.pair(.run, .run) => run_container_is_subset(c1, c2),
            misc.pair(.run, .shared) => unreachable,
            else => unreachable,
        };
    }

    /// no matter what the initial container was, convert it to a bitset if a
    /// new container is produced, caller responsible for freeing the previous
    /// one container should not be a shared container
    ///
    /// c is allocated in r. returned container is allocated in dstr.
    pub fn to_bitset(c: Container, allocator: Allocator) !Container {
        return switch (c.data.typecode) {
            .bitset => c,
            .array => try c.bitset_container_from_array_dst(allocator),
            .run => try c.bitset_container_from_run(allocator),
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
        c2: Container,
    ) !Container {
        assert(c1.data.typecode != .shared);
        // c1 = get_writable_copy_if_shared(c1,&type1);
        // TODO // c2 = container_unwrap_shared(c2, &type2);
        var result = uninit;
        errdefer deinit(&result, allocator);
        switch (misc.pair(c1.data.typecode, c2.data.typecode)) {
            misc.pair(.bitset, .bitset) => {
                if (C.LAZY_OR_BITSET_CONVERSION_TO_FULL) {
                    // if we have two bitsets, we might as well compute the cardinality
                    bitset_container_or(c1, c2, c1);
                    // it is possible that two bitsets can lead to a full container
                    if (c1.data.cardinality == C.MAX_KEY_CARDINALITY) { // we convert
                        return try run_container_create_range(allocator, 0, C.MAX_KEY_CARDINALITY);
                    }
                } else {
                    const c1words = c1.blocks_as(.bitset);
                    const c2words = c2.blocks_as(.bitset);
                    _ = bitset_container_or_nocard(c1words, c2words, c1.*, c1words);
                }
                return c1.*;
            },
            misc.pair(.array, .array) => {
                try array_array_container_lazy_inplace_union(c1.*, allocator, c2, &result);
                if (result.is_uninit() and c1.data.typecode == .array)
                    return c1.*; // the computation was done in-place!
                return result;
            },
            misc.pair(.run, .run) => {
                try run_container_union_inplace(c1, allocator, c2);
                return try c1.convert_run_to_efficient_container(allocator);
            },
            misc.pair(.bitset, .array) => {
                array_bitset_container_lazy_union(c2, c1.*, c1); // is lazy
                return c1.*;
            },
            misc.pair(.array, .bitset) => {
                // c1 is an array, so no in-place possible
                result = try bitset_container_create_noinit(allocator);
                array_bitset_container_lazy_union(c1.*, c2, &result); // is lazy
                return result;
            },
            misc.pair(.bitset, .run) => {
                if (run_container_is_full(c2)) {
                    result = try run_container_create_given_capacity(allocator, c2.data.cardinality);
                    try run_container_copy(c2, allocator, &result, c2.blocks_as(.run));
                    return result;
                }
                run_bitset_container_lazy_union(c2, c1.*, c1); // allowed //  lazy
                return c1.*;
            },
            misc.pair(.run, .bitset) => {
                if (run_container_is_full(c1.*)) {
                    return c1.*;
                }
                result = try bitset_container_create_noinit(allocator);
                run_bitset_container_lazy_union(c1.*, c2, &result); //  lazy
                return result;
            },
            misc.pair(.array, .run) => {
                result = try run_container_create_given_capacity(allocator, c2.data.cardinality);
                try array_run_container_union(c1.*, allocator, c2, &result);
                // skip convert_run_to_efficient_container since we are lazy
                return result;
            },
            misc.pair(.run, .array) => {
                try array_run_container_inplace_union(c2, allocator, c1);
                // skip convert_run_to_efficient_container since we are lazy
                return c1.*;
            },
            else => unreachable,
        }
    }

    fn array_array_container_lazy_inplace_union(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        const totalCardinality = src1.data.cardinality + src2.data.cardinality;
        assert(dst.is_uninit());
        trace(@src(), "totalCardinality={} src1.calc_capacity()={}", .{ totalCardinality, src1.calc_capacity() });
        if (totalCardinality <= C.ARRAY_LAZY_LOWERBOUND) {
            if (src1.calc_capacity() < totalCardinality) {
                // be purposefully generous
                dst.* = try array_container_create_given_capacity(allocator, 2 * totalCardinality);
                try array_container_union(src1, allocator, src2, dst);
                return;
            } else {
                const arr1 = src1.blocks_as(.array);
                const arr2 = src2.blocks_as(.array)[0..src2.data.cardinality];
                @memmove(arr1 + src2.data.cardinality, arr1[0..src1.data.cardinality]);
                src1.data.cardinality = @intCast(misc.fast_union_uint16(
                    arr1[src2.data.cardinality..][0..src1.data.cardinality],
                    arr2,
                    arr1,
                ));
                return;
            }
        }
        dst.* = try bitset_container_create(allocator);
        const dstwords = dst.blocks_as(.bitset);
        misc.bitset_set_list(dstwords, src1.blocks_as(.array)[0..src1.data.cardinality]);
        misc.bitset_set_list(dstwords, src2.blocks_as(.array)[0..src2.data.cardinality]);
        dst.data.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
    }

    fn array_array_container_lazy_union(
        src1: Container,
        allocator: Allocator,
        src2: Container,
        dst: *Container,
    ) !void {
        const totalCardinality = src1.data.cardinality + src2.data.cardinality;
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
        if (totalCardinality <= C.ARRAY_LAZY_LOWERBOUND) {
            dst.* = try array_container_create_given_capacity(allocator, totalCardinality);
            try array_container_union(src1, allocator, src2, dst);
            return;
        }

        dst.* = try bitset_container_create(allocator);
        const dstwords = dst.blocks_as(.bitset);
        misc.bitset_set_list(dstwords, src1.blocks_as(.array)[0..src1.data.cardinality]);
        misc.bitset_set_list(dstwords, src2.blocks_as(.array)[0..src2.data.cardinality]);
        dst.data.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
    }

    /// Compute the union of src1 and src2 and write the result to
    /// dst. It is allowed for src2 to be dst.  This version does not
    /// update the cardinality of dst (it is set to BITSET_UNKNOWN_CARDINALITY).
    fn array_bitset_container_lazy_union(
        src1: Container,
        src2: Container,
        dst: *Container,
    ) void {
        if (src2.data != dst.data) bitset_container_copy(dst, src2);
        const dstwords = dst.blocks_as(.bitset);
        misc.bitset_set_list(dstwords, src1.blocks_as(.array)[0..src1.data.cardinality]);
        dst.data.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
    }

    fn run_bitset_container_lazy_union(
        src1: Container,
        src2: Container,
        dst: *Container,
    ) void {
        if (src2.data != dst.data) bitset_container_copy(dst, src2);
        const runs = src1.blocks_as(.run)[0..src1.data.cardinality];
        const dstwords = dst.blocks_as(.bitset);
        for (runs) |rle| {
            misc.bitset_set_lenrange(dstwords, rle.value, rle.length);
        }
        dst.data.cardinality = C.BITSET_UNKNOWN_CARDINALITY;
    }

    /// Compute union between two containers, generate a new container. This
    /// allocates new memory, caller is responsible for deallocation.
    ///
    /// This lazy version delays some operations such as the maintenance of the
    /// cardinality. It requires repair later on the generated containers.
    pub fn lazy_or(
        c1: Container,
        allocator: Allocator,
        c2: Container,
    ) !Container {
        assert(c1.data.typecode != .shared);
        // c1 = get_writable_copy_if_shared(c1,&type1);
        // TODO // c2 = container_unwrap_shared(c2, &type2);
        var result = uninit;
        errdefer deinit(&result, allocator);
        switch (misc.pair(c1.data.typecode, c2.data.typecode)) {
            misc.pair(.bitset, .bitset) => {
                result = try bitset_container_create_noinit(allocator);
                _ = bitset_container_or_nocard(
                    c1.blocks_as(.bitset),
                    c2.blocks_as(.bitset),
                    result,
                    result.blocks_as(.bitset),
                );
                return result;
            },
            misc.pair(.array, .array) => {
                try array_array_container_lazy_union(c1, allocator, c2, &result);
                if (result.is_uninit() and c1.data.typecode == .array)
                    return c1; // the computation was done in-place!
                return result;
            },
            misc.pair(.run, .run) => {
                result = try run_container_create_given_capacity(
                    allocator,
                    @max(c1.data.cardinality, c2.data.cardinality),
                );
                try run_container_union(c1, allocator, c2, &result);
                return try convert_run_to_efficient_container_and_free(&result, allocator);
            },
            misc.pair(.bitset, .array) => {
                result = try bitset_container_create_noinit(allocator);
                array_bitset_container_lazy_union(c2, c1, &result); // is lazy
                return result;
            },
            misc.pair(.array, .bitset) => {
                // c1 is an array, so no in-place possible
                result = try bitset_container_create_noinit(allocator);
                array_bitset_container_lazy_union(c1, c2, &result); // is lazy
                return result;
            },
            misc.pair(.bitset, .run) => {
                if (run_container_is_full(c2)) {
                    result = try run_container_create_given_capacity(allocator, c2.data.cardinality);
                    const c2runs = c2.blocks_as(.run);
                    try run_container_copy(c2, allocator, &result, c2runs);
                    return result;
                }
                result = try bitset_container_create_noinit(allocator);
                run_bitset_container_lazy_union(c2, c1, &result); // is lazy
                return result;
            },
            misc.pair(.run, .bitset) => {
                if (run_container_is_full(c1)) {
                    result = try run_container_create_given_capacity(allocator, c1.data.cardinality);
                    const c1runs = c1.blocks_as(.run);
                    try run_container_copy(c1, allocator, &result, c1runs);
                    return result;
                }
                result = try bitset_container_create_noinit(allocator);
                run_bitset_container_lazy_union(c1, c2, &result); //  lazy
                return result;
            },
            misc.pair(.array, .run) => {
                result = try run_container_create_given_capacity(allocator, 2 * (c1.data.cardinality + c2.data.cardinality));
                try array_run_container_union(c1, allocator, c2, &result);
                // skip convert_run_to_efficient_container since we are lazy
                return result;
            },
            misc.pair(.run, .array) => {
                result = try run_container_create_given_capacity(allocator, 2 * (c1.data.cardinality + c2.data.cardinality));
                try array_run_container_union(c2, allocator, c1, &result);
                // skip convert_run_to_efficient_container since we are lazy
                return result;
            },
            else => unreachable,
        }
    }

    /// "repair" the container after lazy operations.
    pub fn repair_after_lazy(cp: *Container, allocator: Allocator) !Container {
        const c = cp.*;
        switch (c.data.typecode) {
            .bitset => {
                c.data.cardinality = bitset_container_compute_cardinality(c.blocks_as(.bitset));
                if (c.data.cardinality <= C.DEFAULT_MAX_SIZE) {
                    const bc = try c.array_container_from_bitset(allocator);
                    deinit(cp, allocator);
                    return bc;
                }
                return c;
            },
            .array => return c,
            .run => return try convert_run_to_efficient_container_and_free(cp, allocator),
            else => unreachable,
        }
    }

    fn shared_container_extract_copy(sc: Container, allocator: Allocator, r: Bitmap) !Container {
        _ = sc;
        _ = r;
        _ = allocator;
        unreachable;
    }

    pub fn get_writable_copy_if_shared(c1: Container, allocator: Allocator, x1: Bitmap) !Container {
        return if (c1.data.typecode == .shared)
            try c1.shared_container_extract_copy(allocator, x1)
        else
            c1;
    }

    /// Check whether a range of bits from position `pos_start' (included) to
    /// `pos_end' (excluded) is present in the bitset container.
    fn bitset_container_get_range(c: Container, pos_start: u32, pos_end: u32) bool {
        const start = pos_start >> 6;
        const end = pos_end >> 6;

        const first = ~((@as(u64, 1) << @truncate(pos_start)) - 1);
        const last = (@as(u64, 1) << @truncate(pos_end)) - 1;

        const words = c.blocks_as(.bitset);
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
    fn array_container_contains_range(c: Container, range_start: u32, range_end: u32) bool {
        const range_count = range_end - range_start;
        const rs_included: u16 = @truncate(range_start);
        const re_included: u16 = @truncate(range_end - 1);
        if (range_count == 0) // Empty range is always included
            return true;
        if (range_count > c.data.cardinality)
            return false;

        const array = c.blocks_as(.array)[0..c.data.cardinality];
        const start = misc.binarySearch(array, rs_included);
        const startu: u32 = @bitCast(start);
        // If this sorted array contains all items in the range:
        // * the start item must be found
        // * the last item in range range_count must exist, and be the expected end value
        return start >= 0 and
            c.data.cardinality >= startu + range_count and
            array[startu + range_count - 1] == re_included;
    }

    /// Check whether all positions in a range of positions from
    /// [pos_start, pos_end) is present in `run`.
    fn run_container_contains_range(run: Container, pos_start: u32, pos_end: u32) bool {
        const runs = run.blocks_as(.run)[0..run.data.cardinality];
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
        while (i < run.data.cardinality) : (i += 1) {
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
    pub fn contains_range(c: Container, range_start: u32, range_end: u32) bool {
        return switch (c.data.typecode) {
            .bitset => c.bitset_container_get_range(range_start, range_end),
            .array => c.array_container_contains_range(range_start, range_end),
            .run => c.run_container_contains_range(range_start, range_end),
            .shared => unreachable,
        };
    }

    /// computes the size of the intersection of array1 and array2
    fn array_container_intersection_cardinality(c1: Container, c2: Container) Cardinality {
        const card_1 = c1.data.cardinality;
        const card_2 = c2.data.cardinality;
        const threshold = 64; // subject to tuning
        const c1array = c1.blocks_as(.array)[0..card_1];
        const c2array = c2.blocks_as(.array)[0..card_2];
        return @intCast(if (card_1 * threshold < card_2)
            misc.intersect_skewed_uint16_cardinality(c1array, c2array)
        else if (card_2 * threshold < card_1)
            misc.intersect_skewed_uint16_cardinality(c2array, c1array)
        else if (C.IS_X64 and C.HAS_AVX2)
            misc.intersect_vector16_cardinality(c1array, c2array)
        else
            misc.intersect_uint16_cardinality(c1array, c2array));
    }

    /// Compute the size of the intersection between src1 and src2
    fn array_run_container_intersection_cardinality(src1: Container, src2: Container) u32 {
        if (src2.run_container_is_full())
            return src1.data.cardinality;
        if (src2.data.cardinality == 0)
            return 0;

        var rlepos: u32 = 0;
        var arraypos: u32 = 0;
        const src2runs = src2.blocks_as(.run);
        var rle = src2runs[rlepos];
        var newcard: u32 = 0;
        const src1array = src1.blocks_as(.array);
        while (arraypos < src1.data.cardinality) {
            const arrayval = src1array[arraypos];
            while (rle.value + rle.length < arrayval) {
                // this will frequently be false
                @branchHint(.unlikely); // TODO bench
                rlepos += 1;
                if (rlepos == src2.data.cardinality)
                    return newcard;
                rle = src2runs[rlepos];
            }
            if (rle.value > arrayval) {
                arraypos = misc.advanceUntil(src1array[0..src1.data.cardinality], arraypos, rle.value);
            } else {
                newcard += 1;
                arraypos += 1;
            }
        }
        return newcard;
    }

    /// Compute the size of the intersection of src1 and src2
    fn run_container_intersection_cardinality(src1: Container, src2: Container) u32 {
        const if1 = src1.run_container_is_full();
        const if2 = src2.run_container_is_full();
        const src1runs = src1.blocks_as(.run);
        const src2runs = src2.blocks_as(.run);
        if (if1 or if2) {
            if (if1)
                return src2.run_container_cardinality(src2runs);

            if (if2)
                return src1.run_container_cardinality(src1runs);
        }
        var answer: u32 = 0;
        var xrlepos: u32 = 0;
        var rlepos: u32 = 0;
        var start: u32 = src1runs[rlepos].value;
        var end: u32 = start + src1runs[rlepos].length + 1;
        var xstart: u32 = src2runs[xrlepos].value;
        var xend: u32 = xstart + src2runs[xrlepos].length + 1;
        while (rlepos < src1.data.cardinality and xrlepos < src2.data.cardinality) {
            if (end <= xstart) {
                rlepos += 1;
                if (rlepos < src1.data.cardinality) {
                    start = src1runs[rlepos].value;
                    end = start + src1runs[rlepos].length + 1;
                }
            } else if (xend <= start) {
                xrlepos += 1;
                if (xrlepos < src2.data.cardinality) {
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
                    if (rlepos < src1.data.cardinality) {
                        start = src1runs[rlepos].value;
                        end = start + src1runs[rlepos].length + 1;
                    }
                    if (xrlepos < src2.data.cardinality) {
                        xstart = src2runs[xrlepos].value;
                        xend = xstart + src2runs[xrlepos].length + 1;
                    }
                } else if (end < xend) {
                    earliestend = end;
                    rlepos += 1;
                    if (rlepos < src1.data.cardinality) {
                        start = src1runs[rlepos].value;
                        end = start + src1runs[rlepos].length + 1;
                    }
                } else { // end > xend
                    earliestend = xend;
                    xrlepos += 1;
                    if (xrlepos < src2.data.cardinality) {
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
    fn array_bitset_container_intersection_cardinality(src1: Container, src2: Container) u32 {
        var newcard: u32 = 0;
        const origcard = src1.data.cardinality;
        const src1array = src1.blocks_as(.array);
        for (0..origcard) |i| {
            const key = src1array[i];
            newcard += @intFromBool(src2.bitset_container_contains(key));
        }
        return newcard;
    }

    /// Compute the intersection  between src1 and src2
    fn run_bitset_container_intersection_cardinality(src1: Container, src2: Container) u32 {
        if (run_container_is_full(src1))
            return src2.data.cardinality;

        var answer: u32 = 0;
        const src1runs = src1.blocks_as(.run)[0..src1.data.cardinality];
        const src2words = src2.blocks_as(.bitset);
        for (0..src1.data.cardinality) |rlepos| {
            const rle = src1runs[rlepos];
            answer += misc.bitset_lenrange_cardinality(src2words, rle.value, rle.length);
        }
        return answer;
    }

    /// Compute the size of the intersection between two containers.
    pub fn and_cardinality(c1: Container, c2: Container) u32 {
        // TODO // c1 = container_unwrap_shared(c1, &type1);
        // TODO // c2 = container_unwrap_shared(c2, &type2);
        return switch (misc.pair(c1.data.typecode, c2.data.typecode)) {
            misc.pair(.bitset, .bitset) => bitset_container_and_justcard(
                c1.blocks_as(.bitset),
                c2.blocks_as(.bitset),
            ),
            misc.pair(.array, .array),
            => array_container_intersection_cardinality(c1, c2),
            misc.pair(.run, .run),
            => run_container_intersection_cardinality(c1, c2),
            misc.pair(.bitset, .array),
            => array_bitset_container_intersection_cardinality(c2, c1),
            misc.pair(.array, .bitset),
            => array_bitset_container_intersection_cardinality(c1, c2),
            misc.pair(.bitset, .run),
            => run_bitset_container_intersection_cardinality(c2, c1),
            misc.pair(.run, .bitset),
            => run_bitset_container_intersection_cardinality(c1, c2),
            misc.pair(.array, .run),
            => array_run_container_intersection_cardinality(c1, c2),
            misc.pair(.run, .array),
            => array_run_container_intersection_cardinality(c2, c1),
            else => unreachable,
        };
    }

    /// Initializes the iterator at the first entry in the container.
    pub fn init_iterator(c: Container, value: *u16) Iterator {
        switch (c.data.typecode) {
            .bitset => {
                const words = c.blocks_as(.bitset);
                var wordindex: u32 = 0;
                var word = words[wordindex];
                while (word == 0) {
                    wordindex += 1;
                    word = words[wordindex];
                }
                const index = wordindex * 64 + @ctz(word);
                value.* = @intCast(index);
                return .{ .index = @intCast(index) };
            },
            .array => {
                const array = c.blocks_as(.array);
                value.* = array[0];
                return .{ .index = 0 };
            },
            .run => {
                const runs = c.blocks_as(.run);
                value.* = runs[0].value;
                return .{ .index = 0 };
            },
            else => unreachable,
        }
    }

    /// Initializes the iterator at the last entry in the container.
    pub fn init_iterator_last(c: Container, value: *u16) Iterator {
        switch (c.data.typecode) {
            .bitset => {
                const words = c.blocks_as(.bitset);
                var wordindex: u32 = C.BITSET_CONTAINER_SIZE_IN_WORDS - 1;
                var word = words[wordindex];
                while (word == 0) {
                    wordindex -= 1;
                    word = words[wordindex];
                }
                const index = wordindex * 64 + 63 - @clz(word);
                value.* = @intCast(index);
                return .{ .index = @intCast(index) };
            },
            .array => {
                const array = c.blocks_as(.array);
                const index = c.data.cardinality - 1;
                value.* = array[index];
                return .{ .index = @intCast(index) };
            },
            .run => {
                const runs = c.blocks_as(.run);
                const run_index = c.data.cardinality - 1;
                value.* = runs[run_index].value + runs[run_index].length;
                return .{ .index = @intCast(run_index) };
            },
            else => unreachable,
        }
    }

    /// Moves the iterator to the next entry. Returns true if a value is present.
    pub fn iterator_next(c: Container, it: *Iterator, value: *u16) bool {
        switch (c.data.typecode) {
            .bitset => {
                const words = c.blocks_as(.bitset);
                it.index += 1;
                var wordindex: u32 = it.index / 64;
                if (wordindex >= C.BITSET_CONTAINER_SIZE_IN_WORDS) return false;
                var word = words[wordindex] & (~@as(u64, 0) << @truncate(it.index));
                while (word == 0 and (wordindex + 1 < C.BITSET_CONTAINER_SIZE_IN_WORDS)) {
                    wordindex += 1;
                    word = words[wordindex];
                }
                if (word != 0) {
                    it.index = wordindex * 64 + @ctz(word);
                    value.* = @intCast(it.index);
                    return true;
                }
                return false;
            },
            .array => {
                const array = c.blocks_as(.array);
                it.index += 1;
                if (it.index < c.data.cardinality) {
                    value.* = array[it.index];
                    return true;
                }
                return false;
            },
            .run => {
                if (value.* == math.maxInt(u16)) return false;
                const runs = c.blocks_as(.run);
                const limit = runs[it.index].value + runs[it.index].length;
                if (value.* < limit) {
                    value.* += 1;
                    return true;
                }
                it.index += 1;
                if (it.index < c.data.cardinality) {
                    value.* = runs[it.index].value;
                    return true;
                }
                return false;
            },
            else => unreachable,
        }
    }

    /// Moves the iterator to the previous entry. Returns true if a value is present.
    pub fn iterator_prev(c: Container, it: *Iterator, value: *u16) bool {
        switch (c.data.typecode) {
            .bitset => {
                it.index -= 1;
                if (it.index == math.maxInt(u32)) return false;
                const words = c.blocks_as(.bitset);
                var wordindex: u32 = it.index / 64;
                var word = words[wordindex] & (~@as(u64, 0) >> @as(u6, @intCast(63 - (it.index % 64))));
                while (word == 0) {
                    if (wordindex == 0) return false;
                    wordindex -= 1;
                    word = words[wordindex];
                }
                it.index = wordindex * 64 + 63 - @clz(word);
                value.* = @intCast(it.index);
                return true;
            },
            .array => {
                it.index -%= 1;
                if (it.index == math.maxInt(u32)) return false;
                const array = c.blocks_as(.array);
                value.* = array[it.index];
                return true;
            },
            .run => {
                if (value.* == 0) return false;
                const runs = c.blocks_as(.run);
                value.* -= 1;
                if (value.* >= runs[it.index].value) return true;
                it.index -%= 1;
                if (it.index == math.maxInt(u32)) return false;
                value.* = runs[it.index].value + runs[it.index].length;
                return true;
            },
            else => unreachable,
        }
    }

    /// Moves the iterator to the first element >= val. Returns true if found.
    pub fn iterator_lower_bound(c: Container, it: *Iterator, value_out: *u16, val: u16) bool {
        switch (c.data.typecode) {
            .bitset => {
                const words = c.blocks_as(.bitset);
                const idx = bitset_container_index_equalorlarger(words, val);
                if (idx < 0) return false;
                it.index = @bitCast(idx);
                value_out.* = @intCast(it.index);
                return true;
            },
            .array => {
                const array = c.blocks_as(.array);
                const idx = array_container_index_equalorlarger(array, c.data.cardinality, val);
                if (idx < 0) return false;
                it.index = @bitCast(idx);
                value_out.* = array[it.index];
                return true;
            },
            .run => {
                const runs = c.blocks_as(.run);
                const idx = run_container_index_equalorlarger(runs, c.data.cardinality, val);
                if (idx < 0) return false;
                it.index = @bitCast(idx);
                value_out.* = if (runs[it.index].value <= val) val else runs[it.index].value;
                return true;
            },
            else => unreachable,
        }
    }

    /// Reads next values from iterator into buf. Returns true if iterator still has values after.
    pub fn iterator_read_into_uint32(
        c: Container,
        it: *Iterator,
        high16: u32,
        buf: []u32,
        consumed: *u32,
        value_out: *u16,
    ) bool {
        consumed.* = 0;
        if (buf.len == 0) return false;

        var buf1 = buf.ptr;
        switch (c.data.typecode) {
            .bitset => {
                const words = c.blocks_as(.bitset);
                var wordindex: u32 = it.index / 64;
                var word = words[wordindex] & (~@as(u64, 0) << @as(u6, @intCast(it.index % 64)));
                while (true) {
                    while (word != 0 and consumed.* < buf.len) {
                        buf1[0] = high16 | (wordindex * 64 + @ctz(word));
                        word &= word - 1;
                        consumed.* += 1;
                        buf1 += 1;
                    }
                    while (word == 0 and wordindex + 1 < C.BITSET_CONTAINER_SIZE_IN_WORDS) {
                        wordindex += 1;
                        word = words[wordindex];
                    }
                    if (word == 0 or consumed.* >= buf.len) break;
                }
                if (word != 0) {
                    it.index = wordindex * 64 + @ctz(word);
                    value_out.* = @intCast(it.index);
                    return true;
                }
                return false;
            },
            .array => {
                const array = c.blocks_as(.array);
                const num_values = @min(c.data.cardinality - it.index, buf.len);
                var i: u32 = 0;
                while (i < num_values) : (i += 1) {
                    buf1[i] = high16 | array[it.index + i];
                }
                consumed.* = num_values;
                it.index += num_values;
                if (it.index < c.data.cardinality) {
                    value_out.* = array[it.index];
                    return true;
                }
                return false;
            },
            .run => {
                const runs = c.blocks_as(.run);
                while (true) {
                    const largest_run_value = @as(u32, runs[it.index].value) + runs[it.index].length;
                    const num_values: u32 = @intCast(@min(
                        (largest_run_value - value_out.*) + 1,
                        buf.len - consumed.*,
                    ));

                    var i: u32 = 0;
                    while (i < num_values) : (i += 1) {
                        buf1[i] = high16 | (value_out.* + i);
                    }
                    value_out.* = value_out.* +% @as(u16, @intCast(num_values));
                    buf1 += num_values;
                    consumed.* += num_values;
                    if (value_out.* > largest_run_value or value_out.* == 0) {
                        it.index += 1;
                        if (it.index < c.data.cardinality) {
                            value_out.* = runs[it.index].value;
                        } else {
                            return false;
                        }
                    }
                    if (consumed.* >= buf.len) break;
                }
                return true;
            },
            else => unreachable,
        }
    }

    fn array_container_to_uint32_array_vector16(
        out: []u32,
        array: []align(C.BLOCK_ALIGN) const u16,
        base: u32,
    ) u32 {
        var i: u32 = 0;
        var outpos = out.ptr;
        const cardinality = array.len;
        const u16x8 = @Vector(C.BLOCK_LEN32, u16); // half block width
        while (i + C.BLOCK_LEN32 <= cardinality) : (i += C.BLOCK_LEN32) {
            const input: u16x8 = (array.ptr + i)[0..C.BLOCK_LEN32].*;
            const output = input + @as(root.Block32, @splat(base));
            outpos[0..C.BLOCK_LEN32].* = output;
            outpos += C.BLOCK_LEN32;
        }
        while (i < cardinality) : (i += 1) {
            outpos[0] = base + array[i]; // should be compiled as a MOV on x64
            outpos += 1;
        }

        return @intCast(outpos - out.ptr);
    }

    fn bitset_container_to_uint32_array(
        words: [*]align(C.BLOCK_ALIGN) const u64,
        cardinality: u32,
        out: []u32,
        base: u32,
    ) u32 {
        if (C.IS_X64) {
            // TODO AVX512, bitset_extract_setbits_avx512
            if (C.HAS_AVX2 and cardinality >= 8192) // heuristic
                return @intCast(misc.bitset_extract_setbits_avx2(
                    words,
                    C.BITSET_CONTAINER_SIZE_IN_WORDS,
                    out.ptr,
                    cardinality,
                    base,
                ));
        }
        return @intCast(misc.bitset_extract_setbits(
            words,
            C.BITSET_CONTAINER_SIZE_IN_WORDS,
            out,
            base,
        ));
    }

    fn array_container_to_uint32_array(
        array: []align(C.BLOCK_ALIGN) const u16,
        out: []u32,
        base: u32,
    ) u32 {
        if (C.IS_X64) {
            // TODO AVX512, avx512_array_container_to_uint32_array
            if (C.HAS_AVX2)
                return array_container_to_uint32_array_vector16(out, array, base);
        }
        for (out[0..array.len], array) |*o, a| {
            o.* = base + a; // should be compiled as a MOV on x64
        }
        return @intCast(array.len);
    }

    fn run_container_to_uint32_array(
        runs: []align(C.BLOCK_ALIGN) const Rle16,
        out: []u32,
        base: u32,
    ) u32 {
        var outpos = out;
        for (runs) |run| {
            const run_start = base + run.value;
            const le = run.length;
            var j: u32 = 0;
            while (j <= le) : (j += 1) {
                const val = run_start + j;
                outpos[0] = val;
                outpos = outpos[1..];
            }
        }
        return @intCast(outpos.ptr - out.ptr);
    }

    /// Convert a container to an array of values, requires a "base" (most
    /// significant values).
    ///
    /// Returns number of ints added.
    pub fn to_uint32_array(c: Container, output: []u32, base: u32) u32 {
        // TODO // c = container_unwrap_shared(c);
        return switch (c.data.typecode) {
            .bitset => bitset_container_to_uint32_array(
                c.blocks_as(.bitset),
                c.data.cardinality,
                output,
                base,
            ),
            .array => array_container_to_uint32_array(
                c.blocks_as(.array)[0..c.data.cardinality],
                output,
                base,
            ),
            .run => run_container_to_uint32_array(
                c.blocks_as(.run)[0..c.data.cardinality],
                output,
                base,
            ),
            else => unreachable,
        };
    }

    /// Computes the intersection of c1 and c2 and writes the result to c1.
    fn array_container_intersection_inplace(c1: Container, c2: Container) !void {
        const card1 = c1.data.cardinality;
        const card2 = c2.data.cardinality;
        const threshold = 64; // subject to tuning

        c1.data.cardinality = @intCast(if (card1 * threshold < card2)
            misc.intersect_skewed_uint16(
                c1.blocks_as(.array)[0..card1],
                c2.blocks_as(.array)[0..card2],
                c1.blocks_as(.array)[0..card1],
            )
        else if (card2 * threshold < card1)
            misc.intersect_skewed_uint16(
                c2.blocks_as(.array)[0..card2],
                c1.blocks_as(.array)[0..card1],
                c1.blocks_as(.array)[0..card1],
            )
        else if (C.HAS_AVX2)
            misc.intersect_vector16_inplace(
                c1.blocks_as(.array)[0..card1],
                c2.blocks_as(.array)[0..card2],
            )
        else
            misc.intersect_uint16(
                c1.blocks_as(.array)[0..card1],
                c2.blocks_as(.array)[0..card2],
                c1.blocks_as(.array)[0..card1],
            ));
    }

    pub fn iand(
        c1p: *Container,
        allocator: Allocator,
        c2: Container,
    ) !Container {
        // TODO // c1 = get_writable_copy_if_shared(c1);
        // TODO // c2 = container_unwrap_shared(c2);
        var result = uninit;
        errdefer deinit(&result, allocator);
        const c1 = c1p.*;
        switch (misc.pair(c1.data.typecode, c2.data.typecode)) {
            misc.pair(.bitset, .bitset) => {
                return try bitset_bitset_container_intersection_inplace(c1, allocator, c2);
            },
            misc.pair(.array, .array) => {
                try array_container_intersection_inplace(c1, c2);
                return c1;
            },
            misc.pair(.run, .run) => {
                result = try run_container_create_given_capacity(allocator, c1.data.cardinality + c2.data.cardinality);
                try run_container_intersection(c1, allocator, c2, &result);
                return try convert_run_to_efficient_container_and_free(&result, allocator);
            },
            misc.pair(.bitset, .array) => {
                result = try array_container_create_given_capacity(allocator, c2.data.cardinality);
                try array_bitset_container_intersection(c2, allocator, c1, &result);
            },
            misc.pair(.array, .bitset) => {
                try array_bitset_container_intersection(c1, allocator, c2, c1p);
                return c1p.*;
            },
            misc.pair(.bitset, .run) => {
                try run_bitset_container_intersection(c2, allocator, c1, &result);
            },
            misc.pair(.run, .bitset) => {
                try run_bitset_container_intersection(c1, allocator, c2, &result);
            },
            misc.pair(.array, .run) => {
                result = try array_container_create_given_capacity(allocator, c1.data.cardinality);
                try array_run_container_intersection(c1, allocator, c2, &result);
            },
            misc.pair(.run, .array) => {
                result = try array_container_create_given_capacity(allocator, c2.data.cardinality);
                try array_run_container_intersection(c2, allocator, c1, &result);
            },
            else => unreachable,
        }
        return result;
    }

    /// Negation across a range of the container.
    /// Compute the negation of src and write result to dst
    /// and return result.
    fn array_container_negation_range(
        src: Container,
        allocator: Allocator,
        range_start: u32,
        range_end: u32,
    ) !Container {
        assert(src.data.typecode == .array);
        if (range_start >= range_end) {
            return try src.array_container_clone(allocator);
        }

        var srcarray = src.blocks_as(.array);
        const cardinality = src.data.cardinality;
        var start_index = misc.binarySearch(srcarray[0..cardinality], @truncate(range_start));
        if (start_index < 0) start_index = -start_index - 1;
        var last_index = misc.binarySearch(srcarray[0..cardinality], @truncate(range_end - 1));
        if (last_index < 0) last_index = -last_index - 2;

        const current_values_in_range: u32 = @intCast(last_index - start_index + 1);
        const span_to_be_flipped = range_end - range_start;
        const new_values_in_range = span_to_be_flipped - current_values_in_range;
        const cardinality_change = new_values_in_range -% current_values_in_range;
        const new_cardinality = cardinality +% cardinality_change;

        if (new_cardinality > C.DEFAULT_MAX_SIZE) {
            var temp = try src.bitset_container_from_array_dst(allocator);
            misc.bitset_flip_range(temp.blocks_as(.bitset), range_start, range_end);
            temp.data.cardinality = @intCast(new_cardinality);
            return temp;
        }
        if (new_cardinality == 0)
            return uninit;

        var arr = try array_container_create_given_capacity(allocator, new_cardinality);
        const arrarray = arr.blocks_as(.array);
        srcarray = src.blocks_as(.array);
        // copy stuff before the active area
        @memcpy(arrarray[0..@intCast(start_index)], srcarray);

        // work on the range
        var out_pos: u32 = @intCast(start_index);
        var in_pos: u32 = @intCast(start_index);
        var val_in_range = range_start;
        while (val_in_range < range_end and in_pos <= last_index) : (val_in_range += 1) {
            if (@as(u16, @truncate(val_in_range)) != srcarray[in_pos]) {
                arrarray[out_pos] = @intCast(val_in_range);
                out_pos += 1;
            } else {
                in_pos += 1;
            }
        }
        while (val_in_range < range_end) : (val_in_range += 1) {
            arrarray[out_pos] = @intCast(val_in_range);
            out_pos += 1;
        }

        // content after the active range
        const last_index_u: u32 = @intCast(last_index + 1);
        @memcpy(
            arrarray[out_pos..][0 .. src.data.cardinality - last_index_u],
            srcarray + last_index_u,
        );
        arr.data.cardinality = @intCast(new_cardinality);
        return arr;
    }

    /// Negation across a range of the container.
    /// Compute negation of src, write result to dst and return result.
    fn bitset_container_negation_range(
        src: Container,
        allocator: Allocator,
        range_start: u32,
        range_end: u32,
    ) !Container {

        // TODO maybe consider density-based estimate
        // and sometimes build result directly as array, with
        // conversion back to bitset if wrong.  Or determine
        // actual result cardinality, then go directly for the known final cont.

        // keep computation using bitsets as long as possible.
        assert(src.data.typecode == .bitset);
        var t = try src.bitset_container_clone(allocator);
        errdefer deinit(&t, allocator);
        const words = t.blocks_as(.bitset);
        misc.bitset_flip_range(words, range_start, range_end);
        t.data.cardinality = bitset_container_compute_cardinality(words);

        if (t.data.cardinality > C.DEFAULT_MAX_SIZE) {
            return t;
        } else {
            const answer = try t.array_container_from_bitset(allocator);
            deinit(&t, allocator);
            return answer;
        }
    }

    /// Negation across a range of the container.
    /// Compute negation of src, write the result to dst and return result.
    fn run_container_negation_range(
        src: Container,
        allocator: Allocator,
        range_start: u32,
        range_end: u32,
    ) !Container {
        // follows the Java implementation
        assert(src.data.typecode == .run);
        if (range_end <= range_start) {
            return try src.run_container_clone(allocator);
        }

        const nruns = src.data.cardinality;
        var ans = try run_container_create_given_capacity(allocator, nruns + 1);
        errdefer deinit(&ans, allocator);
        const srcruns = src.blocks_as(.run);
        const ansruns = ans.blocks_as(.run);

        var k: u32 = 0;
        while (k < nruns and srcruns[k].value < range_start) : (k += 1) {
            ansruns[k] = srcruns[k];
            ans.data.cardinality += 1;
        }

        ans.run_container_smart_append_exclusive(
            ansruns,
            @intCast(range_start),
            @intCast(range_end - range_start - 1),
        );

        while (k < nruns) : (k += 1) {
            ans.run_container_smart_append_exclusive(
                ans.blocks_as(.run),
                srcruns[k].value,
                srcruns[k].length,
            );
        }

        if (ans.data.cardinality == 0) {
            deinit(&ans, allocator);
            return uninit;
        }

        const answer = try ans.convert_run_to_efficient_container(allocator);
        if (answer.data.typecode != .run)
            deinit(&ans, allocator);
        return answer;
    }

    /// Negation across a range of the container.
    /// Compute the negation of src within the range [range_start, range_end).
    /// Follows CRoaring's container_not_range.
    pub fn not_range(
        c: Container,
        allocator: Allocator,
        range_start: u32,
        range_end: u32,
    ) !Container {
        return switch (c.data.typecode) {
            .bitset => try c.bitset_container_negation_range(allocator, range_start, range_end),
            .array => try c.array_container_negation_range(allocator, range_start, range_end),
            .run => try c.run_container_negation_range(allocator, range_start, range_end),
            .shared => unreachable,
        };
    }

    /// Compute the full negation of a container (range [0, 0x10000)).
    /// Follows CRoaring's container_not.
    pub fn not(c: Container, allocator: Allocator) !Container {
        return try c.not_range(allocator, 0, C.MAX_KEY_CARDINALITY);
    }

    pub fn container_from_run_range(
        run: Container,
        allocator: Allocator,
        min: u32,
        max: u32,
    ) !Container {
        if (run.data.cardinality == 0)
            return uninit;
        // We expect most of the time to end up with a bitset container
        var bitset = try bitset_container_create(allocator);
        errdefer deinit(&bitset, allocator);
        const words = bitset.blocks_as(.bitset);
        var union_cardinality: u32 = 0;
        const runs = run.blocks_as(.run)[0..run.data.cardinality];
        for (0..run.data.cardinality) |i| {
            const rle_min: u32 = runs[i].value;
            const rle_max: u32 = rle_min + runs[i].length;
            misc.bitset_set_lenrange(words, rle_min, rle_max - rle_min);
            union_cardinality += runs[i].length + 1;
        }
        union_cardinality += @intCast(max - min + 1);
        union_cardinality -=
            misc.bitset_lenrange_cardinality(words, min, max - min);
        assert(union_cardinality > 0);
        misc.bitset_set_lenrange(words, min, max - min);
        bitset.data.cardinality = @intCast(union_cardinality);
        if (union_cardinality <= C.DEFAULT_MAX_SIZE) {
            // convert to an array container
            const array = try bitset.array_container_from_bitset(allocator);
            deinit(&bitset, allocator);
            return array;
        }
        return bitset;
    }

    /// Add all values in range [min, max] to a given container.
    ///
    /// If the returned pointer is different from $c, then a new container
    /// has been created and the caller is responsible for freeing it.
    /// The type of the first container may change. Returns the modified
    /// (and possibly new) container.
    pub fn container_add_range(
        c: *Container,
        allocator: Allocator,
        min: u32,
        max: u32,
    ) !Container {
        // NB: when selecting new container type, we perform only inexpensive checks
        switch (c.data.typecode) {
            .bitset => {
                const words = c.blocks_as(.bitset);
                var union_cardinality: u32 = 0;
                union_cardinality += c.data.cardinality;
                union_cardinality += max - min + 1;
                union_cardinality -=
                    misc.bitset_lenrange_cardinality(words, min, max - min);

                if (union_cardinality == C.MAX_KEY_CARDINALITY) {
                    return try run_container_create_range(allocator, 0, C.MAX_KEY_CARDINALITY);
                } else {
                    misc.bitset_set_lenrange(words, min, max - min);
                    c.data.cardinality = @intCast(union_cardinality);
                    return c.*;
                }
            },
            .array => {
                const array = c.blocks_as(.array)[0..c.data.cardinality];
                const nvals_greater =
                    misc.count_greater(array, @truncate(max));
                const nvals_less =
                    misc.count_less(array[0 .. c.data.cardinality - nvals_greater], @truncate(min));
                const union_cardinality =
                    nvals_less + (max - min + 1) + nvals_greater;
                if (union_cardinality == C.MAX_KEY_CARDINALITY) {
                    return try run_container_create_range(allocator, 0, C.MAX_KEY_CARDINALITY);
                } else if (union_cardinality <= C.DEFAULT_MAX_SIZE) {
                    try c.array_container_add_range_nvals(allocator, min, max, nvals_less, nvals_greater);
                    return c.*;
                } else {
                    var bitset = try c.bitset_container_from_array(allocator);
                    misc.bitset_set_lenrange(bitset.blocks_as(.bitset), min, max - min);
                    bitset.data.cardinality = @intCast(union_cardinality);
                    return bitset;
                }
            },
            .run => {
                const runs = c.blocks_as(.run)[0..c.data.cardinality];
                const nruns_greater =
                    misc.rle16_count_greater(runs, @truncate(max));
                const nruns_less =
                    misc.rle16_count_less(runs[0 .. c.data.cardinality - nruns_greater], @truncate(min));
                const run_size_bytes =
                    (nruns_less + 1 + nruns_greater) * @sizeOf(root.Rle16);

                trace(@src(), "run run_size_bytes={}", .{run_size_bytes});
                if (run_size_bytes <= @sizeOf(root.Bitset)) {
                    try c.run_container_add_range_nruns(allocator, min, max, nruns_less, nruns_greater);
                    return c.*;
                }
                return c.container_from_run_range(allocator, min, max);
            },
            else => unreachable,
        }
    }

    /// Adds all values in range [min,max] using hint:
    ///   nvals_less is the number of array values less than $min
    ///   nvals_greater is the number of array values greater than $max
    pub fn array_container_add_range_nvals(
        ac: *Container,
        allocator: Allocator,
        min: u32,
        max: u32,
        nvals_less: u32,
        nvals_greater: u32,
    ) !void {
        const union_cardinality = nvals_less + (max - min + 1) + nvals_greater;
        // trace(@src(), "union_cardinality={} ac.calc_capacity()={}", .{ union_cardinality, ac.calc_capacity() });
        if (union_cardinality > ac.calc_capacity()) {
            try ac.array_container_grow(allocator, union_cardinality, true);
        }
        const array = ac.blocks_as(.array)[0..union_cardinality];
        @memmove(
            array.ptr + union_cardinality - nvals_greater,
            (array.ptr + ac.data.cardinality - nvals_greater)[0..nvals_greater],
        );
        for (0..max - min + 1) |i| {
            array[nvals_less + i] = @intCast(min + i);
        }
        ac.data.cardinality = @intCast(union_cardinality);
    }

    /// The new container contains the range [start,stop).
    /// It is required that stop>start, the caller is responsible for this check.
    /// It is required that stop <= (1<<16), the caller is responsibe for this
    /// check. The cardinality of the created container is stop - start.
    pub fn create_range(
        allocator: Allocator,
        tc: Typecode,
        start: u32,
        stop: u32,
    ) !Container {
        switch (tc) {
            .run => {
                const c = try run_container_create_given_capacity(allocator, 1);
                c.append_first(Rle16{
                    .value = @truncate(start),
                    .length = @truncate(stop - start - 1),
                });
                return c;
            },
            .array => {
                var c = try array_container_create_given_capacity(allocator, stop - start);
                const array = c.blocks_as(.array);
                var k: u32 = @intCast(start);
                while (k < stop) : (k += 1) {
                    array[c.data.cardinality] = @intCast(k);
                    c.data.cardinality += 1;
                }
                return c;
            },
            .bitset => unreachable,
            .shared => unreachable,
        }
    }

    /// make a container with a run of ones
    ///
    /// initially always use a run container, even if an array might be marginally
    /// smaller
    pub fn range_of_ones(
        allocator: Allocator,
        range_start: u32,
        range_end: u32,
    ) !Container {
        assert(range_end >= range_start);
        const card = range_end - range_start + 1;
        return if (card <= 2)
            try create_range(allocator, .array, range_start, range_end)
        else
            try create_range(allocator, .run, range_start, range_end);
    }

    /// Create a container with all the values between in [min,max) at a
    /// distance k*step from min.
    pub fn from_range(
        allocator: Allocator,
        min: u32,
        max: u32,
        step: u16,
    ) !Container {
        // trace(@src(), "{}-{} step {}", .{ min, max, step });
        if (step == 0) return uninit; // being paranoid
        if (step == 1) {
            return try range_of_ones(allocator, min, max);
        }
        const size = (max - min + step - 1) / step;
        if (size <= C.DEFAULT_MAX_SIZE) { // array container
            unreachable;
        } else { // bitset container
            unreachable;
        }
    }
};

/// For bitset and array containers this is the index of the bit / entry.
/// For run containers this points at the run.
pub const Iterator = struct { index: u32 };

/// Returns the index of the first element >= x, or -1 if not found.
fn bitset_container_index_equalorlarger(words: [*]align(C.BLOCK_ALIGN) const u64, x: u16) i32 {
    var k: u32 = x / 64;
    var word = words[k] >> @as(u6, @intCast(x % 64)) << @as(u6, @intCast(x % 64));
    while (word == 0) {
        k += 1;
        if (k == C.BITSET_CONTAINER_SIZE_IN_WORDS) return -1;
        word = words[k];
    }
    return @intCast(k * 64 + @ctz(word));
}

/// Returns the index of the first element >= x, or -1 if not found.
fn array_container_index_equalorlarger(array: [*]align(C.BLOCK_ALIGN) const u16, cardinality: u32, x: u16) i32 {
    const idx = misc.binarySearch(array[0..cardinality], x);
    if (idx >= 0) return idx;
    const candidate = -idx - 1;
    if (candidate < cardinality) return candidate;
    return -1;
}

/// Returns the index of the first element >= x, or -1 if not found.
fn run_container_index_equalorlarger(runs: [*]align(C.BLOCK_ALIGN) const Rle16, n_runs: u32, x: u16) i32 {
    var idx = misc.interleavedBinarySearch(runs[0..n_runs], x);
    if (idx >= 0) return idx;
    idx = -idx - 2;
    if (idx != -1) {
        const offset = x - runs[@intCast(idx)].value;
        const le = runs[@intCast(idx)].length;
        if (offset <= le) return idx;
    }
    idx += 1;
    if (idx < n_runs) return idx;
    return -1;
}

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const root = @import("root.zig");
const flexible = @import("flexible");
const Block = root.Block;
const Typecode = root.Typecode;
const Bitmap = root.Bitmap;
const Rle16 = root.Rle16;
const C = @import("constants.zig");
const misc = @import("misc.zig");
const trace = misc.trace;
const builtin = @import("builtin");
const math = std.math;
