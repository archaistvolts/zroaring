const ArrayContainer = @This();
sorted_values: [*]align(ALIGNMENT) u16,
cardinality: u32,
capacity: u32,

pub const BLOCK_LEN_16 = std.simd.suggestVectorLength(u16).?;
pub const Block_u16 = @Vector(BLOCK_LEN_16, u16);
pub const ALIGNMENT = @alignOf(Block_u16);
pub const Builder = std.ArrayListAligned(u16, .fromByteUnits(ALIGNMENT));
pub const init: ArrayContainer = .{ .capacity = 0, .cardinality = 0, .sorted_values = undefined };

pub fn init_capacity(allocator: mem.Allocator, cap: u32) !ArrayContainer {
    const values = try allocator.alignedAlloc(u16, .fromByteUnits(ALIGNMENT), cap);
    @memset(values, 0);
    return .{
        .sorted_values = values.ptr,
        .cardinality = 0,
        .capacity = cap,
    };
}

pub fn create(allocator: mem.Allocator) !*ArrayContainer {
    return try create_with_capacity(allocator, 0);
}
pub fn create_with_capacity(allocator: mem.Allocator, cap: u32) !*ArrayContainer {
    // return create_with_capacity(allocator, ARRAY_DEFAULT_INIT_SIZE);
    const ret = try allocator.create(ArrayContainer);
    errdefer allocator.destroy(ret);
    const sorted_values = try allocator.alignedAlloc(u16, .fromByteUnits(ALIGNMENT), cap);
    ret.* = .{ .sorted_values = sorted_values.ptr, .capacity = cap, .cardinality = 0 };
    return ret;
}

// pub fn init_buffer(buf: []u16) ArrayContainer {
//     return .{
//         .sorted_values = buf[0..0],
//         .capacity = @intCast(buf.len),
//         .cardinality = 0,
//     };
// }

pub fn deinit(c: ArrayContainer, allocator: mem.Allocator) void {
    // std.debug.print("deinit sorted values capacity {}\n", .{c.capacity});
    if (c.capacity == 0) return;
    allocator.free(c.sorted_values[0..c.capacity]);
}
pub fn slice(c: ArrayContainer) []align(ALIGNMENT) u16 {
    return c.sorted_values[0..c.cardinality];
}
pub fn size_in_bytes(c: ArrayContainer) usize {
    return c.cardinality * @sizeOf(u16);
}
/// Writes the underlying array to buf, outputs how many bytes were written.
/// The number of bytes written should be
/// array_container_size_in_bytes(container).
pub fn write(c: ArrayContainer, w: *Io.Writer) !usize {
    try w.writeSliceEndian(u16, c.sorted_values[0..c.cardinality], .little);
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
pub fn get_index(values: []const u16, x: u16) Array.GetIndex {
    const idx = Array.binarySearch(values, x);
    const found = idx >= 0;
    return .{ found, @intCast(if (found) idx else -idx - 1) };
}

pub const AddResult = union(enum) { added, already_present, not_added };

/// Add value to the set if final cardinality doesn't exceed max_cardinality.
/// Returns an enum indicating if value was added, already present, or not
/// added because cardinality would exceed max_cardinality
pub fn try_add(
    c: *ArrayContainer,
    allocator: mem.Allocator,
    value: u16,
    /// max cardinality
    max_card: u32,
) !AddResult {
    const card = c.cardinality;
    // best case, we can append.
    if ((card == 0 or c.sorted_values[card - 1] < value) and card < max_card) {
        try c.add(allocator, value);
        return .added;
    }

    const found, const loc = ArrayContainer.get_index(c.sorted_values[0 .. card - 1], value);
    return if (found)
        .already_present
    else if (c.cardinality < max_card) blk: {
        if (c.full()) try c.grow(allocator, c.capacity + 1, true);
        const insert_idx = loc - 1;
        // @memmove(array + insert_idx + 1, array + insert_idx, (cardinality - insert_idx) * @sizeOf(u16));
        @memmove(
            c.sorted_values + insert_idx + 1,
            (c.sorted_values + insert_idx)[0 .. c.cardinality - insert_idx],
        );
        c.sorted_values[insert_idx] = value;
        c.cardinality += 1;
        break :blk .added;
    } else .not_added;
}

pub fn full(c: ArrayContainer) bool {
    return c.cardinality == c.capacity;
}

pub fn grow(c: *ArrayContainer, allocator: mem.Allocator, capacity: u32, x: bool) !void {
    _ = c;
    _ = allocator;
    _ = capacity;
    _ = x;
    unreachable;
}

pub fn builder(c: ArrayContainer) Builder {
    return .{
        .items = c.slice(),
        .capacity = c.capacity,
    };
}

pub fn fromBuilder(b: Builder) ArrayContainer {
    return .{
        .sorted_values = b.items.ptr,
        .capacity = @intCast(b.capacity),
        .cardinality = @intCast(b.items.len),
    };
}

pub fn add(c: *ArrayContainer, allocator: mem.Allocator, pos: u16) !void {
    var b = c.builder();
    try b.append(allocator, pos);
    c.* = fromBuilder(b);
}

pub fn equals(c1: ArrayContainer, c2: *const ArrayContainer) bool {
    return c1.cardinality == c2.cardinality and mem.eql(u16, c1.slice(), c2.slice());
}

pub fn bitset_container_from_array(ac: ArrayContainer, allocator: mem.Allocator) !BitsetContainer {
    // const ans = try allocator.create(BitsetContainer);
    // errdefer allocator.destroy(ans);
    var ans: BitsetContainer = try .create(allocator);
    for (ac.slice()) |x| _ = ans.put(x);
    return ans;
}

pub fn format(c: ArrayContainer, w: *Io.Writer) !void {
    try w.print("ArrayContainer {any}\n", .{c});
    try w.print("  values {any}", .{c.slice()[0..@min(20, c.cardinality)]});
}

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const root = @import("root.zig");
const Array = root.Array;
const BitsetContainer = root.BitsetContainer;
