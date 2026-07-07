#!/bin/bash

set -e

zig build -Dfuzz-exe # -Dcpu=baseline # --verbose

echo "NOTE: sudo required to appease AFL performance warnings"

echo core | sudo tee /proc/sys/kernel/core_pattern &&
  pushd /sys/devices/system/cpu &&
  echo performance | sudo tee cpu*/cpufreq/scaling_governor &&
  popd

#
# previous compile and launch
#
# afl-clang-lto -o fuzz zig-out/lib/libfuzz.a
# AFL_SKIP_CPUFREQ=true AFL_AUTORESUME=1 afl-fuzz -i afl/input -o afl/output -- ./fuzz

AFL_AUTORESUME=1 afl-fuzz -t20 -i afl/input -o afl/output -- zig-out/bin/fuzz-afl
