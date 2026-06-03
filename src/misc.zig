//! common helpers

///
///   Good old binary search.
///   Assumes that array is sorted, has logarithmic complexity.
///   if the result is x, then:
///    * if ( x>0 )  you have array[x] = ikey
///    * if ( x<0 ) then inserting ikey at position -x-1 in array (insuring that
///  array[-x-1]=ikey) keeps the array sorted.
// TODO use sort.lowerBound()?
pub fn binarySearch(array: []const u16, ikey: u16) i32 {
    var low: i32 = 0;
    var high: i32 = @intCast(array.len);
    high -= 1;
    while (low <= high) {
        const middleIndex = (low + high) >> 1;
        const middleValue = array[@intCast(middleIndex)];
        if (middleValue < ikey) {
            low = middleIndex + 1;
        } else if (middleValue > ikey) {
            high = middleIndex - 1;
        } else {
            return middleIndex;
        }
    }
    return -(low + 1);
}

/// binary search with fallback to linear search for short ranges
pub fn binarySearchFallbackLinear(array: []align(C.BLOCK_ALIGN) const u16, pos: u16) i32 {
    var low: i32 = 0;
    var high = @as(i32, @intCast(array.len)) - 1;
    while (high >= low + 16) {
        const middleIndex = (low + high) >> 1;
        const middleValue = array[@intCast(middleIndex)];
        if (middleValue < pos) {
            low = middleIndex + 1;
        } else if (middleValue > pos) {
            high = middleIndex - 1;
        } else {
            return middleIndex;
        }
    }

    var j = low;
    while (j <= high) : (j += 1) {
        const v = array[@intCast(j)];
        if (v == pos) return j;
        if (v > pos) break;
    }
    return -(j + 1);
}

/// binary search through rle data
pub fn interleavedBinarySearch(array: []align(C.BLOCK_ALIGN) const root.Rle16, ikey: u16) i32 {
    var low: i32 = 0;
    var high = @as(i32, @intCast(array.len)) - 1;
    while (low <= high) {
        const middleIndex = (low + high) >> 1;
        const middleValue = array[@intCast(middleIndex)].value;
        if (middleValue < ikey) {
            low = middleIndex + 1;
        } else if (middleValue > ikey) {
            high = middleIndex - 1;
        } else {
            return middleIndex;
        }
    }
    return -(low + 1);
}

/// Returns number of elements which are greater than ikey.
/// Array elements must be unique and sorted.
pub fn count_greater(array: []align(C.BLOCK_ALIGN) const u16, ikey: u16) u32 {
    if (array.len == 0) return 0;
    const pos = binarySearch(array, ikey);
    if (pos >= 0) {
        return @intCast(array.len - @as(u32, @intCast(pos + 1)));
    } else {
        return @intCast(array.len - @as(u32, @intCast(-pos - 1)));
    }
}

/// Returns number of elements which are less than ikey.
/// Array elements must be unique and sorted.
pub fn count_less(array: []align(C.BLOCK_ALIGN) const u16, ikey: u16) u32 {
    if (array.len == 0) return 0;
    const pos = binarySearch(array, ikey);
    return @intCast(if (pos >= 0) pos else -(pos + 1));
}

/// Returns number of runs which can'be be merged with the key because they
/// are less than the key.
/// Note that [5,6,7,8] can be merged with the key 9 and won't be counted.
pub fn rle16_count_less(array: []align(C.BLOCK_ALIGN) const root.Rle16, key: u16) u32 {
    if (array.len == 0) return 0;
    var low: i32 = 0;
    var high = @as(i32, @intCast(array.len)) - 1;
    while (low <= high) {
        const middleIndex = (low + high) >> 1;
        const min_value = array[@intCast(middleIndex)].value;
        const max_value =
            array[@intCast(middleIndex)].value + array[@intCast(middleIndex)].length;
        if (max_value + @as(u32, 1) < key) { // uint32 arithmetic
            low = middleIndex + 1;
        } else if (key < min_value) {
            high = middleIndex - 1;
        } else {
            return @intCast(middleIndex);
        }
    }
    return @intCast(low);
}

pub fn rle16_count_greater(array: []align(C.BLOCK_ALIGN) const root.Rle16, key: u16) u32 {
    if (array.len == 0) return 0;
    var low: i32 = 0;
    var high = @as(i32, @intCast(array.len)) - 1;
    while (low <= high) {
        const middleIndex = (low + high) >> 1;
        const min_value = array[@intCast(middleIndex)].value;
        const max_value =
            array[@intCast(middleIndex)].value + array[@intCast(middleIndex)].length;
        if (max_value < key) {
            low = middleIndex + 1;
        } else if (key + @as(u32, 1) < min_value) { // uint32 arithmetic
            high = middleIndex - 1;
        } else {
            return @intCast(@as(i32, @intCast(array.len)) - (middleIndex + 1));
        }
    }
    return @intCast(@as(i32, @intCast(array.len)) - low);
}

/// Galloping search
/// Assumes that array is sorted, has logarithmic complexity.
/// if the result is x, then if x = length, you have that all values in array
/// between pos and length are smaller than min. otherwise returns the first
/// index x such that array[x] >= min.
pub fn advanceUntil(array: []align(C.BLOCK_ALIGN) const u16, pos: u32, min: u16) u32 {
    var lower: u32 = pos + 1;
    const length: u32 = @intCast(array.len);
    if (lower >= length or array[lower] >= min)
        return lower;

    var spansize: u32 = 1;
    while (lower + spansize < length and array[lower + spansize] < min) {
        spansize <<= 1;
    }
    var upper: u32 = if (lower + spansize < length)
        lower + spansize
    else
        length - 1;

    if (array[upper] == min)
        return upper;
    if (array[upper] < min)
        return length;

    lower += spansize >> 1;

    var mid: u32 = 0;
    while (lower + 1 != upper) {
        mid = (lower + upper) >> 1;
        if (array[mid] == min) {
            return mid;
        } else if (array[mid] < min) {
            lower = mid;
        } else {
            upper = mid;
        }
    }
    return upper;
}

/// Branchless binary search going after 4 values at once.
/// Assumes that array is sorted.
/// You have that array[index1] >= target1, array[index2] >= target2, ...
/// except when index = array.len, in which case you know that all values
/// in array are smaller than the target.
/// It has logarithmic complexity.
pub fn binarySearch4(
    array: []const u16,
    target1: u16,
    target2: u16,
    target3: u16,
    target4: u16,
    index1: *u32,
    index2: *u32,
    index3: *u32,
    index4: *u32,
) void {
    var base1: u32 = 0;
    var base2: u32 = 0;
    var base3: u32 = 0;
    var base4: u32 = 0;
    var n: u32 = @intCast(array.len);
    if (n == 0) return;
    while (n > 1) {
        const half = n >> 1;
        if (array[base1 + half] < target1) base1 += half;
        if (array[base2 + half] < target2) base2 += half;
        if (array[base3 + half] < target3) base3 += half;
        if (array[base4 + half] < target4) base4 += half;
        n -= half;
    }
    index1.* = base1 + @intFromBool(array[base1] < target1);
    index2.* = base2 + @intFromBool(array[base2] < target2);
    index3.* = base3 + @intFromBool(array[base3] < target3);
    index4.* = base4 + @intFromBool(array[base4] < target4);
}

/// Branchless binary search going after 2 values at once.
/// Assumes that array is sorted.
/// You have that array[index1] >= target1, array[index2] >= target2.
/// except when index = array.len, in which case you know that all values
/// in array are smaller than the target.
/// It has logarithmic complexity.
pub fn binarySearch2(
    array: []const u16,
    target1: u16,
    target2: u16,
    index1: *u32,
    index2: *u32,
) void {
    var base1: u32 = 0;
    var base2: u32 = 0;
    var n: u32 = @intCast(array.len);
    if (n == 0) return;
    while (n > 1) {
        const half = n >> 1;
        if (array[base1 + half] < target1) base1 += half;
        if (array[base2 + half] < target2) base2 += half;
        n -= half;
    }
    index1.* = base1 + @intFromBool(array[base1] < target1);
    index2.* = base2 + @intFromBool(array[base2] < target2);
}

/// Computes the intersection between one small and one large set of uint16_t.
/// Stores the result into buffer and return the number of elements.
/// Processes the small set in blocks of 4 values calling binarySearch4
/// and binarySearch2. This approach can be slightly superior to a conventional
/// galloping search in some instances.
pub fn intersect_skewed_uint16(
    small: []align(C.BLOCK_ALIGN) const u16,
    large: []align(C.BLOCK_ALIGN) const u16,
    buffer: []align(C.BLOCK_ALIGN) u16,
) u32 {
    var pos: u32 = 0;
    var idx_l: u32 = 0;
    var idx_s: u32 = 0;
    const size_s = small.len;
    const size_l = large.len;
    if (size_s == 0) return 0;

    var index1: u32 = undefined;
    var index2: u32 = undefined;
    var index3: u32 = undefined;
    var index4: u32 = undefined;

    while (idx_s + 4 <= size_s and idx_l < size_l) {
        const target1 = small[idx_s];
        const target2 = small[idx_s + 1];
        const target3 = small[idx_s + 2];
        const target4 = small[idx_s + 3];
        binarySearch4(
            large[idx_l..size_l],
            target1,
            target2,
            target3,
            target4,
            &index1,
            &index2,
            &index3,
            &index4,
        );
        if (index1 + idx_l < size_l and large[idx_l + index1] == target1) {
            buffer[pos] = target1;
            pos += 1;
        }
        if (index2 + idx_l < size_l and large[idx_l + index2] == target2) {
            buffer[pos] = target2;
            pos += 1;
        }
        if (index3 + idx_l < size_l and large[idx_l + index3] == target3) {
            buffer[pos] = target3;
            pos += 1;
        }
        if (index4 + idx_l < size_l and large[idx_l + index4] == target4) {
            buffer[pos] = target4;
            pos += 1;
        }
        idx_s += 4;
        idx_l += index4;
    }
    if (idx_s + 2 <= size_s and idx_l < size_l) {
        const target1 = small[idx_s];
        const target2 = small[idx_s + 1];
        binarySearch2(large[idx_l..size_l], target1, target2, &index1, &index2);
        if (index1 + idx_l < size_l and large[idx_l + index1] == target1) {
            buffer[pos] = target1;
            pos += 1;
        }
        if (index2 + idx_l < size_l and large[idx_l + index2] == target2) {
            buffer[pos] = target2;
            pos += 1;
        }
        idx_s += 2;
        idx_l += index2;
    }
    if (idx_s < size_s and idx_l < size_l) {
        const val_s = small[idx_s];
        if (binarySearch(large[idx_l..size_l], val_s) >= 0) {
            buffer[pos] = val_s;
            pos += 1;
        }
    }
    return pos;
}

/// Generic intersection function.
/// attempts to reproduce but `goto SKIP_FIRST_COMPARE`
pub fn intersect_uint16(
    A: []align(C.BLOCK_ALIGN) const u16,
    B: []align(C.BLOCK_ALIGN) const u16,
    OUT: []align(C.BLOCK_ALIGN) u16,
) u32 {
    if (A.len == 0 or B.len == 0) return 0;
    var a: [*]const u16 = A.ptr;
    var b: [*]const u16 = B.ptr;
    var out: [*]u16 = OUT.ptr;
    const aend = A.ptr + A.len;
    const bend = B.ptr + B.len;

    while (true) {
        while (a[0] < b[0]) { // advance a while smaller
            a += 1;
            if (a == aend) return @intCast(out - OUT.ptr);
        }

        while (a[0] > b[0]) { // advance b while smaller
            b += 1;
            if (b == bend) return @intCast(out - OUT.ptr);
        }

        if (a[0] == b[0]) {
            out[0] = a[0];
            out += 1;

            a += 1;
            b += 1;
            if (a == aend or b == bend) return @intCast(out - OUT.ptr);
        } else {
            // a > b happened after b advanced.  advance a once to catch up.
            // emulates `goto SKIP_FIRST_COMPARE` from croaring.
            a += 1;
            if (a == aend) return @intCast(out - OUT.ptr);
        }
    }
}

pub const pshufb =
    if (@import("builtin").zig_backend == .stage2_llvm)
        struct {
            extern fn @"llvm.x86.avx2.pshuf.b"(a: Block, b: Block) Block;
            const pshufb = @"llvm.x86.avx2.pshuf.b";
        }.pshufb
    else if (C.IS_X86)
        pshufb_x86
    else
        unreachable; // TODO non-llvm, non-x86

inline fn pshufb_x86(a: Block, b: Block) Block {
    return asm ("vpshufb %[mask], %[src], %[ret]"
        : [ret] "=x" (-> Block),
        : [src] "x" (a),
          [mask] "x" (b),
    );
}

/// computes absolute differences of u8s and sums them into 64-bit blocks
pub const psadbw =
    if (@import("builtin").zig_backend == .stage2_llvm)
        struct {
            extern fn @"llvm.x86.avx2.psad.bw"(a: Block, b: Block) @Vector(4, u64);
            extern fn @"llvm.x86.avx2.pshuf.b"(a: Block, b: Block) Block;
            const psadbw = @"llvm.x86.avx2.psad.bw";
        }.psadbw
    else if (C.IS_X86)
        psadbw_x86
    else
        unreachable; // TODO non-llvm, non-x86

inline fn psadbw_x86(a: Block, b: Block) root.Block64 {
    return asm ("vpsadbw %[src2], %[src1], %[ret]"
        : [ret] "=x" (-> root.Block64),
        : [src1] "x" (a),
          [src2] "x" (b),
    );
}

/// number of groups of size in num. `size=8 | 0=>0, [1,8]=>1, [9,16]=>2` etc.
///
/// align num forward to size and divide by size.
///
/// example: `elemscapacity = numGroupsOfSize(capacity*@sizeOf(u16), elem_size)`.
pub fn numGroupsOfSize(num: anytype, comptime size: anytype) @TypeOf(num) {
    return (num + size - 1) / size;
}

test numGroupsOfSize {
    try testing.expectEqual(0, numGroupsOfSize(0, 8));
    try testing.expectEqual(1, numGroupsOfSize(1, 8));
    try testing.expectEqual(1, numGroupsOfSize(8, 8));
    try testing.expectEqual(2, numGroupsOfSize(9, 8));
    try testing.expectEqual(2, numGroupsOfSize(16, 8));
}

/// an int with t1 in lo, t2 in hi bits
pub fn pair(t1: root.Typecode, t2: root.Typecode) u16 {
    return @as(u16, @intFromEnum(t1)) << 8 | @intFromEnum(t2);
}

/// an int with t1 in lo, t2 in hi bits
pub fn pairFromInt(int: u16) [2]root.Typecode {
    return .{ @enumFromInt(int >> 8), @enumFromInt(int & 0xF) };
}

// ---
// Memory helpers
// ---
pub fn cast(T: type, i: anytype) T {
    return @intCast(i);
}

/// convert other_slice to Slice with pointer attributes
pub fn asSlice(Slice: type, other_slice: anytype) Slice {
    return std.mem.bytesAsSlice(std.meta.Child(Slice), std.mem.sliceAsBytes(other_slice));
}

pub fn trace(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    if (@import("build-options").trace) {
        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();
        var term = stderr.terminal();
        term.mode = .escape_codes;
        term.writer.print("src/{s}:{}:{}: ", .{ src.file, src.line, src.column }) catch {};
        term.setColor(.yellow) catch {};
        term.writer.print("{s}", .{src.fn_name}) catch {};
        term.setColor(.white) catch {};
        term.writer.print(" : ", .{}) catch {};
        term.writer.print(fmt, args) catch {};
        term.writer.print("\n", .{}) catch {};
    }
}

const std = @import("std");
const testing = std.testing;
const root = @import("root.zig");
const C = root.constants;
const Block = root.Block;
