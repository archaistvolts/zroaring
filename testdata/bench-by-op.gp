# Parse out directory of currently running script -
# strip filename from end of script path
script_dir = (ARG0 eq "") ? "" : ARG0[1:strlen(ARG0)-strlen(system("basename ".ARG0))]
set loadpath script_dir
load "bench-config.gp"
set title "per op - zroaring speed / croaring speed"
set origin 0.0, 0.15
set size 1.0, 0.85
set key below
set key font ",8"
set key horizontal maxcolumns 5
set key spacing 0.8
set key samplen 1
unset xtics
set ytics 0, 0.5, 2
set yrange [0:2]

plot for [op in allops] "bench-data.csv" using 1:(column(op."_ratio")) with linespoints title op
