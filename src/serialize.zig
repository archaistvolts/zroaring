//!
//! # References
//!  * https://github.com/RoaringBitmap/RoaringFormatSpec/
//!  * https://github.com/RoaringBitmap/RoaringFormatSpec/blob/master/roaringbitmap64.ksy
//!

// TODO support 64 bit values

/// The actual container data. The type is determined by:
/// - If run containers are allowed and the run_bitset indicates this container
///   is a run container, use run_container (type 1)
/// - Otherwise, if the container's cardinality is <= 4096, use array_container
///   (type 2) - Otherwise, use bitset_container (type 3)
const Container = extern union {
    array: [*]u16,
    bitset: [*]align(32) u64,
    /// A run container is serialized as a 16-bit integer indicating the number
    /// of runs, followed by a pair of 16-bit values for each run. Runs are
    /// non-overlapping and sorted. Thus a run container with x runs will use 2 +
    /// 4 x bytes. Each pair of 16-bit values contains the starting index of the
    /// run followed by the length of the run minus 1. That is, we interleave
    /// values and lengths, so that if you have the values 11,12,13,14,15, you
    /// store that as 11,4 where 4 means that beyond 11 itself, there are 4
    /// contiguous values that follow. Other example: e.g., 1,10, 20,0, 31,2
    /// would be a concise representation of 1, 2, ..., 11, 20, 31, 32, 33
    run: [*]u16,
    const Tag = enum(u8) {
        bitset = 1,
        array = 2,
        run = 3,
        shared = 4,
    };

    pub fn contains(c: Container, tag: Tag, card: u32, value: u32) bool {
        return switch (tag) {
            .array => {
                const idx = root.Array.binarySearch(c.array[0..card], @truncate(value >> 16));
                return idx >= 0;
            },
            .bitset => {
                const bs = root.BitsetContainer{ .words = c.bitset, .cardinality = card, .capacity = card };
                return bs.contains(@truncate(value));
            },

            .run => unreachable,
            .shared => unreachable,
        };
    }
};

pub const Magic = enum(u16) {
    SERIAL_COOKIE_NO_RUNCONTAINER = 12346,
    SERIAL_COOKIE = 12347,
    _,
};

/// # Cookie header
/// The cookie header spans either 64 bits or 32 bits followed by a variable number of bytes.
/// Magic cookie value that identifies the type of Roaring Bitmap format.
/// 12346 (SERIAL_COOKIE_NO_RUNCONTAINER) means no run containers are used.
/// 12347 (SERIAL_COOKIE) means run containers may be present.
pub const Cookie = extern struct { magic: Magic, cardinality_minus1: u16 };

const NO_OFFSET_THRESHOLD = 4;

/// # Container Metadata
/// Header structure that follows the magic cookie value.
/// The structure differs depending on whether run containers are used or not.
pub const MetaItem = extern struct { key: u16, cardinality_minus1: u16 };

pub const BitmapStorage = struct {
    cookie: Cookie,
    /// container count.  shared count for `containers`, `offsets`, `metas` and `runs_bitset`
    count: u32,
    /// presence of runs for each container
    runs_bitset: ?[*]u8,
    /// # Offset header
    /// Offset header containing the byte offsets of each container from the beginning
    /// of the stream. This is included if either:
    ///  * No run containers are present, or
    ///  * There are at least NO_OFFSET_THRESHOLD (4) containers
    /// the location in bytes of the container from the beginning of the stream
    /// (starting with the cookie) for each container.
    offsets: ?[*]u32,
    metas: [*]MetaItem,
    containers: [*]Container,

    pub const Builder = struct {
        arena: std.heap.ArenaAllocator,

        pub fn init(allocator: mem.Allocator) Builder {
            return .{ .arena = .init(allocator) };
        }

        pub fn deserialize(b: *Builder, reader: *Io.Reader) !BitmapStorage {
            return try deserializeImpl(reader, b.arena.allocator());
        }
    };

    pub fn contains(rb: BitmapStorage, value: u32) bool {
        return for (0..rb.count) |container_i| {
            const card = @as(u32, rb.metas[container_i].cardinality_minus1) + 1;
            const tag = containerTag(container_i, rb.cookie.magic, card, rb.runs_bitset, (rb.count + 7) / 8);
            const container = rb.containers[container_i];
            if (container.contains(tag, card, value)) break true;
        } else false;
    }
};

fn isRunContainer(
    container_i: usize,
    runs_bitset: ?[*]u8,
    runs_bitset_count: u32,
) bool {
    return if (runs_bitset) |rb|
        (rb[0..runs_bitset_count][container_i / 8] &
            (@as(u8, 1) << @truncate(container_i % 8))) != 0
    else
        false;
}

fn containerTag(
    container_i: usize,
    magic: Magic,
    container_len: u32,
    runs_bitset: ?[*]u8,
    runs_bitset_count: u32,
) Container.Tag {
    return if (magic == .SERIAL_COOKIE and
        isRunContainer(container_i, runs_bitset, runs_bitset_count))
        .run
    else if (container_len > 4096)
        .bitset
    else
        .array;
}

pub fn deserializeImpl(reader: *Io.Reader, arena: mem.Allocator) !BitmapStorage {
    var rb: BitmapStorage = undefined;
    rb.cookie = try reader.takeStruct(Cookie, .little);
    switch (rb.cookie.magic) {
        .SERIAL_COOKIE, .SERIAL_COOKIE_NO_RUNCONTAINER => {},
        _ => return error.UnexpectedMagic,
    }
    rb.count = if (rb.cookie.magic == .SERIAL_COOKIE_NO_RUNCONTAINER)
        try reader.takeInt(u32, .little)
    else
        @as(u32, rb.cookie.cardinality_minus1) + 1;

    rb.runs_bitset = null;
    const runs_bitset_count = (rb.count + 7) / 8;
    if (rb.cookie.magic == .SERIAL_COOKIE) {
        // Let size be the number of containers. Then we store (size + 7) / 8
        // bytes, following the initial 32 bits, as a bitset to indicate whether
        // each of the containers is a run container
        rb.runs_bitset = (try arena.alloc(u8, runs_bitset_count)).ptr;
        try reader.readSliceAll(rb.runs_bitset.?[0..runs_bitset_count]);
        // std.debug.print("rb.runs_bitset {any}\n", .{rb.runs_bitset.?[0..runs_bitset_count]});
    }

    rb.metas = (try arena.alloc(MetaItem, rb.count)).ptr;
    for (rb.metas[0..rb.count]) |*dh| {
        dh.* = try reader.takeStruct(MetaItem, .little);
    }

    rb.offsets =
        if (rb.cookie.magic == .SERIAL_COOKIE_NO_RUNCONTAINER or
        (rb.cookie.magic == .SERIAL_COOKIE and rb.count >= NO_OFFSET_THRESHOLD)) offsets: {
            const offsets = try arena.alloc(u32, rb.count);
            for (offsets) |*o| o.* = try reader.takeInt(u32, .little);
            break :offsets offsets.ptr;
        } else null;

    rb.containers = (try arena.alloc(Container, rb.count)).ptr;

    for (0..rb.count, rb.metas) |i, meta| {
        const container_card = @as(u32, meta.cardinality_minus1) + 1;
        // std.debug.print("conatiner i: {} meta: {} container_card: {}\n", .{ i, meta, container_card });
        // const offset = if (rb.offsets) |offsets| offsets[i] else null;
        // std.debug.print("oh: {?} reader.seek {}\n", .{ offset, reader.seek });
        switch (containerTag(i, rb.cookie.magic, container_card, rb.runs_bitset, runs_bitset_count)) {
            .array => {
                const storage = try arena.alloc(u16, container_card);
                try reader.readSliceEndian(u16, storage, .little);
                rb.containers[i] = .{ .array = storage.ptr };
                // std.debug.print("array: {any}\n", .{storage[0..@min(storage.len, 5)]});
            },
            .bitset => {
                const storage = try arena.alignedAlloc(u64, .fromByteUnits(32), 1024); // 8Ki
                try reader.readSliceEndian(u64, storage, .little);
                rb.containers[i] = .{ .bitset = storage.ptr };
                // std.debug.print("bitset:", .{});
                // for (storage[0..@min(storage.len, 5)]) |x| std.debug.print("{b}, ", .{x});
                // std.debug.print("\n", .{});
            },
            .run => {
                const len: u32 = try reader.takeInt(u16, .little);
                // std.debug.print("run len: {} rb.runs_bitset: {any}\n", .{ len, rb.runs_bitset.?[0..runs_bitset_count] });
                const storage = try arena.alloc(u16, len * 2);
                try reader.readSliceEndian(u16, storage, .little);
                rb.containers[i] = .{ .run = storage.ptr };
                // std.debug.print("run: {any}\n", .{storage[0..@min(storage.len, 5)]});
            },
            .shared => unreachable, // TODO
        }
    }

    // std.debug.print("{} {}\n", .{ rb.cookie, rb.count });
    // std.debug.print("container meta:\n", .{});
    // for (rb.metas[0..rb.count]) |x|
    //     std.debug.print("  {any}\n", .{x});
    // if (rb.offsets != null) {
    //     std.debug.print("offsets:\n", .{});
    //     for (rb.offsets.?[0..rb.count]) |x| std.debug.print("  {any}\n", .{x});
    // }

    return rb;
}

fn validateTestdata(filepath: []const u8) !void {
    const f = try std.fs.cwd().openFile(filepath, .{});
    defer f.close();
    var rbuf: [256]u8 = undefined;
    var freader = f.reader(&rbuf);
    var b: BitmapStorage.Builder = .init(testing.allocator);
    defer b.arena.deinit();
    const rb = try b.deserialize(&freader.interface);

    // > That is, they contain all multiplies of 1000 in [0,100000), all multiplies of 3 in [100000,200000) and all values in [700000,800000).
    var k: u32 = 0;
    while (k < 100000) : (k += 1000) {
        try testing.expect(rb.contains(k));
    }
    // for (int k = 100000; k < 200000; ++k) {
    //     rb.add(3*k);
    // }
    // for (int k = 700000; k < 800000; ++k) {
    //     rb.add(k);
    // }
}

test "without runs" {
    try validateTestdata("testdata/bitmapwithoutruns.bin");
}

test "with runs" {
    try validateTestdata("testdata/bitmapwithruns.bin");
}

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;
const root = @import("root.zig");
const Array = root.Array;
const Bitmap = root.Bitmap;
