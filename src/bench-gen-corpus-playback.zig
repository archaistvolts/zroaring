/// write the following format for a given op - little endian.
/// args: <op> <output-path>
///
/// num_states: u32
/// for num_states:
///   op_len: u32                 // length in bytes of this op's encoding
///   op_tag: u8                  // fuzz.Op.Tag
///   op_payload: [*]u8           // payload specific: idx byte(s), u32 values, etc. per writeOp.
///   for NUM_BITMAPS:
///     serialized_size: u32      // roaring_bitmap_portable_size_in_bytes
///     serialized_payload: [*]u8 // bytes from roaring_bitmap_portable_serialize
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next().?;
    const op_name = args.next() orelse {
        std.debug.print("usage: gen-states <op> <output-path>\n", .{});
        std.process.exit(1);
    };
    const output_path = args.next() orelse {
        std.debug.print("usage: gen-states <op> <output-path>\n", .{});
        std.process.exit(1);
    };

    var crs: [NUM_BITMAPS][*c]c.roaring_bitmap_t = undefined;
    for (&crs) |*bm| bm.* = c.roaring_bitmap_create().?;
    defer for (crs) |bm| c.roaring_bitmap_free(bm);

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeInt(u32, 0, .little);

    var num_states: u32 = 0;
    var ser_buf: [1024 * 1024]u8 align(zr.constants.BLOCK_ALIGN) = undefined;
    for (crash_corpus) |ops| {
        for (ops) |op| {
            if (mem.eql(u8, @tagName(op), op_name)) {
                num_states += 1;

                var op_buf: [256]u8 = undefined;
                var fbs = Io.Writer.fixed(&op_buf);
                try fuzz.writeOp(op, &fbs);
                const op_bytes = fbs.buffered();

                try w.writeInt(u32, @intCast(op_bytes.len), .little);
                try w.writeAll(op_bytes);

                // only serialize bitmaps needed for op
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
                    => |idx| try crSerialize(crs[idx], w, &ser_buf),
                    .add,
                    .contains,
                    .rank,
                    .select,
                    => |o| try crSerialize(crs[o.idx], w, &ser_buf),
                    .add_many,
                    => |o| try crSerialize(crs[o.idx], w, &ser_buf),
                    .add_range_closed,
                    .contains_range,
                    .range_cardinality,
                    .flip,
                    => |o| try crSerialize(crs[o.idx], w, &ser_buf),
                    .remove,
                    => |o| try crSerialize(crs[o.idx], w, &ser_buf),
                    .@"and",
                    .@"or",
                    .xor,
                    .andnot,
                    .lazy_or,
                    => |o| {
                        try crSerialize(crs[o.idx], w, &ser_buf);
                        try crSerialize(crs[o.src1], w, &ser_buf);
                        try crSerialize(crs[o.src2], w, &ser_buf);
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
                        try crSerialize(crs[o.idx], w, &ser_buf);
                        try crSerialize(crs[o.src1], w, &ser_buf);
                    },
                    .or_many => |o| {
                        for (o.idxs) |idx|
                            try crSerialize(crs[idx], w, &ser_buf);
                    },
                }
            }

            try @import("bench.zig").cr_benchmark_op(op, &crs, &ser_buf);
        }
    }

    std.mem.writeInt(u32, aw.written()[0..4], num_states, .little);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = aw.written(),
    });
}

fn crSerialize(cr: [*c]c.roaring_bitmap_t, w: *std.Io.Writer, ser_buf: []u8) !void {
    if (cr != null and cr.*.high_low_container.allocation_size == 0) {
        try w.writeInt(u32, 0, .little);
        return;
    }
    const size = c.roaring_bitmap_portable_size_in_bytes(cr);
    try w.writeInt(u32, @intCast(size), .little);
    _ = c.roaring_bitmap_portable_serialize(cr, ser_buf.ptr);
    try w.writeAll(ser_buf[0..size]);
}

const std = @import("std");
const mem = std.mem;
const fuzz = @import("fuzz.zig");
const c = @import("croaring");
const zr = @import("root.zig");
const Io = std.Io;
const crash_corpus: []const []const fuzz.Op = @import("fuzz-crash-corpus.zon");
const NUM_BITMAPS = fuzz.NUM_BITMAPS;
