//! common helpers

///
///   Good old binary search.
///   Assumes that array is sorted, has logarithmic complexity.
///   if the result is x, then:
///    * if ( x>0 )  you have array[x] = ikey
///    * if ( x<0 ) then inserting ikey at position -x-1 in array (insuring that
///  array[-x-1]=ikey) keeps the array sorted.
// TODO use sort.lowerBound()?
pub fn binarySearch(array: []align(C.BLOCK_ALIGN) const u16, ikey: u16) i32 {
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
pub fn binarySearch2(array: []align(C.BLOCK_ALIGN) const u16, pos: u16) i32 {
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

//
// Good old binary search through rle data
//
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

///
/// Returns number of elements which are greater than ikey.
/// Array elements must be unique and sorted.
///
pub fn count_greater(array: []align(C.BLOCK_ALIGN) const u16, ikey: u16) u32 {
    if (array.len == 0) return 0;
    const pos = binarySearch(array, ikey);
    if (pos >= 0) {
        return @intCast(array.len - @as(u32, @intCast(pos + 1)));
    } else {
        return @intCast(array.len - @as(u32, @intCast(-pos - 1)));
    }
}

///
/// Returns number of elements which are less than ikey.
/// Array elements must be unique and sorted.
///
pub fn count_less(array: []align(C.BLOCK_ALIGN) const u16, ikey: u16) u32 {
    if (array.len == 0) return 0;
    const pos = binarySearch(array, ikey);
    return @intCast(if (pos >= 0) pos else -(pos + 1));
}

///
/// Returns number of runs which can'be be merged with the key because they
/// are less than the key.
/// Note that [5,6,7,8] can be merged with the key 9 and won't be counted.
///
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

/// number of groups of size in num. `size=8 | 0:0, [1,8]:1, [9,16]:2 etc`.
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

pub fn fieldTypes(comptime Header: type) *const [@typeInfo(Header).@"struct".fields.len]type {
    const fs = std.meta.fields(Header);
    comptime var ret: [fs.len]type = undefined;
    for (fs, &ret) |f, *r| r.* = f.type;
    return &ret;
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
        term.writer.print("{s}::{s}", .{ src.module, src.fn_name }) catch {};
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
