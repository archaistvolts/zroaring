/// a tagged pointer
pub const Container = packed struct(usize) {
    /// lower 2 bits
    typecode: Typecode,
    /// upper 62 bits on 64 bit platforms
    address: Address,

    pub const MAX_CARDINALITY = 0x10000;
    pub const zero = mem.zeroes(Container);

    const Address = @Type(.{ .int = .{
        .bits = @bitSizeOf(usize) - @bitSizeOf(Typecode),
        .signedness = .unsigned,
    } });

    pub fn init(c: anytype) Container {
        const address = @intFromPtr(c);
        assert(@typeInfo(Typecode).@"enum".fields.len == 4);
        assert(address & 0b11 == 0);
        return .{
            .typecode = Typecode.fromType(@TypeOf(c.*)),
            .address = @intCast(address >> 2),
        };
    }

    /// c must be a container type such as ArrayContainer
    pub fn create_from_value(allocator: mem.Allocator, c: anytype) !Container {
        const T = @TypeOf(c);
        return switch (T) {
            ArrayContainer, BitsetContainer, RunContainer, SharedContainer => {
                const ret = try allocator.create(T);
                ret.* = c;
                return .init(ret);
            },
            else => unreachable, // non container type
        };
    }

    pub fn deinit(c: Container, allocator: mem.Allocator) void {
        switch (c.typecode) {
            inline else => |t| {
                c.mut_cast(t).deinit(allocator);
                allocator.destroy(c.mut_cast(t));
            },
        }
    }

    pub fn ptr(c: Container) *anyopaque {
        return @ptrFromInt(@as(usize, c.address) << 2);
    }

    pub fn is_null(c: Container) bool {
        return c == mem.zeroes(Container);
    }

    pub fn get_cardinality(c: Container) u64 {
        return switch (c.typecode) {
            inline else => |t| c.const_cast(t).cardinality,
            .run => c.const_cast(.run).get_cardinality_scalar(), // TODO avx2, avx512
            .shared => unreachable, // TODO
        };
    }

    pub fn get_container_type(c: Container) Typecode {
        return if (c.typecode == .shared)
            c.const_cast(.shared).container.typecode
        else
            c.typecode;
    }

    ///
    /// Get the container size in bytes under portable serialization (see
    /// container_write), requires a
    /// typecode
    ///
    pub fn size_in_bytes(c: Container) usize {
        const ret = switch (c.typecode) {
            inline else => |t| c.unwrap_shared().const_cast(t).size_in_bytes(),
        };
        // std.debug.print("Container.size_in_bytes {t} {}\n", .{ c.typecode, ret });
        return ret;
    }

    pub fn unwrap_shared(candidate_shared_container: Container) Container {
        // /* access to container underneath */
        // static inline const container_t *container_unwrap_shared(
        // const container_t *candidate_shared_container, uint8_t *type) {
        if (candidate_shared_container.typecode == .shared) {
            assert(candidate_shared_container.const_cast(.shared).container.typecode != .shared);
            return candidate_shared_container.const_cast(.shared).container;
        } else {
            return candidate_shared_container;
        }
    }

    // /* access to container underneath, cloning it if needed */
    pub fn get_writable_copy_if_shared(c: Container) Container {
        if (c.typecode == .shared) { // shared, return enclosed container
            // return shared_container_extract_copy(CAST_shared(c), type);
            unreachable; // TODO
        } else {
            return c; // not shared, so return as-is
        }
    }

    pub fn const_cast(c: Container, comptime typecode: Typecode) *const typecode.Type() {
        return @ptrCast(@alignCast(c.ptr()));
    }

    pub fn mut_cast(c: Container, comptime typecode: Typecode) *typecode.Type() {
        return @ptrCast(@alignCast(c.ptr()));
    }

    pub fn add(c: Container, allocator: mem.Allocator, val: u16) !Container {
        // TODO // const c = get_writable_copy_if_shared(c, &typecode);
        switch (c.typecode) {
            .bitset => {
                _ = c.mut_cast(.bitset).set(val);
                return c;
            },
            .array => {
                const ac = c.mut_cast(.array);
                const ok = try ac.try_add(allocator, val, C.DEFAULT_MAX_SIZE) != .not_added;
                if (ok) return .init(ac);

                const bitset = try allocator.create(BitsetContainer);
                errdefer allocator.destroy(bitset);
                bitset.* = try ac.bitset_container_from_array(allocator);
                _ = bitset.set(val);
                return .init(bitset);
            },
            .run => {
                unreachable;
                // per Java, no container type adjustments are done (revisit?)
                // run_container_add(CAST_run(c), val);
                // *new_typecode = .run;
                // return c;
            },
            .shared => unreachable, // TODO
        }
    }

    pub fn add_assume_capacity(c: Container, hb: u16, typecode: Typecode) void {
        _ = hb;
        _ = typecode;
        _ = c;
        unreachable; // TODO
    }

    ///
    /// Writes the underlying array to buf, outputs how many bytes were written.
    /// This is meant to be byte-by-byte compatible with the Java and Go versions of
    /// Roaring.
    /// The number of bytes written should be
    /// container_write(container, buf).
    ///
    pub fn write(c: Container, w: *Io.Writer) !usize {
        const c1 = c.unwrap_shared();
        return switch (c1.typecode) {
            inline else => |t| try c1.const_cast(t).write(w),
            .shared => unreachable, // TODO
        };
    }

    pub fn contains(c: Container, val: u16) bool {
        const c1 = c.unwrap_shared();
        const ret = switch (c1.typecode) {
            inline else => |t| c1.const_cast(t).contains(val),
            .shared => unreachable, // TODO
        };
        // std.debug.print("Container.contains({}) {t} {}\n", .{ val, c1.typecode, ret });
        return ret;
    }

    pub fn equals(c1: Container, c2: Container) bool {
        const c1u = c1.unwrap_shared();
        const c2u = c2.unwrap_shared();

        return switch (c1u.typecode.pair(c2u.typecode)) { // PAIR_CONTAINER_TYPES(type1, type2)) {
            Typecode.pair(.bitset, .bitset) => c1u.const_cast(.bitset)
                .equals(c2u.const_cast(.bitset)),
            Typecode.pair(.array, .array) => c1u.const_cast(.array)
                .equals(c2u.const_cast(.array)),
            else => {
                std.debug.print("Conatiner.equals(). TODO pair ({t}, {t})\n", .{ c1u.typecode, c2u.typecode });
                unreachable;
            },
            //     case CONTAINER_PAIR(BITSET, BITSET):
            //         return bitset_container_equals(const_CAST_bitset(c1),
            //                                        const_CAST_bitset(c2));

            //     case CONTAINER_PAIR(BITSET, RUN):
            //         return run_container_equals_bitset(const_CAST_run(c2),
            //                                            const_CAST_bitset(c1));

            //     case CONTAINER_PAIR(RUN, BITSET):
            //         return run_container_equals_bitset(const_CAST_run(c1),
            //                                            const_CAST_bitset(c2));

            //     case CONTAINER_PAIR(BITSET, ARRAY):
            //         // java would always return false?
            //         return ArrayContainer.equal_bitset(const_CAST_array(c2),
            //                                             const_CAST_bitset(c1));

            //     case CONTAINER_PAIR(ARRAY, BITSET):
            //         // java would always return false?
            //         return ArrayContainer.equal_bitset(const_CAST_array(c1),
            //                                             const_CAST_bitset(c2));

            //     case CONTAINER_PAIR(ARRAY, RUN):
            //         return run_container_equals_array(const_CAST_run(c2),
            //                                           const_CAST_array(c1));

            //     case CONTAINER_PAIR(RUN, ARRAY):
            //         return run_container_equals_array(const_CAST_run(c1),
            //                                           const_CAST_array(c2));

            //     case CONTAINER_PAIR(ARRAY, ARRAY):
            //         return ArrayContainer.equals(const_CAST_array(c1),
            //                                       const_CAST_array(c2));

            //     case CONTAINER_PAIR(RUN, RUN):
            //         return run_container_equals(const_CAST_run(c1), const_CAST_run(c2));

            //     default:
            //         assert(false);
            //         roaring_unreachable;
            //         return false;
            // }
        };
    }

    ///
    ///Create new container which is a union of run container and
    ///range [min, max]. Caller is responsible for freeing run container.
    ///
    pub fn from_run_range(run: *const RunContainer, min: u32, max: u32) Container {
        _ = run; // autofix
        _ = min; // autofix
        _ = max; // autofix
        unreachable;
    }

    ///
    /// Add all values in range [min, max] to a given container.
    ///
    /// If the returned pointer is different from $container, then a new container
    /// has been created and the caller is responsible for freeing it.
    /// The type of the first container may change. Returns the modified
    /// (and possibly new) container.
    ///
    pub fn add_range(c: Container, allocator: mem.Allocator, min: u32, max: u32) !Container {
        // NB: when selecting new container type, we perform only inexpensive checks
        switch (c.typecode) {
            .bitset => {
                const bitset = c.mut_cast(.bitset);

                var union_cardinality: u32 = 0;
                union_cardinality += bitset.cardinality;
                union_cardinality += max - min + 1;
                union_cardinality -=
                    BitsetContainer.lenrange_cardinality(bitset.words, min, max - min);

                if (union_cardinality == MAX_CARDINALITY) {
                    return try create_from_value(allocator, try RunContainer.create_range(allocator, 0, MAX_CARDINALITY));
                } else {
                    BitsetContainer.set_lenrange(bitset.words, min, max - min);
                    bitset.cardinality = union_cardinality;
                    return c;
                }
            },
            .array => {
                const array = c.mut_cast(.array);
                const nvals_greater =
                    misc.count_greater(array.slice(), @truncate(max));
                const nvals_less =
                    misc.count_less(array.slice()[0 .. array.cardinality - nvals_greater], @truncate(min));
                const union_cardinality =
                    nvals_less + (max - min + 1) + nvals_greater;

                if (union_cardinality == MAX_CARDINALITY) {
                    return try create_from_value(allocator, try RunContainer.create_range(allocator, 0, MAX_CARDINALITY));
                } else if (union_cardinality <= C.DEFAULT_MAX_SIZE) {
                    try array.add_range_nvals(allocator, min, max, nvals_less, nvals_greater);
                    return c;
                } else {
                    var bitset = try array.to_bitset_container(allocator);
                    BitsetContainer.set_lenrange(bitset.words, min, max - min);
                    bitset.cardinality = union_cardinality;
                    return try create_from_value(allocator, bitset);
                }
            },
            .run => {
                const run = c.mut_cast(.run);
                const nruns_greater =
                    misc.rle16_count_greater(run.slice(), @truncate(max));
                const nruns_less =
                    misc.rle16_count_less(run.runs[0 .. run.n_runs - nruns_greater], @truncate(min));

                const run_size_bytes =
                    (nruns_less + 1 + nruns_greater) * @sizeOf(root.Rle16);
                const bitset_size_bytes =
                    BitsetContainer.SIZE_IN_WORDS * @sizeOf(u64);

                if (run_size_bytes <= bitset_size_bytes) {
                    try run.add_range_nruns(allocator, min, max, nruns_less, nruns_greater);
                    return c;
                } else {
                    return from_run_range(run, min, max);
                }
            },
            .shared => unreachable, // TODO
        }
    }

    ///
    /// make a container with a run of ones
    ///
    /// initially always use a run container, even if an array might be
    /// marginally smaller
    pub fn range_of_ones(allocator: mem.Allocator, range_start: u32, range_end: u32) !Container {
        assert(range_end >= range_start);
        const cardinality = range_end - range_start + 1;
        return try if (cardinality <= 2)
            create_from_value(allocator, try ArrayContainer.create_range(allocator, range_start, range_end))
        else
            create_from_value(allocator, try RunContainer.create_range(allocator, range_start, range_end));
    }

    /// Create a container with all the values between in [min,max) at a
    /// distance k*step from min.
    pub fn from_range(allocator: mem.Allocator, min: u32, max: u32, step: u16) !Container {
        if (step == 0) return .zero; // being paranoid
        if (step == 1) {
            return try range_of_ones(allocator, min, max);
        }
        const size = (max - min + step - 1) / step;
        if (size <= C.DEFAULT_MAX_SIZE) { // array container

            const array = try ArrayContainer.create_with_capacity(allocator, size);
            try array.add_from_range(allocator, min, max, step);
            assert(array.cardinality == size);
            return try create_from_value(allocator, array);
        } else { // bitset container
            var bitset = try BitsetContainer.create(allocator);
            bitset.add_range(min, max, step);
            assert(bitset.cardinality == size);
            return try create_from_value(allocator, bitset);
        }
    }

    pub fn format(c: Container, w: *Io.Writer) !void {
        std.debug.print("{x}-{x}", .{ @intFromEnum(c.typecode), c.address });
        switch (c.typecode) {
            inline else => |tag| {
                try w.print("{t} ", .{tag});
                try c.const_cast(tag).format(w);
            },
        }
    }
};

pub const BitsetContainer = @import("WordBitset.zig").WordBitset(.{});

pub const RunContainer = struct {
    runs: [*]Rle16,
    n_runs: u32,
    capacity: u32,

    pub const Rle16 = struct { value: u16, length: u16 };

    pub fn create(allocator: mem.Allocator) !RunContainer {
        return try create_with_capacity(allocator, 0);
    }
    pub fn create_with_capacity(allocator: mem.Allocator, size: u32) !RunContainer {
        return .{ .runs = (try allocator.alloc(Rle16, size)).ptr, .capacity = size, .n_runs = 0 };
    }
    ///
    /// The new container consists of a single run [start,stop).
    /// It is required that stop>start, the caller is responsability for this check.
    /// It is required that stop <= (1<<16), the caller is responsability for this
    /// check. The cardinality of the created container is stop - start. Returns NULL
    /// on failure
    ///
    pub fn create_range(allocator: mem.Allocator, start: u32, stop: u32) !RunContainer {
        var rc = try create_with_capacity(allocator, 1);
        _ = rc.append_first(.{ .value = @intCast(start), .length = @intCast(stop - start - 1) });
        return rc;
    }
    pub fn deinit(r: RunContainer, allocator: mem.Allocator) void {
        allocator.free(r.runs[0..r.capacity]);
    }
    ///
    /// Like run_container_append but it is assumed that the content of run is empty.
    ///
    pub fn append_first(run: *RunContainer, vl: Rle16) Rle16 {
        run.runs[run.n_runs] = vl;
        run.n_runs += 1;
        return vl;
    }
    pub fn serialized_size_in_bytes(r: RunContainer) usize {
        return @sizeOf(u16) + @sizeOf(Rle16) * r.n_runs; // each run requires 2 2-byte entries.
    }
    pub fn size_in_bytes(r: RunContainer) usize {
        return r.serialized_size_in_bytes();
    }
    pub fn write(r: RunContainer, w: *Io.Writer) !usize {
        _ = r;
        _ = w;
        unreachable;
    }
    pub fn contains(r: RunContainer, pos: u16) bool {
        var index = misc.interleavedBinarySearch(r.slice(), pos);
        // std.debug.print("RunContainer.contains pos {} index {}\n", .{pos, index});
        if (index >= 0) return true;
        index = -index - 2; // points to preceding value, possibly -1
        if (index != -1) { // possible match
            const offset = pos - r.runs[@intCast(index)].value;
            const le = r.runs[@intCast(index)].length;
            if (offset <= le) return true;
        }
        return false;
    }
    pub fn read(r: *RunContainer, allocator: mem.Allocator, n_runs: u32, ior: *Io.Reader) !usize {
        if (n_runs > r.capacity) {
            try r.grow(allocator, n_runs, false);
        }
        r.n_runs = n_runs;
        // std.debug.print("RunContainer.read() r {any}\n", .{r});
        try ior.readSliceEndian(Rle16, r.slice(), .little);
        return r.size_in_bytes();
    }
    pub fn grow(r: *RunContainer, allocator: mem.Allocator, min: u32, copy: bool) !void {
        var newCapacity = if (r.capacity == 0)
            0
        else if (r.capacity < 64)
            r.capacity * 2
        else if (r.capacity < 1024)
            r.capacity * 3 / 2
        else
            r.capacity * 5 / 4;
        if (newCapacity < min) newCapacity = min;
        // std.debug.print("RunContainer.grow({}) newCapacity {}\n", .{ min, newCapacity });
        r.capacity = newCapacity;
        assert(r.capacity >= min);
        if (copy) {
            const oldruns = r.slice();
            r.runs = (try allocator.realloc(oldruns, r.capacity)).ptr;
        } else {
            allocator.free(r.slice());
            r.runs = (try allocator.alloc(Rle16, r.capacity)).ptr;
        }
        // We may have run.runs == NULL.
    }
    pub fn slice(c: RunContainer) []Rle16 {
        return c.runs[0..c.n_runs];
    }
    /// Get the cardinality of `run'. Requires an actual computation.
    pub fn get_cardinality_scalar(run: RunContainer) u64 {
        var sum = run.n_runs; // start at n_runs to skip +1 for each pair.
        for (0..run.n_runs) |k| sum += run.runs[k].length;
        return sum;
    }
    ///
    /// Moves the data so that we can write data at index
    ///
    fn makeRoomAtIndex(run: *RunContainer, allocator: mem.Allocator, index: u0) !void {
        // static inline void makeRoomAtIndex(run_container_t *run, uint16_t index) {
        // This function calls realloc + memmove sequentially to move by one index.
        // Potentially copying twice the array.
        //
        if (run.n_runs + 1 > run.capacity)
            try run.grow(allocator, run.n_runs + 1, true);
        const len = run.n_runs - index;
        @memmove(
            (run.runs + 1 + index)[0..len],
            (run.runs + index)[0..len],
        );
        run.n_runs += 1;
    }

    ///
    /// Add all values in range [min, max] using hint.
    ///
    pub fn add_range_nruns(run: *RunContainer, allocator: mem.Allocator, min: u32, max: u32, nruns_less: u32, nruns_greater: u32) !void {
        const nruns_common = run.n_runs - nruns_less - nruns_greater;
        if (nruns_common == 0) {
            try run.makeRoomAtIndex(allocator, @truncate(nruns_less));
            run.runs[nruns_less].value = @truncate(min);
            run.runs[nruns_less].length = @truncate(max - min);
        } else {
            const common_min = run.runs[nruns_less].value;
            const common_max = run.runs[nruns_less + nruns_common - 1].value +
                run.runs[nruns_less + nruns_common - 1].length;
            const result_min = if (common_min < min) common_min else min;
            const result_max = if (common_max > max) common_max else max;

            run.runs[nruns_less].value = @truncate(result_min);
            run.runs[nruns_less].length = @truncate(result_max - result_min);

            @memmove(
                run.runs[nruns_less + 1 ..][0..nruns_greater],
                run.runs[run.n_runs - nruns_greater ..][0..nruns_greater],
            );
            run.n_runs = nruns_less + 1 + nruns_greater;
        }
    }

    pub fn format(c: RunContainer, w: *Io.Writer) !void {
        try w.print("RunConatiner values {any}", .{c.slice()});
    }
};

pub const SharedContainer = extern struct {
    container: Container,
    /// to be managed atomically // TODO
    refcount: std.atomic.Value(u32),
    pub fn deinit(r: SharedContainer, allocator: mem.Allocator) void {
        r.container.deinit(allocator);
    }
    pub fn size_in_bytes(s: SharedContainer) usize {
        return s.container.size_in_bytes();
    }
    pub fn format(c: SharedContainer, w: *Io.Writer) error{WriteFailed}!void {
        try w.print("SharedContainer ", .{});
        try c.container.format(w);
    }
};

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Io = std.Io;
const root = @import("root.zig");
const Typecode = root.Typecode;
const ArrayContainer = root.ArrayContainer;
const Array = root.Array;
const misc = @import("misc.zig");
const C = @import("constants.zig");
