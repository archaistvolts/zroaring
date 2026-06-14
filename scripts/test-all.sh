zig build
zig build test
zig build test -Dcpu=baseline
zig build test -Dllvm
zig build test -Dllvm -Dcpu=baseline
zig build test -Drun-slow-tests # -Doptimize=ReleaseSmall
