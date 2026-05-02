///
/// All container data is stored in `blocks`s including `header` and
/// its keys/containers.
///
const Bitmap = @This();

/// `header` is a storage description for an `Array` of keys and containers
/// all stored in `blocks`.
header: Container,
/// Storage for all container data, including `header`.
/// `header` Array is stored in first block.
/// `Containers` are stored starting at block 1 with keys next.
/// All other container data is stored after keys.
blocks: std.ArrayList(Block),

pub const empty: Bitmap = .{ .header = .uninit, .blocks = .empty };
pub const Flag = enum(u8) { cow, frozen };

pub fn deinit(r: *Bitmap, allocator: mem.Allocator) void {
    r.blocks.deinit(allocator);
    r.header = .uninit;
}

pub fn create_with_capacity(r: *Bitmap, allocator: mem.Allocator, container_count: u32) !void {
    assert(r.header == Container.uninit);
    const hinfo = header_info(container_count);
    const totalblocks = hinfo.headerblocks + hinfo.containerblocks;
    try r.blocks.ensureTotalCapacity(allocator, totalblocks);
    r.blocks.items.len = hinfo.headerblocks;

    r.header = .{
        .cardinality = Container.MAX_CARDINALITY,
        .blockoffset = hinfo.headerblocks,
        .nblocks_minus1 = 0,
        .typecode = .array,
    };

    trace(@src(), "totalblocks={}", .{totalblocks});
    const ra: *Array = mem.bytesAsValue(Array, r.blocks.items[0..C.HEADER_BLOCKS]);
    ra.* = .empty;
    ra.containers = @ptrCast(&r.blocks.items[C.HEADER_BLOCKS]);
    ra.keys = @ptrCast(@alignCast(ra.containers + hinfo.containercount));
    ra.capacity = hinfo.containercount;
}

pub fn get_header(r: *const Bitmap) *align(C.BLOCK_ALIGN) Array {
    assert(r.header.cardinality == Container.MAX_CARDINALITY);
    assert(r.header.nblocks_minus1 == 0);
    assert(r.blocks.items.len != 0);
    return mem.bytesAsValue(Array, r.blocks.items[0..C.HEADER_BLOCKS]);
}

/// returns nblocks for given array capacity
fn header_nblocks(len: comptime_int) u24 {
    // first HEADER_BLOCKS blocks are an Array.  following blocks hold Array containers/keys.
    return C.HEADER_BLOCKS + // Array
        @divExact(len * @sizeOf(u16), C.BLOCK_BYTES) + // keys
        @divExact(len * @sizeOf(Container), C.BLOCK_BYTES); // containers
}

const HeaderInfo = struct {
    headerblocks: u24,
    containerblocks: u24,
    containercount: u32,
};

/// returns HeaderInfo for the requested length of containers. minimum
/// containercount is 256 in an attempt to minimize need for reallocation
/// memcpys.
fn header_info(len: u32) HeaderInfo {
    return switch (len) {
        0...256 => .{
            .headerblocks = header_nblocks(256),
            .containercount = 256,
            .containerblocks = @intCast(256 * C.BITSET_BLOCKS),
        },
        257...1024 => .{
            .headerblocks = header_nblocks(1024),
            .containercount = 1024,
            .containerblocks = @intCast(1024 * C.BITSET_BLOCKS),
        },
        1025...4096 => .{
            .headerblocks = header_nblocks(4096),
            .containercount = 4096,
            .containerblocks = @intCast(4096 * C.BITSET_BLOCKS),
        },
        4097...16384 => .{
            .headerblocks = header_nblocks(16384),
            .containercount = 16384,
            .containerblocks = @intCast(16384 * C.BITSET_BLOCKS),
        },
        else => unreachable, // TODO
    };
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
    const info = try Array.info_from_file_reader(&freader);
    if (info.len == 0) return .empty;
    const hinfo = header_info(info.len);
    const totalblocks = hinfo.headerblocks + hinfo.containerblocks;
    trace(@src(), "{} {}", .{ totalblocks, hinfo });
    var blocks: std.ArrayList(Block) = try .initCapacity(allocator, totalblocks);
    blocks.items.len = hinfo.headerblocks;
    errdefer blocks.deinit(allocator);

    const ra: *Array = mem.bytesAsValue(Array, blocks.items[0..C.HEADER_BLOCKS]);
    ra.* = .empty;
    ra.magic = info.cookie.magic;
    ra.len = info.len;
    ra.capacity = hinfo.containercount;
    ra.containers = @ptrCast(&blocks.items[C.HEADER_BLOCKS]);
    ra.keys = @ptrCast(@alignCast(ra.containers + ra.capacity));
    var run_flags: root.RunFlags = undefined;
    try ra.deserialize_file_reader(&freader, &run_flags);
    assert(freader.logicalPos() == ra.portable_size());

    var ret = Bitmap{ .header = .{
        .cardinality = Container.MAX_CARDINALITY,
        .blockoffset = @intCast(hinfo.headerblocks),
        .nblocks_minus1 = 0,
        .typecode = .array,
    }, .blocks = blocks };

    var r = &freader.interface;

    var blockoffset: u24 = hinfo.headerblocks;
    for (0..ra.len) |k| { // read container data
        const c = &ra.containers[k];
        const thiscard = c.cardinality;
        var isbitset = (thiscard > C.DEFAULT_MAX_SIZE);
        var isrun = false;
        if (ra.can_have_run_containers() and
            ((run_flags[k / 8] & @as(u8, 1) << @truncate(k % 8))) != 0)
        {
            isbitset = false;
            isrun = true;
        }
        if (isbitset) {
            try r.readSliceAll(mem.asBytes(blocks.items.ptr[blockoffset..][0..C.BITSET_BLOCKS]));
            c.* = .{
                .typecode = .bitset,
                .cardinality = thiscard,
                .blockoffset = blockoffset,
                .nblocks_minus1 = C.BITSET_BLOCKS - 1,
            };
            blockoffset += C.BITSET_BLOCKS;
        } else if (isrun) {
            const nruns: u32 = try r.takeInt(u16, .little);
            const blocks_size = mem.alignForward(u32, nruns * @sizeOf(Rle16), C.BLOCK_BYTES);
            const nblocks = @divExact(blocks_size, C.BLOCK_BYTES);
            const runs = misc.asSlice([]align(C.BLOCK_ALIGN) Rle16, blocks.items.ptr[blockoffset..][0..nblocks]);
            try r.readSliceEndian(Rle16, runs[0..nruns], .little);
            c.* = .{
                .typecode = .run,
                .cardinality = @intCast(nruns),
                .blockoffset = blockoffset,
                .nblocks_minus1 = @intCast(nblocks - 1),
            };
            blockoffset += @intCast(nblocks);
        } else { // array container
            const blocks_size = mem.alignForward(u32, thiscard * @sizeOf(u16), C.BLOCK_BYTES);
            const nblocks = @divExact(blocks_size, C.BLOCK_BYTES);
            const values = misc.asSlice([]align(C.BLOCK_ALIGN) u16, blocks.items.ptr[blockoffset..][0..nblocks]);
            try r.readSliceEndian(u16, values[0..thiscard], .little);
            c.* = .{
                .typecode = .array,
                .cardinality = thiscard,
                .blockoffset = blockoffset,
                .nblocks_minus1 = @intCast(nblocks - 1),
            };
            blockoffset += @intCast(nblocks);
        }
    }

    assert(freader.size == null or freader.atEnd());
    assert(blockoffset <= totalblocks);
    assert(ret.blocks.items.len + hinfo.containerblocks <= ret.blocks.capacity);
    ret.blocks.items.len += hinfo.containerblocks;
    trace(@src(), "ra={f}", .{ra});

    // FIXME - portable_size_in_bytes() doesn't match logicalPos() on testdatawithruns - 48056 48050
    if (freader.logicalPos() != ret.portable_size_in_bytes()) {
        // trace(@src(), "Error: readerpos={} portablesize={}", .{ freader.logicalPos(), ret.portable_size_in_bytes() });
        // FIXME // assert(false);
    }
    return ret;
}

pub fn insert_new_kv_at(r: *Bitmap, allocator: mem.Allocator, key: u16, c: Container, i: u32) !void {
    try r.extend_array(allocator, 1);
    const a = r.get_header();
    @memmove(a.keys + i + 1, a.slice(.keys, .len)[i..]);
    @memmove(a.containers + i + 1, a.slice(.containers, .len)[i..]);
    a.keys[i] = key;
    a.containers[i] = c;
    a.len += 1;
}

/// returns count of `vals` added
pub fn add_many(r: *Bitmap, allocator: mem.Allocator, vals: []const u32) !usize {
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
    const key: u16, const valuelow: u16 = .{ @truncate(value >> 16), @truncate(value) };
    if (r.header == Container.uninit) {
        @branchHint(.unlikely);
        assert(r.blocks.capacity == 0);
        try r.create_with_capacity(allocator, 0);
    }
    // trace(@src(), "{*} {*}", .{ r.blocks.items, r.get_header().keys });
    assert(@intFromPtr(r.get_header().containers + r.get_header().capacity) == @intFromPtr(r.get_header().keys));
    const mcontaineridx = misc.binarySearch(r.get_header().slice(.keys, .len), key);
    const containeridx: u32 = @bitCast(mcontaineridx);
    if (mcontaineridx >= 0) { // key found
        const c = &r.get_header().containers[containeridx];
        const card = c.cardinality;
        // trace(@src(), "key found container={} {any}", .{ c, c.blocks_as(.array, r) });
        const c2 = try c.add(allocator, r, valuelow);
        if (c.* != c2) {
            // skip deinit of inplace array/bitset conversion
            if (c.blockoffset != c2.blockoffset) {
                c.deinit(allocator, r);
            }
            r.get_header().slice(.containers, .len)[containeridx] = c2;
        }
        return card != r.get_header().slice(.containers, .len)[containeridx].cardinality;
    } else { // key not found, add new array container
        const insertidx: u32 = @intCast(-mcontaineridx - 1);
        trace(@src(), "new container - insertidx={} header {}", .{ insertidx, r.get_header() });

        var newac: Container = .{
            .blockoffset = @intCast(r.blocks.items.len),
            .nblocks_minus1 = 0,
            .cardinality = 0,
            .typecode = .array,
        };
        assert(r.blocks.items.len < r.blocks.capacity); // TODO grow blocks
        r.blocks.items.len += 1;

        _ = try newac.add(allocator, r, valuelow); // assume it stays an array container
        try r.insert_new_kv_at(allocator, key, newac, insertidx);
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
    const blockoffset = r.blocks.items.len;
    trace(@src(), "{t} card_or_nruns={} header={f}", .{ tc, card_or_nruns, r.get_header() });
    try r.extend_array(allocator, 1);
    trace(@src(), "header={f}", .{r.get_header()});

    const c = switch (tc) {
        .run => {
            const blocks_size = mem.alignForward(u32, card_or_nruns * @sizeOf(Rle16), C.BLOCK_BYTES);
            const nblocks = @divExact(blocks_size, C.BLOCK_BYTES);
            _ = try r.blocks.addManyAsSlice(allocator, nblocks);
            return .{
                .typecode = .run,
                .cardinality = 0,
                .blockoffset = @intCast(blockoffset),
                .nblocks_minus1 = @intCast(nblocks - 1),
            };
        },
        .array => {
            const blocks_size = mem.alignForward(u32, card_or_nruns * @sizeOf(u16), C.BLOCK_BYTES);
            const nblocks = @divExact(blocks_size, C.BLOCK_BYTES);
            _ = try r.blocks.addManyAsSlice(allocator, nblocks);
            if (true) unreachable; // TODO incorrect ^
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

fn append_first(r: *Bitmap, c: *Container, container_value: anytype) void {
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
            trace(@src(), "run {} {}", .{ c.cardinality, r.get_header() });
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

fn add_range_to_container(r: *Bitmap, allocator: mem.Allocator, container: Container.Id, container_min: u32, container_max: u32) !Container {
    _ = r;
    _ = allocator;
    _ = container;
    _ = container_min;
    _ = container_max;
    unreachable;
}

fn replace_key_and_container_at_index(r: *Bitmap, i: u32, key: u16, c: Container) void {
    assert(i < r.get_header().len);
    r.get_header().slice(.containers, .len)[i] = c;
    r.get_header().slice(.keys, .len)[i] = key;
}

/// Add all values in range [min, max]
pub fn add_range_closed(r: *Bitmap, allocator: mem.Allocator, min: u32, max: u32) !void {
    if (min > max) return;
    if (r.header == Container.uninit) {
        @branchHint(.unlikely);
        assert(r.blocks.capacity == 0);
        try r.create_with_capacity(allocator, 0);
    }
    trace(@src(), "({},{}) size={}", .{ min, max, r.get_header().len });

    const min_key = min >> 16;
    const max_key = max >> 16;
    const num_required_containers = max_key - min_key + 1;
    const suffix_length = misc.count_greater(r.get_header().slice(.keys, .len), @truncate(max_key));
    const prefix_length = misc.count_less(
        r.get_header().slice(.keys, .len)[0 .. r.get_header().len - suffix_length],
        @truncate(min_key),
    );
    const common_length = r.get_header().len - prefix_length - suffix_length;

    trace(@src(), "num_required_containers={} prefix_length={} suffix_length={} common_length={}", .{ num_required_containers, prefix_length, suffix_length, common_length });
    if (num_required_containers > common_length) {
        try r.shift_tail(
            allocator,
            suffix_length,
            @bitCast(num_required_containers -% common_length),
        );
    }

    var src: i32 = @bitCast(prefix_length + common_length -% 1);
    var dst = r.get_header().len - suffix_length -% 1;
    var key = max_key;
    trace(@src(), "dst={} src={} ra.len={}", .{ dst, src, r.get_header().len });
    while (key +% 1 != min_key) : (key -%= 1) { // beware of min_key==0
        trace(@src(), "key {} min_key {} max_key {} dst={} h.len={}", .{ key, min_key, max_key, dst, r.get_header().len });
        const container_min = if (min_key == key) min & 0xffff else 0;
        const container_max = if (max_key == key) max & 0xffff else 0xffff;
        var newc: Container = .uninit;
        if (src > 0 and r.get_header().slice(.keys, .len)[@intCast(src)] == key) {
            const srcu: Container.Id = @enumFromInt(src);
            // TODO // ra.unshare_container_at_index(srcu);
            newc = try r.add_range_to_container(allocator, srcu, container_min, container_max);
            if (newc != r.get_header().get_container(srcu)) {
                unreachable; // TODO r.deinit_container(allocator, srcu);
            }
            src -= 1;
        } else {
            newc = try r.from_range(allocator, container_min, container_max + 1, 1);
        }
        trace(@src(), "dst {}, newc {} {any}", .{ dst, newc, newc.blocks_as(.run, r)[0..newc.cardinality] });
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

pub fn contains(r: *const Bitmap, val: u32) bool {
    const h = r.get_header();
    // trace(@src(), "{}/{} {*} {*}", .{ h.len, h.capacity, h.containers, h.keys });
    const key: u16 = @truncate(val >> 16);
    // the next function call involves a binary search and lots of branching.
    // trace(@src(), "{any}", .{h.slice(.keys, .len)});
    const i = misc.binarySearch(h.slice(.keys, .len), key);
    // std.debug.print("Bitmap.contains({}) key {} i {}\n", .{ val, key, i });
    if (i < 0) return false;
    const iu: u32 = @bitCast(i);

    // rest might be a tad expensive, possibly involving another round of binary search
    const c: Container = h.slice(.containers, .len)[iu];

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
pub fn equals(r1: *const Bitmap, r2: *const Bitmap) bool {
    // trace(@src(), "r1.header={}", .{r1.header});
    if (r1.header == Container.uninit) return r2.header == Container.uninit;
    const h1 = r1.get_header();
    const h2 = r2.get_header();
    if (h1.len != h2.len)
        return false;

    for (h1.slice(.keys, .len), h2.slice(.keys, .len)) |k1, k2| {
        if (k1 != k2) return false;
    }

    for (
        h1.slice(.containers, .len),
        h2.slice(.containers, .len),
    ) |c1, c2| {
        trace(@src(), "c1={}", .{c1});
        trace(@src(), "c2={}", .{c2});
        if (!c1.equals(c2, r1, r2)) return false;
    }

    return true;
}

///
/// Get the index corresponding to a 16-bit key
///
pub fn get_index(r: Bitmap, v: u32) i32 {
    const key: u16 = @truncate(v >> 16);
    const h = r.get_header();
    const keys = h.slice(.keys, .len);
    if (h.len == 0 or keys[h.len - 1] == key)
        return @as(i32, @intCast(h.len)) - 1;
    return misc.binarySearch(keys, key);
}

pub fn has_run_container(r: Bitmap) bool {
    if (r.header == Container.uninit) return false;
    return r.get_header().has_run_container();
}

pub fn portable_header_size(r: Bitmap) usize {
    if (r.header == Container.uninit) return 8;
    return r.get_header().portable_size_has_run();
}

pub fn portable_size_in_bytes(r: Bitmap) usize {
    if (r.header == Container.uninit) return 8;
    return r.get_header().portable_size_in_bytes();
}

/// Writes the container to `w`, returns how many bytes were written.
/// The number of bytes written should be equal to `portable_size_in_bytes()`.
pub fn write(r: *const Bitmap, c: Container, w: *Io.Writer) !usize {
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

// TODO replace temp_allocator with RunFlags
pub fn portable_serialize(r: Bitmap, w: *std.Io.Writer, runflags: *root.RunFlags) !usize {
    if (r.header == Container.uninit) {
        return portable_serialize_empty(w);
    }

    const h: Array.AlignedPtr = r.get_header();
    const cslen = h.len;
    if (cslen == 0) {
        return portable_serialize_empty(w);
    }

    var startOffset: u32 = 0;
    var written_count: usize = 0;
    const hasrun = r.has_run_container();
    const cs = h.slice(.containers, .len);
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

    for (h.slice(.keys, .len), cs) |k, c| {
        try w.writeInt(u16, k, .little);
        const card: u16 = @intCast(c.get_cardinality(&r) - 1);
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
    for (r.get_header().slice(.containers, .len)) |*c| {
        // TODO // r.unshare_container_at_index(i); // TODO: this introduces extra cloning!
        const c1 = try r.convert_run_optimize(c, allocator);
        if (c1.typecode == .run) answer = true;
        r.get_header().slice(.containers, .len)[c - r.get_header().containers] = c1;
    }
    return answer;
}

/// Get the cardinality of the bitmap (number of elements).
pub fn cardinality(r: *const Bitmap) u64 {
    if (r.header == Container.uninit) return 0;
    var card: u64 = 0;
    for (r.get_header().slice(.containers, .len)) |c| card += c.compute_cardinality(r);
    return card;
}
pub const get_cardinality = cardinality;

fn array_number_of_runs(r: *Bitmap, c: Container) u32 {
    // Can SIMD work here?
    var nr_runs: u32 = 0;
    var prev: i32 = -2;
    const start: [*]u16 = @ptrCast(&r.blocks.items[c.blockoffset]);
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
    trace(@src(), "{t}", .{c.typecode});
    if (c.typecode == .run) {
        const newc = try r.convert_run_to_efficient_container(c.*, allocator);
        if (newc != c.*) c.deinit(allocator, r);
        return newc;
    } else if (c.typecode == .array) {
        // it might need to be converted to a run container.
        const nruns = r.array_number_of_runs(c.*);
        const nblocks = @divExact(mem.alignForward(u32, nruns * @sizeOf(Rle16), C.BLOCK_BYTES), C.BLOCK_BYTES);
        var rc: Container = .{
            .typecode = .run,
            .cardinality = @intCast(nruns),
            .nblocks_minus1 = @intCast(nblocks - 1),
            .blockoffset = @intCast(r.blocks.items.len),
        };
        const size_as_run_container = rc.serialized_size_in_bytes();
        const size_as_array_container = c.serialized_size_in_bytes();
        trace(@src(), "arraysize={} runsize={}", .{ size_as_array_container, size_as_run_container });
        if (size_as_array_container <= size_as_run_container) {
            return c.*;
        }
        // convert array to run container
        _ = try r.blocks.addManyAsSlice(allocator, nblocks);
        var prev: i32 = -2;
        var run_start: i32 = -1;

        const card = c.cardinality;
        rc.cardinality = 0;
        assert(card > 0);
        const c_qua_array = c.blocks_as(.array, r)[0..c.cardinality];
        var i: u32 = 0;
        while (i < card) : (i += 1) {
            const cur_val = c_qua_array[i];
            if (cur_val != prev + 1) {
                // new run starts; flush old one, if any
                if (run_start != -1) rc.add_run(@intCast(run_start), @intCast(prev), r);
                run_start = cur_val;
            }
            prev = c_qua_array[i];
        }
        assert(run_start >= 0);
        // now prev is the last seen value
        rc.add_run(@intCast(run_start), @intCast(prev), r);
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
pub fn convert_run_to_efficient_container(r: *Bitmap, c: Container, allocator: mem.Allocator) !Container {
    _ = allocator; // autofix
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
        //         answer.get_array()[answer.cardinality] = run_value;
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
pub fn get_copy_on_write(r: *const Bitmap) bool {
    return r.get_header().flags & 1 << @intFromEnum(Flag.cow) != 0;
}

var reason_global: ?[]const u8 = null;
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
/// Note: not thread safe - global
pub fn internal_validate(r: *const Bitmap, reason: *?[]const u8) bool {
    reason.* = null;

    if (r.header == Container.uninit) return true;

    if (!r.get_header().internal_validate(reason, r)) {
        return false;
    }

    if (@popCount(r.get_header().flags) > 1) {
        reason.* = "invalid flags";
        return false;
    }
    if (r.get_header().len == 0) return true;

    const keys = r.get_header().slice(.keys, .len);
    var prev_key = keys[0];
    for (keys[1..]) |key| {
        if (key <= prev_key) {
            reason.* = "keys not strictly increasing";
            return false;
        }
        prev_key = key;
    }

    const cow = r.get_copy_on_write();
    for (0..r.get_header().len) |ci| {
        const cid: Container.Id = @enumFromInt(ci);
        const c = r.get_header().get_container(cid);
        if (c.typecode == .shared and !cow) {
            reason.* = "shared container in non-COW bitmap";
            return false;
        }
        if (!r.internal_validate_container(cid, reason)) {
            // reason should already be set
            if (reason.* == null) {
                reason.* = "container failed to validate but no reason given";
            }
            return false;
        }
    }

    return true;
}

pub fn internal_validate_container(r: *const Bitmap, cid: Container.Id, reason: *?[]const u8) bool {
    const c = r.get_header().get_container(cid);

    if (c.cardinality == 0) {
        reason.* = "container is empty";
        return false;
    }
    return c.internal_validate(reason, r);
}

/// grow if necessary to new_capacity.  deinit if 0.  does not modify `r.get_array().len`.
fn realloc_array(r: *Bitmap, allocator: mem.Allocator, new_capacity: u32) !void {
    const a = r.get_header();
    trace(@src(), "new_capacity={} array={f}", .{ new_capacity, a });
    if (new_capacity == 0) {
        r.deinit(allocator);
        return;
    }
    if (new_capacity <= a.capacity)
        return;
    // const buf_size = Array.buffer_size_from_count(a.magic, new_capacity);
    const nblocks = header_info(new_capacity);
    trace(@src(), "buf_size={}", .{nblocks});
    try r.blocks.resize(allocator, nblocks.headerblocks + nblocks.containerblocks);
    if (true) unreachable; // TODO incorrect ^
    // const array_buf = if (a.capacity == 0)
    //     // try allocator.alloc(u8, buf_size)
    //     try r.blocks.addManyAsSlice(allocator, new_capacity)
    // else b: {
    //     break :b r.blocks.items;
    //     // try allocator.realloc(a.allocated_buffer(), buf_size);
    // };
    // errdefer allocator.free(array_buf);
    var newa: Array = undefined;
    try newa.init_from_buffer(a, mem.sliceAsBytes(r.blocks.items), new_capacity);
    trace(@src(), "old array {f}", .{a});
    // if (a.capacity != 0) a.deinit(allocator);
    a.* = newa;
    trace(@src(), "new array {f}", .{a});
}

pub fn extend_array(r: *Bitmap, allocator: mem.Allocator, k: i32) !void {
    const a = r.get_header();
    const desired_len = misc.cast(i32, a.len) + k;
    // trace(@src(), "desired_len={} len/cap={}/{}", .{ desired_len, a.len, a.capacity });
    assert(desired_len <= C.MAX_CONTAINERS);

    if (desired_len > a.capacity) {
        const new_capacity: u32 = @intCast(@min(C.MAX_CONTAINERS, if (a.len < 1024)
            2 * desired_len
        else
            @divFloor(5 * desired_len, 4)));
        trace(@src(), "old/newcount={}/{}", .{ a.len, new_capacity });
        try r.realloc_array(allocator, new_capacity);
    }
}

/// Shifts rightmost $count containers to the left (distance < 0) or
/// to the right (distance > 0).
/// Allocates memory if necessary.
/// This function doesn't free or create new containers.
/// Caller is responsible for that.
pub fn shift_tail(r: *Bitmap, allocator: mem.Allocator, count: u32, distance: i32) !void {
    trace(@src(), "count={} distance={}", .{ count, distance });
    if (distance > 0) {
        try r.extend_array(allocator, distance);
    }

    const srcpos = r.get_header().len - count;
    const dstpos = srcpos +% @as(u32, @bitCast(distance));
    trace(@src(), "srcpos={} dstpos={}", .{ srcpos, dstpos });

    r.get_header().len += @bitCast(distance);
    const keys = r.get_header().slice(.keys, .len);
    @memmove(
        keys[@intCast(dstpos)..].ptr,
        keys[@intCast(srcpos)..][0..count],
    );
    const cs = r.get_header().slice(.containers, .len);
    @memmove(
        cs[@intCast(dstpos)..].ptr,
        cs[@intCast(srcpos)..][0..count],
    );
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
        try testing.expectEqual(.SERIAL_COOKIE_NO_RUNCONTAINER, rb.get_header().magic);
        // try testing.expectEqual(8 * 256 + 220 + @as(u32, rb.header.nblocks()), rb.blocks.items.len); // 8 bitsets, 220 array blocks
        try validateTestdataFile(rb);
    }
    { // "with runs"
        const filepath = "testdata/bitmapwithruns.bin";
        const f = try Io.Dir.cwd().openFile(testio, filepath, .{});
        defer f.close(testio);
        var rb = try deserializeTestdataPortable(testio, f);
        defer rb.deinit(testing.allocator);
        try testing.expectEqual(.SERIAL_COOKIE, rb.get_header().magic);
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
const C = @import("constants.zig");
const misc = @import("misc.zig");
const trace = misc.trace;
const root = @import("root.zig");
const Typecode = root.Typecode;
const Any = root.container.Any;
const Container = root.container.Container;
const Block = root.Block;
const Array = root.Array;
const Rle16 = root.Rle16;
