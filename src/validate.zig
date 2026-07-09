/// build identical bitmaps in zroaring and croaring from values.
/// serialize both, compare bytes. cross deserialize, verify contents.
fn validateRoundTrip(
    allocator: mem.Allocator,
    name: @EnumLiteral(),
    values: []const u32,
    run_optimize: bool,
) !void {
    misc.trace(@src(), "\n\n--  {s}{s} --\n", .{ @tagName(name), if (run_optimize) " +run_optimize" else "" });
    var zr: Bitmap = .empty;
    defer zr.deinit(allocator);
    _ = try zr.add_many(allocator, values);
    var reason: ?[]const u8 = null;
    if (!zr.internal_validate(&reason)) {
        misc.trace(@src(), "validation failed: {s}", .{reason.?});
        misc.trace(@src(), "{f}", .{zr});
        return error.Invalid;
    }

    for (values, 0..) |v, i| {
        testing.expect(zr.contains(v)) catch |e| {
            const key, const val = [2]u16{ @truncate(v >> 16), @truncate(v) };
            misc.trace(@src(), "Bitmap missing value {}:0x{x} hb/lb {}/{}:0x{x}/0x{x}, #containers {} at values index {}", .{ v, v, key, val, key, val, zr.array.len, i });
            misc.trace(@src(), "  keys {}", .{zr.array.len});
            misc.trace(@src(), "  values {} index {}", .{ values.len, zr.get_index(v) });
            misc.trace(@src(), "  zr {f}", .{zr});
            const c1 = zr.array.containers[@intCast(zr.get_index(v))];
            misc.trace(@src(), "  container {}: {f}", .{ zr.get_index(v), c1.fmt(key) });
            return e;
        };
    }
    if (run_optimize) _ = try zr.run_optimize(allocator);

    if (!zr.has_run_container())
        try testing.expectEqual(values.len, zr.get_cardinality());

    // build coaring bitmap
    const cr = c.roaring_bitmap_create().?;
    defer c.roaring_bitmap_free(cr);
    for (values) |v| c.roaring_bitmap_add(cr, v);
    if (run_optimize) _ = c.roaring_bitmap_run_optimize(cr);

    // check size in bytes equal
    const cr_header_size = c.ra_portable_header_size(&cr.*.high_low_container);
    const zr_header_size = zr.portable_header_size();
    try testing.expectEqual(cr_header_size, zr_header_size);
    const zr_size = zr.portable_size_in_bytes();
    const cr_size = c.roaring_bitmap_portable_size_in_bytes(cr);
    try testing.expectEqual(cr_size, zr_size);

    // serialize both
    const zr_serbuf = try allocator.alloc(u8, zr_size);
    defer allocator.free(zr_serbuf);
    var zr_w = std.Io.Writer.fixed(zr_serbuf);
    const cr_serbuf = try allocator.alloc(u8, cr_size);
    defer allocator.free(cr_serbuf);
    var runflags: zroaring.RunFlags = undefined;

    try testing.expectEqual(
        c.roaring_bitmap_portable_serialize(cr, @ptrCast(cr_serbuf.ptr)),
        zr.portable_serialize(&zr_w, &runflags),
    );
    try testing.expectEqualSlices(u8, cr_serbuf, zr_serbuf);

    // deserialize zr bytes with croaring. check equal.
    const cr2 = c.roaring_bitmap_portable_deserialize_safe(@ptrCast(zr_serbuf.ptr), zr_serbuf.len);
    try testing.expect(cr2 != null);
    defer c.roaring_bitmap_free(cr2);
    try testing.expectEqual(c.roaring_bitmap_get_cardinality(cr2), zr.get_cardinality());
    for (values) |v| try testing.expect(c.roaring_bitmap_contains(cr2, v));

    // deserialize croaring bytes with zroaring. check equal.
    var crr = Io.Reader.fixed(cr_serbuf);
    var zr2 = try Bitmap.portable_deserialize_reader(allocator, &crr);
    defer zr2.deinit(allocator);
    try testing.expectEqual(zr2.get_cardinality(), zr.get_cardinality());
    try testing.expect(zr2.equals(zr));

    // compare to cr/zr2 after shrink_to_fit()
    const zrshrink = try zr.shrink_to_fit(allocator);
    const crshrink = c.roaring_bitmap_shrink_to_fit(cr);
    if (false) misc.trace(@src(), "zrshrink={} crshrink={}\n", .{ zrshrink, crshrink });
    zr_w = std.Io.Writer.fixed(zr_serbuf);
    const crlen = c.roaring_bitmap_portable_serialize(cr, @ptrCast(cr_serbuf.ptr));
    try testing.expectEqual(crlen, zr.portable_serialize(&zr_w, &runflags));
    try testing.expectEqualSlices(u8, cr_serbuf[0..crlen], zr_serbuf[0..crlen]);
    try testing.expect(zr2.equals(zr));

    try validateMisc(allocator, zr, cr);
}

/// Validate using addRange instead of individual adds.
fn validateRangeRoundTrip(
    allocator: mem.Allocator,
    name: @EnumLiteral(),
    start: u32,
    end: u32,
    run_optimize: bool,
) !void {
    misc.trace(@src(), "\n\n--  {s}{s} --\n", .{ @tagName(name), if (run_optimize) " +run_optimize" else "" });
    // build both
    const cr = c.roaring_bitmap_create() orelse return error.CRoaringAllocFailed;
    defer c.roaring_bitmap_free(cr);
    c.roaring_bitmap_add_range(cr, start, @as(u64, end) + 1);
    const cr_did_optimize = run_optimize and c.roaring_bitmap_run_optimize(cr);

    var zr: Bitmap = .empty;
    defer zr.deinit(allocator);
    try Bitmap.add_range(&zr, allocator, start, @as(u64, end) + 1);
    misc.trace(@src(), "{s}: after add_range({},{}) zr {f}", .{ @tagName(name), start, end + 1, zr });
    const zr_did_optimize = run_optimize and try zr.run_optimize(allocator);

    // serialize both
    const cr_size = c.roaring_bitmap_portable_size_in_bytes(cr);
    // misc.trace(@src(), "ra_portable_header_size()={}", .{c.ra_portable_header_size(&cr.*.high_low_container)});
    const cr_buf = try allocator.alloc(u8, cr_size);
    defer allocator.free(cr_buf);

    const zr_size = zr.portable_size_in_bytes();
    const zr_buf = try allocator.alloc(u8, zr_size);
    defer allocator.free(zr_buf);
    var zr_w: std.Io.Writer = .fixed(zr_buf);
    var runflags: zroaring.RunFlags = undefined;
    _ = try zr.portable_serialize(&zr_w, &runflags);

    _ = c.roaring_bitmap_portable_serialize(cr, @ptrCast(cr_buf.ptr));
    try testing.expectEqual(cr_did_optimize, zr_did_optimize);
    try testing.expectEqual(cr_size, zr_size);
    try testing.expectEqualSlices(u8, cr_buf, zr_buf);

    // deserialize zr bytes with croaring
    const cr2 = c.roaring_bitmap_portable_deserialize_safe(@ptrCast(zr_buf.ptr), zr_size);
    try testing.expect(cr2 != null);
    defer c.roaring_bitmap_free(cr2);
    try testing.expectEqual(c.roaring_bitmap_get_cardinality(cr2), zr.get_cardinality());

    // deserialize croaring bytes with zr
    var crr = Io.Reader.fixed(cr_buf);
    var zr2 = try Bitmap.portable_deserialize_reader(allocator, &crr);
    defer zr2.deinit(allocator);
    try testing.expect(zr.equals(zr2));

    try validateMisc(allocator, zr, cr);
}

/// Validate FrozenBitmap can read serialized bytes and contains() works correctly.
fn validateFrozenContains(allocator: mem.Allocator, name: @EnumLiteral(), values: []const u32, run_optimize: bool) !void {
    misc.trace(@src(), "\n\n--  {s}{s} --\n", .{ @tagName(name), if (run_optimize) " +run_optimize" else "" });

    // Build both and serialize frozen
    const cr = c.roaring_bitmap_create();
    defer c.roaring_bitmap_free(cr);
    c.roaring_bitmap_add_many(cr, values.len, values.ptr);
    if (run_optimize) _ = c.roaring_bitmap_run_optimize(cr);
    const cr_frozen_buf = try allocator.alloc(u8, c.roaring_bitmap_frozen_size_in_bytes(cr));
    defer allocator.free(cr_frozen_buf);
    c.roaring_bitmap_frozen_serialize(cr, cr_frozen_buf.ptr);
    // std.debug.print("{s} cr_frozen_size {}\n", .{ name, cr_frozen_size });

    var zr: Bitmap = .empty;
    defer zr.deinit(allocator);
    _ = try zr.add_many(allocator, values);
    if (run_optimize) _ = try zr.run_optimize(allocator);
    const zr_frozen_buf = try allocator.alignedAlloc(u8, zroaring.constants.BLOCK_ALIGNMENT, zr.frozen_size_in_bytes());
    defer allocator.free(zr_frozen_buf);
    try zr.frozen_serialize(zr_frozen_buf);
    try testing.expectEqualSlices(u8, cr_frozen_buf, zr_frozen_buf);

    var zr_frozen = try Bitmap.frozen_view(allocator, zr_frozen_buf);
    defer zr_frozen.deinit(allocator);
    for (values) |v| try testing.expect(zr_frozen.contains(v));
    try testing.expect(zr.equals(zr_frozen));
}

fn validateMisc(allocator: mem.Allocator, zr: Bitmap, cr: [*c]c.roaring_bitmap_t) !void {
    // to_uint32_array
    const len: usize = @intCast(zr.get_cardinality());
    const crbuf = try allocator.alloc(u32, len);
    defer allocator.free(crbuf);
    c.roaring_bitmap_to_uint32_array(cr, crbuf.ptr);

    const zrbuf = try allocator.alloc(u32, len);
    defer allocator.free(zrbuf);
    zr.to_uint32_array(zrbuf);

    try testing.expectEqualSlices(u32, crbuf, zrbuf);
    // end to_uint32_array
}

const testio = testing.io;

fn validateAll(allocator: mem.Allocator) !void {
    // if (!@import("build-options").with_croaring) return;
    // Basic tests:
    try validateRoundTrip(allocator, .empty, &.{}, false);
    try validateRoundTrip(allocator, .single_zero, &.{0}, false);
    try validateRoundTrip(allocator, .single_max, &.{0xFFFFFFFF}, false);
    try validateRoundTrip(allocator, .single_mid, &.{1000000}, false);

    // Array container tests:
    var arr100: [100]u32 = undefined; // Small array
    for (0..100) |i| arr100[i] = @intCast(i * 10);
    try validateRoundTrip(allocator, .array_100, &arr100, false);
    var arr4096: [4096]u32 = undefined; // Array at threshold (4096 = max array size)
    for (0..4096) |i| arr4096[i] = @intCast(i);
    try validateRoundTrip(allocator, .array_4096, &arr4096, false);

    // Bitset container tests:
    var bitset5000: [5000]u32 = undefined; // Just over threshold -> bitset
    for (0..5000) |i| bitset5000[i] = @intCast(i);
    try validateRoundTrip(allocator, .bitset_5000, &bitset5000, false);

    // Full chunk as run (65536 values) - CRoaring auto-optimizes to run, so we must too
    // (This tests run serialization, not bitset - renamed to avoid confusion)
    try validateRangeRoundTrip(allocator, .run_full_chunk, 0, 65535, true);

    // Multiple container tests:
    // Values at chunk boundaries
    try validateRoundTrip(allocator, .chunk_boundaries, &.{ 65535, 65536, 131071, 131072 }, false);
    // 3 containers (below NO_OFFSET_THRESHOLD for run format)
    var three_containers: [3]u32 = .{ 100, 65536 + 100, 131072 + 100 };
    try validateRoundTrip(allocator, .three_containers, &three_containers, false);
    // 4 containers (at NO_OFFSET_THRESHOLD)
    var four_containers: [4]u32 = .{ 100, 65536 + 100, 131072 + 100, 196608 + 100 };
    try validateRoundTrip(allocator, .four_containers, &four_containers, false);
    // 5+ containers
    var five_containers: [5]u32 = .{ 100, 65536 + 100, 131072 + 100, 196608 + 100, 262144 + 100 };
    try validateRoundTrip(allocator, .five_containers, &five_containers, false);

    // Run-optimized tests:
    // Range that compresses well
    try validateRangeRoundTrip(allocator, .range_0_1000, 0, 1000, true);
    try validateRangeRoundTrip(allocator, .range_0_10000, 0, 10000, true);
    // Multiple ranges -> multiple runs
    var multi_range: [300]u32 = undefined;
    for (0..100) |i| {
        multi_range[i] = @intCast(i); // 0-99
        multi_range[100 + i] = @intCast(500 + i); // 500-599
        multi_range[200 + i] = @intCast(1000 + i); // 1000-1099
    }
    try validateRoundTrip(allocator, .multi_range_runs, &multi_range, true);
    // Alternating values (doesn't compress to runs)
    var alternating: [100]u32 = undefined;
    for (0..100) |i| alternating[i] = @intCast(i * 2); // 0, 2, 4, 6...
    try validateRoundTrip(allocator, .alternating_no_runs, &alternating, true);

    // 4+ containers with run_optimize - exercises run format WITH offset header
    // (NO_OFFSET_THRESHOLD = 4, so this triggers offset header in run format)
    var four_chunks_runs: [400]u32 = undefined;
    for (0..100) |i| four_chunks_runs[i] = @intCast(i); // chunk 0: 0-99
    for (0..100) |i| four_chunks_runs[100 + i] = @intCast(65536 + i); // chunk 1
    for (0..100) |i| four_chunks_runs[200 + i] = @intCast(131072 + i); // chunk 2
    for (0..100) |i| four_chunks_runs[300 + i] = @intCast(196608 + i); // chunk 3
    try validateRoundTrip(allocator, .four_chunks_runs, &four_chunks_runs, true);

    // Large scale tests:
    // Dense range (1M values) - CRoaring auto-optimizes ranges, so we must too
    try validateRangeRoundTrip(allocator, .dense_1M, 0, 999999, true);

    // Sparse random (N values across u17 space)
    const N = 100_000;
    var prng = std.Random.DefaultPrng.init(0);
    var set = std.AutoArrayHashMapUnmanaged(u32, void).empty;
    defer set.deinit(testing.allocator);
    try set.ensureTotalCapacity(testing.allocator, N);
    for (0..N) |_| {
        set.putAssumeCapacity(prng.random().int(u17), {});
    }
    try validateRoundTrip(allocator, .sparse_N, set.keys(), false);

    // validate frozen_view can read serialized bytes correctly
    try validateFrozenContains(allocator, .frozen_array, &arr100, false);
    try validateFrozenContains(allocator, .frozen_bitset, &bitset5000, false);
    try validateFrozenContains(allocator, .frozen_run_single_chunk, &multi_range, true);
    try validateFrozenContains(allocator, .frozen_run_with_offsets, &four_chunks_runs, true);
    try validateFrozenContains(allocator, .frozen_multi_container, &five_containers, false);
}

const testgpa = testing.allocator;

test validateAll {
    try validateAll(testgpa);
}

test "allocation failures" {
    if (!@import("build-options").run_slow_tests) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(testgpa, validateAll, .{});
}

fn validateTestdata(io: Io, filepath: []const u8) !void {
    const f = try Io.Dir.cwd().openFile(io, filepath, .{});
    defer f.close(io);
    var rbuf: [256]u8 = undefined;
    var r = try Bitmap.portable_deserialize_file(testgpa, io, f, &rbuf);
    defer r.deinit(testgpa);

    // > That is, they contain all multiplies of 1000 in [0,100000), all multiplies of 3 in [100000,200000) and all values in [700000,800000).
    // > https://github.com/RoaringBitmap/RoaringFormatSpec/tree/master/testdata
    var k: u32 = 0;
    while (k < 100000) : (k += 1000) {
        testing.expect(r.contains(k)) catch |e| {
            std.debug.print("missing {}\n", .{k});
            std.debug.print("{f}\n", .{r});
            return e;
        };
    }

    k = 100000;
    while (k < 200000) : (k += 1)
        try testing.expect(r.contains(3 * k));

    k = 700000;
    while (k < 800000) : (k += 1)
        try testing.expect(r.contains(k));
}

test "without runs" {
    try validateTestdata(testing.io, "testdata/bitmapwithoutruns.bin");
}

test "with runs" {
    try validateTestdata(testing.io, "testdata/bitmapwithruns.bin");
}

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const testing = std.testing;
const zroaring = @import("root.zig");
const Bitmap = zroaring.Bitmap;
const c = @import("croaring");
const misc = @import("misc.zig");
