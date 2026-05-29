test "croaring oracle" {
    const Context = struct {
        fn testOne(_: @This(), smith: *testing.Smith) anyerror!void {
            try croaringOracle(smith, testgpa);
        }
    };
    const corpus = try loadCorpus(testing.io);
    defer {
        for (corpus) |x| testgpa.free(x);
        testgpa.free(corpus);
    }
    try std.testing.fuzz(Context{}, Context.testOne, .{ .corpus = corpus });
}

fn loadPath(io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, testgpa, .unlimited) catch |e| {
        std.log.info("loadPath: failed to read path '{s}'", .{path});
        return e;
    };
}

fn loadCorpus(io: std.Io) ![]const []const u8 {
    var ret: std.ArrayList([]const u8) = .empty;
    if (loadPath(io, ".zig-cache/f/crash")) |contents| // skip if missing
        try ret.append(testgpa, contents)
    else |_| {}

    const path = "testdata/crashfiles";
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind != .file) continue;
        var buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        try fbs.print("{s}/{s}", .{ path, e.name });

        if (loadPath(io, fbs.buffered())) |contents| // skip if missing
            try ret.append(testgpa, contents)
        else |_| {}
    }

    return ret.toOwnedSlice(testgpa);
}

fn croaringOracleFile(io: std.Io, path: []const u8) !void {
    const contents = loadPath(io, path) catch return;
    defer testgpa.free(contents);
    var smith = testing.Smith{ .in = contents };
    try croaringOracle(&smith, testgpa);
}

test "croaring oracle crash - current" {
    const io = testing.io;
    try croaringOracleFile(io, ".zig-cache/f/crash");
}

test "croaring oracle crashes" {
    const io = testing.io;
    const path = "testdata/crashfiles";
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind != .file) continue;
        var buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        try fbs.print("{s}/{s}", .{ path, e.name });
        try croaringOracleFile(io, fbs.buffered());
    }
}

pub const FuzzOp = union(enum) {
    add: u32,
    add_many: []const u32,
    add_range_closed: [2]u32,
    remove: u32,
    clear,
    run_optimize,
    shrink_to_fit,
    portable_serialize,
    frozen_serialize,
    equals,
    // portable_deserialize, // TODO skipped due to slow/akward file write. could use mmap but not cross platform.
    // get_index, // TODO
    contains: u32,
    contains_many: []const u32,

    pub const Tag = std.meta.Tag(FuzzOp);
};

const MAX_VAL = 10_000_000;
const MAX_RANGE_LEN = 50_000;

/// provider may be a `*testing.Smith` or a `std.Random`
fn fillArray(provider: anytype, array: anytype) u8 {
    const valFn = if (@TypeOf(provider) == *testing.Smith)
        testing.Smith.valueRangeLessThan
    else if (@TypeOf(provider) == std.Random)
        std.Random.intRangeLessThan
    else
        unreachable;

    const len = valFn(provider, u8, 1, array.len);
    for (0..len) |i| array[i] = valFn(provider, u32, 0, MAX_VAL);
    return len;
}

fn croaringOracle(smith: *testing.Smith, allocator: mem.Allocator) !void {
    var r = zroaring.Bitmap.empty;
    defer r.deinit(allocator);
    const oracle = c.roaring_bitmap_create().?;
    defer c.roaring_bitmap_free(oracle);

    fuzzprint("\n\n// begin croaringOracle\n", .{});
    while (!smith.eos()) {
        const tag = smith.value(FuzzOp.Tag);
        switch (tag) {
            .add => {
                const val = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                try perform_op(.{ .add = val }, oracle, &r, allocator);
            },
            .add_many => {
                var vals: [8]u32 = undefined;
                const len = fillArray(smith, &vals);
                try perform_op(.{ .add_many = vals[0..len] }, oracle, &r, allocator);
            },
            .add_range_closed => {
                const start = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                const len = smith.valueRangeLessThan(u32, 1, MAX_RANGE_LEN);
                const val1 = smith.valueRangeLessThan(u32, start, start + len);
                const val2 = smith.valueRangeLessThan(u32, start + len, start + len * 2);
                try perform_op(.{ .add_range_closed = .{ val1, val2 } }, oracle, &r, allocator);
            },
            .remove => { // weighted 10:1 to remove existing values
                const select_found = smith.boolWeighted(1, 9); // usually true
                const val = if (select_found) val: {
                    const card = c.roaring_bitmap_get_cardinality(oracle);
                    if (card == 0) break :val smith.valueRangeLessThan(u32, 0, MAX_VAL);
                    const rank = smith.valueRangeLessThan(u32, 0, @truncate(card));
                    var val: u32 = undefined;
                    assert(c.roaring_bitmap_select(oracle, rank, &val));
                    break :val val;
                } else smith.valueRangeLessThan(u32, 0, MAX_VAL);
                try perform_op(.{ .remove = val }, oracle, &r, allocator);
            },
            .clear => try perform_op(.clear, oracle, &r, allocator),
            .run_optimize => try perform_op(.run_optimize, oracle, &r, allocator),
            .shrink_to_fit => try perform_op(.shrink_to_fit, oracle, &r, allocator),
            .portable_serialize => try perform_op(.portable_serialize, oracle, &r, allocator),
            .frozen_serialize => try perform_op(.frozen_serialize, oracle, &r, allocator),
            .equals => try perform_op(.equals, oracle, &r, allocator),
            .contains => {
                const val = smith.valueRangeLessThan(u32, 0, MAX_VAL);
                try perform_op(.{ .contains = val }, oracle, &r, allocator);
            },
            .contains_many => {
                var vals: [8]u32 = undefined;
                const len = fillArray(smith, &vals);
                try perform_op(.{ .contains_many = vals[0..len] }, oracle, &r, allocator);
            },
        }
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

const HashMapOracle = std.AutoArrayHashMapUnmanaged(u32, void);

fn hashMapOracle(in: []const u8, allocator: mem.Allocator) !void {
    var r = zroaring.Bitmap.empty;
    defer r.deinit(allocator);
    var oracle = HashMapOracle.empty;
    defer oracle.deinit(allocator);
    try oracle.ensureTotalCapacity(allocator, 1024 * 16);
    var prng = FuzzPrng{ .input = in };
    const random = prng.random();
    fuzzprint("\n\n// begin hashMapOracle\n", .{});
    while (!prng.eos()) {
        const tag = random.enumValue(FuzzOp.Tag);
        switch (tag) {
            .add => try perform_op(.{ .add = random.intRangeLessThan(u32, 0, MAX_VAL) }, &oracle, &r, allocator),
            .add_many => {
                var vals: [8]u32 = undefined;
                const len = fillArray(random, &vals);
                try perform_op(.{ .add_many = vals[0..len] }, &oracle, &r, allocator);
            },
            .add_range_closed => {
                const start = random.intRangeLessThan(u32, 0, MAX_VAL);
                const len = random.intRangeLessThan(u16, 1, MAX_RANGE_LEN);
                const val1 = random.intRangeLessThan(u32, start, start + len);
                const val2 = random.intRangeLessThan(u32, start + len, start + len * 2);
                try perform_op(.{ .add_range_closed = .{ val1, val2 } }, &oracle, &r, allocator);
            },
            .remove => { // weighted 10:1 to remove existing values
                const select_found = random.intRangeLessThan(u8, 0, 10) > 0; // usually true
                const val = if (select_found) val: {
                    const card = oracle.count();
                    if (card == 0) break :val random.intRangeLessThan(u32, 0, MAX_VAL);
                    const rank = random.intRangeLessThan(u32, 0, @truncate(card));
                    break :val oracle.keys()[rank];
                } else random.intRangeLessThan(u32, 0, MAX_VAL);
                try perform_op(.{ .remove = val }, &oracle, &r, allocator);
            },
            .clear => try perform_op(.clear, &oracle, &r, allocator),
            .run_optimize => try perform_op(.run_optimize, &oracle, &r, allocator),
            .shrink_to_fit => try perform_op(.shrink_to_fit, &oracle, &r, allocator),
            .portable_serialize => try perform_op(.portable_serialize, &oracle, &r, allocator),
            .frozen_serialize => try perform_op(.frozen_serialize, &oracle, &r, allocator),
            .equals => try perform_op(.equals, &oracle, &r, allocator),
            .contains => try perform_op(.{ .contains = random.intRangeLessThan(u32, 0, MAX_VAL) }, &oracle, &r, allocator),
            .contains_many => {
                var vals: [8]u32 = undefined;
                const len = fillArray(random, &vals);
                try perform_op(.{ .contains_many = vals[0..len] }, &oracle, &r, allocator);
            },
        }
    }
}

// -- end AFL fuzzing

/// oracle must be [*c]c.roaring_bitmap_t or *HashMapOracle.
fn perform_op(
    op: FuzzOp,
    oracle: anytype,
    r: *Bitmap,
    allocator: mem.Allocator,
) !void {
    const O = @TypeOf(oracle);
    const is_cr = O == [*c]c.roaring_bitmap_t;
    const is_hashmap = O == *HashMapOracle;
    comptime assert(is_cr or is_hashmap);
    switch (op) {
        .add,
        .add_many,
        .add_range_closed,
        .remove,
        => fuzzprint(".{{ .{t} = ", .{op}),
        .clear,
        .run_optimize,
        .shrink_to_fit,
        .portable_serialize,
        .frozen_serialize,
        .equals,
        => fuzzprint(".{t},\n", .{op}),
        .contains,
        .contains_many,
        => {}, // don't print, not part of reproduction
    }
    switch (op) {
        .add => |val| {
            fuzzprint("{} }},\n", .{val});
            try r.add(allocator, val);
            if (is_cr)
                c.roaring_bitmap_add(oracle, val)
            else
                try oracle.put(allocator, val, {});
        },
        .add_many => |vals| {
            fuzzprint("&.{{ ", .{});
            for (vals, 0..) |val, i| {
                if (i != 0) fuzzprint(", ", .{});
                fuzzprint("{}", .{val});
            }
            fuzzprint(" }} }},\n", .{});
            _ = try r.add_many(allocator, vals);
            if (is_cr)
                c.roaring_bitmap_add_many(oracle, vals.len, vals.ptr)
            else {
                try oracle.ensureUnusedCapacity(allocator, @intCast(vals.len));
                for (vals) |x| oracle.putAssumeCapacity(x, {});
            }
        },
        .add_range_closed => |rg| {
            const val1, const val2 = rg;
            fuzzprint(".{{ {}, {} }} }},\n", .{ val1, val2 });
            try r.add_range_closed(allocator, val1, val2);
            if (is_cr)
                c.roaring_bitmap_add_range_closed(oracle, val1, val2)
            else {
                try oracle.ensureUnusedCapacity(allocator, val2 + 1 - val1);
                var x = val1;
                while (x <= val2) : (x += 1) oracle.putAssumeCapacity(x, {});
            }
        },
        .remove => |val| {
            fuzzprint("{} }},\n", .{val});
            try std.testing.expectEqual(
                if (is_cr)
                    c.roaring_bitmap_remove_checked(oracle, val)
                else
                    oracle.swapRemove(val),
                try r.remove_checked(allocator, val),
            );
        },
        .clear => {
            r.clear_retaining_capacity();
            if (is_cr)
                c.roaring_bitmap_clear(oracle)
            else
                oracle.clearRetainingCapacity();
        },
        .run_optimize => {
            const res = try r.run_optimize(allocator);
            if (is_cr)
                try testing.expectEqual(
                    c.roaring_bitmap_run_optimize(oracle),
                    res,
                );
        },
        .shrink_to_fit => {
            _ = try r.shrink_to_fit(allocator);
            if (is_cr)
                _ = c.roaring_bitmap_shrink_to_fit(oracle);
        },
        .portable_serialize => {
            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            var runflags: zroaring.RunFlags = undefined;
            const x = try r.portable_serialize(&w.writer, &runflags);
            const buf = try allocator.alloc(u8, x);
            defer allocator.free(buf);
            if (is_cr) {
                try testing.expectEqual(
                    c.roaring_bitmap_portable_serialize(oracle, buf.ptr),
                    x,
                );
                try testing.expectEqualSlices(u8, buf, w.written());
            }
        },
        .frozen_serialize => {
            const size = r.frozen_size_in_bytes();
            const buf = try allocator.alloc(u8, size);
            defer allocator.free(buf);
            try r.frozen_serialize(buf);
            if (is_cr) {
                try testing.expectEqual(
                    c.roaring_bitmap_frozen_size_in_bytes(oracle),
                    size,
                );
                // TODO repro and file bug for UB in c.roaring_bitmap_frozen_serialize here
                // const buf2 = try allocator.alloc(u8, size);
                // defer allocator.free(buf2);
                // c.roaring_bitmap_frozen_serialize(oracle, buf2.ptr);
                // try testing.expectEqualSlices(u8, buf, buf2);
            }
        },
        .equals => try testing.expect(r.equals(r.*)),
        // don't print, not part of reproduction
        .contains => |val| {
            try std.testing.expectEqual(
                if (is_cr)
                    c.roaring_bitmap_contains(oracle, val)
                else
                    oracle.contains(val),
                r.contains(val),
            );
        },
        .contains_many => |vals| {
            for (vals) |val| {
                try std.testing.expectEqual(
                    if (is_cr)
                        c.roaring_bitmap_contains(oracle, val)
                    else
                        oracle.contains(val),
                    r.contains(val),
                );
            }
        },
    }
    try std.testing.expectEqual(
        if (is_cr)
            c.roaring_bitmap_get_cardinality(oracle)
        else
            oracle.count(),
        r.get_cardinality(),
    );
}

fn perform_ops(ops: []const FuzzOp) !void {
    const cr = c.roaring_bitmap_create() orelse return error.CRoaringAllocFailed;
    defer c.roaring_bitmap_free(cr);
    var zr: Bitmap = .empty;
    defer zr.deinit(testgpa);

    errdefer std.debug.print("{f}\n", .{zr.fmtLong()});
    fuzzprint("\n\n--  perform ops  --\n", .{});
    for (ops) |op| {
        try perform_op(op, cr, &zr, testgpa);
    }
}

fn fuzzprint(comptime fmt: []const u8, args: anytype) void {
    if (!@import("build-options").fuzzprint) return;
    std.debug.print(fmt, args);
}

test "crash reproductions" {
    try perform_ops(&.{
        .{ .add_many = &.{ 98128, 17714 } },
        .{ .add_range_closed = .{ 0, 100 } },
    });

    try perform_ops(&.{
        .{ .add = 28939 },
        .{ .add_range_closed = .{ 58, 109 } },
        .{ .add_range_closed = .{ 15, 158 } },
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
        .clear,
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
        .clear,
        .{ .remove = 63913 },
        .clear,
        .{ .add = 51548 },
        .{ .add_range_closed = .{ 14181, 14276 } },
        .{ .add_range_closed = .{ 814, 945 } },
        .{ .remove = 63913 },
        .{ .add_many = &.{93120} },
        .{ .add_range_closed = .{ 5677, 5702 } },
        .{ .add_many = &.{ 27047, 95148, 96415, 27461 } },
        .{ .add_many = &.{ 16912, 74410, 93120, 59285 } },
    });

    try perform_ops(&.{
        .{ .add = 26360 },
        .{ .add_range_closed = .{ 7557, 7640 } },
        .run_optimize,
        .{ .add_many = &.{ 66305, 6151, 80245, 13872, 7641, 7641 } },
    });

    try perform_ops(&.{ // run optimize run to array
        .{ .add_range_closed = .{ 13042, 13044 } },
        .{ .add = 62034 },
        .{ .add_many = &.{ 56204, 13694, 95054, 72879 } },
        .run_optimize,
    });

    try perform_ops(&.{ // run_container_add_range_nruns stale ptr
        .{ .add = 86940 },
        .{ .add_many = &.{ 78327, 33246, 28925, 27574, 3773, 75436, 90838 } },
        .{ .contains_many = &.{ 4218, 53202, 73992, 78031 } },
        .{ .add_range_closed = .{ 12485, 12562 } },
        .{ .add_range_closed = .{ 1788, 1883 } },
        .{ .add_many = &.{ 15443, 80245, 46573, 8525, 4618, 57642, 4618 } },
        .{ .remove = 61611 },
        .run_optimize,
        .{ .add_many = &.{ 9606, 35473, 53110, 96833, 56206, 19615, 89556 } },
        .{ .add_range_closed = .{ 6425, 6597 } },
    });

    try perform_ops(&.{ // break run in two when blockslen==blockscapacity
        .{ .add_many = &.{ 71302, 41283, 5184, 53083 } },
        .run_optimize,
        .{ .add_range_closed = .{ 3356, 3443 } },
        .{ .add_range_closed = .{ 11478, 11585 } },
        .{ .add_range_closed = .{ 10140, 10242 } },
        .{ .add_range_closed = .{ 4020, 4068 } },
        .{ .add_range_closed = .{ 1593, 1748 } },
        .run_optimize,
        .{ .remove = 1680 },
    });

    try perform_ops(&.{ // convert_run_to_efficient_container integer overflow
        .run_optimize,
        .{ .add_range_closed = .{ 8404, 8449 } },
        .{ .add_range_closed = .{ 8349, 8534 } },
        .run_optimize,
        .{ .add_range_closed = .{ 8369, 8486 } },
        .{ .add_range_closed = .{ 4477, 4544 } },
        .{ .add_many = &.{ 4435, 42585, 13881, 34164, 21153 } },
        .{ .contains_many = &.{ 50428, 72937, 13881, 35471, 2056, 52358 } },
        .{ .add_range_closed = .{ 9468, 9585 } },
        .{ .remove = 9559 },
        .{ .add_many = &.{ 57594, 84215, 0, 9586, 57594, 3007 } },
        .run_optimize,
        .run_optimize,
        .{ .contains_many = &.{ 9586, 9586, 76212, 6165 } },
        .{ .remove = 42662 },
        .{ .add_many = &.{57594} },
        .{ .remove = 57594 },
        .{ .add_range_closed = .{ 2639, 2642 } },
        .{ .add_many = &.{ 4825, 65535 } },
        .run_optimize,
    });

    try perform_ops(&.{ // add_range_closed blockoffset counting bug
        .{ .add_range_closed = .{ 269193, 269194 } },
        .{ .add_many = &.{ 573007, 65042, 934201, 955639, 952480, 934201 } },
        .{ .add_range_closed = .{ 295, 1717 } },
        .{ .shrink_to_fit = {} },
        .{ .add_range_closed = .{ 618200, 619690 } },
        .run_optimize,
        .{ .add = 65536 },
        .{ .add_range_closed = .{ 524057, 524674 } },
        .{ .add_range_closed = .{ 700979, 701862 } },
    });

    try perform_ops(&.{ // add_container_blocks overflow, uninit container bug
        .{ .add = 602334 },
        .{ .add_range_closed = .{ 589467, 589986 } },
    });

    try perform_ops(&.{ // create_range: array unimplemented
        .{ .add_range_closed = .{ 654535, 655360 } },
    });

    try perform_ops(&.{ // create range: overflow
        .{ .add = 74473 },
        .{ .add_range_closed = .{ 262143, 262845 } },
    });

    try perform_ops(&.{ // container_add_range bitset
        .{ .add = 21571 },
        .{ .add_range_closed = .{ 230, 5661 } },
    });

    try perform_ops(&.{ // container_add_range bitset
        .{ .add_many = &.{ 129631, 93925 } },
        .{ .add = 65536 },
        .{ .add_range_closed = .{ 87, 7994 } },
        .run_optimize,
        .{ .shrink_to_fit = {} },
        .{ .add_range_closed = .{ 102782, 107350 } },
    });

    try perform_ops(&.{ // convert_run_optimize, bitset, update blockslen
        .{ .add = 21571 },
        .{ .add_range_closed = .{ 230, 5482 } },
        .run_optimize,
        .{ .add_range_closed = .{ 355102, 356802 } },
    });

    try perform_ops(&.{ // array_container_grow: use calc_capacity()
        .{ .add_many = &.{ 129631, 93925 } },
        .{ .add = 65536 },
        .{ .add_range_closed = .{ 87, 88 } },
        .run_optimize,
        .{ .shrink_to_fit = {} },
        .{ .add_range_closed = .{ 102782, 103370 } },
    });

    try perform_ops(&.{ // bitset_lenrange_cardinality: popcount not ctz
        .{ .add_range_closed = .{ 269193, 269194 } },
        .clear,
        .{ .add_many = &.{ 246143, 479398, 519512, 479398, 2304, 93925 } },
        .{ .add_range_closed = .{ 105168, 109491 } },
        .{ .add_many = &.{ 976463, 48064 } },
        .{ .add_range_closed = .{ 222979, 224481 } },
        .{ .shrink_to_fit = {} },
        .{ .add_range_closed = .{ 63199, 63735 } },
        .{ .add_range_closed = .{ 871311, 872258 } },
        .{ .shrink_to_fit = {} },
        .{ .add_range_closed = .{ 501983, 503122 } },
        .{ .add = 65536 },
        .{ .remove = 224099 },
        .{ .add_range_closed = .{ 1511, 1512 } },
        .{ .remove = 981223 },
        .{ .add_many = &.{830160} },
        .{ .add_range_closed = .{ 654898, 655635 } },
        .{ .add_range_closed = .{ 997826, 997827 } },
        .{ .add_range_closed = .{ 102455, 103396 } },
    });

    try perform_ops(&.{ // bitset_lenrange_cardinality: u64 to avoid overflow
        .{ .add = 75944 },
        .{ .add_range_closed = .{ 86940, 94246 } },
        .{ .add_range_closed = .{ 87951, 94779 } },
    });

    try perform_ops(&.{ // bitset_set_lenrange: use wrapping math to avoid overflow
        .{ .add = 29614 },
        .{ .add = 65536 },
        .{ .add_range_closed = .{ 63252, 71190 } },
    });

    try perform_ops(&.{ // bitset_lenrange_cardinality: use wrapping math to avoid overflow
        .{ .add = 232231 },
        .{ .add_range_closed = .{ 11141, 11245 } },
        .{ .remove = 11245 },
        .{ .add_range_closed = .{ 223401, 231936 } },
        .{ .add_range_closed = .{ 192113, 199991 } },
    });

    try perform_ops(&.{ // remove_at_index @memmove length bug
        .{ .add = 956902 },
        .shrink_to_fit,
        .{ .add_many = &.{ 547367, 43854 } },
        .clear,
        .{ .add_range_closed = .{ 63253, 68554 } },
        .{ .remove = 8283 },
        .{ .add = 80434 },
        .{ .add_many = &.{ 929337, 106248, 347873, 514060, 164928 } },
        .{ .add = 533060 },
        .{ .remove = 164928 },
    });

    try perform_ops(&.{ // Container.remove: skip assert_valid
        .clear,
        .{ .add_many = &.{ 188901, 624734, 783759 } },
        .shrink_to_fit,
        .{ .add_range_closed = .{ 131424, 134903 } },
        .{ .add_range_closed = .{ 174930, 175543 } },
        .{ .add_many = &.{ 511169, 736404, 616057, 136937, 140723, 912071, 624980 } },
        .shrink_to_fit,
        .{ .remove = 133236 },
    });

    try perform_ops(&.{
        .{ .add_range_closed = .{ 720895, 723787 } },
        .{ .add_range_closed = .{ 654236, 733271 } },
    });

    try perform_ops(&.{ // convert_run_optimize: blockslen double increment
        .{ .add_many = &.{ 624980, 288844, 195140, 851109, 442054, 90431 } },
        .run_optimize,
        .{ .add_range_closed = .{ 973441, 976611 } },
        .{ .remove = 90431 },
        .{ .add_range_closed = .{ 130468, 135996 } },
        .{ .add_range_closed = .{ 2856152, 2858382 } },
        .{ .add_range_closed = .{ 107184, 107384 } },
        .frozen_serialize,
        .{ .remove = 107184 },
        .{ .add_many = &.{ 624980, 50064, 814965, 963343, 50064, 138676, 168443 } },
        .{ .add_many = &.{ 99204, 299749, 951000, 804571 } },
        .portable_serialize,
        .{ .remove = 135567 },
        .run_optimize,
        .{ .add_range_closed = .{ 921371, 924952 } },
        .{ .add_range_closed = .{ 130836, 132565 } },
        .{ .remove = 974319 },
        .{ .add_many = &.{50064} },
        .{ .add_range_closed = .{ 259797, 285999 } },
        .run_optimize,
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
