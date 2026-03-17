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
    var high: i32 = @bitCast(@as(u32, @intCast(array.len)));
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

//
// Good old binary search through rle data
//
pub fn interleavedBinarySearch(array: []const root.Rle16, ikey: u16) i32 {
    var low: i32 = 0;
    var high = @as(i32, @intCast(array.len)) - 1;
    while (low <= high) {
        const middleIndex = (low + high) >> 1;
        const middleValue = array[@intCast(middleIndex)].value;
        // std.debug.print("low {} high {} middleIndex {} middlevalue {}\n", .{ low, high, middleIndex, middleValue });
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
pub fn count_greater(array: []const u16, ikey: u16) u32 {
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
pub fn count_less(array: []const u16, ikey: u16) u32 {
    if (array.len == 0) return 0;
    const pos = binarySearch(array, ikey);
    return @intCast(if (pos >= 0) pos else -(pos + 1));
}

///
/// Returns number of runs which can'be be merged with the key because they
/// are less than the key.
/// Note that [5,6,7,8] can be merged with the key 9 and won't be counted.
///
pub fn rle16_count_less(array: []const root.Rle16, key: u16) u32 {
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

pub fn rle16_count_greater(array: []const root.Rle16, key: u16) u32 {
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

pub fn cast(T: type, i: anytype) T {
    return @intCast(i);
}

const std = @import("std");
const root = @import("root.zig");
