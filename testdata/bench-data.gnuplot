set datafile separator ","
set xdata time
set timefmt "%Y-%m-%dT%H:%M:%S"
set format x "%m-%d\n%H:%M"
# set terminal dumb noenhanced
set key noenhanced
set lmargin 10
set rmargin 5

set multiplot

set origin 0.0, 0.15
set size 1.0, 0.85
set key below
set key font ",8"
set key horizontal maxcolumns 5
set key spacing 0.8
set key samplen 1
unset xtics
set ytics 0, 1, 3

allops = "clear run_optimize shrink_to_fit portable_serialize frozen_serialize minimum maximum add rank select contains add_many add_range_closed contains_range range_cardinality remove and or andnot lazy_or or_inplace and_inplace is_subset equals and_cardinality or_cardinality xor_cardinality andnot_cardinality jaccard_index or_many"
plot for [op in allops] "testdata/bench-data.csv" using 1:(column(op."_ratio")) with linespoints title op


set origin 0.0, 0.0
set size 1.0, 0.15
unset xtics
set format x "%m-%d\n%H:%M"
# fix y-axis ticks for small plot
set yrange [0.1:1.0]    # Explicitly bound range based data
set ytics 0, 0.3, 1   # Slightly wider step (0.2) so text fits in the small space

# set key right top      # Move baseline legend inside to save vertical space
plot for [col in "ratio"] "testdata/bench-data.csv" using 1:(column(col)) with linespoints title col


unset multiplot
