
script_dir = (ARG0 eq "") ? "" : ARG0[1:strlen(ARG0)-strlen(system("basename ".ARG0))]
set loadpath script_dir
load "bench-config.gp"
set title "ratio - zroaring ops/sec over croaring ops/sec"

#set origin 0.0, 0.15
#set size 1.0, 0.85
set key below
set key font ",8"
set key horizontal maxcolumns 5
set key spacing 0.8
set key samplen 1
unset xtics
set ytics 0, 0.5, 1
set yrange [0:1]

# Do not change the list order.  It may only be appended to
#allops = "clear run_optimize shrink_to_fit portable_serialize frozen_serialize minimum maximum add rank select contains add_many add_range_closed contains_range range_cardinality remove and or andnot lazy_or or_inplace and_inplace is_subset equals and_cardinality or_cardinality xor_cardinality andnot_cardinality jaccard_index or_many"
plot for [row in "ratio"] "bench-data.csv" using 1:(column(row)) with linespoints title row
