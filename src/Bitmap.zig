pub const Bitmap = @This();

high_low_container: Array = .init,

///
/// Dynamically allocates a new bitmap (initially empty).
/// Returns NULL if the allocation fails.
/// Capacity is a performance hint for how many "containers" the data will need.
/// Client is responsible for calling `free()`.
///
pub fn create_with_capacity(cap: u32) *Bitmap {
    _ = cap;
    unreachable; // TODO
}

///
/// Dynamically allocates a new bitmap (initially empty).
/// Returns NULL if the allocation fails.
/// Client is responsible for calling `free()`.
///
pub fn create() Bitmap {
    return create_with_capacity(0);
}

///
/// Initialize a roaring bitmap structure in memory controlled by client.
/// Capacity is a performance hint for how many "containers" the data will need.
/// Can return false if auxiliary allocations fail when capacity greater than 0.
///
fn init_with_capacity(r: *Bitmap, cap: u32) bool {
    _ = r;
    _ = cap;
    unreachable;
}

///
/// Initialize a roaring bitmap structure in memory controlled by client.
/// The bitmap will be in a "clear" state, with no auxiliary allocations.
/// Since this performs no allocations, the function will not fail.
///
pub fn init_cleared(r: *Bitmap) void {
    init_with_capacity(r, 0);
}

///
/// Add all the values between min (included) and max (excluded) that are at a
/// distance k*step from min.
/// The returned pointer may be NULL in case of errors.
///
pub fn from_range(min: u64, max: u64, step: u32) *Bitmap {
    _ = min;
    _ = max;
    _ = step;
    unreachable;
}

///
/// Creates a new bitmap from a pointer of u32 integers
/// The returned pointer may be NULL in case of errors.
///
pub fn of_ptr(vals: []const u32) *Bitmap {
    _ = vals;
    unreachable;
}

///
/// Check if the bitmap contains any shared containers.
///
pub fn contains_shared(r: Bitmap) *Bitmap {
    _ = r;
    unreachable; // TODO
}

///
/// Unshare all shared containers.
/// Returns true if any unsharing was performed, false if there were no shared
/// containers.
///
pub fn unshare_all(r: *Bitmap) void {
    _ = r;
    unreachable; // TODO
}

pub const FLAG_COW: u8 = 0x1;
pub const FLAG_FROZEN: u8 = 0x2;

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
///
pub fn get_copy_on_write(r: *const Bitmap) bool {
    return r.high_low_container.flags.contains(.cow);
}
pub fn set_copy_on_write(r: *Bitmap, cow: bool) void {
    if (cow) {
        r.high_low_container.flags.insert(.cow);
    } else {
        if (r.get_copy_on_write()) {
            r.unshare_all();
        }
        r.high_low_container.flags.remove(.cow);
    }
}

///
/// Return a copy of the bitmap with all values shifted by offset.
/// The returned pointer may be NULL in case of errors. The caller is responsible
/// for freeing the return bitmap.
///
pub fn add_offset(bm: Bitmap, offset: i64) *Bitmap {
    _ = bm;
    _ = offset;
    unreachable; // TODO
}

///
/// Copies a bitmap (this does memory allocation).
/// The caller is responsible for memory management.
/// The returned pointer may be NULL in case of errors.
///
pub fn copy(r: Bitmap) *Bitmap {
    _ = r;
    unreachable; // TODO
}

///
/// Computes the intersection between two bitmaps and returns new bitmap. The
/// caller is responsible for memory management.
///
/// Performance hint: if you are computing the intersection between several
/// bitmaps, two-by-two, it is best to start with the smallest bitmap.
/// You may also rely on and_inplace to avoid creating
/// many temporary bitmaps.
/// The returned pointer may be NULL in case of errors.
///
pub fn andWith(r1: Bitmap, r2: Bitmap) *Bitmap {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Computes the size of the intersection between two bitmaps.
///
pub fn and_cardinality(r1: Bitmap, r2: Bitmap) u64 {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Check whether two bitmaps intersect.
///
pub fn intersect(r1: Bitmap, r2: Bitmap) bool {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Check whether a bitmap and an open range intersect.
///
pub fn intersect_with_range(bm: Bitmap, x: u64, y: u64) bool {
    _ = bm;
    _ = x;
    _ = y;
    unreachable; // TODO
}

///
/// Computes the Jaccard index between two bitmaps. (Also known as the Tanimoto
/// distance, or the Jaccard similarity coefficient)
///
/// The Jaccard index is undefined if both bitmaps are empty.
///
pub fn jaccard_index(r1: Bitmap, r2: Bitmap) f64 {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Computes the size of the union between two bitmaps.
///
pub fn or_cardinality(r1: Bitmap, r2: Bitmap) u64 {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Computes the size of the difference (andnot) between two bitmaps.
///
pub fn andnot_cardinality(r1: Bitmap, r2: Bitmap) u64 {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Computes the size of the symmetric difference (xor) between two bitmaps.
///
pub fn xor_cardinality(r1: Bitmap, r2: Bitmap) u64 {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Inplace version of `and()`, modifies r1
/// r1 == r2 is allowed.
///
/// Performance hint: if you are computing the intersection between several
/// bitmaps, two-by-two, it is best to start with the smallest bitmap.
///
pub fn and_inplace(r1: *Bitmap, r2: Bitmap) void {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Computes the union between two bitmaps and returns new bitmap. The caller is
/// responsible for memory management.
/// The returned pointer may be NULL in case of errors.
///
pub fn or_with(r1: Bitmap, r2: Bitmap) *Bitmap {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Inplace version of `or_with(), modifies r1.
/// TODO: decide whether r1 == r2 ok
///
pub fn or_inplace(r1: *Bitmap, r2: Bitmap) void {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Compute the union of 'number' bitmaps.
/// Caller is responsible for freeing the result.
/// See also `or_many_heap()`
/// The returned pointer may be NULL in case of errors.
///
pub fn or_many(rs: []const Bitmap) *Bitmap {
    _ = rs;
    unreachable; // TODO
}

///
/// Compute the union of 'number' bitmaps using a heap. This can sometimes be
/// faster than `or_many() which uses a naive algorithm.
/// Caller is responsible for freeing the result.
///
pub fn or_many_heap(number: u32, rs: []const Bitmap) *Bitmap {
    _ = number;
    _ = rs;
    unreachable; // TODO
}

///
/// Computes the symmetric difference (xor) between two bitmaps
/// and returns new bitmap. The caller is responsible for memory management.
/// The returned pointer may be NULL in case of errors.
///
pub fn xor(r1: Bitmap, r2: Bitmap) *Bitmap {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Inplace version of xor, modifies r1, r1 != r2.
///
pub fn xor_inplace(r1: *Bitmap, r2: Bitmap) void {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Compute the xor of 'number' bitmaps.
/// Caller is responsible for freeing the result.
/// The returned pointer may be NULL in case of errors.
///
pub fn xor_many(number: usize, rs: []const Bitmap) *Bitmap {
    _ = number;
    _ = rs;
    unreachable; // TODO
}

///
/// Computes the difference (andnot) between two bitmaps and returns new bitmap.
/// Caller is responsible for freeing the result.
/// The returned pointer may be NULL in case of errors.
///
pub fn andnot(r1: Bitmap, r2: Bitmap) *Bitmap {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Inplace version of andnot, modifies r1, r1 != r2.
///
pub fn andnot_inplace(r1: *Bitmap, r2: Bitmap) void {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

pub fn is_frozen(r: Bitmap) bool {
    return r.high_low_container.flags.contains(.frozen);
}

///
/// TODO: consider implementing:
///
/// "Compute the xor of 'number' bitmaps using a heap. This can sometimes be
///  faster than xor_many which uses a naive algorithm. Caller is
///  responsible for freeing the result.""
///
/// Bitmap *xor_many_heap(number: u32,
///                                                rs: []const Bitmap);
///
///
/// Frees the memory.
///
pub fn deinit(r: *Bitmap, allocator: mem.Allocator) void {
    if (!r.is_frozen()) r.high_low_container.clear(allocator);
}

///
/// A bit of context usable with `*_bulk()` functions
///
/// Should be initialized with `{0}` (or `memset()` to all zeros).
/// Callers should treat it as an opaque type.
///
/// A context may only be used with a single bitmap
/// (unless re-initialized to zero), and any modification to a bitmap
/// (other than modifications performed with `_bulk()` functions with the context
/// passed) will invalidate any contexts associated with that bitmap.
///
pub const BulkContext = struct {
    container: root.Container,
    idx: u32,
    key: u16,
};

///
/// Add an item, using context from a previous insert for speed optimization.
///
/// `context` will be used to store information between calls to make bulk
/// operations faster. `*context` should be zero-initialized before the first
/// call to this function.
///
/// Modifying the bitmap in any way (other than `-bulk` suffixed functions)
/// will invalidate the stored context, calling this function with a non-zero
/// context after doing any modification invokes undefined behavior.
///
/// In order to exploit this optimization, the caller should call this function
/// with values with the same "key" (high 16 bits of the value) consecutively.
///
pub fn add_bulk(r: *Bitmap, context: *BulkContext, val: u32) !void {
    _ = r;
    _ = context;
    _ = val;
    unreachable; // TODO
}

///
/// Add value x
///
pub fn add(r: *Bitmap, allocator: mem.Allocator, x: u32) !void {
    try r.add_many(allocator, &.{x});
}

///
/// Add vals, faster than repeatedly calling `add()`
///
/// In order to exploit this optimization, the caller should attempt to keep
/// values with the same "key" (high 16 bits of the value) as consecutive
/// elements in `vals`
///
pub fn add_many(r: *Bitmap, allocator: mem.Allocator, vals: []const u32) !void {
    if (vals.len == 0) return;
    const end = vals.ptr + vals.len;
    var cur = vals.ptr;
    var idx: u32 = undefined;
    const container = try r.containerptr_add(allocator, cur[0], &idx);
    var context: BulkContext = .{
        .container = container,
        .idx = idx,
        .key = @truncate(cur[0] >> 16),
    };
    cur += 1;
    while (cur != end) : (cur += 1) {
        try r.add_bulk_impl(allocator, &context, cur[0]);
    }
}

pub fn add_bulk_impl(r: *Bitmap, allocator: mem.Allocator, context: *BulkContext, val: u32) !void {
    // std.debug.print("add_bulk_impl {f}\n", .{r});
    const key: u16 = @truncate(val >> 16);
    if (context.container.is_null() or context.key != key) {
        var idx: u32 = undefined;
        context.* = .{
            .container = try r.containerptr_add(allocator, val, &idx),
            .idx = idx,
            .key = key,
        };
    } else {
        // no need to seek the container, it is at hand
        // because we already have the container at hand, we can do the
        // insertion directly, bypassing the roaring_bitmap_add call
        const container2 = try context.container.add(allocator, @truncate(val));
        if (container2 != context.container) {
            // rare instance when we need to change the container type
            @branchHint(.unlikely);
            context.container.free(allocator);
            r.high_low_container.set_container_at_index(context.idx, container2);
            // context.typecode = r.high_low_container.get_container_at_index(context.idx).typecode;
            context.container = container2;
        }
    }
}

/// this is like roaring_bitmap_add, but it populates pointer arguments in such a
/// way
/// that we can recover the container touched, which, in turn can be used to
/// accelerate some functions (when you repeatedly need to add to the same
/// container)
fn containerptr_add(
    r: *Bitmap,
    allocator: mem.Allocator,
    val: u32,
    index: *u32,
) !Container {
    const ra = &r.high_low_container;
    const key: u16 = @truncate(val >> 16);
    const found, const i = ra.get_index(key);
    if (found) {
        ra.unshare_container_at_index(i);
        const c = ra.get_container_at_index(i);
        const c2 = try c.add(allocator, @truncate(val));
        index.* = i;
        if (c2 != c) {
            c.free(allocator);
            ra.set_container_at_index(i, c2);
            return c2;
        } else {
            return c;
        }
    } else {
        var new_c = Container.init(try root.ArrayContainer.create(allocator));
        errdefer new_c.const_cast(.array).deinit(allocator);
        new_c = try new_c.add(allocator, @truncate(val));
        // we could just assume that it stays an array container
        try ra.insert_new_key_value_at(allocator, i, key, new_c);
        index.* = i;
        return new_c;
    }
}

///
/// Add value x
/// Returns true if a new value was added, false if the value already existed.
///
pub fn add_checked(r: *Bitmap, x: u32) bool {
    _ = r;
    _ = x;
    unreachable; // TODO
}

///
/// Add all values in range [min, max]
///
pub fn add_range_closed(r: *Bitmap, allocator: mem.Allocator, min: u32, max: u32) !void {
    _ = allocator;
    _ = r;
    _ = min;
    _ = max;
    unreachable; // TODO
}

const u32_max = std.math.maxInt(u32);
///
/// Add all values in range [min, max)
///
pub fn add_range(r: *Bitmap, allocator: mem.Allocator, min: u32, max: u32) !void {
    if (max <= min or min > u32_max + 1) {
        return;
    }
    try r.add_range_closed(allocator, min, (max - 1));
}

///
/// Remove value x
///
pub fn remove(r: *Bitmap, x: u32) void {
    _ = r;
    _ = x;
    unreachable; // TODO
}

///
/// Remove all values in range [min, max]
///
pub fn remove_range_closed(r: *Bitmap, min: u32, max: u32) void {
    _ = r;
    _ = min;
    _ = max;
    unreachable; // TODO
}

///
/// Remove all values in range [min, max)
///
pub fn remove_range(r: *Bitmap, min: u64, max: u64) void {
    if (max <= min or min > u32_max + 1) {
        return;
    }
    remove_range_closed(r, min, (max - 1));
}

///
/// Remove multiple values
///
pub fn remove_many(r: *Bitmap, vals: []const u32) void {
    _ = r;
    _ = vals;
    unreachable; // TODO
}

///
/// Remove value x
/// Returns true if a new value was removed, false if the value was not existing.
///
pub fn remove_checked(r: *Bitmap, x: u32) bool {
    _ = r;
    _ = x;
    unreachable; // TODO
}

///
/// Check if value is present
///
pub fn contains(r: Bitmap, val: u32) bool {
    // For performance reasons, this function is and uses internal
    // functions directly.
    const hb: u16 = val >> 16;

    // the next function call involves a binary search and lots of branching.
    const i = r.high_low_container.get_index(hb);
    if (i < 0) return false;

    // rest might be a tad expensive, possibly involving another round of binary
    // search
    return r.high_low_container.get_container_at_index(i).contains(val);
}

///
/// Check whether a range of values from range_start (included)
/// to range_end (excluded) is present
///
pub fn contains_range(r: Bitmap, range_start: u64, range_end: u64) bool {
    _ = r;
    _ = range_start;
    _ = range_end;
    unreachable; // TODO
}

///
/// Check whether a range of values from range_start (included)
/// to range_end (included) is present
///
pub fn contains_range_closed(r: Bitmap, range_start: u32, range_end: u32) bool {
    _ = r;
    _ = range_start;
    _ = range_end;
    unreachable; // TODO
}

///
/// Check if an items is present, using context from a previous insert or search
/// for speed optimization.
///
/// `context` will be used to store information between calls to make bulk
/// operations faster. `*context` should be zero-initialized before the first
/// call to this function.
///
/// Modifying the bitmap in any way (other than `-bulk` suffixed functions)
/// will invalidate the stored context, calling this function with a non-zero
/// context after doing any modification invokes undefined behavior.
///
/// In order to exploit this optimization, the caller should call this function
/// with values with the same "key" (high 16 bits of the value) consecutively.
///
pub fn contains_bulk(r: Bitmap, context: BulkContext, val: u32) bool {
    _ = r;
    _ = context;
    _ = val;
    unreachable; // TODO
}

///
/// Get the cardinality of the bitmap (number of elements).
///
pub fn get_cardinality(r: Bitmap) u64 {
    var card: u64 = 0;
    for (r.high_low_container.containers.items(.container)) |c| {
        // std.debug.print("c.cardinality {}\n ", .{c.get_cardinality()});
        card += c.get_cardinality();
    }
    return card;
}

///
/// Returns the number of elements in the range [range_start, range_end).
///
pub fn range_cardinality(r: Bitmap, range_start: u64, range_end: u64) u64 {
    _ = r;
    _ = range_start;
    _ = range_end;
    unreachable; // TODO
}

///
/// Returns the number of elements in the range [range_start, range_end].
///
pub fn range_cardinality_closed(r: Bitmap, range_start: u32, range_end: u32) u64 {
    _ = r;
    _ = range_start;
    _ = range_end;
    unreachable; // TODO
}
///
/// Returns true if the bitmap is empty (cardinality is zero).
///
pub fn is_empty(r: Bitmap) bool {
    _ = r;
    unreachable; // TODO
}

///
/// Empties the bitmap.  It will have no auxiliary allocations (so if the bitmap
/// was initialized in client memory via init(), then a call to
/// clear() would be enough to "free" it)
///
pub fn clear(r: *Bitmap) void {
    _ = r;
    unreachable; // TODO
}

/// Convert the bitmap to a sorted array, output in `ans`.
///
/// Caller is responsible to ensure that there is enough memory allocated, e.g.
///
///     ans = malloc(roaring_bitmap_get_cardinality(bitmap) * sizeof(uint32_t));
///
pub fn to_u32_array(r: Bitmap, out: []u32) void {
    _ = r;
    _ = out;
    unreachable; // TODO
}

///
/// Convert the bitmap to a sorted array from `offset` by `limit`, output in
/// `ans`.
///
/// Caller is responsible to ensure that there is enough memory allocated, e.g.
///
///     ans = malloc(get_cardinality(limit)/// sizeof(u32));
///
/// This function always returns `true`
///
/// For more control, see `iterator32_skip` and
/// `iterator32_read`, which can be used to e.g. tell how many
/// values were actually read.
///
pub fn range_uint32_array(r: Bitmap, offset: usize, limit: usize, ans: []u32) bool {
    _ = r;
    _ = offset;
    _ = limit;
    _ = ans;
    unreachable; // TODO
}

///
/// Remove run-length encoding even when it is more space efficient.
/// Return whether a change was applied.
///
pub fn remove_run_compression(r: *Bitmap) bool {
    _ = r;
    unreachable; // TODO
}

///
/// Convert array and bitmap containers to run containers when it is more
/// efficient; also convert from run containers when more space efficient.
///
/// Returns true if the result has at least one run container.
/// Additional savings might be possible by calling `shrinkToFit()`.
///
pub fn run_optimize(r: *Bitmap, allocator: mem.Allocator) !bool {
    _ = allocator;
    _ = r;
    unreachable; // TODO
}

///
/// If needed, reallocate memory to shrink the memory usage.
/// Returns the number of bytes saved.
///
pub fn shrink_to_fit(r: *Bitmap) usize {
    _ = r;
    unreachable; // TODO
}

///
/// Write the bitmap to an output pointer, this output buffer should refer to
/// at least `size_in_bytes(r)` allocated bytes.
///
/// See `portable_serialize()` if you want a format that's
/// compatible with Java and Go implementations.  This format can sometimes be
/// more space efficient than the portable form, e.g. when the data is sparse.
///
/// Returns how many bytes written, should be `size_in_bytes(r)`.
///
/// This function is endian-sensitive. If you have a big-endian system (e.g., a
/// mainframe IBM s390x), the data format is going to be big-endian and not
/// compatible with little-endian systems.
///
/// When serializing data to a file, we recommend that you also use
/// checksums so that, at deserialization, you can be confident
/// that you are recovering the correct data.
///
pub fn serialize(r: Bitmap, w: *Io.Writer) !usize {
    const portablesize = r.portable_size_in_bytes();
    const cardinality = r.get_cardinality();
    const sizeasarray = cardinality * @sizeOf(u32) + @sizeOf(u32);

    if (portablesize < sizeasarray) {
        try w.writeByte(CROARING_SERIALIZATION_CONTAINER);
        return r.portable_serialize(w) + 1;
    } else {
        try w.writeByte(CROARING_SERIALIZATION_ARRAY_UINT32);
        try w.writeInt(@TypeOf(cardinality), cardinality, .little);
        try w.writeSliceEndian(u32, r.high_low_container.containers.items(.key), .little);
        return 1 + sizeasarray;
    }
}

const CROARING_SERIALIZATION_ARRAY_UINT32 = 1;
const CROARING_SERIALIZATION_CONTAINER = 2;

///
/// Use with `serialize()`.
///
/// (See `portable_deserialize()` if you want a format that's
/// compatible with Java and Go implementations).
///
/// This function is endian-sensitive. If you have a big-endian system (e.g., a
/// mainframe IBM s390x), the data format is going to be big-endian and not
/// compatible with little-endian systems.
///
/// The returned pointer may be NULL in case of errors.
///
pub fn deserialize(r: *Io.Reader) !Bitmap {
    const first_byte = try r.peekByte();
    // std.debug.print("deserialize first_byte {}\n", .{first_byte});
    if (first_byte == CROARING_SERIALIZATION_ARRAY_UINT32) {
        // This looks like a compressed set of uint32_t elements

        const card = try r.takeInt(u32, .little);
        var bitmap: Bitmap = .{};
        var context: BulkContext = mem.zeroes(BulkContext);
        for (0..card) |_| try bitmap.add_bulk(&context, try r.takeInt(u32, .little));

        return bitmap;
    } else if (first_byte == CROARING_SERIALIZATION_CONTAINER) {
        return try portable_deserialize(r);
    } else return error.UnexpectedFirstByte;
}

///
/// Use with `serialize()`.
///
/// (See `portable_deserialize_safe()` if you want a format that's
/// compatible with Java and Go implementations).
///
/// This function is endian-sensitive. If you have a big-endian system (e.g., a
/// mainframe IBM s390x), the data format is going to be big-endian and not
/// compatible with little-endian systems.
///
/// The difference with `deserialize()` is that this function
/// checks that the input buffer is a valid bitmap.  If the buffer is too small,
/// NULL is returned.
///
/// The returned pointer may be NULL in case of errors.
///
// pub fn deserialize_safe(buf: []const u8);

///
/// How many bytes are required to serialize this bitmap (NOT compatible
/// with Java and Go versions)
///
pub fn size_in_bytes(r: Bitmap) usize {
    _ = r;
    unreachable; // TODO
}

///
/// Read bitmap from a serialized buffer.
/// In case of failure, NULL is returned.
///
/// This function is unsafe in the sense that if there is no valid serialized
/// bitmap at the pointer, then many bytes could be read, possibly causing a
/// buffer overflow.  See also portable_deserialize_safe().
///
/// This is meant to be compatible with the Java and Go versions:
/// https://github.com/RoaringBitmap/RoaringFormatSpec
///
/// This function is endian-sensitive. If you have a big-endian system (e.g., a
/// mainframe IBM s390x), the data format is going to be big-endian and not
/// compatible with little-endian systems.
///
/// The returned pointer may be NULL in case of errors.
///
pub fn portable_deserialize(allocator: mem.Allocator, r: *Io.Reader) !Bitmap {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var rb: Bitmap = .{ .high_low_container = try Array.portable_deserialize(allocator, r, arena.allocator()) };
    rb.set_copy_on_write(false);
    return rb;
}

///
/// Read bitmap from a serialized buffer safely (reading up to maxbytes).
/// In case of failure, NULL is returned.
///
/// This is meant to be compatible with the Java and Go versions:
/// https://github.com/RoaringBitmap/RoaringFormatSpec
///
/// The function itself is safe in the sense that it will not cause buffer
/// overflows: it will not read beyond the scope of the provided buffer
/// (buf,maxbytes).
///
/// However, for correct operations, it is assumed that the bitmap
/// read was once serialized from a valid bitmap (i.e., it follows the format
/// specification). If you provided an incorrect input (garbage), then the bitmap
/// read may not be in a valid state and following operations may not lead to
/// sensible results. In particular, the serialized array containers need to be
/// in sorted order, and the run containers should be in sorted non-overlapping
/// order. This is is guaranteed to happen when serializing an existing bitmap,
/// but not for random inputs.
///
/// If the source is untrusted, you should call
/// internal_validate to check the validity of the
/// bitmap prior to using it. Only after calling internal_validate
/// is the bitmap considered safe for use.
///
/// We also recommend that you use checksums to check that serialized data
/// corresponds to the serialized bitmap. The CRoaring library does not provide
/// checksumming.
///
/// This function is endian-sensitive. If you have a big-endian system (e.g., a
/// mainframe IBM s390x), the data format is going to be big-endian and not
/// compatible with little-endian systems.
///
/// The returned pointer may be NULL in case of errors.
///
pub fn portable_deserialize_safe(buf: []const u8) Bitmap {
    _ = buf;
    unreachable; // TODO
}

///
/// Read bitmap from a serialized buffer.
/// In case of failure, NULL is returned.
///
/// Bitmap returned by this function can be used in all readonly contexts.
/// Bitmap must be freed as usual, by calling free().
/// Underlying buffer must not be freed or modified while it backs any bitmaps.
///
/// The function is unsafe in the following ways:
/// 1) It may execute unaligned memory accesses.
/// 2) A buffer overflow may occur if buf does not point to a valid serialized
///    bitmap.
///
/// This is meant to be compatible with the Java and Go versions:
/// https://github.com/RoaringBitmap/RoaringFormatSpec
///
/// This function is endian-sensitive. If you have a big-endian system (e.g., a
/// mainframe IBM s390x), the data format is going to be big-endian and not
/// compatible with little-endian systems.
///
/// The returned pointer may be NULL in case of errors.
///
pub fn portable_deserialize_frozen(buf: []const u8) *Bitmap {
    _ = buf;
    unreachable; // TODO
}

///
/// Check how many bytes would be read (up to maxbytes) at this pointer if there
/// is a bitmap, returns zero if there is no valid bitmap.
///
/// This is meant to be compatible with the Java and Go versions:
/// https://github.com/RoaringBitmap/RoaringFormatSpec
///
pub fn portable_deserialize_size(buf: []const u8) usize {
    _ = buf;
    unreachable; // TODO
}

///
/// How many bytes are required to serialize this bitmap.
///
/// This is meant to be compatible with the Java and Go versions:
/// https://github.com/RoaringBitmap/RoaringFormatSpec
///
pub fn portable_size_in_bytes(r: Bitmap) usize {
    return r.high_low_container.portable_size_in_bytes();
}

///
/// Write a bitmap to a char buffer.  The output buffer should refer to at least
/// `portable_size_in_bytes(r)` bytes of allocated memory.
///
/// Returns how many bytes were written which should match
/// `portable_size_in_bytes(r)`.
///
/// This is meant to be compatible with the Java and Go versions:
/// https://github.com/RoaringBitmap/RoaringFormatSpec
///
/// This function is endian-sensitive. If you have a big-endian system (e.g., a
/// mainframe IBM s390x), the data format is going to be big-endian and not
/// compatible with little-endian systems.
///
/// When serializing data to a file, we recommend that you also use
/// checksums so that, at deserialization, you can be confident
/// that you are recovering the correct data.
///
pub fn portable_serialize(r: Bitmap, w: *Io.Writer) !usize {
    return try r.high_low_container.portable_serialize(w);
}

/// "Frozen" serialization format imitates memory layout of Bitmap.
/// Deserialized bitmap is a constant view of the underlying buffer.
/// This significantly reduces amount of allocations and copying required during
/// deserialization.
/// It can be used with memory mapped files.
/// Example can be found in benchmarks/frozen_benchmark.c
///
///         [#####] const Bitmap/////          | | |
///     +----+ | +-+
///     |      |   |
/// [#####################################] underlying buffer
///
/// Note that because frozen serialization format imitates C memory layout
/// of Bitmap, it is not fixed. It is different on big/little endian
/// platforms and can be changed in future.
///
///
/// Returns number of bytes required to serialize bitmap using frozen format.
///
pub fn frozen_size_in_bytes(r: Bitmap) usize {
    _ = r;
    unreachable; // TODO
}

///
/// Serializes bitmap using frozen format.
/// Buffer size must be at least frozen_size_in_bytes().
///
/// This function is endian-sensitive. If you have a big-endian system (e.g., a
/// mainframe IBM s390x), the data format is going to be big-endian and not
/// compatible with little-endian systems.
///
/// When serializing data to a file, we recommend that you also use
/// checksums so that, at deserialization, you can be confident
/// that you are recovering the correct data.
///
pub fn frozen_serialize(r: Bitmap, buf: []u8) void {
    _ = r;
    _ = buf;
    unreachable; // TODO
}

///
/// Creates constant bitmap that is a view of a given buffer.
/// Buffer data should have been written by `frozen_serialize()`
/// Its beginning must also be aligned by 32 bytes.
/// Length must be equal exactly to `frozen_size_in_bytes()`.
/// In case of failure, NULL is returned.
///
/// Bitmap returned by this function can be used in all readonly contexts.
/// Bitmap must be freed as usual, by calling free().
/// Underlying buffer must not be freed or modified while it backs any bitmaps.
///
/// This function is endian-sensitive. If you have a big-endian system (e.g., a
/// mainframe IBM s390x), the data format is going to be big-endian and not
/// compatible with little-endian systems.
///
pub fn frozen_view(r: Bitmap, buf: []const u8) void {
    _ = r;
    _ = buf;
    unreachable; // TODO
}

///
/// Iterate over the bitmap elements. The function iterator is called once for
/// all the values with ptr (can be NULL) as the second parameter of each call.
///
/// `roaring_iterator` is simply a pointer to a function that returns bool
/// (true means that the iteration should continue while false means that it
/// should stop), and takes (u32,void*) as inputs.
///
/// Returns true if the iterator returned true throughout (so that all
/// data points were necessarily visited).
///
/// Iteration is ordered: from the smallest to the largest elements.
///
pub fn roaring_iterate(r: Bitmap) void {
    _ = r;
    //                      void *ptr);
    unreachable; // TODO
}

// bool iterate64(r: Bitmap, iterator64 iterator,
//                        high_bits: u64, void *ptr);

///
/// Return true if the two bitmaps contain the same elements.
///
pub fn equals(r1: Bitmap, r2: Bitmap) bool {
    const ra1 = &r1.high_low_container;
    const ra2 = &r2.high_low_container;

    if (false) {
        if (ra1.containers.len != ra2.containers.len) return false;
        const slice1 = ra1.containers.slice();
        const slice2 = ra2.containers.slice();
        for (slice1.items(.key), slice2.items(.key)) |k1, k2|
            if (k1 != k2) return false;

        for (slice1.items(.container), slice2.items(.container)) |c1, c2|
            if (!c1.equals(c2.*)) return false;

        return true;
    }

    return ra1.containers.len == ra2.containers.len and eql: {
        const slice1 = ra1.containers.slice();
        const slice2 = ra2.containers.slice();
        break :eql for (slice1.items(.key), slice2.items(.key)) |k1, k2| {
            if (k1 != k2) break false;
        } else for (slice1.items(.container), slice2.items(.container)) |c1, c2| {
            if (!c1.equals(c2)) break false;
        } else true;
    };
}

///
/// Return true if all the elements of r1 are also in r2.
///
pub fn is_subset(r1: Bitmap, r2: Bitmap) bool {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Return true if all the elements of r1 are also in r2, and r2 is strictly
/// greater than r1.
///
pub fn is_strict_subset(r1: Bitmap, r2: Bitmap) bool {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// (For expert users who seek high performance.)
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
/// operations force a bitset conversion.
///
/// The returned pointer may be NULL in case of errors.
///
pub fn lazy_or(
    r1: Bitmap,
    r2: Bitmap,
    // const bool bitsetconversion
) *Bitmap {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// (For expert users who seek high performance.)
///
/// Inplace version of lazy_or, modifies r1.
///
/// `bitsetconversion` is a flag which determines whether container-container
/// operations force a bitset conversion.
///
pub fn lazy_or_inplace(r1: *Bitmap, r2: Bitmap, bitsetconversion: bool) void {
    _ = r1;
    _ = r2;
    _ = bitsetconversion;
    unreachable; // TODO
}

///
/// (For expert users who seek high performance.)
///
/// Execute maintenance on a bitmap created from `lazy_or()`
/// or modified with `lazy_or_inplace()`.
///
pub fn repair_after_lazy(r: *Bitmap) void {
    _ = r;
    unreachable; // TODO
}

///
/// Computes the symmetric difference between two bitmaps and returns new bitmap.
/// The caller is responsible for memory management.
///
/// The lazy version defers some computations such as the maintenance of the
/// cardinality counts. Thus you must call `repair_after_lazy()`
/// after executing "lazy" computations.
///
/// It is safe to repeatedly call `lazy_xor_inplace()` on
/// the result.
///
/// The returned pointer may be NULL in case of errors.
///
pub fn lazy_xor(r1: Bitmap, r2: Bitmap) *Bitmap {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// (For expert users who seek high performance.)
///
/// Inplace version of lazy_xor, modifies r1. r1 != r2
///
pub fn lazy_xor_inplace(r1: *Bitmap, r2: Bitmap) void {
    _ = r1;
    _ = r2;
    unreachable; // TODO
}

///
/// Compute the negation of the bitmap in the interval [range_start, range_end).
/// The number of negated values is range_end - range_start.
/// Areas outside the range are passed through unchanged.
/// The returned pointer may be NULL in case of errors.
///
pub fn flip(r: Bitmap, range_start: u64, range_end: u64) *Bitmap {
    _ = r;
    _ = range_start;
    _ = range_end;
    unreachable; // TODO
}

///
/// Compute the negation of the bitmap in the interval [range_start, range_end].
/// The number of negated values is range_end - range_start + 1.
/// Areas outside the range are passed through unchanged.
/// The returned pointer may be NULL in case of errors.
///
pub fn flip_closed(x1: Bitmap, range_start: u32, range_end: u32) *Bitmap {
    _ = x1;
    _ = range_start;
    _ = range_end;
    unreachable; // TODO
}
///
/// compute (in place) the negation of the roaring bitmap within a specified
/// interval: [range_start, range_end). The number of negated values is
/// range_end - range_start.
/// Areas outside the range are passed through unchanged.
///
pub fn flip_inplace(r: *Bitmap, range_start: u64, range_end: u64) void {
    _ = r;
    _ = range_start;
    _ = range_end;
    unreachable; // TODO
}

///
/// compute (in place) the negation of the roaring bitmap within a specified
/// interval: [range_start, range_end]. The number of negated values is
/// range_end - range_start + 1.
/// Areas outside the range are passed through unchanged.
///
pub fn flip_inplace_closed(r: *Bitmap, range_start: u32, range_end: u32) void {
    _ = r;
    _ = range_start;
    _ = range_end;
    unreachable; // TODO
}

///
/// Selects the element at index 'rank' where the smallest element is at index 0.
/// If the size of the roaring bitmap is strictly greater than rank, then this
/// function returns true and sets element to the element of given rank.
/// Otherwise, it returns false.
///
pub fn select(r: Bitmap, rank_: u32, element: *u32) bool {
    _ = r;
    _ = rank_;
    _ = element;
    unreachable; // TODO
}

///
/// rank returns the number of integers that are smaller or equal
/// to x. Thus if x is the first element, this function will return 1. If
/// x is smaller than the smallest element, this function will return 0.
///
/// The indexing convention differs between select and
/// rank: select refers to the smallest value
/// as having index 0, whereas rank returns 1 when ranking
/// the smallest value.
///
pub fn rank(r: Bitmap, x: u32) u64 {
    _ = r;
    _ = x;
    unreachable; // TODO
}

///
/// rank_many is an `Bulk` version of `rank`
/// it puts rank value of each element in `[begin .. end)` to `ans[]`
///
/// the values in `[begin .. end)` must be sorted in Ascending order;
/// Caller is responsible to ensure that there is enough memory allocated, e.g.
///
///     ans = malloc((end-begin)/// sizeof(u64));
///
pub fn rank_many(r: Bitmap, begin: []const u32, end: []const u32, ans: []u64) void {
    _ = r;
    _ = begin;
    _ = end;
    _ = ans;
    unreachable; // TODO
}

///
/// Returns the index of x in the given roaring bitmap.
/// If the roaring bitmap doesn't contain x , this function will return -1.
/// The difference with rank function is that this function will return -1 when x
/// is not the element of roaring bitmap, but the rank function will return a
/// non-negative number.
///
pub fn get_index(r: Bitmap, x: u32) i64 {
    _ = r;
    _ = x;
    unreachable; // TODO
}

///
/// Returns the smallest value in the set, or u32_max if the set is empty.
///
pub fn minimum(r: Bitmap) u32 {
    _ = r;
    unreachable; // TODO
}

///
/// Returns the greatest value in the set, or 0 if the set is empty.
///
pub fn maximum(r: Bitmap) u32 {
    _ = r;
    unreachable; // TODO
}

///
/// (For advanced users.)
///
/// Collect statistics about the bitmap, see types.h for
/// a description of statistics_t
///
// pub fn statistics(r: Bitmap,
//                                statistics_t *stat) void;

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
// bool r: Bitmap internal_validate({}
//                                       const char **reason);
pub fn internal_validate(r: Bitmap, reason: *[]const u8) bool {
    _ = r;
    _ = reason;
    unreachable; // TODO
}

///*******************
/// * What follows is code use to iterate through values in a roaring bitmap
/// r: *Bitmap =...
/// iterator32_t i;
/// iterator_create(r, &i);
/// while(i.has_value) {
///   printf("value = %d\n", i.current_value);
///   iterator32_advance(&i);
/// }
/// iterator32_free(&i);
/// Obviously, if you modify the underlying bitmap, the iterator
/// becomes invalid. So don't.
///
/// A struct used to keep iterator state. Users should only access
/// `current_value` and `has_value`, the rest of the type should be treated as
/// opaque.
///
const Iterator32 = struct {
    // parent: Bitmap;        // Owner
    // const ROARING_CONTAINER_T *container;  // Current container
    // uint8_t typecode;                      // Typecode of current container
    // int32_t container_index;               // Current  ndex
    // highbits: u32;                     // High 16 bits of the current value
    // container_iterator_t container_it;

    // current_value: u32;
    // bool has_value;
};

///
/// Initialize an iterator object that can be used to iterate through the values.
/// If there is a  value, then this iterator points to the first value and
/// `it.has_value` is true. The value is in `it.current_value`.
///
pub fn iterator_init(r: Bitmap, newit: *Iterator32) void {
    _ = r;
    _ = newit;
    unreachable; // TODO
}

///
/// Initialize an iterator object that can be used to iterate through the values.
/// If there is a value, then this iterator points to the last value and
/// `it.has_value` is true. The value is in `it.current_value`.
///
pub fn iterator_init_last(r: Bitmap, newit: *Iterator32) void {
    _ = r;
    _ = newit;
    unreachable; // TODO
}

///
/// Create an iterator object that can be used to iterate through the values.
/// Caller is responsible for calling `iterator32_free()`.
///
/// The iterator is initialized (this function calls `roaring_iterator_init()`)
/// If there is a value, then this iterator points to the first value and
/// `it.has_value` is true.  The value is in `it.current_value`.
///
pub fn roaring_iterator_create(r: Bitmap) *Iterator32 {
    _ = r;
    unreachable; // TODO
}

///
/// Advance the iterator. If there is a new value, then `it.has_value` is true.
/// The new value is in `it.current_value`. Values are traversed in increasing
/// orders. For convenience, returns `it.has_value`.
///
/// Once `it.has_value` is false, `iterator32_advance` should not
/// be called on the iterator again. Calling `iterator32_previous`
/// is allowed.
///
pub fn iterator32_advance(it: *Iterator32) bool {
    _ = it;
    unreachable; // TODO
}

///
/// Decrement the iterator. If there's a new value, then `it.has_value` is true.
/// The new value is in `it.current_value`. Values are traversed in decreasing
/// order. For convenience, returns `it.has_value`.
///
/// Once `it.has_value` is false, `iterator32_previous` should not
/// be called on the iterator again. Calling `iterator32_advance` is
/// allowed.
///
pub fn iterator32_previous(it: *Iterator32) bool {
    _ = it;
    unreachable; // TODO
}

///
/// Move the iterator to the first value >= `val`. If there is a such a value,
/// then `it.has_value` is true. The new value is in `it.current_value`.
/// For convenience, returns `it.has_value`.
///
pub fn iterator32_move_equalorlarger(it: *Iterator32, val: u32) bool {
    _ = it;
    _ = val;
    unreachable; // TODO
}

///
/// Creates a copy of an iterator.
/// Caller must free it.
///
pub fn iterator32_copy(dst: *Iterator32, it: *const Iterator32) void {
    _ = dst;
    _ = it;
    unreachable; // TODO
}

///
/// Free memory following `roaring_iterator_create()`
///
pub fn iterator32_free(it: *Iterator32) void {
    _ = it;
    unreachable; // TODO
}

///
/// Reads next ${count} values from iterator into user-supplied ${buf}.
/// Returns the number of read elements.
/// This number can be smaller than ${count}, which means that iterator is
/// drained.
///
/// This function satisfies semantics of iteration and can be used together with
/// other iterator functions.
///  - first value is copied from ${it}.current_value
///  - after function returns, iterator is positioned at the next element
///
// u32 iterator32_read
pub fn iterator32_read(it: *Iterator32, buf: []u32) void {
    _ = it;
    _ = buf;
    unreachable; // TODO
}

///
/// Skip the next ${count} values from iterator.
/// Returns the number of values actually skipped.
/// The number can be smaller than ${count}, which means that iterator is
/// drained.
///
/// This function is equivalent to calling `iterator32_advance()`
/// ${count} times but is much more efficient.
///
pub fn iterator32_skip(it: *Iterator32, count: u32) u32 {
    _ = it;
    _ = count;
    unreachable; // TODO
}

///
/// Skip the previous ${count} values from iterator (move backwards).
/// Returns the number of values actually skipped backwards.
/// The number can be smaller than ${count}, which means that iterator reached
/// the beginning.
///
/// This function is equivalent to calling `iterator32_previous()`
/// ${count} times but is much more efficient.
///
pub fn iterator32_skip_backward(it: *Iterator32, count: u32) u32 {
    _ = it;
    _ = count;
    unreachable; // TODO
}

pub fn format(b: Bitmap, w: *Io.Writer) !void {
    try w.print("Bitmap.hi_lo_container ", .{});
    try b.high_low_container.format(w);
}
test Bitmap {
    _ = Bitmap;
}

const std = @import("std");
const root = @import("root.zig");
const Array = root.Array;
const Container = root.Container;
const Typecode = root.Typecode;
const mem = std.mem;
const Io = std.Io;
