test "croaring oracle fuzz" { // primary zig fuzzing routine
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

fn croaringFuzzFile(io: Io, path: []const u8) !void {
    const contents = loadPath(io, path) catch return;
    defer testgpa.free(contents);
    var smith = testing.Smith{ .in = contents };
    try croaringOracle(&smith, testgpa);
}

test "croaring oracle crash - current" {
    try croaringFuzzFile(testing.io, ".zig-cache/f/crash");
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
        try croaringFuzzFile(io, fbs.buffered());
    }
}

pub const FuzzOp = union(enum) {
    add: Val,
    add_many: Vals,
    add_range_closed: Vals2,
    remove: Remove,
    intersect: BinOp,
    merge: BinOp,
    xor: BinOp,
    andnot: BinOp,
    lazy_or: BinOp,
    or_inplace: BinOpInplace,
    is_subset: BinOp,
    or_many: ManyOp,
    clear: u8,
    run_optimize: u8,
    shrink_to_fit: u8,
    portable_serialize: u8,
    frozen_serialize: u8,
    equals: u8,
    minimum: u8,
    maximum: u8,
    rank: Val,
    select: Val,
    // portable_deserialize, // TODO skipped due to slow/akward file write. could use mmap but not cross platform.
    // get_index, // TODO
    contains: Val,
    contains_range: Vals2,
    contains_many: Vals,

    const Val = struct { idx: u8, val: u32 };
    const Vals2 = struct { idx: u8, val: [2]u32 };
    const Vals = struct { idx: u8, vals: []const u32 };
    const Remove = struct { idx: u8, pick_existing: u8, val: u32 };
    /// example: idx = src1 & src2.
    const BinOp = struct {
        /// destination index.  name `idx` follows other FuzzOps.
        idx: u8,
        src1: u8,
        src2: u8,
    };
    /// example: idx = idx & src1
    const BinOpInplace = struct { idx: u8, src1: u8 };
    const ManyOp = struct { idxs: []const u8 };

    pub const Tag = std.meta.Tag(FuzzOp);
};

const crash_corpus: []const []const FuzzOp = @import("fuzz-crash-corpus.zon");

const MAX_VAL = 100_000_000;
const MAX_RANGE_LEN = 500_000;
const NUM_BITMAPS = 8;

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
            inline .add_range_closed, .contains_range => |t| {
                const start = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                const len = smith.valueRangeLessThan(u32, 1, MAX_RANGE_LEN);
                const val1 = smith.valueRangeLessThan(u32, start, start + len);
                const val2 = smith.valueRangeLessThan(u32, start + len, start + len * 2);
                try perform_op(@unionInit(FuzzOp, @tagName(t), .{ .idx = idx, .val = .{ val1, val2 } }), &oracles, &rs, allocator);
            },
            .remove => try perform_op(.{ .remove = .{
                .idx = idx,
                .pick_existing = smith.value(u8),
                .val = smith.valueRangeLessThan(u32, 0, MAX_VAL),
            } }, &oracles, &rs, allocator),
            inline .intersect,
            .merge,
            .xor,
            .andnot,
            .is_subset,
            .lazy_or,
            => |t| try perform_op(@unionInit(FuzzOp, @tagName(t), .{
                .idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
                .src1 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
                .src2 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
            }), &oracles, &rs, allocator),
            inline .or_inplace => |t| try perform_op(@unionInit(FuzzOp, @tagName(t), .{
                .idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
                .src1 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS),
            }), &oracles, &rs, allocator),
            inline .or_many => |t| {
                var idxs: [NUM_BITMAPS + 1]u8 = undefined;
                const len = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS + 1);
                for (idxs[0..len]) |*x| x.* = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS);
                try perform_op(@unionInit(FuzzOp, @tagName(t), .{ .idxs = idxs[0..len] }), &oracles, &rs, allocator);
            },
            inline .clear,
            .run_optimize,
            .shrink_to_fit,
            .portable_serialize,
            .frozen_serialize,
            .equals,
            .minimum,
            .maximum,
            => |t| try perform_op(@unionInit(FuzzOp, @tagName(t), idx), &oracles, &rs, allocator),
            inline .rank,
            .select,
            .contains,
            => |t| {
                const val = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                try perform_op(@unionInit(FuzzOp, @tagName(t), .{ .idx = idx, .val = val }), &oracles, &rs, allocator);
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

pub export fn zig_fuzz_test(dataptr: [*]const u8, size: usize) void {
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
    pub fn nextOp(smith: *AflSmith, buf: []u32) ?FuzzOp {
        const byte = smith.bytes.takeByte() catch return null;
        const tag: FuzzOp.Tag = @enumFromInt(byte % @typeInfo(FuzzOp).@"union".fields.len);
        const idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null;
        return switch (tag) {
            .add => .{ .add = .{ .idx = idx, .val = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null } },
            .add_many => {
                const len = smith.valueRangeLessThan(u8, 1, @intCast(buf.len + 1)) orelse return null;
                for (buf[0..len]) |*v| v.* = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null;
                return .{ .add_many = .{ .idx = idx, .vals = buf[0..len] } };
            },
            inline .add_range_closed, .contains_range => |t| {
                const start = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null;
                const len = smith.valueRangeLessThan(u32, 1, MAX_RANGE_LEN) orelse return null;
                const val1 = smith.valueRangeLessThan(u32, start, start + len) orelse return null;
                const val2 = smith.valueRangeLessThan(u32, start + len, start + len * 2) orelse return null;
                return @unionInit(FuzzOp, @tagName(t), .{ .idx = idx, .val = .{ val1, val2 } });
            },
            .remove => .{ .remove = .{
                .idx = idx,
                .pick_existing = smith.value(u8) orelse return null,
                .val = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null,
            } },
            inline .intersect,
            .merge,
            .xor,
            .andnot,
            .is_subset,
            .lazy_or,
            => |t| @unionInit(FuzzOp, @tagName(t), .{
                .idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
                .src1 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
                .src2 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
            }),
            inline .or_inplace => |t| @unionInit(FuzzOp, @tagName(t), .{
                .idx = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
                .src1 = smith.valueRangeLessThan(u8, 0, NUM_BITMAPS) orelse return null,
            }),
            inline .or_many => |t| @unionInit(FuzzOp, @tagName(t), .{
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
            .frozen_serialize,
            .equals,
            .minimum,
            .maximum,
            => |t| @unionInit(FuzzOp, @tagName(t), idx),
            inline .rank,
            .select,
            .contains,
            => |t| @unionInit(FuzzOp, @tagName(t), .{ .idx = idx, .val = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null }),
            .contains_many => {
                const len = smith.valueRangeLessThan(u8, 0, @intCast(buf.len + 1)) orelse return null;
                for (buf[0..len]) |*v| v.* = smith.valueRangeLessThan(u32, 0, MAX_VAL) orelse return null;
                return .{ .contains_many = .{ .idx = idx, .vals = buf[0..len] } };
            },
        };
    }
};

const HashMapOracle = std.AutoArrayHashMapUnmanaged(u32, void);
const HashMapOracleSortCtx = struct {
    keys: []u32,
    pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
        return ctx.keys[a_index] < ctx.keys[b_index];
    }
};

fn hashMapOracle(in: []const u8, allocator: mem.Allocator) !void {
    var rbs: [NUM_BITMAPS]Bitmap = @splat(.empty);
    defer for (&rbs) |*rb| rb.deinit(allocator);
    var oracles: [NUM_BITMAPS]HashMapOracle = @splat(.empty);
    defer for (&oracles) |*o| o.deinit(allocator);
    for (&oracles) |*o| try o.ensureTotalCapacity(allocator, 1024 * 16);
    var fbs = Io.Reader.fixed(in);
    var smith = AflSmith{ .bytes = &fbs };

    fuzzprint("\n\n// begin hashMapOracle\n", .{});
    var buf: [8]u32 = undefined;
    while (smith.nextOp(&buf)) |op| {
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

pub fn writeOpFile(ctx: AflCtx, ops: []const FuzzOp) !void {
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

pub fn writeOp(op: FuzzOp, writer: *Io.Writer) !void {
    try writer.writeByte(@intFromEnum(op));
    switch (op) {
        inline else => |x| try writer.writeByte(if (@TypeOf(x) == u8) x else x.idx),
        .or_many => {},
    }
    switch (op) {
        .add => |o| try writer.writeInt(u32, o.val, .little),
        .add_many => |o| {
            try writer.writeByte(@intCast(o.vals.len));
            for (o.vals) |v| try writer.writeInt(u32, v, .little);
        },
        .add_range_closed, .contains_range => |o| {
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
        .intersect,
        .merge,
        .xor,
        .andnot,
        .is_subset,
        .lazy_or,
        => |o| try writer.writeAll(&.{ o.idx, o.src1, o.src2 }),
        .or_inplace,
        => |o| try writer.writeAll(&.{ o.idx, o.src1 }),
        .or_many,
        => |o| {
            try writer.writeByte(@intCast(o.idxs.len));
            try writer.writeAll(o.idxs);
        },
        .contains,
        .rank,
        .select,
        => |o| try writer.writeInt(u32, o.val, .little),
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
        .minimum,
        .maximum,
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
    const Os = @TypeOf(oracles);
    const is_cr = Os == *[NUM_BITMAPS][*c]c.roaring_bitmap_t;
    const is_hashmap = Os == *[NUM_BITMAPS]HashMapOracle;
    comptime assert(is_cr or is_hashmap);
    switch (op) {
        .add, // only print ops which may modify
        .remove,
        .intersect,
        .merge,
        .xor,
        .andnot,
        .lazy_or,
        .or_inplace,
        .is_subset,
        .clear,
        .run_optimize,
        .shrink_to_fit,
        => fuzzprint("{},\n", .{op}),
        .add_range_closed,
        => |x| fuzzprint(".{{ .add_range_closed = .{{ .idx = {}, .val = .{{ {}, {} }} }} }},\n", .{ x.idx, x.val[0], x.val[1] }),
        .add_many,
        => |x| fuzzprint(".{{ .add_many = .{{ .idx = {}, .vals = .{any} }} }},\n", .{ x.idx, x.vals }),
        .or_many,
        => |x| fuzzprint(".{{ .or_many = .{{ .idxs = .{any} }} }},\n", .{x.idxs}),
        // don't print ops which don't modify - usually not part of reproduction
        .portable_serialize,
        .frozen_serialize,
        .equals,
        .minimum,
        .maximum,
        .contains,
        .contains_many,
        .contains_range,
        .rank,
        .select,
        => {},
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
                try oracles[o.idx].ensureUnusedCapacity(allocator, o.vals.len);
                for (o.vals) |x|
                    oracles[o.idx].putAssumeCapacity(x, {});
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
                while (x <= val2) : (x += 1)
                    oracles[o.idx].putAssumeCapacity(x, {});
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
        .intersect, .merge, .xor, .andnot, .lazy_or => |o| {
            var res = switch (op) {
                .intersect => try Bitmap.intersect(&rs[o.src1], allocator, &rs[o.src2]),
                .merge => try Bitmap.merge(&rs[o.src1], allocator, &rs[o.src2]),
                .xor => try Bitmap.xor(&rs[o.src1], allocator, &rs[o.src2]),
                .andnot => try Bitmap.andnot(&rs[o.src1], allocator, &rs[o.src2]),
                .lazy_or => try Bitmap.lazy_or(
                    &rs[o.src1],
                    allocator,
                    &rs[o.src2],
                    zroaring.constants.LAZY_OR_BITSET_CONVERSION_TO_FULL,
                ),
                else => unreachable,
            };
            errdefer res.deinit(allocator);

            if (is_cr) {
                const cr_res = switch (op) {
                    .intersect => c.roaring_bitmap_and(oracles[o.src1], oracles[o.src2]),
                    .merge => c.roaring_bitmap_or(oracles[o.src1], oracles[o.src2]),
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
                if (op == .lazy_or) c.roaring_bitmap_repair_after_lazy(oracles[o.idx]);
            } else switch (op) {
                .intersect => {
                    var ret = HashMapOracle.empty;
                    try ret.ensureTotalCapacity(allocator, @min(
                        oracles[o.src1].count(),
                        oracles[o.src2].count(),
                    ));
                    for (oracles[o.src1].keys()) |key| {
                        if (oracles[o.src2].contains(key)) {
                            ret.putAssumeCapacity(key, {});
                        }
                    }
                    oracles[o.idx].deinit(allocator);
                    oracles[o.idx] = ret;
                },
                .merge, .lazy_or => {
                    var ret = HashMapOracle.empty;
                    try ret.ensureTotalCapacity(
                        allocator,
                        oracles[o.src1].count() + oracles[o.src2].count(),
                    );
                    for (oracles[o.src1].keys()) |key|
                        ret.putAssumeCapacity(key, {});
                    for (oracles[o.src2].keys()) |key|
                        ret.putAssumeCapacity(key, {});

                    oracles[o.idx].deinit(allocator);
                    oracles[o.idx] = ret;
                },
                .xor => {
                    var ret = HashMapOracle.empty;
                    try ret.ensureTotalCapacity(
                        allocator,
                        oracles[o.src1].count() + oracles[o.src2].count(),
                    );
                    const s1 = &oracles[o.src1];
                    const s2 = &oracles[o.src2];
                    for (s1.keys()) |key|
                        if (!s2.contains(key)) ret.putAssumeCapacity(key, {});
                    for (s2.keys()) |key|
                        if (!s1.contains(key)) ret.putAssumeCapacity(key, {});

                    oracles[o.idx].deinit(allocator);
                    oracles[o.idx] = ret;
                },
                .andnot => {
                    var ret = HashMapOracle.empty;
                    try ret.ensureTotalCapacity(allocator, @max(
                        oracles[o.src1].count(),
                        oracles[o.src2].count(),
                    ));
                    for (oracles[o.src1].keys()) |key| {
                        if (!oracles[o.src2].contains(key))
                            ret.putAssumeCapacity(key, {});
                    }

                    oracles[o.idx].deinit(allocator);
                    oracles[o.idx] = ret;
                },
                else => unreachable,
            }

            if (op == .lazy_or)
                try res.repair_after_lazy(allocator);

            rs[o.idx].deinit(allocator);
            rs[o.idx] = res;
        },
        .or_inplace => |o| {
            try rs[o.idx].or_inplace(allocator, &rs[o.src1]);
            if (is_cr) {
                c.roaring_bitmap_or_inplace(oracles[o.idx], oracles[o.src1]);
            } else {
                try oracles[o.idx].ensureUnusedCapacity(
                    allocator,
                    oracles[o.src1].count() * 5 / 4,
                );
                for (oracles[o.src1].keys()) |key|
                    oracles[o.idx].putAssumeCapacity(key, {});
            }
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

            if (is_cr) {
                const ret = c.roaring_bitmap_or_many(o.idxs.len, @ptrCast(&osbuf));
                if (oracles[o.idxs[0]]) |old| c.roaring_bitmap_free(old);
                oracles[o.idxs[0]] = ret;
            } else {
                var cap: usize = 0;
                for (o.idxs) |src| cap += oracles[src].count();
                var ret = HashMapOracle.empty;
                try ret.ensureTotalCapacity(allocator, cap);
                for (o.idxs) |src| {
                    for (oracles[src].keys()) |key|
                        ret.putAssumeCapacity(key, {});
                }
                oracles[o.idxs[0]].deinit(allocator);
                oracles[o.idxs[0]] = ret;
            }
        },
        .is_subset => |o| {
            try std.testing.expectEqual(
                if (is_cr)
                    c.roaring_bitmap_is_subset(oracles[o.src1], oracles[o.src2])
                else blk: {
                    const s1 = oracles[o.src1];
                    const s2 = oracles[o.src2];
                    if (s1.count() > s2.count()) break :blk false;
                    for (s1.keys()) |key| {
                        if (!s2.contains(key)) break :blk false;
                    }
                    break :blk true;
                },
                rs[o.src1].is_subset(rs[o.src2]),
            );
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
            const x = rs[idx].portable_serialize(&w.writer, &runflags) catch |e| switch (e) {
                // this allows test "allocation failures" to pass
                error.WriteFailed => return error.OutOfMemory,
            };
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
        .minimum => |idx| {
            try std.testing.expectEqual(
                if (is_cr)
                    c.roaring_bitmap_minimum(oracles[idx])
                else if (oracles[idx].count() == 0)
                    std.math.maxInt(u32)
                else
                    mem.min(u32, oracles[idx].keys()),
                rs[idx].minimum(),
            );
        },
        .maximum => |idx| {
            try std.testing.expectEqual(
                if (is_cr)
                    c.roaring_bitmap_maximum(oracles[idx])
                else if (oracles[idx].count() == 0)
                    0
                else
                    mem.max(u32, oracles[idx].keys()),
                rs[idx].maximum(),
            );
        },
        .rank => |o| {
            try std.testing.expectEqual(
                if (is_cr)
                    c.roaring_bitmap_rank(oracles[o.idx], o.val)
                else blk: {
                    oracles[o.idx].sortUnstable(HashMapOracleSortCtx{ .keys = oracles[o.idx].keys() });
                    break :blk for (oracles[o.idx].keys(), 0..) |k, i| {
                        if (k > o.val) break i;
                    } else oracles[o.idx].count();
                },
                rs[o.idx].rank(o.val),
            );
        },
        .select => |o| blk: {
            const card: u32 = @intCast(if (is_cr)
                c.roaring_bitmap_get_cardinality(oracles[o.idx])
            else
                oracles[o.idx].count());
            if (card == 0) break :blk;
            const mzr_val = rs[o.idx].select(o.val % card);
            const zr_ok = mzr_val != null;
            if (is_cr) {
                var cr_val: u32 = undefined;
                const cr_ok = c.roaring_bitmap_select(
                    oracles[o.idx],
                    o.val % card,
                    &cr_val,
                );
                try std.testing.expectEqual(cr_ok, zr_ok);
                if (zr_ok) try std.testing.expectEqual(cr_val, mzr_val.?);
            } else {
                if (card == 0) {
                    try std.testing.expect(!zr_ok);
                } else {
                    try std.testing.expect(zr_ok);
                    if (zr_ok) {
                        oracles[o.idx].sortUnstable(HashMapOracleSortCtx{ .keys = oracles[o.idx].keys() });
                        try std.testing.expectEqual(
                            oracles[o.idx].keys()[o.val % card],
                            mzr_val.?,
                        );
                    }
                }
            }
        },
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
        .contains_range => |o| if (is_cr) {
            try std.testing.expectEqual(
                c.roaring_bitmap_contains_range(oracles[o.idx], o.val[0], o.val[1]),
                rs[o.idx].contains_range(o.val[0], o.val[1]),
            );
        } else {
            var val = o.val[0];
            while (val < o.val[1]) : (val += 1) {
                try std.testing.expectEqual(
                    oracles[o.idx].contains(val),
                    rs[o.idx].contains(val),
                );
            }
        },
    }

    for (0..NUM_BITMAPS) |i| {
        const oc = if (is_cr)
            c.roaring_bitmap_get_cardinality(oracles[i])
        else
            oracles[i].count();
        try std.testing.expectEqual(oc, rs[i].get_cardinality());
    }
    if (is_cr) {
        for (rs, oracles) |r, oracle| {
            const ra = &oracle.*.high_low_container;
            if (false) {
                std.debug.print("cr: #{} ", .{ra.*.size});
                roaring_bitmap_printf_describe(oracle, std.debug.print);
                std.debug.print("\n", .{});
            }
            try testing.expectEqual(@as(u32, @intCast(ra.*.size)), r.array.ptr(.len).*);
            for (r.slice(.containers, .len), 0..) |zc, i| {
                //                                                                            % 4 maps [1,2,3,4] to [1,2,3,0]
                try testing.expectEqual(@as(zroaring.Typecode, @enumFromInt(ra.*.typecodes[i] % 4)), zc.typecode);
                const cr_raw = @as(u32, @bitCast(c.container_get_cardinality(ra.*.containers[i], ra.*.typecodes[i])));
                const cr_card: u32 = if (cr_raw == std.math.maxInt(u32)) // convert -1 (u32 max) to u30 max
                    zroaring.constants.BITSET_UNKNOWN_CARDINALITY
                else
                    cr_raw;
                try testing.expectEqual(cr_card, zc.get_cardinality(r));
            }
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

fn cr_perform_ops(allocator: mem.Allocator, ops: []const FuzzOp) !void {
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

test "crash reproductions" {
    for (crash_corpus) |ops| {
        try cr_perform_ops(testgpa, ops);
    }
}

test "crash0" {
    if (true) return error.SkipZigTest;
    const corpustmp: []const []const FuzzOp = @import("fuzz-crash-corpus-tmp.zon");
    for (corpustmp) |ops| {
        try cr_perform_ops(testgpa, ops);
    }
}

test "allocation failures from crash reproductions" {
    if (!@import("build-options").run_slow_tests) return error.SkipZigTest;
    for (crash_corpus) |ops| {
        try testing.checkAllAllocationFailures(testgpa, cr_perform_ops, .{ops});
    }
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
