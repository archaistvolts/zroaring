# About
A Roaring Bitmap with a flat, pointerless layout and API similar to [CRoaring](https://github.com/RoaringBitmap/CRoaring).  Implemented with [resizable struct](https://codeberg.org/ziglang/zig/pulls/30823) ([2](https://github.com/archaistvolts/resizable-struct)), all Bitmap data shares a single, serialization and simd friendly allocation.

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

AFL fuzzing is a work in progress.  It uses `std.ArrayHashMap` instead of `CRoaring` as an oracle due to some fuzzer build issues.

#### Reproducing with an AFL crash/hang file
```console
$ zig build && zig-out/bin/afl-main afl/output/default/crashes...
```

# CRoaring API coverage
```console
$ date +%F; zig build run -- api-coverage
```
```console
2026-06-16

parsed command:
  api-coverage --filter API-COVERAGE-FILTER-NONE

symbols coverage:
  prefix              : found / total / %   :
---------------------------------------------
  roaring_bitmap_     : 57    / 93    / 61.3%
  ra_                 : 15    / 40    / 37.5%
  container_          : 39    / 64    / 60.9%
  run_container_      : 33    / 60    / 55.0%
  bitset_container_   : 30    / 66    / 45.5%
  array_container_    : 30    / 58    / 51.7%
---------------------------------------------
  total               : 204   / 381   / 53.5%
---------------------------------------------
  filtered            : 0     / 0     / -nan%
```

Add `--filter`, a substring to search, if you want to see individual method coverage.

# Contributing
Human contributions are very welcome.  Please open a pull request or issue on codeberg if you run into a TODO, FIXME or any problems while using this project.  There is a lot of work yet to be done here.

# Ideas / TODOs - contributions welcome
* [x] in memory layout - a single allocation, resizable struct to model state - serialization friendly, single write, single read.
* [x] validation: fix failing checkAllAllocationFailures test
* [x] checkAllAllocationFailures - why so slow? - added -Dskip-slow-tests
* [x] allocation failures test with crash corpus.
* [x] container: match croaring binop param ordering: src1, src2, dst
* [ ] Provide a similar api to std.HashMap
* [ ] Bounded API: initBuffer, appendBounded
* [ ] Support more set sizes than just u32. with generics - Bitmap(T)?
* [ ] build commands `$ zig build [api-coverage | correctness | bench]`
  * [x] api-coverage:    show % of c api covered
  * [x] bench:           show timings of bench with c
    * [x] keep track of benchmarks over time - testdata/bench-data.csv
  * [ ] api-correctness: show % correct fuzzing with c api oracle
  * [ ] api-endian:      check for and document endian sensitive methods by comparing big endian serialized bytes to little endian bytes with help from qemu.
* [ ] documentation needs a lot of work
* [ ] audit endian sensitive methods.  aim for endian awareness throughout.
* [ ] use in regex / peg impl in another project maybe following https://github.com/MartinErhardt/RoaringRegex
* [ ] strategy for reclaiming blocks to reduce memory usage.  depending on users calling shrink_to_fit() doesn't seem viable.
* [ ] AFL fuzzer
  * [ ] slow fuzzing - check for HashMapOracle leaks
  * [ ] try again to use croaring, address build issues, remove HashMapOracle
* [ ] CI: windows failure: use translate-c to replace pre-translated src/c/roaring.zig

# References
* https://github.com/RoaringBitmap/RoaringFormatSpec
* https://github.com/RoaringBitmap/CRoaring
* https://github.com/awesomo4000/rawr
* https://github.com/lalinsky/roaring.zig
* https://codeberg.org/ziglang/zig/pulls/30823
  * https://github.com/archaistvolts/resizable-struct
