#! /bin/bash
set -e
targets="cr zr"
cwd=`pwd`
args=""
poop=~/Documents/Code/zig/poop/zig-out/bin/poop # TODO script param

for target in $targets; do
    zig build -Dbench-target=$target -Doptimize=ReleaseFast
    args="$args $cwd/zig-out/bin/bench-$target"
done
echo $args
$poop -d 2000 $args

# ops="clear run_optimize shrink_to_fit portable_serialize frozen_serialize minimum maximum add rank select contains add_many add_range_closed contains_range range_cardinality remove and or xor andnot lazy_or or_inplace and_inplace is_subset equals and_cardinality or_cardinality xor_cardinality andnot_cardinality jaccard_index or_many"
# for op in $ops; do
#     args=""
#     for target in $targets; do
#         zig build -Dbench-target=$target -Dbench-op=$op -Doptimize=ReleaseFast
#         args="$args $cwd/zig-out/bin/bench-$target-$op"
#     done
#     echo $args
#     $poop -d 2000 $args
# done
