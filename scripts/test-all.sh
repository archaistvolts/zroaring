set -xe

opt=""
zig build $opt
zig build test $opt
zig build test -Dcpu=baseline $opt
zig build test -Dllvm $opt
zig build test -Dllvm -Dcpu=baseline $opt

opt="-Dtarget=wasm32-wasi -fwasmtime"
zig build $opt
zig build test $opt
zig build test -Dcpu=baseline $opt
zig build test -Dllvm $opt
zig build test -Dllvm -Dcpu=baseline $opt

opt="-Doptimize=ReleaseSmall"
zig build $opt
zig build test $opt
zig build test -Dcpu=baseline $opt
zig build test -Dllvm $opt
zig build test -Dllvm -Dcpu=baseline $opt

# zig build test -Drun-slow-tests -Doptimize=ReleaseSmall
zig build test -Drun-slow-tests -Doptimize=ReleaseSafe
