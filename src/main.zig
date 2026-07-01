/// cli commands
const Command = union(enum) {
    @"api-coverage": struct {
        @"--filter": []const u8 = "API-COVERAGE-FILTER-NONE",
    },
    const Tag = meta.Tag(Command);

    pub fn format(c: Command, w: *std.Io.Writer) !void {
        try w.writeAll(@tagName(c));
        switch (c) {
            .@"api-coverage" => |x| {
                try w.print(" --filter {s}", .{x.@"--filter"});
            },
        }
    }
};

fn bail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.debug.print("Commands: \n", .{});
    inline for (comptime meta.fieldNames(Command), 0..) |n, i| {
        if (i != 0) std.debug.print(", ", .{});
        std.debug.print("{s}: {{\n", .{n});

        const F = @FieldType(Command, n);
        switch (@typeInfo(F)) {
            .@"struct" => {
                inline for (comptime meta.fieldNames(F)) |cn| {
                    if (i != 0) std.debug.print(", ", .{});
                    std.debug.print("  {s}: {s}\n", .{ cn, @typeName(@FieldType(F, cn)) });
                }
            },
            .void => {},
            else => @panic("TODO: " ++ @typeName(F)),
        }
        std.debug.print("}}\n", .{});
    }
    std.debug.print("\n", .{});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const arg1 = args.next() orelse bail("Missing command argument.\n", .{});
    var command = if (meta.stringToEnum(Command.Tag, arg1)) |x| switch (x) {
        inline else => |t| @unionInit(Command, @tagName(t), .{}),
    } else {
        bail("Unexpected command argument '{s}'\n", .{arg1});
    };

    // parse args
    while (args.next()) |arg| {
        switch (command) {
            inline else => |_, tag| {
                const Cf = @FieldType(Command, @tagName(tag));
                switch (@typeInfo(Cf)) {
                    .@"struct" => if (meta.stringToEnum(meta.FieldEnum(Cf), arg)) |cmdfield| {
                        switch (cmdfield) {
                            inline else => |cmdfieldtag| {
                                const T = @FieldType(Cf, @tagName(cmdfieldtag));
                                switch (T) {
                                    []const u8 => @field(
                                        @field(command, @tagName(tag)),
                                        @tagName(cmdfieldtag),
                                    ) = args.next() orelse
                                        bail("Missing command argument: '{s}: {s}'\n", .{ @tagName(cmdfieldtag), @typeName(T) }),
                                    else => @panic("TODO: " ++ @typeName(T)),
                                }
                            },
                        }
                    },
                    .void => {},
                    else => @panic("TODO: " ++ @typeName(Cf)),
                }
            },
        }
    }

    std.debug.print("\nparsed command:\n  {f}\n", .{command});

    const arena = init.arena.allocator();
    switch (command) {
        .@"api-coverage" => {
            const cr_syms = try collect_api(croaring, arena);
            const bitmap_syms = try collect_api(zroaring.Bitmap, arena);
            const ctr_syms = try collect_api(zroaring.Container, arena);
            const it_syms = try collect_api(zroaring.Iterator, arena);

            // table from cr_sym to (zr_sym, zr_namespace)
            var result = std.StringArrayHashMapUnmanaged([2]?[]const u8).empty;
            // table of found, total for each crprefix
            var syms_stats_by_prefix: [crprefixes.len][2]f32 = @splat(@splat(0));

            // for each cr_sym search for matching zr_sym and update stats
            for (cr_syms.keys(), cr_syms.values()) |cr_sym, cr_sym_prefixlen| {
                const cr_sym_suffix = cr_sym[cr_sym_prefixlen..];
                const cr_sym_prefix = cr_sym[0..cr_sym_prefixlen];
                const i = for (crprefixes, 0..) |crprefix, i| {
                    if (mem.eql(u8, cr_sym_prefix, crprefix)) {
                        break i;
                    }
                } else unreachable;
                const gop = try result.getOrPut(arena, cr_sym);
                std.debug.assert(!gop.found_existing);
                gop.value_ptr.* = .{ null, null };
                syms_stats_by_prefix[i][1] += 1; // total

                var found = false;
                for (bitmap_syms.keys()) |bsym| {
                    if (mem.eql(u8, cr_sym, bsym) or mem.eql(u8, cr_sym_suffix, bsym)) {
                        gop.value_ptr.* = .{ bsym, "Bitmap" };
                        found = true;
                        syms_stats_by_prefix[i][0] += 1; // found
                        break;
                    }
                }
                if (!found) {
                    for (ctr_syms.keys()) |ctrsym| {
                        if (mem.eql(u8, cr_sym, ctrsym) or mem.eql(u8, cr_sym_suffix, ctrsym)) {
                            gop.value_ptr.* = .{ ctrsym, "Container" };
                            syms_stats_by_prefix[i][0] += 1; // found
                            break;
                        }
                    }
                }
                if (!found) {
                    for (it_syms.keys()) |itsym| {
                        if (mem.eql(u8, cr_sym, itsym) or mem.eql(u8, cr_sym_suffix, itsym)) {
                            gop.value_ptr.* = .{ itsym, "Iterator" };
                            syms_stats_by_prefix[i][0] += 1; // found
                            break;
                        }
                    }
                }
            }

            const filter = command.@"api-coverage".@"--filter";
            var filtered_cr_syms_found: f32 = 0;
            var filtered_cr_syms_total: f32 = 0;
            for (cr_syms.keys()) |crsym| {
                if (mem.containsAtLeast(u8, crsym, 1, filter)) {
                    const s = result.get(crsym).?;
                    filtered_cr_syms_total += 1;
                    if (s[0] != null) {
                        filtered_cr_syms_found += 1;
                        std.debug.print("{s: <50} {?s}.{?s}\n", .{ crsym, s[1], s[0] });
                    } else std.debug.print("{s: <50} --\n", .{crsym});
                }
            }

            std.debug.print("\nsymbols coverage:\n  {s: <25} {s}\n", .{ "prefix", "found total %" });
            const sep = "---------------------------------------------\n";
            std.debug.print(sep, .{});
            for (crprefixes, syms_stats_by_prefix) |crp, stat| {
                const found, const total = stat;
                std.debug.print(
                    "  {s: <25} {: <5} {: <5} {:2.1}%\n",
                    .{ crp, found, total, found / total * 100 },
                );
            }
            {
                var totals: [2]f32 = @splat(0);
                for (syms_stats_by_prefix) |stat| {
                    totals[0] += stat[0];
                    totals[1] += stat[1];
                }
                const found, const total = totals;
                std.debug.print(sep, .{});
                std.debug.print(
                    "  {s: <25} {: <5} {: <5} {:2.1}%\n",
                    .{ "total", found, total, found / total * 100 },
                );
            }
            {
                const total = filtered_cr_syms_total;
                const found = filtered_cr_syms_found;
                std.debug.print(sep, .{});
                std.debug.print(
                    "  {s: <25} {: <5} {: <5} {:2.1}%\n",
                    .{ "filtered", found, total, found / total * 100 },
                );
            }
        },
    }
}

const crprefixes = [_][]const u8{
    "roaring_bitmap_",
    "ra_",
    "container_",
    "run_container_",
    "bitset_container_",
    "array_container_",
    "roaring_uint32_iterator_",
};

/// map of found names to prefix len after which match is found
const StringMap = std.StringArrayHashMapUnmanaged(usize);

fn collect_api(T: type, arena: mem.Allocator) !StringMap {
    var r = StringMap.empty;
    try r.ensureTotalCapacity(arena, 10_000);
    @setEvalBranchQuota(30_000);
    const is_croaring = T == croaring;
    for (meta.declarations(T)) |decl| {
        const declname = decl.name;
        if (!is_croaring or
            for (crprefixes) |crprefix| {
                if (mem.startsWith(u8, declname, crprefix)) break true;
            } else false)
        {
            const l: usize = if (!is_croaring)
                0
            else for (crprefixes) |p| {
                if (mem.startsWith(u8, declname, p)) break p.len;
            } else unreachable;

            if (!mem.endsWith(u8, declname, "_s") and
                !mem.endsWith(u8, declname, "_t"))
                r.putAssumeCapacity(declname, l);
        }
    }
    const C = struct {
        keys: [][]const u8,
        pub fn lessThan(c: @This(), a: usize, b: usize) bool {
            return mem.order(u8, c.keys[a], c.keys[b]) == .lt;
        }
    };
    r.sortUnstable(C{ .keys = r.keys() });
    return r;
}

const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const Type = std.builtin.Type;
const zroaring = @import("zroaring");
const croaring = @import("croaring");
