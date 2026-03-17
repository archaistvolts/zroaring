const Array = @This();

containers: std.MultiArrayList(ContainerKV),
flags: std.EnumSet(Flag),

pub const ContainerKV = struct { container: Container, key: u16 };
pub const Flag = enum { cow, frozen };

/// u13 by default
pub const Cardinality = std.math.IntFittingRange(0, C.DEFAULT_MAX_SIZE);
/// u16 by default
pub const Element = u32; // TODO use Element instead of u32 throughout
pub const Element2 = @Type(.{ // u32
    .int = .{
        .bits = std.math.ceilPowerOfTwo(usize, @bitSizeOf(Cardinality) * 2) catch
            unreachable, // max_cardinality too big
        .signedness = .unsigned,
    },
});
pub const Block = [BLOCK_LEN]Element;
pub const BLOCK_LEN = std.simd.suggestVectorLength(Element).?;
pub const BLOCK_ALIGN = @alignOf(Block);
pub const init: Array = .{ .containers = .{}, .flags = .initEmpty() };
const Elements = std.ArrayListAligned(Element, .fromByteUnits(BLOCK_ALIGN));
/// Containers with DEFAULT_MAX_SIZE or less integers should be arrays
pub fn init_with_capacity(allocator: mem.Allocator, cap: u32) !Array {
    var new_ra: Array = .init;
    // Containers hold 64Ki elements, so 64Ki containers is enough to hold
    // `0x10000 * 0x10000` (all 2^32) elements
    try new_ra.containers.ensureTotalCapacity(allocator, @min(C.MAX_CONTAINERS, cap));
    // std.debug.print("init_with_capacity({}) new_ra.containers.capacity {}\n", .{ cap, new_ra.containers.capacity });
    return new_ra;
}

fn clear_containers(ra: *Array, allocator: mem.Allocator) void {
    for (0..ra.containers.len) |i| {
        const c = ra.containers.items(.container)[i];
        // std.debug.print("c {f}\n", .{c});
        c.deinit(allocator);
    }
}

fn clear_without_containers(ra: *Array, allocator: mem.Allocator) void {
    ra.containers.deinit(allocator);
    ra.containers.len = 0;
}

pub fn clear(ra: *Array, allocator: mem.Allocator) void {
    ra.clear_containers(allocator);
    ra.clear_without_containers(allocator);
}

pub fn deinit(ra: *Array, allocator: mem.Allocator) void {
    // std.debug.print("ra deinit() ra {any}\n", .{ra});
    for (ra.containers.items(.container)) |c| {
        c.deinit(allocator);
    }
    ra.containers.deinit(allocator);
}

///
/// If the container at the index i is share, unshare it (creating a local
/// copy if needed).
///
pub fn unshare_container_at_index(ra: *Array, i: u16) void {
    assert(i < ra.containers.len);
    ra.containers.items(.container)[i] = ra.containers.items(.container)[i].get_writable_copy_if_shared();
}
pub fn extend_array(ra: *Array, allocator: mem.Allocator, k: i32) !void {
    // try ra.containers.ensureTotalCapacity(allocator, k);

    const desired_size = misc.cast(i32, ra.containers.len) + k;
    assert(desired_size <= C.MAX_CONTAINERS);
    if (desired_size > ra.containers.capacity) {
        const new_capacity = @min(C.MAX_CONTAINERS, if (ra.containers.len < 1024)
            2 * desired_size
        else
            @divFloor(5 * desired_size, 4));
        try ra.containers.ensureTotalCapacity(allocator, @intCast(new_capacity));
    }
}

pub fn insert_new_key_value_at(ra: *Array, allocator: mem.Allocator, i: u32, key: u16, c: Container) !void {
    try ra.extend_array(allocator, 1);
    ra.containers.len += 1;
    const containers = ra.containers.slice();
    // May be an optimization opportunity with DIY memmove
    @memmove(containers.items(.key).ptr[i + 1 ..], containers.items(.key)[i..]);
    containers.items(.key)[i] = key;
    @memmove(containers.items(.container).ptr[i + 1 ..], containers.items(.container)[i..]);
    containers.items(.container)[i] = c;
}

pub fn get_container_at_index(ra: Array, i: u16) Container {
    return ra.containers.items(.container)[i];
}

pub fn get_cardinality(ra: Array) u64 {
    var ret: u64 = 0;
    for (ra.containers.items(.container)) |c| ret += c.get_cardinality();
    return ret;
}

pub fn set_container_at_index(ra: *Array, i: u32, c: Container) void {
    assert(i < ra.containers.len);
    ra.containers.items(.container)[i] = c;
}

/// This function is endian-sensitive.
pub fn portable_serialize(ra: Array, w: *std.Io.Writer) !usize {
    const cslen: u32 = @intCast(ra.containers.len);
    if (cslen == 0) {
        try w.writeStruct(root.Cookie{
            .magic = .SERIAL_COOKIE_NO_RUNCONTAINER,
            .cardinality_minus1 = 0,
        }, .little);
        try w.writeInt(u32, 0, .little);
        return @sizeOf(u32) * 2;
    }
    const slice = ra.containers.slice();
    var startOffset: u32 = 0;
    var written_count: usize = 0;
    const hasrun = ra.has_run_container();
    if (hasrun) {
        try w.writeStruct(root.Cookie{
            .magic = .SERIAL_COOKIE,
            .cardinality_minus1 = @intCast(cslen - 1),
        }, .little);
        written_count += @sizeOf(root.Cookie);
        const s = (cslen + 7) / 8;
        written_count += try w.writeSplat(&.{"\x00"}, s);
        if (true) unreachable; // TODO
        for (slice.items(.container)) |c| {
            if (c.get_container_type() == .run) {
                // buf[i / 8] |= 1 << (i % 8);
                unreachable; // TODO
            }
        }
        startOffset = if (cslen < C.NO_OFFSET_THRESHOLD)
            4 + 4 * cslen + s
        else
            4 + 8 * cslen + s;
    } else { // backwards compatibility
        try w.writeStruct(root.Cookie{
            .magic = .SERIAL_COOKIE_NO_RUNCONTAINER,
            .cardinality_minus1 = @intCast(cslen - 1),
        }, .little);
        try w.writeInt(u32, cslen, .little);
        written_count += @sizeOf(root.Cookie) + @sizeOf(u32);
        startOffset = 4 + 4 + 4 * cslen + 4 * cslen;
    }
    for (slice.items(.container), slice.items(.key)) |c, k| {
        try w.writeInt(@TypeOf(k), k, .little);
        // get_cardinality returns a value in [1,1<<16], subtracting one
        // we get [0,1<<16 - 1] which fits in 16 bits
        try w.writeInt(u16, @intCast(c.get_cardinality() - 1), .little);
        written_count += @sizeOf(@TypeOf(k)) + @sizeOf(u16);
    }
    if ((!hasrun) or (cslen >= C.NO_OFFSET_THRESHOLD)) {
        // write the containers offsets
        for (slice.items(.container)) |c| {
            try w.writeInt(u32, startOffset, .little);
            written_count += @sizeOf(u32);
            startOffset += @intCast(c.size_in_bytes());
        }
    }
    for (slice.items(.container)) |c| {
        written_count += try c.write(w);
    }

    return written_count;
}

/// This function populates answer from the content of buf (reading up to
/// maxbytes bytes). The function returns false if a properly serialized bitmap
/// cannot be found. If it returns true, readbytes is populated by how many bytes
/// were read, we have that *readbytes <= maxbytes.
///
/// This function is endian-sensitive.
pub fn portable_deserialize(
    allocator: mem.Allocator,
    r: *Io.Reader,
    tmp_allocator: mem.Allocator,
) !Array {
    const cookie = try r.takeStruct(root.Cookie, .little);
    if (cookie.magic != .SERIAL_COOKIE and cookie.magic != .SERIAL_COOKIE_NO_RUNCONTAINER)
        return error.UnexpectedCookie;

    const size: u32 = if (cookie.magic == .SERIAL_COOKIE)
        cookie.cardinality_minus1 + 1
    else
        try r.takeInt(u32, .little);
    if (size > C.MAX_CONTAINERS)
        return error.TooManyContainers; // data must be corrupted

    var bitmapOfRunContainers: ?[]u8 = null;
    const hasrun = cookie.magic == .SERIAL_COOKIE;
    if (hasrun) {
        const s = (size + 7) / 8;
        bitmapOfRunContainers = try r.readAlloc(tmp_allocator, s);
    }
    const keyscards = try r.readSliceEndianAlloc(tmp_allocator, u16, size * 2, .little);
    var answer = try init_with_capacity(allocator, size);
    errdefer answer.deinit(allocator);
    // std.debug.print("keyscards {any}\n", .{keyscards});
    answer.containers.len = size;
    for (0..size) |k| {
        const key = keyscards[k * 2];
        answer.containers.items(.key)[k] = key;
    }
    // std.debug.print("answer {f}\n", .{answer});

    if ((!hasrun) or (size >= C.NO_OFFSET_THRESHOLD)) {
        _ = try r.discard(.limited(size * 4)); // skip the offsets
    }
    for (0..size) |k| { // read containers

        const tmp = keyscards[k * 2 + 1];
        const thiscard = @as(u32, tmp) + 1;
        var isbitmap = (thiscard > C.DEFAULT_MAX_SIZE);
        var isrun = false;
        if (hasrun) {
            if (((bitmapOfRunContainers.?[k / 8] & @as(u8, 1) << @truncate(k % 8))) != 0) {
                isbitmap = false;
                isrun = true;
            }
        }
        // std.debug.print("k {} tmp {} thiscard {} isbitmap {} isrun {}\n", .{ k, tmp, thiscard, isbitmap, isrun });
        if (isbitmap) {
            const c = try allocator.create(BitsetContainer);
            errdefer allocator.destroy(c);
            c.* = try BitsetContainer.create(allocator);
            errdefer c.deinit(allocator);
            try c.read(r, thiscard);
            answer.containers.items(.container)[k] = .init(c);
        } else if (isrun) {
            const n_runs = try r.takeInt(u16, .little);
            const containersize = n_runs * @sizeOf(root.Rle16);
            _ = containersize; // autofix
            // std.debug.print("n_runs {} containersize {} thiscard {}\n", .{ n_runs, containersize, thiscard });
            const c = try allocator.create(RunContainer);
            errdefer allocator.destroy(c);
            c.* = try RunContainer.create_with_capacity(allocator, n_runs);
            errdefer c.deinit(allocator);
            _ = try c.read(allocator, n_runs, r);
            answer.containers.items(.container)[k] = .init(c);
        } else {
            const c = try allocator.create(ArrayContainer);
            c.* = try ArrayContainer.init_capacity(allocator, thiscard);
            _ = try c.read(allocator, thiscard, r);
            // std.debug.print("ArrayContainer after read() {f}\n", .{c});
            assert(c.cardinality == thiscard);
            answer.containers.items(.container)[k] = .init(c);
        }
    }
    return answer;
}

pub fn orderFn16(a: u16, b: u16) std.math.Order {
    return std.math.order(a, b);
}

pub const GetIndex = struct { bool, u16 };
pub fn get_index(ra: Array, key: u16) GetIndex {
    return ArrayContainer.get_index(ra.containers.items(.key), key);
}

pub fn has_run_container(ra: Array) bool {
    return for (ra.containers.items(.container)) |c| {
        if (c.get_container_type() == .run)
            break true;
    } else false;
}
pub fn portable_header_size(ra: Array) usize {
    if (ra.has_run_container()) {
        if (ra.containers.len < C.NO_OFFSET_THRESHOLD) { // for small bitmaps, we omit the offsets
            return 4 + (ra.containers.len + 7) / 8 + 4 * ra.containers.len;
        }
        return 4 + (ra.containers.len + 7) / 8 +
            8 * ra.containers.len; // - 4 because we pack the size with the cookie
    } else {
        return 4 + 4 + 8 * ra.containers.len;
    }
}

pub fn portable_size_in_bytes(ra: Array) usize {
    var count = ra.portable_header_size();
    for (ra.containers.items(.container)) |c| {
        count += c.size_in_bytes();
    }
    return count;
}

pub fn replace_key_and_container_at_index(
    ra: *Array,
    i: u32,
    key: u16,
    c: Container,
) void {
    assert(i < ra.containers.len);
    const slice = ra.containers.slice();
    slice.items(.key)[i] = key;
    slice.items(.container)[i] = c;
}

///
/// Shifts rightmost $count containers to the left (distance < 0) or
/// to the right (distance > 0).
/// Allocates memory if necessary.
/// This function doesn't free or create new containers.
/// Caller is responsible for that.
///
pub fn shift_tail(ra: *Array, allocator: mem.Allocator, count: u32, distance: i32) !void {
    if (distance > 0) try ra.extend_array(allocator, distance);

    const srcpos = misc.cast(i32, ra.containers.len - count);
    const dstpos = srcpos + distance;
    ra.containers.len += @intCast(distance);
    const s = ra.containers.slice();
    @memmove(
        s.items(.key)[@intCast(dstpos)..][0..count],
        s.items(.key)[@intCast(srcpos)..][0..count],
    );
    @memmove(
        s.items(.container)[@intCast(dstpos)..][0..count],
        s.items(.container)[@intCast(srcpos)..][0..count],
    );
}

pub fn format(ra: Array, w: *Io.Writer) !void {
    try w.print("Array containers {}\n", .{ra.containers.len});
    for (ra.containers.items(.container)) |c| {
        try c.format(w);
        try w.writeByte('\n');
    }
}

test "c.roaring Array" {
    const c = @cImport({
        @cInclude("c/roaring.h");
    });
    const r1 = c.roaring_bitmap_create();
    defer c.roaring_bitmap_free(r1);
    for (100..1000) |i| c.roaring_bitmap_add(r1, @intCast(i));
    try testing.expectEqual(900, c.roaring_bitmap_get_cardinality(r1));
    const b = c.bitset_create();
    defer c.bitset_free(b);
    for (0..1000) |i| c.bitset_set(b, 3 * i);
    try testing.expectEqual(1000, c.bitset_count(b));
    try testing.expectEqual(Element, Element2);
}

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Io = std.Io;
const assert = std.debug.assert;
const root = @import("root.zig");
const Typecode = root.Typecode;
const Container = root.Container;
const BitsetContainer = root.BitsetContainer;
const ArrayContainer = root.ArrayContainer;
const RunContainer = root.RunContainer;
const C = @import("constants.zig");
const misc = @import("misc.zig");
