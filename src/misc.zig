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
///
/// `pos` may be u32 max so wrapping addition is used.
pub fn advanceUntil(array: []align(C.BLOCK_ALIGN) const u16, pos: u32, min: u16) u32 {
    var lower = pos +% 1;
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

// TODO: this could be accelerated, possibly, by using binarySearch4 as above.
pub fn intersect_skewed_uint16_cardinality(
    small: []align(C.BLOCK_ALIGN) const u16,
    large: []align(C.BLOCK_ALIGN) const u16,
) u32 {
    var pos: u32 = 0;
    var idx_l: u32 = 0;
    var idx_s: u32 = 0;
    const size_l: u32 = @intCast(large.len);
    const size_s: u32 = @intCast(small.len);

    if (0 == small.len)
        return 0;

    var val_l = large[idx_l];
    var val_s = small[idx_s];
    while (true) {
        if (val_l < val_s) {
            idx_l = advanceUntil(large, idx_l, val_s);
            if (idx_l == size_l) break;
            val_l = large[idx_l];
        } else if (val_s < val_l) {
            idx_s += 1;
            if (idx_s == size_s) break;
            val_s = small[idx_s];
        } else {
            pos += 1;
            idx_s += 1;
            if (idx_s == size_s) break;
            val_s = small[idx_s];
            idx_l = advanceUntil(large, idx_l, val_s);
            if (idx_l == size_l) break;
            val_l = large[idx_l];
        }
    }

    return pos;
}

/// Generic intersection function.
/// attempts to reproduce `goto SKIP_FIRST_COMPARE`
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
            // imitates croaring `goto SKIP_FIRST_COMPARE`.
            a += 1;
            if (a == aend) return @intCast(out - OUT.ptr);
        }
    }
}

// TODO simd with blocks?
pub fn intersect_uint16_cardinality(
    A: []const u16,
    B: []const u16,
) u32 {
    var answer: u32 = 0;
    if (A.len == 0 or B.len == 0) return 0;
    const endA = A.ptr + A.len;
    const endB = B.ptr + B.len;
    var a = A.ptr;
    var b = B.ptr;
    while (true) {
        while (a[0] < b[0]) {
            a += 1;
            if (a == endA) return answer;
        }
        while (a[0] > b[0]) {
            b += 1;
            if (b == endB) return answer;
        }
        if (a[0] == b[0]) {
            answer += 1;
            a += 1;
            b += 1;
            if (a == endA or b == endB) return answer;
        } else {
            // a > b after b advanced; advance a once to catch up.
            // imitates croaring `goto SKIP_FIRST_COMPARE`.
            a += 1;
            if (a == endA) return answer;
        }
    }
}

fn gen_shuffle_mask16_entry(comptime mask: u8) [16]u8 {
    @setEvalBranchQuota(5000);
    var result: [16]u8 = undefined;
    var j: usize = 0;
    inline for (0..8) |k| {
        if (mask & (@as(u8, 1) << @intCast(k)) != 0) {
            result[j] = @intCast(k * 2);
            result[j + 1] = @intCast(k * 2 + 1);
            j += 2;
        }
    }
    while (j < 16) : (j += 1) result[j] = 0xFF;
    return result;
}

/// pshufb control table: for each 8-bit match mask, a 16-byte shuffle pattern
/// that shuffles the matching u16 values to the front.
const shuffle_mask16: [256][16]u8 = blk: {
    var table: [256][16]u8 = undefined;
    for (&table, 0..) |*entry, i| entry.* = gen_shuffle_mask16_entry(@intCast(i));
    break :blk table;
};

const u16x8 = @Vector(8, u16);
const u16x8_len = @typeInfo(u16x8).vector.len;

pub fn intersect_vector16(
    A: []align(C.BLOCK_ALIGN) const u16,
    B: []align(C.BLOCK_ALIGN) const u16,
    out: []align(C.BLOCK_ALIGN) u16,
) u32 {
    var count: u32 = 0;
    var ia: u32 = 0;
    var ib: u32 = 0;

    const enda = (A.len / u16x8_len) * u16x8_len;
    const endb = (B.len / u16x8_len) * u16x8_len;
    while (ia < enda and ib < endb) {
        const va: u16x8 = A[ia .. ia + u16x8_len][0..u16x8_len].*;
        const vb: u16x8 = B[ib .. ib + u16x8_len][0..u16x8_len].*;

        // imitate _mm_cmpestrm / _SIDD_CMP_EQUAL_ANY
        // broadcast each element of vb and check if it matches anything in va
        var matches: @Vector(u16x8_len, bool) = @splat(false);
        inline for (0..u16x8_len) |i| {
            // Broadcast the i-th element of vb to all 8 slots
            const b_elem: u16x8 = @splat(vb[i]);
            matches = matches | (va == b_elem);
        }

        const match_mask: u8 = @bitCast(matches);
        if (match_mask != 0) {
            // use match_mask to load precomputed shuffle mask
            const p: @Vector(8, u16) = @bitCast(pshufbhalf(
                @as(BlockHalf, @bitCast(va)),
                shuffle_mask16[match_mask],
            ));

            // Store the packed matches into C.
            //
            // TODO use an unaligned scalar store here to avoid out-of-bounds if
            // out isn't padded, but we follow CRoaring.
            inline for (0..u16x8_len) |idx| {
                if (idx < @popCount(match_mask))
                    out[count + idx] = p[idx];
            }
            count += @popCount(match_mask);
        }

        const amax = A[ia + u16x8_len - 1];
        const bmax = B[ib + u16x8_len - 1];
        if (amax <= bmax) ia += u16x8_len;
        if (bmax <= amax) ib += u16x8_len;
    }

    // scalar tail intersection
    while (ia < A.len and ib < B.len) {
        const a = A[ia];
        const b = B[ib];
        if (a < b) {
            ia += 1;
        } else if (b < a) {
            ib += 1;
        } else {
            out[count] = a;
            count += 1;
            ia += 1;
            ib += 1;
        }
    }
    return count;
}

/// intersect a and b, writing the result inplace to A.
/// returns length of the intersected array.
pub fn intersect_vector16_inplace(A: []u16, B: []const u16) u32 {
    var count: u32 = 0;
    var ia: u32 = 0;
    var ib: u32 = 0;
    const enda = (A.len / u16x8_len) * u16x8_len;
    const endb = (B.len / u16x8_len) * u16x8_len;

    // tmp buffer to avoid trampling A. capacity is 16 because an 8 element
    // store at an offset requires up to 16 slots to avoid OOB.
    var tmp: [16]u16 = undefined;
    var tmpcount: u8 = 0;
    while (ia < enda and ib < endb) {
        const va: @Vector(u16x8_len, u16) = A[ia..][0..u16x8_len].*;
        const vb: @Vector(u16x8_len, u16) = B[ib..][0..u16x8_len].*;

        // imitate _mm_cmpestrm equal any
        var match_mask: @Vector(u16x8_len, bool) = @splat(false);
        inline for (0..u16x8_len) |i| {
            const b_elem: @Vector(u16x8_len, u16) = @splat(vb[i]);
            match_mask = match_mask | (va == b_elem);
        }

        const r: u8 = @bitCast(match_mask);
        if (r != 0) { // pack matches to tmp
            // shuffle matching elements to front
            const p: [8]u16 = @bitCast(pshufbhalf(
                @as(BlockHalf, @bitCast(va)),
                @as(BlockHalf, shuffle_mask16[r]),
            ));
            // unconditionally copy 8 elements. because tmpcount will never
            // exceed 8 before a flush, tmpcount + 8 <= 16, keeping within tmp
            // buffer.
            @memcpy(tmp[tmpcount..].ptr, p[0..u16x8_len]);
            tmpcount += @popCount(r);
        }

        const amax = A[ia + u16x8_len - 1];
        const bmax = B[ib + u16x8_len - 1];
        // advance pointers, flush tmp to a
        if (amax <= bmax) {
            @memcpy(A[count..].ptr, tmp[0..tmpcount]);
            count += tmpcount;
            tmpcount = 0;
            ia += u16x8_len;
        }

        if (bmax <= amax)
            ib += u16x8_len;
    }

    // flush remaining items in tmp

    @memcpy(A[count..].ptr, tmp[0..tmpcount]);
    count += tmpcount;

    // Lemire's optimization:
    // If A didn't advance, tmpcount contains the matches for the current va.
    // Because the sets are uniquely sorted, we can safely jump past these already-matched
    // elements in the scalar tail to prevent double-counting them.
    ia += tmpcount;

    // scalar intersect tail
    while (ia < A.len and ib < B.len) {
        const a = A[ia];
        const b = B[ib];
        if (a < b) {
            ia += 1;
        } else if (b < a) {
            ib += 1;
        } else {
            A[count] = a;
            count += 1;
            ia += 1;
            ib += 1;
        }
    }
    return count;
}

pub fn intersect_vector16_cardinality(
    A: []align(C.BLOCK_ALIGN) const u16,
    B: []align(C.BLOCK_ALIGN) const u16,
) u32 {
    var count: u32 = 0;
    var ia: u32 = 0;
    var ib: u32 = 0;
    const enda = (A.len / u16x8_len) * u16x8_len;
    const endb = (B.len / u16x8_len) * u16x8_len;

    while (ia < enda and ib < endb) {
        const va: u16x8 = A[ia..][0..u16x8_len].*;
        const vb: u16x8 = B[ib..][0..u16x8_len].*;

        var matches: @Vector(8, bool) = @splat(false);
        inline for (0..8) |i| {
            matches = matches | (va == @as(u16x8, @splat(vb[i])));
        }
        count += @popCount(@as(u8, @bitCast(matches)));

        const amax = A[ia + 7];
        const bmax = B[ib + 7];
        if (amax <= bmax) ia += 8;
        if (bmax <= amax) ib += 8;
    }

    while (ia < A.len and ib < B.len) {
        if (A[ia] < B[ib]) {
            ia += 1;
        } else if (B[ib] < A[ia]) {
            ib += 1;
        } else {
            count += 1;
            ia += 1;
            ib += 1;
        }
    }
    return count;
}

/// Batcher odd-even merge: two sorted 8-u16 vectors → 8 smallest + 8 largest sorted.
fn sse_merge(v1: u16x8, v2: u16x8, min: *u16x8, max: *u16x8) void {
    var cur = @min(v1, v2);
    var max2 = @max(v1, v2);
    inline for (0..7) |_| {
        cur = std.simd.rotateElementsLeft(cur, 1);
        const new_min = @min(cur, max2);
        max2 = @max(cur, max2);
        cur = new_min;
    }
    cur = std.simd.rotateElementsLeft(cur, 1);
    min.* = cur;
    max.* = max2;
}

/// Writes unique elements from newval (deduped against old[7] and internally)
/// to output. Returns count of elements written.
fn store_unique(old: u16x8, newval: u16x8, output: [*]u16) u32 {
    // [old[7], newval[0..6]] — each lane i checks if newval[i] matches previous
    const shift_r: u16x8 = .{
        old[7],    newval[0], newval[1], newval[2],
        newval[3], newval[4], newval[5], newval[6],
    };
    const dup: u8 = @bitCast(shift_r == newval);
    const keep: u8 = ~dup;
    const count = @popCount(keep);
    const packed_vec = @as(BlockHalf, @bitCast(pshufbhalf(
        @as(BlockHalf, @bitCast(newval)),
        shuffle_mask16[keep],
    )));
    const p: u16x8 = @bitCast(packed_vec);
    inline for (0..8) |i| {
        if (i < count) output[i] = p[i];
    }
    return count;
}

/// write vector vecTmp2 = [old[7], newval[0..6]], omitting elements where
/// vecTmp2[i] equals either neighbor (XOR semantics: paired values cancel).
fn store_unique_xor(old: u16x8, newval: u16x8, output: [*]u16) u32 {
    // tmp1 = o[6], o[7], n[0], n[1], n[2], n[3], n[4], n[5]
    var tmp1 = std.simd.shiftElementsRight(newval, 2, old[6]);
    tmp1[1] = old[7];
    // tmp2 = o[7], n[0], n[1], n[2], n[3], n[4], n[5], n[6]
    const tmp2 = std.simd.shiftElementsRight(newval, 1, old[7]);
    const equalleft: u8 = @bitCast(tmp2 == tmp1);
    const equalright: u8 = @bitCast(tmp2 == newval);
    const equalleftorright = equalleft | equalright;
    const keep = ~equalleftorright;
    const numberofnewvalues = @popCount(keep);
    const key: BlockHalf = pshufbhalf(@as(BlockHalf, @bitCast(tmp2)), shuffle_mask16[keep]);
    @memcpy(output, @as([8]u16, @bitCast(key))[0..]);
    return numberofnewvalues;
}

/// removes consecutive duplicate pairs from a sorted array in-place (XOR
/// semantics: equal elements cancel out entirely).
fn unique_xor(out: []u16) u32 {
    if (out.len == 0) return 0;
    var pos: u32 = 1;
    for (1..out.len) |i| {
        if (out[i] != out[i - 1]) {
            out[pos] = out[i];
            pos += 1;
        } else {
            pos -= 1;
        }
    }
    return pos;
}

/// removes consecutive duplicates from a sorted array in-place.
fn unique(out: []u16) u32 {
    if (out.len == 0) return 0;
    var pos: u32 = 1;
    for (1..out.len) |i| {
        if (out[i] != out[i - 1]) {
            out[pos] = out[i];
            pos += 1;
        }
    }
    return pos;
}

/// one-pass SIMD union of two sorted uint16 arrays.
/// This function may not be safe if output == set1 or output == set2.
pub fn union_vector16(
    set1: []const u16,
    set2: []const u16,
    output: [*]align(C.BLOCK_ALIGN) u16,
) usize {
    if (set1.len < 8 or set2.len < 8) {
        return union_uint16(set1, set2, output);
    }
    const len1 = set1.len / 8;
    const len2 = set2.len / 8;
    var pos1: u32 = 1;
    var pos2: u32 = 1;

    // start the machine
    const vA: u16x8 = set1[0..8].*;
    const vB: u16x8 = set2[0..8].*;

    var vecMin: u16x8 = undefined;
    var vecMax: u16x8 = undefined;
    sse_merge(vA, vB, &vecMin, &vecMax);

    var laststore: u16x8 = @splat(0xFFFF);
    var out = output + store_unique(laststore, vecMin, output);
    laststore = vecMin;

    if (pos1 < len1 and pos2 < len2) {
        var curA = set1[8 * pos1];
        var curB = set2[8 * pos2];
        var V: u16x8 = undefined;
        while (true) {
            if (curA <= curB) {
                V = set1[8 * pos1 ..][0..8].*;
                pos1 += 1;
                if (pos1 < len1) {
                    curA = set1[8 * pos1];
                } else break;
            } else {
                V = set2[8 * pos2 ..][0..8].*;
                pos2 += 1;
                if (pos2 < len2) {
                    curB = set2[8 * pos2];
                } else break;
            }
            sse_merge(V, vecMax, &vecMin, &vecMax);
            out += store_unique(laststore, vecMin, out);
            laststore = vecMin;
        }
        sse_merge(V, vecMax, &vecMin, &vecMax);
        out += store_unique(laststore, vecMin, out);
        laststore = vecMin;
    }

    // trailing scalar union
    // could be improved?
    //
    // copy the small end on a tmp buffer
    var tmp: [16]u16 = undefined;
    var leftoversize = store_unique(laststore, vecMax, tmp[0..]);
    if (pos1 == len1) {
        const taillen: u32 = @intCast(set1.len - 8 * pos1);
        @memcpy(tmp[leftoversize..][0..taillen], set1[8 * pos1 ..].ptr);
        leftoversize += taillen;
        std.mem.sortUnstable(u16, tmp[0..leftoversize], {}, std.sort.asc(u16));
        const ulen = unique(tmp[0..leftoversize]);
        out += union_uint16(tmp[0..ulen], set2[8 * pos2 ..], out);
    } else {
        const taillen: u32 = @intCast(set2.len - 8 * pos2);
        @memcpy(tmp[leftoversize..][0..taillen], set2[8 * pos2 ..].ptr);
        leftoversize += taillen;
        std.mem.sortUnstable(u16, tmp[0..leftoversize], {}, std.sort.asc(u16));
        const ulen = unique(tmp[0..leftoversize]);
        out += union_uint16(tmp[0..ulen], set1[8 * pos1 ..], out);
    }
    const len = out - output;
    assert(len == 0 or len >= @max(set1.len, set2.len));
    assert(len <= set1.len + set2.len);
    return @intCast(len);
}

/// one-pass SIMD xor of two sorted uint16 arrays.
pub fn xor_vector16(
    array1: []align(C.BLOCK_ALIGN) const u16,
    array2: []align(C.BLOCK_ALIGN) const u16,
    output: [*]align(C.BLOCK_ALIGN) u16,
) usize {
    if (array1.len < 8 or array2.len < 8) {
        return xor_uint16(array1, array2, output[0 .. array1.len + array2.len].ptr);
    }
    const len1 = array1.len / 8;
    const len2 = array2.len / 8;
    var pos1: u32 = 1;
    var pos2: u32 = 1;

    // we start the machine
    const vA: u16x8 = array1[0..8].*;
    const vB: u16x8 = array2[0..8].*;

    var vecMin: u16x8 = undefined;
    var vecMax: u16x8 = undefined;
    sse_merge(vA, vB, &vecMin, &vecMax);

    var laststore: u16x8 = @splat(0xFFFF);
    var out = output + store_unique_xor(laststore, vecMin, output);
    laststore = vecMin;

    if (pos1 < len1 and pos2 < len2) {
        var curA = array1[8 * pos1];
        var curB = array2[8 * pos2];
        var V: u16x8 = undefined;
        while (true) {
            if (curA <= curB) {
                V = array1[8 * pos1 ..][0..8].*;
                pos1 += 1;
                if (pos1 < len1) {
                    curA = array1[8 * pos1];
                } else break;
            } else {
                V = array2[8 * pos2 ..][0..8].*;
                pos2 += 1;
                if (pos2 < len2) {
                    curB = array2[8 * pos2];
                } else break;
            }
            sse_merge(V, vecMax, &vecMin, &vecMax);
            out += store_unique_xor(laststore, vecMin, out);
            laststore = vecMin;
        }
        // final merge of last V with vecMax
        sse_merge(V, vecMax, &vecMin, &vecMax);
        out += store_unique_xor(laststore, vecMin, out);
        laststore = vecMin;
    }

    // we finish the rest off using a scalar algorithm.  could be improved?
    // conditionally stores the last value of laststore as well as all but the
    // last value of vecMax, to "buffer"
    var buffer: [17]u16 align(C.BLOCK_ALIGN) = undefined;
    var leftoversize = store_unique_xor(laststore, vecMax, buffer[0..]);
    const vec7 = vecMax[7];
    if (vec7 != vecMax[6]) {
        buffer[leftoversize] = vec7;
        leftoversize += 1;
    }

    var len = out - output;
    if (pos1 == len1) {
        const taillen: u32 = @intCast(array1.len - 8 * pos1);
        @memcpy(buffer[leftoversize..][0..taillen], array1.ptr[8 * pos1 ..]);
        leftoversize += taillen;
        if (leftoversize == 0) { // trivial case
            const n = array2.len - 8 * pos2;
            @memcpy(out, array2[8 * pos2 ..]);
            len += n;
        } else {
            std.mem.sortUnstable(u16, buffer[0..leftoversize], {}, std.sort.asc(u16));
            leftoversize = unique_xor(buffer[0..leftoversize]);
            len += xor_uint16(buffer[0..leftoversize], array2[8 * pos2 ..], out);
        }
    } else {
        const taillen: u32 = @intCast(array2.len - 8 * pos2);
        @memcpy(buffer[leftoversize..][0..taillen], array2.ptr[8 * pos2 ..]);
        leftoversize += taillen;
        if (leftoversize == 0) { // trivial case
            const n: usize = array1.len - 8 * pos1;
            @memcpy(out, array1[8 * pos1 ..]);
            len += n;
        } else {
            std.mem.sortUnstable(u16, buffer[0..leftoversize], {}, std.sort.asc(u16));
            leftoversize = unique_xor(buffer[0..leftoversize]);
            len += xor_uint16(buffer[0..leftoversize], array1[8 * pos1 ..], out);
        }
    }

    assert(len <= array1.len + array2.len);
    return @intCast(len);
}

pub fn union_uint16(
    set1: []const u16,
    set2: []const u16,
    buffer: [*]u16,
) u32 {
    var pos: usize = 0;
    var idx1: u32 = 0;
    var idx2: u32 = 0;

    if (set2.len == 0) {
        @memmove(buffer, set1);
        return @intCast(set1.len);
    }
    if (set1.len == 0) {
        @memmove(buffer, set2);
        return @intCast(set2.len);
    }

    var val1 = set1[idx1];
    var val2 = set2[idx2];

    while (true) {
        if (val1 < val2) {
            buffer[pos] = val1;
            pos += 1;
            idx1 += 1;
            if (idx1 >= set1.len)
                break;
            val1 = set1[idx1];
        } else if (val2 < val1) {
            buffer[pos] = val2;
            pos += 1;
            idx2 += 1;
            if (idx2 >= set2.len)
                break;
            val2 = set2[idx2];
        } else {
            buffer[pos] = val1;
            pos += 1;
            idx1 += 1;
            idx2 += 1;
            if (idx1 >= set1.len or idx2 >= set2.len)
                break;
            val1 = set1[idx1];
            val2 = set2[idx2];
        }
    }

    if (idx1 < set1.len) {
        const n_elems = set1.len - idx1;
        @memmove(buffer[pos..], set1[idx1..][0..n_elems]);
        pos += n_elems;
    } else if (idx2 < set2.len) {
        const n_elems = set2.len - idx2;
        @memmove(buffer[pos..], set2[idx2..][0..n_elems]);
        pos += n_elems;
    }

    return @intCast(pos);
}

pub fn xor_uint16(
    set1: []align(C.BLOCK_ALIGN) const u16,
    set2: []const u16,
    out: [*]u16,
) usize {
    var pos1: usize = 0;
    var pos2: usize = 0;
    var pos_out: usize = 0;
    while (pos1 < set1.len and pos2 < set2.len) {
        const v1 = set1[pos1];
        const v2 = set2[pos2];
        if (v1 == v2) {
            pos1 += 1;
            pos2 += 1;
            continue;
        }
        if (v1 < v2) {
            out[pos_out] = v1;
            pos_out += 1;
            pos1 += 1;
        } else {
            out[pos_out] = v2;
            pos_out += 1;
            pos2 += 1;
        }
    }
    if (pos1 < set1.len) {
        const n_elems = set1.len - pos1;
        @memcpy(out[pos_out..][0..n_elems], set1[pos1..].ptr);
        pos_out += n_elems;
    } else if (pos2 < set2.len) {
        const n_elems = set2.len - pos2;
        @memcpy(out[pos_out..][0..n_elems], set2[pos2..].ptr);
        pos_out += n_elems;
    }
    return pos_out;
}

/// Compute the difference (a1 minus a2) of two sorted uint16 arrays.
pub fn difference_uint16(
    a1: []align(C.BLOCK_ALIGN) const u16,
    a2: []align(C.BLOCK_ALIGN) const u16,
    out: []align(C.BLOCK_ALIGN) u16,
) u32 {
    var out_card: u32 = 0;
    var k1: u32 = 0;
    var k2: u32 = 0;
    const length1: u32 = @intCast(a1.len);
    const length2: u32 = @intCast(a2.len);
    if (length1 == 0) return 0;
    if (length2 == 0) {
        if (a1.ptr != out.ptr) @memcpy(out.ptr, a1);
        return length1;
    }
    var s1 = a1[k1];
    var s2 = a2[k2];
    while (true) {
        if (s1 < s2) {
            out[out_card] = s1;
            out_card += 1;
            k1 += 1;
            if (k1 >= length1) {
                break;
            }
            s1 = a1[k1];
        } else if (s1 == s2) {
            k1 += 1;
            k2 += 1;
            if (k1 >= length1) {
                break;
            }
            if (k2 >= length2) {
                @memmove(out.ptr + out_card, a1[k1..]);
                return out_card + length1 - k1;
            }
            s1 = a1[k1];
            s2 = a2[k2];
        } else { // if (val1>val2)
            k2 += 1;
            if (k2 >= length2) {
                @memmove(out.ptr + out_card, a1[k1..]);
                return out_card + length1 - k1;
            }
            s2 = a2[k2];
        }
    }
    return out_card;
}

pub fn fast_union_uint16(
    set1: []const u16,
    set2: []align(C.BLOCK_ALIGN) const u16,
    buffer: [*]align(C.BLOCK_ALIGN) u16,
) usize {
    // compute union with smallest array first
    const unionfn = if (C.HAS_AVX2)
        union_vector16
    else
        union_uint16;

    if (set1.len < set2.len) {
        return unionfn(set1, set2, buffer);
    } else {
        return unionfn(set2, set1, buffer);
    }
}

/// Find the cardinality of the bitset in [begin,begin+lenminusone]
pub fn bitset_lenrange_cardinality(
    words: [*]align(C.BLOCK_ALIGN) u64,
    start: u32,
    lenminusone: u32,
) u32 {
    const firstword = start / 64;
    const endword = (start + lenminusone) / 64;
    if (firstword == endword) {
        return @popCount(words[firstword] &
            ((~@as(u64, 0)) >>
                @truncate((63 - lenminusone) % 64)) <<
                @truncate(start % 64));
    }
    var answer: u64 =
        @popCount(words[firstword] & ((~@as(u64, 0)) << @truncate(start % 64)));
    for (firstword + 1..endword) |i| {
        answer += @popCount(words[i]);
    }
    answer += @popCount(words[endword] &
        (~@as(u64, 0)) >>
            @truncate(((~start +% 1) -% lenminusone -% 1) % 64));
    return @intCast(answer);
}

/// Set all bits in indexes [begin,begin+lenminusone] to true.
pub fn bitset_set_lenrange(
    words: [*]align(C.BLOCK_ALIGN) u64,
    start: u32,
    lenminusone: u32,
) void {
    const firstword = start / 64;
    const endword = (start + lenminusone) / 64;
    if (firstword == endword) {
        words[firstword] |= ((~@as(u64, 0)) >>
            @truncate((63 - lenminusone) % 64)) <<
            @truncate(start % 64);
        return;
    }
    const temp = words[endword];
    words[firstword] |= (~@as(u64, 0)) << @truncate(start % 64);
    // diverge from croaring which uses loop with += 2.
    @memset(words[firstword + 1 .. endword], ~@as(u64, 0));
    words[endword] =
        temp | (~@as(u64, 0)) >> @truncate(((~start +% 1) -% lenminusone -% 1) % 64);
}

/// Set all bits in indexes [begin,end) to true.
pub fn bitset_set_range(words: [*]align(C.BLOCK_ALIGN) u64, start: u32, end: u32) void {
    if (start == end) return;
    const firstword = start / 64;
    const endword = (end - 1) / 64;
    if (firstword == endword) {
        words[firstword] |=
            ~@as(u64, 0) << @truncate(start % 64) &
            ~@as(u64, 0) >> @truncate((~end + 1) % 64);
        return;
    }
    words[firstword] |= ~@as(u64, 0) << @truncate(start % 64);
    for (firstword + 1..endword) |i| {
        words[i] = ~@as(u64, 0);
    }
    words[endword] |= ~@as(u64, 0) >> @truncate((~end + 1) % 64);
}

/// Flip bits in range [start, end).
pub fn bitset_flip_range(
    words: [*]align(C.BLOCK_ALIGN) u64,
    start: u32,
    end: u32,
) void {
    if (start == end) return;
    const firstword = start / 64;
    const endword = (end - 1) / 64;
    words[firstword] ^= ~((~@as(u64, 0)) << @truncate(start % 64));
    for (words[firstword..endword]) |*w|
        w.* = ~w.*;
    words[endword] ^= ((~@as(u64, 0)) >> @truncate(((~end +% 1) % 64)));
}

/// Flip (XOR) bits at given positions (no cardinality tracking).
pub fn bitset_flip_list(
    words: [*]align(C.BLOCK_ALIGN) u64,
    list: []align(C.BLOCK_ALIGN) const u16,
) void {
    for (list) |pos| {
        const offset = pos >> 6;
        const index: u6 = @truncate(pos & 63);
        words[offset] ^= (@as(u64, 1) << index);
    }
}

/// Flip bits at given positions, return updated cardinality.
pub fn bitset_flip_list_withcard(
    words: [*]align(C.BLOCK_ALIGN) u64,
    card: u32,
    list: []align(C.BLOCK_ALIGN) const u16,
) u32 {
    var card_out = card;
    for (list) |pos| {
        const offset = pos >> 6;
        const index: u6 = @truncate(pos & 63);
        const load = words[offset];
        const newload = load ^ (@as(u64, 1) << index);
        const inc: u32 = @truncate(1 -% ((load >> index) & 1) * 2); // avoid branch
        std.debug.assert(inc == math.maxInt(u32) or inc == 1); //  +1 or -1
        card_out +%= inc;
        words[offset] = newload;
    }
    return card_out;
}

/// set word bits from list
pub fn bitset_set_list(
    words: [*]align(C.BLOCK_ALIGN) u64,
    list: []align(C.BLOCK_ALIGN) const u16,
) void {
    if (C.HAS_AVX2) {
        // TODO _asm_bitset_set_list(words, list, length);
    }
    // _scalar_bitset_set_list(words, list, length);
    var offset: u64 = 0;
    var load: u64 = 0;
    var newload: u64 = 0;
    var pos: u64 = 0;
    var index: u6 = 0;
    const end = list.ptr + list.len;
    var list1: [*]const u16 = list.ptr;
    while (list1 != end) {
        pos = list1[0];
        offset = pos >> 6;
        index = @truncate(pos % 64);
        load = words[@intCast(offset)];
        newload = load | @as(u64, 1) << index;
        words[@intCast(offset)] = newload;
        list1 += 1;
    }
}

/// Clear bits at positions in list, return updated cardinality.
pub fn bitset_clear_list(
    words: [*]align(C.BLOCK_ALIGN) u64,
    card: u32,
    list: []align(C.BLOCK_ALIGN) const u16,
) u64 {
    if (C.HAS_AVX2) {
        // TODO _asm_bitset_clear_list
    }
    // _scalar_bitset_clear_list
    var card_out: u64 = card;
    for (list) |pos| {
        const offset = pos >> 6;
        const index: u6 = @truncate(pos & 63);
        const load = words[offset];
        const newload = load & ~(@as(u64, 1) << index);
        card_out -= (load ^ newload) >> index;
        words[offset] = newload;
    }
    return card_out;
}

pub fn bitset_extract_setbits(
    words: [*]align(C.BLOCK_ALIGN) const u64,
    length: u32,
    out: []u32,
    base: u32,
) usize {
    var outpos: u32 = 0;
    var basemut = base;
    for (words[0..length]) |w0| {
        var w = w0;
        while (w != 0) {
            const r = @ctz(w); // on x64, should compile to TZCNT
            out[outpos] = r + basemut;
            outpos += 1;
            w &= (w - 1);
        }
        basemut += 64;
    }
    return outpos;
}

const length_table: [256]u8 = tbl: {
    var tbl: [256]u8 = undefined;
    for (&tbl, 0..) |*e, b| e.* = @popCount(b);
    break :tbl tbl;
};

const vec_decode_table: [256]root.Block32 = tbl: {
    @setEvalBranchQuota(5000);
    var tbl: [256]root.Block32 = undefined;
    for (&tbl, 0..) |*e, b| {
        var v: root.Block32 = @splat(0);
        var lane: u8 = 0;
        for (0..8) |bit| {
            if (b >> bit & 1 != 0) {
                v[lane] = bit + 1; // 1-based
                lane += 1;
            }
        }
        e.* = v;
    }
    break :tbl tbl;
};

pub fn bitset_extract_setbits_avx2(
    words: [*]align(C.BLOCK_ALIGN) const u64,
    wordslen: u32,
    out: [*]u32,
    outlen: u32,
    base: u32,
) usize {
    var outcur = out;
    var base_vec: root.Block32 = @splat(base -% 1);
    const inc_vec: root.Block32 = @splat(64);
    const add8_vec: root.Block32 = @splat(8);
    const safe_out = @intFromPtr(outcur + outlen);
    var i: u32 = 0;
    while (i < wordslen and @intFromPtr(outcur + 64) <= safe_out) : (i += 1) {
        var w = words[i];
        if (w == 0) {
            base_vec +%= inc_vec;
            continue;
        }
        for (0..4) |_| {
            const bytea: u8 = @truncate(w);
            const byteb: u8 = @truncate(w >> 8);
            w >>= 16;

            const veca = base_vec +% vec_decode_table[bytea];
            base_vec +%= add8_vec;
            const vecb = base_vec +% vec_decode_table[byteb];
            base_vec +%= add8_vec;

            outcur[0..8].* = veca;
            outcur += length_table[bytea];
            outcur[0..8].* = vecb;
            outcur += length_table[byteb];
        }
    }

    var base_scalar = base + i * 64;
    while (i < wordslen and @intFromPtr(outcur) < safe_out) : (i += 1) {
        var w = words[i];
        while (w != 0 and @intFromPtr(outcur) < safe_out) {
            outcur[0] = @ctz(w) + base_scalar;
            outcur += 1;
            w &= (w - 1);
        }
        base_scalar += 64;
    }
    return @intCast(outcur - out);
}

pub inline fn cmpBlock(
    a: [*]const u8,
    b: [*]const u8,
) root.BlockMask {
    const ablk: [*]const Block = @ptrCast(@alignCast(a[0..C.BLOCK_SIZE]));
    const bblk: [*]const Block = @ptrCast(@alignCast(b[0..C.BLOCK_SIZE]));
    return @bitCast(ablk[0] == bblk[0]);
}

pub fn memequals(
    a: [*]align(C.BLOCK_ALIGN) const u8,
    b: [*]align(C.BLOCK_ALIGN) const u8,
    n: usize,
) bool {
    if (a == b) return true;

    const B = C.BLOCK_SIZE;
    var i: usize = 0;
    while (i + B * 4 <= n) : (i += B * 4) {
        if (cmpBlock(a + i + B * 0, b + i + B * 0) &
            cmpBlock(a + i + B * 1, b + i + B * 1) &
            cmpBlock(a + i + B * 2, b + i + B * 2) &
            cmpBlock(a + i + B * 3, b + i + B * 3) !=
            math.maxInt(root.BlockMask))
            return false;
    }
    while (i + B * 2 <= n) : (i += B * 2) {
        if (cmpBlock(a + i + B * 0, b + i + B * 0) &
            cmpBlock(a + i + B * 1, b + i + B * 1) !=
            math.maxInt(root.BlockMask))
            return false;
    }
    while (i + B <= n) : (i += B) {
        if (cmpBlock(a + i + B * 0, b + i + B * 0) !=
            math.maxInt(root.BlockMask))
            return false;
    }
    // tail compare
    //
    // TODO remove local Blocks and memcpy.  instead zero block padding when blocks
    // are allocated.
    const tail = n - i;
    assert(tail < B);
    var ablock: Block = @splat(0);
    var bblock: Block = @splat(0);
    const aptr: [*]u8 = @ptrCast(&ablock);
    const bptr: [*]u8 = @ptrCast(&bblock);
    @memcpy(aptr[0..tail], a + i);
    @memcpy(bptr[0..tail], b + i);
    return cmpBlock(aptr, bptr) == std.math.maxInt(root.BlockMask);
}

pub const pshufb =
    if (C.HAS_AVX2 and @import("builtin").zig_backend == .stage2_llvm)
        struct {
            extern fn @"llvm.x86.avx2.pshuf.b"(a: Block, b: Block) Block;
            const pshufb = @"llvm.x86.avx2.pshuf.b";
        }.pshufb
    else if (C.HAS_AVX2)
        pshufb_avx2
    else
        unreachable; // TODO non-llvm, non-avx2

const BlockHalf = @Vector(C.BLOCK_SIZE / 2, u8);
pub const pshufbhalf =
    if (C.HAS_AVX2 and @import("builtin").zig_backend == .stage2_llvm)
        struct {
            extern fn @"llvm.x86.ssse3.pshuf.b.128"(a: BlockHalf, b: BlockHalf) BlockHalf;
            const pshufbhalf = @"llvm.x86.ssse3.pshuf.b.128";
        }.pshufbhalf
    else if (C.HAS_AVX2)
        pshufb_avx2
    else
        unreachable; // TODO non-llvm, non-avx2

inline fn pshufb_avx2(a: anytype, b: anytype) @TypeOf(a) {
    return asm ("vpshufb %[mask], %[src], %[ret]"
        : [ret] "=x" (-> @TypeOf(a)),
        : [src] "x" (a),
          [mask] "x" (b),
    );
}

/// computes absolute differences of u8s and sums them into 64-bit blocks
pub const psadbw =
    if (C.HAS_AVX2 and @import("builtin").zig_backend == .stage2_llvm)
        struct {
            extern fn @"llvm.x86.avx2.psad.bw"(a: Block, b: Block) @Vector(4, u64);
            const psadbw = @"llvm.x86.avx2.psad.bw";
        }.psadbw
    else if (C.HAS_AVX2)
        psadbw_avx2
    else
        unreachable; // TODO non-llvm, non-avx2

inline fn psadbw_avx2(a: Block, b: Block) root.Block64 {
    return asm ("vpsadbw %[src2], %[src1], %[ret]"
        : [ret] "=x" (-> root.Block64),
        : [src1] "x" (a),
          [src2] "x" (b),
    );
}

/// number of groups of `size` in `num`. `size=8 | 0=>0, [1,8]=>1, [9,16]=>2` etc.
///
/// align num forward to `size` and divide by `size`.
///
/// example: `elemscapacity = numGroupsOfSize(capacity*@sizeOf(u16), elem_size)`.
pub fn numGroupsOfSize(
    num: anytype,
    comptime size: anytype,
) std.math.IntFittingRange(0, (math.maxInt(@TypeOf(num)) + size - 1) / size) {
    return @intCast((num + size - 1) / size);
}

test numGroupsOfSize {
    try testing.expectEqual(0, numGroupsOfSize(@as(u8, 0), 8));
    try testing.expectEqual(1, numGroupsOfSize(@as(u8, 1), 8));
    try testing.expectEqual(1, numGroupsOfSize(@as(u8, 8), 8));
    try testing.expectEqual(2, numGroupsOfSize(@as(u8, 9), 8));
    try testing.expectEqual(2, numGroupsOfSize(@as(u8, 16), 8));
}

/// a u8 with t1 in hi nibble, t2 in lo nibble
pub fn pair(t1: root.Typecode, t2: root.Typecode) u8 {
    return @as(u8, @intFromEnum(t1)) << 4 | @intFromEnum(t2);
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
const assert = std.debug.assert;
const root = @import("root.zig");
const C = root.constants;
const Block = root.Block;
const builtin = @import("builtin");
const math = std.math;
