#!/bin/bash
# Render every prepared frame with the Flip Screen DIP off and on, two
# simulations at a time, then check each pair. Run from the repo root after
# compiling the work library (see tb_flip_frame.sv's header).
cd "$(dirname "$0")"
jobs_list=()
for d in run/*/; do d=${d%/}; for f in 0 1; do jobs_list+=("$d $f"); done; done
run_one() {
	vsim -c -quiet tb_flip_frame +dir=$1 +flip=$2 -do "run -all; quit -f" > "$1/vsim_flip$2.log" 2>&1
	grep -h "wrote\|FAIL\|Error" "$1/vsim_flip$2.log"
}
export -f run_one
printf '%s\n' "${jobs_list[@]}" | xargs -P 2 -L 1 bash -c 'run_one "$0" "$1"'
status=0
for d in run/*/; do python compare.py "${d%/}" || status=1; done
exit $status
