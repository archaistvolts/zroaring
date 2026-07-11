set datafile separator ","
set xdata time
# set timefmt "%Y-%m-%dT%H:%M:%S"
set timefmt "%Y-%m-%d"
# set format x "%m-%d\n%H:%M"
set format x "%Y-%m-%d"
# set terminal dumb noenhanced
set key noenhanced
set lmargin 10
set rmargin 5
# APPEND ONLY! Do not change list order.
allops = "clear run_optimize shrink_to_fit portable_serialize frozen_serialize minimum maximum add rank select contains add_many add_range_closed contains_range range_cardinality remove and or andnot lazy_or or_inplace and_inplace is_subset equals and_cardinality or_cardinality xor_cardinality andnot_cardinality jaccard_index or_many portable_deserialize statistics flip frozen_view"
