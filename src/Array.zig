/// an unmanaged, sorted array list wrapper with Olog(n) contains() via binary search.
/// TODO more assume capacity functions
/// TODO bounded api
pub const Array = @This();

/// a sorted list
values: *std.ArrayList(V),

pub const V = u16;

pub fn init(values: *std.ArrayList(V)) Array {
    return .{ .values = values };
}

pub fn deinit(self: Array, allocator: mem.Allocator) void {
    self.values.deinit(allocator);
}

pub fn set(self: Array, allocator: mem.Allocator, value: V) !Array {
    const idx = sort.lowerBound(V, self.values.items, value, order);
    if (idx < self.values.items.len and self.values.items[idx] == value)
        return self;
    try self.values.insert(allocator, idx, value);
    assert(sort.isSorted(V, self.values.items, {}, sort.asc(u16)));
    return self;
}

pub fn setAssumeCapacity(self: Array, value: V) Array {
    const idx = sort.lowerBound(V, self.values.items, value, order);
    if (idx < self.values.items.len and self.values.items[idx] == value)
        return self;
    self.values.insertAssumeCapacity(idx, value);
    return self;
}

pub fn setValues(self: Array, allocator: mem.Allocator, vals: []const V) !Array {
    try self.values.ensureUnusedCapacity(allocator, vals.len);
    for (vals) |v| _ = self.setAssumeCapacity(allocator, v);
    return self;
}

pub fn setValuesAssumeCapacity(self: Array, vals: []const V) Array {
    for (vals) |v| _ = self.setAssumeCapacity(v);
    return self;
}

pub fn unset(self: Array, value: V) Array {
    if (sort.binarySearch(V, self.values.items, value, order)) |idx|
        _ = self.values.orderedRemove(idx);
    return self;
}

pub fn contains(self: Array, value: V) bool {
    return sort.binarySearch(V, self.values.items, value, order) != null;
}

pub fn containsValues(self: Array, vals: []const V) bool {
    for (vals) |v| {
        if (!self.contains(v)) return false;
    }
    return true;
}

pub fn cardinality(self: Array) u32 {
    return @intCast(self.values.items.len);
}

pub fn isEmpty(self: Array) bool {
    return self.values.items.len == 0;
}

pub fn clear(self: Array) Array {
    self.values.clearRetainingCapacity();
    return self;
}

pub fn copy(self: Array, allocator: mem.Allocator, other: Array) !Array {
    self.values.clearRetainingCapacity();
    try self.values.appendSlice(allocator, other.values.items);
    return self;
}

pub fn equals(self: Array, other: Array) bool {
    if (self.cardinality() != other.cardinality()) return false;
    for (self.values.items, other.values.items) |s, o| { // TODO optimize?
        if (s != o) return false;
    }
    return true;
}

pub fn unionWith(self: Array, allocator: mem.Allocator, other: Array) !Array {
    for (other.values.items) |v| _ = try self.set(allocator, v);
    return self;
}

pub fn unionWithAssumeCapacity(self: Array, other: Array) Array {
    _ = self.setValuesAssumeCapacity(other.values.items);
    return self;
}

pub fn intersectWith(self: Array, other: Array) Array {
    var i: usize = 0;
    while (i < self.values.items.len) {
        if (!other.contains(self.values.items[i])) {
            _ = self.values.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    return self;
}

pub fn differenceWith(self: Array, other: Array) Array {
    var i: usize = 0;
    while (i < self.values.items.len) {
        if (other.contains(self.values.items[i])) {
            _ = self.values.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    return self;
}

pub fn xorWith(self: Array, allocator: mem.Allocator, other: Array) !Array {
    for (other.values.items) |v| {
        if (self.contains(v)) {
            _ = self.unset(v);
        } else {
            _ = try self.set(allocator, v);
        }
    }
    return self;
}

pub fn order(a: V, b: V) std.math.Order {
    return std.math.order(a, b);
}

test init {
    var buf1: [3]u16 = undefined;
    var values: std.ArrayList(u16) = .initBuffer(&buf1);
    var container = init(&values);
    try testing.expectEqual(container.cardinality(), 0);
}

test contains {
    var buf1: [3]u16 = undefined;
    var values: std.ArrayList(u16) = .initBuffer(&buf1);
    var container = init(&values).setAssumeCapacity(5);
    try testing.expect(container.contains(5));
    try testing.expect(!container.contains(6));
}

test setValuesAssumeCapacity {
    var buf1: [4]u16 = undefined;
    var values: std.ArrayList(u16) = .initBuffer(&buf1);
    var container = init(&values).setValuesAssumeCapacity(&.{ 0, 63, 100, 65535 });
    try testing.expect(container.containsValues(&.{ 0, 63, 100, 65535 }));
}

test "sort order" {
    var buf1: [4]u16 = undefined;
    var values: std.ArrayList(u16) = .initBuffer(&buf1);
    const container = init(&values).setValuesAssumeCapacity(&.{ 100, 5, 50, 10 });
    try testing.expectEqualSlices(u16, &.{ 5, 10, 50, 100 }, container.values.items);
}

test unset {
    var buf1: [3]u16 = undefined;
    var values: std.ArrayList(u16) = .initBuffer(&buf1);
    var container = init(&values).setAssumeCapacity(100);
    try testing.expect(container.contains(100));
    try testing.expect(!container.unset(100).contains(100));
}

test cardinality {
    var buf1: [3]u16 = undefined;
    var values: std.ArrayList(u16) = .initBuffer(&buf1);
    var container = init(&values);
    try testing.expectEqual(container.cardinality(), 0);
    _ = try container.set(talloc, 10);
    try testing.expectEqual(container.cardinality(), 1);
    _ = try container.set(talloc, 20);
    try testing.expectEqual(container.cardinality(), 2);
    _ = try container.set(talloc, 10);
    try testing.expectEqual(container.cardinality(), 2);
}

test unionWith {
    var buf1: [3]u16 = undefined;
    var values1: std.ArrayList(u16) = .initBuffer(&buf1);
    const c1 = init(&values1);

    var buf2: [3]u16 = undefined;
    var values2: std.ArrayList(u16) = .initBuffer(&buf2);
    var c2 = init(&values2);

    _ = c1.setValuesAssumeCapacity(&.{ 5, 10 });
    _ = c2.setValuesAssumeCapacity(&.{ 10, 15 });
    _ = try c1.unionWith(talloc, c2);
    try testing.expect(c1.containsValues(&.{ 5, 10, 15 }));
    try testing.expectEqual(c1.cardinality(), 3);
}

test intersectWith {
    var buf1: [3]u16 = undefined;
    var values1: std.ArrayList(u16) = .initBuffer(&buf1);
    var buf2: [3]u16 = undefined;
    var values2: std.ArrayList(u16) = .initBuffer(&buf2);
    const c1 = init(&values1).setValuesAssumeCapacity(&.{ 5, 10, 15 })
        .intersectWith(
        init(&values2).setValuesAssumeCapacity(&.{ 10, 15, 20 }),
    );
    try testing.expect(!c1.contains(5));
    try testing.expect(c1.contains(10));
    try testing.expect(c1.contains(15));
    try testing.expect(!c1.contains(20));
    try testing.expectEqual(c1.cardinality(), 2);
}

test xorWith {
    var buf1: [3]u16 = undefined;
    var buf2: [3]u16 = undefined;
    var values1: std.ArrayList(u16) = .initBuffer(&buf1);
    var values2: std.ArrayList(u16) = .initBuffer(&buf2);
    const c1 = try init(&values1).setValuesAssumeCapacity(&.{ 5, 10, 15 }).xorWith(
        talloc,
        init(&values2).setValuesAssumeCapacity(&.{ 10, 15, 20 }),
    );

    try testing.expect(c1.contains(5));
    try testing.expect(!c1.contains(10));
    try testing.expect(!c1.contains(15));
    try testing.expect(c1.contains(20));
    try testing.expectEqual(c1.cardinality(), 2);
}

test differenceWith {
    var buf1: [3]u16 = undefined;
    var values1: std.ArrayList(u16) = .initBuffer(&buf1);
    var buf2: [3]u16 = undefined;
    var values2: std.ArrayList(u16) = .initBuffer(&buf2);
    const c1 = init(&values1).setValuesAssumeCapacity(&.{ 5, 10, 15 })
        .differenceWith(init(&values2).setValuesAssumeCapacity(&.{ 10, 15, 20 }));

    try testing.expect(c1.contains(5));
    try testing.expect(!c1.containsValues(&.{ 10, 15 }));
    try testing.expectEqual(c1.cardinality(), 1);
}

test clear {
    var buf1: [3]u16 = undefined;
    var values: std.ArrayList(u16) = .initBuffer(&buf1);
    var container = init(&values).setValuesAssumeCapacity(&.{ 5, 100, 1000 });
    try testing.expectEqual(container.cardinality(), 3);
    _ = container.clear();
    try testing.expectEqual(container.cardinality(), 0);
}

test isEmpty {
    var buf1: [3]u16 = undefined;
    var values: std.ArrayList(u16) = .initBuffer(&buf1);
    var container = init(&values);
    try testing.expect(container.isEmpty());
    _ = container.setAssumeCapacity(100);
    try testing.expect(!container.isEmpty());
}

test equals {
    var buf1: [3]u16 = undefined;
    var values1: std.ArrayList(u16) = .initBuffer(&buf1);
    var buf2: [3]u16 = undefined;
    var values2: std.ArrayList(u16) = .initBuffer(&buf2);
    const c1 = init(&values1).setValuesAssumeCapacity(&.{ 5, 10 });
    const c2 = init(&values2).setValuesAssumeCapacity(&.{ 5, 10 });
    try testing.expect(c1.equals(c2));
    try testing.expect(!c1.equals(c2.setAssumeCapacity(15)));
}

test copy {
    var buf1: [3]u16 = undefined;
    var values: std.ArrayList(u16) = .initBuffer(&buf1);
    const c1 = init(&values).setValuesAssumeCapacity(&.{ 5, 100, 65535 });
    var buf2: [3]u16 = undefined;
    var values2: std.ArrayList(u16) = .initBuffer(&buf2);
    const c2 = try init(&values2).copy(talloc, c1);
    try testing.expect(c2.containsValues(&.{ 5, 100, 65535 }));
    try testing.expectEqual(c2.cardinality(), 3);
}

test "sparse region" {
    var buf1: [4]u16 = undefined;
    var values1: std.ArrayList(u16) = .initBuffer(&buf1);
    const container = init(&values1).setValuesAssumeCapacity(&.{ 0, 100, 10000, 65000 });
    try testing.expectEqual(container.cardinality(), 4);
    try testing.expect(container.containsValues(&buf1));
}

test "duplicates" {
    var buf1: [3]u16 = undefined;
    var values1: std.ArrayList(u16) = .initBuffer(&buf1);
    const container = init(&values1).setAssumeCapacity(50).setAssumeCapacity(50);
    try testing.expectEqual(container.cardinality(), 1);
}

test "multiple unions" {
    var buf1: [3]u16 = undefined;
    var values1: std.ArrayList(u16) = .initBuffer(&buf1);
    var buf2: [3]u16 = undefined;
    var values2: std.ArrayList(u16) = .initBuffer(&buf2);
    var buf3: [3]u16 = undefined;
    var values3: std.ArrayList(u16) = .initBuffer(&buf3);
    const c1 = init(&values1).setValuesAssumeCapacity(&.{ 5, 10, 15 })
        .unionWithAssumeCapacity(init(&values2).setValuesAssumeCapacity(&.{ 5, 10 }))
        .unionWithAssumeCapacity(init(&values3).setValuesAssumeCapacity(&.{15}));
    try testing.expectEqual(c1.cardinality(), 3);
    try testing.expect(c1.containsValues(&.{ 5, 10, 15 }));
}

test "intersection with empty" {
    var buf1: [3]u16 = undefined;
    var values1: std.ArrayList(u16) = .initBuffer(&buf1);
    var buf2: [3]u16 = undefined;
    var values2: std.ArrayList(u16) = .initBuffer(&buf2);
    const c1 = init(&values1).setValuesAssumeCapacity(&.{ 5, 10, 15 });
    try testing.expectEqual(3, c1.cardinality());
    try testing.expectEqual(0, c1.intersectWith(init(&values2)).cardinality());
}

const std = @import("std");
const testing = std.testing;
const talloc = testing.allocator;
const mem = std.mem;
const assert = std.debug.assert;
const sort = std.sort;
