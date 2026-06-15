# About
A Roaring Bitmap with a flat, pointerless layout and API similar to [CRoaring](https://github.com/RoaringBitmap/CRoaring).  Implemented with [resizable struct](https://codeberg.org/ziglang/zig/pulls/30823) [2](https://github.com/archaistvolts/resizable-struct), all Bitmap data shares a single, serialization and simd friendly allocation.

This repo is hosted on [codeberg](https://codeberg.org/archaistvolts/zroaring) and mirrored to [github](https://github.com/archaistvolts/zroaring).

# Documentation
[Documentation](https://archaistvolts.github.io/zroaring/) is hosted on github.

# Use
With zig version 0.16.0

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
With an Allocator
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

`-Dfuzzprint` prints zon reproductions which can be copied to [src/fuzz-crash-corpus.zon](src/fuzz-crash-corpus.zon).
#### With nix-shell and AFL++:

```console
$ nix-shell
$ ./scripts/afl-fuzz.sh
```

AFL fuzzing is a work in progress.  It uses `std.ArrayHashMap` instead `CRoaring` as an oracle due to some fuzzer build issues.

#### Reproducing with an AFL crash/hang file
```console
$ zig build && zig-out/bin/afl-main afl/output/default/crashes.2026-06-12-18\:09\:25/id:000000,sig:06,src:000003,time:565011,execs:101066,op:havoc,rep:1
```

# CRoaring API coverage
```console
$ date +%F; zig build run -- api-coverage
```
```console
2026-06-14

parsed command:
  api-coverage --filter API-COVERAGE-FILTER-NONE

symbols coverage:
  prefix              : found / total / %   :
---------------------------------------------
  roaring_bitmap_     : 53    / 93    / 57.0%
  ra_                 : 14    / 40    / 35.0%
  container_          : 37    / 64    / 57.8%
  run_container_      : 32    / 60    / 53.3%
  bitset_container_   : 29    / 66    / 43.9%
  array_container_    : 29    / 58    / 50.0%
---------------------------------------------
  total               : 194   / 381   / 50.9%
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
* [x] checkAllAllocationFailures - why so slow? - added -Dskip-slow-tests
* [x] allocation failures test with crash corpus.
* [x] container: match croaring binop param ordering: src1, src2, dst
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
* [ ] use in regex / peg impl in another project maybe following https://github.com/MartinErhardt/RoaringRegex
* [ ] strategy for reclaiming blocks to reduce memory usage.  depending on users calling shrink_to_fit() isn't viable.
* [ ] AFL fuzzer
  * [ ] try again to use croaring, address build issues, remove HashMapOracle
  * [ ] slow fuzzing - check for HashMapOracle leaks
* [ ] CI: windows failure: use translate-c to replace pre-translated src/c/roaring.zig
