/// Designed for frequent updates.
pub const Array = extern struct {
    // Fields ordered for serialization and small, `Block` size.
    // Slice fields ordered by decreasing element size to simplify math.

    /// shared container count. 0..65536.
    len: u32 align(C.BLOCK_ALIGN),
    /// shared container capacity.  0..65536.
    capacity: u32,
    magic: root.Magic,
    /// an extern compatible `std.enums.EnumSet(Flag)`
    flags: u8,

    containers: [*]align(C.BLOCK_ALIGN) root.Container,
    /// keys from `descriptive_header`.
    keys: [*]align(C.BLOCK_ALIGN) u16,

    pub const empty = mem.zeroes(Array);
    pub const AlignedPtr = *align(C.BLOCK_ALIGN) Array;

    pub fn can_have_run_containers(h: *const Array) bool {
        return h.magic == .SERIAL_COOKIE;
    }

    pub fn get_run_flags(h: *const Array) []u8 {
        return if (h.can_have_run_containers())
            h.run_flags.?[0 .. (h.len + 7) / 8]
        else
            &.{};
    }

    pub fn GetSlice(comptime field: std.meta.FieldEnum(Array)) type {
        const F = @FieldType(Array, @tagName(field));
        const finfo = @typeInfo(F).pointer;
        const OtherSlice = if (finfo.is_const) []align(C.BLOCK_ALIGN) const finfo.child else []align(C.BLOCK_ALIGN) finfo.child;
        const ret = mem.bytesAsSlice(
            std.meta.Child(F),
            mem.sliceAsBytes(@as(OtherSlice, mem.zeroes(OtherSlice))),
        );
        return @TypeOf(ret);
    }

    /// Helper for slicing Array pointer `field` with len from `len_field`.
    ///  * example: `h.slice(.keys, .len)`.
    pub fn slice(
        h: *const Array,
        comptime field: std.meta.FieldEnum(Array),
        comptime len_field: std.meta.FieldEnum(Array),
    ) GetSlice(field) {
        const ptr = @field(h, @tagName(field));
        const len = @field(h, @tagName(len_field));
        // trace(@src(), "{t}.{t}: {*} {*} {}", .{ field, len_field, h, ptr, len });
        return misc.asSlice(GetSlice(field), ptr[0..len]);
    }

    pub fn get_container(h: *const Array, id: Container.Id) Container {
        return h.containers[@intFromEnum(id)];
    }

    pub fn has_run_container(a: *const Array) bool {
        return for (a.slice(.containers, .len)) |c| {
            if (c.typecode == .run) break true;
        } else false;
    }

    /// depends only on `ra.len`.
    pub fn portable_size_ext(ra: *const Array, hasruns: bool) usize {
        const count = ra.len;
        if (hasruns) {
            return 4 + (count + 7) / 8 +
                if (count < C.NO_OFFSET_THRESHOLD) // for small bitmaps, we omit the offsets
                    4 * count
                else
                    8 * count; // - 4 because we pack the size with the cookie
        } else {
            return 4 + 4 + 8 * count; // no run flags, u32 cardinality,
        }
    }

    /// file position where array data ends and container data starts.
    /// depends only on `ra.magic` and `ra.len`.
    pub fn portable_size(ra: *const Array) usize {
        return ra.portable_size_ext(ra.can_have_run_containers());
    }

    /// file position where array data ends and container data starts.
    /// depends on `ra.containers` being populated and checks if there are any
    /// run containers present.
    pub fn portable_size_has_run(ra: *const Array) usize {
        return ra.portable_size_ext(ra.has_run_container());
    }

    /// `containers` must be populated such as after deserialize()
    pub fn portable_size_in_bytes(ra: *const Array) usize {
        var count = ra.portable_size_has_run();
        // trace(@src(), "portable_size_has_run={}", .{count});
        for (ra.slice(.containers, .len)) |c| {
            count += c.serialized_size_in_bytes();
        }
        return count;
    }

    pub const Info = struct {
        serialized_size: usize,
        cookie: root.Cookie,
        len: u32,
    };

    /// how many bytes are needed to store array slices (not including `@sizeOf(Array)`).
    pub fn info_from_file(io: Io, bitmap_file: Io.File) !Info {
        var read_buf: [8]u8 = undefined;
        var freader = bitmap_file.reader(io, &read_buf);
        return info_from_file_reader(&freader);
    }

    /// advances `freader` by 4 bytes or 8 bytes when there are runs
    pub fn info_from_file_reader(freader: *Io.File.Reader) !Info {
        assert(freader.logicalPos() == 0);
        const r = &freader.interface;
        const cookie = try r.takeStruct(root.Cookie, .little);
        if (cookie.magic != .SERIAL_COOKIE and
            cookie.magic != .SERIAL_COOKIE_NO_RUNCONTAINER)
            return error.UnexpectedCookie;

        const len = if (cookie.magic == .SERIAL_COOKIE)
            @as(u32, cookie.cardinality_minus1) + 1
        else
            try r.takeInt(u32, .little);

        return .{
            .cookie = cookie,
            .len = len,
            .serialized_size = serialized_size_from_count(cookie.magic, len),
        };
    }

    pub fn buffer_size_from_count(magic: root.Magic, container_count: u32) usize {
        const ssize = serialized_size_from_count(magic, container_count);
        return mem.alignForward(usize, ssize, @alignOf(root.Block));
    }

    pub fn serialized_size_from_count(magic: root.Magic, container_count: u32) usize {
        const run_flags_len = if (magic == .SERIAL_COOKIE)
            (container_count + 7) / 8
        else
            0;
        const size = run_flags_len +
            container_count * (@sizeOf(Container) + @sizeOf(u16));
        return size;
    }

    pub fn buffer_size(ra: *const Array) usize {
        return buffer_size_from_count(ra.magic, ra.len);
    }

    /// inverse of buffer_size_from_count
    pub fn count_from_buffer_size(magic: root.Magic, buf_size: usize) u32 {
        return @intCast(buf_size / ( //
            @sizeOf(Container) + // containers
                @sizeOf(u16) + // keys
                @as(u32, 1) * @intFromBool(magic == .SERIAL_COOKIE) + // run_flags
                0));
    }

    /// copies `ra` and its' slices to a `newa` with slices backed by `array_buf`.
    /// updates `newa.size` and `capacity`.
    pub fn init_from_buffer(newra: *Array, oldra: *const Array, array_buf: []align(C.BLOCK_ALIGN) u8, newlen: u32) !void {
        var fba = std.heap.FixedBufferAllocator.init(array_buf);
        const fbaa = fba.allocator();
        newra.* = oldra.*;
        newra.capacity = count_from_buffer_size(oldra.magic, array_buf.len);
        trace(@src(), "{}", .{newra});
        assert(newra.capacity >= newra.len);

        newra.containers = (try fbaa.alignedAlloc(Container, C.BLOCK_ALIGNMENT, newlen)).ptr;
        @memcpy(newra.slice(.containers, .len).ptr, oldra.slice(.containers, .len));
        newra.keys = (try fbaa.alignedAlloc(u16, C.BLOCK_ALIGNMENT, newlen)).ptr;
        @memcpy(newra.slice(.keys, .len).ptr, oldra.slice(.keys, .len));
        if (oldra.magic == .SERIAL_COOKIE) {
            unreachable;
            // const new_run_flags = try fbaa.alloc(u8, (newlen + 7) / 8);
            // if (oldra.run_flags != null) {
            //     @memcpy(new_run_flags.ptr, oldra.get_run_flags());
            // } else {
            //     @memset(new_run_flags, 0);
            // }
            // newra.run_flags = new_run_flags.ptr;
        }
    }

    /// allocate `Array`.containers and `Array`.keys.  read/write all container
    /// cardinalities and keys.  read run_flags when present.
    ///
    /// returns number of blocks needed to store all containers.
    pub fn deserialize_file_reader(
        ra: *Array,
        freader: *Io.File.Reader,
        run_flags: ?*root.RunFlags,
    ) !void {
        assert(ra.magic == .SERIAL_COOKIE or ra.magic == .SERIAL_COOKIE_NO_RUNCONTAINER);
        assert(ra.len <= C.MAX_KEY_CARDINALITY); // data must be corrupted
        const r = &freader.interface;
        const hasruns = ra.magic == .SERIAL_COOKIE;

        if (hasruns) {
            try r.readSliceAll(run_flags.?[0 .. (ra.len + 7) / 8]);
        }

        for (0..ra.len) |i| { // TODO maybe read N key_cards at a time, less looping here
            const kc = try r.takeStruct(root.KeyCard, .little);
            ra.keys[i] = kc.key;
            ra.containers[i].cardinality = @as(u30, kc.cardinality_minus1) + 1;
        }

        // skip file offsets
        if (!hasruns or (hasruns and ra.len >= C.NO_OFFSET_THRESHOLD))
            _ = try r.discard(.limited(ra.len * @sizeOf(u32)));

        assert(freader.logicalPos() == ra.portable_size());
    }

    pub fn internal_validate(h: *const Array, reason: *?[]const u8, r: *const root.Bitmap) bool {
        if (!(@intFromEnum(h.magic) == 0 or
            h.magic == .SERIAL_COOKIE or
            h.magic == .SERIAL_COOKIE_NO_RUNCONTAINER))
        {
            reason.* = "unsupported magic";
            return false;
        }

        // trace(@src(), "{}\n  buffer_size()={} h.allocation_size={}", .{ h, h.buffer_size(), h.capacity });
        if (!(h.capacity >= h.len)) {
            reason.* = "array capacity not gte len";
            return false;
        }
        // if (h.can_have_run_containers() != (h.run_flags != null)) {
        //     reason.* = "invalid array run flags";
        //     return false;
        // }

        // Serialization Sync: Check that container_startpos equals the sum of the array field sizes plus any padding.
        for (h.slice(.containers, .len)) |c| {
            if (!c.internal_validate(reason, r)) return false;
        }

        return true;
    }

    pub fn format(h: *const Array, w: *Io.Writer) !void {
        try w.print("len/capacity={}/{} keys={any}", .{ h.len, h.capacity, h.slice(.keys, .len) });
        for (h.slice(.containers, .len), 0..) |c, i| {
            try w.print("\n  {}: {}", .{ i, c });
        }
    }
};

test Array {
    // check Array has same size as an auto layout, ArrayAuto.
    const ArrayAuto = @Struct(.auto, null, std.meta.fieldNames(Array), misc.fieldTypes(Array), &@splat(.{}));
    try testing.expectEqual(@sizeOf(Array), @sizeOf(ArrayAuto));
    try testing.expectEqual(32, @sizeOf(Array));

    const testio = testing.io;
    {
        const f = try Io.Dir.cwd().openFile(testio, "testdata/bitmapwithoutruns.bin", .{});
        defer f.close(testio);
        try testing.expectEqual(110, (try Array.info_from_file(testio, f)).serialized_size);
    }
    {
        const f = try Io.Dir.cwd().openFile(testio, "testdata/bitmapwithruns.bin", .{});
        defer f.close(testio);
        try testing.expectEqual(112, (try Array.info_from_file(testio, f)).serialized_size);
    }
}

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const root = @import("root.zig");
const Container = root.Container;
const misc = @import("misc.zig");
const C = @import("constants.zig");
const trace = misc.trace;
