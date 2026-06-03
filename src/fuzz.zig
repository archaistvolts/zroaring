test "croaring oracle fuzz" {
    const Context = struct {
        fn testOne(_: @This(), smith: *testing.Smith) anyerror!void {
            try croaringOracle(smith, testgpa);
        }
    };
    const corpus = try loadCorpus(testing.io, "testdata/crashfiles");
    defer {
        for (corpus) |x| testgpa.free(x);
        testgpa.free(corpus);
    }
    try std.testing.fuzz(Context{}, Context.testOne, .{ .corpus = corpus });
}

fn loadPath(io: Io, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, testgpa, .unlimited) catch |e| {
        std.debug.panic("loadPath: {} path: '{s}'", .{ e, path });
    };
}

/// loads .zig-cache/f/crash along with files in dirpath
fn loadCorpus(io: Io, dirpath: []const u8) ![]const []const u8 {
    var ret: std.ArrayList([]const u8) = .empty;
    defer ret.deinit(testgpa);
    if (loadPath(io, ".zig-cache/f/crash")) |contents| // skip if missing
        try ret.append(testgpa, contents)
    else |_| {}

    var dir = try Io.Dir.cwd().openDir(io, dirpath, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind != .file) continue;
        var buf: [256]u8 = undefined;
        var fbs = Io.Writer.fixed(&buf);
        try fbs.print("{s}/{s}", .{ dirpath, e.name });

        if (loadPath(io, fbs.buffered())) |contents| // skip if missing
            try ret.append(testgpa, contents)
        else |_| {}
    }

    return ret.toOwnedSlice(testgpa);
}

fn croaringOracleFile(io: Io, path: []const u8) !void {
    const contents = loadPath(io, path) catch return;
    defer testgpa.free(contents);
    var smith = testing.Smith{ .in = contents };
    try croaringOracle(&smith, testgpa);
}

test "croaring oracle crash - current" {
    try croaringOracleFile(testing.io, ".zig-cache/f/crash");
}

test "croaring oracle crashes" {
    const io = testing.io;
    const path = "testdata/crashfiles";
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind != .file) continue;
        var buf: [256]u8 = undefined;
        var fbs = Io.Writer.fixed(&buf);
        try fbs.print("{s}/{s}", .{ path, e.name });
        try croaringOracleFile(io, fbs.buffered());
    }
}

pub const FuzzOp = union(enum) {
    add: One,
    add_many: Many,
    add_range_closed: Two,
    remove: Remove,
    intersect: BinOp,
    clear: u8,
    run_optimize: u8,
    shrink_to_fit: u8,
    portable_serialize: u8,
    frozen_serialize: u8,
    equals: u8,
    // portable_deserialize, // TODO skipped due to slow/akward file write. could use mmap but not cross platform.
    // get_index, // TODO
    contains: One,
    contains_many: Many,

    const One = struct { idx: u8, val: u32 };
    const Two = struct { idx: u8, val: [2]u32 };
    const Many = struct { idx: u8, vals: []const u32 };
    const Remove = struct { idx: u8, pick_existing: u8, val: u32 };
    /// example: idx = src1 & src2.
    const BinOp = struct {
        /// destination index.  name `idx` follows other FuzzOps.
        idx: u8,
        src1: u8,
        src2: u8,
    };

    pub const Tag = std.meta.Tag(FuzzOp);
};

const MAX_VAL = 100_000_000;
const MAX_RANGE_LEN = 500_000;
const NUM_BITMAPS = 2;

fn croaringOracle(smith: *testing.Smith, allocator: mem.Allocator) !void {
    var rs: [NUM_BITMAPS]Bitmap = @splat(.empty);
    defer for (&rs) |*x| x.deinit(allocator);
    var oracles: [NUM_BITMAPS][*c]c.roaring_bitmap_t = undefined;
    for (&oracles) |*o| o.* = c.roaring_bitmap_create().?;
    defer for (oracles) |o| c.roaring_bitmap_free(o);

    fuzzprint("\n\n// begin croaringOracle\n", .{});
    while (!smith.eos()) {
        const tag = smith.value(FuzzOp.Tag);
        const idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS);
        switch (tag) {
            .add => {
                const val = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                try perform_op(.{ .add = .{ .idx = idx, .val = val } }, &oracles, &rs, allocator);
            },
            .add_many => {
                var vals: [8]u32 = undefined;
                const len = smith.valueRangeLessThan(u8, 1, vals.len);
                for (0..len) |i| vals[i] = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                try perform_op(.{ .add_many = .{ .idx = idx, .vals = vals[0..len] } }, &oracles, &rs, allocator);
            },
            .add_range_closed => {
                const start = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                const len = smith.valueRangeLessThan(u32, 1, MAX_RANGE_LEN);
                const val1 = smith.valueRangeLessThan(u32, start, start + len);
                const val2 = smith.valueRangeLessThan(u32, start + len, start + len * 2);
                try perform_op(.{ .add_range_closed = .{ .idx = idx, .val = .{ val1, val2 } } }, &oracles, &rs, allocator);
            },
            .remove => try perform_op(.{ .remove = .{
                .idx = idx,
                .pick_existing = smith.value(u8),
                .val = smith.valueRangeLessThan(u32, 0, MAX_VAL),
            } }, &oracles, &rs, allocator),
            .intersect => try perform_op(.{ .intersect = .{
                .idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
                .src1 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
                .src2 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
            } }, &oracles, &rs, allocator),
            .clear => try perform_op(.{ .clear = idx }, &oracles, &rs, allocator),
            .run_optimize => try perform_op(.{ .run_optimize = idx }, &oracles, &rs, allocator),
            .shrink_to_fit => try perform_op(.{ .shrink_to_fit = idx }, &oracles, &rs, allocator),
            .portable_serialize => try perform_op(.{ .portable_serialize = idx }, &oracles, &rs, allocator),
            .frozen_serialize => try perform_op(.{ .frozen_serialize = idx }, &oracles, &rs, allocator),
            .equals => try perform_op(.{ .equals = idx }, &oracles, &rs, allocator),
            .contains => {
                const val = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                try perform_op(.{ .contains = .{ .idx = idx, .val = val } }, &oracles, &rs, allocator);
            },
            .contains_many => {
                var vals: [8]u32 = undefined;
                const len = smith.valueRangeLessThan(u8, 1, vals.len);
                for (0..len) |i| vals[i] = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                try perform_op(.{ .contains_many = .{ .idx = idx, .vals = vals[0..len] } }, &oracles, &rs, allocator);
            },
        }
    }
}

// -- AFL fuzzing

var arena_impl: std.heap.ArenaAllocator = .{
    .child_allocator = std.heap.smp_allocator,
    .state = .{},
};
export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(dataptr: [*]const u8, size: usize) void {
    zig_fuzz_test1(dataptr[0..size]) catch unreachable;
}

fn zig_fuzz_test1(in: []const u8) !void {
    _ = arena_impl.reset(.retain_capacity);
    try hashMapOracle(in, arena_impl.allocator());
}

const AflSmith = struct {
    bytes: *Io.Reader,

    pub fn uintLessThan(smith: *AflSmith, comptime T: type, less_than: T) ?T {
        comptime assert(@typeInfo(T).int.signedness == .unsigned);
        assert(0 < less_than);
        const val = smith.value(T) orelse return null;
        return val % less_than;
    }

    pub fn value(smith: *AflSmith, T: type) ?T {
        var ret: T = 0;
        const buf = mem.asBytes(&ret);
        for (buf) |*byte| {
            byte.* = smith.bytes.takeByte() catch return null;
        }
        return ret;
    }

    pub fn valueRangeLessThan(smith: *AflSmith, T: type, at_least: T, less_than: T) ?T {
        comptime assert(@typeInfo(T).int.signedness == .unsigned); // TODO signed
        return at_least + (smith.uintLessThan(T, less_than - at_least) orelse return null);
    }

    /// returns or null on eof
    pub fn nextOp(smith: *AflSmith, outvals: []u32) ?FuzzOp {
        const byte = smith.bytes.takeByte() catch return null;
        const tag: FuzzOp.Tag = @enumFromInt(byte % @typeInfo(FuzzOp).@"union".fields.len);
        const idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null;
        return switch (tag) {
            .add => .{ .add = .{ .idx = idx, .val = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null } },
            .add_many => {
                const len = smith.valueRangeLessThan(u8, 1, @intCast(outvals.len + 1)) orelse return null;
                for (outvals[0..len]) |*v| v.* = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null;
                return .{ .add_many = .{ .idx = idx, .vals = outvals[0..len] } };
            },
            .add_range_closed => {
                const start = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null;
                const len = smith.valueRangeLessThan(u32, 1, MAX_RANGE_LEN) orelse return null;
                const val1 = smith.valueRangeLessThan(u32, start, start + len) orelse return null;
                const val2 = smith.valueRangeLessThan(u32, start + len, start + len * 2) orelse return null;
                return .{ .add_range_closed = .{ .idx = idx, .val = .{ val1, val2 } } };
            },
            .remove => .{ .remove = .{
                .idx = idx,
                .pick_existing = smith.value(u8) orelse return null,
                .val = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null,
            } },
            .intersect => .{ .intersect = .{
                .idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
                .src1 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
                .src2 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
            } },
            .clear => .{ .clear = idx },
            .run_optimize => .{ .run_optimize = idx },
            .shrink_to_fit => .{ .shrink_to_fit = idx },
            .portable_serialize => .{ .portable_serialize = idx },
            .frozen_serialize => .{ .frozen_serialize = idx },
            .equals => .{ .equals = idx },
            .contains => .{ .contains = .{ .idx = idx, .val = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null } },
            .contains_many => {
                const len = smith.valueRangeLessThan(u8, 0, @intCast(outvals.len + 1)) orelse return null;
                for (outvals[0..len]) |*v| v.* = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null;
                return .{ .contains_many = .{ .idx = idx, .vals = outvals[0..len] } };
            },
        };
    }
};

const HashMapOracle = std.AutoArrayHashMapUnmanaged(u32, void);

fn hashMapOracle(in: []const u8, allocator: mem.Allocator) !void {
    var rbs: [NUM_BITMAPS]Bitmap = @splat(.empty);
    defer for (&rbs) |*rb| rb.deinit(allocator);
    var oracles: [NUM_BITMAPS]HashMapOracle = @splat(.empty);
    defer for (&oracles) |*o| o.deinit(allocator);
    for (&oracles) |*o| try o.ensureTotalCapacity(allocator, 1024 * 16);
    var fbs = Io.Reader.fixed(in);
    var smith = AflSmith{ .bytes = &fbs };

    fuzzprint("\n\n// begin hashMapOracle\n", .{});
    var vals: [8]u32 = undefined;
    while (smith.nextOp(&vals)) |op| {
        try perform_op(op, &oracles, &rbs, allocator);
    }
}

fn fuzzAflCrashFiles(io: Io, path: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind != .file) continue;
        if (!mem.startsWith(u8, e.name, "id:")) continue;
        var buf: [256]u8 = undefined;
        var fbs = Io.Writer.fixed(&buf);
        try fbs.print("{s}/{s}", .{ path, e.name });
        // std.debug.print("{s}\n", .{fbs.buffered()});
        if (loadPath(io, fbs.buffered())) |contents| // skip if missing
        {
            defer testgpa.free(contents);
            try zig_fuzz_test1(contents);
        } else |_| {}
    }
}

test "AFL fuzz crashes" {
    fuzzAflCrashFiles(testing.io, "afl/output/default/crashes") catch |e| switch (e) {
        error.FileNotFound => {}, // allows test to pass on CI
        else => return e,
    };
}

pub const AflCtx = struct { io: Io, dir: Io.Dir, file_index: *usize };

pub fn writeOpFile(ctx: AflCtx, ops: []const FuzzOp) !void {
    const dir = ctx.dir;
    const io = ctx.io;
    var filename_buf: [32]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buf, "in{d:0>3}", .{ctx.file_index.*});
    ctx.file_index.* += 1;

    const file = try dir.createFile(io, filename, .{});
    defer file.close(io);

    var bw = file.writer(io, &.{});
    for (ops) |op| {
        try writeOp(op, &bw.interface);
    }
    try bw.flush();
}

pub fn writeOp(op: FuzzOp, writer: *Io.Writer) !void {
    try writer.writeByte(@intFromEnum(op));
    try writer.writeByte(switch (op) {
        inline else => |x| if (@TypeOf(x) == u8) x else x.idx,
    });
    switch (op) {
        .add => |o| try writer.writeInt(u32, o.val, .little),
        .add_many => |o| {
            try writer.writeByte(@intCast(o.vals.len));
            for (o.vals) |v| try writer.writeInt(u32, v, .little);
        },
        .add_range_closed => |o| {
            const len = o.val[1] - o.val[0];
            try writer.writeInt(u32, o.val[0], .little);
            try writer.writeInt(u32, len - 1, .little);
            try writer.writeInt(u32, 0, .little); // val1: X % len = 0, start
            try writer.writeInt(u32, 0, .little); // val2: X % len = 0, start + len
        },
        .remove => |o| {
            try writer.writeByte(o.pick_existing);
            try writer.writeInt(u32, o.val, .little);
        },
        .intersect => |o| try writer.writeAll(&.{ o.idx, o.src1, o.src1 }),
        .contains => |o| try writer.writeInt(u32, o.val, .little),
        .contains_many => |o| {
            try writer.writeByte(@intCast(o.vals.len));
            for (o.vals) |v| try writer.writeInt(u32, v, .little);
        },
        .clear,
        .run_optimize,
        .shrink_to_fit,
        .portable_serialize,
        .frozen_serialize,
        .equals,
        => {},
    }
}

// -- end AFL fuzzing

/// oracles: either `*[NUM_BITMAPS][*c]c.roaring_bitmap_t` or `*[NUM_BITMAPS]*HashMapOracle`.
fn perform_op(
    op: FuzzOp,
    oracles: anytype,
    rs: *[NUM_BITMAPS]Bitmap,
    allocator: mem.Allocator,
) !void {
    const O = @TypeOf(oracles);
    const is_cr = O == *[NUM_BITMAPS][*c]c.roaring_bitmap_t;
    const is_hashmap = O == *[NUM_BITMAPS]HashMapOracle;
    comptime assert(is_cr or is_hashmap);
    switch (op) {
        .add,
        .add_many,
        .remove,
        .intersect,
        => fuzzprint("{},\n", .{op}),
        .add_range_closed,
        => |x| fuzzprint(".{{ .add_range_closed = .{{ .idx = {}, .val = .{{ {}, {} }} }} }},\n", .{ x.idx, x.val[0], x.val[1] }), // TODO bug report for std.Io.Writer.printArray() missing '.' before '{'.

        .clear,
        .run_optimize,
        .shrink_to_fit,
        .portable_serialize,
        .frozen_serialize,
        .equals,
        => fuzzprint("{},\n", .{op}),
        .contains,
        .contains_many,
        => {}, // no print, not part of reproduction
    }
    switch (op) {
        .add => |o| {
            try rs[o.idx].add(allocator, o.val);
            if (is_cr)
                c.roaring_bitmap_add(oracles[o.idx], o.val)
            else
                try oracles[o.idx].put(allocator, o.val, {});
        },
        .add_many => |o| {
            _ = try rs[o.idx].add_many(allocator, o.vals);
            if (is_cr)
                c.roaring_bitmap_add_many(oracles[o.idx], o.vals.len, o.vals.ptr)
            else {
                try oracles[o.idx].ensureUnusedCapacity(allocator, @intCast(o.vals.len));
                for (o.vals) |x| oracles[o.idx].put(allocator, x, {}) catch unreachable;
            }
        },
        .add_range_closed => |o| {
            const val1, const val2 = o.val;
            try rs[o.idx].add_range_closed(allocator, val1, val2);
            if (is_cr)
                c.roaring_bitmap_add_range_closed(oracles[o.idx], val1, val2)
            else {
                try oracles[o.idx].ensureUnusedCapacity(allocator, val2 + 1 - val1);
                var x = val1;
                while (x <= val2) : (x += 1) oracles[o.idx].put(allocator, x, {}) catch unreachable;
            }
        },
        .remove => |o| {
            const card = if (is_cr)
                c.roaring_bitmap_get_cardinality(oracles[o.idx])
            else
                oracles[o.idx].count();

            // 90% chance to pick existing (255 * 0.10 = ~25)
            const val = if (o.pick_existing > 25 and card > 0) val: {
                const rank = o.val % @as(u32, @truncate(card));
                var existing_val: u32 = undefined;
                if (is_cr) {
                    assert(c.roaring_bitmap_select(oracles[o.idx], rank, &existing_val));
                } else {
                    existing_val = oracles[o.idx].keys()[rank];
                }
                break :val existing_val;
            } else o.val;

            try std.testing.expectEqual(
                if (is_cr)
                    c.roaring_bitmap_remove_checked(oracles[o.idx], val)
                else
                    oracles[o.idx].swapRemove(val),
                try rs[o.idx].remove_checked(allocator, val),
            );
        },
        .intersect => |o| {
            var res = try rs[o.src1].intersect(allocator, rs[o.src2]);
            defer res.deinit(allocator);

            if (is_cr) {
                const cr_res = c.roaring_bitmap_and(oracles[o.src1], oracles[o.src2]);
                if (oracles[o.idx]) |old| c.roaring_bitmap_free(old);
                oracles[o.idx] = cr_res;
            } else {
                var intersection = HashMapOracle.empty;
                try intersection.ensureTotalCapacity(allocator, 1024);

                // Find matching keys between src1 and src2
                for (oracles[o.src1].keys()) |key| {
                    if (oracles[o.src2].contains(key)) {
                        try intersection.put(allocator, key, {});
                    }
                }

                oracles[o.idx].deinit(allocator);
                oracles[o.idx] = intersection;
            }

            rs[o.idx].deinit(allocator);
            rs[o.idx] = try res.clone(allocator);
        },
        .clear => |idx| {
            rs[idx].clear_retaining_capacity();
            if (is_cr)
                c.roaring_bitmap_clear(oracles[idx])
            else
                oracles[idx].clearRetainingCapacity();
        },
        .run_optimize => |idx| {
            const res = try rs[idx].run_optimize(allocator);
            if (is_cr)
                try testing.expectEqual(
                    c.roaring_bitmap_run_optimize(oracles[idx]),
                    res,
                );
        },
        .shrink_to_fit => |idx| {
            _ = try rs[idx].shrink_to_fit(allocator);
            if (is_cr)
                _ = c.roaring_bitmap_shrink_to_fit(oracles[idx]);
        },
        .portable_serialize => |idx| {
            var w = Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            var runflags: zroaring.RunFlags = undefined;
            const x = try rs[idx].portable_serialize(&w.writer, &runflags);
            const buf = try allocator.alloc(u8, x);
            defer allocator.free(buf);
            if (is_cr) {
                try testing.expectEqual(
                    c.roaring_bitmap_portable_serialize(oracles[idx], buf.ptr),
                    x,
                );
                try testing.expectEqualSlices(u8, buf, w.written());
            }
        },
        .frozen_serialize => |idx| {
            const size = rs[idx].frozen_size_in_bytes();
            const buf = try allocator.alloc(u8, size);
            defer allocator.free(buf);
            try rs[idx].frozen_serialize(buf);
            if (is_cr) {
                try testing.expectEqual(
                    c.roaring_bitmap_frozen_size_in_bytes(oracles[idx]),
                    size,
                );
                // TODO repro and file bug for UB in c.roaring_bitmap_frozen_serialize here
                // const buf2 = try allocator.alloc(u8, size);
                // defer allocator.free(buf2);
                // c.roaring_bitmap_frozen_serialize(oracle, buf2.ptr);
                // try testing.expectEqualSlices(u8, buf, buf2);
            }
        },
        .equals => |idx| try testing.expect(rs[idx].equals(rs[idx])),
        // don't print, not part of reproduction
        .contains => |o| {
            try std.testing.expectEqual(
                if (is_cr)
                    c.roaring_bitmap_contains(oracles[o.idx], o.val)
                else
                    oracles[o.idx].contains(o.val),
                rs[o.idx].contains(o.val),
            );
        },
        .contains_many => |o| {
            for (o.vals) |val| {
                try std.testing.expectEqual(
                    if (is_cr)
                        c.roaring_bitmap_contains(oracles[o.idx], val)
                    else
                        oracles[o.idx].contains(val),
                    rs[o.idx].contains(val),
                );
            }
        },
    }
    for (0..NUM_BITMAPS) |i|
        try std.testing.expectEqual(
            if (is_cr)
                c.roaring_bitmap_get_cardinality(oracles[i])
            else
                oracles[i].count(),
            rs[i].get_cardinality(),
        );
}

fn cr_perform_ops(_: void, ops: []const FuzzOp) !void {
    var zrs: [NUM_BITMAPS]Bitmap = @splat(.empty);
    defer for (&zrs) |*x| x.deinit(testgpa);
    var crs: [NUM_BITMAPS][*c]c.roaring_bitmap_t = undefined;
    for (&crs) |*o| o.* = c.roaring_bitmap_create().?;
    defer for (crs) |o| c.roaring_bitmap_free(o);

    errdefer for (zrs) |zr| std.debug.print("{f}\n", .{zr.fmtLong()});
    fuzzprint("\n\n--  perform ops  --\n", .{});
    for (ops) |op| {
        try perform_op(op, &crs, &zrs, testgpa);
    }
}

fn fuzzprint(comptime fmt: []const u8, args: anytype) void {
    if (!@import("build-options").fuzzprint) return;
    std.debug.print(fmt, args);
}

test "crash reproductions" {
    try perform_crash_ops({}, cr_perform_ops);
}

pub fn perform_crash_ops(ctx: anytype, ops_fn: fn (@TypeOf(ctx), []const FuzzOp) anyerror!void) !void {
    try ops_fn(ctx, &.{
        .{ .add_many = .{ .idx = 0, .vals = &.{ 98128, 17714 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 0, 100 } } },
    });

    try ops_fn(ctx, &.{
        .{ .add = .{ .idx = 0, .val = 28939 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 58, 109 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 15, 158 } } },
    });

    try ops_fn(ctx, &.{
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 6, 140 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 13 } },
    });

    try ops_fn(ctx, &.{
        .{ .add = .{ .idx = 0, .val = 37022 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 0, 169 } } },
        .{ .add = .{ .idx = 0, .val = 56276 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 79, 196 } } },
    });

    try ops_fn(ctx, &.{
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 51, 194 } } },
        .{ .add = .{ .idx = 0, .val = 10 } },
    });

    try ops_fn(ctx, &.{
        .{ .add_many = .{ .idx = 0, .vals = &.{ 46535, 45534 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 11, 181 } } },
    });

    try ops_fn(ctx, &.{
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 87070 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 166, 192 } } },
        .{ .add = .{ .idx = 0, .val = 0 } },
        .{ .add = .{ .idx = 0, .val = 512 } },
        .{ .add = .{ .idx = 0, .val = 256 } },
        .{ .add = .{ .idx = 0, .val = 167 } },
        .{ .add = .{ .idx = 0, .val = 26389 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 104, 178 } } },
        .{ .add = .{ .idx = 0, .val = 22272 } },
        .{ .add = .{ .idx = 0, .val = 0 } },
        .{ .add = .{ .idx = 0, .val = 7168 } },
        .{ .add = .{ .idx = 0, .val = 512 } },
        .{ .add = .{ .idx = 0, .val = 0 } },
        .{ .add = .{ .idx = 0, .val = 256 } },
        .{ .add = .{ .idx = 0, .val = 194 } },
        .{ .add = .{ .idx = 0, .val = 28 } },
    });

    try ops_fn(ctx, &.{
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 39, 139 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 12690, 12753 } } },
    });

    try ops_fn(ctx, &.{
        .{ .add = .{ .idx = 0, .val = 62568 } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 62568 } },
    });
    try ops_fn(ctx, &.{
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 87070 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 166, 192 } } },
        .{ .add = .{ .idx = 0, .val = 0 } },
        .{ .add = .{ .idx = 0, .val = 512 } },
        .{ .add = .{ .idx = 0, .val = 256 } },
        .{ .add = .{ .idx = 0, .val = 167 } },
        .{ .add = .{ .idx = 0, .val = 26389 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 104, 178 } } },
        .{ .add = .{ .idx = 0, .val = 22272 } },
        .{ .add = .{ .idx = 0, .val = 0 } },
        .{ .add = .{ .idx = 0, .val = 7168 } },
        .{ .add = .{ .idx = 0, .val = 512 } },
        .{ .add = .{ .idx = 0, .val = 0 } },
        .{ .add = .{ .idx = 0, .val = 256 } },
        .{ .add = .{ .idx = 0, .val = 194 } },
        .{ .add = .{ .idx = 0, .val = 28 } },
    });

    try ops_fn(ctx, &.{
        .{ .add = .{ .idx = 0, .val = 50119 } },
        .{ .add = .{ .idx = 0, .val = 62568 } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 62568 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 10276, 10424 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 49098 } },
        .{ .clear = 0 },
        .{ .add = .{ .idx = 0, .val = 62568 } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 62568 } },
        .{ .add = .{ .idx = 0, .val = 49721 } },
    });

    try ops_fn(ctx, &.{
        .{ .add = .{ .idx = 0, .val = 49191 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 66, 136 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 13544, 13684 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 14890, 15026 } } },
        .{ .add = .{ .idx = 0, .val = 0 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 8080, 8142 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 3464, 3609 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 92533 } },
        .{ .add = .{ .idx = 0, .val = 512 } },
    });

    try ops_fn(ctx, &.{
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 6764, 6894 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 13773, 13854 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 6766, 6909 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 48948, 31144, 22, 49190, 25646, 78018, 10133, 76937, 48583, 30673, 22, 90948, 31107, 23386, 46995, 68047, 16320, 49577, 677, 37978, 47808, 27610, 88520, 70996, 62004, 94019, 43879, 13907, 1949, 28038 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 4099, 4188 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 82655, 56815, 86334, 62004, 732, 62004, 40661, 47808, 73862, 93192, 38013, 53393, 677, 28543, 85664, 36133, 80365, 42126, 75508, 78529, 4132, 60102 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 36559 } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 36559 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 4583, 4758 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 36, 170 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 23232, 66772, 48948, 33025, 56815, 56104, 44748, 52498, 27950, 60102, 42168, 45924, 18860, 22730, 50616, 47654, 12354, 48252, 54560, 23558, 95317, 68095 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 59501, 37670, 76761, 62233, 60102, 36703, 48923, 79184, 34000, 56232, 14170, 32742, 46325, 54945, 43678, 8533, 25708, 95293, 20267, 52246, 48836, 8505, 11355 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 68140, 8533, 11355, 89774, 22890, 37126, 48886, 11355, 85535, 53796, 83412, 31153, 62004, 82694, 23047, 31922, 52246, 11355, 11355, 54168, 90585, 55515, 77388, 39683, 33899, 65437 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 90915, 43523, 677, 1795, 91917, 77704, 2156, 2123, 17697, 26518, 87440, 95293, 39797, 76339, 60102, 70347, 58901, 22858, 73958, 22727, 46971, 1949 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 53393, 21069, 57726, 19617, 78427, 65705, 2198, 7957, 66342, 85444, 95090, 52246, 30486 } } },
    });

    try ops_fn(ctx, &.{
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 6111, 6209 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 25060, 63400, 74045, 98806, 36081 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 2476, 2573 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 22715, 7649, 16716 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 51475 } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 84217, 31754, 94058, 4, 90104, 7649, 98806 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 6048, 6184 } } },
        .{ .clear = 0 },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 63913 } },
        .{ .clear = 0 },
        .{ .add = .{ .idx = 0, .val = 51548 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 14181, 14276 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 814, 945 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 63913 } },
        .{ .add_many = .{ .idx = 0, .vals = &.{93120} } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 5677, 5702 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 27047, 95148, 96415, 27461 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 16912, 74410, 93120, 59285 } } },
    });

    try ops_fn(ctx, &.{
        .{ .add = .{ .idx = 0, .val = 26360 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 7557, 7640 } } },
        .{ .run_optimize = 0 },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 66305, 6151, 80245, 13872, 7641, 7641 } } },
    });

    try ops_fn(ctx, &.{ // run optimize run to array
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 13042, 13044 } } },
        .{ .add = .{ .idx = 0, .val = 62034 } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 56204, 13694, 95054, 72879 } } },
        .{ .run_optimize = 0 },
    });

    try ops_fn(ctx, &.{ // run_container_add_range_nruns stale ptr
        .{ .add = .{ .idx = 0, .val = 86940 } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 78327, 33246, 28925, 27574, 3773, 75436, 90838 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 12485, 12562 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 1788, 1883 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 15443, 80245, 46573, 8525, 4618, 57642, 4618 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 61611 } },
        .{ .run_optimize = 0 },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 9606, 35473, 53110, 96833, 56206, 19615, 89556 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 6425, 6597 } } },
    });

    try ops_fn(ctx, &.{ // break run in two when blockslen==blockscapacity
        .{ .add_many = .{ .idx = 0, .vals = &.{ 71302, 41283, 5184, 53083 } } },
        .{ .run_optimize = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 3356, 3443 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 11478, 11585 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 10140, 10242 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 4020, 4068 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 1593, 1748 } } },
        .{ .run_optimize = 0 },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 1680 } },
    });

    try ops_fn(ctx, &.{ // convert_run_to_efficient_container integer overflow
        .{ .run_optimize = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 8404, 8449 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 8349, 8534 } } },
        .{ .run_optimize = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 8369, 8486 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 4477, 4544 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 4435, 42585, 13881, 34164, 21153 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 9468, 9585 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 9559 } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 57594, 84215, 0, 9586, 57594, 3007 } } },
        .{ .run_optimize = 0 },
        .{ .run_optimize = 0 },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 42662 } },
        .{ .add_many = .{ .idx = 0, .vals = &.{57594} } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 57594 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 2639, 2642 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 4825, 65535 } } },
        .{ .run_optimize = 0 },
    });

    try ops_fn(ctx, &.{ // add_range_closed blockoffset counting bug
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 269193, 269194 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 573007, 65042, 934201, 955639, 952480, 934201 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 295, 1717 } } },
        .{ .shrink_to_fit = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 618200, 619690 } } },
        .{ .run_optimize = 0 },
        .{ .add = .{ .idx = 0, .val = 65536 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 524057, 524674 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 700979, 701862 } } },
    });

    try ops_fn(ctx, &.{ // add_container_blocks overflow, uninit container bug
        .{ .add = .{ .idx = 0, .val = 602334 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 589467, 589986 } } },
    });

    try ops_fn(ctx, &.{ // create_range: array unimplemented
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 654535, 655360 } } },
    });

    try ops_fn(ctx, &.{ // create range: overflow
        .{ .add = .{ .idx = 0, .val = 74473 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 262143, 262845 } } },
    });

    try ops_fn(ctx, &.{ // container_add_range bitset
        .{ .add = .{ .idx = 0, .val = 21571 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 230, 5661 } } },
    });

    try ops_fn(ctx, &.{ // container_add_range bitset
        .{ .add_many = .{ .idx = 0, .vals = &.{ 129631, 93925 } } },
        .{ .add = .{ .idx = 0, .val = 65536 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 87, 7994 } } },
        .{ .run_optimize = 0 },
        .{ .shrink_to_fit = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 102782, 107350 } } },
    });

    try ops_fn(ctx, &.{ // convert_run_optimize, bitset, update blockslen
        .{ .add = .{ .idx = 0, .val = 21571 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 230, 5482 } } },
        .{ .run_optimize = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 355102, 356802 } } },
    });

    try ops_fn(ctx, &.{ // array_container_grow: use calc_capacity()
        .{ .add_many = .{ .idx = 0, .vals = &.{ 129631, 93925 } } },
        .{ .add = .{ .idx = 0, .val = 65536 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 87, 88 } } },
        .{ .run_optimize = 0 },
        .{ .shrink_to_fit = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 102782, 103370 } } },
    });

    try ops_fn(ctx, &.{ // bitset_lenrange_cardinality: popcount not ctz
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 269193, 269194 } } },
        .{ .clear = 0 },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 246143, 479398, 519512, 479398, 2304, 93925 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 105168, 109491 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 976463, 48064 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 222979, 224481 } } },
        .{ .shrink_to_fit = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 63199, 63735 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 871311, 872258 } } },
        .{ .shrink_to_fit = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 501983, 503122 } } },
        .{ .add = .{ .idx = 0, .val = 65536 } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 224099 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 1511, 1512 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 981223 } },
        .{ .add_many = .{ .idx = 0, .vals = &.{830160} } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 654898, 655635 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 997826, 997827 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 102455, 103396 } } },
    });

    try ops_fn(ctx, &.{ // bitset_lenrange_cardinality: u64 to avoid overflow
        .{ .add = .{ .idx = 0, .val = 75944 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 86940, 94246 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 87951, 94779 } } },
    });

    try ops_fn(ctx, &.{ // bitset_set_lenrange: use wrapping math to avoid overflow
        .{ .add = .{ .idx = 0, .val = 29614 } },
        .{ .add = .{ .idx = 0, .val = 65536 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 63252, 71190 } } },
    });

    try ops_fn(ctx, &.{ // bitset_lenrange_cardinality: use wrapping math to avoid overflow
        .{ .add = .{ .idx = 0, .val = 232231 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 11141, 11245 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 11245 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 223401, 231936 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 192113, 199991 } } },
    });

    try ops_fn(ctx, &.{ // remove_at_index @memmove length bug
        .{ .add = .{ .idx = 0, .val = 956902 } },
        .{ .shrink_to_fit = 0 },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 547367, 43854 } } },
        .{ .clear = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 63253, 68554 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 8283 } },
        .{ .add = .{ .idx = 0, .val = 80434 } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 929337, 106248, 347873, 514060, 164928 } } },
        .{ .add = .{ .idx = 0, .val = 533060 } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 164928 } },
    });

    try ops_fn(ctx, &.{ // Container.remove: skip assert_valid
        .{ .clear = 0 },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 188901, 624734, 783759 } } },
        .{ .shrink_to_fit = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 131424, 134903 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 174930, 175543 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 511169, 736404, 616057, 136937, 140723, 912071, 624980 } } },
        .{ .shrink_to_fit = 0 },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 133236 } },
    });

    try ops_fn(ctx, &.{
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 720895, 723787 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 654236, 733271 } } },
    });

    try ops_fn(ctx, &.{ // convert_run_optimize: blockslen double increment
        .{ .add_many = .{ .idx = 0, .vals = &.{ 624980, 288844, 195140, 851109, 442054, 90431 } } },
        .{ .run_optimize = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 973441, 976611 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 90431 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 130468, 135996 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 2856152, 2858382 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 107184, 107384 } } },
        .{ .frozen_serialize = 0 },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 107184 } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 624980, 50064, 814965, 963343, 50064, 138676, 168443 } } },
        .{ .add_many = .{ .idx = 0, .vals = &.{ 99204, 299749, 951000, 804571 } } },
        .{ .portable_serialize = 0 },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 135567 } },
        .{ .run_optimize = 0 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 921371, 924952 } } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 130836, 132565 } } },
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 974319 } },
        .{ .add_many = .{ .idx = 0, .vals = &.{50064} } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 259797, 285999 } } },
        .{ .run_optimize = 0 },
    });

    try ops_fn(ctx, &.{ // bitset_container_clone crash
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 87070 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 365, 423 } } },
        .{ .portable_serialize = 1 },
        .{ .portable_serialize = 1 },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 616, 129897 } } },
        .{ .add = .{ .idx = 0, .val = 256 } },
        .{ .add = .{ .idx = 1, .val = 167 } },
        .{ .add = .{ .idx = 0, .val = 58056981 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 104, 228 } } },
        .{ .run_optimize = 1 },
        .{ .add = .{ .idx = 0, .val = 90595328 } },
        .{ .add_range_closed = .{ .idx = 1, .val = .{ 13, 43022 } } },
        .{ .add = .{ .idx = 0, .val = 11010048 } },
        .{ .add = .{ .idx = 0, .val = 15925248 } },
        .{ .add = .{ .idx = 0, .val = 0 } },
        .{ .intersect = .{ .idx = 0, .src1 = 0, .src2 = 1 } },
    });

    try ops_fn(ctx, &.{ // run_bitset_container_intersection handle uninit
        .{ .remove = .{ .idx = 0, .pick_existing = 1, .val = 87070 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 166, 192 } } },
        .{ .add = .{ .idx = 1, .val = 0 } },
        .{ .add_range_closed = .{ .idx = 1, .val = .{ 10779, 73338 } } },
        .{ .add = .{ .idx = 0, .val = 256 } },
        .{ .add = .{ .idx = 1, .val = 167 } },
        .{ .add = .{ .idx = 0, .val = 58056981 } },
        .{ .add_range_closed = .{ .idx = 0, .val = .{ 104, 210 } } },
        .{ .add = .{ .idx = 0, .val = 11010048 } },
        .{ .add = .{ .idx = 0, .val = 15925248 } },
        .{ .add = .{ .idx = 0, .val = 0 } },
        .{ .intersect = .{ .idx = 0, .src1 = 0, .src2 = 1 } },
    });
}

test "crash0" {
    //
}

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const testing = std.testing;
const testgpa = testing.allocator;
const assert = std.debug.assert;
const zroaring = @import("root.zig");
const Bitmap = zroaring.Bitmap;
const c = zroaring.c.root;
