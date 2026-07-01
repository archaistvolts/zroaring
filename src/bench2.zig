pub const BenchTarget = enum { cr, zr };

fn crDeserialize(r: *std.Io.Reader, cr: *[*c]c.roaring_bitmap_t, _: std.mem.Allocator) !void {
    const size = try r.takeInt(u32, .little);
    if (size != 0) {
        cr.* = c.roaring_bitmap_portable_deserialize_safe((try r.take(size)).ptr, size);
    } else {
        cr.* = c.roaring_bitmap_create();
    }
}

fn zrDeserialize(r: *std.Io.Reader, zrb: *Bitmap, allocator: std.mem.Allocator) !void {
    const size = try r.takeInt(u32, .little);
    if (size != 0) {
        zrb.* = try .portable_deserialize(allocator, try r.take(size));
    } else {
        zrb.* = .empty;
    }
}

fn deserializeOp(
    op: fuzz.Op,
    r: *std.Io.Reader,
    rs: anytype,
    deserializeFn: anytype,
    allocator: std.mem.Allocator,
) !void {
    // deserialize bitmaps needed for op
    switch (op) {
        .clear,
        .run_optimize,
        .shrink_to_fit,
        .portable_serialize,
        .portable_deserialize,
        .frozen_serialize,
        .minimum,
        .maximum,
        .statistics,
        => |idx| try deserializeFn(r, &rs[idx], allocator),
        .add,
        .contains,
        .rank,
        .select,
        => |o| try deserializeFn(r, &rs[o.idx], allocator),
        .add_many,
        => |o| try deserializeFn(r, &rs[o.idx], allocator),
        .add_range_closed,
        .contains_range,
        .range_cardinality,
        .flip,
        => |o| try deserializeFn(r, &rs[o.idx], allocator),
        .remove,
        => |o| try deserializeFn(r, &rs[o.idx], allocator),
        .@"and",
        .@"or",
        .xor,
        .andnot,
        .lazy_or,
        => |o| {
            try deserializeFn(r, &rs[o.idx], allocator);
            try deserializeFn(r, &rs[o.src1], allocator);
            try deserializeFn(r, &rs[o.src2], allocator);
        },
        .or_inplace,
        .is_subset,
        .and_inplace,
        .and_cardinality,
        .or_cardinality,
        .xor_cardinality,
        .andnot_cardinality,
        .jaccard_index,
        .equals,
        => |o| {
            try deserializeFn(r, &rs[o.idx], allocator);
            try deserializeFn(r, &rs[o.src1], allocator);
        },
        .or_many => |o| {
            for (o.idxs) |idx|
                try deserializeFn(r, &rs[idx], allocator);
        },
    }
}

fn runBenchmarkOp(
    io: std.Io,
    allocator: std.mem.Allocator,
    comptime bench_op: []const u8,
    ser_buf: []align(8) u8,
) !void {
    const bench_opts = @import("bench_options");
    const buf = try std.Io.Dir.cwd().readFileAlloc(
        io,
        @field(bench_opts, "corpus_replay_" ++ bench_op ++ "_bin"),
        allocator,
        .unlimited,
    );
    defer allocator.free(buf);
    const vals = try allocator.alloc(u32, 256);
    defer allocator.free(vals);

    var r = std.Io.Reader.fixed(buf);
    _ = try r.takeInt(u32, .little); // skip num_states
    while (r.seek < r.end) {
        const op_len = try r.takeInt(u32, .little);
        const start = r.seek;
        const op = try fuzz.readOp(&r, vals);
        std.debug.assert(std.mem.eql(u8, @tagName(op), bench_op));
        std.debug.assert(r.seek - start == op_len);
        switch (build_options.bench_target) {
            .cr => {
                var crs: [fuzz.NUM_BITMAPS][*c]c.roaring_bitmap_t = @splat(null);
                try deserializeOp(op, &r, &crs, crDeserialize, allocator);
                try bench.cr_benchmark_op(op, &crs, ser_buf);
                inline for (crs) |cr| c.roaring_bitmap_free(cr); // TODO only free op idxs
            },
            .zr => {
                var zrs: [fuzz.NUM_BITMAPS]Bitmap = @splat(.empty);
                try deserializeOp(op, &r, &zrs, zrDeserialize, allocator);
                try bench.zr_benchmark_op(op, &zrs, allocator, ser_buf);
                inline for (&zrs) |*zrb| zrb.deinit(allocator); // TODO only free op idxs
            },
        }
    }
}

// FIXME - this approach reqiures building 2 * #fuzz.Op executables.  need to
// modify gen-corups-playback to write a single file with all ops and a header
// with op offsets.  and then call with `zig-out/bin/bench2 cr add`.
fn runBenchmark(io: std.Io, allocator: std.mem.Allocator) !void {
    var ser_buf: [1024 * 1024]u8 align(zr.constants.BLOCK_ALIGN) = undefined;
    switch (build_options.bench_target) {
        .cr => {
            if (build_options.bench_op) |bench_op| {
                try runBenchmarkOp(io, allocator, bench_op, &ser_buf);
            } else {
                var crs: [fuzz.NUM_BITMAPS][*c]c.roaring_bitmap_t = undefined;
                for (&crs) |*o| o.* = c.roaring_bitmap_create().?;
                defer for (crs) |x| c.roaring_bitmap_free(x);
                for (fuzz.crash_corpus) |ops| {
                    for (ops) |op| {
                        try bench.cr_benchmark_op(op, &crs, &ser_buf);
                    }
                }
            }
        },
        .zr => {
            if (build_options.bench_op) |bench_op| {
                try runBenchmarkOp(io, allocator, bench_op, &ser_buf);
            } else {
                var zrs: [fuzz.NUM_BITMAPS]Bitmap = @splat(.empty);
                defer for (&zrs) |*x| x.deinit(allocator);
                for (fuzz.crash_corpus) |ops| {
                    for (ops) |op| {
                        try bench.zr_benchmark_op(op, &zrs, allocator, &ser_buf);
                    }
                }
            }
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = if (builtin.cpu.arch.isWasm() and !builtin.link_libc)
        std.heap.wasm_allocator
    else
        std.heap.c_allocator;
    try runBenchmark(init.io, gpa);
}

const std = @import("std");
const fuzz = @import("fuzz.zig");
const zr = @import("root.zig");
const bench = @import("bench.zig");
const Bitmap = zr.Bitmap;
const c = @import("croaring");
const builtin = @import("builtin");
const build_options = @import("build-options");
