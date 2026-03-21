const ArrayContainer = @This();
array: [*]align(ALIGNMENT) u16,
cardinality: u32,
capacity: u32,

pub const BLOCK_LEN_16 = std.simd.suggestVectorLength(u16).?;
pub const Block_u16 = @Vector(BLOCK_LEN_16, u16);
pub const ALIGNMENT = @alignOf(Block_u16);
pub const init: ArrayContainer = .{ .capacity = 0, .cardinality = 0, .array = undefined };

pub fn init_with_capacity(allocator: mem.Allocator, cap: u32) !ArrayContainer {
    const sorted_values = try allocator.alignedAlloc(u16, .fromByteUnits(ALIGNMENT), cap);
    return .{ .array = sorted_values.ptr, .capacity = cap, .cardinality = 0 };
}
/// Create a new array containing all values in [min,max).
pub fn init_range(allocator: mem.Allocator, min: u32, max: u32) !ArrayContainer {
    var answer = try init_with_capacity(allocator, max - min + 1);
    answer.cardinality = 0;
    for (min..max) |k| {
        answer.array[answer.cardinality] = @intCast(k);
        answer.cardinality += 1;
    }
    return answer;
}

// TODO bounded api

pub fn deinit(c: ArrayContainer, allocator: mem.Allocator) void {
    // std.debug.print("deinit sorted values capacity {}\n", .{c.capacity});
    if (c.capacity == 0) return;
    allocator.free(c.array[0..c.capacity]);
}

pub fn slice(c: ArrayContainer) []align(ALIGNMENT) u16 {
    return c.array[0..c.cardinality];
}
pub fn size_in_bytes(c: ArrayContainer) usize {
    return c.cardinality * @sizeOf(u16);
}
/// Writes the underlying array to buf, outputs how many bytes were written.
/// The number of bytes written should be
/// array_container_size_in_bytes(container).
pub fn write(c: ArrayContainer, w: *Io.Writer) !usize {
    try w.writeSliceEndian(u16, c.array[0..c.cardinality], .little);
    return c.size_in_bytes();
}

///
/// Reads the instance from buf, outputs how many bytes were read.
/// This is meant to be byte-by-byte compatible with the Java and Go versions of
/// Roaring.
/// The number of bytes read should be array_container_size_in_bytes(container).
/// You need to provide the (known) cardinality.
///
pub fn read(container: *ArrayContainer, allocator: mem.Allocator, cardinality: u32, r: *Io.Reader) !usize {
    if (container.capacity < cardinality) {
        try container.grow(allocator, cardinality, false);
    }
    container.cardinality = cardinality;
    try r.readSliceEndian(u16, container.slice(), .little);
    return container.size_in_bytes();
}

/// Returns (found, index), if not found, index is where to insert x
pub fn get_index(values: []const u16, x: u16) i32 {
    return misc.binarySearch(values, x);
}

/// Add value to the set if final cardinality doesn't exceed max_cardinality.
/// Returns an enum indicating if value was added, already present, or not
/// added because cardinality would exceed max_cardinality
pub fn try_add(
    c: *ArrayContainer,
    allocator: mem.Allocator,
    value: u16,
    /// max cardinality
    max_card: u32,
) !types.AddResult {
    assert(c.cardinality <= C.DEFAULT_MAX_SIZE);
    defer assert(c.cardinality <= C.DEFAULT_MAX_SIZE);
    const card = c.cardinality;
    // best case, we can append.
    if ((card == 0 or value > c.array[card - 1]) and card < max_card) {
        // std.debug.print("value {}\n", .{value});
        try c.append(allocator, value);
        return .added;
    }

    const loc = misc.binarySearch(c.array[0 .. card - 1], value);
    return if (loc >= 0)
        .already_present
    else if (c.cardinality < max_card) blk: {
        if (c.full()) try c.grow(allocator, c.capacity + 1, true);
        const insert_idx: u32 = @intCast(-loc - 1);
        @memmove(
            c.array + insert_idx + 1,
            (c.array + insert_idx)[0 .. c.cardinality - insert_idx],
        );
        c.array[insert_idx] = value;
        c.cardinality += 1;
        break :blk .added;
    } else .not_added;
}

pub fn full(c: ArrayContainer) bool {
    return c.cardinality == c.capacity;
}

pub fn grow_capacity(capacity: u32) u32 {
    return if (capacity < 64)
        capacity * 2
    else if (capacity < 1024)
        capacity * 3 / 2
    else
        capacity * 5 / 4;
}

pub fn grow(c: *ArrayContainer, allocator: mem.Allocator, min: u32, preserve: bool) !void {
    const max: u32 = @min(C.DEFAULT_MAX_SIZE, C.MAX_CONTAINERS);
    const new_capacity = std.math.clamp(grow_capacity(c.capacity), min, max);
    const array = c.array[0..c.capacity];
    c.capacity = new_capacity;

    if (preserve) {
        c.array = (try allocator.realloc(array, @max(c.capacity, new_capacity))).ptr;
    } else {
        allocator.free(array);
        c.array = (try allocator.alignedAlloc(u16, .fromByteUnits(ALIGNMENT), new_capacity)).ptr;
    }
}

/// pos must be greater than all sorted_values
pub fn append_assume_capacity(c: *ArrayContainer, pos: u16) void {
    assert(c.cardinality == 0 or pos > c.array[c.cardinality - 1]);
    c.array[c.cardinality] = pos;
    c.cardinality += 1;
}

///
/// Adds all values in range [min,max] using hint:
///   nvals_less is the number of array values less than $min
///   nvals_greater is the number of array values greater than $max
///
pub fn add_range_nvals(
    array: *ArrayContainer,
    allocator: mem.Allocator,
    min: u32,
    max: u32,
    nvals_less: u32,
    nvals_greater: u32,
) !void {
    const union_cardinality = nvals_less + (max - min + 1) + nvals_greater;
    if (union_cardinality > array.capacity) {
        try array.grow(allocator, union_cardinality, true);
    }
    @memmove(
        array.array[union_cardinality - nvals_greater ..][0..nvals_greater],
        array.array[array.cardinality - nvals_greater ..][0..nvals_greater],
    );
    for (0..max - min) |i| {
        array.array[nvals_less + i] = @truncate(min + i);
    }
    array.cardinality = union_cardinality;
}

/// Append x to the set. Assumes that the value is larger than any preceding
/// values.
pub fn append(arr: *ArrayContainer, allocator: mem.Allocator, pos: u16) !void {
    const capacity = arr.capacity;

    if (arr.full()) {
        try arr.grow(allocator, capacity + 1, true);
    }

    arr.array[arr.cardinality] = pos;
    arr.cardinality += 1;
}

pub fn add_from_range(arr: *ArrayContainer, allocator: mem.Allocator, min: u32, max: u32, step: u16) !void {
    var value = min;
    while (value < max) : (value += step) {
        // FIXME remove @intCast. types wrong?
        try arr.append(allocator, @intCast(value));
    }
}

pub fn equals(c1: ArrayContainer, c2: *const ArrayContainer) bool {
    return c1.cardinality == c2.cardinality and mem.eql(u16, c1.slice(), c2.slice());
}

/// binary search with fallback to linear search for short ranges
pub fn contains(c: ArrayContainer, pos: u16) bool {
    // std.debug.print("ArrayContainer.contains({}) cardinality {} slice {any}\n", .{ pos, c.cardinality, c.slice() });
    var low: i32 = 0;
    const carr = c.slice();
    var high = @as(i32, @intCast(c.cardinality)) - 1;
    while (high >= low + 16) {
        const middleIndex = (low + high) >> 1;
        const middleValue = carr[@intCast(middleIndex)];
        // std.debug.print("low {} high {} middleIndex {} middlevalue {}\n", .{ low, high, middleIndex, middleValue });
        if (middleValue < pos) {
            low = middleIndex + 1;
        } else if (middleValue > pos) {
            high = middleIndex - 1;
        } else {
            return true;
        }
    }

    var i = low;
    while (i <= high) : (i += 1) {
        const v = carr[@intCast(i)];
        if (v == pos) return true;
        if (v > pos) return false;
    }
    return false;
}

pub fn bitset_container_from_array(ac: ArrayContainer, allocator: mem.Allocator) !BitsetContainer {
    var ans: BitsetContainer = try .create(allocator);
    for (ac.slice()) |x| _ = ans.set(x);
    return ans;
}

pub fn to_bitset_container(ac: *ArrayContainer, allocator: mem.Allocator) !BitsetContainer {
    var ans = try BitsetContainer.create(allocator);
    for (0..ac.cardinality) |i| _ = ans.set(ac.array[i]);
    return ans;
}
/// Compute the number of runs
pub fn number_of_runs(ac: *const ArrayContainer) u32 {
    // Can SIMD work here?
    var nr_runs: u32 = 0;
    var prev: i32 = -2;
    var p: [*]u16 = ac.array;
    while (p != ac.array + ac.cardinality) : (p += 1) {
        if (p[0] != prev + 1) nr_runs += 1;
        prev = p[0];
    }
    return nr_runs;
}
///
/// Return the serialized size in bytes of a container having cardinality "card".
///
pub fn serialized_size_in_bytes(card: u32) u32 {
    return card * @sizeOf(u16);
}

pub const format = format2;
pub fn format1(c: ArrayContainer, w: *Io.Writer) !void {
    try w.print("cardinality/capacity {}/{}", .{ c.cardinality, c.capacity });
}
pub fn format2(c: ArrayContainer, w: *Io.Writer) !void {
    try w.print("cardinality/capacity {}/{} values {any}", .{ c.cardinality, c.capacity, c.slice()[0..@min(10, c.cardinality)] });
}

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const assert = std.debug.assert;
const root = @import("root.zig");
const Array = root.Array;
const BitsetContainer = root.BitsetContainer;
const misc = @import("misc.zig");
const C = @import("constants.zig");
const types = @import("types.zig");
