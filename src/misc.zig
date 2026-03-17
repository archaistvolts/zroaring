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

const root = @import("root.zig");
const std = @import("std");
