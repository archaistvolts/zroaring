const Bitmap = @This();

/// header, keys, containers in a single allocation.
array: *align(C.BLOCK_ALIGN) Array,

pub const Array = extern struct {
    /// container count. [0, 1<<16].
    ///
    /// align is needed on 32 bit platforms such as wasm32 to align Array size
    /// and make keys and containers aligned in create().
    len: u32 align(C.BLOCK_ALIGN),
    /// container capacity. [0, 1<<16].
    capacity: u32,
    magic: root.Magic,
    /// a bitset of `Flag`.
    flags: u8,
    /// container keys.
    keys: [*]align(C.BLOCK_ALIGN) u16,
    /// container descriptors.
    containers: [*]align(C.BLOCK_ALIGN) Container,

    fn calcSize(capacity: u32) u32 {
        return @intCast(0 +
            @sizeOf(Array) +
            C.BLOCK_ALIGNMENT.forward(@sizeOf(u16) * capacity) +
            C.BLOCK_ALIGNMENT.forward(@sizeOf(Container) * capacity));
    }

    fn asBytes(a: *align(C.BLOCK_ALIGN) Array) [*]align(C.BLOCK_ALIGN) u8 {
        return @ptrCast(a);
    }

    fn destroy(a: *align(C.BLOCK_ALIGN) Array, allocator: mem.Allocator) void {
        allocator.free(a.asBytes()[0..calcSize(a.capacity)]);
    }

    fn fromBytes(bytes: []align(C.BLOCK_ALIGN) u8, capacity: u32) *align(C.BLOCK_ALIGN) Array {
        const a: *align(C.BLOCK_ALIGN) Array = @ptrCast(bytes.ptr);
        @memset(mem.asBytes(a), 0);
        a.capacity = capacity;
        a.keys = @ptrCast(bytes.ptr + @sizeOf(Array));
        a.containers = @ptrCast(@alignCast(bytes.ptr +
            @sizeOf(Array) +
            C.BLOCK_ALIGNMENT.forward(capacity * @sizeOf(u16))));
        @memset(a.get_containers(), Container.uninit);
        return a;
    }

    fn create(allocator: mem.Allocator, capacity: u32) !*align(C.BLOCK_ALIGN) Array {
        const size = calcSize(capacity);
        const bytes = try allocator.alignedAlloc(u8, C.BLOCK_ALIGNMENT, size);
        return fromBytes(bytes, capacity);
    }

    const Field = std.meta.FieldEnum(Array);

    fn copyField(
        dst: *align(C.BLOCK_ALIGN) Array,
        src: *align(C.BLOCK_ALIGN) const Array,
        comptime field: Field,
    ) void {
        @memcpy(
            @field(dst, @tagName(field))[0..@min(dst.capacity, src.capacity)],
            @field(src, @tagName(field)),
        );
    }

    fn cloneContainers(
        src: Bitmap,
        allocator: mem.Allocator,
        dst: *Bitmap,
    ) !void {
        for (
            dst.array.containers[0..@min(dst.array.capacity, src.array.capacity)],
            src.array.containers,
        ) |*d, s| {
            errdefer {
                for (dst.array.containers[0 .. d - dst.array.containers]) |*c|
                    c.deinit(allocator);
            }
            d.* = try s.clone(allocator);
        }
    }

    fn get_containers(a: *align(C.BLOCK_ALIGN) Array) []align(C.BLOCK_ALIGN) Container {
        return a.containers[0..a.capacity];
    }
};

/// Context for bulk add operations.  Must be default init before use.
pub const BulkContext = struct {
    container: *Container = @constCast(&Container.uninit),
    idx: u32 = 0,
    key: u32 = 0,
};

pub const empty: Bitmap = .{
    .array = blk: {
        const aligned: Array align(C.BLOCK_ALIGN) = .{
            .len = 0,
            .capacity = 0,
            .magic = @enumFromInt(0),
            .flags = 0,
            .keys = &.{},
            .containers = &.{},
        };
        break :blk @constCast(&aligned);
    },
};

pub const Flag = enum(u8) {
    /// copy on write
    cow,
    /// frozen layout described in `frozen_size_in_bytes`.
    frozen,
};

pub const free = deinit;

// free all allocated memory and enter empty state
pub fn deinit(r: *Bitmap, allocator: Allocator) void {
    if (r.is_empty()) return;
    if (r.get_flag(.frozen)) {
        var blocks_cap: u32 = 0;
        for (r.get_containers()) |c| {
            switch (c.data.typecode) {
                .array, .run => blocks_cap += c.data.blocks_cap,
                else => {},
            }
        }
        const size = Array.calcSize(r.array.capacity) +
            C.BLOCK_ALIGNMENT.forward(r.array.capacity * C.CONTAINER_DATA_SIZE) +
            C.BLOCK_SIZE * blocks_cap;
        allocator.free(r.array.asBytes()[0..size]);
    } else {
        for (r.get_containers()) |*c| {
            c.deinit(allocator);
        }
        if (r.array != empty.array)
            r.array.destroy(allocator);
    }
    r.* = empty;
}

pub fn is_empty(r: Bitmap) bool {
    return r.array == empty.array;
}

fn zero_init(m: *align(C.BLOCK_ALIGN) Array) void {
    m.len = 0;
    m.magic = .SERIAL_COOKIE_NO_RUNCONTAINER;
    m.flags = 0;
    @memset(m.get_containers(), Container.uninit);
}

/// Allocates room for container_count containers with minimum of 16.
pub fn create_with_capacity(allocator: Allocator, container_count: u32) !Bitmap {
    const capacity = @max(16, container_count); // subject to tuning.  TODO bench
    const m = try Array.create(allocator, capacity);
    zero_init(m);
    return .{ .array = m };
}

pub fn get_keys(r: Bitmap) []align(C.BLOCK_ALIGN) u16 {
    return r.array.keys[0..r.array.len];
}

pub fn get_containers(r: Bitmap) []align(C.BLOCK_ALIGN) Container {
    return r.array.containers[0..r.array.len];
}

pub fn can_have_run_containers(h: Bitmap) bool {
    if (h.is_empty()) return false;
    return h.array.magic == .SERIAL_COOKIE;
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
pub fn info_from_file_reader(r: *Io.Reader) !Info {
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

/// Read bitmap from a serialized buffer.
///
/// This is meant to be compatible with the Java and Go versions:
/// https://github.com/RoaringBitmap/RoaringFormatSpec
pub fn portable_deserialize(allocator: Allocator, buf: []const u8) !Bitmap {
    var r = Io.Reader.fixed(buf);
    return try portable_deserialize_reader(allocator, &r);
}

/// Allocates and returns a Bitmap read from `bitmap_file`. `read_buf` is a
/// temporary buffer.
pub fn portable_deserialize_file(
    allocator: Allocator,
    io: Io,
    bitmap_file: Io.File,
    read_buf: []u8,
) !Bitmap {
    var freader = bitmap_file.reader(io, read_buf);
    const r = try portable_deserialize_reader(allocator, &freader.interface);
    assert(freader.logicalPos() == r.portable_size_in_bytes());
    return r;
}

/// Allocates and returns a Bitmap read from `r`.
pub fn portable_deserialize_reader(allocator: Allocator, r: *Io.Reader) !Bitmap {
    const ainfo = try info_from_file_reader(r);
    trace(@src(), "{}", .{ainfo});

    var ret: Bitmap = .{ .array = try Array.create(allocator, ainfo.len) };
    errdefer ret.array.destroy(allocator);
    ret.array.magic = ainfo.cookie.magic;
    ret.array.len = ainfo.len;
    ret.array.flags = 0;

    var cs_created: usize = 0;
    const containers = ret.array.containers;
    errdefer {
        for (containers[0..cs_created]) |c|
            c.destroy(allocator);
    }

    for (containers[0..ret.array.len]) |*c| {
        c.* = try Container.create(allocator, .bitset, 0, 1);
        cs_created += 1;
    }

    var run_flags: root.RunFlags = undefined;
    try ret.deserialize_reader(r, &run_flags);

    for (0..ret.array.len) |k| { // read container data
        const c = &containers[k];
        const thiscard = c.data.cardinality;
        var isbitset = (thiscard > C.DEFAULT_MAX_SIZE);
        var isrun = false;
        if (ret.can_have_run_containers() and
            ((run_flags[k / 8] & @as(u8, 1) << @truncate(k % 8))) != 0)
        {
            isbitset = false;
            isrun = true;
        }
        if (isbitset) {
            try c.realloc_container(allocator, .bitset, thiscard, C.BITSET_BLOCKS);
            try r.readSliceAll(mem.sliceAsBytes(c.data.blocks[0..C.BITSET_BLOCKS]));
        } else if (isrun) {
            const nruns: u32 = try r.takeInt(u16, .little);
            const nblocks = misc.numGroupsOfSize(nruns * @sizeOf(Rle16), C.BLOCK_SIZE);
            try c.realloc_container(allocator, .run, nruns, @intCast(nblocks));
            const runs = misc.asSlice([]align(C.BLOCK_ALIGN) Rle16, c.data.blocks[0..nblocks]);
            try r.readSliceEndian(Rle16, runs[0..nruns], .little);
        } else { // array container
            const nblocks = misc.numGroupsOfSize(thiscard * @sizeOf(u16), C.BLOCK_SIZE);

            try c.realloc_container(allocator, .array, thiscard, @intCast(nblocks));
            const arr = misc.asSlice([]align(C.BLOCK_ALIGN) u16, c.data.blocks[0..nblocks]);
            try r.readSliceEndian(u16, arr[0..thiscard], .little);
        }
    }

    return ret;
}

/// read/write all header cardinalities and keys along with run_flags
/// when present.  stops before container data.
pub fn deserialize_reader(
    rb: Bitmap,
    r: *Io.Reader,
    run_flags: ?*root.RunFlags,
) !void {
    const array = rb.array;
    const magic = array.magic;
    assert(magic == .SERIAL_COOKIE or magic == .SERIAL_COOKIE_NO_RUNCONTAINER); // TODO
    const len = array.len;
    assert(len <= C.MAX_KEY_CARDINALITY); // data must be corrupted
    const hasruns = magic == .SERIAL_COOKIE;

    if (hasruns) {
        try r.readSliceAll(run_flags.?[0 .. (len + 7) / 8]);
    }

    for (rb.get_keys(), rb.get_containers()) |*k, c| { // TODO maybe read N key_cards at a time, less looping here
        const kc = try r.takeStruct(root.KeyCard, .little);
        k.* = kc.key;
        c.data.cardinality = @as(Cardinality, kc.cardinality_minus1) + 1;
    }

    // skip file offsets
    if (!hasruns or (hasruns and len >= C.NO_OFFSET_THRESHOLD))
        _ = try r.discard(.limited(len * @sizeOf(u32)));
}

/// insert key and container at index i, increment array.len by 1.
pub fn insert_new_key_value_at(
    r: *Bitmap,
    allocator: Allocator,
    i: u32,
    key: u16,
    c: Container,
) !void {
    try r.ensure_unused_capacity(allocator, 1);
    const len = r.array.len;
    const ks = r.array.keys[0..len];
    const cs = r.array.containers[0..len];
    @memmove(ks.ptr + i + 1, ks[i..]);
    ks.ptr[i] = key;
    @memmove(cs.ptr + i + 1, cs[i..]);
    cs.ptr[i] = c;
    r.array.len += 1;
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
    const mcontaineridx = r.get_key_index(key);
    if (mcontaineridx >= 0) { // key found
        const cid: u32 = @bitCast(mcontaineridx);
        const c = &r.array.containers[cid];
        const c2 = try c.add(allocator, valuelow);
        if (c2.data != c.data) {
            c.deinit(allocator);
            r.array.containers[cid] = c2;
        }
        return c.data.cardinality != c2.data.cardinality;
    } else { // key not found, add new array container
        const cid: u32 = @intCast(-mcontaineridx - 1);
        var newac = try Container.create(allocator, .array, 0, 1);
        errdefer newac.deinit(allocator);
        try r.insert_new_key_value_at(allocator, cid, key, newac);
        _ = newac.add(allocator, valuelow) catch unreachable; // never fails. always an array with cardinality 1
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
    const i = misc.binarySearch(r.get_keys(), key);
    if (i >= 0) {
        // TODO //  ra_unshare_container_at_index(ra, @truncate(i));
        const iu: u32 = @bitCast(i);
        const c = &r.array.containers[iu];
        const c2 = try c.add(allocator, @truncate(val));
        index.* = iu;
        if (c2.data != c.data) {
            c.deinit(allocator);
            r.array.containers[iu] = c2;
            return &r.array.containers[iu];
        } else {
            return c;
        }
    } else {
        index.* = @intCast(-i - 1);
        var newac = try Container.create(allocator, .array, 0, 1);
        errdefer newac.deinit(allocator);
        try r.insert_new_key_value_at(allocator, index.*, key, newac);
        _ = newac.add(allocator, @truncate(val)) catch unreachable; // never fails. always an array with cardinality 1
        return &r.array.containers[index.*];
    }
}

/// similar to `add_bulk_impl` from croaring
pub fn add_checked_bulk(
    r: *Bitmap,
    allocator: Allocator,
    context: *BulkContext,
    val: u32,
) !bool {
    if (r.is_empty()) {
        @branchHint(.unlikely);
        r.* = try create_with_capacity(allocator, 1);
    }

    const key: u16 = @truncate(val >> 16);
    if (context.container.is_uninit() or context.key != key) { // not found
        context.container = try r.containerptr_add(allocator, val, &context.idx);
        context.key = key;
        return true;
    } else {
        // no need to seek the container, it is at hand
        // because we already have the container at hand, we can do the
        // insertion directly, bypassing `add`
        const card = context.container.data.cardinality;
        const c2 = try context.container.add(allocator, @truncate(val));
        if (c2.data != context.container.data) {
            @branchHint(.unlikely);
            // rare instance when we need to change the container
            context.container.deinit(allocator);
            r.array.containers[context.idx] = c2;
            context.container = &r.array.containers[context.idx];
        }
        return context.container.data.cardinality != card;
    }
}

pub fn add_bulk(r: *Bitmap, allocator: Allocator, context: *BulkContext, val: u32) !void {
    _ = try r.add_checked_bulk(allocator, context, val);
}

fn append(r: *Bitmap, allocator: Allocator, key: u16, c: Container) !void {
    try r.ensure_unused_capacity(allocator, 1);
    const pos = r.array.len;
    r.array.keys[pos] = key;
    r.array.containers[pos] = c;
    r.array.len += 1;
}

fn replace_key_and_container_at_index(r: Bitmap, i: u32, key: u16, c: Container) void {
    assert(i < r.array.len);
    r.array.containers[i] = c;
    r.array.keys[i] = key;
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
    const len = r.array.len;
    const keys = r.get_keys();

    const suffix_len = misc.count_greater(keys, @truncate(max_key));
    const prefix_len = misc.count_less(keys[0 .. len - suffix_len], @truncate(min_key));
    const common_len = len - prefix_len - suffix_len;
    // trace(@src(), "len={} num_required_containers={} prefix_len={} suffix_len={} common_len={}", .{ len, num_required_containers, prefix_len, suffix_len, common_len });
    if (num_required_containers > common_len) {
        const distance = num_required_containers - common_len;
        try r.shift_tail(allocator, suffix_len, @bitCast(distance));
        @memset(r.get_containers()[prefix_len + common_len ..][0..distance], .uninit);
    }

    const src_start: i32 = @bitCast(prefix_len + common_len -% 1);
    var src = src_start;
    const dst_start = r.array.len - suffix_len -% 1;
    var dst = dst_start;
    errdefer { // maintain valid state on error.  consumed containers are lost.

        // deinit containers from [dst+1 .. dst_start]
        if (dst < dst_start) {
            var i = dst_start + 1;
            while (true) {
                i -= 1;
                if (i == dst) break;
                r.array.containers[i].deinit(allocator);
            }
        }
        // move containers and keys back into place
        const mdistance: i32 = @bitCast(num_required_containers -% common_len);
        const distance: u32 = @bitCast(mdistance);
        const srcidx = prefix_len + common_len;
        const consumed_count: u32 = @bitCast(src_start - src);
        const dstidx = srcidx - consumed_count;
        // trace(
        //     @src(),
        //     "errdefer: len={} r.array.len={} dst={} dst_start={} mdistance={} srcidx={} consumed_count={} dstidx={}",
        //     .{ len, r.array.len, dst, dst_start, mdistance, srcidx, consumed_count, dstidx },
        // );
        if (srcidx + distance < r.array.len) {
            @memmove(
                r.array.containers[dstidx..],
                r.array.containers[srcidx + distance .. r.array.len],
            );
            @memmove(
                r.array.keys[dstidx..],
                r.array.keys[srcidx + distance .. r.array.len],
            );
        }
        r.array.len = len - consumed_count;
    }

    var key = max_key;
    // trace(@src(), "dst={} src={} len={}", .{ dst, src, r.array.len });
    while (key +% 1 != min_key) : (key -%= 1) { // beware of min_key==0
        // trace(@src(), "dst={} key={} min_key={} max_key={} len={}", .{ dst, key, min_key, max_key, r.array.len });
        const container_min = if (min_key == key) min & 0xffff else 0;
        const container_max = if (max_key == key) max & 0xffff else 0xffff;
        var newc = Container.uninit;
        const srcu: u32 = @bitCast(src);
        // trace(@src(), "src={}", .{src});
        if (src >= 0 and r.get_keys()[srcu] == key) {
            // TODO // ra.unshare_container_at_index(srcu);
            newc = try r.array.containers[srcu]
                .container_add_range(allocator, container_min, container_max);
            if (newc.data != r.array.containers[srcu].data) {
                r.array.containers[srcu].deinit(allocator);
            } else r.array.containers[srcu] = Container.uninit;
            src -= 1;
        } else {
            newc = try Container.from_range(allocator, container_min, container_max + 1, 1);
        }
        // trace(@src(), "dst {}, newc {f}", .{ dst, newc.fmtLong(@intCast(key)) });
        assert(!newc.is_uninit());
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
    return r.array.containers[iu].contains(@truncate(val));
}

/// true if the two bitmaps contain the same elements.
pub fn equals(r1: Bitmap, r2: Bitmap) bool {
    const h1 = r1.array;
    const h2 = r2.array;
    if (h1 == h2)
        return true;
    const len = h1.len;
    if (len != h2.len)
        return false;

    if (!misc.memequals(
        @ptrCast(@alignCast(h1.keys)),
        @ptrCast(@alignCast(h2.keys)),
        len * @sizeOf(u16),
    ))
        return false;

    for (h1.containers[0..len], h2.containers) |c1, c2| {
        if (!c1.equals(c2))
            return false;
    }

    return true;
}

/// Renamed from `ra_get_index`.
///
/// Get the index corresponding to a 16-bit key.
pub fn get_key_index(r: Bitmap, key: u16) i32 {
    const keys = r.get_keys();
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
    const cs = r.array.containers;
    for (r.get_keys(), cs) |k, c| {
        if (key > k) {
            index += c.get_cardinality();
        } else if (key == k) {
            const low_idx = cs[key_idxu].get_index(@truncate(x));
            if (low_idx < 0) return -1;
            return index + low_idx;
        } else {
            return -1;
        }
    }
    return index;
}

pub fn has_run_container(r: Bitmap) bool {
    return for (r.get_containers()) |c| {
        if (c.data.typecode == .run) break true;
    } else false;
}

/// depends only on `Array` `len`.
pub fn portable_size_ext(ra: Bitmap, hasruns: bool) usize {
    const count = ra.array.len;
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
    for (ra.get_containers()) |c| {
        count += c.serialized_size_in_bytes();
        // trace(@src(), "serialized_size_in_bytes={}", .{c.serialized_size_in_bytes()});
    }
    return count;
}

/// Writes the container to `w`, returns how many bytes were written.
/// The number of bytes written should be equal to `portable_size_in_bytes()`.
pub fn write_container(c: Container, w: *Io.Writer) !usize {
    switch (c.data.typecode) {
        .array => {
            // std.debug.print("array card {}\n", .{ card });
            try w.writeSliceEndian(u16, c.blocks_as(.array)[0..c.data.cardinality], .little);
            return c.data.cardinality * @sizeOf(u16);
        },
        .run => {
            try w.writeInt(u16, @intCast(c.data.cardinality), .little);
            try w.writeSliceEndian(Rle16, c.blocks_as(.run)[0..c.data.cardinality], .little);
            return @sizeOf(u16) + c.data.cardinality * @sizeOf(Rle16);
        },
        .bitset => {
            assert(c.data.blocks_cap == C.BITSET_BLOCKS);
            try w.writeSliceEndian(u64, c.blocks_as(.bitset)[0..C.BITSET_CONTAINER_SIZE_IN_WORDS], .little);
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
    const len = r.array.len;

    var startOffset: u32 = 0;
    var written_count: usize = 0;
    const hasrun = r.has_run_container();
    const cs = r.get_containers();
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
            if (c.data.typecode == .run) {
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

    for (r.get_keys(), cs) |k, c| {
        try w.writeInt(u16, k, .little);
        const card: u16 = @intCast(c.get_cardinality() - 1);
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
        written_count += try write_container(c, w);
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

    for (0..r.array.len) |i| {
        // TODO // r.unshare_container_at_index(i); // TODO: this introduces extra cloning!
        const c1 = try Container.convert_run_optimize(&r.array.containers[i], allocator);
        if (c1.data.typecode == .run) answer = true;
        r.array.containers[i] = c1;
    }
    return answer;
}

/// Get the cardinality of the bitmap (number of elements).
pub fn get_cardinality(r: Bitmap) u64 {
    if (r.is_empty()) return 0;
    var card: i64 = 0; // signed for sign extension, matching C i32->u64
    for (r.get_containers()) |c| {
        // sign extend C.BITSET_UNKNOWN_CARDINALITY, u30 max, to i64 min.
        const cc: Container.ICardinality = @bitCast(c.get_cardinality());
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
    return r.array.flags & @as(u8, 1) << @intCast(@intFromEnum(flag)) != 0;
}

pub fn internal_validate_header(r: Bitmap, reason: *?[]const u8) bool {
    const h = r.array;
    const magic = h.magic;
    if (!(r.is_empty() or
        magic == .SERIAL_COOKIE or
        magic == .SERIAL_COOKIE_NO_RUNCONTAINER))
    {
        trace(@src(), "magic={}", .{@intFromEnum(magic)});
        reason.* = "unsupported magic";
        return false;
    }

    // trace(@src(), "{}\n  buffer_size()={} h.allocation_size={}", .{ h, h.buffer_size(), h.capacity });
    if (!(h.capacity >= h.len)) {
        reason.* = "array capacity not gte len";
        return false;
    }

    if (@popCount(r.array.flags) > 1) {
        reason.* = "invalid flags";
        return false;
    }

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
    if (!(@import("builtin").is_test or @import("builtin").mode == .Debug))
        return;
    reason.* = null;
    // trace(@src(), "{f}", .{r});
    if (r.is_empty()) return true;
    if (!r.internal_validate_header(reason)) return false;
    if (r.array.len == 0) return true;
    const keys = r.get_keys();
    var prev_key = keys[0];
    for (keys[1..]) |*key| {
        if (key.* <= prev_key) {
            reason.* = "keys not strictly increasing";
            trace(@src(), "key={} idx={}", .{ key.*, key - keys.ptr });
            return false;
        }
        prev_key = key.*;
    }

    for (r.get_containers(), 0..) |c, cid| {
        if (c.data.typecode == .shared and !r.get_flag(.cow)) {
            reason.* = "shared container in non-COW bitmap";
            return false;
        }
        if (!c.internal_validate(reason)) {
            trace(@src(), "invalid container at index={}: {f}", .{ cid, c.fmtLong(keys[cid]) });
            // reason should already be set
            if (reason.* == null) {
                reason.* = "container failed to validate but no reason given";
            }
            return false;
        }
    }

    return true;
}

pub fn assert_valid(r: Bitmap) void {
    if (!(@import("builtin").is_test or @import("builtin").mode == .Debug))
        return;
    var reason: ?[]const u8 = null;
    if (!r.internal_validate(&reason)) {
        trace(@src(), "{s}", .{reason.?});
        trace(@src(), "{f}", .{r.fmtLong()});
        for (r.get_keys(), r.get_containers(), 0..) |k, c, i| {
            if (false)
                trace(@src(), "{} {}: {f}", .{ i, k, c.fmt(r) });
        }

        unreachable;
    }
}

/// copy r to newarray maintaining new capacity, keys and containers
pub fn copy_to(r: Bitmap, newarray: *align(C.BLOCK_ALIGN) Array) void {
    newarray.* = .{
        .capacity = newarray.capacity,
        .containers = newarray.containers,
        .keys = newarray.keys,
        .len = r.array.len,
        .flags = r.array.flags,
        .magic = r.array.magic,
    };
    newarray.copyField(r.array, .keys);
    newarray.copyField(r.array, .containers);
}

/// ensure new capacity. deinit if new capacity is 0. shrink if new capacity is
/// less than existing.
///
/// modifies `Array` capacity and moves Array to a new allocation.
pub fn realloc_array(r: *Bitmap, allocator: Allocator, new_capacity: u32) !void {
    if (new_capacity == 0) {
        r.deinit(allocator);
        return;
    }
    assert(new_capacity != r.array.capacity);

    if (r.is_empty()) {
        r.array = try Array.create(allocator, new_capacity);
        zero_init(r.array);
        return;
    }

    const bytes = r.array.asBytes()[0..Array.calcSize(r.array.capacity)];
    const newarray = try Array.create(allocator, new_capacity);
    r.copy_to(newarray);
    allocator.free(bytes);
    r.array = newarray;
}

/// similar to croaring.extend_array.
///
/// ensure the bitmap has room for `more_len` containers and keys. may modify
/// `Array` capacity.
pub fn ensure_unused_capacity(r: *Bitmap, allocator: Allocator, more_len: u32) !void {
    assert(more_len > 0);
    const len = r.array.len;
    const capacity = r.array.capacity;
    const desired_len = len + more_len;
    assert(desired_len < C.MAX_CONTAINERS);
    if (desired_len > capacity) {
        const new_capacity = @min(
            C.MAX_CONTAINERS,
            if (len < 1024) 2 * desired_len else 5 * desired_len / 4,
        );

        if (new_capacity > capacity)
            try r.realloc_array(allocator, new_capacity);
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
        try r.ensure_unused_capacity(allocator, @bitCast(distance));
    }
    const len = &r.array.len;
    const srcpos = len.* - count;
    const dstpos = srcpos +% @as(u32, @bitCast(distance));
    // trace(@src(), "count={} distance={} srcpos={} dstpos={}", .{ count, distance, srcpos, dstpos });
    len.* +%= @bitCast(distance);

    const keys = r.get_keys();
    @memmove(keys[dstpos..].ptr, keys[srcpos..][0..count]);
    const cs = r.get_containers();
    @memmove(cs[dstpos..].ptr, cs[srcpos..][0..count]);
}

pub fn format(r: Bitmap, w: *Io.Writer) !void {
    if (r.is_empty()) {
        try w.writeAll("empty");
        return;
    }
    var blocks_cap: u32 = 0;
    for (r.get_containers()) |c| blocks_cap += c.data.blocks_cap;
    try w.print("Bitmap: len/cap={}/{} {B:.1}. Containers: {B:.1}", .{
        r.array.len,
        r.array.capacity,
        Array.calcSize(r.array.capacity),
        blocks_cap * @sizeOf(Block) + r.array.capacity * C.CONTAINER_DATA_SIZE,
    });

    try w.writeByte('{');
    for (r.get_containers(), r.array.keys, 0..) |c, key, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{}: {B: <6.1} {f}", .{ key, C.CONTAINER_DATA_SIZE + c.data.blocks_cap * @sizeOf(Block), c.fmt(key) });
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
        var blocks_cap: u32 = 0;
        for (r.get_containers()) |c| blocks_cap += c.data.blocks_cap;
        try w.print("Bitmap: len/cap={}/{} {B:.1}. Containers: {B:.1}", .{
            r.array.len,
            r.array.capacity,
            Array.calcSize(r.array.capacity),
            blocks_cap * @sizeOf(Block) + r.array.capacity * C.CONTAINER_DATA_SIZE,
        });

        for (r.get_containers(), r.array.keys, 0..) |c, key, i| {
            try w.print("\n{: <5} {: <5} {B: <6.1} {f}", .{ i, key, C.CONTAINER_DATA_SIZE + c.data.blocks_cap * @sizeOf(Block), c.fmtLong(key) });
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
pub fn frozen_size_in_bytes(rb: Bitmap) usize {
    var num_bytes: usize = 0;
    const len = rb.array.len;
    const cs = rb.array.containers;
    for (0..len) |i| {
        const c = cs[i];
        num_bytes += switch (c.data.typecode) {
            .bitset => @sizeOf(root.Bitset),
            .run => c.data.cardinality * @sizeOf(root.Rle16),
            .array => c.data.cardinality * @sizeOf(u16),
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

/// in safe builds, `buf` must have size `r.frozen_size_in_bytes()`.
pub fn frozen_serialize(r: Bitmap, buf: []u8) !void {
    // Note: we do not require user to supply a specifically aligned buffer.

    var bitset_zone_size: usize = 0;
    var run_zone_size: usize = 0;
    var array_zone_size: usize = 0;

    const len = r.array.len;
    const cs = r.array.containers;
    for (cs[0..len]) |c| {
        switch (c.data.typecode) {
            .bitset => bitset_zone_size += C.BITSET_CONTAINER_SIZE_IN_WORDS,
            .run => run_zone_size += c.data.cardinality,
            .array => array_zone_size += c.data.cardinality,
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
        // std.debug.print("c {f} typecode {}\n", .{ c, @intFromEnum(c.data.typecode) });
        typecode.* = c.data.typecode;
        count.* = @intCast(switch (c.data.typecode) {
            .bitset => blk: {
                var w = fixedw(mem.sliceAsBytes(bitset_zone[0..C.BITSET_CONTAINER_SIZE_IN_WORDS]));
                try w.writeSliceEndian(root.Word, c.blocks_as(.bitset)[0..C.BITSET_CONTAINER_SIZE_IN_WORDS], .little);
                assert(w.unusedCapacityLen() == 0);
                bitset_zone += C.BITSET_CONTAINER_SIZE_IN_WORDS;
                break :blk if (c.data.cardinality != C.BITSET_UNKNOWN_CARDINALITY)
                    c.data.cardinality - 1
                else
                    c.compute_cardinality() - 1;
            },
            .run => blk: {
                var w = fixedw(mem.sliceAsBytes(run_zone[0..c.data.cardinality]));
                try w.writeSliceEndian(root.Rle16, c.blocks_as(.run)[0..c.data.cardinality], .little);
                assert(w.unusedCapacityLen() == 0);
                run_zone += c.data.cardinality;
                break :blk c.data.cardinality;
            },
            .array => blk: {
                var w = fixedw(mem.sliceAsBytes(array_zone[0..c.data.cardinality]));
                try w.writeSliceEndian(u16, c.blocks_as(.array)[0..c.data.cardinality], .little);
                assert(w.unusedCapacityLen() == 0);
                array_zone += c.data.cardinality;
                break :blk c.data.cardinality - 1;
            },
            else => unreachable,
        });
    }
    var keysw = fixedw(mem.sliceAsBytes(key_zone[0..len]));
    try keysw.writeSliceEndian(u16, r.array.keys[0..len], .little);
    var headerw = fixedw(mem.sliceAsBytes(header_zone[0..1]));
    try headerw.writeInt(
        u32,
        (@as(u32, @intCast(len)) << 15) | @intFromEnum(root.Magic.FROZEN_COOKIE),
        .little,
    );
}

/// Creates constant bitmap that is a view of a given buffer.
/// Buffer data should have been written by `roaring_bitmap_frozen_serialize()`
/// Its beginning must also be aligned by 32 bytes.
/// Length must be equal exactly to `roaring_bitmap_frozen_size_in_bytes()`.
/// In case of failure, NULL is returned.
///
/// Bitmap returned by this function can be used in all readonly contexts.
/// Bitmap must be freed as usual, by calling roaring_bitmap_free().
/// Underlying buffer must not be freed or modified while it backs any bitmaps.
///
/// This function is endian-sensitive. If you have a big-endian system (e.g., a
/// mainframe IBM s390x), the data format is going to be big-endian and not
/// compatible with little-endian systems.
///
/// Note: differs from CRoaring in that `Array.keys` are also allocated and
/// copied because zroaring requires block aligned keys.
pub fn frozen_view(
    allocator: std.mem.Allocator,
    /// frozen serialized bytes
    buf: []align(C.BLOCK_ALIGN) const u8,
) !Bitmap {
    const length = buf.len;
    // cookie and num_containers
    if (length < 4)
        return error.BufferSize;

    const header = mem.readInt(u32, buf[buf.len - 4 ..][0..4], .little);

    const num_containers = (header >> 15);
    if (header & 0x7FFF != @intFromEnum(root.Magic.FROZEN_COOKIE))
        return error.Magic;

    if (length < 4 + num_containers * (1 + 2 + 2)) // typecodes + counts + keys
        return error.BufferSize;

    const keys: [*]const u16 = @ptrCast(@alignCast(buf.ptr + length - 4 - num_containers * 5));
    const counts: [*]const u16 = @ptrCast(@alignCast(buf.ptr + length - 4 - num_containers * 3));
    const typecodes = buf.ptr + length - 4 - num_containers * 1;

    // {bitset,array,run}_zone
    var num_bitset_containers: u32 = 0;
    var num_run_containers: u32 = 0;
    var num_array_containers: u32 = 0;
    var bitset_zone_size: usize = 0;
    var run_zone_size: usize = 0;
    var array_zone_size: usize = 0;
    var num_blocks: u32 = 0;

    for (0..num_containers) |i| {
        switch (@as(Typecode, @enumFromInt(typecodes[i]))) {
            .bitset => {
                num_bitset_containers += 1;
                bitset_zone_size += @sizeOf(root.Bitset);
            },
            .run => {
                num_run_containers += 1;
                num_blocks += misc.numGroupsOfSize(counts[i], C.BLOCK_LEN32);
                run_zone_size += counts[i] * @sizeOf(Rle16);
            },
            .array => {
                num_array_containers += 1;
                num_blocks += misc.numGroupsOfSize(counts[i] + @as(u32, 1), C.BLOCK_LEN16);
                array_zone_size += (counts[i] + @as(u32, 1)) * @sizeOf(u16);
            },
            else => return error.Typecode,
        }
    }
    if (length != bitset_zone_size + run_zone_size + array_zone_size + 5 * num_containers + 4)
        return error.BufferSize;

    var bitset_zone: [*]const u64 = @ptrCast(@alignCast(buf.ptr));
    var run_zone: [*]const Rle16 = @ptrCast(@alignCast(buf.ptr + bitset_zone_size));
    var array_zone: [*]const u16 = @ptrCast(@alignCast(buf.ptr + bitset_zone_size + run_zone_size));

    var alloc_size: usize = Array.calcSize(num_containers);
    alloc_size += C.BLOCK_ALIGNMENT.forward(
        (num_bitset_containers + num_run_containers + num_array_containers) * C.CONTAINER_DATA_SIZE,
    );
    alloc_size += num_blocks * C.BLOCK_SIZE;
    const arena_mem = try allocator.alignedAlloc(u8, C.BLOCK_ALIGNMENT, alloc_size);
    errdefer allocator.free(arena_mem);
    const array: *Array = @ptrCast(arena_mem.ptr);
    var arena: [*]u8 = arena_mem.ptr + @sizeOf(Array);
    array.* = .{
        .flags = 1 << @intFromEnum(Flag.frozen),
        .magic = .FROZEN_COOKIE,
        .len = num_containers,
        .capacity = num_containers,
        .keys = @ptrCast(@alignCast(arena_alloc(u16, @ptrCast(&arena), num_containers).ptr)),
        .containers = undefined,
    };
    @memcpy(array.keys[0..array.len], keys);
    arena += mem.alignPointerOffset(arena, C.BLOCK_ALIGN).?;
    array.containers = @ptrCast(@alignCast(arena_alloc(Container, @ptrCast(&arena), num_containers).ptr));
    arena += mem.alignPointerOffset(arena, C.BLOCK_ALIGN).?;
    var blocks: [*]Block = @ptrCast(@alignCast(&arena_mem.ptr[arena_mem.len]));

    for (0..num_containers) |i| {
        switch (@as(Typecode, @enumFromInt(typecodes[i]))) {
            .bitset => {
                const cardinality = counts[i] + @as(u32, 1);
                arena = mem.alignPointer(arena, C.BLOCK_ALIGN).?;
                const bitset = arena_alloc(Container.Data, @ptrCast(&arena), 1);
                bitset[0] = .{
                    .blocks = @ptrCast(@alignCast(@constCast(bitset_zone))),
                    .blocks_cap = C.BITSET_BLOCKS,
                    .cardinality = cardinality,
                    .typecode = .bitset,
                };
                array.containers[i] = .{ .data = @alignCast(&bitset[0]) };
                bitset_zone += C.BITSET_CONTAINER_SIZE_IN_WORDS;
            },
            .run => { // use counts[i] here while bitsets and arrays use counts[i]+1
                arena = mem.alignPointer(arena, C.BLOCK_ALIGN).?;
                const run = arena_alloc(Container.Data, @ptrCast(&arena), 1);
                const blocks_cap = misc.numGroupsOfSize(counts[i], C.BLOCK_LEN32);
                blocks -= blocks_cap;
                const rleblocks: [*]align(C.BLOCK_ALIGN) Rle16 = @ptrCast(blocks);
                @memcpy(rleblocks, run_zone[0..counts[i]]);
                run[0] = .{
                    .cardinality = counts[i],
                    .blocks_cap = blocks_cap,
                    .blocks = blocks,
                    .typecode = .run,
                };
                array.containers[i] = .{ .data = @alignCast(&run[0]) };
                run_zone += counts[i];
            },
            .array => {
                const cardinality = counts[i] + @as(u32, 1);
                arena = mem.alignPointer(arena, C.BLOCK_ALIGN).?;
                const arr = arena_alloc(Container.Data, @ptrCast(&arena), 1);
                const blocks_cap: u16 = @intCast(misc.numGroupsOfSize(cardinality, C.BLOCK_LEN16));
                blocks -= blocks_cap;
                const arrblocks: [*]align(C.BLOCK_ALIGN) u16 = @ptrCast(@alignCast(blocks));
                @memcpy(arrblocks, array_zone[0..cardinality]);
                arr[0] = .{
                    .blocks_cap = blocks_cap,
                    .cardinality = cardinality,
                    .blocks = blocks,
                    .typecode = .array,
                };
                array.containers[i] = .{ .data = @alignCast(&arr[0]) };
                array_zone += cardinality;
            },
            else => return error.Typecode,
        }
    }

    return .{ .array = array };
}

/// call shrink_to_fit() on all containers which may shrink their blocks allocation.
/// shrink array if len < cap.
pub fn shrink_to_fit(r: *Bitmap, allocator: Allocator) !usize {
    const capacity = r.array.capacity;
    const len = r.array.len;
    // possibly shrink containers
    var containersavings: usize = 0;
    for (0..len) |i| {
        const c = &r.array.containers[i];
        assert(!c.is_uninit());
        containersavings += try c.shrink_to_fit(allocator);
    }

    if (containersavings == 0 and capacity == len)
        return 0; // no shrinking possible

    assert(len <= capacity);
    if (len != capacity)
        try r.realloc_array(allocator, len);

    return containersavings +
        (capacity - len) * (@sizeOf(u16) + @sizeOf(Container));
}

pub fn remove_at_index(r: *Bitmap, i: usize, allocator: mem.Allocator) void {
    const len = r.array.len;
    assert(i < len);
    const ctrs = r.array.containers;
    const keys = r.array.keys;
    ctrs[i].deinit(allocator);
    @memmove(ctrs[i..], ctrs[i + 1 ..][0 .. len - i - 1]);
    @memmove(keys[i..], keys[i + 1 ..][0 .. len - i - 1]);
    r.array.len -= 1;
}

/// Same as `deinit` because we don't free a Bitmap pointer like CRoaring.
pub const clear = deinit;

pub fn remove(r: *Bitmap, allocator: Allocator, val: u32) !void {
    _ = try r.remove_checked(allocator, val);
}

pub fn remove_checked(r: *Bitmap, allocator: Allocator, val: u32) !bool {
    r.assert_valid();
    trace(@src(), "val={}", .{val});
    const key: u16 = @truncate(val >> 16);
    const i = r.get_key_index(key);
    if (i >= 0) {
        // TODO // r.unshare_container_at_index(i);
        const iu: u32 = @intCast(i);
        const c = &r.array.containers[iu];
        const oldcard = c.get_cardinality();
        const c2 = try c.remove(allocator, @truncate(val));
        if (c2.data != c.data) {
            c.deinit(allocator);
            r.array.containers[iu] = c2;
        }

        const newcard = c2.get_cardinality();
        // trace(@src(), "old/newcard={}/{} c2={f}", .{ oldcard, newcard, c2.fmt(r.*, c.get_key(r.*)) });
        if (newcard != 0) {
            r.array.containers[iu] = c2;
        } else {
            r.remove_at_index(iu, allocator);
        }
        r.assert_valid();
        return oldcard != newcard;
    }
    r.assert_valid();
    return false;
}

pub fn is_cow(x1: Bitmap) bool {
    return (x1.array.flags & 1 << @intFromEnum(Flag.cow)) != 0;
}

pub fn set_copy_on_write(x1: Bitmap, cow: bool) void {
    x1.array.flags |= (@as(u8, @intFromBool(cow)) << @intFromEnum(Flag.cow));
}

fn advance_until(ra: Bitmap, x: u16, pos: u32) u32 {
    return misc.advanceUntil(ra.get_keys(), pos, x);
}

pub fn copy(src: Bitmap, allocator: Allocator) !Bitmap {
    if (src.is_empty()) return src;
    const a = try Array.create(allocator, src.array.len);
    errdefer a.destroy(allocator);
    var ret: Bitmap = .{ .array = a };
    ret.array.len = src.array.len;
    ret.array.magic = src.array.magic;
    ret.array.flags = src.array.flags;
    @memcpy(ret.array.keys[0..src.array.len], src.array.keys[0..src.array.len]);
    try Array.cloneContainers(src, allocator, &ret);
    return ret;
}

pub fn overwrite(r: *Bitmap, allocator: Allocator, src: Bitmap) !void {
    const new_copy = try src.copy(allocator);
    r.deinit(allocator);
    r.* = new_copy;
}

pub fn is_subset(r1: Bitmap, r2: Bitmap) bool {
    const keys1 = r1.get_keys();
    const keys2 = r2.get_keys();
    const containers1 = r1.get_containers();
    const containers2 = r2.get_containers();
    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (pos1 < containers1.len and pos2 < containers2.len) {
        const key1 = keys1[pos1];
        const key2 = keys2[pos2];
        if (key1 == key2) {
            if (!containers1[pos1].is_subset(containers2[pos2]))
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
pub fn intersect(x1: Bitmap, allocator: Allocator, x2: Bitmap) !Bitmap {
    const length1 = x1.array.len;
    const length2 = x2.array.len;
    var answer = try create_with_capacity(allocator, @max(length1, length2));
    errdefer answer.deinit(allocator);
    answer.set_copy_on_write(x1.is_cow() or x2.is_cow());
    defer answer.assert_valid();
    trace(@src(), "x1={f}", .{x1.fmtLong()});
    trace(@src(), "x2={f}", .{x2.fmtLong()});

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (pos1 < length1 and pos2 < length2) {
        const key1 = x1.array.keys[pos1];
        const key2 = x2.array.keys[pos2];

        if (key1 == key2) {
            const c1 = x1.array.containers[pos1];
            const c2 = x2.array.containers[pos2];
            var c = try Container.intersect(c1, allocator, c2, &answer);

            if (c.nonzero_cardinality()) {
                try answer.append(allocator, key1, c);
            } else {
                c.deinit(allocator); // otherwise: memory leak!
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
    sa: Bitmap,
    start_index: u32,
    end_index: u32,
    copy_on_write: bool,
) !void {
    const sakeys = sa.array.keys;
    const sacontainers = sa.array.containers;
    const more_len = end_index - start_index;
    if (more_len > 0)
        try ra.ensure_unused_capacity(allocator, more_len);

    for (start_index..end_index) |i| {
        const pos = ra.array.len;
        ra.array.keys[pos] = sakeys[i];
        const c = if (copy_on_write)
            try sacontainers[i].get_copy_of_container(allocator, copy_on_write)
        else
            try sacontainers[i].clone(allocator);
        ra.array.containers[pos] = c;
        ra.array.len += 1;
    }
}

/// Computes the union between two bitmaps and returns new bitmap. The caller is
/// responsible for memory management.
pub const @"or" = merge;

pub fn merge(x1: Bitmap, allocator: Allocator, x2: Bitmap) !Bitmap {
    trace(@src(), "x1={f}", .{x1.fmtLong()});
    trace(@src(), "x2={f}", .{x2.fmtLong()});
    const length1 = x1.array.len;
    const length2 = x2.array.len;
    if (length1 == 0) return try x2.copy(allocator);
    if (length2 == 0) return try x1.copy(allocator);

    var answer = try create_with_capacity(allocator, length1 + length2);
    errdefer answer.deinit(allocator);
    answer.set_copy_on_write(x1.is_cow() or x2.is_cow());
    defer answer.assert_valid();

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (pos1 < length1 and pos2 < length2) {
        const key1 = x1.array.keys[pos1];
        const key2 = x2.array.keys[pos2];

        if (key1 == key2) {
            const c1 = x1.array.containers[pos1];
            const c2 = x2.array.containers[pos2];
            const c = try c1.merge(allocator, c2);
            try answer.append(allocator, key1, c);
            pos1 += 1;
            pos2 += 1;
        } else if (key1 < key2) {
            const c1 = x1.array.containers[pos1];
            const c = try c1.get_copy_of_container(allocator, x1.is_cow());
            try answer.append(allocator, key1, c);
            pos1 += 1;
        } else {
            const c2 = x2.array.containers[pos2];
            const c = try c2.get_copy_of_container(allocator, x2.is_cow());
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
pub fn or_inplace(x1: *Bitmap, allocator: Allocator, x2: Bitmap) !void {
    trace(@src(), "x1: {f}", .{x1.fmtLong()});
    trace(@src(), "x2: {f}", .{x2.fmtLong()});
    const length2 = x2.array.len;
    if (length2 == 0) return;

    var length1 = x1.array.len;
    if (length1 == 0) {
        try x1.overwrite(allocator, x2);
        return;
    }

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    var key1 = x1.array.keys[pos1];
    var key2 = x2.array.keys[pos2];
    while (true) {
        if (key1 == key2) {
            const c1 = &x1.array.containers[pos1];
            const c2 = x2.array.containers[pos2];
            if (!c1.is_full()) {
                const c = if (c1.data.typecode == .shared)
                    try c1.merge(allocator, c2)
                else
                    try c1.ior(allocator, c2);
                if (c.data != c1.data)
                    c1.deinit(allocator);
                x1.array.containers[pos1] = c;
            }
            pos1 += 1;
            pos2 += 1;
            if (pos1 == length1) break;
            if (pos2 == length2) break;
            key1 = x1.array.keys[pos1];
            key2 = x2.array.keys[pos2];
        } else if (key1 < key2) {
            pos1 += 1;
            if (pos1 == length1) break;
            key1 = x1.array.keys[pos1];
        } else { // key1 > key2
            var c2 = x2.array.containers[pos2];
            c2 = try c2.get_copy_of_container(allocator, x2.is_cow());
            errdefer c2.deinit(allocator);
            if (x2.is_cow())
                x2.array.containers[pos2] = c2;
            try x1.insert_new_key_value_at(allocator, pos1, key2, c2);
            pos1 += 1;
            length1 += 1;
            pos2 += 1;

            if (pos2 == length2) break;
            key2 = x2.array.keys[pos2];
        }
    }

    if (pos1 == length1) {
        try x1.append_copy_range(allocator, x2, pos2, length2, x2.is_cow());
    }
}

/// Returned Bitamp contains values present in one but not both inputs.
pub fn xor(x1: Bitmap, allocator: Allocator, x2: Bitmap) !Bitmap {
    trace(@src(), "x1={f}", .{x1.fmtLong()});
    trace(@src(), "x2={f}", .{x2.fmtLong()});
    const length1 = x1.array.len;
    const length2 = x2.array.len;
    if (length1 == 0) return try x2.copy(allocator);
    if (length2 == 0) return try x1.copy(allocator);

    var answer = try create_with_capacity(allocator, length1 + length2);
    errdefer answer.deinit(allocator);
    answer.set_copy_on_write(x1.is_cow() or x2.is_cow());
    defer answer.assert_valid();

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (pos1 < length1 and pos2 < length2) {
        const key1 = x1.array.keys[pos1];
        const key2 = x2.array.keys[pos2];

        if (key1 == key2) {
            const c1 = x1.array.containers[pos1];
            const c2 = x2.array.containers[pos2];
            var c = try c1.xor(allocator, c2);
            if (c.nonzero_cardinality()) {
                try answer.append(allocator, key1, c);
            } else {
                c.deinit(allocator);
            }
            pos1 += 1;
            pos2 += 1;
        } else if (key1 < key2) {
            const c1 = x1.array.containers[pos1];
            const c = try c1.get_copy_of_container(allocator, x1.is_cow());
            try answer.append(allocator, key1, c);
            pos1 += 1;
        } else {
            const c2 = x2.array.containers[pos2];
            const c = try c2.get_copy_of_container(allocator, x2.is_cow());
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
pub fn andnot(x1: Bitmap, allocator: Allocator, x2: Bitmap) !Bitmap {
    const length1 = x1.array.len;
    const length2 = x2.array.len;
    if (length1 == 0) {
        var result = try create_with_capacity(allocator, 0);
        result.set_copy_on_write(x1.is_cow() or x2.is_cow());
        return result;
    }
    if (length2 == 0) return try x1.copy(allocator);

    var answer = try create_with_capacity(allocator, length1);
    errdefer answer.deinit(allocator);
    answer.set_copy_on_write(x1.is_cow() or x2.is_cow());
    defer answer.assert_valid();

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (true) {
        const key1 = x1.array.keys[pos1];
        const key2 = x2.array.keys[pos2];

        if (key1 == key2) {
            const c1 = x1.array.containers[pos1];
            const c2 = x2.array.containers[pos2];
            var c = try c1.andnot(allocator, c2, &answer);
            if (c.nonzero_cardinality()) {
                try answer.append(allocator, key1, c);
            } else {
                c.deinit(allocator);
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
    if (bm.array.len > 0) {
        const c = bm.array.containers[0];
        const key: u32 = bm.array.keys[0];
        const lowvalue = c.minimum();
        return lowvalue | (key << 16);
    }
    return std.math.maxInt(u32);
}

/// returns the greatest value in the set or 0 if the set is empty.
pub fn maximum(bm: Bitmap) u32 {
    const len = bm.array.len;
    if (len > 0) {
        const container = bm.array.containers[len - 1];
        const key: u32 = bm.array.keys[len - 1];
        const lowvalue = container.maximum();
        return lowvalue | (key << 16);
    }
    return 0;
}

/// Returns the number of integers that are smaller or equal to x.
pub fn rank(bm: Bitmap, x: u32) u64 {
    var size: u64 = 0;
    const xhigh: u16 = @truncate(x >> 16);
    for (bm.get_keys(), bm.get_containers()) |key, c| {
        if (xhigh > key) {
            size += c.get_cardinality();
        } else if (xhigh == key) {
            return size + c.rank(@truncate(x));
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
    const len = bm.array.len;
    for (bm.array.keys[0..len], bm.array.containers) |key, c| {
        if (c.select(&start_rank, target_rank)) |element| {
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
    x2: Bitmap,
    bitsetconversion: bool,
) !Bitmap {
    const length1 = x1.array.len;
    const length2 = x2.array.len;
    trace(@src(), "x1={f}", .{x1.fmtLong()});
    trace(@src(), "x2={f}", .{x2.fmtLong()});
    defer x1.assert_valid();
    if (0 == length1)
        return try x2.copy(allocator);

    if (0 == length2)
        return try x1.copy(allocator);

    var answer = try create_with_capacity(allocator, length1 + length2);
    errdefer answer.deinit(allocator);
    defer trace(@src(), "answer={f}", .{answer.fmtLong()});
    defer x1.assert_valid();
    defer answer.assert_valid();
    answer.set_copy_on_write(x1.is_cow() or x2.is_cow());
    var pos1: u32 = 0;
    var pos2: u32 = 0;

    var key1 = x1.array.keys[pos1];
    var key2 = x2.array.keys[pos2];
    while (true) {
        if (key1 == key2) {
            const c1 = x1.array.containers[pos1];
            const c2 = x2.array.containers[pos2];
            var c = Container.uninit;
            if (bitsetconversion and c1.data.typecode != .bitset and c2.data.typecode != .bitset) {
                // TODO // container_mutable_unwrap_shared(c1);
                var newc1 = try c1.to_bitset(allocator);
                errdefer newc1.deinit(allocator);
                c = try newc1.lazy_ior(allocator, c2);
                if (c.data != newc1.data) { // should not happen
                    @branchHint(.unlikely);
                    newc1.deinit(allocator);
                }
            } else {
                c = try c1.lazy_or(allocator, c2);
            }
            // since we assume that the initial containers are non-empty, the
            // result here can only be non-empty
            assert(!c.is_uninit());
            errdefer if (c.data != c1.data) c.deinit(allocator);
            try answer.append(allocator, key1, c);
            pos1 += 1;
            pos2 += 1;
            if (pos1 == length1) break;
            if (pos2 == length2) break;
            key1 = x1.array.keys[pos1];
            key2 = x2.array.keys[pos2];
        } else if (key1 < key2) {
            var c1 = x1.array.containers[pos1];
            c1 = try c1.get_copy_of_container(allocator, x1.is_cow());
            errdefer c1.deinit(allocator);
            if (x1.is_cow()) {
                x1.array.containers[pos1] = c1;
            }
            try answer.append(allocator, key1, c1);
            pos1 += 1;
            key1 = x1.array.keys[pos1];
            if (pos1 == length1) break;
        } else { // key1 > key2
            var c2 = x2.array.containers[pos2];
            c2 = try c2.get_copy_of_container(allocator, x2.is_cow());
            errdefer c2.deinit(allocator);
            if (x2.is_cow()) {
                x2.array.containers[pos2] = c2;
            }
            try answer.append(allocator, key2, c2);

            pos2 += 1;
            if (pos2 == length2) break;
            key2 = x2.array.keys[pos2];
        }
    }
    if (pos1 == length1) {
        try answer.append_copy_range(allocator, x2, pos2, length2, x2.is_cow());
    } else if (pos2 == length2) {
        try answer.append_copy_range(allocator, x1.*, pos1, length1, x1.is_cow());
    }
    return answer;
}

/// (For users who seek high performance.)
///
/// Execute maintenance on a bitmap created from `lazy_or()`
/// or modified with `lazy_or_inplace()`.
pub fn repair_after_lazy(r: *Bitmap, allocator: Allocator) !void {
    const len = r.array.len;
    for (0..len) |i| {
        // read before write! avoids write to stale pointer.
        r.array.containers[i] = try Container.repair_after_lazy(&r.array.containers[i], allocator);
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
    x2: Bitmap,
    bitsetconversion: bool,
) !void {
    var length1 = x1.array.len;
    const length2 = x2.array.len;

    if (length2 == 0) return;
    if (length1 == 0) {
        try x1.overwrite(allocator, x2);
        return;
    }

    trace(@src(), "x1={f}", .{x1.fmtLong()});
    trace(@src(), "x2={f}", .{x2.fmtLong()});
    defer x1.assert_valid();

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    var key1 = x1.array.keys[pos1];
    var key2 = x2.array.keys[pos2];
    while (true) {
        if (key1 == key2) {
            var c1 = x1.array.containers[pos1];
            if (!c1.is_full()) {
                if (!bitsetconversion or c1.data.typecode == .bitset) {
                    errdefer c1.deinit(allocator);
                    c1 = try c1.get_writable_copy_if_shared(allocator, x1.*);
                } else {
                    // convert to bitset
                    const oldc1 = c1;
                    c1 = try x1.array.containers[pos1].to_bitset(allocator);
                    if (c1.data != oldc1.data) {
                        x1.array.containers[pos1].deinit(allocator);
                    }
                    x1.array.containers[pos1] = c1;
                }

                errdefer c1.deinit(allocator);
                c1 = try c1.lazy_ior(allocator, x2.array.containers[pos2]);
                if (c1.data != x1.array.containers[pos1].data) {
                    x1.array.containers[pos1].deinit(allocator);
                }
                x1.array.containers[pos1] = c1;
            }
            pos1 += 1;
            pos2 += 1;
            if (pos1 == length1) break;
            if (pos2 == length2) break;
            key1 = x1.array.keys[pos1];
            key2 = x2.array.keys[pos2];
        } else if (key1 < key2) {
            pos1 += 1;
            if (pos1 == length1) break;
            key1 = x1.array.keys[pos1];
        } else { // key1 > key2
            var c2 = x2.array.containers[pos2];
            c2 = try c2.get_copy_of_container(allocator, x2.is_cow());
            errdefer c2.deinit(allocator);
            if (x2.is_cow())
                x2.array.containers[pos2] = c2;
            try x1.insert_new_key_value_at(allocator, pos1, key2, c2);
            pos1 += 1;
            length1 += 1;
            pos2 += 1;

            if (pos2 == length2) break;
            key2 = x2.array.keys[pos2];
        }
    }

    if (pos1 == length1) {
        try x1.append_copy_range(allocator, x2, pos2, length2, x2.is_cow());
    }
}

/// Compute the union of 'number' bitmaps.
pub fn or_many(allocator: Allocator, xs: []Bitmap) !Bitmap {
    const number = xs.len;
    if (number == 0)
        return empty;
    if (number == 1)
        return try xs[0].copy(allocator);

    var answer = try lazy_or(&xs[0], allocator, xs[1], C.LAZY_OR_BITSET_CONVERSION);
    errdefer answer.deinit(allocator);
    for (2..number) |i| {
        try answer.lazy_or_inplace(allocator, xs[i], C.LAZY_OR_BITSET_CONVERSION);
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
    const hlc_sz = r.array.len;
    if (hlc_sz < span + 1)
        return false;

    const is = r.get_key_index(hb_rs);
    const ie = r.get_key_index(hb_re);
    if (ie < 0 or is < 0 or (ie - is) != span or ie >= hlc_sz)
        return false;

    const lb_rs = range_start & 0xFFFF;
    const lb_re = (range_end & 0xFFFF) + 1;
    const cs = r.array.containers;
    const isu: u32 = @bitCast(is);
    const ieu: u32 = @bitCast(ie);
    if (hb_rs == hb_re)
        return cs[isu].contains_range(lb_rs, lb_re);
    if (!cs[isu].contains_range(lb_rs, 1 << 16))
        return false;
    if (!cs[ieu].contains_range(0, lb_re))
        return false;

    for (isu + 1..ieu) |i| {
        if (!cs[i].is_full())
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

pub fn and_cardinality(x1: Bitmap, x2: Bitmap) u64 {
    const length1 = x1.array.len;
    const length2 = x2.array.len;
    var answer: u64 = 0;
    var pos1: u32 = 0;
    var pos2: u32 = 0;
    while (pos1 < length1 and pos2 < length2) {
        const key1 = x1.array.keys[pos1];
        const key2 = x2.array.keys[pos2];

        if (key1 == key2) {
            const c1 = x1.array.containers[pos1];
            const c2 = x2.array.containers[pos2];
            answer += c1.and_cardinality(c2);
            pos1 += 1;
            pos2 += 1;
        } else if (key1 < key2) {
            pos1 = x1.advance_until(key2, pos1);
        } else { // key1 > key2
            pos2 = x2.advance_until(key1, pos2);
        }
    }
    return answer;
}

pub fn jaccard_index(x1: Bitmap, x2: Bitmap) f64 {
    @setFloatMode(.strict);
    const inter = x1.and_cardinality(x2);
    return @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(
        x1.get_cardinality() + x2.get_cardinality() - inter,
    ));
}

pub fn or_cardinality(x1: Bitmap, x2: Bitmap) u64 {
    return x1.get_cardinality() + x2.get_cardinality() -
        x1.and_cardinality(x2);
}

pub fn andnot_cardinality(x1: Bitmap, x2: Bitmap) u64 {
    return x1.get_cardinality() - x1.and_cardinality(x2);
}

pub fn xor_cardinality(x1: Bitmap, x2: Bitmap) u64 {
    return x1.get_cardinality() + x2.get_cardinality() -
        2 * x1.and_cardinality(x2);
}

pub const iterator = Iterator.init;

pub fn range_cardinality(r: Bitmap, range_start: u64, range_end: u64) u64 {
    if (range_start >= range_end or range_start > std.math.maxInt(u32) + 1) {
        return 0;
    }
    return range_cardinality_closed(r, @truncate(range_start), @truncate(range_end - 1));
}

pub fn range_cardinality_closed(r: Bitmap, range_start: u32, range_end: u32) u64 {
    const ra = r.array;

    if (range_start > range_end)
        return 0;

    // now we have: 0 <= range_start <= range_end <= UINT32_MAX
    const minhb: u16 = @truncate(range_start >> 16);
    const maxhb: u16 = @truncate(range_end >> 16);

    var card: u64 = 0;
    const containers = ra.containers;

    const i = r.get_key_index(minhb);
    var iu: u32 = @bitCast(i);
    if (i >= 0) {
        if (minhb == maxhb) {
            card += containers[iu].rank(@truncate(range_end));
        } else {
            card += containers[iu].get_cardinality();
        }
        const range_start_lo: u16 = @truncate(range_start);
        if (range_start_lo != 0) {
            card -= containers[iu].rank(range_start_lo - 1);
        }
        iu += 1;
    } else {
        iu = @bitCast(-i - 1);
    }

    const len = ra.len;
    const keys = ra.keys;
    while (iu < len) : (iu += 1) {
        const key = keys[iu];
        if (key < maxhb) {
            card += containers[iu].get_cardinality();
        } else if (key == maxhb) {
            card += containers[iu].rank(@truncate(range_end));
            break;
        } else {
            break;
        }
    }

    return card;
}

/// Convert the bitmap to a sorted array, output in `ans`.
///
/// Caller is responsible to ensure that there is enough memory allocated, e.g.
///
///     `ans = allocator.alloc(r.get_cardinality());`
pub fn to_uint32_array(r: Bitmap, ans: []u32) void {
    var anscur = ans;
    const len = r.array.len;
    const cs = r.array.containers;
    const keys = r.array.keys;
    for (cs[0..len], keys[0..len]) |c, key| {
        const num_added = c.to_uint32_array(anscur, @as(u32, key) << 16);
        anscur = anscur[num_added..];
    }
}

/// Inplace version of `roaring_bitmap_and()`, modifies r1
/// r1 == r2 is allowed.
///
/// Performance hint: if you are computing the intersection between several
/// bitmaps, two-by-two, it is best to start with the smallest bitmap.
/// Computes the intersection between two bitmaps and modifies x1 in place.
/// You may also rely on and_inplace to avoid creating many temporary bitmaps.
// there should be some SIMD optimizations possible here
pub fn and_inplace(r1: *Bitmap, allocator: Allocator, r2: Bitmap) !void {
    if (r1.array == r2.array or r1.is_empty()) return;
    const length1 = r1.array.len;
    const length2 = r2.array.len;
    trace(@src(), "x1={f}", .{r1.fmtLong()});
    trace(@src(), "x2={f}", .{r2.fmtLong()});
    defer r1.assert_valid();

    var pos1: u32 = 0;
    var pos2: u32 = 0;
    var intersection_size: u32 = 0;
    defer r1.array.len = intersection_size;
    errdefer {
        while (pos1 < length1) : (pos1 += 1)
            r1.array.containers[pos1].deinit(allocator);
    }

    while (pos1 < length1 and pos2 < length2) {
        const key1 = r1.array.keys[pos1];
        const key2 = r2.array.keys[pos2];

        if (key1 == key2) {
            const c1 = r1.array.containers[pos1];
            const c2 = r2.array.containers[pos2];
            var c = if (c1.data.typecode == .shared)
                try c1.intersect(allocator, c2, r1)
            else
                try Container.iand(&r1.array.containers[pos1], allocator, c2);

            if (c.data != c1.data)
                r1.array.containers[pos1].deinit(allocator);

            if (c.nonzero_cardinality()) {
                r1.array.containers[intersection_size] = c;
                r1.array.keys[intersection_size] = key1;
                intersection_size += 1;
            } else {
                c.deinit(allocator);
            }
            pos1 += 1;
            pos2 += 1;
        } else if (key1 < key2) {
            r1.array.containers[pos1].deinit(allocator);
            pos1 += 1;
        } else {
            pos2 += 1;
        }
    }

    while (pos1 < length1) {
        r1.array.containers[pos1].deinit(allocator);
        pos1 += 1;
    }
}

/// (For advanced users.)
/// Statistics can be used to collect detailed statistics about the composition
/// of a roaring bitmap.
pub const Statistics = struct {
    /// number of containers
    n_containers: u32,
    /// number of array containers
    n_array_containers: u32,
    /// number of run containers
    n_run_containers: u32,
    /// number of bitset containers
    n_bitset_containers: u32,
    /// number of values in array containers
    n_values_array_containers: u32,
    /// number of values in run containers
    n_values_run_containers: u32,
    /// number of values in bitset containers
    n_values_bitset_containers: u32,
    /// number of allocated bytes in array
    n_bytes_array_containers: u32,
    /// number of allocated bytes in run
    n_bytes_run_containers: u32,
    /// number of allocated bytes in  bitmap
    n_bytes_bitset_containers: u32,
    /// the maximal value, undefined if cardinality is zero
    max_value: u32,
    /// the minimal value, undefined if cardinality is zero
    min_value: u32,
    /// deprecated always zero
    sum_value: u64,
    /// total number of values stored in the bitmap
    cardinality: u64,
};

/// (For advanced users.)
/// Collect statistics about the bitmap.
pub fn statistics(bm: Bitmap) Statistics {
    const len = bm.array.len;
    var stat: Statistics = undefined;
    @memset(mem.asBytes(&stat), 0);
    stat.n_containers = len;
    stat.min_value = if (len > 0) bm.minimum() else std.math.maxInt(u32);
    stat.max_value = if (len > 0) bm.maximum() else 0;

    for (bm.get_containers()) |c| {
        const card = c.get_cardinality();
        const sbytes = c.size_in_bytes();
        stat.cardinality += card;
        switch (c.data.typecode) {
            .bitset => {
                stat.n_bitset_containers += 1;
                stat.n_values_bitset_containers += card;
                stat.n_bytes_bitset_containers += sbytes;
            },
            .array => {
                stat.n_array_containers += 1;
                stat.n_values_array_containers += card;
                stat.n_bytes_array_containers += sbytes;
            },
            .run => {
                stat.n_run_containers += 1;
                stat.n_values_run_containers += card;
                stat.n_bytes_run_containers += sbytes;
            },
            .shared => unreachable,
        }
    }
    return stat;
}

/// Compute the negation of the bitmap in the interval [range_start, range_end).
/// The number of negated values is range_end - range_start.
/// Areas outside the range are passed through unchanged.
pub fn flip(x1: Bitmap, allocator: Allocator, range_start: u64, range_end: u64) !Bitmap {
    if (range_start >= range_end or range_start > std.math.maxInt(u32) + 1) {
        return x1.copy(allocator);
    }
    return x1.flip_closed(allocator, @truncate(range_start), @truncate(range_end - 1));
}

fn append_copy(
    ra: *Bitmap,
    allocator: mem.Allocator,
    sa: Bitmap,
    index: u16,
    copy_on_write: bool,
) !void {
    try ra.ensure_unused_capacity(allocator, 1);
    const pos = ra.array.len;
    // old contents is junk that does not need freeing
    ra.array.keys[pos] = sa.array.keys[index];
    // the shared container will be in both bitmaps
    if (copy_on_write) {
        const cpy = try sa.array.containers[index].get_copy_of_container(allocator, copy_on_write);
        sa.array.containers[index] = cpy;
        assert(!cpy.is_uninit());
        assert(cpy.data.cardinality != 0);
        ra.array.containers[pos] = cpy;
    } else {
        const cpy = try sa.array.containers[index].clone(allocator);
        assert(!cpy.is_uninit());
        assert(cpy.data.cardinality != 0);
        ra.array.containers[pos] = cpy;
    }
    ra.array.len += 1;
}

fn append_copies_until(
    ra: *Bitmap,
    allocator: mem.Allocator,
    sa: Bitmap,
    stopping_key: u16,
    copy_on_write: bool,
) !void {
    for (0..sa.array.len, sa.array.keys) |i, k| {
        if (k >= stopping_key) break;
        try ra.append_copy(allocator, sa, @intCast(i), copy_on_write);
    }
}

fn append_copies_after(ra: *Bitmap, allocator: mem.Allocator, sa: Bitmap, before_start: u16, copy_on_write: bool) !void {
    var start_location = get_key_index(sa, before_start);
    if (start_location >= 0)
        start_location += 1
    else
        start_location = -start_location - 1;
    try ra.append_copy_range(
        allocator,
        sa,
        @intCast(start_location),
        sa.array.len,
        copy_on_write,
    );
}

/// Compute the negation of the bitmap in the interval [range_start, range_end].
/// The number of negated values is range_end - range_start + 1.
/// Areas outside the range are passed through unchanged.
pub fn flip_closed(x1: Bitmap, allocator: Allocator, range_start: u32, range_end: u32) !Bitmap {
    trace(@src(), "{f} {} {}", .{ x1.fmtLong(), range_start, range_end });
    if (range_start > range_end)
        return x1.copy(allocator);

    var hb_start: u16 = @truncate(range_start >> 16);
    const lb_start: u16 = @truncate(range_start);
    var hb_end: u16 = @truncate(range_end >> 16);
    const lb_end: u16 = @truncate(range_end);

    const max_containers = x1.array.len + (hb_end - hb_start + 1);
    var ans = try create_with_capacity(allocator, max_containers);
    defer ans.assert_valid();
    errdefer ans.deinit(allocator);
    ans.set_copy_on_write(x1.is_cow());

    try ans.append_copies_until(allocator, x1, hb_start, x1.is_cow());

    if (hb_start == hb_end) {
        try ans.insert_flipped_container(allocator, x1, hb_start, lb_start, lb_end);
    } else { // start and end containers are distinct
        if (lb_start > 0) { // handle first (partial) container
            try ans.insert_flipped_container(allocator, x1, hb_start, lb_start, 0xFFFF);
            hb_start += 1;
        }

        if (lb_end != 0xFFFF) hb_end -= 1; // later we'll handle the partial block

        var hb: u32 = hb_start;
        while (hb <= hb_end) : (hb += 1) {
            try ans.insert_fully_flipped_container(allocator, x1, @truncate(hb));
        }

        if (lb_end != 0xFFFF) { // handle a partial final container
            try ans.insert_flipped_container(allocator, x1, hb_end + 1, 0, lb_end);
            hb_end += 1;
        }
    }

    try ans.append_copies_after(allocator, x1, hb_end, x1.is_cow());

    return ans;
}

/// flip the range [lb_start, lb_end] within key hb.
///
/// compute (in place) the negation of the roaring bitmap within a specified
/// interval: [range_start, range_end). The number of negated values is
/// range_end - range_start.
/// Areas outside the range are passed through unchanged.
fn insert_flipped_container(
    ans: *Bitmap,
    allocator: Allocator,
    x1: Bitmap,
    hb: u16,
    lb_start: u16,
    lb_end: u16,
) !void {
    const i = x1.get_key_index(hb);
    const j = ans.get_key_index(hb);
    if (i >= 0) {
        const container_to_flip = x1.array.containers[@intCast(i)];
        var flipped_container = try container_to_flip.not_range(allocator, lb_start, @as(u32, lb_end) + 1);
        if (flipped_container.nonzero_cardinality()) {
            try ans.insert_new_key_value_at(allocator, @intCast(-j - 1), hb, flipped_container);
        } else if (flipped_container.data.cardinality != 0) {
            flipped_container.deinit(allocator);
        }
    } else {
        const result = try Container.range_of_ones(allocator, lb_start, @as(u32, lb_end) + 1);
        try ans.insert_new_key_value_at(allocator, @intCast(-j - 1), hb, result);
    }
}

/// flip the full key hb (range [0, 0xFFFF]).
fn insert_fully_flipped_container(
    ans: *Bitmap,
    allocator: Allocator,
    x1: Bitmap,
    hb: u16,
) !void {
    const i = x1.get_key_index(hb);
    const j = ans.get_key_index(hb);

    if (i >= 0) {
        var flipped_container =
            try x1.array.containers[@intCast(i)].not(allocator);
        if (flipped_container.nonzero_cardinality()) {
            try ans.insert_new_key_value_at(allocator, @intCast(-j - 1), hb, flipped_container);
        } else {
            flipped_container.deinit(allocator);
        }
    } else {
        const result = try Container.range_of_ones(allocator, 0, C.MAX_KEY_CARDINALITY);
        try ans.insert_new_key_value_at(allocator, @intCast(-j - 1), hb, result);
    }
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
        var rb = try portable_deserialize_file(testing.allocator, testio, f, &rbuf);
        defer rb.deinit(testing.allocator);
        try testing.expectEqual(.SERIAL_COOKIE_NO_RUNCONTAINER, rb.array.magic);
        try validateTestdataFile(rb);
    }
    { // "with runs"
        const filepath = "testdata/bitmapwithruns.bin";
        const f = try Io.Dir.cwd().openFile(testio, filepath, .{});
        defer f.close(testio);
        var rbuf: [256]u8 = undefined;
        var rb = try portable_deserialize_file(testing.allocator, testio, f, &rbuf);
        defer rb.deinit(testing.allocator);
        try testing.expectEqual(.SERIAL_COOKIE, rb.array.magic);
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
const Iterator = @import("Iterator.zig");
