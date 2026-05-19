# About
A Roaring Bitmap implementation in zig inspired by [CRoaring](https://github.com/RoaringBitmap/CRoaring) and with a similar API.

This repo is hosted on [codeberg](https://codeberg.org/archaistvolts/zroaring) and mirrored to [github](https://github.com/archaistvolts/zroaring).

# Documentation
[Documentation](https://archaistvolts.github.io/zroaring/) is hosted on github.

# Use
With zig version 0.16.0

:warning: **Be sure to test your application in debug mode as there may be unreachable code paths left as TODOs**.

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
var zr: zroaring.Bitmap = .empty;
defer zr.deinit(std.testing.allocator);
try zr.add(std.testing.allocator, 1);
try std.testing.expect(zr.contains(1));
try std.testing.expect(!zr.contains(2));
```

# Test
`$ zig build test`
### Fuzz
* with the build system:
```console
$ zig build test -Dllvm --fuzz
```
* with nix-shell and AFL++:
```console
$ nix-shell
$ ./scripts/afl-fuzz.sh
```

# Contributing
Human contributions are very welcome.  Please open a pull request or issue on codeberg if you run into a TODO, FIXME or any problems while using this project.  There is a lot of work yet to be done here.

# References
* https://github.com/RoaringBitmap/RoaringFormatSpec
* https://github.com/RoaringBitmap/CRoaring
* https://github.com/awesomo4000/rawr
* https://github.com/lalinsky/roaring.zig
* https://github.com/archaistvolts/resizable-struct

# Ideas / TODOs - contributions welcome
* [x] in memory layout - a single allocation, resizable struct to model state - serialization friendly, single write, single read.
* [x] Transition to a more from-scratch approach.  Don't try to follow CRoaring impl closely, but try to follow the API.
* [x] validation: fix failing checkAllAllocationFailures test
* [ ] Provide a similar api to std.HashMap
* [ ] Bounded API: initBuffer, appendBounded
* [ ] Support more set sizes than just u32 with generics - Bitmap(T)
* [ ] build commands `$ zig build [api-coverage | correctness | bench]`
  * [ ] api-coverage:    show % of c api covered
  * [ ] api-correctness: show % correct fuzzing with c api oracle
  * [ ] api-endian:      check for and document endian sensitive methods by comparing big endian serialized bytes to little endian bytes with help from qemu.
  * [ ] bench:           show timings of bench with c
    * [ ] keep track of benchmarks over time
* [ ] documentation needs a lot of work
* [ ] audit endian sensitive methods.  aim for endian awareness throughout.
* [ ] audit unreachable code paths.  fuzzing will help.
* [ ] use in regex / peg impl in another project maybe following https://github.com/MartinErhardt/RoaringRegex
