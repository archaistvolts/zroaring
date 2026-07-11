set -xe

function buildAndTest() {
    zig build $opt
    zig build test $opt
    zig build test -Dcpu=baseline $opt
    zig build test -Dllvm $opt
    zig build test -Dllvm -Dcpu=baseline $opt
}

opt=""
buildAndTest

opt="-Dtarget=wasm32-wasi -fwasmtime"
buildAndTest

opt="-Dtarget=native-windows -fwine"
buildAndTest

opt="-Doptimize=ReleaseSmall"
buildAndTest

time zig build test -Drun-slow-tests -Doptimize=ReleaseSafe -Dtest-filter="allocation failures" # -Dfuzzprint -Dtrace
