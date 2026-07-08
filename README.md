# About
A Roaring Bitmap with an API similar to [CRoaring](https://github.com/RoaringBitmap/CRoaring) with container data stored in simd sized blocks.

This repo is hosted on [codeberg](https://codeberg.org/archaistvolts/zroaring) and mirrored to [github](https://github.com/archaistvolts/zroaring).

# Documentation
[Documentation](https://archaistvolts.github.io/zroaring/) is hosted on github.

# Use
With zig version 0.16.0

### fetch package
```console
zig fetch --save git+https://codeberg.org/archaistvolts/zroaring
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
```console
zig build test
```
### Fuzz
#### With the build system:
Fuzz, verifying each `fuzz.Op` result against CRoaring.
```console
zig build test -Doptimize=ReleaseSafe --fuzz --webui=[::1]:40313 -j1 -Dfuzzprint
```

`-Dfuzzprint` prints zon reproductions which can be copied to [src/fuzz-crash-corpus.zon](src/fuzz-crash-corpus.zon).

#### With nix-shell and AFL++:

```console
nix-shell
./scripts/afl-fuzz.sh
```

#### Reproducing with an AFL crash/hang file
```console
zig build && zig-out/bin/afl-run afl/output/default/<path_to_crash_file>
```

# CRoaring API coverage
```console
date +%F; zig build run -- api-coverage
```
```console
2026-06-30

parsed command:
  api-coverage --filter API-COVERAGE-FILTER-NONE

symbols coverage:
  prefix                    found total %
---------------------------------------------
  roaring_bitmap_           59    91    64.8%
  ra_                       16    40    40.0%
  container_                11    18    61.1%
  run_container_            16    37    43.2%
  bitset_container_         21    49    42.9%
  array_container_          12    31    38.7%
  roaring_iterator_         0     1     0.0%
  roaring_uint32_iterator_  2     2     100.0%
---------------------------------------------
  total                     137   269   50.9%
---------------------------------------------
  filtered                  0     0     -nan%
```

Add `--filter`, a substring to search, if you want to see individual method coverage.

# Bench
Benchmark data is stored in `testdata/bench-data.csv`.

#### Run benchmark
```console
zig build bench -Doptimize=ReleaseFast # -- write_csv_row
```
`write_csv_row` appends a row to `testdata/bench-data.csv`.

#### Plot benchmarks
```console
gnuplot testdata/bench-by-op.gp -p
gnuplot testdata/bench-total.gp -p
```

# Contributing
Human contributions are very welcome.  Please open a pull request or issue on codeberg if you run into a TODO, FIXME or any problems while using this project.  There is a lot of work yet to be done here.

# Ideas / TODOs - contributions welcome
* [x] in memory layout - 3 allocations: array, bitset_blocks and run/array blocks.
  * [x] - switch to Container managed blocks to improve overall performance by around 7%.
* [x] validation: fix failing checkAllAllocationFailures test
* [x] checkAllAllocationFailures - why so slow? - added -Dskip-slow-tests
* [x] allocation failures test with crash corpus.
* [x] container: match croaring binop param ordering: src1, src2, dst
* [x] optimize: store blocks in a separtate allocation to reduce copying in realloc_array, shrink_to_fit, run_optimize, etc.
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
  * [x] add compaction to realloc_blocks shrink code path
* [x] AFL fuzzer
  * [x] use croaringOracle, address build issues, remove HashMapOracle
* [ ] CI: windows failure: use translate-c to replace pre-translated src/c/roaring.zig
  * [x] workaround until translate-c fixes (hopefully 0.17) - introduce src/c/roaring-subset.h with symbols copied from roaring.h which translate-c can handle.
* [ ] bench with reordered Array fields.  also bench without field alignments.

# References
* https://github.com/RoaringBitmap/RoaringFormatSpec
* https://github.com/RoaringBitmap/CRoaring
* https://github.com/awesomo4000/rawr
* https://github.com/lalinsky/roaring.zig
