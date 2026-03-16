/// a tagged pointer
pub const Container = packed struct(usize) {
    typecode: Typecode,
    address: Address,

    const Address = @Type(.{ .int = .{
        .bits = @bitSizeOf(usize) - @bitSizeOf(Typecode),
        .signedness = .unsigned,
    } });

    pub fn init(c: anytype) Container {
        const address = @intFromPtr(c);
        assert(@typeInfo(Typecode).@"enum".fields.len == 4);
        assert(address & 0b11 == 0);
        return .{
            .typecode = Typecode.fromType(@TypeOf(c.*)),
            .address = @intCast(address >> 2),
        };
    }

    pub fn deinit(c: Container, allocator: mem.Allocator) void {
        switch (c.typecode) {
            inline else => |t| {
                c.mut_cast(t).deinit(allocator);
                allocator.destroy(c.mut_cast(t));
            },
        }
    }

    pub fn ptr(c: Container) *anyopaque {
        return @ptrFromInt(@as(usize, c.address << 2));
    }

    pub fn is_null(c: Container) bool {
        return c.address == 0;
    }

    pub fn get_cardinality(c: Container) u64 {
        return switch (c.typecode) {
            inline else => |t| c.const_cast(t).cardinality,
            .run => unreachable, // TODO
            .shared => unreachable, // TODO
        };
    }

    pub fn get_container_type(c: Container) Typecode {
        return if (c.typecode == .shared)
            c.const_cast(.shared).container.typecode
        else
            c.typecode;
    }

    ///
    /// Get the container size in bytes under portable serialization (see
    /// container_write), requires a
    /// typecode
    ///
    pub fn size_in_bytes(c: Container) usize {
        const ret = switch (c.typecode) {
            inline else => |t| c.unwrap_shared().const_cast(t).size_in_bytes(),
        };
        // std.debug.print("Container.size_in_bytes {t} {}\n", .{ c.typecode, ret });
        return ret;
    }

    pub fn unwrap_shared(candidate_shared_container: Container) Container {
        // /* access to container underneath */
        // static inline const container_t *container_unwrap_shared(
        // const container_t *candidate_shared_container, uint8_t *type) {
        if (candidate_shared_container.typecode == .shared) {
            assert(candidate_shared_container.const_cast(.shared).container.typecode != .shared);
            return candidate_shared_container.const_cast(.shared).container;
        } else {
            return candidate_shared_container;
        }
    }

    // /* access to container underneath, cloning it if needed */
    pub fn get_writable_copy_if_shared(c: Container) Container {
        if (c.typecode == .shared) { // shared, return enclosed container
            // return shared_container_extract_copy(CAST_shared(c), type);
            unreachable; // TODO
        } else {
            return c; // not shared, so return as-is
        }
    }

    pub fn const_cast(c: Container, comptime typecode: Typecode) *const typecode.Type() {
        return @ptrCast(@alignCast(c.ptr()));
    }

    pub fn mut_cast(c: Container, comptime typecode: Typecode) *typecode.Type() {
        return @ptrCast(@alignCast(c.ptr()));
    }

    pub fn add(c: Container, allocator: mem.Allocator, val: u16) !Container {
        // TODO // const c = get_writable_copy_if_shared(c, &typecode);
        switch (c.typecode) {
            .bitset => {
                const bs: *BitsetContainer = c.mut_cast(.bitset);
                _ = bs.put(val);
                return c;
            },
            .array => {
                const ac = c.mut_cast(.array);
                const ok = try ac.try_add(allocator, val, Array.DEFAULT_MAX_SIZE) != .not_added;
                if (ok) return .init(ac);

                const bitset = try allocator.create(BitsetContainer);
                errdefer allocator.destroy(bitset);
                bitset.* = try ac.bitset_container_from_array(allocator);
                _ = bitset.put(val);
                return .init(bitset);
            },
            .run => {
                unreachable;
                // per Java, no container type adjustments are done (revisit?)
                // run_container_add(CAST_run(c), val);
                // *new_typecode = .run;
                // return c;
            },
            .shared => unreachable,
        }
    }

    pub fn addAssumeCapacity(c: Container, hb: u16, typecode: Typecode) void {
        _ = hb;
        _ = typecode;
        _ = c;
        unreachable; // TODO
    }

    pub fn free(c: Container, allocator: mem.Allocator) void {
        switch (c.typecode) {
            inline else => |t| c.mut_cast(t).free(allocator),
        }
    }

    ///
    /// Writes the underlying array to buf, outputs how many bytes were written.
    /// This is meant to be byte-by-byte compatible with the Java and Go versions of
    /// Roaring.
    /// The number of bytes written should be
    /// container_write(container, buf).
    ///
    pub fn write(c: Container, w: *Io.Writer) !usize {
        const c1 = c.unwrap_shared();
        return switch (c1.typecode) {
            inline else => |t| try c1.const_cast(t).write(w),
            // .bitset => ,
            // .array => c1.const_cast(.array).write(w),
            // .run => c1.const_cast(.run).write(w),
            .shared => unreachable,
        };
    }

    pub fn equals(c1: Container, c2: Container) bool {
        const c1_ = c1.unwrap_shared();
        const c2_ = c2.unwrap_shared();

        return switch (c1_.typecode.pair(c2_.typecode)) { // PAIR_CONTAINER_TYPES(type1, type2)) {
            Typecode.pair(.bitset, .bitset) => c1_.const_cast(.bitset)
                .equals(c2_.const_cast(.bitset)),
            Typecode.pair(.array, .array) => c1_.const_cast(.array)
                .equals(c2_.const_cast(.array)),
            else => {
                std.debug.print("Conatiner.equals(). TODO pair ({t}, {t})\n", .{ c1_.typecode, c2_.typecode });
                unreachable;
            },
            //     case CONTAINER_PAIR(BITSET, BITSET):
            //         return bitset_container_equals(const_CAST_bitset(c1),
            //                                        const_CAST_bitset(c2));

            //     case CONTAINER_PAIR(BITSET, RUN):
            //         return run_container_equals_bitset(const_CAST_run(c2),
            //                                            const_CAST_bitset(c1));

            //     case CONTAINER_PAIR(RUN, BITSET):
            //         return run_container_equals_bitset(const_CAST_run(c1),
            //                                            const_CAST_bitset(c2));

            //     case CONTAINER_PAIR(BITSET, ARRAY):
            //         // java would always return false?
            //         return array_container_equal_bitset(const_CAST_array(c2),
            //                                             const_CAST_bitset(c1));

            //     case CONTAINER_PAIR(ARRAY, BITSET):
            //         // java would always return false?
            //         return array_container_equal_bitset(const_CAST_array(c1),
            //                                             const_CAST_bitset(c2));

            //     case CONTAINER_PAIR(ARRAY, RUN):
            //         return run_container_equals_array(const_CAST_run(c2),
            //                                           const_CAST_array(c1));

            //     case CONTAINER_PAIR(RUN, ARRAY):
            //         return run_container_equals_array(const_CAST_run(c1),
            //                                           const_CAST_array(c2));

            //     case CONTAINER_PAIR(ARRAY, ARRAY):
            //         return array_container_equals(const_CAST_array(c1),
            //                                       const_CAST_array(c2));

            //     case CONTAINER_PAIR(RUN, RUN):
            //         return run_container_equals(const_CAST_run(c1), const_CAST_run(c2));

            //     default:
            //         assert(false);
            //         roaring_unreachable;
            //         return false;
            // }
        };
    }
    pub fn format(c: Container, w: *Io.Writer) !void {
        switch (c.typecode) {
            inline else => |tag| {
                try w.print("{t} ", .{tag});
                try c.const_cast(tag).format(w);
            },
        }
    }
};

pub const BitsetContainer = WordBitset(.{});

pub const RunContainer = struct {
    n_runs: u32,
    capacity: u32,
    runs: [*]Rle16,

    pub const Rle16 = struct { value: u16, length: u16 };

    pub fn deinit(r: RunContainer, allocator: mem.Allocator) void {
        allocator.free(r.runs[0..r.capacity]);
    }
    pub fn serialized_size_in_bytes(r: RunContainer) usize {
        return @sizeOf(u16) + @sizeOf(Rle16) * r.n_runs; // each run requires 2 2-byte entries.
    }
    pub fn size_in_bytes(r: RunContainer) usize {
        return r.serialized_size_in_bytes();
    }
    pub fn write(r: RunContainer, w: *Io.Writer) !usize {
        _ = r;
        _ = w;
        unreachable;
    }

    pub fn format(c: RunContainer, w: *Io.Writer) !void {
        _ = c; // autofix
        try w.print("RunConatiner values {any}", .{unreachable});
    }
};

pub const SharedContainer = extern struct {
    container: Container,
    /// to be managed atomically // TODO
    refcount: std.atomic.Value(u32),
    pub fn deinit(r: SharedContainer, allocator: mem.Allocator) void {
        r.container.deinit(allocator);
    }
    pub fn size_in_bytes(s: SharedContainer) usize {
        return s.container.size_in_bytes();
    }
    pub fn format(c: SharedContainer, w: *Io.Writer) error{WriteFailed}!void {
        try w.print("SharedContainer ", .{});
        try c.container.format(w);
    }
};

const types = @import("types.zig");
const Typecode = types.Typecode;
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Io = std.Io;
const ArrayContainer = @import("ArrayContainer.zig");
const Array = @import("Array.zig");
const WordBitset = @import("WordBitset.zig").WordBitset;
