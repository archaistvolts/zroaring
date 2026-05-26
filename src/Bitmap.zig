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
    /// a bitset of `Flag`
    flags: u8,
    /// container keys.
    keys: flexible.Array(u16, .capacity) align(C.BLOCK_ALIGN),
    /// container descriptors.
    containers: flexible.Array(Container, .capacity) align(C.BLOCK_ALIGN),
    /// container data stored as blocks.
    blocks: flexible.Array(Block, .blockscapacity),
};

const Model = flexible.Struct(Array);
const emptybuf: Model.Buf(.{
    .capacity = 0,
    .blockscapacity = 0,
}) align(C.BLOCK_ALIGN) = @splat(0);
pub const empty: Bitmap = .{ .array = @ptrCast(@constCast(&emptybuf)) };

pub const Flag = enum(u8) {
    /// copy on write
    cow,
    /// frozen layout described in `frozen_size_in_bytes`.
    frozen,
};

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

/// Allocates room for at minimum 16 containers and blocks
pub fn create_with_capacity(allocator: mem.Allocator, container_count: u32) !Bitmap {
    const capacity = @max(16, container_count);
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

/// wrapper of `info_from_file_reader()`.
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
/// seekable/positional file. `read_buf` is a temporary buffer.
/// TODO non-positional/streaming files.
pub fn portable_deserialize(
    allocator: mem.Allocator,
    io: Io,
    bitmap_file: Io.File,
    read_buf: []u8,
) !Bitmap {
    var freader = bitmap_file.reader(io, read_buf);
    return try portable_deserialize_file_reader(allocator, &freader);
}

/// Allocates and returns a Bitmap, read from `bitmap_freader` which must be a
/// seekable/positional file.
/// TODO non-positional/streaming files.
pub fn portable_deserialize_file_reader(
    allocator: mem.Allocator,
    bitmap_file_reader: *Io.File.Reader,
) !Bitmap {
    const ainfo = try info_from_file_reader(bitmap_file_reader);
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
    try ret.deserialize_file_reader(bitmap_file_reader, &run_flags);
    assert(bitmap_file_reader.logicalPos() == ret.portable_size());

    const r = &bitmap_file_reader.interface;
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

    assert(bitmap_file_reader.size == null or bitmap_file_reader.atEnd());
    const blockslen = curblock - blocks;
    ret.array.ptr(.blockslen).* = @intCast(blockslen);

    assert(ret.array.ptr(.blockslen).* <= ret.array.ptr(.blockscapacity).*);

    // FIXME - portable_size_in_bytes() doesn't match logicalPos() on testdatawithruns - 48056 48050
    if (bitmap_file_reader.logicalPos() != ret.portable_size_in_bytes()) {
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

pub fn insert_new_key_value_at(
    r: *Bitmap,
    allocator: mem.Allocator,
    key: u16,
    c: Container,
    i: u32,
) !void {
    try r.extend_array(allocator, 1, 1);
    const len = r.array.ptr(.len).*;
    const ks = r.array.ptr(.keys)[0..len];
    const cs = r.array.ptr(.containers)[0..len];
    @memmove(ks.ptr + i + 1, ks[i..]);
    ks.ptr[i] = key;
    @memmove(cs.ptr + i + 1, cs[i..]);
    cs.ptr[i] = c;
    r.array.ptr(.len).* += 1;
    r.array.ptr(.blockslen).* += 1;
}

/// returns count of `vals` added
pub fn add_many(r: *Bitmap, allocator: mem.Allocator, vals: []const u32) !usize {
    // TODO estimate how many containers and blocks are needed, preallocate and then use assume capacity api.
    trace(@src(), "vals={}:{?}..{?}", .{ vals.len, if (vals.len > 0) vals[0] else null, if (vals.len > 1) vals[vals.len - 1] else null });
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
    defer assert(r.contains(value));
    defer r.assert_valid();

    if (r.is_empty()) {
        @branchHint(.unlikely);
        r.* = try create_with_capacity(allocator, 1);
    }

    const key: u16, const valuelow: u16 = .{ @truncate(value >> 16), @truncate(value) };
    const mcontaineridx = misc.binarySearch(r.slice(.keys, .len), key);
    if (mcontaineridx >= 0) { // key found
        const cid: u32 = @bitCast(mcontaineridx);
        const c = &r.array.ptr(.containers)[cid];
        const oldc = c.*;
        // trace(@src(), "key found container={f} {any}", .{ c.fmt(r), c.blocks_as(.array, r)[0..card] });
        const c2 = try c.add(allocator, r, valuelow);
        if (oldc != c2) {
            // skip deinit of inplace array/bitset conversion
            if (oldc.blockoffset != c2.blockoffset) {
                oldc.deinit_blocks(r.*);
            }
            r.array.ptr(.containers)[cid] = c2;
        }
        return oldc.cardinality != c2.cardinality;
    } else { // key not found, add new array container
        const cid: u32 = @intCast(-mcontaineridx - 1);
        const blockslen = r.array.ptr(.blockslen).*;
        const capacity = r.array.ptr(.capacity).*;
        if (r.array.ptr(.len).* == capacity) {
            try r.realloc_array(allocator, capacity + 1, blockslen + 1);
        }

        try r.insert_new_key_value_at(allocator, key, .{
            .blockoffset = @intCast(blockslen),
            .nblocks_minus1 = 0,
            .cardinality = 0,
            .typecode = .array,
        }, cid);
        const newac = &r.array.ptr(.containers)[cid];
        _ = try newac.add(allocator, r, valuelow); // ignore return. always an array with cardinality 1
        return true;
    }
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
            const array = c.blocks_as(.array, r);
            array[c.cardinality] = container_value;
            c.cardinality += 1;
        },
        else => unreachable, // unsupported type
    }
}

/// The new container consists of a single run [start,stop).
/// It is required that stop>start, the caller is responsible for this check.
/// It is required that stop <= (1<<16), the caller is responsibe for this
/// check. The cardinality of the created container is stop - start.
pub fn create_range(
    r: *Bitmap,
    allocator: mem.Allocator,
    tc: Typecode,
    start: u32,
    stop: u32,
    blockoffset: u32,
) !Container {
    switch (tc) {
        .run => {
            var c = try Container.run_container_create_given_capacity(allocator, 1, blockoffset, r);
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
pub fn range_of_ones(
    r: *Bitmap,
    allocator: mem.Allocator,
    range_start: u32,
    range_end: u32,
    blockoffset: u32,
) !Container {
    assert(range_end >= range_start);
    const card = range_end - range_start + 1;
    trace(@src(), "{}-{}:{}", .{ range_start, range_end, card });
    return if (card <= 2)
        try r.create_range(allocator, .array, range_start, range_end, blockoffset)
    else
        try r.create_range(allocator, .run, range_start, range_end, blockoffset);
}

/// Create a container with all the values between in [min,max) at a
/// distance k*step from min.
pub fn from_range(
    r: *Bitmap,
    allocator: mem.Allocator,
    min: u32,
    max: u32,
    step: u16,
    blockoffset: u32,
) !Container {
    trace(@src(), "{}-{} step {}\n", .{ min, max, step });
    if (step == 0) return .uninit; // being paranoid
    if (step == 1) {
        return try r.range_of_ones(allocator, min, max, blockoffset);
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

/// Find the cardinality of the bitset in [begin,begin+lenminusone]
fn bitset_lenrange_cardinality(
    words: [*]align(C.BLOCK_ALIGN) u64,
    start: u32,
    lenminusone: u32,
) u32 {
    const firstword = start / 64;
    const endword = (start + lenminusone) / 64;
    if (firstword == endword) {
        return @ctz(words[firstword] &
            ((~@as(u64, 0)) >>
                @truncate((63 - lenminusone) % 64)) <<
                @truncate(start % 64));
    }
    var answer =
        @ctz(words[firstword] & ((~@as(u64, 0)) << @truncate(start % 64)));
    for (firstword + 1..endword) |i| {
        answer += @ctz(words[i]);
    }
    answer += @ctz(words[endword] &
        (~@as(u64, 0)) >>
            @truncate(((~start + 1) - lenminusone - 1) % 64));
    return answer;
}

/// Set all bits in indexes [begin,begin+lenminusone] to true.
fn bitset_set_lenrange(words: [*]align(C.BLOCK_ALIGN) u64, start: u32, lenminusone: u32) void {
    const firstword = start / 64;
    const endword = (start + lenminusone) / 64;
    if (firstword == endword) {
        words[firstword] |= ((~@as(u64, 0)) >>
            @truncate((63 - lenminusone) % 64)) <<
            @truncate(start % 64);
        return;
    }
    const temp = words[endword];
    words[firstword] |= (~@as(u64, 0)) << @truncate(start % 64);
    var i: u32 = firstword + 1;
    while (i < endword) : (i += 2) {
        words[i] = ~@as(u64, 0);
        words[i + 1] = ~@as(u64, 0);
    }
    words[endword] =
        temp | (~@as(u64, 0)) >> @truncate(((~start + 1) - lenminusone - 1) % 64);
}

/// The new container consists of a single run [start,stop).
/// It is required that stop>start, the caller is responsability for this check.
/// It is required that stop <= (1<<16), the caller is responsability for this
/// check. The cardinality of the created container is stop - start.
fn run_container_create_range(start: u32, stop: u32, blockoffset: u24, r: Bitmap) !Container {
    var rc: Container = .{
        .typecode = .run,
        .cardinality = @intCast(stop - start),
        .blockoffset = blockoffset,
        .nblocks_minus1 = 0,
    };
    r.append_first(&rc, root.Rle16{
        .value = @intCast(start),
        .length = @intCast(stop - start - 1),
    });
    return rc;
}

/// Adds all values in range [min,max] using hint:
///   nvals_less is the number of array values less than $min
///   nvals_greater is the number of array values greater than $max
fn array_container_add_range_nvals(
    r: *Bitmap,
    allocator: mem.Allocator,
    ac: *Container,
    min: u32,
    max: u32,
    nvals_less: u32,
    nvals_greater: u32,
) !void {
    const union_cardinality = nvals_less + (max - min + 1) + nvals_greater;
    const acid = ac - r.array.ptr(.containers);
    if (union_cardinality > ac.calc_capacity()) {
        try ac.array_container_grow(allocator, r, union_cardinality, true);
    }
    const ac2 = &r.array.ptr(.containers)[acid];
    const array = ac2.blocks_as(.array, r.*)[0..union_cardinality];
    @memmove(
        array.ptr + union_cardinality - nvals_greater,
        (array.ptr + ac2.cardinality - nvals_greater)[0..nvals_greater],
    );
    for (0..max - min + 1) |i| {
        array[nvals_less + i] = @intCast(min + i);
    }
    ac2.cardinality = @intCast(union_cardinality);
}

/// Add all values in range [min, max] using hint.
fn run_container_add_range_nruns(
    r: *Bitmap,
    allocator: mem.Allocator,
    run: *Container,
    min: u32,
    max: u32,
    nruns_less: u32,
    nruns_greater: u32,
) !void {
    const nruns_common = run.cardinality - nruns_less - nruns_greater;
    const runs = run.blocks_as(.run, r.*)[0..run.cardinality];
    if (nruns_common == 0) {
        try r.makeRoomAtIndex(allocator, run, @truncate(nruns_less));
        runs.ptr[nruns_less] = .{
            .value = @truncate(min),
            .length = @truncate(max - min),
        };
    } else {
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

fn container_from_run_range(
    r: *Bitmap,
    allocator: mem.Allocator,
    run: Container,
    min: u32,
    max: u32,
    blockoffset: u24,
) !Container {
    // We expect most of the time to end up with a bitset container
    var bitset = try Container.bitset_container_create(allocator, blockoffset, r);
    const words = bitset.blocks_as(.bitset, r.*);
    var union_cardinality: u32 = 0;
    const runs = run.blocks_as(.run, r.*)[0..run.cardinality];
    for (0..run.cardinality) |i| {
        const rle_min: u32 = runs[i].value;
        const rle_max: u32 = rle_min + runs[i].length;
        bitset_set_lenrange(words.ptr, rle_min, rle_max - rle_min);
        union_cardinality += runs[i].length + 1;
    }
    union_cardinality += @intCast(max - min + 1);
    union_cardinality -=
        bitset_lenrange_cardinality(words.ptr, min, max - min);
    bitset_set_lenrange(words.ptr, min, max - min);
    bitset.cardinality = @intCast(union_cardinality);
    if (bitset.cardinality <= C.DEFAULT_MAX_SIZE) {
        // convert to an array container
        const array = try bitset.array_container_from_bitset(allocator, r);
        bitset.deinit(r.*);
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
fn container_add_range(
    r: *Bitmap,
    allocator: mem.Allocator,
    c: *Container,
    min: u32,
    max: u32,
    blockoffset: u24,
) !Container {
    trace(@src(), "{f}", .{r});
    const cid = c - r.array.ptr(.containers);
    // NB: when selecting new container type, we perform only inexpensive checks
    switch (c.typecode) {
        .bitset => {
            const words = c.blocks_as(.bitset, r.*);
            var union_cardinality: u32 = 0;
            union_cardinality += c.cardinality;
            union_cardinality += max - min + 1;
            union_cardinality -=
                bitset_lenrange_cardinality(words.ptr, min, max - min);

            if (union_cardinality == C.MAX_KEY_CARDINALITY) {
                return run_container_create_range(0, C.MAX_KEY_CARDINALITY, blockoffset, r.*);
            } else {
                bitset_set_lenrange(words.ptr, min, max - min);
                c.cardinality = @intCast(union_cardinality);
                return c.*;
            }
        },
        .array => {
            const array = c.blocks_as(.array, r.*)[0..c.cardinality];
            const nvals_greater =
                misc.count_greater(array, @truncate(max));
            const nvals_less =
                misc.count_less(array[0 .. c.cardinality - nvals_greater], @truncate(min));
            const union_cardinality =
                nvals_less + (max - min + 1) + nvals_greater;
            trace(@src(), "array union_cardinality={}", .{union_cardinality});
            if (union_cardinality == C.MAX_KEY_CARDINALITY) {
                return run_container_create_range(0, C.MAX_KEY_CARDINALITY, blockoffset, r.*);
            } else if (union_cardinality <= C.DEFAULT_MAX_SIZE) {
                try r.array_container_add_range_nvals(allocator, c, min, max, nvals_less, nvals_greater);
                return r.array.ptr(.containers)[cid];
            } else {
                var bitset = try c.bitset_container_from_array(allocator, r);
                bitset_set_lenrange(bitset.blocks_as(.bitset, r.*).ptr, min, max - min);
                bitset.cardinality = @intCast(union_cardinality);
                return bitset;
            }
        },
        .run => {
            const runs = c.blocks_as(.run, r.*)[0..c.cardinality];
            const nruns_greater =
                misc.rle16_count_greater(runs, @truncate(max));
            const nruns_less =
                misc.rle16_count_less(runs[0 .. c.cardinality - nruns_greater], @truncate(min));
            const run_size_bytes =
                (nruns_less + 1 + nruns_greater) * @sizeOf(root.Rle16);
            const bitset_size_bytes = @sizeOf(root.Bitset);

            if (run_size_bytes <= bitset_size_bytes) {
                try r.run_container_add_range_nruns(allocator, c, min, max, nruns_less, nruns_greater);
                return r.array.ptr(.containers)[cid];
            } else {
                return r.container_from_run_range(allocator, c.*, min, max, blockoffset);
            }
        },
        else => unreachable,
    }
}

fn replace_key_and_container_at_index(r: Bitmap, i: u32, key: u16, c: Container) void {
    assert(i < r.array.ptr(.len).*);
    r.array.ptr(.containers)[i] = c;
    r.array.ptr(.keys)[i] = key;
}

/// Add all values in range [min, max]
pub fn add_range_closed(r: *Bitmap, allocator: mem.Allocator, min: u32, max: u32) !void {
    assert_valid(r.*); // TODO
    defer assert_valid(r.*);

    if (min > max) return;
    if (r.is_empty()) {
        @branchHint(.unlikely);
        r.* = try create_with_capacity(allocator, 0);
    }

    trace(@src(), "[{},{})", .{ min, max });

    const min_key = min >> 16;
    const max_key = max >> 16;
    const num_required_containers = max_key - min_key + 1;
    const len = r.array.ptr(.len).*;
    const keys = r.array.ptr(.keys)[0..len];
    var blockoffset: u24 = @intCast(r.array.ptr(.blockslen).*);
    errdefer {
        r.array.ptr(.len).* = len;
        r.array.ptr(.blockslen).* = blockoffset;
    }
    const suffix_length = misc.count_greater(keys, @truncate(max_key));
    const prefix_length = misc.count_less(keys[0 .. len - suffix_length], @truncate(min_key));
    const common_length = len - prefix_length - suffix_length;
    // trace(@src(), "num_required_containers={} prefix_length={} suffix_length={} common_length={}", .{ num_required_containers, prefix_length, suffix_length, common_length });
    if (num_required_containers > common_length) {
        const distance = num_required_containers - common_length;
        try r.shift_tail(allocator, suffix_length, @bitCast(distance));
    }

    var src: i32 = @bitCast(prefix_length + common_length -% 1);
    var dst = r.array.ptr(.len).* - suffix_length -% 1;
    var key = max_key;
    // trace(@src(), "dst={} src={} len={}", .{ dst, src, r.array.ptr(.len).* });
    while (key +% 1 != min_key) : (key -%= 1) { // beware of min_key==0
        // trace(@src(), "dst={} key={} min_key={} max_key={} len={}", .{ dst, key, min_key, max_key, r.array.ptr(.len).* });
        const container_min = if (min_key == key) min & 0xffff else 0;
        const container_max = if (max_key == key) max & 0xffff else 0xffff;
        var newc: Container = .uninit;
        const srcu: u32 = @bitCast(src);
        if (src >= 0 and r.slice(.keys, .len)[srcu] == key) {
            // TODO // ra.unshare_container_at_index(srcu);
            newc = try r.container_add_range(
                allocator,
                &r.array.ptr(.containers)[srcu],
                container_min,
                container_max,
                blockoffset,
            );
            if (newc != r.array.ptr(.containers)[srcu]) {
                r.array.ptr(.containers)[srcu].deinit(r.*);
            }
            src -= 1;
        } else {
            newc = try r.from_range(allocator, container_min, container_max + 1, 1, blockoffset);
        }
        // trace(@src(), "dst {}, newc {f} newc.card={}", .{ dst, newc.fmt(r.*), newc.compute_cardinality(r.*) });
        assert(newc != Container.uninit);
        r.replace_key_and_container_at_index(dst, @truncate(key), newc);
        dst -%= 1;
        blockoffset += newc.nblocks();
    }
}

/// Add all values in range [min, max)
pub fn add_range(r: *Bitmap, allocator: mem.Allocator, min: u64, max: u64) !void {
    trace(@src(), "{} {}", .{ min, max });

    if (!(min < max and min <= C.MAX_VALUE_CARDINALITY)) {
        return;
    }
    try r.add_range_closed(allocator, @intCast(min), @intCast(max - 1));
}

pub fn contains(r: Bitmap, val: u32) bool {
    const key: u16 = @truncate(val >> 16);
    // the next function call involves a binary search and lots of branching.
    const i = r.get_key_index(key);
    if (i < 0) return false;
    // rest might be a tad expensive, possibly involving another round of binary
    // search
    const iu: u32 = @bitCast(i);
    return r.array.ptr(.containers)[iu].contains(@truncate(val), r);
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

/// Get the index corresponding to a 16-bit key
pub fn get_key_index(r: Bitmap, key: u16) i32 {
    const keys = r.slice(.keys, .len);
    if (keys.len == 0 or keys[keys.len - 1] == key)
        return @bitCast(@as(u32, @truncate(keys.len -% 1)));
    return misc.binarySearch(keys, key);
}

/// returns the index of x, if not exist return -1.
pub fn get_index(r: Bitmap, x: u32) i64 {
    var index: i64 = 0;
    const key: u16 = @truncate(x >> 16);
    const key_idx = r.get_key_index(key);
    if (key_idx < 0) return -1;

    const key_idxu: u32 = @bitCast(key_idx);
    const cs = r.array.ptr(.containers);
    for (r.slice(.keys, .len), cs) |k, c| {
        if (key > k) {
            index += c.get_cardinality(r);
        } else if (key == k) {
            const low_idx = cs[key_idxu].get_index(@truncate(x), r);
            if (low_idx < 0) return -1;
            return index + low_idx;
        } else {
            return -1;
        }
    }
    return index;
}

pub fn has_run_container(r: Bitmap) bool {
    return for (r.slice(.containers, .len)) |c| {
        if (c.typecode == .run) break true;
    } else false;
}

/// depends only on `Array` `len`.
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
/// depends only on `Array` `magic` and `len`.
pub fn portable_size(ra: Bitmap) usize {
    return ra.portable_size_ext(ra.can_have_run_containers());
}

/// file position where array data ends and container data starts.   depends on
/// `containers` being populated to check if run containers are present.
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
    const len = r.array.ptr(.len).*;

    var startOffset: u32 = 0;
    var written_count: usize = 0;
    const hasrun = r.has_run_container();
    const cs = r.slice(.containers, .len);
    trace(@src(), "hasrun={}", .{hasrun});
    if (hasrun) {
        try w.writeStruct(root.Cookie{
            .magic = .SERIAL_COOKIE,
            .cardinality_minus1 = @intCast(len - 1),
        }, .little);
        written_count += @sizeOf(root.Cookie);
        const s = (len + 7) / 8;
        @memset(runflags[0..s], 0);
        for (cs, 0..) |c, i| {
            if (c.typecode == .run) {
                runflags[i / 8] |= @as(u8, 1) << @intCast(i % 8);
            }
        }
        try w.writeAll(runflags[0..s]);
        written_count += s;
        startOffset = if (len < C.NO_OFFSET_THRESHOLD)
            4 + 4 * len + s
        else
            4 + 8 * len + s;
    } else { // backwards compatibility
        try w.writeStruct(root.Cookie{
            .magic = .SERIAL_COOKIE_NO_RUNCONTAINER,
            .cardinality_minus1 = 0,
        }, .little);
        try w.writeInt(u32, len, .little);
        written_count += @sizeOf(root.Cookie) + @sizeOf(u32);
        startOffset = 4 + 4 + 4 * len + 4 * len;
    }

    for (r.slice(.keys, .len), cs) |k, c| {
        try w.writeInt(u16, k, .little);
        const card: u16 = @intCast(c.get_cardinality(r) - 1);
        // get_cardinality returns a value in [1,1<<16], subtracting one
        // we get [0,1<<16 - 1] which fits in 16 bits
        try w.writeInt(u16, card, .little);
        written_count += @sizeOf(u16) + @sizeOf(u16);
    }
    if ((!hasrun) or (len >= C.NO_OFFSET_THRESHOLD)) {
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

/// Convert array and bitmap containers to run containers when it is more
/// efficient; also convert from run containers when more space efficient.
///
/// Returns true if the result has at least one run container.
/// Additional savings might be possible by calling `shrink_to_fit()`.
pub fn run_optimize(r: *Bitmap, allocator: mem.Allocator) !bool {
    r.assert_valid();
    defer r.assert_valid();
    var answer = false;
    for (0..r.array.ptr(.len).*) |i| {
        // TODO // r.unshare_container_at_index(i); // TODO: this introduces extra cloning!
        const c1 = try r.convert_run_optimize(@intCast(i), allocator);
        if (c1.typecode == .run) answer = true;
        r.slice(.containers, .len)[i] = c1;
    }
    return answer;
}

/// Get the cardinality of the bitmap (number of elements).
pub fn cardinality(r: Bitmap) u64 {
    var card: u64 = 0;
    for (r.slice(.containers, .len)) |c| {
        card += c.compute_cardinality(r);
    }
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

/// once converted, the original container is disposed here.
///
// TODO: split into run- array- and bitset- subfunctions for sanity;
// a few function calls won't really matter.
pub fn convert_run_optimize(r: *Bitmap, cid: u32, allocator: mem.Allocator) !Container {
    const c = r.array.ptr(.containers)[cid];
    if (c.typecode == .run) {
        const newc = try r.convert_run_to_efficient_container(c, allocator);
        if (newc != c) r.array.ptr(.containers)[cid].deinit_blocks(r.*);
        return newc;
    } else if (c.typecode == .array) {
        // it might need to be converted to a run container.
        const nruns = r.array_number_of_runs(c);
        const nblocks = misc.numGroupsOfSize(nruns * @sizeOf(Rle16), C.BLOCK_SIZE);
        var rc: Container = .{
            .typecode = .run,
            .cardinality = @intCast(nruns),
            .nblocks_minus1 = @intCast(nblocks - 1),
            .blockoffset = @intCast(r.array.ptr(.blockslen).*),
        };
        const size_as_run_container = rc.serialized_size_in_bytes();
        const size_as_array_container = c.serialized_size_in_bytes();
        trace(@src(), "array. arraysize={} runsize={}", .{ size_as_array_container, size_as_run_container });
        if (size_as_array_container <= size_as_run_container) {
            return c;
        }
        // convert array to run container
        try r.extend_array(allocator, 0, nblocks);

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
        r.array.ptr(.blockslen).* += nblocks;
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
pub fn convert_run_to_efficient_container(r: *Bitmap, c: Container, allocator: mem.Allocator) !Container {
    assert(c.typecode == .run);
    const size_as_run_container = c.serialized_size_in_bytes();
    const size_as_bitset_container = @sizeOf(root.Bitset);
    const card = c.compute_cardinality(r.*);
    const size_as_array_container = card * @sizeOf(u16);
    const min_size_non_run = @min(size_as_bitset_container, size_as_array_container);
    if (size_as_run_container <= min_size_non_run) { // no conversion
        return c;
    }
    if (card <= C.DEFAULT_MAX_SIZE) {
        // to array
        const nblocks = misc.numGroupsOfSize(card * @sizeOf(u16), C.BLOCK_SIZE);
        var answer: Container = .{
            .blockoffset = @intCast(r.array.ptr(.blockslen).*),
            .cardinality = 0,
            .nblocks_minus1 = @intCast(nblocks - 1),
            .typecode = .array,
        };
        try r.extend_array(allocator, 0, nblocks);
        r.array.ptr(.blockslen).* += nblocks;
        const array = answer.blocks_as(.array, r.*);
        const runs = c.blocks_as(.run, r.*);
        for (0..c.cardinality) |rlepos| {
            const run_start: u32 = runs[rlepos].value;
            const run_end = run_start + runs[rlepos].length;

            var run_value: u16 = @truncate(run_start);
            while (run_value <= run_end) : (run_value += 1) {
                array[answer.cardinality] = run_value;
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

/// Whether you want to use flag: copy-on-write or frozen.
/// Saves memory and avoids copies, but needs more care in a threaded context.
/// Most users should ignore this flag.
///
/// Note: If you do turn this flag to 'true', enabling COW, then ensure that you
/// do so for all of your bitmaps, since interactions between bitmaps with and
/// without COW is unsafe.
///
/// When setting this flag to false, if any containers are shared, they
/// are unshared (cloned) immediately.
pub fn get_flag(r: Bitmap, flag: Flag) bool {
    return r.array.ptr(.flags).* & @as(u8, 1) << @intCast(@intFromEnum(flag)) != 0;
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
    if (!r.internal_validate_header(reason)) return false;
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

    for (r.slice(.containers, .len)) |*c| {
        if (c.typecode == .shared and !r.get_flag(.cow)) {
            reason.* = "shared container in non-COW bitmap";
            return false;
        }
        if (!c.internal_validate(reason, r)) {
            const cid = c - r.array.ptr(.containers);
            trace(@src(), "invalid container at index={} {f}", .{ cid, c.fmt(r, keys[cid]) });
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
            if (false)
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
        // again (ie when growing an array container).
        newarray.copyField(r.array, f);
    }
}

/// ensure new capacity and blockscapacity.  deinit if new capacity is 0.
/// new capacity or blockscapacity must be greater than existing.
///
/// modifies `Array` capacity and blockscapacity.
pub fn realloc_array(
    r: *Bitmap,
    allocator: mem.Allocator,
    new_capacity: u32,
    new_blockscapacity: u32,
) !void {
    if (new_capacity == 0) {
        r.deinit(allocator);
        return;
    }
    const capacity = r.array.ptr(.capacity).*;
    const blockscapacity = r.array.ptr(.blockscapacity).*;
    assert(new_capacity > capacity or new_blockscapacity > blockscapacity);

    const newlens: Model.Lengths = .{
        .capacity = @max(capacity, new_capacity),
        .blockscapacity = @max(blockscapacity, new_blockscapacity),
    };
    const lens = r.array.calcLens();
    const size = Model.calcSize(lens);
    // if (@import("build-options").trace) {
    //     const newsize = Model.calcSize(newlens);
    //     trace(@src(), "lens:old/new={},{}/{},{} sizes={B:.1}/{B:.1}", .{ lens.capacity, lens.blockscapacity, newlens.capacity, newlens.blockscapacity, size, newsize });
    // }
    if (r.is_empty()) {
        r.array = try Model.create(allocator, newlens);
        zero_init(r.array);
        return;
    }

    // TODO faster to realloc and move fields. when new size is larger?
    const newarray = try Model.create(allocator, newlens);
    r.copy_to(newarray);
    assert(r.array.ptr(.len).* == newarray.ptr(.len).*);
    assert(r.array.ptr(.blockslen).* == newarray.ptr(.blockslen).*);
    allocator.free(r.array.asBytes()[0..size]);
    r.array = newarray;
}

/// ensure the bitmap has room for more containers and more blocks.
pub fn extend_array(r: *Bitmap, allocator: mem.Allocator, more_len: u32, more_blockslen: u32) !void {
    const len = r.array.ptr(.len).*;
    const capacity = r.array.ptr(.capacity).*;
    const blockslen = r.array.ptr(.blockslen).*;
    const blockscapacity = r.array.ptr(.blockscapacity).*;
    const desired_len = len + more_len;
    const desired_blockslen = blockslen + more_blockslen;
    // trace(
    //     @src(),
    //     "len/cap={}/{} blocks:len/cap={}/{} more:len/blockslen={}/{} desired:len/blockslen={}/{}",
    //     .{ len, capacity, blockslen, blockscapacity, more_len, more_blockslen, desired_len, desired_blockslen },
    // );
    assert(desired_len < C.MAX_CONTAINERS and desired_blockslen < C.MAX_BLOCKS);

    if (desired_len > capacity or desired_blockslen > blockscapacity) {
        const new_capacity = @min(
            C.MAX_CONTAINERS,
            if (len < 1024) 2 * desired_len else @divFloor(5 * desired_len, 4),
        );

        const new_blockscapacity = @min(
            C.MAX_BLOCKS,
            if (len < 1024) 2 * desired_blockslen else @divFloor(5 * desired_blockslen, 4),
        );

        if (new_capacity > capacity or new_blockscapacity > blockscapacity)
            try r.realloc_array(allocator, new_capacity, new_blockscapacity);
    }
}

/// Shifts rightmost $count containers to the left (distance < 0) or
/// to the right (distance > 0).
///
/// Allocates distance new containers and blocks when distance > 0.
///
/// Modifies Bitmap len and blockslen, adding distance to both.
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
    try w.print("Bitmap: len/cap={}/{} blocks:len/cap={}/{} {B:.1}. Containers: ", .{
        r.array.ptr(.len).*,
        r.array.ptr(.capacity).*,
        r.array.ptr(.blockslen).*,
        r.array.ptr(.blockscapacity).*,
        Model.calcSize(r.array.calcLens()),
    });

    try w.writeByte('{');
    for (r.slice(.containers, .len), r.array.ptr(.keys), 0..) |*c, key, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{}:{f}", .{ key, c.fmt(r, key) });
    }
    try w.writeByte('}');
}

pub fn formatLong(r: Bitmap) FmtLong {
    return .{ .r = r };
}

pub const FmtLong = struct {
    r: Bitmap,
    pub fn format(f: FmtLong, w: *Io.Writer) !void {
        const r = f.r;
        if (r.is_empty()) {
            try w.writeAll("empty");
            return;
        }
        try w.print("Bitmap: len/cap={}/{} blocks:len/cap={}/{} {B:.1}. Containers: ", .{
            r.array.ptr(.len).*,
            r.array.ptr(.capacity).*,
            r.array.ptr(.blockslen).*,
            r.array.ptr(.blockscapacity).*,
            Model.calcSize(r.array.calcLens()),
        });

        try w.writeByte('{');
        for (r.slice(.containers, .len), r.array.ptr(.keys), 0..) |*c, key, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("{}:{f}", .{ key, c.fmtLong(r, key) });
        }
        try w.writeByte('}');
    }
};

/// FROZEN SERIALIZATION FORMAT DESCRIPTION
///
/// -- (beginning must be aligned by 32 bytes) --
///   - <bitset_data> uint64_t[BITSET_CONTAINER_SIZE_IN_WORDS * num_bitset_containers]
///   - <run_data>    rle16_t[total number of rle elements in all run containers]
///   - <array_data>  uint16_t[total number of array elements in all array containers]
///   - <keys>        uint16_t[num_containers]
///   - <counts>      uint16_t[num_containers]
///   - <typecodes>   uint8_t[num_containers]
///   - <header>      uint32_t
///
/// <header> is a 4-byte value which is a bit union of FROZEN_COOKIE (15 bits)
/// and the number of containers (17 bits).
///
/// <counts> stores number of elements for every container.
/// Its meaning depends on container type.
/// For array and bitset containers, this value is the container cardinality
/// minus one. For run container, it is the number of rle_t elements (n_runs).
///
/// <bitset_data>,<array_data>,<run_data> are flat arrays of elements of
/// all containers of respective type.
///
/// <*_data> and <keys> are kept close together because they are not accessed
/// during deserilization. This may reduce IO in case of large mmaped bitmaps.
/// All members have their native alignments during deserilization except
/// <header>, which is not guaranteed to be aligned by 4 bytes.
pub fn frozen_size_in_bytes(rb: *Bitmap) usize {
    var num_bytes: usize = 0;
    const len = rb.array.ptr(.len).*;
    const cs = rb.array.ptr(.containers);
    for (0..len) |i| {
        const c = cs[i];
        num_bytes += switch (c.typecode) {
            .bitset => @sizeOf(root.Bitset),
            .run => c.cardinality * @sizeOf(root.Rle16),
            .array => c.cardinality * @sizeOf(u16),
            else => unreachable,
        };
    }
    num_bytes += (2 + 2 + 1) * len; // keys, counts, typecodes
    num_bytes += 4; // header
    return num_bytes;
}

fn arena_alloc(T: type, arena: *[*]u8, count: usize) []align(1) T {
    const size = @sizeOf(T) * count;
    defer arena.* += size;
    return @as([]align(1) T, @ptrCast(arena.*[0..size]))[0..count];
}

pub fn frozen_serialize(r: Bitmap, buf: []u8) !void {
    // Note: we do not require user to supply a specifically aligned buffer.

    var bitset_zone_size: usize = 0;
    var run_zone_size: usize = 0;
    var array_zone_size: usize = 0;

    const len = r.array.ptr(.len).*;
    const cs = r.array.ptr(.containers);
    for (cs[0..len]) |c| {
        switch (c.typecode) {
            .bitset => bitset_zone_size += C.BITSET_CONTAINER_SIZE_IN_WORDS,
            .run => run_zone_size += c.cardinality,
            .array => array_zone_size += c.cardinality,
            .shared => unreachable,
        }
    }

    var cur = buf.ptr;
    var bitset_zone = arena_alloc(root.Word, &cur, bitset_zone_size).ptr;
    var run_zone = arena_alloc(root.Rle16, &cur, run_zone_size).ptr;
    var array_zone = arena_alloc(u16, &cur, array_zone_size).ptr;
    const key_zone = arena_alloc(u16, &cur, len);
    const count_zone = arena_alloc(u16, &cur, len);
    const typecode_zone = arena_alloc(Typecode, &cur, len);
    const header_zone = arena_alloc(u32, &cur, 1);
    assert(cur == buf.ptr + buf.len);
    const fixedw = Io.Writer.fixed;
    for (cs[0..len], count_zone, typecode_zone) |c, *count, *typecode| {
        // std.debug.print("c {f} typecode {}\n", .{ c, @intFromEnum(c.typecode) });
        typecode.* = c.typecode;
        count.* = @intCast(switch (c.typecode) {
            .bitset => blk: {
                var w = fixedw(mem.sliceAsBytes(bitset_zone[0..C.BITSET_CONTAINER_SIZE_IN_WORDS]));
                try w.writeSliceEndian(root.Word, c.blocks_as(.bitset, r), .little);
                assert(w.unusedCapacityLen() == 0);
                bitset_zone += C.BITSET_CONTAINER_SIZE_IN_WORDS;
                break :blk if (c.cardinality != C.BITSET_UNKNOWN_CARDINALITY)
                    (c.cardinality - 1)
                else
                    (c.compute_cardinality() - 1);
            },
            .run => blk: {
                var w = fixedw(mem.sliceAsBytes(run_zone[0..c.cardinality]));
                try w.writeSliceEndian(root.Rle16, c.blocks_as(.run, r)[0..c.cardinality], .little);
                assert(w.unusedCapacityLen() == 0);
                run_zone += c.cardinality;
                break :blk c.cardinality;
            },
            .array => blk: {
                var w = fixedw(mem.sliceAsBytes(array_zone[0..c.cardinality]));
                try w.writeSliceEndian(u16, c.blocks_as(.array, r)[0..c.cardinality], .little);
                assert(w.unusedCapacityLen() == 0);
                array_zone += c.cardinality;
                break :blk c.cardinality - 1;
            },
            else => unreachable,
        });
    }
    var keysw = fixedw(mem.sliceAsBytes(key_zone[0..len]));
    try keysw.writeSliceEndian(u16, r.array.ptr(.keys)[0..len], .little);
    var headerw = fixedw(mem.sliceAsBytes(header_zone[0..1]));
    try headerw.writeInt(
        u32,
        (@as(u32, @intCast(len)) << 15) | @intFromEnum(root.Magic.FROZEN_COOKIE),
        .little,
    );
}

/// shrink containers if they use extra blocks then copy used blocks to a new allocation.
pub fn shrink_to_fit(r: *Bitmap, allocator: mem.Allocator) !usize {
    const capacity = r.array.ptr(.capacity).*;
    const blockscapacity = r.array.ptr(.blockscapacity).*;
    const len = r.array.ptr(.len).*;
    const blockslen = r.array.ptr(.blockslen).*;

    var answer: usize = 0;
    for (0..len) |i| {
        const c = &r.array.ptr(.containers)[i];
        assert(c.* != Container.uninit); // TODO handle previously deinit() containers/blocks marked .uninit/0xff
        answer += try c.shrink_to_fit(r.*);
    }
    if (answer == 0 and capacity == len and blockscapacity == blockslen)
        return 0;

    const size = Model.calcSize(.{ .capacity = capacity, .blockscapacity = blockscapacity });
    const newlens = Model.Lengths{ .capacity = len, .blockscapacity = blockslen };
    const newsize = Model.calcSize(newlens);
    const keysoffset = r.array.offsetOf(.keys);
    const buf = try allocator.alignedAlloc(u8, C.BLOCK_ALIGNMENT, newsize);
    // copy non-array fields
    @memcpy(buf[0..keysoffset], r.array.asBytes()[0..keysoffset]);
    const newarray: *Model = @ptrCast(buf);
    newarray.ptr(.capacity).* = len;
    newarray.ptr(.blockscapacity).* = blockslen;
    const newr = Bitmap{ .array = newarray };
    // copy keys and containers
    newarray.copyField(r.array, .keys);
    newarray.copyField(r.array, .containers);
    // copy blocks
    const blocks = newarray.ptr(.blocks);
    var block = blocks;
    const cs = r.array.ptr(.containers);
    const newcs = newarray.ptr(.containers);
    for (0..len) |i| {
        newcs[i].blockoffset = @intCast(block - blocks);
        block += cs[i].nblocks();
        @memcpy(newcs[i].get_blocks(newr), cs[i].get_blocks(r.*));
    }
    allocator.free(r.array.asBytes()[0..size]);
    r.array = newarray;

    return answer + size - newsize;
}

pub fn remove_at_index(ra: Bitmap, i: u32) void {
    const len = ra.array.ptr(.len).*;
    const ctrs = ra.array.ptr(.containers);
    const keys = ra.array.ptr(.keys);
    ctrs[i].deinit_blocks(ra);
    @memmove(ctrs[i..], ctrs[i + 1 ..][0..len]);
    @memmove(keys[i..], keys[i + 1 ..][0..len]);
    ra.array.ptr(.len).* -= 1;
}

/// Effectively deletes the value at index index, repacking data.
pub fn recoverRoomAtIndex(r: Bitmap, run: *Container, index: u16) void {
    const runs = run.blocks_as(.run, r)[0..run.cardinality].ptr;
    @memmove(runs + index, (runs + (1 + index))[0 .. run.cardinality - index - 1]);
    run.cardinality -= 1;
}

/// Moves the data so that we can write data at index
pub fn makeRoomAtIndex(r: *Bitmap, allocator: mem.Allocator, run: *Container, index: u16) !void {
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

pub fn clear_retaining_capacity(r: *Bitmap) void {
    if (r.is_empty()) return;
    r.array.ptr(.len).* = 0;
    r.array.ptr(.blockslen).* = 0;
}

pub fn remove(r: *Bitmap, allocator: mem.Allocator, val: u32) !void {
    _ = try r.remove_checked(allocator, val);
}

pub fn remove_checked(r: *Bitmap, allocator: mem.Allocator, val: u32) !bool {
    r.assert_valid();
    defer r.assert_valid();
    const key: u16 = @truncate(val >> 16);
    const i = r.get_key_index(key);
    if (i >= 0) {
        // TODO // r.unshare_container_at_index(i);
        const iu: u32 = @intCast(i);
        var container = r.array.ptr(.containers)[iu];
        const oldCardinality = container.get_cardinality(r.*);
        const container2 = try container.remove(allocator, @truncate(val), r);
        if (container2 != container) {
            container.deinit_blocks(r.*);
            r.array.ptr(.containers)[iu] = container2;
        }

        const newCardinality = container2.get_cardinality(r.*);
        if (newCardinality != 0) {
            r.array.ptr(.containers)[iu] = container2;
        } else {
            r.array.ptr(.containers)[iu].deinit(r.*);
        }
        return oldCardinality != newCardinality;
    }
    return false;
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
