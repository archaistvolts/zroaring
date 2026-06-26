pub const BenchTarget = enum { cr, zr };

fn runBenchmark(allocator: std.mem.Allocator) !void {
    var ser_buf: [1024 * 1024]u8 align(@alignOf(u64)) = undefined;
    switch (build_options.bench_target) {
        .cr => {
            var crs: [fuzz.NUM_BITMAPS][*c]c.roaring_bitmap_t = undefined;
            for (&crs) |*o| o.* = c.roaring_bitmap_create().?;
            defer for (crs) |x| c.roaring_bitmap_free(x);
            for (fuzz.crash_corpus) |ops| {
                for (ops) |op| {
                    try bench.cr_benchmark_op(op, &crs, &ser_buf);
                }
            }
        },
        .zr => {
            std.debug.assert(build_options.bench_target == .zr);
            var zrs: [fuzz.NUM_BITMAPS]Bitmap = @splat(.empty);
            defer for (&zrs) |*x| x.deinit(allocator);
            for (fuzz.crash_corpus) |ops| {
                for (ops) |op| {
                    try bench.zr_benchmark_op(op, &zrs, allocator, &ser_buf);
                }
            }
        },
    }
}

pub fn main() !void {
    const gpa = if (builtin.cpu.arch.isWasm() and !builtin.link_libc)
        std.heap.wasm_allocator
    else
        std.heap.c_allocator;
    try runBenchmark(gpa);
}

const std = @import("std");
const fuzz = @import("fuzz.zig");
const zroaring = @import("root.zig");
const bench = @import("bench.zig");
const Bitmap = zroaring.Bitmap;
const c = @import("croaring");
const builtin = @import("builtin");
const build_options = @import("build-options");
