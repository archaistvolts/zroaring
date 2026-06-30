
script_dir = (ARG0 eq "") ? "" : ARG0[1:strlen(ARG0)-strlen(system("basename ".ARG0))]
set loadpath script_dir
load "bench-config.gp"
set title "all ops combined - zroaring speed / croaring speed"

set key below
set key font ",8"
set key horizontal maxcolumns 5
set key spacing 0.8
set key samplen 1
set xtics rotate by -45
set xtics font ",7"
set ytics 0.5, 0.1, 1.1
set yrange [0.5:1.1]

plot for [row in "ratio"] "bench-data.csv" using 1:(column(row)) with linespoints title row
