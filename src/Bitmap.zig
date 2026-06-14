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
    /// a bitset of `Flag`.
    flags: u8,
    /// container keys.
    keys: flexible.Array(u16, .capacity) align(C.BLOCK_ALIGN),
    /// container descriptors.
    containers: flexible.Array(Container, .capacity) align(C.BLOCK_ALIGN),
    /// container data stored as blocks.
    blocks: flexible.Array(Block, .blockscapacity),
};

/// Context for bulk add operations.  Must be default init before use.
pub const BulkContext = struct {
    container: *Container = @constCast(&Container.uninit),
    idx: u32 = 0,
    key: u32 = 0,
};

pub const Model = flexible.Struct(Array);
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

pub const free = deinit;

pub fn deinit(r: *Bitmap, allocator: Allocator) void {
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

/// Allocates room for container_count containers and blocks, with minimum of 16.
pub fn create_with_capacity(allocator: Allocator, container_count: u32) !Bitmap {
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
    allocator: Allocator,
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
    allocator: Allocator,
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
        c.cardinality = @as(Cardinality, kc.cardinality_minus1) + 1;
    }

    // skip file offsets
    if (!hasruns or (hasruns and len >= C.NO_OFFSET_THRESHOLD))
        _ = try r.discard(.limited(len * @sizeOf(u32)));

    assert(freader.logicalPos() == rb.portable_size());
}

/// insert key and container at index i, increment array.len by 1.
pub fn insert_new_key_value_at(
    r: *Bitmap,
    allocator: Allocator,
    key: u16,
    c: Container,
    i: u32,
) !void {
    try r.ensure_unused_capacity(allocator, 1, 0);
    const len = r.array.ptr(.len).*;
    const ks = r.array.ptr(.keys)[0..len];
    const cs = r.array.ptr(.containers)[0..len];
    @memmove(ks.ptr + i + 1, ks[i..]);
    ks.ptr[i] = key;
    @memmove(cs.ptr + i + 1, cs[i..]);
    cs.ptr[i] = c;
    r.array.ptr(.len).* += 1;
}

/// add `vals` to bitmap.  returns count of unique `vals` added.
pub fn add_many(r: *Bitmap, allocator: Allocator, vals: []const u32) !usize {
    // TODO estimate how many containers and blocks are needed, preallocate and then use assume capacity api.
    trace(@src(), "vals={}:{?}..{?}", .{ vals.len, if (vals.len > 0) vals[0] else null, if (vals.len > 1) vals[vals.len - 1] else null });
    trace(@src(), "{f}", .{r.fmtLong()});
    var ret: usize = 0;
    var ctx: BulkContext = .{};
    for (vals) |v| {
        ret += @intFromBool(try r.add_checked_bulk(allocator, &ctx, v));
    }
    return ret;
}

/// add val to bitmap.
pub fn add(r: *Bitmap, allocator: Allocator, val: u32) !void {
    _ = try r.add_checked(allocator, val);
}

/// returns true when `value` was added to the bitmap, false if already present.
pub fn add_checked(r: *Bitmap, allocator: Allocator, value: u32) !bool {
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
            if (oldc.blockoffset != c2.blockoffset) { // skip deinit of inplace conversion
                oldc.deinit_blocks(r.*);
            }
            r.array.ptr(.containers)[cid] = c2;
        }
        return oldc.cardinality != c2.cardinality;
    } else { // key not found, add new array container
        const cid: u32 = @intCast(-mcontaineridx - 1);
        const blockslen = r.array.ptr(.blockslen).*;
        try r.ensure_unused_capacity(allocator, 1, 1);
        r.array.ptr(.blockslen).* += 1;
        r.insert_new_key_value_at(allocator, key, .{
            .blockoffset = @intCast(blockslen),
            .nblocks_minus1 = 0,
            .cardinality = 0,
            .typecode = .array,
        }, cid) catch unreachable; // unreachable, kv already reserved
        const newac = &r.array.ptr(.containers)[cid];
        _ = try newac.add(allocator, r, valuelow); // ignore return. always an array with cardinality 1
        return true;
    }

    assert(r.contains(value));
}

/// this is like `add`, but it populates pointer arguments in such a
/// way that we can recover the container touched, which, in turn can be used to
/// accelerate some functions (when you repeatedly need to add to the same
/// container)
fn containerptr_add(r: *Bitmap, allocator: Allocator, val: u32, index: *u32) !*Container {
    const key: u16 = @truncate(val >> 16);
    const i = misc.binarySearch(r.slice(.keys, .len), key);
    if (i >= 0) {
        // TODO //  ra_unshare_container_at_index(ra, @truncate(i));
        const iu: u32 = @bitCast(i);
        var c = &r.array.ptr(.containers)[iu];
        const c2 = try c.add(allocator, r, @truncate(val));
        c = &r.array.ptr(.containers)[iu];
        index.* = iu;
        if (c2 != c.*) {
            c.deinit_blocks(r.*);
            r.array.ptr(.containers)[iu] = c2;
            return &r.array.ptr(.containers)[iu];
        } else {
            return c;
        }
    } else {
        const blockslen = r.array.ptr(.blockslen).*;
        try r.ensure_unused_capacity(allocator, 1, 1);
        r.array.ptr(.blockslen).* += 1;

        index.* = @intCast(-i - 1);
        r.insert_new_key_value_at(allocator, key, .{
            .blockoffset = @intCast(blockslen),
            .nblocks_minus1 = 0,
            .cardinality = 0,
            .typecode = .array,
        }, index.*) catch unreachable; // unreachable, kv already reserved
        const newac = &r.array.ptr(.containers)[index.*];
        _ = try newac.add(allocator, r, @truncate(val));
        return &r.array.ptr(.containers)[index.*];
    }
}

/// similar to `add_bulk_impl` from croaring
pub fn add_checked_bulk(
    r: *Bitmap,
    allocator: Allocator,
    context: *BulkContext,
    val: u32,
) !bool {
    const key: u16 = @truncate(val >> 16);
    if (context.container.* == Container.uninit or context.key != key) { // not found
        context.container = try r.containerptr_add(allocator, val, &context.idx);
        context.key = key;
        return true;
    } else {
        // no need to seek the container, it is at hand
        // because we already have the container at hand, we can do the
        // insertion directly, bypassing `add`
        const card = context.container.cardinality;
        const c2 = try context.container.add(allocator, r, @truncate(val));
        context.container = &r.array.ptr(.containers)[context.idx];
        if (c2 != context.container.*) {
            // rare instance when we need to change the container
            context.container.deinit_blocks(r.*);
            r.array.ptr(.containers)[context.idx] = c2;
            context.container.* = c2;
        }
        return context.container.cardinality != card;
    }
}

pub fn add_bulk(r: *Bitmap, allocator: Allocator, context: *BulkContext, val: u32) !void {
    _ = try r.add_checked_bulk(allocator, context, val);
}

fn append(r: *Bitmap, allocator: Allocator, key: u16, c: Container) !void {
    try r.ensure_unused_capacity(allocator, 1, 0);
    const pos = r.array.ptr(.len).*;
    r.array.ptr(.keys)[pos] = key;
    r.array.ptr(.containers)[pos] = c;
    r.array.ptr(.len).* += 1;
}

/// The new container contains the range [start,stop).
/// It is required that stop>start, the caller is responsible for this check.
/// It is required that stop <= (1<<16), the caller is responsibe for this
/// check. The cardinality of the created container is stop - start.
pub fn create_range(
    r: *Bitmap,
    allocator: Allocator,
    tc: Typecode,
    start: u32,
    stop: u32,
) !Container {
    switch (tc) {
        .run => {
            var c = try Container.run_container_create_given_capacity(allocator, 1, r);
            c.append_first(r.*, Rle16{
                .value = @truncate(start),
                .length = @truncate(stop - start - 1),
            });
            return c;
        },
        .array => {
            var c = try Container.array_container_create_given_capacity(allocator, stop - start, r);
            const array = c.blocks_as(.array, r.*);
            var k: u32 = @intCast(start);
            while (k < stop) : (k += 1) {
                array[c.cardinality] = @intCast(k);
                c.cardinality += 1;
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
    r: *Bitmap,
    allocator: Allocator,
    range_start: u32,
    range_end: u32,
) !Container {
    assert(range_end >= range_start);
    const card = range_end - range_start + 1;
    return if (card <= 2)
        try r.create_range(allocator, .array, range_start, range_end)
    else
        try r.create_range(allocator, .run, range_start, range_end);
}

/// Create a container with all the values between in [min,max) at a
/// distance k*step from min.
pub fn from_range(
    r: *Bitmap,
    allocator: Allocator,
    min: u32,
    max: u32,
    step: u16,
) !Container {
    // trace(@src(), "{}-{} step {}", .{ min, max, step });
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

/// Find the cardinality of the bitset in [begin,begin+lenminusone]
fn bitset_lenrange_cardinality(
    words: [*]align(C.BLOCK_ALIGN) u64,
    start: u32,
    lenminusone: u32,
) u32 {
    const firstword = start / 64;
    const endword = (start + lenminusone) / 64;
    if (firstword == endword) {
        return @popCount(words[firstword] &
            ((~@as(u64, 0)) >>
                @truncate((63 - lenminusone) % 64)) <<
                @truncate(start % 64));
    }
    var answer: u64 =
        @popCount(words[firstword] & ((~@as(u64, 0)) << @truncate(start % 64)));
    for (firstword + 1..endword) |i| {
        answer += @popCount(words[i]);
    }
    answer += @popCount(words[endword] &
        (~@as(u64, 0)) >>
            @truncate(((~start +% 1) -% lenminusone -% 1) % 64));
    return @intCast(answer);
}

/// Adds all values in range [min,max] using hint:
///   nvals_less is the number of array values less than $min
///   nvals_greater is the number of array values greater than $max
fn array_container_add_range_nvals(
    r: *Bitmap,
    allocator: Allocator,
    ac: *Container,
    min: u32,
    max: u32,
    nvals_less: u32,
    nvals_greater: u32,
) !void {
    const union_cardinality = nvals_less + (max - min + 1) + nvals_greater;
    // trace(@src(), "union_cardinality={} ac.calc_capacity()={}", .{ union_cardinality, ac.calc_capacity() });
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

fn container_from_run_range(
    r: *Bitmap,
    allocator: Allocator,
    run: Container,
    min: u32,
    max: u32,
) !Container {
    // We expect most of the time to end up with a bitset container
    var bitset = try Container.bitset_container_create(allocator, r);
    const words = bitset.blocks_as(.bitset, r.*);
    var union_cardinality: u32 = 0;
    const runs = run.blocks_as(.run, r.*)[0..run.cardinality];
    for (0..run.cardinality) |i| {
        const rle_min: u32 = runs[i].value;
        const rle_max: u32 = rle_min + runs[i].length;
        misc.bitset_set_lenrange(words.ptr, rle_min, rle_max - rle_min);
        union_cardinality += runs[i].length + 1;
    }
    union_cardinality += @intCast(max - min + 1);
    union_cardinality -=
        bitset_lenrange_cardinality(words.ptr, min, max - min);
    misc.bitset_set_lenrange(words.ptr, min, max - min);
    bitset.cardinality = @intCast(union_cardinality);
    if (union_cardinality <= C.DEFAULT_MAX_SIZE) {
        // convert to an array container
        const array = try bitset.array_container_from_bitset(allocator, r);
        bitset.deinit_blocks(r.*);
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
    allocator: Allocator,
    c: *Container,
    min: u32,
    max: u32,
) !Container {
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
                return try Container.run_container_create_range(allocator, 0, C.MAX_KEY_CARDINALITY, r);
            } else {
                misc.bitset_set_lenrange(words.ptr, min, max - min);
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
            if (union_cardinality == C.MAX_KEY_CARDINALITY) {
                return try Container.run_container_create_range(allocator, 0, C.MAX_KEY_CARDINALITY, r);
            } else if (union_cardinality <= C.DEFAULT_MAX_SIZE) {
                try r.array_container_add_range_nvals(allocator, c, min, max, nvals_less, nvals_greater);
                return r.array.ptr(.containers)[cid];
            } else {
                var bitset = try c.bitset_container_from_array(allocator, r);
                misc.bitset_set_lenrange(bitset.blocks_as(.bitset, r.*).ptr, min, max - min);
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

            trace(@src(), "run run_size_bytes={}", .{run_size_bytes});
            if (run_size_bytes <= @sizeOf(root.Bitset)) {
                try c.run_container_add_range_nruns(allocator, r, min, max, nruns_less, nruns_greater);
                return r.array.ptr(.containers)[cid];
            }
            return r.container_from_run_range(allocator, c.*, min, max);
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
pub fn add_range_closed(r: *Bitmap, allocator: Allocator, min: u32, max: u32) !void {
    assert_valid(r.*);
    defer assert_valid(r.*);

    if (min > max) return;
    if (r.is_empty()) {
        @branchHint(.unlikely);
        r.* = try create_with_capacity(allocator, 0);
    }

    trace(@src(), "[{},{})#{}", .{ min, max, max - min });
    trace(@src(), "{f}", .{r.fmtLong()});

    const min_key = min >> 16;
    const max_key = max >> 16;
    const num_required_containers = max_key - min_key + 1;
    const len = r.array.ptr(.len).*;
    const keys = r.array.ptr(.keys)[0..len];
    const blockoffset = r.array.ptr(.blockslen).*;
    errdefer { // maintain initial lens on error
        if (!r.is_empty()) {
            r.array.ptr(.len).* = len;
            r.array.ptr(.blockslen).* = blockoffset;
        }
    }
    const suffix_length = misc.count_greater(keys, @truncate(max_key));
    const prefix_length = misc.count_less(keys[0 .. len - suffix_length], @truncate(min_key));
    const common_length = len - prefix_length - suffix_length;
    // trace(@src(), "num_required_containers={} prefix_length={} suffix_length={} common_length={}", .{ num_required_containers, prefix_length, suffix_length, common_length });
    if (num_required_containers > common_length) {
        const distance = num_required_containers - common_length;
        try r.shift_tail(allocator, suffix_length, @bitCast(distance));
        @memset(r.slice(.containers, .len)[prefix_length + common_length ..][0..@intCast(distance)], .uninit);
    }

    var src: i32 = @bitCast(prefix_length + common_length -% 1);
    var dst = r.array.ptr(.len).* - suffix_length -% 1;
    var key = max_key;
    // trace(@src(), "dst={} src={} len={}", .{ dst, src, r.array.ptr(.len).* });
    while (key +% 1 != min_key) : (key -%= 1) { // beware of min_key==0
        // trace(@src(), "dst={} key={} min_key={} max_key={} len={} blockoffset={}", .{ dst, key, min_key, max_key, r.array.ptr(.len).*, blockoffset });
        const container_min = if (min_key == key) min & 0xffff else 0;
        const container_max = if (max_key == key) max & 0xffff else 0xffff;
        var newc: Container = .uninit;
        const srcu: u32 = @bitCast(src);
        if (src >= 0 and r.slice(.keys, .len)[srcu] == key) {
            // TODO // ra.unshare_container_at_index(srcu);
            const c = &r.array.ptr(.containers)[srcu];
            newc = try r.container_add_range(allocator, c, container_min, container_max);
            if (newc != r.array.ptr(.containers)[srcu]) {
                if (newc.blockoffset != r.array.ptr(.containers)[srcu].blockoffset)
                    r.array.ptr(.containers)[srcu].deinit_blocks(r.*);
            }
            src -= 1;
        } else {
            newc = try r.from_range(allocator, container_min, container_max + 1, 1);
        }
        // trace(@src(), "dst {}, newc {f}", .{ dst, newc.fmt(r.*, @intCast(key)) });
        assert(newc != Container.uninit);
        r.replace_key_and_container_at_index(dst, @truncate(key), newc);
        dst -%= 1;
    }
}

/// Add all values in range [min, max)
pub fn add_range(r: *Bitmap, allocator: Allocator, min: u64, max: u64) !void {
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

/// returns the index of x or -1 if not found.
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
pub fn run_optimize(r: *Bitmap, allocator: Allocator) !bool {
    r.assert_valid();
    trace(@src(), "{f}", .{r.fmtLong()});
    defer r.assert_valid();
    var answer = false;
    for (0..r.array.ptr(.len).*) |i| {
        // TODO // r.unshare_container_at_index(i); // TODO: this introduces extra cloning!
        const c1 = try Container.convert_run_optimize(@intCast(i), allocator, r);
        if (c1.typecode == .run) answer = true;
        r.slice(.containers, .len)[i] = c1;
    }
    return answer;
}

/// Get the cardinality of the bitmap (number of elements).
pub fn get_cardinality(r: Bitmap) u64 {
    var card: i64 = 0; // signed for sign extension, matching C i32->u64
    for (r.slice(.containers, .len)) |c| {
        // sign extend C.BITSET_UNKNOWN_CARDINALITY, u30 max, to i64 min.
        const cc: Container.ICardinality = @bitCast(c.get_cardinality(r));
        card += @as(i64, cc);
    }
    return @bitCast(card);
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
            trace(@src(), "invalid container at index={}: {f}", .{ cid, c.fmtLong(r, keys[cid]) });
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
        trace(@src(), "{f}", .{r.fmtLong()});
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
    allocator: Allocator,
    new_capacity: u32,
    new_blockscapacity: u32,
) !void {
    if (new_capacity == 0 and new_blockscapacity == 0) {
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
    if (r.is_empty()) {
        r.array = try Model.create(allocator, newlens);
        zero_init(r.array);
        return;
    }

    errdefer {
        allocator.free(r.array.asBytes()[0..size]);
        r.array = empty.array;
    }
    // TODO faster to realloc and move fields. when new size is larger?
    const newarray = try Model.create(allocator, newlens);
    r.copy_to(newarray);
    assert(r.array.ptr(.len).* == newarray.ptr(.len).*);
    assert(r.array.ptr(.blockslen).* == newarray.ptr(.blockslen).*);
    allocator.free(r.array.asBytes()[0..size]);
    r.array = newarray;
}

/// similar to croaring.extend_array.
///
/// ensure the bitmap has room for more containers and more blocks. may modify
/// `Array` capacity and blockscapacity.
// TODO audit callsites and blockslen usage
pub fn ensure_unused_capacity(r: *Bitmap, allocator: Allocator, more_len: u32, more_blockslen: u32) !void {
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
/// Allocates distance new containers when distance > 0.
///
/// Modifies Bitmap len, adding distance.
pub fn shift_tail(r: *Bitmap, allocator: Allocator, count: u32, distance: i32) !void {
    if (distance > 0) {
        try r.ensure_unused_capacity(allocator, @bitCast(distance), 0);
    }
    const len = r.array.ptr(.len);
    const srcpos = len.* - count;
    const dstpos = srcpos +% @as(u32, @bitCast(distance));
    // trace(@src(), "count={} distance={} srcpos={} dstpos={}", .{ count, distance, srcpos, dstpos });
    len.* +%= @bitCast(distance);

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

pub fn fmtLong(r: Bitmap) FmtLong {
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

        // try w.writeAll("\nindex key   type   card    location nruns  : contents");
        for (r.slice(.containers, .len), r.array.ptr(.keys), 0..) |*c, key, i| {
            try w.print("\n{: <5} {: <5} {f}", .{ i, key, c.fmtLong(r, key) });
        }
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
                    (c.compute_cardinality(r) - 1);
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
pub fn shrink_to_fit(r: *Bitmap, allocator: Allocator) !usize {
    const capacity = r.array.ptr(.capacity).*;
    const blockscapacity = r.array.ptr(.blockscapacity).*;
    const len = r.array.ptr(.len).*;
    // possibly shrink containers before calculating new blockslen
    var containersavings: usize = 0;
    for (0..len) |i| {
        const c = &r.array.ptr(.containers)[i];
        assert(c.* != Container.uninit);
        containersavings += try c.shrink_to_fit(r.*);
    }

    var blockslen: u32 = 0;
    for (r.slice(.containers, .len)) |c| blockslen += c.nblocks();

    if (containersavings == 0 and capacity == len and blockscapacity == blockslen)
        return 0; // no shrinking possible

    const newlens = Model.Lengths{ .capacity = len, .blockscapacity = blockslen };
    const newsize = Model.calcSize(newlens);
    const buf = try allocator.alignedAlloc(u8, C.BLOCK_ALIGNMENT, newsize);
    // copy non-array fields
    const keysoffset = r.array.offsetOf(.keys);
    @memcpy(buf[0..keysoffset], r.array.asBytes()[0..keysoffset]);
    const newarray: *Model = @ptrCast(buf);
    newarray.ptr(.capacity).* = len;
    newarray.ptr(.blockscapacity).* = blockslen;
    newarray.ptr(.len).* = len;
    newarray.ptr(.blockslen).* = blockslen;
    // copy keys and containers
    newarray.copyField(r.array, .keys);
    newarray.copyField(r.array, .containers);
    // copy blocks
    const blocks = newarray.ptr(.blocks);
    var block = blocks;
    const cs = r.array.ptr(.containers);
    const newcs = newarray.ptr(.containers);
    const newr = Bitmap{ .array = newarray };
    for (0..len) |i| {
        newcs[i].blockoffset = @intCast(block - blocks);
        block += cs[i].nblocks();
        @memcpy(newcs[i].get_blocks(newr), cs[i].get_blocks(r.*));
    }
    const size = Model.calcSize(.{ .capacity = capacity, .blockscapacity = blockscapacity });
    allocator.free(r.array.asBytes()[0..size]);
    r.array = newarray;

    return containersavings + size - newsize;
}

pub fn remove_at_index(r: Bitmap, i: u32) void {
    const len = r.array.ptr(.len).*;
    const ctrs = r.array.ptr(.containers);
    const keys = r.array.ptr(.keys);
    ctrs[i].deinit_blocks(r);
    @memmove(ctrs[i..], ctrs[i + 1 ..][0 .. len - i - 1]);
    @memmove(keys[i..], keys[i + 1 ..][0 .. len - i - 1]);
    r.array.ptr(.len).* -= 1;
}

/// Effectively deletes the value at index index, repacking data.
pub fn recoverRoomAtIndex(r: Bitmap, run: *Container, index: u16) void {
    const runs = run.blocks_as(.run, r)[0..run.cardinality].ptr;
    @memmove(runs + index, (runs + (1 + index))[0 .. run.cardinality - index - 1]);
    run.cardinality -= 1;
}

fn clear_containers(r: Bitmap) void {
    for (r.array.ptr(.containers)) |*c| {
        c.deinit(r);
    }
}

pub fn clear(r: *Bitmap, allocator: Allocator) void {
    if (r.is_empty()) return;
    r.clear_containers();
    r.array.ptr(.len).* = 0;
    r.array.ptr(.blockslen).* = 0;
    r.shrink_to_fit(allocator);
}

pub fn clear_retaining_capacity(r: *Bitmap) void {
    if (r.is_empty()) return;
    @memset(r.array.slice(.containers), undefined);
    @memset(r.array.slice(.keys), undefined);
    r.array.ptr(.len).* = 0;
    r.array.ptr(.blockslen).* = 0;
}

pub fn remove(r: *Bitmap, allocator: Allocator, val: u32) !void {
    _ = try r.remove_checked(allocator, val);
}

pub fn remove_checked(r: *Bitmap, allocator: Allocator, val: u32) !bool {
    r.assert_valid();
    defer r.assert_valid();
    trace(@src(), "val={}", .{val});
    const key: u16 = @truncate(val >> 16);
    const i = r.get_key_index(key);
    if (i >= 0) {
        // TODO // r.unshare_container_at_index(i);
        const iu: u32 = @intCast(i);
        const c = &r.array.ptr(.containers)[iu];
        const oldc = c.*;
        const oldcard = c.get_cardinality(r.*);
        const c2 = try c.remove(allocator, @truncate(val), r);
        if (c2 != oldc) {
            if (oldc.blockoffset != c2.blockoffset)
                oldc.deinit_blocks(r.*);
            r.array.ptr(.containers)[iu] = c2;
        }

        const newcard = c2.get_cardinality(r.*);
        // trace(@src(), "old/newcard={}/{} c2={f}", .{ oldcard, newcard, c2.fmt(r.*, c.get_key(r.*)) });
        if (newcard != 0) {
            r.array.ptr(.containers)[iu] = c2;
        } else {
            r.array.ptr(.containers)[iu].deinit(r.*);
        }
        return oldcard != newcard;
    }
    return false;
}

pub fn is_cow(x1: Bitmap) bool {
    return (x1.array.ptr(.flags).* & 1 << @intFromEnum(Flag.cow)) != 0;
}

pub fn set_copy_on_write(x1: Bitmap, cow: bool) void {
    x1.array.ptr(.flags).* |= (@as(u8, @intFromBool(cow)) << @intFromEnum(Flag.cow));
}

fn advance_until(ra: Bitmap, x: u16, pos: u32) u32 {
    return misc.advanceUntil(ra.slice(.keys, .len), pos, x);
}

pub fn copy(r: Bitmap, allocator: Allocator) !Bitmap {
    if (r.is_empty()) return r;
    const lens = r.array.calcLens();
    const buflen = Bitmap.Model.calcSize(lens);
    const buf = try allocator.alignedAlloc(u8, C.BLOCK_ALIGNMENT, buflen);
    const ret: Bitmap = .{ .array = .initBuffer(buf, lens) };
    r.copy_to(ret.array);
    return ret;
}

pub fn overwrite(r: *Bitmap, allocator: Allocator, src: Bitmap) !void {
    const new_copy = try src.copy(allocator);
    r.deinit(allocator);
    r.* = new_copy;
}

pub fn is_subset(r1: Bitmap, r2: Bitmap) bool {
    const keys1 = r1.slice(.keys, .len);
    const keys2 = r2.slice(.keys, .len);
    const containers1 = r1.slice(.containers, .len);
    const containers2 = r2.slice(.containers, .len);
    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (pos1 < containers1.len and pos2 < containers2.len) {
        const key1 = keys1[pos1];
        const key2 = keys2[pos2];
        if (key1 == key2) {
            if (!containers1[pos1].is_subset(r1, containers2[pos2], r2))
                return false;
            pos1 += 1;
            pos2 += 1;
        } else if (key1 < key2) {
            return false;
        } else {
            pos2 = misc.advanceUntil(keys2, pos2, key1);
        }
    }
    return pos1 == containers1.len;
}

pub fn is_strict_subset(r1: Bitmap, r2: Bitmap) bool {
    return r2.get_cardinality() > r1.get_cardinality() and r1.is_subset(r2);
}

pub const @"and" = intersect;

/// Computes the intersection between two bitmaps and returns new bitmap. The
/// caller is responsible for memory management.
///
/// Performance hint: if you are computing the intersection between several
/// bitmaps, two-by-two, it is best to start with the smallest bitmap.
/// You may also rely on and_inplace to avoid creating many temporary bitmaps.
// there should be some SIMD optimizations possible here
pub fn intersect(x1: *const Bitmap, allocator: Allocator, x2: *const Bitmap) !Bitmap {
    const length1 = x1.array.ptr(.len).*;
    const length2 = x2.array.ptr(.len).*;
    var answer = try create_with_capacity(allocator, @max(length1, length2));
    answer.set_copy_on_write(x1.is_cow() or x2.is_cow());
    defer answer.assert_valid();
    trace(@src(), "x1={f}", .{x1.fmtLong()});
    trace(@src(), "x2={f}", .{x2.fmtLong()});

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (pos1 < length1 and pos2 < length2) {
        const key1 = x1.array.ptr(.keys)[pos1];
        const key2 = x2.array.ptr(.keys)[pos2];

        if (key1 == key2) {
            const c1 = &x1.array.ptr(.containers)[pos1];
            const c2 = &x2.array.ptr(.containers)[pos2];
            const c = try Container.intersect(c1, allocator, x1, c2, x2, &answer);

            if (c.nonzero_cardinality(answer)) {
                try answer.append(allocator, key1, c);
            } else if (c != Container.uninit) {
                c.deinit_blocks(answer); // otherwise: memory leak!
            }
            pos1 += 1;
            pos2 += 1;
        } else if (key1 < key2) { // key1 < key2
            pos1 = x1.advance_until(key2, pos1);
        } else { // s1 > key2
            pos2 = x2.advance_until(key1, pos2);
        }
    }
    return answer;
}

/// Append new key-value pairs to ra, cloning (in COW sense) values from sa at
/// indexes [start_index, end_index)
fn append_copy_range(
    ra: *Bitmap,
    allocator: Allocator,
    sa: *const Bitmap,
    start_index: u32,
    end_index: u32,
    copy_on_write: bool,
) !void {
    const sakeys = sa.array.ptr(.keys);
    const sacontainers = sa.array.ptr(.containers);
    var cnblocks: u32 = 0;
    for (sacontainers[start_index..end_index]) |c| {
        cnblocks += c.nblocks();
    }
    try ra.ensure_unused_capacity(allocator, end_index - start_index, cnblocks);

    for (start_index..end_index) |i| {
        const pos = ra.array.ptr(.len).*;
        ra.array.ptr(.keys)[pos] = sakeys[i];
        const c = if (copy_on_write)
            try sacontainers[i].get_copy_of_container(allocator, sa, ra, copy_on_write)
        else
            try sacontainers[i].clone(allocator, sa, ra);
        ra.array.ptr(.containers)[pos] = c;
        ra.array.ptr(.len).* += 1;
    }
}

/// Computes the union between two bitmaps and returns new bitmap. The caller is
/// responsible for memory management.
pub const @"or" = merge;

pub fn merge(x1: *const Bitmap, allocator: Allocator, x2: *const Bitmap) !Bitmap {
    trace(@src(), "x1={f}", .{x1.fmtLong()});
    trace(@src(), "x2={f}", .{x2.fmtLong()});
    const length1 = x1.array.ptr(.len).*;
    const length2 = x2.array.ptr(.len).*;
    if (length1 == 0) return try x2.copy(allocator);
    if (length2 == 0) return try x1.copy(allocator);

    var answer = try create_with_capacity(allocator, length1 + length2);
    answer.set_copy_on_write(x1.is_cow() or x2.is_cow());
    defer answer.assert_valid();

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (pos1 < length1 and pos2 < length2) {
        const key1 = x1.array.ptr(.keys)[pos1];
        const key2 = x2.array.ptr(.keys)[pos2];

        if (key1 == key2) {
            const c1 = &x1.array.ptr(.containers)[pos1];
            const c2 = &x2.array.ptr(.containers)[pos2];
            const c = try Container.merge(c1, allocator, x1, c2, x2, &answer);
            try answer.append(allocator, key1, c);
            pos1 += 1;
            pos2 += 1;
        } else if (key1 < key2) {
            const c1 = x1.array.ptr(.containers)[pos1];
            const c = try Container.get_copy_of_container(c1, allocator, x1, &answer, x1.is_cow());
            try answer.append(allocator, key1, c);
            pos1 += 1;
        } else {
            const c2 = x2.array.ptr(.containers)[pos2];
            const c = try Container.get_copy_of_container(c2, allocator, x2, &answer, x2.is_cow());
            try answer.append(allocator, key2, c);
            pos2 += 1;
        }
    }

    if (pos1 == length1) {
        try answer.append_copy_range(allocator, x2, pos2, length2, x2.is_cow());
    } else if (pos2 == length2) {
        try answer.append_copy_range(allocator, x1, pos1, length1, x1.is_cow());
    }

    return answer;
}

/// Inplace version of `or`, modifies r1.
pub fn or_inplace(x1: *Bitmap, allocator: Allocator, x2: *const Bitmap) !void {
    trace(@src(), "x1: {f}", .{x1.fmtLong()});
    trace(@src(), "x2: {f}", .{x2.fmtLong()});
    const length2 = x2.array.ptr(.len).*;
    if (length2 == 0) return;

    var length1 = x1.array.ptr(.len).*;
    if (length1 == 0) {
        try x1.overwrite(allocator, x2.*);
        return;
    }

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    var key1 = x1.array.ptr(.keys)[pos1];
    var key2 = x2.array.ptr(.keys)[pos2];
    while (true) {
        if (key1 == key2) {
            const c1 = &x1.array.ptr(.containers)[pos1];
            if (!c1.is_full(x1.*)) {
                const c2 = &x2.array.ptr(.containers)[pos2];
                const oldc = c1.*;
                const c = if (c1.typecode == .shared)
                    try Container.merge(c1, allocator, x1, c2, x2, x1)
                else
                    try Container.ior(c1, allocator, x1, c2, x2);
                if (c.blockoffset != oldc.blockoffset)
                    oldc.deinit_blocks(x1.*);
                x1.array.ptr(.containers)[pos1] = c;
            }
            pos1 += 1;
            pos2 += 1;
            if (pos1 == length1) break;
            if (pos2 == length2) break;
            key1 = x1.array.ptr(.keys)[pos1];
            key2 = x2.array.ptr(.keys)[pos2];
        } else if (key1 < key2) {
            pos1 += 1;
            if (pos1 == length1) break;
            key1 = x1.array.ptr(.keys)[pos1];
        } else { // key1 > key2
            var c2 = x2.array.ptr(.containers)[pos2];
            c2 = try Container.get_copy_of_container(c2, allocator, x2, x1, x2.is_cow());
            if (x2.is_cow())
                x2.array.ptr(.containers)[pos2] = c2;
            try x1.insert_new_key_value_at(allocator, key2, c2, pos1);
            pos1 += 1;
            length1 += 1;
            pos2 += 1;

            if (pos2 == length2) break;
            key2 = x2.array.ptr(.keys)[pos2];
        }
    }

    if (pos1 == length1) {
        try x1.append_copy_range(allocator, x2, pos2, length2, x2.is_cow());
    }
}

/// Returned Bitamp contains values present in one but not both inputs.
pub fn xor(x1: *const Bitmap, allocator: Allocator, x2: *const Bitmap) !Bitmap {
    trace(@src(), "x1={f}", .{x1.fmtLong()});
    trace(@src(), "x2={f}", .{x2.fmtLong()});
    const length1 = x1.array.ptr(.len).*;
    const length2 = x2.array.ptr(.len).*;
    if (length1 == 0) return try x2.copy(allocator);
    if (length2 == 0) return try x1.copy(allocator);

    var answer = try create_with_capacity(allocator, length1 + length2);
    answer.set_copy_on_write(x1.is_cow() or x2.is_cow());
    defer answer.assert_valid();

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (pos1 < length1 and pos2 < length2) {
        const key1 = x1.array.ptr(.keys)[pos1];
        const key2 = x2.array.ptr(.keys)[pos2];

        if (key1 == key2) {
            const c1 = &x1.array.ptr(.containers)[pos1];
            const c2 = &x2.array.ptr(.containers)[pos2];
            const c = try Container.xor(c1, allocator, x1, c2, x2, &answer);
            if (c.nonzero_cardinality(answer)) {
                try answer.append(allocator, key1, c);
            } else if (c != Container.uninit) {
                c.deinit_blocks(answer);
            }
            pos1 += 1;
            pos2 += 1;
        } else if (key1 < key2) {
            const c1 = x1.array.ptr(.containers)[pos1];
            const c = try Container.get_copy_of_container(c1, allocator, x1, &answer, x1.is_cow());
            try answer.append(allocator, key1, c);
            pos1 += 1;
        } else {
            const c2 = x2.array.ptr(.containers)[pos2];
            const c = try Container.get_copy_of_container(c2, allocator, x2, &answer, x2.is_cow());
            try answer.append(allocator, key2, c);
            pos2 += 1;
        }
    }

    if (pos1 == length1) {
        try answer.append_copy_range(allocator, x2, pos2, length2, x2.is_cow());
    } else if (pos2 == length2) {
        try answer.append_copy_range(allocator, x1, pos1, length1, x1.is_cow());
    }

    return answer;
}

/// Computes the difference (andnot) between two bitmaps and returns new bitmap.
/// Caller is responsible for freeing the result.
pub fn andnot(x1: *const Bitmap, allocator: Allocator, x2: *const Bitmap) !Bitmap {
    const length1 = x1.array.ptr(.len).*;
    const length2 = x2.array.ptr(.len).*;
    if (length1 == 0) {
        var result = try create_with_capacity(allocator, 0);
        result.set_copy_on_write(x1.is_cow() or x2.is_cow());
        return result;
    }
    if (length2 == 0) return try x1.copy(allocator);

    var answer = try create_with_capacity(allocator, length1);
    answer.set_copy_on_write(x1.is_cow() or x2.is_cow());
    defer answer.assert_valid();

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (true) {
        const key1 = x1.array.ptr(.keys)[pos1];
        const key2 = x2.array.ptr(.keys)[pos2];

        if (key1 == key2) {
            const c1 = &x1.array.ptr(.containers)[pos1];
            const c2 = &x2.array.ptr(.containers)[pos2];
            const c = try Container.andnot(c1, allocator, x1, c2, x2, &answer);
            if (c.nonzero_cardinality(answer)) {
                try answer.append(allocator, key1, c);
            } else if (c != Container.uninit) {
                c.deinit_blocks(answer);
            }
            pos1 += 1;
            pos2 += 1;
            if (pos1 == length1) break;
            if (pos2 == length2) break;
        } else if (key1 < key2) {
            const next_pos1 = x1.advance_until(key2, pos1);
            try answer.append_copy_range(allocator, x1, pos1, next_pos1, x1.is_cow());
            // TODO : perhaps some of the copy_on_write should be based on
            // answer rather than x1 (more stringent?).  Many similar cases
            pos1 = next_pos1;
            if (pos1 == length1) break;
        } else { // key1 > key2
            pos2 = x2.advance_until(key1, pos2);
            if (pos2 == length2) break;
        }
    }

    if (pos2 == length2) {
        try answer.append_copy_range(allocator, x1, pos1, length1, x1.is_cow());
    }

    return answer;
}

/// returns the smallest value in the set or UINT32_MAX if the set is empty.
pub fn minimum(bm: Bitmap) u32 {
    if (bm.array.ptr(.len).* > 0) {
        const c = bm.array.ptr(.containers)[0];
        const key: u32 = bm.array.ptr(.keys)[0];
        const lowvalue = c.minimum(bm);
        return lowvalue | (key << 16);
    }
    return std.math.maxInt(u32);
}

/// returns the greatest value in the set or 0 if the set is empty.
pub fn maximum(bm: Bitmap) u32 {
    const len = bm.array.ptr(.len).*;
    if (len > 0) {
        const container = bm.array.ptr(.containers)[len - 1];
        const key: u32 = bm.array.ptr(.keys)[len - 1];
        const lowvalue = container.maximum(bm);
        return lowvalue | (key << 16);
    }
    return 0;
}

/// Returns the number of integers that are smaller or equal to x.
pub fn rank(bm: Bitmap, x: u32) u64 {
    var size: u64 = 0;
    const xhigh: u16 = @truncate(x >> 16);
    for (bm.slice(.keys, .len), bm.slice(.containers, .len)) |key, *c| {
        if (xhigh > key) {
            size += c.get_cardinality(bm);
        } else if (xhigh == key) {
            return size + c.rank(@truncate(x), bm);
        } else {
            return size;
        }
    }
    return size;
}

/// Selects the element at the specified rank (0-based).
/// Returns null if the bitmap is empty or rank >= cardinality.
pub fn select(bm: Bitmap, target_rank: u32) ?u32 {
    var start_rank: u32 = 0;
    const len = bm.array.ptr(.len).*;
    for (bm.array.ptr(.keys)[0..len], bm.array.ptr(.containers)) |key, *c| {
        if (c.select(&start_rank, target_rank, bm)) |element| {
            return element | @as(u32, key) << 16;
        }
    }
    return null;
}

/// (For users who seek high performance.)
///
/// Computes the union between two bitmaps and returns new bitmap. The caller is
/// responsible for memory management.
///
/// The lazy version defers some computations such as the maintenance of the
/// cardinality counts. Thus you must call `repair_after_lazy()`
/// after executing "lazy" computations.
///
/// It is safe to repeatedly call lazy_or_inplace on the result.
///
/// `bitsetconversion` is a flag which determines whether container-container
/// operations force a bitset conversion. see
/// `zroaring.constants.LAZY_OR_BITSET_CONVERSION_TO_FULL`
pub fn lazy_or(
    x1: *Bitmap,
    allocator: Allocator,
    x2: *const Bitmap,
    bitsetconversion: bool,
) !Bitmap {
    const length1 = x1.array.ptr(.len).*;
    const length2 = x2.array.ptr(.len).*;
    trace(@src(), "x1={f}", .{x1.fmtLong()});
    trace(@src(), "x2={f}", .{x2.fmtLong()});
    defer x1.assert_valid();
    if (0 == length1)
        return try x2.copy(allocator);

    if (0 == length2)
        return try x1.copy(allocator);

    var answer = try create_with_capacity(allocator, length1 + length2);
    defer trace(@src(), "answer={f}", .{answer.fmtLong()});
    defer x1.assert_valid();
    defer answer.assert_valid();
    answer.set_copy_on_write(x1.is_cow() or x2.is_cow());
    var pos1: u32 = 0;
    var pos2: u32 = 0;

    var key1 = x1.array.ptr(.keys)[pos1];
    var key2 = x2.array.ptr(.keys)[pos2];
    while (true) {
        if (key1 == key2) {
            const c1: *Container = &x1.array.ptr(.containers)[pos1];
            const c2: *Container = &x2.array.ptr(.containers)[pos2];
            var c: Container = .uninit;
            if (bitsetconversion and c1.typecode != .bitset and c2.typecode != .bitset) {
                var newc1 = c1.*; // TODO // container_mutable_unwrap_shared(c1);
                newc1 = try newc1.to_bitset(allocator, x1, &answer);
                c = try newc1.lazy_ior(allocator, &answer, c2, x2);
                if (c != newc1) { // should not happen
                    newc1.deinit_blocks(answer);
                }
            } else {
                c = try c1.lazy_or(allocator, x1, c2, x2, &answer);
            }
            // since we assume that the initial containers are non-empty, the
            // result here can only be non-empty
            assert(c != Container.uninit);
            try answer.append(allocator, key1, c);
            pos1 += 1;
            pos2 += 1;
            if (pos1 == length1) break;
            if (pos2 == length2) break;
            key1 = x1.array.ptr(.keys)[pos1];
            key2 = x2.array.ptr(.keys)[pos2];
        } else if (key1 < key2) {
            var c1 = x1.array.ptr(.containers)[pos1];
            c1 = try c1.get_copy_of_container(allocator, x1, &answer, x1.is_cow());
            if (x1.is_cow()) {
                x1.array.ptr(.containers)[pos1] = c1;
            }
            try answer.append(allocator, key1, c1);
            pos1 += 1;
            key1 = x1.array.ptr(.keys)[pos1];
            if (pos1 == length1) break;
        } else { // key1 > key2
            var c2 = x2.array.ptr(.containers)[pos2];
            c2 = try c2.get_copy_of_container(allocator, x2, &answer, x2.is_cow());
            if (x2.is_cow()) {
                x2.array.ptr(.containers)[pos2] = c2;
            }
            try answer.append(allocator, key2, c2);

            pos2 += 1;
            if (pos2 == length2) break;
            key2 = x2.array.ptr(.keys)[pos2];
        }
    }
    if (pos1 == length1) {
        try answer.append_copy_range(allocator, x2, pos2, length2, x2.is_cow());
    } else if (pos2 == length2) {
        try answer.append_copy_range(allocator, x1, pos1, length1, x1.is_cow());
    }
    return answer;
}

/// (For users who seek high performance.)
///
/// Execute maintenance on a bitmap created from `lazy_or()`
/// or modified with `lazy_or_inplace()`.
pub fn repair_after_lazy(r: *Bitmap, allocator: Allocator) !void {
    const len = r.array.ptr(.len).*;
    for (0..len) |i| {
        // read before write! avoids write to stale pointer.
        const c = try r.array.ptr(.containers)[i].repair_after_lazy(allocator, r);
        r.array.ptr(.containers)[i] = c;
    }
    r.assert_valid();
}

/// (For users who seek high performance.)
///
/// Inplace version of `lazy_or`, modifies x1. The caller is responsible for
/// memory management.
///
/// The lazy version defers some computations such as the maintenance of the
/// cardinality counts. Thus you must call `repair_after_lazy()`
/// after executing "lazy" computations.
///
/// It is safe to repeatedly call lazy_or_inplace on the result.
///
/// `bitsetconversion` is a flag which determines whether container-container
/// operations force a bitset conversion. see
/// `zroaring.constants.LAZY_OR_BITSET_CONVERSION_TO_FULL`
pub fn lazy_or_inplace(
    x1: *Bitmap,
    allocator: Allocator,
    x2: *const Bitmap,
    bitsetconversion: bool,
) !void {
    var length1 = x1.array.ptr(.len).*;
    const length2 = x2.array.ptr(.len).*;

    if (length2 == 0) return;
    if (length1 == 0) {
        try x1.overwrite(allocator, x2.*);
        return;
    }

    trace(@src(), "x1={f}", .{x1.fmtLong()});
    trace(@src(), "x2={f}", .{x2.fmtLong()});
    defer x1.assert_valid();

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    var key1 = x1.array.ptr(.keys)[pos1];
    var key2 = x2.array.ptr(.keys)[pos2];
    while (true) {
        if (key1 == key2) {
            var c1 = x1.array.ptr(.containers)[pos1];
            if (!c1.is_full(x1.*)) {
                if (!bitsetconversion or c1.typecode == .bitset) {
                    c1 = try c1.get_writable_copy_if_shared(allocator, x1.*);
                } else {
                    // convert to bitset
                    const oldc = c1;
                    c1 = try x1.array.ptr(.containers)[pos1].to_bitset(allocator, x1, x1);
                    if (c1 != oldc) {
                        oldc.deinit_blocks(x1.*);
                    }
                    x1.array.ptr(.containers)[pos1] = c1;
                }

                const c2 = &x2.array.ptr(.containers)[pos2];
                const oldc = c1;
                c1 = try c1.lazy_ior(allocator, x1, c2, x2);
                if (c1.blockoffset != oldc.blockoffset) {
                    oldc.deinit_blocks(x1.*);
                }
                x1.array.ptr(.containers)[pos1] = c1;
            }
            pos1 += 1;
            pos2 += 1;
            if (pos1 == length1) break;
            if (pos2 == length2) break;
            key1 = x1.array.ptr(.keys)[pos1];
            key2 = x2.array.ptr(.keys)[pos2];
        } else if (key1 < key2) {
            pos1 += 1;
            if (pos1 == length1) break;
            key1 = x1.array.ptr(.keys)[pos1];
        } else { // key1 > key2
            var c2 = x2.array.ptr(.containers)[pos2];
            c2 = try c2.get_copy_of_container(allocator, x2, x1, x2.is_cow());
            if (x2.is_cow())
                x2.array.ptr(.containers)[pos2] = c2;
            try x1.insert_new_key_value_at(allocator, key2, c2, pos1);
            pos1 += 1;
            length1 += 1;
            pos2 += 1;

            if (pos2 == length2) break;
            key2 = x2.array.ptr(.keys)[pos2];
        }
    }

    if (pos1 == length1) {
        try x1.append_copy_range(allocator, x2, pos2, length2, x2.is_cow());
    }
}

/// Compute the union of 'number' bitmaps.
pub fn or_many(allocator: Allocator, xs: []Bitmap) !Bitmap {
    const number = xs.len;
    trace(@src(), "number={}", .{number});
    if (number == 0)
        return empty;
    if (number == 1)
        return try xs[0].copy(allocator);

    var answer = try lazy_or(&xs[0], allocator, &xs[1], C.LAZY_OR_BITSET_CONVERSION);
    for (2..number) |i| {
        try answer.lazy_or_inplace(allocator, &xs[i], C.LAZY_OR_BITSET_CONVERSION);
    }
    try answer.repair_after_lazy(allocator);
    return answer;
}

/// Check whether a range of values from [range_start, range_end) is present
pub fn contains_range_closed(r: Bitmap, range_start: u32, range_end: u32) bool {
    if (range_start > range_end)
        return true;
    // empty range are always contained!
    if (range_end == range_start)
        return r.contains(range_start);

    const hb_rs: u16 = @truncate(range_start >> 16);
    const hb_re: u16 = @truncate(range_end >> 16);
    const span: u32 = hb_re - hb_rs;
    const hlc_sz = r.array.ptr(.len).*;
    if (hlc_sz < span + 1)
        return false;

    const is = r.get_key_index(hb_rs);
    const ie = r.get_key_index(hb_re);
    if (ie < 0 or is < 0 or (ie - is) != span or ie >= hlc_sz)
        return false;

    const lb_rs = range_start & 0xFFFF;
    const lb_re = (range_end & 0xFFFF) + 1;
    const cs = r.array.ptr(.containers);
    const isu: u32 = @bitCast(is);
    const ieu: u32 = @bitCast(ie);
    if (hb_rs == hb_re)
        return cs[isu].contains_range(lb_rs, lb_re, r);
    if (!cs[isu].contains_range(lb_rs, 1 << 16, r))
        return false;
    if (!cs[ieu].contains_range(0, lb_re, r))
        return false;

    for (isu + 1..ieu) |i| {
        if (!cs[i].is_full(r))
            return false;
    }
    return true;
}

/// Check whether a range of values from range_start (included) to
/// range_end (excluded) is present
pub fn contains_range(r: Bitmap, range_start: u64, range_end: u64) bool {
    if (range_start >= range_end or range_start > std.math.maxInt(u32) + 1)
        return true;
    return r.contains_range_closed(@intCast(range_start), @intCast(range_end - 1));
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
        var rbuf: [256]u8 = undefined;
        var rb = try portable_deserialize(testing.allocator, testio, f, &rbuf);
        defer rb.deinit(testing.allocator);
        try testing.expectEqual(.SERIAL_COOKIE_NO_RUNCONTAINER, rb.array.ptr(.magic).*);
        try validateTestdataFile(rb);
    }
    { // "with runs"
        const filepath = "testdata/bitmapwithruns.bin";
        const f = try Io.Dir.cwd().openFile(testio, filepath, .{});
        defer f.close(testio);
        var rbuf: [256]u8 = undefined;
        var rb = try portable_deserialize(testing.allocator, testio, f, &rbuf);
        defer rb.deinit(testing.allocator);
        try testing.expectEqual(.SERIAL_COOKIE, rb.array.ptr(.magic).*);
        try validateTestdataFile(rb);
    }
}

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
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
const Cardinality = Container.Cardinality;
