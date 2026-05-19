const Bitmap = @This();

/// header, keys, containers and container storage blocks in a single allocation.
array: *flexible.Struct(Array),

pub const Array = extern struct {
    /// container count. [0, 1<<16].
    len: u32 align(C.BLOCK_ALIGN),
    /// container capacity. [0, 1<<16].
    capacity: u32,
    /// blocks count. [0, 1<<24]
    blockslen: u32,
    /// blocks capacity. [0, 1<<24]
    blockscapacity: u32,
    magic: root.Magic,
    /// an extern compatible `std.enums.EnumSet(Flag)`
    flags: u8,
    /// container keys.
    keys: flexible.Array(u16, .capacity) align(C.BLOCK_ALIGN),
    /// container descriptors.
    containers: flexible.Array(Container, .capacity) align(C.BLOCK_ALIGN),
    /// storage for container data.
    blocks: flexible.Array(Block, .blockscapacity),
};

pub fn addBlocksAssumeCapacity2(r: Bitmap, n: u32) []Block {
    assert(r.array.ptr(.blockslen).* + n <= r.array.ptr(.blockscapacity).*);
    const ret = r.array.ptr(.blocks)[r.array.ptr(.blockslen).*..][0..n];
    r.array.ptr(.blockslen).* += n;
    return ret;
}

const Model = flexible.Struct(Array);
const emptybuf: Model.Buf(.{ .capacity = 0, .blockscapacity = 0 }) align(C.BLOCK_ALIGN) = @splat(0);
pub const empty: Bitmap = .{ .array = @ptrCast(@constCast(&emptybuf)) };

pub const Flag = enum(u8) { cow, frozen };

pub fn deinit(r: *Bitmap, allocator: mem.Allocator) void {
    if (r.is_empty()) return;
    r.array.destroy(allocator);
    r.array = empty.array;
}

pub fn is_empty(r: Bitmap) bool {
    return r.array == empty.array;
}

fn zero_init(m: *Model) void {
    m.ptr(.len).* = 0;
    m.ptr(.blockslen).* = 0;
    m.ptr(.magic).* = .SERIAL_COOKIE_NO_RUNCONTAINER;
    m.ptr(.flags).* = 0;
    @memset(m.slice(.containers), .uninit);
}

pub fn create_with_capacity(allocator: mem.Allocator, container_count: u32) !Bitmap {
    const capacity = try std.math.ceilPowerOfTwo(u32, @max(16, container_count));
    const m = try Model.create(allocator, .{
        .capacity = capacity,
        .blockscapacity = capacity,
    });
    zero_init(m);
    return .{ .array = m };
}

pub fn slice(
    r: anytype,
    comptime field: Model.Field,
    comptime len_field: Model.Field,
) Model.SliceOf(@TypeOf(r.array), field) {
    if (r.array.ptr(.len).* == 0) return &.{};
    return r.array.ptr(field)[0..r.array.ptr(len_field).*];
}

pub fn can_have_run_containers(h: Bitmap) bool {
    if (h.is_empty()) return false;
    return h.array.ptr(.magic).* == .SERIAL_COOKIE;
}

pub const Info = struct { cookie: root.Cookie, len: u32 };

/// read how many bytes are needed to store array slices (not including `@sizeOf(Array)`).
pub fn info_from_file(io: Io, bitmap_file: Io.File) !Info {
    var read_buf: [8]u8 = undefined;
    var freader = bitmap_file.reader(io, &read_buf);
    return info_from_file_reader(&freader);
}

/// reads only the first 2 fields, cookie and len.
/// advances `freader` by 4 bytes or 8 bytes when `magic` == `SERIAL_COOKIE`.
pub fn info_from_file_reader(freader: *Io.File.Reader) !Info {
    assert(freader.logicalPos() == 0);
    const r = &freader.interface;
    const cookie = try r.takeStruct(root.Cookie, .little);
    if (cookie.magic != .SERIAL_COOKIE and
        cookie.magic != .SERIAL_COOKIE_NO_RUNCONTAINER)
        return error.UnexpectedCookie;

    const len = if (cookie.magic == .SERIAL_COOKIE)
        @as(u32, cookie.cardinality_minus1) + 1
    else
        try r.takeInt(u32, .little);

    return .{ .cookie = cookie, .len = len };
}

/// Allocates and returns a Bitmap, read from `bitmap_file` which must be a
/// seekable file. `read_buf` is a temporary buffer.
/// TODO non-seekable files.
pub fn portable_deserialize(
    allocator: mem.Allocator,
    io: Io,
    bitmap_file: Io.File,
    read_buf: []u8,
) !Bitmap {
    var freader = bitmap_file.reader(io, read_buf);

    const ainfo = try info_from_file_reader(&freader);
    trace(@src(), "{}", .{ainfo});

    const lengths = Model.Lengths{
        .capacity = ainfo.len,
        .blockscapacity = ainfo.len * C.BITSET_BLOCKS,
    };
    trace(@src(), "{}", .{lengths});
    const m = try Model.create(allocator, lengths);
    errdefer m.destroy(allocator);
    var ret: Bitmap = .{ .array = m };
    ret.array.ptr(.magic).* = ainfo.cookie.magic;
    ret.array.ptr(.len).* = ainfo.len;
    ret.array.ptr(.flags).* = 0;

    var run_flags: root.RunFlags = undefined;
    try ret.deserialize_file_reader(&freader, &run_flags);
    assert(freader.logicalPos() == ret.portable_size());

    const r = &freader.interface;
    const containers = ret.array.ptr(.containers);
    const blocks: [*]Block = ret.array.ptr(.blocks);
    var curblock = blocks;
    for (0..ret.array.ptr(.len).*) |k| { // read container data
        const c = &containers[k];
        const thiscard = c.cardinality;
        var isbitset = (thiscard > C.DEFAULT_MAX_SIZE);
        var isrun = false;
        if (ret.can_have_run_containers() and
            ((run_flags[k / 8] & @as(u8, 1) << @truncate(k % 8))) != 0)
        {
            isbitset = false;
            isrun = true;
        }
        if (isbitset) {
            try r.readSliceAll(mem.asBytes(curblock[0..C.BITSET_BLOCKS]));
            c.* = .{
                .typecode = .bitset,
                .cardinality = thiscard,
                .blockoffset = @intCast(curblock - blocks),
                .nblocks_minus1 = C.BITSET_BLOCKS - 1,
            };
            curblock += C.BITSET_BLOCKS;
        } else if (isrun) {
            const nruns: u32 = try r.takeInt(u16, .little);
            const nblocks = misc.numGroupsOfSize(nruns * @sizeOf(Rle16), C.BLOCK_SIZE);
            const runs = misc.asSlice([]align(C.BLOCK_ALIGN) Rle16, curblock[0..nblocks]);
            try r.readSliceEndian(Rle16, runs[0..nruns], .little);
            c.* = .{
                .typecode = .run,
                .cardinality = @intCast(nruns),
                .blockoffset = @intCast(curblock - blocks),
                .nblocks_minus1 = @intCast(nblocks - 1),
            };
            curblock += @intCast(nblocks);
        } else { // array container
            const nblocks = misc.numGroupsOfSize(thiscard * @sizeOf(u16), C.BLOCK_SIZE);
            const values = misc.asSlice([]align(C.BLOCK_ALIGN) u16, curblock[0..nblocks]);
            try r.readSliceEndian(u16, values[0..thiscard], .little);
            c.* = .{
                .typecode = .array,
                .cardinality = thiscard,
                .blockoffset = @intCast(curblock - blocks),
                .nblocks_minus1 = @intCast(nblocks - 1),
            };
            curblock += @intCast(nblocks);
        }
    }

    assert(freader.size == null or freader.atEnd());
    const blockslen = curblock - blocks;
    ret.array.ptr(.blockslen).* = @intCast(blockslen);

    trace(@src(), "{f}", .{ret});
    assert(ret.array.ptr(.blockslen).* <= ret.array.ptr(.blockscapacity).*);

    // FIXME - portable_size_in_bytes() doesn't match logicalPos() on testdatawithruns - 48056 48050
    if (freader.logicalPos() != ret.portable_size_in_bytes()) {
        // trace(@src(), "Error: readerpos={} portablesize={}", .{ freader.logicalPos(), ret.portable_size_in_bytes() });
        // assert(false);
    }

    return ret;
}

/// read/write all header cardinalities and keys along with run_flags
/// when present.  stops before container data.
pub fn deserialize_file_reader(
    rb: Bitmap,
    freader: *Io.File.Reader,
    run_flags: ?*root.RunFlags,
) !void {
    const array = rb.array;
    const magic = array.ptr(.magic).*;
    assert(magic == .SERIAL_COOKIE or magic == .SERIAL_COOKIE_NO_RUNCONTAINER); // TODO
    const len = array.ptr(.len).*;
    assert(len <= C.MAX_KEY_CARDINALITY); // data must be corrupted
    const r = &freader.interface;
    const hasruns = magic == .SERIAL_COOKIE;

    if (hasruns) {
        try r.readSliceAll(run_flags.?[0 .. (len + 7) / 8]);
    }

    for (rb.slice(.keys, .len), rb.slice(.containers, .len)) |*k, *c| { // TODO maybe read N key_cards at a time, less looping here
        const kc = try r.takeStruct(root.KeyCard, .little);
        k.* = kc.key;
        c.cardinality = @as(u30, kc.cardinality_minus1) + 1;
    }

    // skip file offsets
    if (!hasruns or (hasruns and len >= C.NO_OFFSET_THRESHOLD))
        _ = try r.discard(.limited(len * @sizeOf(u32)));

    assert(freader.logicalPos() == rb.portable_size());
}

pub fn insert_new_kv_at(r: *Bitmap, allocator: mem.Allocator, key: u16, c: Container, i: u32) !void {
    try r.extend_array(allocator, 1, 1);
    const ks = r.array.ptr(.keys);
    const cs = r.array.ptr(.containers);
    const len = r.array.ptr(.len).*;
    @memmove(ks + i + 1, ks[i..len]);
    ks[i] = key;
    @memmove(cs + i + 1, cs[i..len]);
    // trace(@src(), "{}", .{c});
    cs[i] = c;
    r.array.ptr(.len).* += 1;
    r.array.ptr(.blockslen).* += 1;
}

/// returns count of `vals` added
pub fn add_many(r: *Bitmap, allocator: mem.Allocator, vals: []const u32) !usize {
    // TODO estimate how many containers and blocks are needed, preallocate and then use assume capacity api.
    trace(@src(), "vals {?}..{?}:{}", .{ if (vals.len > 0) vals[0] else null, if (vals.len > 1) vals[vals.len - 1] else null, vals.len });
    var ret: usize = 0;
    for (vals) |v| {
        ret += @intFromBool(try r.add_checked(allocator, v));
    }
    return ret;
}

pub fn add(r: *Bitmap, allocator: mem.Allocator, val: u32) !void {
    _ = try r.add_checked(allocator, val);
}

/// returns true when `value` was added to the bitmap, false if already present.
pub fn add_checked(r: *Bitmap, allocator: mem.Allocator, value: u32) !bool {
    if (r.is_empty()) {
        @branchHint(.unlikely);
        r.* = try create_with_capacity(allocator, 1);
    }

    const key: u16, const valuelow: u16 = .{ @truncate(value >> 16), @truncate(value) };
    const mcontaineridx = misc.binarySearch(r.slice(.keys, .len), key);
    if (mcontaineridx >= 0) { // key found
        const cid: u32 = @bitCast(mcontaineridx);
        const c: Container = r.array.ptr(.containers)[cid];

        // trace(@src(), "key found container={f} {any}", .{ c.fmt(r), c.blocks_as(.array, r)[0..card] });
        const c2 = try r.array.ptr(.containers)[cid].add(allocator, r, valuelow);
        if (c != c2) {
            // skip deinit of inplace array/bitset conversion
            if (c.blockoffset != c2.blockoffset) {
                r.array.ptr(.containers)[cid].deinit(allocator, r);
            }
            r.array.ptr(.containers)[cid] = c2;
        }
        return c.cardinality != r.array.ptr(.containers)[cid].cardinality;
    } else { // key not found, add new array container
        const cid: u32 = @intCast(-mcontaineridx - 1);
        // trace(@src(), "new container - cid={} {f}", .{ cid, r });
        const blockslen = r.array.ptr(.blockslen).*;
        const blockscapacity = r.array.ptr(.blockscapacity).*;
        const capacity = r.array.ptr(.capacity).*;
        var newac: Container = .{
            .blockoffset = @intCast(blockslen),
            .nblocks_minus1 = 0,
            .cardinality = 0,
            .typecode = .array,
        };
        if (r.array.ptr(.len).* == capacity) {
            try r.realloc_array(allocator, capacity + 1, blockscapacity + 1);
        }
        _ = try newac.add(allocator, r, valuelow);
        assert(newac.typecode == .array); // added 1 value to empty array, must remain an array
        try r.insert_new_kv_at(allocator, key, newac, cid);
        return true;
    }
}

pub fn container_create_given_capacity(
    r: *Bitmap,
    allocator: mem.Allocator,
    tc: Typecode,
    /// array.cardinality or run.nruns
    card_or_nruns: u32,
) !Container {
    const blockoffset = r.array.ptr(.blockslen).*;
    trace(@src(), "{t} card_or_nruns={}", .{ tc, card_or_nruns });

    const c = switch (tc) {
        .run => {
            const nblocks = misc.numGroupsOfSize(card_or_nruns * @sizeOf(Rle16), C.BLOCK_SIZE);

            try r.extend_array(allocator, 1, nblocks);

            return .{
                .typecode = .run,
                .cardinality = 0,
                .blockoffset = @intCast(blockoffset),
                .nblocks_minus1 = @intCast(nblocks - 1),
            };
        },
        .array => {
            const nblocks = misc.numGroupsOfSize(card_or_nruns * @sizeOf(u16), C.BLOCK_SIZE);
            try r.extend_array(allocator, 1, nblocks);
            return .{
                .typecode = .array,
                .cardinality = 0,
                .blockoffset = @intCast(blockoffset),
                .nblocks_minus1 = @intCast(nblocks - 1),
            };
        },
        .bitset => unreachable,
        .shared => unreachable,
    };

    return c;
}

fn append_first(r: Bitmap, c: *Container, container_value: anytype) void {
    switch (@TypeOf(container_value)) {
        Rle16 => {
            assert(c.typecode == .run);
            const runs = c.blocks_as(.run, r);
            runs[c.cardinality] = container_value;
            c.cardinality += 1;
        },
        u16 => {
            assert(c.typecode == .array);
            const values = c.blocks_as(.array, r);
            values[c.cardinality] = container_value;
            c.cardinality += 1;
        },
        else => unreachable, // unsupported type
    }
}

/// The new container consists of a single run [start,stop).
/// It is required that stop>start, the caller is responsible for this check.
/// It is required that stop <= (1<<16), the caller is responsibe for this
/// check. The cardinality of the created container is stop - start.
pub fn create_range(r: *Bitmap, allocator: mem.Allocator, tc: Typecode, start: u32, stop: u32) !Container {
    switch (tc) {
        .run => {
            var c = try r.container_create_given_capacity(allocator, tc, 1);
            r.append_first(&c, Rle16{
                .value = @truncate(start),
                .length = @truncate(stop - start - 1),
            });
            return c;
        },
        .array => unreachable,
        .bitset => unreachable,
        .shared => unreachable,
    }
}

/// make a container with a run of ones
///
/// initially always use a run container, even if an array might be marginally
/// smaller
pub fn range_of_ones(r: *Bitmap, allocator: mem.Allocator, range_start: u32, range_end: u32) !Container {
    assert(range_end >= range_start);
    const card = range_end - range_start + 1;
    trace(@src(), "{}-{}:{}", .{ range_start, range_end, card });
    return if (card <= 2)
        try r.create_range(allocator, .array, range_start, range_end)
    else
        try r.create_range(allocator, .run, range_start, range_end);
}

/// Create a container with all the values between in [min,max) at a
/// distance k*step from min.
pub fn from_range(r: *Bitmap, allocator: mem.Allocator, min: u32, max: u32, step: u16) !Container {
    // std.debug.print("Container.from_range {}-{} step {}\n", .{ min, max, step });
    if (step == 0) return .uninit; // being paranoid
    if (step == 1) {
        return try r.range_of_ones(allocator, min, max);
    }
    const size = (max - min + step - 1) / step;
    if (size <= C.DEFAULT_MAX_SIZE) { // array container
        unreachable;
        // var array = try ArrayContainer.init_with_capacity(allocator, size);
        // try array.add_from_range(allocator, min, max, step);
        // assert(array.cardinality == size);
        // return try create(allocator, array);
    } else { // bitset container
        unreachable;
        // var bitset = try BitsetContainer.create(allocator);
        // bitset.add_range(min, max, step);
        // assert(bitset.cardinality == size);
        // return try create(allocator, bitset);
    }
}

fn add_range_to_container(r: Bitmap, allocator: mem.Allocator, cid: u16, container_min: u32, container_max: u32) !Container {
    _ = r;
    _ = allocator;
    _ = cid;
    _ = container_min;
    _ = container_max;
    unreachable;
}

fn replace_key_and_container_at_index(r: Bitmap, i: u32, key: u16, c: Container) void {
    assert(i < r.array.ptr(.len).*);
    r.slice(.containers, .len)[i] = c;
    r.slice(.keys, .len)[i] = key;
}

/// Add all values in range [min, max]
pub fn add_range_closed(r: *Bitmap, allocator: mem.Allocator, min: u32, max: u32) !void {
    if (min > max) return;
    if (r.is_empty()) {
        @branchHint(.unlikely);
        r.* = try create_with_capacity(allocator, 0);
    }

    trace(@src(), "({},{}) len={}", .{ min, max, r.array.ptr(.len).* });

    const min_key = min >> 16;
    const max_key = max >> 16;
    const num_required_containers = max_key - min_key + 1;
    const suffix_length = misc.count_greater(r.slice(.keys, .len), @truncate(max_key));
    const prefix_length = misc.count_less(
        r.slice(.keys, .len)[0 .. r.array.ptr(.len).* - suffix_length],
        @truncate(min_key),
    );
    const common_length = r.array.ptr(.len).* - prefix_length - suffix_length;

    // trace(@src(), "num_required_containers={} prefix_length={} suffix_length={} common_length={}", .{ num_required_containers, prefix_length, suffix_length, common_length });
    if (num_required_containers > common_length) {
        try r.shift_tail(
            allocator,
            suffix_length,
            @bitCast(num_required_containers -% common_length),
        );
    }

    var src: i32 = @bitCast(prefix_length + common_length -% 1);
    var dst = r.array.ptr(.len).* - suffix_length -% 1;
    var key = max_key;
    trace(@src(), "dst={} src={} len={}", .{ dst, src, r.array.ptr(.len) });
    while (key +% 1 != min_key) : (key -%= 1) { // beware of min_key==0
        trace(@src(), "key {} min_key {} max_key {} dst={} h.ptr(.len)={}", .{ key, min_key, max_key, dst, r.array.ptr(.len) });
        const container_min = if (min_key == key) min & 0xffff else 0;
        const container_max = if (max_key == key) max & 0xffff else 0xffff;
        var newc: Container = .uninit;
        if (src > 0 and r.slice(.keys, .len)[@intCast(src)] == key) {
            // TODO // ra.unshare_container_at_index(srcu);
            newc = try r.add_range_to_container(allocator, @intCast(src), container_min, container_max);
            if (newc != r.array.ptr(.containers)[@intCast(src)]) {
                unreachable; // TODO r.deinit_container(allocator, srcu);
            }
            src -= 1;
        } else {
            newc = try r.from_range(allocator, container_min, container_max + 1, 1);
        }
        trace(@src(), "dst {}, newc {} {any}", .{ dst, newc, newc.blocks_as(.run, r.*)[0..newc.cardinality] });
        assert(newc != Container.uninit);
        r.replace_key_and_container_at_index(dst, @truncate(key), newc);
        dst -%= 1;
    }
}

/// Add all values in range [min, max)
pub fn add_range(r: *Bitmap, allocator: mem.Allocator, min: u64, max: u64) !void {
    trace(@src(), "{} {}", .{ min, max });
    if (max <= min or min > C.MAX_VALUE_CARDINALITY) {
        return;
    }
    try r.add_range_closed(allocator, @intCast(min), @intCast(max - 1));
}

pub fn contains(r: Bitmap, val: u32) bool {
    // trace(@src(), "{}/{} {*} {*}", .{ h.ptr(.len), h.capacity, h.containers, h.keys });
    const key: u16 = @truncate(val >> 16);
    // the next function call involves a binary search and lots of branching.
    // trace(@src(), "{any}", .{h.slice(.keys, .len)});
    const i = misc.binarySearch(r.slice(.keys, .len), key);
    if (i < 0) return false;
    const iu: u32 = @bitCast(i);

    // rest might be a tad expensive, possibly involving another round of binary search
    const c: Container = r.slice(.containers, .len)[iu];

    const pos: u16 = @truncate(val);
    switch (c.typecode) {
        .bitset => {
            const word_idx = pos / 64;
            const bit_idx = pos % 64;
            return (c.blocks_as(.bitset, r)[word_idx] & (@as(u64, 1) << @intCast(bit_idx))) != 0;
        },
        .array => {
            const values = c.blocks_as(.array, r)[0..c.cardinality];
            // trace(@src(), "{} {any}", .{ c, values });

            // binary search with fallback to linear search for short ranges
            var low: i32 = 0;
            var high = @as(i32, @intCast(c.cardinality)) - 1;
            while (high >= low + 16) {
                const middleIndex = (low + high) >> 1;
                const middleValue = values[@intCast(middleIndex)];
                if (middleValue < pos) {
                    low = middleIndex + 1;
                } else if (middleValue > pos) {
                    high = middleIndex - 1;
                } else {
                    return true;
                }
            }

            var j = low;
            while (j <= high) : (j += 1) {
                const v = values[@intCast(j)];
                if (v == pos) return true;
                if (v > pos) return false;
            }
            return false;
        },
        .run => {
            const runs = c.blocks_as(.run, r)[0..c.cardinality];
            var index = misc.interleavedBinarySearch(runs, pos);
            if (index >= 0) return true;
            index = -index - 2; // points to preceding value, possibly -1
            if (index != -1) { // possible match
                const offset = pos - runs[@intCast(index)].value;
                if (offset <= runs[@intCast(index)].length) return true;
            }
            return false;
        },
        .shared => unreachable,
    }
}

/// true if the two bitmaps contain the same elements.
pub fn equals(r1: Bitmap, r2: Bitmap) bool {
    // trace(@src(), "r1.header={}", .{r1.header});
    if (r1.is_empty()) return r2.is_empty();
    const h1 = r1.array;
    const h2 = r2.array;
    if (h1.ptr(.len).* != h2.ptr(.len).*)
        return false;

    for (r1.slice(.keys, .len), r2.slice(.keys, .len)) |k1, k2| {
        if (k1 != k2) return false;
    }

    for (
        r1.slice(.containers, .len),
        r2.slice(.containers, .len),
    ) |c1, c2| {
        // trace(@src(), "c1={}", .{c1});
        // trace(@src(), "c2={}", .{c2});
        if (!c1.equals(c2, r1, r2)) return false;
    }

    return true;
}

///
/// Get the index corresponding to a 16-bit key
///
pub fn get_index(r: Bitmap, v: u32) i32 {
    const key: u16 = @truncate(v >> 16);
    const h = r.array;
    const keys = r.slice(.keys, .len);
    if (h.ptr(.len).* == 0 or keys[h.ptr(.len).* - 1] == key)
        return @as(i32, @intCast(h.ptr(.len).* - 1));
    return misc.binarySearch(keys, key);
}

pub fn has_run_container(r: Bitmap) bool {
    // trace(@src(), "{f}", .{r});
    return for (r.slice(.containers, .len)) |c| {
        if (c.typecode == .run) break true;
    } else false;
}

/// depends only on `ra.len`.
pub fn portable_size_ext(ra: Bitmap, hasruns: bool) usize {
    const count = ra.array.ptr(.len).*;
    if (hasruns) {
        return 4 + (count + 7) / 8 +
            if (count < C.NO_OFFSET_THRESHOLD) // for small bitmaps, we omit the offsets
                4 * count
            else
                8 * count; // - 4 because we pack the size with the cookie
    } else {
        return 4 + 4 + 8 * count; // no run flags, u32 cardinality,
    }
}

/// file position where array data ends and container data starts.
/// depends only on `ra.magic` and `ra.len`.
pub fn portable_size(ra: Bitmap) usize {
    return ra.portable_size_ext(ra.can_have_run_containers());
}

/// file position where array data ends and container data starts.
/// depends on `ra.containers` being populated and checks if there are any
/// run containers present.
pub fn portable_header_size(ra: Bitmap) usize {
    return ra.portable_size_ext(ra.has_run_container());
}

/// `containers` must be populated such as after deserialize()
pub fn portable_size_in_bytes(ra: Bitmap) usize {
    var count = ra.portable_header_size();
    // trace(@src(), "portable_size_has_run={}", .{count});
    for (ra.slice(.containers, .len)) |c| {
        count += c.serialized_size_in_bytes();
        // trace(@src(), "serialized_size_in_bytes={}", .{c.serialized_size_in_bytes()});
    }
    return count;
}

/// Writes the container to `w`, returns how many bytes were written.
/// The number of bytes written should be equal to `portable_size_in_bytes()`.
pub fn write(r: Bitmap, c: Container, w: *Io.Writer) !usize {
    switch (c.typecode) {
        .array => {
            // std.debug.print("array card {}\n", .{ card });
            try w.writeSliceEndian(u16, c.blocks_as(.array, r)[0..c.cardinality], .little);
            return c.cardinality * @sizeOf(u16);
        },
        .run => {
            try w.writeInt(u16, @intCast(c.cardinality), .little);
            try w.writeSliceEndian(Rle16, c.blocks_as(.run, r)[0..c.cardinality], .little);
            return @sizeOf(u16) + c.cardinality * @sizeOf(Rle16);
        },
        .bitset => {
            assert(c.nblocks() == C.BITSET_BLOCKS);
            try w.writeSliceEndian(u64, c.blocks_as(.bitset, r), .little);
            return @sizeOf(root.Bitset);
        },
        .shared => unreachable,
    }
}

fn portable_serialize_empty(w: *std.Io.Writer) !usize {
    try w.writeStruct(root.Cookie{
        .magic = .SERIAL_COOKIE_NO_RUNCONTAINER,
        .cardinality_minus1 = 0,
    }, .little);
    try w.writeInt(u32, 0, .little);
    return @sizeOf(u32) * 2;
}

pub fn portable_serialize(r: Bitmap, w: *std.Io.Writer, runflags: *root.RunFlags) !usize {
    const h = r.array;
    const cslen = h.ptr(.len).*;
    trace(@src(), "{f}", .{r});

    var startOffset: u32 = 0;
    var written_count: usize = 0;
    const hasrun = r.has_run_container();
    const cs = r.slice(.containers, .len);
    trace(@src(), "hasrun={}", .{hasrun});
    if (hasrun) {
        try w.writeStruct(root.Cookie{
            .magic = .SERIAL_COOKIE,
            .cardinality_minus1 = @intCast(cslen - 1),
        }, .little);
        written_count += @sizeOf(root.Cookie);
        const s = (cslen + 7) / 8;
        @memset(runflags[0..s], 0);
        for (cs, 0..) |c, i| {
            if (c.typecode == .run) {
                runflags[i / 8] |= @as(u8, 1) << @intCast(i % 8);
            }
        }
        try w.writeAll(runflags[0..s]);
        written_count += s;
        startOffset = if (cslen < C.NO_OFFSET_THRESHOLD)
            4 + 4 * cslen + s
        else
            4 + 8 * cslen + s;
    } else { // backwards compatibility
        try w.writeStruct(root.Cookie{
            .magic = .SERIAL_COOKIE_NO_RUNCONTAINER,
            .cardinality_minus1 = 0,
        }, .little);
        try w.writeInt(u32, cslen, .little);
        written_count += @sizeOf(root.Cookie) + @sizeOf(u32);
        startOffset = 4 + 4 + 4 * cslen + 4 * cslen;
    }

    for (r.slice(.keys, .len), cs) |k, c| {
        try w.writeInt(u16, k, .little);
        const card: u16 = @intCast(c.get_cardinality(r) - 1);
        // get_cardinality returns a value in [1,1<<16], subtracting one
        // we get [0,1<<16 - 1] which fits in 16 bits
        try w.writeInt(u16, card, .little);
        written_count += @sizeOf(u16) + @sizeOf(u16);
    }
    if ((!hasrun) or (cslen >= C.NO_OFFSET_THRESHOLD)) {
        // write the containers offsets
        for (cs) |c| {
            try w.writeInt(u32, startOffset, .little);
            written_count += @sizeOf(u32);
            startOffset += @intCast(c.size_in_bytes());
        }
    }

    for (cs) |c| {
        written_count += try r.write(c, w);
    }

    return written_count;
}

///
/// Convert array and bitmap containers to run containers when it is more
/// efficient; also convert from run containers when more space efficient.
///
/// Returns true if the result has at least one run container.
/// Additional savings might be possible by calling `shrinkToFit()`.
pub fn run_optimize(r: *Bitmap, allocator: mem.Allocator) !bool {
    var answer = false;
    for (r.slice(.containers, .len)) |*c| {
        // TODO // r.unshare_container_at_index(i); // TODO: this introduces extra cloning!
        const c1 = try r.convert_run_optimize(c, allocator);
        if (c1.typecode == .run) answer = true;
        r.slice(.containers, .len)[c - r.array.ptr(.containers)] = c1;
    }
    return answer;
}

/// Get the cardinality of the bitmap (number of elements).
pub fn cardinality(r: Bitmap) u64 {
    var card: u64 = 0;
    for (r.slice(.containers, .len)) |c| card += c.compute_cardinality(r);
    return card;
}
pub const get_cardinality = cardinality;

fn array_number_of_runs(r: Bitmap, c: Container) u32 {
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

/// once converted, the original container is disposed here, rather than
/// in roaring_array
///
// TODO: split into run- array- and bitset- subfunctions for sanity;
// a few function calls won't really matter.
pub fn convert_run_optimize(r: *Bitmap, c: *Container, allocator: mem.Allocator) !Container {
    if (c.typecode == .run) {
        const newc = try r.convert_run_to_efficient_container(c.*, allocator);
        if (newc != c.*) c.deinit(allocator, r);
        return newc;
    } else if (c.typecode == .array) {
        // it might need to be converted to a run container.
        const nruns = r.array_number_of_runs(c.*);
        const nblocks = misc.numGroupsOfSize(nruns * @sizeOf(Rle16), C.BLOCK_SIZE);
        var rc: Container = .{
            .typecode = .run,
            .cardinality = @intCast(nruns),
            .nblocks_minus1 = @intCast(nblocks - 1),
            .blockoffset = @intCast(r.array.ptr(.blockslen).*),
        };
        const size_as_run_container = rc.serialized_size_in_bytes();
        const size_as_array_container = c.serialized_size_in_bytes();
        trace(@src(), "arraysize={} runsize={}", .{ size_as_array_container, size_as_run_container });
        if (size_as_array_container <= size_as_run_container) {
            return c.*;
        }
        // convert array to run container
        try r.extend_array(allocator, 0, nblocks);

        var prev: i32 = -2;
        var run_start: i32 = -1;

        const card = c.cardinality;
        rc.cardinality = 0;
        assert(card > 0);
        const c_qua_array = c.blocks_as(.array, r.*)[0..c.cardinality];
        var i: u32 = 0;
        while (i < card) : (i += 1) {
            const cur_val = c_qua_array[i];
            if (cur_val != prev + 1) {
                // new run starts; flush old one, if any
                if (run_start != -1) rc.add_run(@intCast(run_start), @intCast(prev), r.*);
                run_start = cur_val;
            }
            prev = c_qua_array[i];
        }
        assert(run_start >= 0);
        // now prev is the last seen value
        rc.add_run(@intCast(run_start), @intCast(prev), r.*);
        c.deinit(allocator, r);
        trace(@src(), "rc={}", .{rc});
        return rc;
    } else if (c.typecode == .bitset) { // run conversions on bitset
        unreachable; // TODO
        // // does bitset need conversion to run?
        // bitset_container_t *c_qua_bitset = CAST_bitset(c);
        // int32_t nruns = bitset_container_number_of_runs(c_qua_bitset);
        // int32_t size_as_run_container =
        //     run_container_serialized_size_in_bytes(nruns);
        // int32_t size_as_bitset_container =
        //     bitset_container_serialized_size_in_bytes();

        // if (size_as_bitset_container <= size_as_run_container) {
        //     // no conversion needed.
        //     *typecode_after = .bitset;
        //     return c;
        // }
        // // bitset to runcontainer (ported from Java  RunContainer(
        // // BitmapContainer bc, int nbrRuns))
        // assert(nruns > 0);  // no empty bitmaps
        // run_container_t *answer = run_container_create_given_capacity(nruns);

        // int long_ctr = 0;
        // uint64_t cur_word = c_qua_bitset.words[0];
        // while (true) {
        //     while (cur_word == UINT64_C(0) &&
        //            long_ctr < BITSET_CONTAINER_SIZE_IN_WORDS - 1)
        //         cur_word = c_qua_bitset.words[++long_ctr];

        //     if (cur_word == UINT64_C(0)) {
        //         bitset_container_free(c_qua_bitset);
        //         *typecode_after = .run;
        //         return answer;
        //     }

        //     int local_run_start = roaring_trailing_zeroes(cur_word);
        //     int run_start = local_run_start + 64 * long_ctr;
        //     uint64_t cur_word_with_1s = cur_word | (cur_word - 1);

        //     int run_end = 0;
        //     while (cur_word_with_1s == UINT64_C(0xFFFFFFFFFFFFFFFF) &&
        //            long_ctr < BITSET_CONTAINER_SIZE_IN_WORDS - 1)
        //         cur_word_with_1s = c_qua_bitset.words[++long_ctr];

        //     if (cur_word_with_1s == UINT64_C(0xFFFFFFFFFFFFFFFF)) {
        //         run_end = 64 + long_ctr * 64;  // exclusive, I guess
        //         add_run(answer, run_start, run_end - 1);
        //         bitset_container_free(c_qua_bitset);
        //         *typecode_after = .run;
        //         return answer;
        //     }
        //     int local_run_end = roaring_trailing_zeroes(~cur_word_with_1s);
        //     run_end = local_run_end + long_ctr * 64;
        //     add_run(answer, run_start, run_end - 1);
        //     cur_word = cur_word_with_1s & (cur_word_with_1s + 1);
        // }
        // return answer;
    } else {
        unreachable;
    }
}

/// Converts a run container to either an array or a bitset, IF it saves space.
///
/// If a conversion occurs, the caller is responsible to free the original
/// container and he becomes responsible to free the new one.
pub fn convert_run_to_efficient_container(r: Bitmap, c: Container, allocator: mem.Allocator) !Container {
    _ = allocator;
    assert(c.typecode == .run);
    const size_as_run_container = c.serialized_size_in_bytes();
    const size_as_bitset_container = @sizeOf(root.Bitset);
    const card = c.compute_cardinality(r);
    var ac: Container = .{ .typecode = .array, .cardinality = card, .nblocks_minus1 = undefined, .blockoffset = undefined };
    const size_as_array_container = ac.serialized_size_in_bytes();

    const min_size_non_run =
        if (size_as_bitset_container < size_as_array_container)
            size_as_bitset_container
        else
            size_as_array_container;
    if (size_as_run_container <= min_size_non_run) { // no conversion
        return c;
    }
    if (card <= C.DEFAULT_MAX_SIZE) {
        unreachable; // TODO
        // // to array
        // var answer = try ArrayContainer.init_with_capacity(allocator, card);
        // answer.cardinality = 0;
        // for (0..c.cardinality) |rlepos| {
        //     const run_start = c.runs[rlepos].value;
        //     const run_end = run_start + c.runs[rlepos].length;

        //     var run_value = run_start;
        //     while (run_value < run_end) : (run_value += 1) {
        //         answer.get_header()[answer.cardinality] = run_value;
        //         answer.cardinality += 1;
        //     }
        // }

        // return .create(allocator, answer);
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

/// Whether you want to use copy-on-write.
/// Saves memory and avoids copies, but needs more care in a threaded context.
/// Most users should ignore this flag.
///
/// Note: If you do turn this flag to 'true', enabling COW, then ensure that you
/// do so for all of your bitmaps, since interactions between bitmaps with and
/// without COW is unsafe.
///
/// When setting this flag to false, if any containers are shared, they
/// are unshared (cloned) immediately.
pub fn get_copy_on_write(r: Bitmap) bool {
    return r.array.ptr(.flags).* & 1 << @intFromEnum(Flag.cow) != 0;
}

pub fn internal_validate_header(r: Bitmap, reason: *?[]const u8) bool {
    const h = r.array;
    const magic = h.ptr(.magic).*;
    if (!(r.is_empty() or
        magic == .SERIAL_COOKIE or
        magic == .SERIAL_COOKIE_NO_RUNCONTAINER))
    {
        trace(@src(), "magic={}", .{@intFromEnum(magic)});
        reason.* = "unsupported magic";
        return false;
    }

    // trace(@src(), "{}\n  buffer_size()={} h.allocation_size={}", .{ h, h.buffer_size(), h.capacity });
    if (!(h.ptr(.capacity).* >= h.ptr(.len).*)) {
        reason.* = "array capacity not gte len";
        return false;
    }

    if (!(h.ptr(.blockscapacity).* >= h.ptr(.blockslen).*)) {
        reason.* = "blocks capacity not gte len";
        return false;
    }

    if (@popCount(r.array.ptr(.flags).*) > 1) {
        reason.* = "invalid flags";
        return false;
    }

    // if (h.can_have_run_containers() != (h.run_flags != null)) {
    //     reason.* = "invalid array run flags";
    //     return false;
    // }

    // Serialization Sync: Check that container_startpos equals the sum of the array field sizes plus any padding.

    return true;
}

///
/// Perform internal consistency checks. Returns true if the bitmap is
/// consistent. It may be useful to call this after deserializing bitmaps from
/// untrusted sources. If internal_validate returns true, then the
/// bitmap should be consistent and can be trusted not to cause crashes or memory
/// corruption.
///
/// Note that some operations intentionally leave bitmaps in an inconsistent
/// state temporarily, for example, `lazy_*` functions, until
/// `repair_after_lazy` is called.
///
/// If reason is non-null, it will be set to a string describing the first
/// inconsistency found if any.
///
/// Checks that:
/// - Array containers are sorted and contain no duplicates
/// - Range containers are sorted and contain no overlapping ranges
/// - Roaring containers are sorted by key and there are no duplicate keys
/// - The correct container type is use for each container (e.g. bitmaps aren't
/// used for small containers)
/// - Shared containers are only used when the bitmap is COW
///
pub fn internal_validate(r: Bitmap, reason: *?[]const u8) bool {
    reason.* = null;
    // trace(@src(), "{f}", .{r});
    if (r.is_empty()) return true;

    if (!r.internal_validate_header(reason)) {
        return false;
    }

    if (r.array.ptr(.len).* == 0) return true;

    const keys = r.slice(.keys, .len);
    var prev_key = keys[0];
    for (keys[1..]) |*key| {
        if (key.* <= prev_key) {
            reason.* = "keys not strictly increasing";
            trace(@src(), "key={} idx={}", .{ key.*, key - keys.ptr });
            return false;
        }
        prev_key = key.*;
    }

    const cow = r.get_copy_on_write();
    for (r.slice(.containers, .len)) |*c| {
        if (c.typecode == .shared and !cow) {
            reason.* = "shared container in non-COW bitmap";
            return false;
        }
        if (!c.internal_validate(reason, r)) {
            trace(@src(), "invalid container at index={} {f}", .{ c - r.array.ptr(.containers), c.fmt(r) });
            // reason should already be set
            if (reason.* == null) {
                reason.* = "container failed to validate but no reason given";
            }
            return false;
        }
    }

    return true;
}

pub fn internal_validate_container(r: Bitmap, c: Container, reason: *?[]const u8) bool {
    return c.internal_validate(reason, r);
}

pub fn assert_valid(r: Bitmap) void {
    if (!(@import("builtin").is_test or @import("builtin").mode == .Debug)) return;
    var reason: ?[]const u8 = null;
    if (!r.internal_validate(&reason)) {
        trace(@src(), "{s}", .{reason.?});
        trace(@src(), "{f}", .{r});
        for (r.slice(.keys, .len), r.slice(.containers, .len), 0..) |k, c, i| {
            if (false and c.cardinality > 1)
                trace(@src(), "{} {}: {f}", .{ i, k, c.fmt(r) });
        }

        unreachable;
    }
}

/// copy r to newarray
pub fn copy_to(r: *const Bitmap, newarray: *Model) void {
    inline for (Model.sorted_fields) |sf| {
        if (@hasField(Model.Lengths, sf.name)) continue; // skip lengths
        const f = @field(Model.Field, sf.name);
        // TODO dont copy blocks here when they need to be immediately moved
        // again (ie when adding growing an array container)
        newarray.copyField(r.array, f);
    }
}

/// grow if necessary to new_capacity.  deinit if 0.  modifies `Array.len/capacity`.
pub fn realloc_array(r: *Bitmap, allocator: mem.Allocator, new_capacity: u32, new_blockscapacity: u32) !void {
    if (new_capacity == 0) {
        r.deinit(allocator);
        return;
    }
    const cap = r.array.ptr(.capacity).*;
    const bcap = r.array.ptr(.blockscapacity).*;
    assert(new_capacity > cap or new_blockscapacity > bcap);

    const newlens: Model.Lengths = .{
        .capacity = @max(cap, new_capacity),
        .blockscapacity = @max(bcap, new_blockscapacity),
    };
    const lens = r.array.calcLens();
    const size = Model.calcSize(lens);
    const newsize = Model.calcSize(newlens);
    trace(@src(), "lens:old/new={},{}/{},{} sizes={B:.1}/{B:.1}", .{ lens.capacity, lens.blockscapacity, newlens.capacity, newlens.blockscapacity, size, newsize });
    if (r.is_empty()) {
        r.array = try Model.create(allocator, newlens);
        zero_init(r.array);
        return;
    }

    // TODO faster to realloc and move fields. when newsize is larger?
    const newarray = try Model.create(allocator, newlens);
    r.copy_to(newarray);
    assert(r.array.ptr(.len).* == newarray.ptr(.len).*);
    assert(r.array.ptr(.blockslen).* == newarray.ptr(.blockslen).*);
    allocator.free(r.array.asBytes()[0..size]);
    r.array = newarray;
}

pub fn extend_array(r: *Bitmap, allocator: mem.Allocator, more_cap: u32, more_blockscap: u32) !void {
    const len = r.array.ptr(.len).*;
    const capacity = r.array.ptr(.capacity).*;
    const blockslen = r.array.ptr(.blockslen).*;
    const blockscapacity = r.array.ptr(.blockscapacity).*;
    const desired_len = len + more_cap;
    const desired_blockslen = blockslen + more_blockscap;
    // trace(
    //     @src(),
    //     "len/cap={}/{} blocks:len/cap={}/{} more:cap/blockscap={}/{} desired:len/blockslen={}/{}",
    //     .{ len, capacity, blockslen, blockscapacity, more_cap, more_blockscap, desired_len, desired_blockslen },
    // );
    assert(desired_len < C.MAX_CONTAINERS and desired_blockslen < C.MAX_BLOCKS);

    if (desired_len > capacity or desired_blockslen > blockscapacity) {
        const new_capacity = @min(
            C.MAX_CONTAINERS,
            if (len < 1024)
                2 * desired_len
            else
                @divFloor(5 * desired_len, 4),
        );

        const new_blockscapacity = @min(
            C.MAX_BLOCKS,
            if (len < 1024)
                2 * desired_blockslen
            else
                @divFloor(5 * desired_blockslen, 4),
        );

        if (new_capacity > capacity or new_blockscapacity > blockscapacity)
            try r.realloc_array(allocator, new_capacity, new_blockscapacity);
    }
}

/// Shifts rightmost $count containers to the left (distance < 0) or
/// to the right (distance > 0).
/// Allocates memory if necessary.
/// This function doesn't free or create new containers.
/// Caller is responsible for that.
pub fn shift_tail(r: *Bitmap, allocator: mem.Allocator, count: u32, distance: i32) !void {
    if (distance > 0) {
        try r.extend_array(allocator, @bitCast(distance), @bitCast(distance));
    }
    const srcpos = r.array.ptr(.len).* - count;
    const dstpos = srcpos +% @as(u32, @bitCast(distance));
    trace(@src(), "count={} distance={} srcpos={} dstpos={}", .{ count, distance, srcpos, dstpos });

    r.array.ptr(.len).* += @bitCast(distance);
    r.array.ptr(.blockslen).* += @bitCast(distance);

    const keys = r.slice(.keys, .len);
    @memmove(keys[dstpos..].ptr, keys[srcpos..][0..count]);
    const cs = r.slice(.containers, .len);
    @memmove(cs[dstpos..].ptr, cs[srcpos..][0..count]);
}

pub fn format(r: Bitmap, w: *Io.Writer) !void {
    if (r.is_empty()) {
        try w.writeAll("empty");
        return;
    }
    const size = Model.calcSize(r.array.calcLens());
    try w.print("len/cap={}/{} blocks:len/cap={}/{} {B:.1} magic={} flags={}", .{
        r.array.ptr(.len).*,
        r.array.ptr(.capacity).*,
        r.array.ptr(.blockslen).*,
        r.array.ptr(.blockscapacity).*,
        size,
        @intFromEnum(r.array.ptr(.magic).*),
        r.array.ptr(.flags).*,
    });
    // try w.print(" keys={any}", .{ h.slice(.keys, .len) });
    const cs = r.slice(.containers, .len);

    // try w.print("\n  {: <4}: {?f}", .{ 0, if (cs.len > 0) cs[0].fmt(r) else null });
    // if (cs.len > 1) try w.print("\n  ...\n  {: <4}: {f}", .{ cs.len, cs[cs.len - 1].fmt(r) });

    const len = @min(cs.len, 10);
    for (cs[0..len], 0..) |*c, i| {
        try w.print("\n  {}: {}", .{ i, c });
    }
    // if (cs.len > 0) try w.print("\n  {?}: {f}", .{ 0,  cs[0].fmt(f.r)  });

}

fn deserializeTestdataPortable(io: Io, f: Io.File) !Bitmap {
    var rbuf: [256]u8 = undefined;
    return try portable_deserialize(testing.allocator, io, f, &rbuf);
}

fn validateTestdataFile(rb: Bitmap) !void {
    // > They contain all multiplies of 1000 in [0,100000), all multiplies of 3 in [100000,200000) and all values in [700000,800000).
    // > https://github.com/RoaringBitmap/RoaringFormatSpec/tree/master/testdata
    var k: u32 = 0;
    while (k < 100000) : (k += 1000) {
        try testing.expect(rb.contains(k));
    }
    k = 100000;
    while (k < 200000) : (k += 1) {
        try testing.expect(rb.contains(3 * k));
    }
    k = 700000;
    while (k < 800000) : (k += 1) {
        try testing.expect(rb.contains(k));
    }
}

test Bitmap {
    const testio = testing.io;
    { // "without runs"
        const filepath = "testdata/bitmapwithoutruns.bin";
        const f = try Io.Dir.cwd().openFile(testio, filepath, .{});
        defer f.close(testio);
        var rb = try deserializeTestdataPortable(testio, f);
        defer rb.deinit(testing.allocator);
        try testing.expectEqual(.SERIAL_COOKIE_NO_RUNCONTAINER, rb.array.ptr(.magic).*);
        // try testing.expectEqual(8 * 256 + 220 + @as(u32, rb.header.nblocks()), rb.blocks.items.len); // 8 bitsets, 220 array blocks
        try validateTestdataFile(rb);
    }
    { // "with runs"
        const filepath = "testdata/bitmapwithruns.bin";
        const f = try Io.Dir.cwd().openFile(testio, filepath, .{});
        defer f.close(testio);
        var rb = try deserializeTestdataPortable(testio, f);
        defer rb.deinit(testing.allocator);
        try testing.expectEqual(.SERIAL_COOKIE, rb.array.ptr(.magic).*);
        // try testing.expectEqual(5 * 256 + 220 + 3 + @as(u32, rb.header.nblocks()), rb.blocks.items.len); // 5 bitsets, 220 array blocks, 3 run blocks
        try validateTestdataFile(rb);
    }
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;
const Io = std.Io;
const builtin = @import("builtin");
const flexible = @import("flexible_struct");
const C = @import("constants.zig");
const misc = @import("misc.zig");
const trace = misc.trace;
const root = @import("root.zig");
const Typecode = root.Typecode;
const Any = root.container.Any;
const Container = root.container.Container;
const Block = root.Block;
const Rle16 = root.Rle16;
