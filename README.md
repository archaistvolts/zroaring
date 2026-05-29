# About
A Roaring Bitmap implementation in zig with an API similar to [CRoaring](https://github.com/RoaringBitmap/CRoaring).

Implemented with [resizable struct](https://github.com/archaistvolts/resizable-struct), the Bitmap and all container data share a single, serialization friendly allocation.

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
#### With the build system:
```console
$ zig build test -Doptimize=ReleaseSafe --fuzz --webui=[::1]:40313 -j1 -Dfuzzprint
```
`-Dfuzzprint` prints reproductions which can be copied to [src/fuzz.zig](src/fuzz.zig), test "crash reproductions".
#### With nix-shell and AFL++:

```console
$ nix-shell
$ ./scripts/afl-fuzz.sh
```

AFL fuzzing is a work in progress.  It uses `std.ArrayHashMap` instead `CRoaring` as an oracle due to some zig-0.16 fuzzer missing c symbols.  Also reproducing from AFL crash/hang files hasn't been implemented yet.

# CRoaring API coverage
```console
# 5/29/2026
$ zig build run -- api-coverage

parsed command:
  api-coverage --filter='API-COVERAGE-FILTER-NONE'

symbols coverage:
  prefix              : found / total / %   :
---------------------------------------------
  roaring_bitmap_     : 31    / 93    / 33.3%
  ra_                 : 13    / 40    / 32.5%
  container_          : 22    / 64    / 34.4%
  run_container_      : 24    / 60    / 40.0%
  bitset_container_   : 20    / 66    / 30.3%
  array_container_    : 24    / 58    / 41.4%
---------------------------------------------
  total               : 134   / 381   / 35.2%
---------------------------------------------
  filtered            : 0     / 0     / -nan%
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
* [x] Transition to a more from-scratch approach.  But try to follow the CRoaring API.
* [x] validation: fix failing checkAllAllocationFailures test
* [ ] checkAllAllocationFailures - why so slow?
* [ ] Provide a similar api to std.HashMap
* [ ] Bounded API: initBuffer, appendBounded
* [ ] Support more set sizes than just u32 with generics - Bitmap(T)
* [ ] build commands `$ zig build [api-coverage | correctness | bench]`
  * [x] api-coverage:    show % of c api covered
  * [ ] api-correctness: show % correct fuzzing with c api oracle
  * [ ] api-endian:      check for and document endian sensitive methods by comparing big endian serialized bytes to little endian bytes with help from qemu.
  * [ ] bench:           show timings of bench with c
    * [ ] keep track of benchmarks over time
* [ ] documentation needs a lot of work
* [ ] audit endian sensitive methods.  aim for endian awareness throughout.
* [ ] audit unreachable code paths.  fuzzing will help.
* [ ] use in regex / peg impl in another project maybe following https://github.com/MartinErhardt/RoaringRegex
