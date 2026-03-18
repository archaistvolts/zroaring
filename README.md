# About
A port of [CRoaring](https://github.com/RoaringBitmap/CRoaring)

This repo is hosted on [codeberg](https://codeberg.org/archaistvolts/zroaring) and mirrored to [github](https://github.com/archaistvolts/zroaring).

requires Zig version 0.15.2

# Documentation
[Documentation](https://archaistvolts.github.io/zroaring/) is hosted on github.

# Use

### With the Zig package manager
```console
$ zig fetch --save git+https://codeberg.org/archaistvolts/zroaring
```
```zig
// build.zig
const zroaring_dep = b.dependency("zroaring", .{ .target = target, .optimize = optimize });
const exe_mod = b.createModule(.{
    // ...
    .imports = &.{
        .{ .name = "zroaring", .module = zroaring_dep.module("zroaring") },
    },
});
```
```zig
// app.zig
const zroaring = @import("zroaring");
var zr: zroaring.Bitmap = .{};
defer zr.deinit(std.testing.allocator);
try zr.add(std.testing.allocator, 1);
try std.testing.expect(zr.contains(1));
try std.testing.expect(!zr.contains(2));
```

# Contributing
Contributions are welcome.  Please open an pull request or issue on codeberg if you run into a TODO or FIXME while using this project.  There is a lot of work to do here.  Obviously AI generated contributions will not be accepted.

# References
* https://github.com/RoaringBitmap/RoaringFormatSpec/
* https://github.com/RoaringBitmap/CRoaring
* https://github.com/awesomo4000/rawr
* https://github.com/lalinsky/roaring.zig

# Ideas
* https://github.com/MartinErhardt/RoaringRegex
 * use in regex / peg impl in another project
