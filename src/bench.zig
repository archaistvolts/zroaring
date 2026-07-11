pub fn zr_benchmark_op(
    op: fuzz.Op,
    rs: *[NUM_BITMAPS]Bitmap,
    allocator: std.mem.Allocator,
    ser_buf: []align(@alignOf(u64)) u8,
) !void {
    switch (op) {
        inline .add => |o, t| try @field(Bitmap, @tagName(t))(&rs[o.idx], allocator, o.val),
        inline .contains => |o, t| std.mem.doNotOptimizeAway(@field(Bitmap, @tagName(t))(rs[o.idx], o.val)),
        .remove => |o| _ = try rs[o.idx].remove_checked(allocator, o.val),
        .add_many => |o| _ = try rs[o.idx].add_many(allocator, o.vals),
        .add_range_closed => |o| try rs[o.idx].add_range_closed(allocator, o.vals[0], o.vals[1]),
        inline .@"and",
        .@"or",
        .xor,
        .andnot,
        => |o, t| {
            const res = try @field(Bitmap, @tagName(t))(rs[o.src1], allocator, rs[o.src2]);
            rs[o.idx].deinit(allocator);
            rs[o.idx] = res;
        },
        inline .lazy_or => |o, t| {
            var res = try @field(Bitmap, @tagName(t))(
                &rs[o.src1],
                allocator,
                rs[o.src2],
                root.constants.LAZY_OR_BITSET_CONVERSION_TO_FULL,
            );
            try res.repair_after_lazy(allocator);
            rs[o.idx].deinit(allocator);
            rs[o.idx] = res;
        },
        inline .is_subset,
        .and_cardinality,
        .or_cardinality,
        .xor_cardinality,
        .andnot_cardinality,
        .jaccard_index,
        .equals,
        => |o, t| std.mem.doNotOptimizeAway(@field(Bitmap, @tagName(t))(rs[o.idx], rs[o.src1])),
        inline .and_inplace,
        .or_inplace,
        => |o, t| try @field(Bitmap, @tagName(t))(&rs[o.idx], allocator, rs[o.src1]),
        inline .or_many => |o, t| {
            if (o.idxs.len == 0) return; // nothing to do

            var rsbuf: [NUM_BITMAPS + 1]Bitmap = undefined;
            for (o.idxs) |*idx| {
                rsbuf[idx - o.idxs.ptr] = rs[idx.*];
            }

            const result = try @field(Bitmap, @tagName(t))(allocator, rsbuf[0..o.idxs.len]);
            rs[o.idxs[0]].deinit(allocator);
            rs[o.idxs[0]] = result;
        },
        inline .rank,
        .select,
        => |o, t| std.mem.doNotOptimizeAway(@field(Bitmap, @tagName(t))(rs[o.idx], o.val)),
        .clear => |o| rs[o].clear(allocator),
        inline .run_optimize,
        .shrink_to_fit,
        => |o, t| _ = try @field(Bitmap, @tagName(t))(&rs[o], allocator),
        inline .maximum,
        .minimum,
        .statistics,
        => |o, t| std.mem.doNotOptimizeAway(@field(Bitmap, @tagName(t))(rs[o])),
        .frozen_serialize => |o| {
            try rs[o].frozen_serialize(ser_buf[0..rs[o].frozen_size_in_bytes()]);
            std.mem.doNotOptimizeAway(ser_buf[0]);
        },
        .frozen_view => |o| {
            const frozen_buf = ser_buf[0..rs[o].frozen_size_in_bytes()];
            try rs[o].frozen_serialize(frozen_buf);
            var zr = try Bitmap.frozen_view(allocator, @alignCast(frozen_buf));
            std.mem.doNotOptimizeAway(zr);
            zr.deinit(allocator);
        },
        .portable_serialize => |o| {
            var w = Io.Writer.fixed(ser_buf);
            var runflags: root.RunFlags = undefined;
            std.mem.doNotOptimizeAway(try rs[o].portable_serialize(&w, &runflags));
        },
        .portable_deserialize => |o| {
            var w = Io.Writer.fixed(ser_buf);
            var runflags: root.RunFlags = undefined;
            _ = try rs[o].portable_serialize(&w, &runflags);
            var x = try Bitmap.portable_deserialize(allocator, ser_buf);
            defer x.deinit(allocator);
            std.mem.doNotOptimizeAway(ser_buf[0]);
        },
        .flip => |o| {
            const result = try rs[o.idx].flip(allocator, o.vals[0], o.vals[1]);
            rs[o.idx].deinit(allocator);
            rs[o.idx] = result;
        },
        inline .range_cardinality, .contains_range => |o, t| std.mem.doNotOptimizeAway(
            @field(Bitmap, @tagName(t))(rs[o.idx], o.vals[0], o.vals[1]),
        ),
        // inline else => |_, t| @panic("TODO: " ++ @tagName(t)),
    }
}

pub fn cr_benchmark_op(
    op: fuzz.Op,
    rs: *[NUM_BITMAPS][*c]c.roaring_bitmap_t,
    ser_buf: []align(2) u8,
) !void {
    switch (op) {
        inline .add,
        .contains,
        => |o, t| std.mem.doNotOptimizeAway(@field(c, "roaring_bitmap_" ++ @tagName(t))(rs[o.idx], o.val)),
        .remove => |o| std.mem.doNotOptimizeAway(c.roaring_bitmap_remove_checked(rs[o.idx], o.val)),
        .equals => |o| std.mem.doNotOptimizeAway(c.roaring_bitmap_equals(rs[o.idx], rs[o.src1])),
        .add_many => |o| c.roaring_bitmap_add_many(rs[o.idx], o.vals.len, o.vals.ptr),
        .add_range_closed => |o| c.roaring_bitmap_add_range_closed(rs[o.idx], o.vals[0], o.vals[1]),
        .@"and",
        => |o| {
            const res = c.roaring_bitmap_and(rs[o.src1], rs[o.src2]);
            c.roaring_bitmap_free(rs[o.idx]);
            rs[o.idx] = res;
        },
        .@"or",
        => |o| {
            const res = c.roaring_bitmap_or(rs[o.src1], rs[o.src2]);
            c.roaring_bitmap_free(rs[o.idx]);
            rs[o.idx] = res;
        },
        inline .xor,
        .andnot,
        => |o, t| {
            const res = @field(c, "roaring_bitmap_" ++ @tagName(t))(rs[o.src1], rs[o.src2]);
            c.roaring_bitmap_free(rs[o.idx]);
            rs[o.idx] = res;
        },
        inline .lazy_or => |o, t| {
            const res = @field(c, "roaring_bitmap_" ++ @tagName(t))(
                rs[o.src1],
                rs[o.src2],
                root.constants.LAZY_OR_BITSET_CONVERSION_TO_FULL,
            );
            c.roaring_bitmap_repair_after_lazy(res);
            c.roaring_bitmap_free(rs[o.idx]);
            rs[o.idx] = res;
        },
        inline .is_subset,
        .and_cardinality,
        .or_cardinality,
        .xor_cardinality,
        .andnot_cardinality,
        .jaccard_index,
        => |o, t| std.mem.doNotOptimizeAway(@field(c, "roaring_bitmap_" ++ @tagName(t))(rs[o.idx], rs[o.src1])),
        inline .or_inplace,
        .and_inplace,
        => |o, t| @field(c, "roaring_bitmap_" ++ @tagName(t))(rs[o.idx], rs[o.src1]),
        inline .or_many => |o, t| {
            if (o.idxs.len == 0) return; // nothing to do

            var rsbuf: [NUM_BITMAPS + 1][*c]c.roaring_bitmap_t = undefined;
            for (o.idxs) |*idx| {
                rsbuf[idx - o.idxs.ptr] = rs[idx.*];
            }

            const result = @field(c, "roaring_bitmap_" ++ @tagName(t))(o.idxs.len, @ptrCast(&rsbuf));
            c.roaring_bitmap_free(rs[o.idxs[0]]);
            rs[o.idxs[0]] = result;
        },
        .rank => |o| std.mem.doNotOptimizeAway(c.roaring_bitmap_rank(rs[o.idx], o.val)),
        .select => |o| {
            var ele: u32 = undefined;
            std.mem.doNotOptimizeAway(c.roaring_bitmap_select(rs[o.idx], o.val, &ele));
        },
        inline .clear,
        .run_optimize,
        .shrink_to_fit,
        => |o, t| std.mem.doNotOptimizeAway(@field(c, "roaring_bitmap_" ++ @tagName(t))(rs[o])),
        .frozen_serialize => |o| if (rs[o].*.high_low_container.allocation_size != 0) {
            c.roaring_bitmap_frozen_serialize(rs[o], ser_buf.ptr);
        },
        .frozen_view => |o| if (rs[o].*.high_low_container.allocation_size != 0) {
            c.roaring_bitmap_frozen_serialize(rs[o], ser_buf.ptr);
            const cr = c.roaring_bitmap_frozen_view(ser_buf.ptr, c.roaring_bitmap_frozen_size_in_bytes(rs[o]));
            c.roaring_bitmap_free(cr);
        },
        .portable_serialize => |o| std.mem.doNotOptimizeAway(
            c.roaring_bitmap_portable_serialize(rs[o], ser_buf.ptr),
        ),
        .portable_deserialize => |o| {
            const size = c.roaring_bitmap_portable_serialize(rs[o], ser_buf.ptr);
            const tmp = c.roaring_bitmap_portable_deserialize_safe(ser_buf.ptr, size);
            c.roaring_bitmap_free(tmp);
        },
        inline .range_cardinality, .contains_range => |o, t| std.mem.doNotOptimizeAway(
            @field(c, "roaring_bitmap_" ++ @tagName(t))(rs[o.idx], o.vals[0], o.vals[1]),
        ),
        inline .minimum, .maximum, .statistics => |o, t| {
            if (t == .statistics) {
                var stat: c.roaring_statistics_t = undefined;
                c.roaring_bitmap_statistics(rs[o], &stat);
                std.mem.doNotOptimizeAway(stat);
            } else {
                std.mem.doNotOptimizeAway(@field(c, "roaring_bitmap_" ++ @tagName(t))(rs[o]));
            }
        },
        .flip => |o| {
            const result = c.roaring_bitmap_flip(rs[o.idx], o.vals[0], o.vals[1]);
            c.roaring_bitmap_free(rs[o.idx]);
            rs[o.idx] = result;
        },
        // inline else => |_, t| @panic("TODO: " ++ @tagName(t)),
    }
}

fn runBenchmarkGeneric(
    io: Io,
    bitmaps: anytype,
    allocator: std.mem.Allocator,
    ser_buf: []align(root.constants.BLOCK_ALIGN) u8,
    op_stats: *OpStats,
    ops_len: *usize,
    total_ns: *i96,
    extra_ops: []const fuzz.Op,
    random: std.Random,
) !void {
    const is_cr = @TypeOf(bitmaps) == *[NUM_BITMAPS][*c]c.roaring_bitmap_t;

    const totalts = Io.Timestamp.now(io, .real);
    for (crash_corpus) |ops| {
        for (ops) |op| {
            const ts = Io.Timestamp.now(io, .real);
            if (is_cr)
                try cr_benchmark_op(op, bitmaps, ser_buf)
            else
                try zr_benchmark_op(op, bitmaps, allocator, ser_buf);
            op_stats.getPtr(op)[1].nanoseconds += ts.untilNow(io, .real).toNanoseconds();
            op_stats.getPtr(op)[0] += 1;
        }
        ops_len.* += ops.len;
    }
    var cur = extra_ops.ptr;
    const end = extra_ops.ptr + extra_ops.len;
    while (@intFromPtr(cur) < @intFromPtr(end)) {
        const group_count = @min(
            end - cur,
            random.intRangeLessThan(u16, 5, 20),
        );
        for (cur[0..group_count]) |op| {
            const ts = Io.Timestamp.now(io, .real);
            if (is_cr)
                try cr_benchmark_op(op, bitmaps, ser_buf)
            else
                try zr_benchmark_op(op, bitmaps, allocator, ser_buf);
            const elapsed_ns = ts.untilNow(io, .real).toNanoseconds();
            op_stats.getPtr(op)[0] += 1;
            op_stats.getPtr(op)[1].nanoseconds += elapsed_ns;
        }
        cur += group_count;
        ops_len.* += group_count;
    }
    total_ns.* += totalts.untilNow(io, .real).nanoseconds;
}

/// count and time for each op
const OpStats = std.EnumArray(fuzz.Op.Tag, struct { u64, Io.Duration });

const sep = @as([52]u8, @splat('-')) ++ "\n";
const fast = "⚡";
const ok = "👍🏻";
const slow = "🥔";
const poop = "💩";

fn runBenchmark(allocator: std.mem.Allocator, io: Io, parsed_args: std.EnumSet(Arg)) !void {
    var zrs: [NUM_BITMAPS]Bitmap = @splat(.empty);
    defer for (&zrs) |*x| x.deinit(allocator);
    var crs: [NUM_BITMAPS][*c]c.roaring_bitmap_t = undefined;
    for (&crs) |*o| o.* = c.roaring_bitmap_create().?;
    defer for (crs) |x| c.roaring_bitmap_free(x);
    var ser_buf: [1024 * 1024]u8 align(root.constants.BLOCK_ALIGN) = undefined;

    // generate a list of extra ops which are missing from fuzz-crash-corpus.zon
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    const extra_ops = try allocator.alloc(fuzz.Op, 1000);
    defer allocator.free(extra_ops);
    var arenas = std.heap.ArenaAllocator.init(allocator);
    defer arenas.deinit();
    const arena = arenas.allocator();

    for (extra_ops) |*op| {
        const tag = random.enumValue(fuzz.Op.Tag);
        const idx = random.intRangeLessThan(u8, 0, NUM_BITMAPS);
        const vals_len = 8;
        op.* = fuzz_op: switch (tag) {
            .add => .{ .add = .{ .idx = idx, .val = random.intRangeLessThan(u32, 0, fuzz.MAX_VAL) } },
            .add_many => {
                const len = random.intRangeLessThan(u8, 1, vals_len);
                const vals = try arena.alloc(u32, len);
                for (0..len) |i| vals[i] = random.intRangeLessThan(u32, 0, fuzz.MAX_VAL);
                break :fuzz_op .{ .add_many = .{ .idx = idx, .vals = vals[0..len] } };
            },
            inline .add_range_closed,
            .contains_range,
            .range_cardinality,
            .flip,
            => |t| {
                const start = random.intRangeLessThan(u32, 0, fuzz.MAX_VAL);
                const len = random.intRangeLessThan(u32, 1, fuzz.MAX_RANGE_LEN);
                break :fuzz_op @unionInit(
                    fuzz.Op,
                    @tagName(t),
                    .{ .idx = idx, .vals = .{
                        random.intRangeLessThan(u32, start, start + len),
                        random.intRangeLessThan(u32, start + len, start + len * 2),
                    } },
                );
            },
            .remove => break :fuzz_op .{ .remove = .{
                .idx = idx,
                .pick_existing = random.int(u8),
                .val = random.intRangeLessThan(u32, 0, fuzz.MAX_VAL),
            } },
            inline .@"and",
            .@"or",
            .xor,
            .andnot,
            .lazy_or,
            => |t| break :fuzz_op @unionInit(fuzz.Op, @tagName(t), .{
                .idx = random.intRangeLessThan(u8, 0, NUM_BITMAPS),
                .src1 = random.intRangeLessThan(u8, 0, NUM_BITMAPS),
                .src2 = random.intRangeLessThan(u8, 0, NUM_BITMAPS),
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
            => |t| break :fuzz_op @unionInit(fuzz.Op, @tagName(t), .{
                .idx = random.intRangeLessThan(u8, 0, NUM_BITMAPS),
                .src1 = random.intRangeLessThan(u8, 0, NUM_BITMAPS),
            }),
            inline .or_many => |t| {
                const idxs = try arena.create([NUM_BITMAPS + 1]u8);
                const len = random.intRangeLessThan(u8, 0, NUM_BITMAPS + 1);
                for (idxs[0..len]) |*x| x.* = random.intRangeLessThan(u8, 0, NUM_BITMAPS);
                break :fuzz_op @unionInit(fuzz.Op, @tagName(t), .{ .idxs = idxs[0..len] });
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
            => |t| @unionInit(fuzz.Op, @tagName(t), idx),
            inline .rank,
            .select,
            .contains,
            => |t| @unionInit(fuzz.Op, @tagName(t), .{
                .idx = idx,
                .val = random.intRangeLessThan(u32, 0, fuzz.MAX_VAL),
            }),
        };
    }

    // warmup once each
    var cr_ops_len: usize = 0;
    var cr_op_stats = OpStats.initFill(.{ 0, .fromNanoseconds(0) });
    var cr_total_ns: i96 = 0;
    var zr_ops_len: usize = 0;
    var zr_op_stats = OpStats.initFill(.{ 0, .fromNanoseconds(0) });
    var zr_total_ns: i96 = 0;
    try runBenchmarkGeneric(io, &crs, allocator, &ser_buf, &cr_op_stats, &cr_ops_len, &cr_total_ns, extra_ops, random);
    try runBenchmarkGeneric(io, &zrs, allocator, &ser_buf, &zr_op_stats, &zr_ops_len, &zr_total_ns, extra_ops, random);
    // run, collect results
    cr_ops_len = 0;
    cr_op_stats = OpStats.initFill(.{ 0, .fromNanoseconds(0) });
    cr_total_ns = 0;
    zr_ops_len = 0;
    zr_op_stats = OpStats.initFill(.{ 0, .fromNanoseconds(0) });
    zr_total_ns = 0;
    for (0..10) |_| {
        for (&crs) |*x| {
            c.roaring_bitmap_free(x.*);
            x.* = c.roaring_bitmap_create();
        }
        try runBenchmarkGeneric(io, &crs, allocator, &ser_buf, &cr_op_stats, &cr_ops_len, &cr_total_ns, extra_ops, random);
        for (&zrs) |*x| x.deinit(allocator);
        try runBenchmarkGeneric(io, &zrs, allocator, &ser_buf, &zr_op_stats, &zr_ops_len, &zr_total_ns, extra_ops, random);
    }

    const write_csv_row = parsed_args.contains(.write_csv_row);
    // debug.print and write csv file when write_csv_row
    const csvf = if (write_csv_row)
        try Io.Dir.cwd().createFile(io, "testdata/bench-data.csv", .{ .truncate = false })
    else
        undefined;
    var buf: [256]u8 = undefined;
    var csvfw = csvf.writer(io, &buf);
    const fw = &csvfw.interface;
    if (write_csv_row) {
        const stat = try csvf.stat(io);
        try csvfw.seekTo(stat.size);
        if (stat.size == 0) { // write header if empty file
            try fw.writeAll("timestamp,commit,cr_ops,cr_ns,zr_ops,zr_ns,ratio,");
            for (std.meta.tags(fuzz.Op.Tag), 0..) |op, i| {
                if (i != 0) try fw.writeAll(",");
                try fw.print("{t}_ratio", .{op});
            }
        }
        const ts = unixTimestampToUTC(Io.Timestamp.now(io, .real).toMilliseconds());
        try fw.print( // write timestamp
            "\n{}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>3},",
            .{ ts.year, ts.month, ts.day, ts.hour, ts.minute, ts.second, ts.millisecond },
        );
        // write commit
        const res = try std.process.run(allocator, io, .{ .argv = &.{ "git", "rev-parse", "--short", "HEAD" } });
        defer allocator.free(res.stdout);
        try fw.writeAll(std.mem.trim(u8, res.stdout, "\n"));
        try fw.writeByte(',');
    }

    var cr_fmt_buf: [16]u8 = undefined;
    var zr_fmt_buf: [16]u8 = undefined;
    const cr_speed: usize = cr_ops_len * std.time.ns_per_s / @as(usize, @intCast(@as(u64, @intCast(cr_total_ns))));
    const zr_speed: usize = zr_ops_len * std.time.ns_per_s / @as(usize, @intCast(@as(u64, @intCast(zr_total_ns))));
    const zr_cr_ratio =
        @as(f32, @floatFromInt((zr_speed * 100_000) / cr_speed)) / 100_000;
    const cr_dur_fmt = try std.fmt.bufPrint(&cr_fmt_buf, "{f:.1}", .{Io.Duration{ .nanoseconds = cr_total_ns }});
    const zr_dur_fmt = try std.fmt.bufPrint(&zr_fmt_buf, "{f:.1}", .{Io.Duration{ .nanoseconds = zr_total_ns }});
    std.debug.print(sep ++
        \\overall:
        \\
    ++ sep ++
        \\CRoaring: {} ops {s: <10} {B:.3} ops/sec
        \\ZRoaring: {} ops {s: <10} {B:.3} ops/sec
        \\
        \\                                 ratio -- {d:.3} {s}
        \\
        \\
    , .{
        cr_ops_len,
        cr_dur_fmt,
        cr_speed,
        zr_ops_len,
        zr_dur_fmt,
        zr_speed,
        zr_cr_ratio,
        if (zr_cr_ratio > 1.07)
            fast
        else if (zr_cr_ratio > 0.93)
            ok
        else if (zr_cr_ratio > 0.75)
            slow
        else
            poop,
    });

    if (write_csv_row)
        try fw.print("{},{},{},{},{d:.2},", .{ // cr_ops,cr_ns,zr_ops,zr_ns,ratio,
            cr_ops_len,
            Io.Duration.fromNanoseconds(cr_total_ns).toMicroseconds(),
            zr_ops_len,
            Io.Duration.fromNanoseconds(zr_total_ns).toMicroseconds(),
            zr_cr_ratio,
        });

    std.debug.print(sep ++ "individual ops: speed=ops/sec\n" ++ sep, .{});
    std.debug.print("op                   cr speed zr speed #    ratio\n" ++ sep, .{});
    for (std.meta.tags(fuzz.Op.Tag), 0..) |op, i| {
        const cr_speed_op: u64 = cr_op_stats.get(op).@"0" * std.time.ns_per_s /
            @as(usize, @intCast(cr_op_stats.get(op).@"1".toNanoseconds()));
        const zr_speed_op: u64 = zr_op_stats.get(op).@"0" * std.time.ns_per_s /
            @as(usize, @intCast(zr_op_stats.get(op).@"1".toNanoseconds()));
        const zr_cr_ratio_op =
            @as(f32, @floatFromInt((zr_speed_op * 100_000) / cr_speed_op)) / 100_000;
        std.debug.print("{t: <20} {B: <8.2} {B: <8.2} {: <4} {d: <5.2} {s}\n", .{
            op,
            cr_speed_op,
            zr_speed_op,
            (cr_op_stats.get(op).@"0" + zr_op_stats.get(op).@"0") / 2,
            zr_cr_ratio_op,
            if (zr_cr_ratio_op > 1.07)
                fast
            else if (zr_cr_ratio_op > 0.93)
                ok
            else if (zr_cr_ratio_op > 0.75)
                slow
            else
                poop,
        });
        if (write_csv_row) {
            if (i != 0) try fw.writeByte(',');
            try fw.print("{d:.3}", .{zr_cr_ratio_op});
        }
    }

    if (write_csv_row) try fw.flush();
}

const DateTime = struct {
    year: u32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
};

fn isLeapYear(year: u32) bool {
    return (@rem(year, 4) == 0 and @rem(year, 100) != 0) or (@rem(year, 400) == 0);
}

fn daysInMonth(month: u8, year: u32) u8 {
    return switch (month) {
        1 => 31,
        2 => if (isLeapYear(year)) 29 else 28,
        3 => 31,
        4 => 30,
        5 => 31,
        6 => 30,
        7 => 31,
        8 => 31,
        9 => 30,
        10 => 31,
        11 => 30,
        12 => 31,
        else => unreachable,
    };
}

fn unixTimestampToUTC(timestamp: i64) DateTime {
    const MILLIS_PER_SEC = 1000;
    const SECS_PER_MIN = 60;
    const SECS_PER_HOUR = SECS_PER_MIN * 60;
    const SECS_PER_DAY = SECS_PER_HOUR * 24;

    const millisecond: u16 = @intCast(@rem(timestamp, MILLIS_PER_SEC));
    const seconds = @divTrunc(timestamp, MILLIS_PER_SEC);

    // Compute the time of day.
    const hour: u8 = @intCast(@divTrunc(@rem(seconds, SECS_PER_DAY), SECS_PER_HOUR));
    const minute: u8 = @intCast(@divTrunc(@rem(seconds, SECS_PER_HOUR), SECS_PER_MIN));
    const second: u8 = @intCast(@rem(seconds, SECS_PER_MIN));

    // Compute the date.
    var days = @divTrunc(seconds, SECS_PER_DAY);
    var year: u32 = 1970;

    while (true) {
        const days_in_year: u16 = if (isLeapYear(year)) 366 else 365;
        if (days >= days_in_year) {
            days -= days_in_year;
            year += 1;
        } else break;
    }

    var month: u8 = 1;
    while (true) {
        const day_of_month = daysInMonth(month, year);
        if (days >= day_of_month) {
            days -= day_of_month;
            month += 1;
        } else break;
    }

    const day: u8 = @intCast(days + 1);

    return DateTime{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .millisecond = millisecond,
    };
}

const Arg = enum { write_csv_row };

pub fn main(init: std.process.Init) !void {
    const gpa = if (builtin.cpu.arch.isWasm() and !builtin.link_libc)
        std.heap.wasm_allocator
    else
        std.heap.c_allocator;
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    var parsed_args: std.EnumSet(Arg) = .initEmpty();
    while (args.next()) |arg| {
        parsed_args.insert(std.meta.stringToEnum(Arg, arg) orelse
            return error.Arg);
    }

    try runBenchmark(gpa, init.io, parsed_args);
}

const std = @import("std");
const Io = std.Io;
const fuzz = @import("fuzz.zig");
const crash_corpus: []const []const fuzz.Op = @import("fuzz-crash-corpus.zon");
const NUM_BITMAPS = fuzz.NUM_BITMAPS;
const root = @import("root.zig");
const Bitmap = root.Bitmap;
const c = @import("croaring");
const builtin = @import("builtin");
