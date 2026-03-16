/// build identical bitmaps in zroaring and croaring from values.
/// serialize both, compare bytes. cross deserialize, verify contents.
fn validateRoundTrip(arena: mem.Allocator, name: []const u8, values: []const u32, run_optimize: bool) !void {
    _ = name;

    // build zroaring bitmap
    var zr: Bitmap = .{};
    defer zr.deinit(arena);
    for (values) |v| try zr.add(arena, v);
    if (run_optimize) _ = try zr.run_optimize(arena);
    // std.debug.print("zr {any}\n", .{zr});
    // std.debug.print("{s} zr {f}\n", .{ name, zr });
    try testing.expectEqual(values.len, zr.get_cardinality());

    // build coaring bitmap
    const cr = c.roaring_bitmap_create().?;
    defer c.roaring_bitmap_free(cr);
    for (values) |v| c.roaring_bitmap_add(cr, v);
    if (run_optimize) _ = c.roaring_bitmap_run_optimize(cr);

    // check size in bytes equal
    const zr_header_size = zr.high_low_container.portable_header_size();
    const cr_header_size = c.ra_portable_header_size(&cr.*.high_low_container);
    try testing.expectEqual(cr_header_size, zr_header_size);
    const zr_size = zr.portable_size_in_bytes();
    const cr_size = c.roaring_bitmap_portable_size_in_bytes(cr);
    try testing.expectEqual(cr_size, zr_size);

    // serialize both
    const zr_buf = try arena.alloc(u8, zr_size);
    defer arena.free(zr_buf);
    var zr_w = std.Io.Writer.fixed(zr_buf);
    const cr_buf = try arena.alloc(u8, cr_size);
    defer arena.free(cr_buf);
    try testing.expectEqual(
        c.roaring_bitmap_portable_serialize(cr, @ptrCast(cr_buf.ptr)),
        zr.portable_serialize(&zr_w),
    );
    try testing.expectEqualSlices(u8, cr_buf, zr_buf);

    // deserialize zr bytes with croaring. check equal.
    const cr2 = c.roaring_bitmap_portable_deserialize_safe(@ptrCast(zr_buf.ptr), zr_buf.len);
    try testing.expect(cr2 != null);
    defer c.roaring_bitmap_free(cr2);
    try testing.expectEqual(c.roaring_bitmap_get_cardinality(cr2), zr.get_cardinality());
    for (values) |v| try testing.expect(c.roaring_bitmap_contains(cr2, v));

    // deserialize croaring bytes with zroaring. check equal.
    var cr_r = std.Io.Reader.fixed(cr_buf);
    var zr2 = try Bitmap.portable_deserialize(arena, &cr_r);
    defer zr2.deinit(arena);
    // std.debug.print("zr2 {f}\n", .{zr2});
    // std.debug.print("zr2 {} zr {any}\n", .{ zr, zr2, cr_buf.len, zr });
    // std.debug.print("zr2 card {} zr card {}\n", .{ zr2.get_cardinality(), zr.get_cardinality() });
    try testing.expectEqual(zr2.get_cardinality(), zr.get_cardinality());
    try testing.expect(zr2.equals(zr));
    // std.debug.print("  PASS: {s}{s} ({d} values, {d} bytes)\n", .{ name, if (run_optimize) " [run-optimized]" else "", values.len, zr_buf.len });
}

/// Validate using addRange instead of individual adds.
fn validateRangeRoundTrip(allocator: mem.Allocator, name: []const u8, start: u32, end: u32, run_optimize: bool) !void {
    _ = name;
    // build both
    var zr: Bitmap = .{};
    defer zr.deinit(allocator);
    try zr.add_range(allocator, start, end);
    if (run_optimize) _ = try zr.run_optimize(allocator);

    const cr = c.roaring_bitmap_create() orelse return error.CRoaringAllocFailed;
    defer c.roaring_bitmap_free(cr);
    c.roaring_bitmap_add_range(cr, start, @as(u64, end) + 1);
    if (run_optimize) _ = c.roaring_bitmap_run_optimize(cr);

    // serialize both
    const cr_size = c.roaring_bitmap_portable_size_in_bytes(cr);
    const buf = try allocator.alloc(u8, cr_size);
    defer allocator.free(buf);
    const zr_size = zr.portable_size_in_bytes();
    const zr_buf = try allocator.alloc(u8, zr_size);
    defer allocator.free(zr_buf);
    var zr_w: std.Io.Writer = .fixed(zr_buf);
    _ = try zr.portable_serialize(&zr_w);
    const cr_buf = try allocator.alloc(u8, cr_size);
    defer allocator.free(cr_buf);
    _ = c.roaring_bitmap_portable_serialize(cr, @ptrCast(cr_buf.ptr));
    try testing.expectEqualSlices(u8, cr_buf, zr_buf);

    // deserialize zr bytes with croaring
    const cr2 = c.roaring_bitmap_portable_deserialize_safe(@ptrCast(zr_buf.ptr), zr_size);
    try testing.expect(cr2 != null);
    defer c.roaring_bitmap_free(cr2);
    try testing.expectEqual(c.roaring_bitmap_get_cardinality(cr2), zr.get_cardinality());

    // deserialize croaring bytes with zr
    var zr2 = Bitmap.portable_deserialize_safe(cr_buf);
    defer zr2.deinit(allocator);
    try testing.expect(zr.equals(zr2));

    // const suffix = if (run_optimize) " [run-optimized]" else "";
    // std.debug.print("  PASS: {s}{s} ({d} values, {d} bytes)\n", .{ name, suffix, end - start + 1, zr_size });
}
const FrozenBitmap = struct {};
/// Validate FrozenBitmap can read serialized bytes and contains() works correctly.
fn validateFrozenContains(allocator: mem.Allocator, name: []const u8, values: []const u32, run_optimize: bool) !void {
    _ = name;
    if (true) unreachable; // TODO
    // Build both and serialize
    var zr: Bitmap = .{};
    defer zr.deinit(allocator);
    for (values) |v| _ = try zr.add(v);
    if (run_optimize) _ = try zr.runOptimize();

    const cr_size = zr.portable_size_in_bytes();
    const zr_bytes = try allocator.alloc(u8, cr_size);
    defer allocator.free(zr_bytes);
    try zr.portable_serialize_safe(zr_bytes);

    // wrap in FrozenBitmap and verify contains
    const frozen = try FrozenBitmap.init(zr_bytes);

    try testing.expectEqual(zr.cardinality(), frozen.cardinality());

    // Check all values are present
    for (values) |v| {
        if (!frozen.contains(v)) {
            // std.debug.print("FAIL: {s} - FrozenBitmap missing value {d}\n", .{ name, v });
            return error.MissingValue;
        }
    }

    // Spot check some values that should NOT be present
    const absent_values = [_]u32{ 0xDEADBEEF, 0xCAFEBABE, 0x12345678 };
    for (absent_values) |v| {
        // Only check if the value wasn't in our input

        const found = for (values) |input_v| {
            if (input_v == v) break true;
        } else false;
        if (!found and frozen.contains(v)) {
            // std.debug.print("FAIL: {s} - FrozenBitmap false positive for {d}\n", .{ name, v });
            return error.FalsePositive;
        }
    }

    // const suffix = if (run_optimize) " [run-optimized]" else "";
    // std.debug.print("  PASS: {s}{s} (FrozenBitmap, {d} values)\n", .{ name, suffix, values.len });
}

pub fn validate() !void {
    const allocator = testing.allocator;
    // Basic tests:
    try validateRoundTrip(allocator, "empty", &.{}, false);
    try validateRoundTrip(allocator, "single_zero", &.{0}, false);
    try validateRoundTrip(allocator, "single_max", &.{0xFFFFFFFF}, false);
    try validateRoundTrip(allocator, "single_mid", &.{1000000}, false);

    // Array container tests:
    var arr100: [100]u32 = undefined; // Small array
    for (0..100) |i| arr100[i] = @intCast(i * 10);
    try validateRoundTrip(allocator, "array_100", &arr100, false);
    var arr4096: [4096]u32 = undefined; // Array at threshold (4096 = max array size)
    for (0..4096) |i| arr4096[i] = @intCast(i);
    try validateRoundTrip(allocator, "array_4096", &arr4096, false);

    // Bitset container tests:
    var bitset5000: [5000]u32 = undefined; // Just over threshold -> bitset
    for (0..5000) |i| bitset5000[i] = @intCast(i);
    try validateRoundTrip(allocator, "bitset_5000", &bitset5000, false);

    if (true) return;

    // Full chunk as run (65536 values) - CRoaring auto-optimizes to run, so we must too
    // (This tests run serialization, not bitset - renamed to avoid confusion)
    try validateRangeRoundTrip(allocator, "run_full_chunk", 0, 65535, true);

    // Multiple container tests:
    // Values at chunk boundaries
    try validateRoundTrip(allocator, "chunk_boundaries", &.{ 65535, 65536, 131071, 131072 }, false);
    // 3 containers (below NO_OFFSET_THRESHOLD for run format)
    var three_containers: [3]u32 = .{ 100, 65536 + 100, 131072 + 100 };
    try validateRoundTrip(allocator, "three_containers", &three_containers, false);
    // 4 containers (at NO_OFFSET_THRESHOLD)
    var four_containers: [4]u32 = .{ 100, 65536 + 100, 131072 + 100, 196608 + 100 };
    try validateRoundTrip(allocator, "four_containers", &four_containers, false);
    // 5+ containers
    var five_containers: [5]u32 = .{ 100, 65536 + 100, 131072 + 100, 196608 + 100, 262144 + 100 };
    try validateRoundTrip(allocator, "five_containers", &five_containers, false);

    // Run-optimized tests:
    // Range that compresses well
    try validateRangeRoundTrip(allocator, "range_0_1000", 0, 1000, true);
    try validateRangeRoundTrip(allocator, "range_0_10000", 0, 10000, true);
    // Multiple ranges -> multiple runs
    var multi_range: [300]u32 = undefined;
    for (0..100) |i| multi_range[i] = @intCast(i); // 0-99
    for (0..100) |i| multi_range[100 + i] = @intCast(500 + i); // 500-599
    for (0..100) |i| multi_range[200 + i] = @intCast(1000 + i); // 1000-1099
    try validateRoundTrip(allocator, "multi_range_runs", &multi_range, true);
    // Alternating values (doesn't compress to runs)
    var alternating: [100]u32 = undefined;
    for (0..100) |i| alternating[i] = @intCast(i * 2); // 0, 2, 4, 6...
    try validateRoundTrip(allocator, "alternating_no_runs", &alternating, true);
    // 4+ containers with run_optimize - exercises run format WITH offset header
    // (NO_OFFSET_THRESHOLD = 4, so this triggers offset header in run format)
    var four_chunks_runs: [400]u32 = undefined;
    for (0..100) |i| four_chunks_runs[i] = @intCast(i); // chunk 0: 0-99
    for (0..100) |i| four_chunks_runs[100 + i] = @intCast(65536 + i); // chunk 1
    for (0..100) |i| four_chunks_runs[200 + i] = @intCast(131072 + i); // chunk 2
    for (0..100) |i| four_chunks_runs[300 + i] = @intCast(196608 + i); // chunk 3
    try validateRoundTrip(allocator, "four_chunks_run_optimized", &four_chunks_runs, true);

    // Large scale tests:
    // Dense range (1M values) - CRoaring auto-optimizes ranges, so we must too
    try validateRangeRoundTrip(allocator, "dense_1M", 0, 999999, true);
    // Sparse random (500K values across u32 space)
    var prng = std.Random.DefaultPrng.init(12345);
    var sparse_500k: [500000]u32 = undefined;
    for (0..500000) |i| sparse_500k[i] = prng.random().int(u32);

    // Sort and dedupe for consistent results
    std.mem.sort(u32, &sparse_500k, {}, std.sort.asc(u32));
    var deduped_len: usize = 1;
    for (1..500000) |i| {
        if (sparse_500k[i] != sparse_500k[deduped_len - 1]) {
            sparse_500k[deduped_len] = sparse_500k[i];
            deduped_len += 1;
        }
    }
    try validateRoundTrip(allocator, "sparse_500k", sparse_500k[0..deduped_len], false);
    // Gap 1 fix: validate FrozenBitmap can read serialized bytes correctly
    // FrozenBitmap tests:
    // Array container
    try validateFrozenContains(allocator, "frozen_array", &arr100, false);
    // Bitset container
    try validateFrozenContains(allocator, "frozen_bitset", &bitset5000, false);
    // Run container (single chunk)
    try validateFrozenContains(allocator, "frozen_run_single", &multi_range, true);
    // Run container with offset header (4+ chunks)
    try validateFrozenContains(allocator, "frozen_run_with_offsets", &four_chunks_runs, true);
    // Multiple containers without run optimize
    try validateFrozenContains(allocator, "frozen_multi_container", &five_containers, false);
}

test validate {
    try validate();
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const zroaring = @import("root.zig");
const Bitmap = zroaring.Bitmap;

const c = @cImport({
    // @cDefine("CROARING_COMPILER_SUPPORTS_AVX512", "0");
    // @cDefine("CROARING_ATOMIC_IMPL_NONE", "");
    // @cInclude("c/roaring.h");
    @cInclude("c/roaring-subset.h");
});
