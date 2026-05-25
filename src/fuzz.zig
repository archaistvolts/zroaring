//! TODO maybe get rid of hashMapOracle and use croaringOracle everywhere.
//! It was added to work around fuzzer croaring undefined symbol issues.

export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(dataptr: [*]const u8, size: usize) void {
    zig_fuzz_test1(dataptr[0..size]) catch unreachable;
}

fn zig_fuzz_test1(in: []const u8) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer assert(gpa.detectLeaks() == 0);
    _ = in;
    unreachable; // TODO
    // try croaringOracle(in, gpa.allocator());
}

test "std.HashMap oracle" {
    const Context = struct {
        fn testOne(_: @This(), smith: *testing.Smith) anyerror!void {
            try hashMapOracle(smith, testing.allocator);
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

test "croaring oracle" {
    const Context = struct {
        fn testOne(_: @This(), smith: *testing.Smith) anyerror!void {
            try croaringOracle(smith, testing.allocator);
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

test "std.HashMap oracle crash" {
    const io = testing.io;
    const contents = std.Io.Dir.cwd().readFileAlloc(io, ".zig-cache/f/crash", testing.allocator, .unlimited) catch return;
    defer testing.allocator.free(contents);
    var smith = testing.Smith{ .in = contents };
    try hashMapOracle(&smith, testing.allocator);
}

pub const FuzzOp = union(enum) {
    add: u32,
    add_many: []const u32,
    add_range_closed: [2]u32,
    remove: u32,
    contains: u32,
    contains_many: []const u32,
    get_cardinality: u64,
    clear,

    pub const Tag = std.meta.Tag(FuzzOp);
};

/// provider may be a `*testing.Smith` or a `std.Random`
fn getvals(provider: anytype, vals: anytype) u8 {
    const valFn = if (@TypeOf(provider) == *testing.Smith)
        testing.Smith.valueRangeLessThan
    else if (@TypeOf(provider) == std.Random)
        std.Random.intRangeLessThan
    else
        unreachable;
    const len = valFn(provider, u8, 1, vals.len);

    for (0..len) |i| vals[i] = valFn(provider, u32, 0, 100_000);
    return len;
}

// TODO remove, reuse perform_op
fn hashMapOracle(smith: *testing.Smith, allocator: mem.Allocator) !void {
    var r = zroaring.Bitmap.empty;
    defer r.deinit(allocator);
    var oracle = std.AutoHashMapUnmanaged(u32, void).empty;
    defer oracle.deinit(allocator);
    fuzzprint("\n\n-- init --\n", .{});

    while (!smith.eos()) {
        const op = smith.value(FuzzOp.Tag);
        fuzzprint(".{{ .{t} = ", .{op});
        switch (op) {
            .add => {
                const val = smith.valueRangeLessThan(u32, 0, 100_000);
                fuzzprint("{} }},\n", .{val});
                try r.add(allocator, val);
                try oracle.put(allocator, val, {});
            },
            .add_many => {
                var vals: [8]u32 = undefined;
                const len = getvals(smith, &vals);
                fuzzprint("&.{{ ", .{});
                for (vals[0..len], 0..) |val, i| {
                    if (i != 0) fuzzprint(", ", .{});
                    fuzzprint("{}", .{val});
                }
                fuzzprint(" }} }},\n", .{});
                _ = try r.add_many(allocator, vals[0..len]);
                try oracle.ensureUnusedCapacity(allocator, len);
                for (vals[0..len]) |val| oracle.putAssumeCapacity(val, {});
            },
            .add_range_closed => {
                const start = smith.valueRangeLessThan(u32, 0, 16000);
                const val1 = smith.valueRangeLessThan(u32, start, start + 100);
                const val2 = smith.valueRangeLessThan(u32, start + 100, start + 200);
                fuzzprint(".{{ {}, {} }} }},\n", .{ val1, val2 });
                try r.add_range_closed(allocator, val1, val2);
                try oracle.ensureUnusedCapacity(allocator, val2 + 1 - val1);
                var x = val1;
                while (x <= val2) : (x += 1) oracle.putAssumeCapacity(x, {});
            },
            .remove => {
                const val = smith.valueRangeLessThan(u32, 0, 100_000);
                fuzzprint("{} }},\n", .{val});
                try std.testing.expectEqual(
                    oracle.remove(val),
                    try r.remove_checked(allocator, val),
                );
            },
            .contains => {
                const val = smith.valueRangeLessThan(u32, 0, 100_000);
                fuzzprint("{} }},\n", .{val});
                try std.testing.expectEqual(oracle.contains(val), r.contains(val));
            },
            .contains_many => {
                var vals: [8]u32 = undefined;
                const len = getvals(smith, &vals);
                fuzzprint("&.{{ ", .{});
                for (vals[0..len], 0..) |val, i| {
                    if (i != 0) fuzzprint(", ", .{});
                    fuzzprint("{}", .{val});
                }
                fuzzprint(" }} }},\n", .{});
                for (vals[0..len]) |val|
                    try std.testing.expectEqual(oracle.contains(val), r.contains(val));
            },
            .clear => {
                fuzzprint("{{}} }},\n", .{});
                r.clear_retaining_capacity();
                oracle.clearRetainingCapacity();
            },
            .get_cardinality => {
                fuzzprint("{} }},\n", .{oracle.count()});
                try std.testing.expectEqual(oracle.count(), r.get_cardinality());
            },
        }
        // for (r.array.ptr(.containers)[0..r.array.ptr(.len).*]) |c| {
        //     fuzzprint("{f}\n", .{c.fmt(r)});
        // }
        // fuzzprint("counts={},{}\n", .{ oracle.count(), r.cardinality() });
        try std.testing.expectEqual(oracle.count(), r.cardinality());
    }
}

const FuzzPrng = struct {
    input: []const u8,
    pos: usize = 0,

    pub fn init(input: []const u8) FuzzPrng {
        return .{ .input = input };
    }

    pub fn random(self: *FuzzPrng) std.Random {
        return .{ .ptr = self, .fillFn = fill };
    }

    pub fn eos(self: FuzzPrng) bool {
        return self.pos >= self.input.len;
    }

    fn fill(ptr: *anyopaque, buf: []u8) void {
        const self: *FuzzPrng = @ptrCast(@alignCast(ptr));
        const remaining = self.input.len - self.pos;
        const to_copy = @min(buf.len, remaining);

        if (to_copy > 0) {
            @memcpy(buf[0..to_copy], self.input[self.pos .. self.pos + to_copy]);
            self.pos += to_copy;
        }

        // not enough bytes, pad with zeros to avoid uninitialized memory.
        if (to_copy < buf.len) {
            @memset(buf[to_copy..], 0);
        }
    }
};

// TODO remove, reuse perform_op
fn croaringOracle(smith: *testing.Smith, allocator: mem.Allocator) !void {
    var r = zroaring.Bitmap.empty;
    defer r.deinit(allocator);

    const oracle = c.roaring_bitmap_create().?;
    defer c.roaring_bitmap_free(oracle);

    fuzzprint("\n\n-- init --\n", .{});

    while (!smith.eos()) {
        const op = smith.value(FuzzOp.Tag);
        fuzzprint(".{{ .{t} = ", .{op});
        switch (op) {
            .add => {
                const val = smith.valueRangeLessThan(u32, 0, 100_000);
                fuzzprint("{} }},\n", .{val});
                try r.add(allocator, val);
                c.roaring_bitmap_add(oracle, val);
            },
            .add_many => {
                var vals: [8]u32 = undefined;
                const len = getvals(smith, &vals);
                fuzzprint("&.{{ ", .{});
                for (vals[0..len], 0..) |val, i| {
                    if (i != 0) fuzzprint(", ", .{});
                    fuzzprint("{}", .{val});
                }
                fuzzprint(" }} }},\n", .{});
                _ = try r.add_many(allocator, vals[0..len]);
                c.roaring_bitmap_add_many(oracle, len, &vals);
            },
            .add_range_closed => {
                const start = smith.valueRangeLessThan(u32, 0, 16000);
                const val1 = smith.valueRangeLessThan(u32, start, start + 100);
                const val2 = smith.valueRangeLessThan(u32, start + 100, start + 200);
                fuzzprint(".{{ {}, {} }} }},\n", .{ val1, val2 });
                try r.add_range_closed(allocator, val1, val2);
                c.roaring_bitmap_add_range_closed(oracle, val1, val2);
            },
            .remove => {
                const val = smith.valueRangeLessThan(u32, 0, 100_000);
                fuzzprint("{} }},\n", .{val});
                try std.testing.expectEqual(
                    c.roaring_bitmap_remove_checked(oracle, val),
                    try r.remove_checked(allocator, val),
                );
            },
            .contains => {
                const val = smith.valueRangeLessThan(u32, 0, 100_000);
                fuzzprint("{} }},\n", .{val});
                try std.testing.expectEqual(
                    c.roaring_bitmap_contains(oracle, val),
                    r.contains(val),
                );
            },
            .contains_many => { // TODO contains_many
                var vals: [8]u32 = undefined;
                const len = getvals(smith, &vals);
                fuzzprint("&.{{ ", .{});
                for (vals[0..len], 0..) |val, i| {
                    if (i != 0) fuzzprint(", ", .{});
                    fuzzprint("{}", .{val});
                }
                fuzzprint(" }} }},\n", .{});
                for (vals[0..len]) |val|
                    try std.testing.expectEqual(c.roaring_bitmap_contains(oracle, val), r.contains(val));
            },
            .clear => {
                fuzzprint("{{}} }},\n", .{});
                r.clear_retaining_capacity();
                c.roaring_bitmap_clear(oracle);
            },
            .get_cardinality => {
                fuzzprint("{} }},\n", .{c.roaring_bitmap_get_cardinality(oracle)});
                try std.testing.expectEqual(c.roaring_bitmap_get_cardinality(oracle), r.get_cardinality());
            },
        }
        // for (r.array.ptr(.containers)[0..r.array.ptr(.len).*]) |c| {
        //     fuzzprint("{f}\n", .{c.fmt(r)});
        // }
        // fuzzprint("counts={},{}\n", .{ oracle.count(), r.cardinality() });
        try std.testing.expectEqual(c.roaring_bitmap_get_cardinality(oracle), r.cardinality());
    }
}

fn fuzzprint(comptime fmt: []const u8, args: anytype) void {
    if (!@import("build-options").fuzzprint) return;
    std.debug.print(fmt, args);
}

const testgpa = testing.allocator;

fn perform_op(op: FuzzOp, cr: [*c]c.roaring_bitmap_t, zr: *Bitmap) !void {
    errdefer {
        fuzzprint("failed op: {}\n", .{op});
        fuzzprint("{}\n", .{op});
        fuzzprint("zr={f}\n", .{zr});
        c.roaring_bitmap_printf(cr);
    }
    fuzzprint("op: {}\n", .{op});
    switch (op) {
        .add => |x| {
            c.roaring_bitmap_add(cr, x);
            try zr.add(testgpa, x);
        },
        .add_many => |x| {
            c.roaring_bitmap_add_many(cr, x.len, x.ptr);
            _ = try zr.add_many(testgpa, x);
        },
        .add_range_closed => |x| {
            c.roaring_bitmap_add_range_closed(cr, x[0], x[1]);
            try zr.add_range_closed(testgpa, x[0], x[1]);
        },
        .remove => |x| {
            c.roaring_bitmap_remove(cr, x);
            try zr.remove(testgpa, x);
        },

        .contains => |x| {
            try testing.expectEqual(
                c.roaring_bitmap_contains(cr, x),
                zr.contains(x),
            );
        },
        .contains_many => |x| for (x) |v| {
            try testing.expectEqual(
                c.roaring_bitmap_contains(cr, v),
                zr.contains(v),
            );
        },
        .get_cardinality => |x| {
            try testing.expectEqual(x, c.roaring_bitmap_get_cardinality(cr));
            try testing.expectEqual(x, zr.get_cardinality());
        },
        .clear => {
            c.roaring_bitmap_clear(cr);
            zr.clear_retaining_capacity();
        },
        // else => std.debug.panic("TODO {t}", .{op}),
    }
    try testing.expectEqual(c.roaring_bitmap_get_cardinality(cr), zr.get_cardinality());
}

fn perform_ops(ops: []const FuzzOp) !void {
    const cr = c.roaring_bitmap_create() orelse return error.CRoaringAllocFailed;
    defer c.roaring_bitmap_free(cr);
    var zr: Bitmap = .empty;
    defer zr.deinit(testgpa);

    for (ops) |op| {
        try perform_op(op, cr, &zr);
    }
}

test "crash reproductions" {
    // if (!@import("build-options").with_croaring) return;

    try perform_ops(&.{
        .{ .add_many = &.{ 98128, 17714 } },
        .{ .add_range_closed = .{ 0, 100 } },
        .{ .contains = 98128 },
        .{ .contains = 17714 },
        .{ .contains = 0 },
        .{ .contains = 50 },
        .{ .contains = 100 },
        .{ .get_cardinality = 103 },
    });

    try perform_ops(&.{
        .{ .add = 28939 },
        .{ .add_range_closed = .{ 58, 109 } },
        .{ .add_range_closed = .{ 15, 158 } },
        .{ .contains = 65277 },
    });

    try perform_ops(&.{
        .{ .add_range_closed = .{ 6, 140 } },
        .{ .remove = 13 },
    });

    try perform_ops(&.{
        .{ .add = 37022 },
        .{ .add_range_closed = .{ 0, 169 } },
        .{ .add = 56276 },
        .{ .add_range_closed = .{ 79, 196 } },
    });

    try perform_ops(&.{
        .{ .add_range_closed = .{ 51, 194 } },
        .{ .add = 10 },
    });

    try perform_ops(&.{
        .{ .add_many = &.{ 46535, 45534 } },
        .{ .add_range_closed = .{ 11, 181 } },
    });

    try perform_ops(&.{
        .{ .remove = 87070 },
        .{ .add_range_closed = .{ 166, 192 } },
        .{ .add = 0 },
        .{ .add = 512 },
        .{ .add = 256 },
        .{ .add = 167 },
        .{ .add = 26389 },
        .{ .add_range_closed = .{ 104, 178 } },
        .{ .add = 22272 },
        .{ .add = 0 },
        .{ .add = 7168 },
        .{ .add = 512 },
        .{ .add = 0 },
        .{ .add = 256 },
        .{ .add = 194 },
        .{ .contains = 107 },
        .{ .contains = 73080 },
        .{ .add = 28 },
    });

    try perform_ops(&.{
        .{ .add_range_closed = .{ 39, 139 } },
        .{ .add_range_closed = .{ 12690, 12753 } },
    });

    try perform_ops(&.{
        .{ .add = 62568 },
        .{ .remove = 62568 },
    });
    try perform_ops(&.{
        .{ .remove = 87070 },
        .{ .add_range_closed = .{ 166, 192 } },
        .{ .add = 0 },
        .{ .add = 512 },
        .{ .add = 256 },
        .{ .add = 167 },
        .{ .add = 26389 },
        .{ .add_range_closed = .{ 104, 178 } },
        .{ .add = 22272 },
        .{ .add = 0 },
        .{ .add = 7168 },
        .{ .add = 512 },
        .{ .add = 0 },
        .{ .add = 256 },
        .{ .add = 194 },
        .{ .add = 28 },
    });

    try perform_ops(&.{
        .{ .add = 50119 },
        .{ .add = 62568 },
        .{ .remove = 62568 },
        .{ .add_range_closed = .{ 10276, 10424 } },
        .{ .remove = 49098 },
        .{ .clear = {} },
        .{ .add = 62568 },
        .{ .remove = 62568 },
        .{ .add = 49721 },
    });

    try perform_ops(&.{
        .{ .add = 49191 },
        .{ .add_range_closed = .{ 66, 136 } },
        .{ .add_range_closed = .{ 13544, 13684 } },
        .{ .add_range_closed = .{ 14890, 15026 } },
        .{ .add = 0 },
        .{ .add_range_closed = .{ 8080, 8142 } },
        .{ .add_range_closed = .{ 3464, 3609 } },
        .{ .remove = 92533 },
        .{ .add = 512 },
    });

    try perform_ops(&.{
        .{ .add_range_closed = .{ 6764, 6894 } },
        .{ .add_range_closed = .{ 13773, 13854 } },
        .{ .add_range_closed = .{ 6766, 6909 } },
        .{ .add_many = &.{ 48948, 31144, 22, 49190, 25646, 78018, 10133, 76937, 48583, 30673, 22, 90948, 31107, 23386, 46995, 68047, 16320, 49577, 677, 37978, 47808, 27610, 88520, 70996, 62004, 94019, 43879, 13907, 1949, 28038 } },
        .{ .add_range_closed = .{ 4099, 4188 } },
        .{ .add_many = &.{ 82655, 56815, 86334, 62004, 732, 62004, 40661, 47808, 73862, 93192, 38013, 53393, 677, 28543, 85664, 36133, 80365, 42126, 75508, 78529, 4132, 60102 } },
        .{ .remove = 36559 },
        .{ .remove = 36559 },
        .{ .add_range_closed = .{ 4583, 4758 } },
        .{ .add_range_closed = .{ 36, 170 } },
        .{ .add_many = &.{ 23232, 66772, 48948, 33025, 56815, 56104, 44748, 52498, 27950, 60102, 42168, 45924, 18860, 22730, 50616, 47654, 12354, 48252, 54560, 23558, 95317, 68095 } },
        .{ .add_many = &.{ 59501, 37670, 76761, 62233, 60102, 36703, 48923, 79184, 34000, 56232, 14170, 32742, 46325, 54945, 43678, 8533, 25708, 95293, 20267, 52246, 48836, 8505, 11355 } },
        .{ .add_many = &.{ 68140, 8533, 11355, 89774, 22890, 37126, 48886, 11355, 85535, 53796, 83412, 31153, 62004, 82694, 23047, 31922, 52246, 11355, 11355, 54168, 90585, 55515, 77388, 39683, 33899, 65437 } },
        .{ .add_many = &.{ 90915, 43523, 677, 1795, 91917, 77704, 2156, 2123, 17697, 26518, 87440, 95293, 39797, 76339, 60102, 70347, 58901, 22858, 73958, 22727, 46971, 1949 } },
        .{ .add_many = &.{ 53393, 21069, 57726, 19617, 78427, 65705, 2198, 7957, 66342, 85444, 95090, 52246, 30486 } },
    });

    try perform_ops(&.{
        .{ .add_range_closed = .{ 6111, 6209 } },
        .{ .add_many = &.{ 25060, 63400, 74045, 98806, 36081 } },
        .{ .add_range_closed = .{ 2476, 2573 } },
        .{ .add_many = &.{ 22715, 7649, 16716 } },
        .{ .remove = 51475 },
        .{ .add_many = &.{ 84217, 31754, 94058, 4, 90104, 7649, 98806 } },
        .{ .add_range_closed = .{ 6048, 6184 } },
        .{ .clear = {} },
        .{ .remove = 63913 },
        .{ .clear = {} },
        .{ .get_cardinality = 0 },
        .{ .add = 51548 },
        .{ .add_range_closed = .{ 14181, 14276 } },
        .{ .add_range_closed = .{ 814, 945 } },
        .{ .remove = 63913 },
        .{ .add_many = &.{93120} },
        .{ .add_range_closed = .{ 5677, 5702 } },
        .{ .get_cardinality = 256 },
        .{ .get_cardinality = 256 },
        .{ .add_many = &.{ 27047, 95148, 96415, 27461 } },
        .{ .get_cardinality = 260 },
        .{ .add_many = &.{ 16912, 74410, 93120, 59285 } },
    });
}

test "crash0" {
    //
}

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const testing = std.testing;
const assert = std.debug.assert;
const zroaring = @import("root.zig");
const Bitmap = zroaring.Bitmap;
const c = zroaring.c.root;
