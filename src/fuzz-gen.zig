// generates a corpus from previously discovered crashing inputs
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var dir = try Io.Dir.cwd().openDir(io, "afl/input", .{});
    defer dir.close(io);

    var file_index: usize = 0;
    const ctx: fuzz.AflCtx = .{ .dir = dir, .io = io, .file_index = &file_index };
    try fuzz.perform_crash_ops(ctx, fuzz.writeOpFile);
}

const std = @import("std");
const Io = std.Io;
const fuzz = @import("fuzz.zig");
