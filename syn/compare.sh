#!/usr/bin/env bash
# Synthesise the MAC at each pipeline depth and report the numbers that
# actually matter for the tradeoff: how much logic it costs, and how
# deep the worst combinational path is.
#
#   cells          : total standard cells after technology-independent
#                    mapping -- the area proxy
#   registers      : flip-flops inferred (rises with pipeline depth)
#   logic levels   : longest topological path through combinational
#                    logic, from Yosys 'ltp'. This is the timing proxy:
#                    fewer levels between registers means a shorter
#                    critical path and therefore a higher achievable
#                    clock frequency.
#
# A real sign-off flow would run STA against a liberty file for ns
# numbers; logic levels is the tool-independent stand-in.

set -u
cd "$(dirname "$0")"
RTL=../rtl
OUT=results
mkdir -p "$OUT"

printf "%-8s %10s %12s %14s\n" "DEPTH" "CELLS" "REGISTERS" "LOGIC_LEVELS"
printf "%-8s %10s %12s %14s\n" "-----" "-----" "---------" "------------"

for D in 0 1 2 3; do
  yosys -p "
    read_verilog -DPIPE_STAGES=$D $RTL/booth_pp_gen.v $RTL/csa.v $RTL/wallace_tree.v $RTL/mac_int8.v
    hierarchy -top mac_int8
    proc; opt; fsm; opt; techmap; opt
    flatten; opt -purge
    stat
    ltp -noff
  " > "$OUT/synth_p$D.log" 2>&1

  CELLS=$(grep -E "Number of cells:" "$OUT/synth_p$D.log" | tail -1 | awk '{print $4}' || true)
  FFS=$(sed -n '/Number of cells:/,$p' "$OUT/synth_p$D.log" \
        | grep -oE '\$_[A-Z]*DFF[A-Z0-9_]*_ +[0-9]+' \
        | awk '{s+=$NF} END {print s+0}' || true)
  LEVELS=$(grep -E "Longest topological path in mac_int8" "$OUT/synth_p$D.log" \
           | tail -1 | grep -oE "length=[0-9]+" | grep -oE "[0-9]+" || true)
  printf "%-8s %10s %12s %14s\n" "$D" "${CELLS:-?}" "${FFS:-0}" "${LEVELS:-?}"
done

echo
echo "Full logs in $OUT/"
