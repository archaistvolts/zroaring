// generates a corpus from previously discovered crashing inputs
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var dir = try Io.Dir.cwd().openDir(io, "afl/input", .{});
    defer dir.close(io);

    var file_index: usize = 0;
    const ctx: fuzz.AflCtx = .{ .dir = dir, .io = io, .file_index = &file_index };
    const crash_corpus: []const []const fuzz.Op = @import("fuzz-crash-corpus.zon");
    for (crash_corpus) |ops| {
        try fuzz.writeOpFile(ctx, ops);
    }
}

const std = @import("std");
const Io = std.Io;
const fuzz = @import("fuzz.zig");
