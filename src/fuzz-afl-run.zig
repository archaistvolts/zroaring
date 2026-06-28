pub fn main(init: std.process.Init) !void {
    var iter = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = iter.next();
    const filepath = iter.next() orelse return error.MissingFilepathArg;
    const contents = try std.Io.Dir.cwd().readFileAlloc(init.io, filepath, init.arena.allocator(), .unlimited);
    fuzz.zig_fuzz_test(contents.ptr, contents.len);
}

const fuzz = @import("fuzz.zig");
const std = @import("std");
