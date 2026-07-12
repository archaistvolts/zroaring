/// Iterator for roaring bitmaps
const Iterator = @This();

parent: Bitmap,
container: Container,
container_index: u32,
highbits: u32,
container_it: zr.container.Iterator,
current_value: u32,
has_value: bool,

fn load_first_value(it: *Iterator) bool {
    if (it.container_index >= it.parent.array.len or
        it.container_index < 0)
    {
        it.current_value = std.math.maxInt(u32);
        it.has_value = false;
        return false;
    }
    it.has_value = true;
    const containers = it.parent.array.containers;
    it.container = containers[it.container_index];
    it.highbits = @as(u32, it.parent.array.keys[it.container_index]) << 16;
    var value: u16 = undefined;
    it.container_it = it.container.init_iterator(&value);
    it.current_value = it.highbits | value;
    return true;
}

fn load_last_value(it: *Iterator) bool {
    if (it.container_index >= it.parent.array.len or it.container_index < 0) {
        it.current_value = std.math.maxInt(u32);
        it.has_value = false;
        return false;
    }
    it.has_value = true;
    const containers = it.parent.array.containers;
    it.container = &containers[it.container_index];
    it.highbits = @as(u32, it.parent.array.keys[it.container_index]) << 16;
    var value: u16 = undefined;
    it.container_it = it.containerinit_iterator_last(it.parent, &value);
    it.current_value = it.highbits | value;
    return true;
}

fn load_first_value_largeorequal(it: *Iterator, val: u32) bool {
    _ = it.load_first_value();
    var value: u16 = undefined;
    if (!it.container.iterator_lower_bound(it.parent, &it.container_it, &value, @truncate(val))) return false;
    it.current_value = it.highbits | value;
    return true;
}

/// Initialize an iterator at the first value.
pub fn init(r: Bitmap) Iterator {
    var it = Iterator{
        .parent = r,
        .container = undefined,
        .container_index = 0,
        .highbits = 0,
        .container_it = .{ .index = 0 },
        .current_value = 0,
        .has_value = false,
    };
    it.has_value = it.load_first_value();
    return it;
}

/// Initialize an iterator at the last value.
pub fn init_last(r: Bitmap) Iterator {
    const size = r.array.len;
    var it = Iterator{
        .parent = r,
        .container = undefined,
        .container_index = @as(i32, @intCast(if (size > 0) size - 1 else 0)),
        .highbits = 0,
        .container_it = .{ .index = 0 },
        .current_value = 0,
        .has_value = false,
    };
    it.has_value = it.load_last_value();
    return it;
}

/// Advance the iterator. Returns has_value.
fn advance(it: *Iterator) bool {
    if (it.container_index >= @as(i32, @intCast(it.parent.array.len))) {
        it.has_value = false;
        return false;
    }
    if (it.container_index < 0) {
        it.container_index = 0;
        it.has_value = it.load_first_value();
        return it.has_value;
    }
    var low16: u16 = @truncate(it.current_value);
    if (it.container.iterator_next(&it.container_it, &low16)) {
        it.current_value = it.highbits | low16;
        it.has_value = true;
        return true;
    }
    it.container_index += 1;
    it.has_value = it.load_first_value();
    return it.has_value;
}

/// Move to previous value. Returns has_value.
fn previous(it: *Iterator) bool {
    if (it.container_index < 0) {
        it.has_value = false;
        return false;
    }
    if (it.container_index >= @as(i32, @intCast(it.parent.array.len))) {
        it.container_index = @as(i32, @intCast(it.parent.array.len)) - 1;
        it.has_value = it.load_last_value();
        return it.has_value;
    }
    var low16: u16 = @truncate(it.current_value);
    if (it.container.iterator_prev(it.parent, &it.container_it, &low16)) {
        it.current_value = it.highbits | low16;
        it.has_value = true;
        return true;
    }
    it.container_index -= 1;
    it.has_value = it.load_last_value();
    return it.has_value;
}

/// Move the iterator to the first value >= val. Returns has_value.
pub fn move_equalorlarger(it: *Iterator, val: u32) bool {
    const hb: u16 = @truncate(val >> 16);
    const i = it.parent.get_key_index(hb);
    if (i >= 0) {
        const containers = it.parent.array.containers;
        const low_max = Container.maximum(containers[@intCast(i)], it.parent);
        const lb: u16 = @truncate(val);
        if (low_max < lb) {
            it.container_index = i + 1;
        } else {
            it.container_index = i;
            it.has_value = it.load_first_value_largeorequal(val);
            return it.has_value;
        }
    } else {
        it.container_index = -i - 1;
    }
    it.has_value = it.load_first_value();
    return it.has_value;
}

/// Read next values into buf. Returns number read.
pub fn read(it: *Iterator, buf: []u32) u32 {
    var ret: u32 = 0;
    while (it.has_value and ret < buf.len) {
        var consumed: u32 = 0;
        var low16: u16 = @truncate(it.current_value);
        const has_val = it.container.iterator_read_into_uint32(&it.container_it, it.highbits, buf[ret..], &consumed, &low16);
        ret += consumed;
        if (has_val) {
            it.has_value = true;
            it.current_value = it.highbits | low16;
            return ret;
        }
        it.container_index += 1;
        it.has_value = it.load_first_value();
    }
    return ret;
}

/// Skip next count values. Returns number skipped.
pub fn skip(it: *Iterator, count: u32) u32 {
    var ret: u32 = 0;
    while (it.has_value and ret < count) {
        var consumed: u32 = 0;
        var low16: u16 = @truncate(it.current_value);
        const has_val = it.container.iterator_skip(it.parent, &it.container_it, count - ret, &consumed, &low16);
        ret += consumed;
        if (has_val) {
            it.has_value = true;
            it.current_value = it.highbits | low16;
            return ret;
        }
        it.container_index += 1;
        it.has_value = it.load_first_value();
    }
    return ret;
}

/// Skip previous count values going backwards. Returns number skipped.
pub fn skip_backward(it: *Iterator, count: u32) u32 {
    var ret: u32 = 0;
    while (it.has_value and ret < count) {
        var consumed: u32 = 0;
        var low16: u16 = @truncate(it.current_value);
        const has_val = it.container.iterator_skip_backward(it.parent, &it.container_it, count - ret, &consumed, &low16);
        ret += consumed;
        if (has_val) {
            it.has_value = true;
            it.current_value = it.highbits | low16;
            return ret;
        }
        it.container_index -= 1;
        it.has_value = it.load_last_value();
    }
    return ret;
}

pub fn next(it: *Iterator) ?u32 {
    if (!it.has_value) return null;
    defer _ = it.advance();
    return it.current_value;
}

pub fn prev(it: *Iterator) ?u32 {
    if (!it.has_value) return null;
    defer _ = it.previous();
    return it.current_value;
}

const zr = @import("root.zig");
const Bitmap = zr.Bitmap;
const Container = zr.Container;
const std = @import("std");
