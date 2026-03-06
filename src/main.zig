pub const PositionalArgs = struct {
    file: []const u8,
    pattern: []const u8,

    pub const Mask = std.meta.Int(.unsigned, positionals_fields.len);
    const Mask_all_ones = (1 << (positionals_fields.len)) - 1;
    pub const Error = error{MissingArg};
    fn usage(exe: []const u8) void {
        std.debug.print("usage {s} FILE PATTERN\n", .{exe});
    }
    pub fn parse(argiter: *std.process.ArgIterator) Error!PositionalArgs {
        var seen: usize = 0;
        var ret: PositionalArgs = undefined;
        const exe = argiter.next().?;
        inline for (positionals_fields) |f| {
            @field(ret, f) = argiter.next() orelse {
                usage(exe);
                std.log.err("missing positional arg '{s}'\n", .{f});
                return error.MissingArg;
            };
            seen += 1;
        }
        // std.debug.print("seen {b} all ones {b}\n", .{ seen, Mask_all_ones });

        if (seen != positionals_fields.len) {
            std.log.err("missing positional arg. expected args to follow: \n", .{});
            for (positionals_fields[seen..]) |f| std.debug.print("  {s}\n", .{f});
            usage(exe);
            return error.MissingArg;
        }
        // std.debug.print("seen {b}\n", .{seen});
        // std.debug.print("parsed args: {s} {s}\n", .{ ret.file, ret.pattern });
        return ret;
    }
};

const positionals_fields = std.meta.fieldNames(PositionalArgs);

pub fn main() !void {
    var argiter = std.process.args();
    const args = try PositionalArgs.parse(&argiter);
    std.debug.print("file '{s}'\npattern '{s}'\n", .{ args.file, args.pattern });

    // TODO stdin?
    // var stdin_buf: [4096]u8 = undefined;
    // var stdin = std.fs.File.stdin().reader(&stdin_buf);
    // const text = try stdin.interface.takeDelimiter('\n');
    // const pattern = try stdin.interface.takeDelimiter('\n');

    // TODO compile and run regex

    // const r = RoaringRegex.init(args.pattern);
}

const std = @import("std");
const RoaringRegex = @import("RoaringRegex");
