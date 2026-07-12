test "croaring oracle fuzz" { // primary zig fuzzing routine
    const Context = struct {
        fn testOne(_: @This(), smith: *testing.Smith) anyerror!void {
            try croaringOracle(testgpa, smith);
        }
    };
    const corpus = try loadCorpus(testing.io, "testdata/crashfiles");
    defer {
        for (corpus) |x| testgpa.free(x);
        testgpa.free(corpus);
    }
    try std.testing.fuzz(Context{}, Context.testOne, .{ .corpus = corpus });
}

test "crash corpus" {
    for (crash_corpus) |ops| {
        try cr_perform_ops(testgpa, ops);
        if (testing.allocator_instance.deinit() == .leak) @panic("leak detected!");
        testing.allocator_instance = .init;
    }
}

test "allocation failures with crash corpus" {
    if (!@import("build-options").run_slow_tests) return error.SkipZigTest;
    for (crash_corpus) |ops| {
        try testing.checkAllAllocationFailures(testgpa, cr_perform_ops, .{ops});
    }
}

test "allocation failures corpus" {
    // const corpus: []const []const Op = @import("fuzz-alloc-failures-corpus.zon");
    // for (corpus) |ops| {
    //     try testing.checkAllAllocationFailures(testgpa, cr_perform_ops, .{ops});
    // }
}

fn loadPath(io: Io, path: []const u8) ![]const u8 {
    return try Io.Dir.cwd().readFileAlloc(io, path, testgpa, .unlimited);
}

/// loads fuzz-crash-corpus.zon, .zig-cache/f/crash and files in dirpath.
fn loadCorpus(io: Io, dirpath: []const u8) ![]const []const u8 {
    var ret: std.ArrayList([]const u8) = .empty;
    defer ret.deinit(testgpa);

    try ret.ensureTotalCapacity(testgpa, crash_corpus.len + 1);
    for (crash_corpus) |ops| {
        var w: Io.Writer.Allocating = .init(testgpa);
        defer w.deinit();
        for (ops) |op| try writeOp(op, &w.writer);
        ret.appendAssumeCapacity(try w.toOwnedSlice());
    }

    if (loadPath(io, ".zig-cache/f/crash")) |contents| // skip if missing
        ret.appendAssumeCapacity(contents)
    else |_| {}

    if (Io.Dir.cwd().openDir(io, dirpath, .{ .iterate = true })) |dir| {
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
    } else |_| {}

    return ret.toOwnedSlice(testgpa);
}

fn croaringFuzzFile(io: Io, path: []const u8) !void {
    const contents = loadPath(io, path) catch return;
    defer testgpa.free(contents);
    var smith = testing.Smith{ .in = contents };
    try croaringOracle(testgpa, &smith);
}

test "croaring oracle crash - current" {
    try croaringFuzzFile(testing.io, ".zig-cache/f/crash");
}

test "croaring oracle crashes" {
    const io = testing.io;
    const path = "testdata/crashfiles";
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind != .file) continue;
        var buf: [256]u8 = undefined;
        var fbs = Io.Writer.fixed(&buf);
        try fbs.print("{s}/{s}", .{ path, e.name });
        try croaringFuzzFile(io, fbs.buffered());
    }
}

/// all ops have a bitmap idx. Rest have additional params.
///
/// APPEND ONLY LIST.  add new ops last too stay synced with testdata/bench-data.csv
/// ordering and avoid breaking bench charts.
pub const Op = union(enum) {
    clear: u8, // bitmap idx only
    run_optimize: u8,
    shrink_to_fit: u8,
    portable_serialize: u8,
    frozen_serialize: u8,
    minimum: u8,
    maximum: u8,

    add: Val, // bitmap idx and value
    rank: Val,
    select: Val,
    contains: Val,

    add_many: Vals,

    add_range_closed: Vals2, // bitmap idx and 2 values
    contains_range: Vals2,
    range_cardinality: Vals2,

    remove: Remove, // bitmap idx, value and chance to pick existing

    @"and": BinOp, // three bitmap idx
    @"or": BinOp,
    xor: BinOp,
    andnot: BinOp,
    lazy_or: BinOp,

    or_inplace: BinOp2, // two bitmap idx
    and_inplace: BinOp2,
    is_subset: BinOp2,
    equals: BinOp2,
    and_cardinality: BinOp2,
    or_cardinality: BinOp2,
    xor_cardinality: BinOp2,
    andnot_cardinality: BinOp2,
    jaccard_index: BinOp2,

    or_many: ManyOp, // many bitmap idx

    // new ops go last to match existing csv column order
    portable_deserialize: u8,
    statistics: u8,
    flip: Vals2,
    frozen_view: u8,

    // bitmap idx with 1 u32 param
    const Val = struct { idx: u8, val: u32 };
    const Vals2 = struct { idx: u8, vals: [2]u32 };
    const Vals = struct { idx: u8, vals: []const u32 };
    /// remove val from bitmap idx with chance to choose existing
    const Remove = struct {
        idx: u8,
        val: u32,
        /// random int.  when < 25 choose an existing value.  otherwise a random value.
        pick_existing: u8,
    };
    /// example: idx = src1 & src2.
    const BinOp = struct {
        /// destination index.  name `idx` follows other FuzzOps.
        idx: u8,
        src1: u8,
        src2: u8,
    };
    /// in place: idx = idx & src1
    const BinOp2 = struct { idx: u8, src1: u8 };
    const ManyOp = struct { idxs: []const u8 };
    pub const Tag = std.meta.Tag(Op);
};

pub const crash_corpus: []const []const Op = @import("fuzz-crash-corpus.zon");

pub const MAX_VAL = 100_000_000;
pub const MAX_RANGE_LEN = 500_000;
pub const NUM_BITMAPS = 8;

fn croaringOracle(allocator: mem.Allocator, smith: *testing.Smith) !void {
    var rs: [NUM_BITMAPS]Bitmap = @splat(.empty);
    defer for (&rs) |*x| x.deinit(allocator);
    var oracles: [NUM_BITMAPS][*c]c.roaring_bitmap_t = undefined;
    for (&oracles) |*o| o.* = c.roaring_bitmap_create().?;
    defer for (oracles) |o| c.roaring_bitmap_free(o);
    var idxs: [NUM_BITMAPS + 1]u8 = undefined;

    fuzzprint("\n\n// begin croaringOracle\n", .{});
    while (!smith.eos()) {
        const tag = smith.value(Op.Tag);
        const idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS);
        var vals: [8]u32 = undefined;
        const fuzz_op: Op = fuzz_op: switch (tag) {
            .add => .{ .add = .{ .idx = idx, .val = smith.valueRangeLessThan(u32, 0, MAX_VAL) } },
            .add_many => {
                const len = smith.valueRangeLessThan(u8, 1, vals.len);
                for (&vals) |*v| v.* = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                break :fuzz_op .{ .add_many = .{ .idx = idx, .vals = vals[0..len] } };
            },
            inline .add_range_closed,
            .contains_range,
            .range_cardinality,
            .flip,
            => |t| {
                const start = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                const len = smith.valueRangeLessThan(u32, 1, MAX_RANGE_LEN);
                break :fuzz_op @unionInit(
                    Op,
                    @tagName(t),
                    .{ .idx = idx, .vals = .{
                        smith.valueRangeLessThan(u32, start, start + len),
                        smith.valueRangeLessThan(u32, start + len, start + len * 2),
                    } },
                );
            },
            .remove => .{ .remove = .{
                .idx = idx,
                .pick_existing = smith.value(u8),
                .val = smith.valueRangeLessThan(u32, 0, MAX_VAL),
            } },
            inline .@"and",
            .@"or",
            .xor,
            .andnot,
            .lazy_or,
            => |t| @unionInit(Op, @tagName(t), .{
                .idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
                .src1 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
                .src2 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
            }),
            inline .or_inplace,
            .is_subset,
            .and_inplace,
            .and_cardinality,
            .or_cardinality,
            .xor_cardinality,
            .andnot_cardinality,
            .jaccard_index,
            .equals,
            => |t| @unionInit(Op, @tagName(t), .{
                .idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
                .src1 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
            }),
            inline .or_many => |t| {
                const len = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS + 1);
                for (idxs[0..len]) |*x| x.* = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS);
                break :fuzz_op @unionInit(Op, @tagName(t), .{ .idxs = idxs[0..len] });
            },
            inline .clear,
            .run_optimize,
            .shrink_to_fit,
            .portable_serialize,
            .portable_deserialize,
            .frozen_serialize,
            .minimum,
            .maximum,
            .statistics,
            .frozen_view,
            => |t| @unionInit(Op, @tagName(t), idx),
            inline .rank,
            .select,
            .contains,
            => |t| @unionInit(Op, @tagName(t), .{
                .idx = idx,
                .val = smith.valueRangeLessThan(u32, 0, MAX_VAL),
            }),
        };

        try perform_op(fuzz_op, &oracles, &rs, allocator);
    }
}

// -- AFL fuzzing
fn croaringOracleAfl(allocator: mem.Allocator, smith: *AflSmith) !void {
    var zrs: [NUM_BITMAPS]Bitmap = @splat(.empty);
    defer for (&zrs) |*x| x.deinit(allocator);
    var oracles: [NUM_BITMAPS][*c]c.roaring_bitmap_t = undefined;
    for (&oracles) |*o| o.* = c.roaring_bitmap_create().?;
    defer for (oracles) |o| c.roaring_bitmap_free(o);

    fuzzprint("\n\n// begin croaringOracleAfl\n", .{});
    var buf: [8]u32 = undefined;
    while (smith.nextOp(&buf)) |op| {
        try perform_op(op, &oracles, &zrs, allocator);
    }
}

export fn zig_fuzz_init() void {}

pub export fn zig_fuzz_test(dataptr: [*]const u8, size: usize) void {
    zig_fuzz_test1(dataptr[0..size]) catch unreachable;
}

var arena_impl: std.heap.ArenaAllocator = .{
    .child_allocator = std.heap.page_allocator,
    .state = .{},
};

fn zig_fuzz_test1(in: []const u8) !void {
    _ = arena_impl.reset(.retain_capacity);
    var bytes = Io.Reader.fixed(in);
    var smith: AflSmith = .{ .bytes = &bytes };
    try croaringOracleAfl(arena_impl.allocator(), &smith);
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

    pub fn slice(smith: *AflSmith, len: usize, at_least: u8, less_than: u8) ?[]u8 {
        const bytes = smith.bytes.take(len) catch return null;
        for (bytes) |*b| b.* = smith.valueRangeLessThan(u8, at_least, less_than) orelse return null;
        return bytes;
    }

    pub fn valueRangeLessThan(smith: *AflSmith, T: type, at_least: T, less_than: T) ?T {
        comptime assert(@typeInfo(T).int.signedness == .unsigned); // TODO signed
        return at_least + (smith.uintLessThan(T, less_than - at_least) orelse return null);
    }

    /// returns or null on eof
    pub fn nextOp(smith: *AflSmith, buf: []u32) ?Op {
        const byte = smith.bytes.takeByte() catch return null;
        const tag: Op.Tag = @enumFromInt(byte % @typeInfo(Op).@"union".fields.len);
        const idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null;
        return switch (tag) {
            .add => .{ .add = .{ .idx = idx, .val = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null } },
            .add_many => {
                const len = smith.valueRangeLessThan(u8, 1, @intCast(buf.len + 1)) orelse return null;
                for (buf[0..len]) |*v| v.* = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null;
                return .{ .add_many = .{ .idx = idx, .vals = buf[0..len] } };
            },
            inline .add_range_closed,
            .contains_range,
            .range_cardinality,
            .flip,
            => |t| {
                const start = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null;
                const len = smith.valueRangeLessThan(u32, 1, MAX_RANGE_LEN) orelse return null;
                const val1 = smith.valueRangeLessThan(u32, start, start + len) orelse return null;
                const val2 = smith.valueRangeLessThan(u32, start + len, start + len * 2) orelse return null;
                return @unionInit(Op, @tagName(t), .{ .idx = idx, .vals = .{ val1, val2 } });
            },
            .remove => .{ .remove = .{
                .idx = idx,
                .pick_existing = smith.value(u8) orelse return null,
                .val = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null,
            } },
            inline .@"and",
            .@"or",
            .xor,
            .andnot,
            .lazy_or,
            => |t| @unionInit(Op, @tagName(t), .{
                .idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
                .src1 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
                .src2 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
            }),
            inline .or_inplace,
            .is_subset,
            .and_inplace,
            .and_cardinality,
            .or_cardinality,
            .xor_cardinality,
            .andnot_cardinality,
            .jaccard_index,
            .equals,
            => |t| @unionInit(Op, @tagName(t), .{
                .idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
                .src1 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
            }),
            inline .or_many => |t| @unionInit(Op, @tagName(t), .{
                .idxs = smith.slice(
                    smith.valueRangeLessThan(u8, 0, NUM_BITMAPS + 1) orelse return null,
                    0,
                    NUM_BITMAPS,
                ) orelse return null,
            }),
            inline .clear,
            .run_optimize,
            .shrink_to_fit,
            .portable_serialize,
            .portable_deserialize,
            .frozen_serialize,
            .minimum,
            .maximum,
            .statistics,
            .frozen_view,
            => |t| @unionInit(Op, @tagName(t), idx),
            inline .rank,
            .select,
            .contains,
            => |t| @unionInit(Op, @tagName(t), .{ .idx = idx, .val = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null }),
        };
    }
};

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
        if (loadPath(io, fbs.buffered())) |contents| // skip if missing
        {
            defer testgpa.free(contents);
            try zig_fuzz_test1(contents);
        } else |_| {}
    }
}

test "AFL fuzz crashes" {
    // if (true) return error.SkipZigTest;
    const afl_output_path = "afl/output/default";
    const io = testing.io;
    var dir = Io.Dir.cwd().openDir(io, afl_output_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind != .directory) continue;
        if (mem.find(u8, e.name, "crashes") == null) continue;
        var buf: [256]u8 = undefined;
        var fbs = Io.Writer.fixed(&buf);
        try fbs.print("{s}/{s}", .{ afl_output_path, e.name });
        fuzzAflCrashFiles(testing.io, fbs.buffered()) catch |err| switch (err) {
            error.FileNotFound => {}, // allows test to pass on CI
            else => return err,
        };
    }
}

pub const AflCtx = struct { io: Io, dir: Io.Dir, file_index: *usize };

pub fn writeOpFile(ctx: AflCtx, ops: []const Op) !void {
    const dir = ctx.dir;
    const io = ctx.io;
    var filename_buf: [32]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buf, "in{d:0>3}", .{ctx.file_index.*});
    ctx.file_index.* += 1;

    const file = try dir.createFile(io, filename, .{});
    defer file.close(io);
    var filebuf: [256]u8 = undefined;
    var fw = file.writer(io, &filebuf);
    for (ops) |op| {
        try writeOp(op, &fw.interface);
    }
    try fw.flush();
}

pub fn writeOp(op: Op, writer: *Io.Writer) !void {
    try writer.writeByte(@intFromEnum(op));
    switch (op) { // write idx for all ops
        inline else => |x| try writer.writeByte(if (@TypeOf(x) == u8) x else x.idx),
        .or_many => {},
    }
    switch (op) {
        .add => |o| try writer.writeInt(u32, o.val, .little),
        .add_many => |o| {
            try writer.writeByte(@intCast(o.vals.len));
            for (o.vals) |v| try writer.writeInt(u32, v, .little);
        },
        .add_range_closed,
        .contains_range,
        .range_cardinality,
        .flip,
        => |o| {
            const len = o.vals[1] - o.vals[0];
            try writer.writeInt(u32, o.vals[0], .little);
            try writer.writeInt(u32, len - 1, .little);
            try writer.writeInt(u32, 0, .little); // val1: X % len = 0, start
            try writer.writeInt(u32, 0, .little); // val2: X % len = 0, start + len
        },
        .remove => |o| {
            try writer.writeByte(o.pick_existing);
            try writer.writeInt(u32, o.val, .little);
        },
        .@"and",
        .@"or",
        .xor,
        .andnot,
        .lazy_or,
        => |o| try writer.writeAll(&.{ o.src1, o.src2 }),
        .equals,
        .or_inplace,
        .is_subset,
        .and_inplace,
        .and_cardinality,
        .or_cardinality,
        .xor_cardinality,
        .andnot_cardinality,
        .jaccard_index,
        => |o| try writer.writeAll(&.{o.src1}),
        .or_many,
        => |o| {
            try writer.writeByte(@intCast(o.idxs.len));
            try writer.writeAll(o.idxs);
        },
        .contains,
        .rank,
        .select,
        => |o| try writer.writeInt(u32, o.val, .little),
        .clear,
        .run_optimize,
        .shrink_to_fit,
        .portable_serialize,
        .portable_deserialize,
        .frozen_serialize,
        .minimum,
        .maximum,
        .statistics,
        .frozen_view,
        => {},
    }
}

pub fn readOp(r: *Io.Reader, buf: []u32) !Op {
    const tag: Op.Tag = @enumFromInt(try r.takeByte());
    switch (tag) {
        inline .clear,
        .run_optimize,
        .shrink_to_fit,
        .portable_serialize,
        .portable_deserialize,
        .frozen_serialize,
        .minimum,
        .maximum,
        .statistics,
        => |t| return @unionInit(Op, @tagName(t), try r.takeByte()),
        inline .add,
        .contains,
        .rank,
        .select,
        => |t| {
            const idx = try r.takeByte();
            const val = try r.takeInt(u32, .little);
            return @unionInit(Op, @tagName(t), .{ .idx = idx, .val = val });
        },
        .add_many => {
            const idx = try r.takeByte();
            const len = try r.takeByte();
            for (buf[0..len]) |*v| v.* = try r.takeInt(u32, .little);
            return .{ .add_many = .{ .idx = idx, .vals = buf[0..len] } };
        },
        inline .add_range_closed,
        .contains_range,
        .range_cardinality,
        .flip,
        => |t| {
            const idx = try r.takeByte();
            const start = try r.takeInt(u32, .little);
            const len = try r.takeInt(u32, .little);
            _ = try r.takeInt(u32, .little); // skip val1, val2
            _ = try r.takeInt(u32, .little);
            return @unionInit(Op, @tagName(t), .{
                .idx = idx,
                .vals = .{ start, start + len + 1 },
            });
        },
        .remove => {
            const idx = try r.takeByte();
            const pick_existing = try r.takeByte();
            const val = try r.takeInt(u32, .little);
            return .{ .remove = .{ .idx = idx, .val = val, .pick_existing = pick_existing } };
        },
        inline .@"and",
        .@"or",
        .xor,
        .andnot,
        .lazy_or,
        => |t| {
            const idx = try r.takeByte();
            const src1 = try r.takeByte();
            const src2 = try r.takeByte();
            return @unionInit(Op, @tagName(t), .{ .idx = idx, .src1 = src1, .src2 = src2 });
        },
        inline .or_inplace,
        .is_subset,
        .and_inplace,
        .and_cardinality,
        .or_cardinality,
        .xor_cardinality,
        .andnot_cardinality,
        .jaccard_index,
        .equals,
        => |t| {
            const idx = try r.takeByte();
            const src1 = try r.takeByte();
            return @unionInit(Op, @tagName(t), .{ .idx = idx, .src1 = src1 });
        },
        .or_many => {
            const len = try r.takeByte();
            const idxs = try r.take(len);
            return .{ .or_many = .{ .idxs = idxs } };
        },
    }
}

// -- end AFL fuzzing

fn perform_op(
    op: Op,
    oracles: *[NUM_BITMAPS][*c]c.roaring_bitmap_t,
    rs: *[NUM_BITMAPS]Bitmap,
    allocator: mem.Allocator,
) !void {
    switch (op) {
        .add, // only print ops which may mutate
        .remove,
        .xor,
        .andnot,
        .lazy_or,
        .or_inplace,
        .and_inplace,
        .is_subset,
        .clear,
        .run_optimize,
        .shrink_to_fit,
        => fuzzprint("{},\n", .{op}),
        .add_range_closed,
        .flip,
        => |x| fuzzprint(".{{ .{t} = .{{ .idx = {}, .vals = .{{ {}, {} }} }} }},\n", .{ op, x.idx, x.vals[0], x.vals[1] }),
        .add_many,
        => |x| fuzzprint(".{{ .{t} = .{{ .idx = {}, .vals = .{any} }} }},\n", .{ op, x.idx, x.vals }),
        .or_many,
        => |x| fuzzprint(".{{ .or_many = .{{ .idxs = .{any} }} }},\n", .{x.idxs}),
        .@"and",
        .@"or",
        => |x| fuzzprint(".{{ .@\"{t}\" = .{{ .idx = {}, .src1 = {}, .src2 = {} }} }},\n", .{ op, x.idx, x.src1, x.src2 }),
        // don't print ops which don't mutate - usually not part of reproduction
        .portable_serialize,
        .portable_deserialize,
        .frozen_serialize,
        .equals,
        .minimum,
        .maximum,
        .statistics,
        .frozen_view,
        .contains,
        .contains_range,
        .rank,
        .select,
        .and_cardinality,
        .or_cardinality,
        .xor_cardinality,
        .andnot_cardinality,
        .jaccard_index,
        .range_cardinality,
        => {},
    }
    switch (op) {
        .add => |o| {
            try rs[o.idx].add(allocator, o.val);
            c.roaring_bitmap_add(oracles[o.idx], o.val);
        },
        .add_many => |o| {
            _ = try rs[o.idx].add_many(allocator, o.vals);
            c.roaring_bitmap_add_many(oracles[o.idx], o.vals.len, o.vals.ptr);
        },
        .add_range_closed => |o| {
            const val1, const val2 = o.vals;
            try rs[o.idx].add_range_closed(allocator, val1, val2);
            c.roaring_bitmap_add_range_closed(oracles[o.idx], val1, val2);
        },
        .remove => |o| {
            const card =
                c.roaring_bitmap_get_cardinality(oracles[o.idx]);

            // 75% chance to pick existing (255 * 0.25 = ~60)
            const val = if (o.pick_existing > 60 and card > 0) val: {
                const rank = o.val % @as(u32, @truncate(card));
                var existing_val: u32 = undefined;
                assert(c.roaring_bitmap_select(oracles[o.idx], rank, &existing_val));
                break :val existing_val;
            } else o.val;

            try std.testing.expectEqual(
                c.roaring_bitmap_remove_checked(oracles[o.idx], val),
                try rs[o.idx].remove_checked(allocator, val),
            );
        },
        .@"and", .@"or", .xor, .andnot, .lazy_or => |o| {
            var res = switch (op) {
                .@"and" => try Bitmap.intersect(rs[o.src1], allocator, rs[o.src2]),
                .@"or" => try Bitmap.merge(rs[o.src1], allocator, rs[o.src2]),
                .xor => try Bitmap.xor(rs[o.src1], allocator, rs[o.src2]),
                .andnot => try Bitmap.andnot(rs[o.src1], allocator, rs[o.src2]),
                .lazy_or => try Bitmap.lazy_or(
                    &rs[o.src1],
                    allocator,
                    rs[o.src2],
                    zroaring.constants.LAZY_OR_BITSET_CONVERSION_TO_FULL,
                ),
                else => unreachable,
            };
            errdefer res.deinit(allocator);

            const cr_res = switch (op) {
                .@"and" => c.roaring_bitmap_and(oracles[o.src1], oracles[o.src2]),
                .@"or" => c.roaring_bitmap_or(oracles[o.src1], oracles[o.src2]),
                .xor => c.roaring_bitmap_xor(oracles[o.src1], oracles[o.src2]),
                .andnot => c.roaring_bitmap_andnot(oracles[o.src1], oracles[o.src2]),
                .lazy_or => c.roaring_bitmap_lazy_or(
                    oracles[o.src1],
                    oracles[o.src2],
                    zroaring.constants.LAZY_OR_BITSET_CONVERSION_TO_FULL,
                ),
                else => unreachable,
            };

            if (oracles[o.idx]) |old| c.roaring_bitmap_free(old);
            oracles[o.idx] = cr_res;
            if (op == .lazy_or) {
                c.roaring_bitmap_repair_after_lazy(oracles[o.idx]);
                try res.repair_after_lazy(allocator);
            }

            rs[o.idx].deinit(allocator);
            rs[o.idx] = res;
        },
        .or_inplace => |o| {
            try rs[o.idx].or_inplace(allocator, rs[o.src1]);
            c.roaring_bitmap_or_inplace(oracles[o.idx], oracles[o.src1]);
        },
        .and_inplace => |o| {
            try rs[o.idx].and_inplace(allocator, rs[o.src1]);
            c.roaring_bitmap_and_inplace(oracles[o.idx], oracles[o.src1]);
        },
        .and_cardinality => |o| {
            try testing.expectEqual(
                c.roaring_bitmap_and_cardinality(oracles[o.idx], oracles[o.src1]),
                rs[o.idx].and_cardinality(rs[o.src1]),
            );
        },
        .or_cardinality => |o| {
            try testing.expectEqual(
                c.roaring_bitmap_or_cardinality(oracles[o.idx], oracles[o.src1]),
                rs[o.idx].or_cardinality(rs[o.src1]),
            );
        },
        .xor_cardinality => |o| {
            try testing.expectEqual(
                c.roaring_bitmap_xor_cardinality(oracles[o.idx], oracles[o.src1]),
                rs[o.idx].xor_cardinality(rs[o.src1]),
            );
        },
        .andnot_cardinality => |o| {
            try testing.expectEqual(
                c.roaring_bitmap_andnot_cardinality(oracles[o.idx], oracles[o.src1]),
                rs[o.idx].andnot_cardinality(rs[o.src1]),
            );
        },
        .jaccard_index => |o| {
            const expected = c.roaring_bitmap_jaccard_index(oracles[o.idx], oracles[o.src1]);
            const actual = rs[o.idx].jaccard_index(rs[o.src1]);
            if (!std.math.isNan(expected) or !std.math.isNan(actual))
                try testing.expectApproxEqAbs(expected, actual, 0.000000001);
        },
        .or_many => |o| {
            if (o.idxs.len == 0) return; // nothing to do

            var rsbuf: [NUM_BITMAPS + 1]Bitmap = undefined;
            var osbuf: [NUM_BITMAPS + 1]@TypeOf(oracles[0]) = undefined;
            for (o.idxs) |*idx| {
                rsbuf[idx - o.idxs.ptr] = rs[idx.*];
                osbuf[idx - o.idxs.ptr] = oracles[idx.*];
            }

            const result = try Bitmap.or_many(allocator, rsbuf[0..o.idxs.len]);
            rs[o.idxs[0]].deinit(allocator);
            rs[o.idxs[0]] = result;

            const ret = c.roaring_bitmap_or_many(o.idxs.len, @ptrCast(&osbuf));
            if (oracles[o.idxs[0]]) |old| c.roaring_bitmap_free(old);
            oracles[o.idxs[0]] = ret;
        },
        .is_subset => |o| {
            try std.testing.expectEqual(
                c.roaring_bitmap_is_subset(oracles[o.idx], oracles[o.src1]),
                rs[o.idx].is_subset(rs[o.src1]),
            );
        },
        .clear => |idx| {
            rs[idx].clear(allocator);
            c.roaring_bitmap_clear(oracles[idx]);
        },
        .run_optimize => |idx| {
            try testing.expectEqual(
                c.roaring_bitmap_run_optimize(oracles[idx]),
                try rs[idx].run_optimize(allocator),
            );
        },
        .shrink_to_fit => |idx| {
            _ = c.roaring_bitmap_shrink_to_fit(oracles[idx]);
            _ = try rs[idx].shrink_to_fit(allocator);
        },
        .portable_serialize => |idx| {
            var w = Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            var runflags: zroaring.RunFlags = undefined;
            const size = rs[idx].portable_serialize(&w.writer, &runflags) catch |e| switch (e) {
                error.WriteFailed => return error.OutOfMemory, // allow allocation failures tests to pass
            };
            const buf = try allocator.alloc(u8, size);
            defer allocator.free(buf);

            try testing.expectEqual(
                c.roaring_bitmap_portable_serialize(oracles[idx], buf.ptr),
                size,
            );
            try testing.expectEqualSlices(u8, buf, w.written());
        },
        .portable_deserialize => |idx| {
            const zbuf = try allocator.alloc(u8, rs[idx].portable_size_in_bytes());
            defer allocator.free(zbuf);
            var w = Io.Writer.fixed(zbuf);
            var runflags: zroaring.RunFlags = undefined;
            const zrsize = rs[idx].portable_serialize(&w, &runflags) catch |e| switch (e) {
                error.WriteFailed => return error.OutOfMemory, // allows allocation failures test to pass
            };
            var z = try Bitmap.portable_deserialize(allocator, zbuf);
            defer z.deinit(allocator);

            const buf = try allocator.alloc(u8, z.portable_size_in_bytes());
            defer allocator.free(buf);
            const crsize = c.roaring_bitmap_portable_serialize(oracles[idx], buf.ptr);
            const cr = c.roaring_bitmap_portable_deserialize(buf.ptr);
            defer c.roaring_bitmap_free(cr);
            try testing.expectEqual(crsize, zrsize);
            try testing.expectEqualSlices(u8, buf, zbuf);
        },
        .frozen_serialize => |idx| {
            const size = rs[idx].frozen_size_in_bytes();
            const buf = try allocator.alloc(u8, size);
            defer allocator.free(buf);
            try rs[idx].frozen_serialize(buf);

            try testing.expectEqual(
                c.roaring_bitmap_frozen_size_in_bytes(oracles[idx]),
                size,
            );
            // TODO is it documented that c.roaring_bitmap_frozen_serialize
            // needs a non-empty bitmap.  if not make issue.
            if (oracles[idx].*.high_low_container.size != 0) {
                const buf2 = try allocator.alignedAlloc(u8, zroaring.constants.BLOCK_ALIGNMENT, size);
                defer allocator.free(buf2);
                c.roaring_bitmap_frozen_serialize(oracles[idx], buf2.ptr);
                try testing.expectEqualSlices(u8, buf, buf2);
            }
        },
        .equals => |o| {
            try testing.expectEqual(
                c.roaring_bitmap_equals(oracles[o.idx], oracles[o.src1]),
                rs[o.idx].equals(rs[o.src1]),
            );
            try testing.expectEqual(
                c.roaring_bitmap_equals(oracles[o.idx], oracles[o.idx]),
                rs[o.idx].equals(rs[o.idx]),
            );
        },
        .minimum => |idx| {
            try std.testing.expectEqual(
                c.roaring_bitmap_minimum(oracles[idx]),
                rs[idx].minimum(),
            );
        },
        .maximum => |idx| {
            try std.testing.expectEqual(
                c.roaring_bitmap_maximum(oracles[idx]),
                rs[idx].maximum(),
            );
        },
        .rank => |o| {
            try std.testing.expectEqual(
                c.roaring_bitmap_rank(oracles[o.idx], o.val),
                rs[o.idx].rank(o.val),
            );
        },
        .select => |o| blk: {
            const card: u32 = @intCast(c.roaring_bitmap_get_cardinality(oracles[o.idx]));

            if (card == 0) break :blk;
            const mzr_val = rs[o.idx].select(o.val % card);
            const zr_ok = mzr_val != null;

            var cr_val: u32 = undefined;
            const cr_ok = c.roaring_bitmap_select(
                oracles[o.idx],
                o.val % card,
                &cr_val,
            );
            try std.testing.expectEqual(cr_ok, zr_ok);
            if (zr_ok) try std.testing.expectEqual(cr_val, mzr_val.?);
        },
        // don't print, not part of reproduction
        .contains => |o| {
            try std.testing.expectEqual(
                c.roaring_bitmap_contains(oracles[o.idx], o.val),
                rs[o.idx].contains(o.val),
            );
        },
        .contains_range => |o| try std.testing.expectEqual(
            c.roaring_bitmap_contains_range(oracles[o.idx], o.vals[0], o.vals[1]),
            rs[o.idx].contains_range(o.vals[0], o.vals[1]),
        ),
        .range_cardinality => |o| try std.testing.expectEqual(
            c.roaring_bitmap_range_cardinality(oracles[o.idx], o.vals[0], o.vals[1]),
            rs[o.idx].range_cardinality(o.vals[0], o.vals[1]),
        ),
        .statistics => |idx| {
            var cs: c.roaring_statistics_t = undefined;
            c.roaring_bitmap_statistics(oracles[idx], &cs);
            const zs = rs[idx].statistics(); // zig fmt: off
try testing.expectEqual(cs.n_containers,               zs.n_containers);
try testing.expectEqual(cs.n_array_containers,         zs.n_array_containers);
try testing.expectEqual(cs.n_run_containers,           zs.n_run_containers);
try testing.expectEqual(cs.n_bitset_containers,        zs.n_bitset_containers);
try testing.expectEqual(cs.n_values_array_containers,  zs.n_values_array_containers);
try testing.expectEqual(cs.n_values_run_containers,    zs.n_values_run_containers);
try testing.expectEqual(cs.n_values_bitset_containers, zs.n_values_bitset_containers);
try testing.expectEqual(cs.n_bytes_array_containers,   zs.n_bytes_array_containers);
try testing.expectEqual(cs.n_bytes_run_containers,     zs.n_bytes_run_containers);
try testing.expectEqual(cs.n_bytes_bitset_containers,  zs.n_bytes_bitset_containers);
try testing.expectEqual(cs.min_value,                  zs.min_value);
try testing.expectEqual(cs.max_value,                  zs.max_value);
try testing.expectEqual(cs.cardinality,                zs.cardinality); // zig fmt: on
        },
        .flip => |o| {
            const result = try rs[o.idx].flip(allocator, o.vals[0], o.vals[1]);
            rs[o.idx].deinit(allocator);
            rs[o.idx] = result;

            const cr_res = c.roaring_bitmap_flip(oracles[o.idx], o.vals[0], o.vals[1]);
            c.roaring_bitmap_free(oracles[o.idx]);
            oracles[o.idx] = cr_res;
        },
        .frozen_view => |o| {
            const zr = rs[o];
            const zr_frozen_buf = try allocator.alignedAlloc(
                u8,
                zroaring.constants.BLOCK_ALIGNMENT,
                zr.frozen_size_in_bytes(),
            );
            defer allocator.free(zr_frozen_buf);
            try zr.frozen_serialize(zr_frozen_buf);
            var zr_frozen = try Bitmap.frozen_view(allocator, zr_frozen_buf);
            try testing.expect(zr.equals(zr_frozen));
            zr_frozen.deinit(allocator);
        },
    }

    for (0..NUM_BITMAPS) |i| {
        const oc = c.roaring_bitmap_get_cardinality(oracles[i]);
        try std.testing.expectEqual(oc, rs[i].get_cardinality());
    }
    for (rs, oracles) |r, oracle| {
        const ra = &oracle.*.high_low_container;
        if (false) {
            std.debug.print("cr: #{} ", .{ra.*.size});
            roaring_bitmap_printf_describe(oracle, std.debug.print);
            std.debug.print("\n", .{});
        }
        try testing.expectEqual(@as(u32, @bitCast(ra.*.size)), r.array.len);
        for (r.get_containers(), 0..) |zc, i| {
            //                                                                            % 4 maps [1,2,3,4] to [1,2,3,0]
            try testing.expectEqual(@as(zroaring.Typecode, @enumFromInt(ra.*.typecodes[i] % 4)), zc.data.typecode);
            const cr_raw = @as(u32, @bitCast(c.container_get_cardinality(ra.*.containers[i], ra.*.typecodes[i])));
            const cr_card: u32 = if (cr_raw == std.math.maxInt(u32)) // convert -1 (u32 max) to u30 max
                zroaring.constants.BITSET_UNKNOWN_CARDINALITY
            else
                cr_raw;
            try testing.expectEqual(cr_card, zc.get_cardinality());
        }
    }

    if (@import("build-options").run_slow_tests) {
        switch (op) {
            inline .add,
            .add_many,
            .add_range_closed,
            .flip,
            .remove,
            .@"and",
            .@"or",
            .xor,
            .andnot,
            .lazy_or,
            .or_inplace,
            .and_inplace,
            .is_subset,
            .clear,
            .run_optimize,
            .shrink_to_fit,
            => |x| blk: {
                const i = if (@TypeOf(x) == u8) x else x.idx;
                var zrit = rs[i].iterator();
                const crit = c.roaring_iterator_create(oracles[i]);
                defer c.roaring_uint32_iterator_free(crit);

                const max_card = @min(
                    rs[i].get_cardinality(),
                    c.roaring_bitmap_get_cardinality(oracles[i]),
                );
                if (max_card == 0)
                    break :blk;

                var zrbuf: [8192]u32 = undefined;
                var crbuf: [zrbuf.len]u32 = undefined;

                var total_matched: u32 = 0;
                while (total_matched < max_card) {
                    const chunk = @min(max_card - total_matched, zrbuf.len);
                    const zrn = zrit.read(zrbuf[0..chunk]);
                    const crn = c.roaring_uint32_iterator_read(crit, &crbuf[0], chunk);
                    testing.expectEqual(crn, zrn) catch |e| {
                        std.debug.print("OP {t} bitmap {}: length mismatch at offset {}\n", .{ op, i, total_matched });
                        std.debug.print("{f}\n", .{rs[i].fmtLong()});
                        return e;
                    };
                    for (0..zrn) |j| {
                        // std.debug.print("{},{}\n", .{ crbuf[j], zrbuf[j] });
                        testing.expectEqual(crbuf[j], zrbuf[j]) catch |e| {
                            std.debug.print("OP {t} bitmap {}: first mismatch at element {}\n", .{ op, i, total_matched + j });
                            return e;
                        };
                    }
                    total_matched += zrn;
                }
            },
            .or_many, // excluded - not slow
            .portable_serialize,
            .portable_deserialize,
            .frozen_serialize,
            .frozen_view,
            .equals,
            .minimum,
            .maximum,
            .statistics,
            .rank,
            .select,
            .contains,
            .contains_range,
            .and_cardinality,
            .or_cardinality,
            .xor_cardinality,
            .andnot_cardinality,
            .jaccard_index,
            .range_cardinality,
            => {},
        }
    }
}

fn roaring_bitmap_printf_describe(r: [*c]c.roaring_bitmap_t, printf: anytype) void {
    const ra = &r.*.high_low_container;

    printf("{{", .{});
    for (0..@intCast(ra.*.size)) |i| {
        printf("{}: {s} {d}", .{
            ra.*.keys[i],
            c.get_full_container_name(ra.*.containers[i], ra.*.typecodes[i]),
            c.container_get_cardinality(ra.*.containers[i], ra.*.typecodes[i]),
        });
        if (ra.*.typecodes[i] == c.SHARED_CONTAINER_TYPE) {
            printf("(shared count = {})", .{c.croaring_refcount_get(
                &(@as([*c]c.shared_container_t, @ptrCast(@alignCast(ra.*.containers[i]))).*.counter),
            )});
        }

        if (i + 1 < ra.*.size) {
            printf(", ", .{});
        }
    }
    printf("}}", .{});
}

fn cr_perform_ops(allocator: mem.Allocator, ops: []const Op) !void {
    var zrs: [NUM_BITMAPS]Bitmap = @splat(.empty);
    defer for (&zrs) |*x| x.deinit(allocator);
    var crs: [NUM_BITMAPS][*c]c.roaring_bitmap_t = undefined;
    for (&crs) |*o| o.* = c.roaring_bitmap_create().?;
    defer for (crs) |o| c.roaring_bitmap_free(o);

    fuzzprint("\n\n--  perform ops  --\n", .{});
    for (ops) |op| {
        try perform_op(op, &crs, &zrs, allocator);
    }
}

fn fuzzprint(comptime fmt: []const u8, args: anytype) void {
    if (!@import("build-options").fuzzprint) return;
    std.debug.print(fmt, args);
}

test "crash0" {
    // const corpustmp: []const []const Op = @import("fuzz-crash-corpus-tmp.zon");
    // for (corpustmp) |ops| {
    //     try cr_perform_ops(testgpa, ops);
    // }
}

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const testing = std.testing;
const testgpa = testing.allocator;
const assert = std.debug.assert;
const zroaring = @import("root.zig");
const Bitmap = zroaring.Bitmap;
const c = @import("croaring");
