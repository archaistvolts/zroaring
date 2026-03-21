# About
Exploring [CRoaring](https://github.com/RoaringBitmap/CRoaring) by attempting to port it to zig.  

This repo is hosted on [codeberg](https://codeberg.org/archaistvolts/zroaring) and mirrored to [github](https://github.com/archaistvolts/zroaring).

# Documentation
[Documentation](https://archaistvolts.github.io/zroaring/) is hosted on github.

# Use
With zig version 0.15.2

### fetch package
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
Human contributions are very welcome.  Please open a pull request or issue on codeberg if you run into a TODO or FIXME while using this project.  There is a lot of work yet to be done here.

# References
* https://github.com/RoaringBitmap/RoaringFormatSpec
* https://github.com/RoaringBitmap/CRoaring
* https://github.com/awesomo4000/rawr
* https://github.com/lalinsky/roaring.zig

# Ideas
* Support more set sizes than just u32 with generics or a build option.
* Bounded API: initBuffer, appendBounded
* For now this an exploration of CRoaring.  Hopefully this project could transition to a more from-scratch approach given better understanding.
* an API which delegates to c and zig backends.  perhaps some c translation to build the c api?

* https://github.com/MartinErhardt/RoaringRegex
 * use in regex / peg impl in another project
