#!/bin/bash
# Soak test of the chronos server: memory per connection, and no growth under churn.
#
#   tools/soak.sh [--tls]
#
# Build tools/asyncload.nim with -d:release first (ASYNCLOAD=path, default
# /tmp/asyncload). Environment:
#   HOLD_CONNS     connections held open in phase 1          (default 1000)
#   BUDGET_KIB     allowed server RSS per held connection    (default 34 plain, 96 with TLS)
#   CHURN_WORKERS  concurrent dial/call/close loops          (default 20)
#   CHURN_SECONDS  length of phase 2                         (default 600)
#   GROWTH_KIB     allowed RSS growth between the second half-point and the end of phase 2 (default 8192)
#   FD_GROWTH      allowed growth of open descriptors        (default 20)
#   OUT            directory for the samples                 (default soak-out)
# Exit status 1 on a breach; the samples are in $OUT/*.csv.
set -u
MODE=""; [ "${1:-}" = "--tls" ] && MODE="tls"
BIN=${ASYNCLOAD:-/tmp/asyncload}
HOLD_CONNS=${HOLD_CONNS:-1000}
# Measured on 2026-11-19 (HOLD_CONNS 1000, a development machine and the CI runner alike):
# 28 KiB plain and 86 KiB with TLS; the budgets leave about 10 KiB of room.
if [ -n "$MODE" ]; then DEF_BUDGET=96; else DEF_BUDGET=34; fi
BUDGET_KIB=${BUDGET_KIB:-$DEF_BUDGET}
CHURN_WORKERS=${CHURN_WORKERS:-20}
CHURN_SECONDS=${CHURN_SECONDS:-600}
GROWTH_KIB=${GROWTH_KIB:-8192}
FD_GROWTH=${FD_GROWTH:-20}
OUT=${OUT:-soak-out}
PORT=${PORT:-10070}
mkdir -p "$OUT"
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)"

rss() { awk '/VmRSS/ {print $2}' /proc/$1/status; }
fds() { ls /proc/$1/fd | wc -l; }
fail=0

$BIN server $PORT $MODE > "$OUT/server.log" 2>&1 & SRV=$!
trap 'kill $SRV $CLI 2>/dev/null' EXIT
sleep 1
kill -0 $SRV 2>/dev/null || { echo "server did not start"; cat "$OUT/server.log"; exit 1; }
base=$(rss $SRV)
echo "idle server: $base KiB, $(fds $SRV) fds"

# Phase 1: HOLD_CONNS connections, each with a call open. RSS per connection.
$BIN hold $PORT $HOLD_CONNS $MODE > "$OUT/hold.log" 2>&1 & CLI=$!
for _ in $(seq 1 120); do grep -q "^open:" "$OUT/hold.log" 2>/dev/null && break; sleep 1; done
grep -q "^open:" "$OUT/hold.log" || { echo "client did not open $HOLD_CONNS connections"; cat "$OUT/hold.log"; exit 1; }
sleep 2
held=$(rss $SRV)
per=$(( (held - base) / HOLD_CONNS ))
echo "phase 1: $HOLD_CONNS connections held, RSS $held KiB, $per KiB per connection (budget $BUDGET_KIB)"
echo "$HOLD_CONNS,$base,$held,$per" > "$OUT/hold.csv"
[ "$per" -le "$BUDGET_KIB" ] || { echo "BREACH: $per KiB per connection is over the budget of $BUDGET_KIB"; fail=1; }
kill $CLI 2>/dev/null; wait $CLI 2>/dev/null
sleep 3

# Phase 2: churn. The server must reach a plateau: sample RSS and descriptors.
$BIN churn $PORT $CHURN_WORKERS $CHURN_SECONDS $MODE > "$OUT/churn.log" 2>&1 & CLI=$!
echo "second,rss_kib,fds" > "$OUT/churn.csv"
t0=$(date +%s); mid=""; 
while kill -0 $CLI 2>/dev/null; do
  now=$(( $(date +%s) - t0 ))
  echo "$now,$(rss $SRV),$(fds $SRV)" >> "$OUT/churn.csv"
  sleep 5
done
wait $CLI 2>/dev/null
cat "$OUT/churn.log"
sleep 3
end_rss=$(rss $SRV); end_fds=$(fds $SRV)
echo "$(( $(date +%s) - t0 )),$end_rss,$end_fds" >> "$OUT/churn.csv"

# Reference point: the sample nearest to half of the run (warm-up is over).
half=$(( CHURN_SECONDS / 2 ))
ref=$(awk -F, -v h=$half 'NR>1 {d=$1-h; if (d<0) d=-d; if (best==""||d<best) {best=d; r=$2; f=$3}} END {print r","f}' "$OUT/churn.csv")
ref_rss=${ref%,*}; ref_fds=${ref#*,}
grow=$(( end_rss - ref_rss )); fgrow=$(( end_fds - ref_fds ))
echo "phase 2: RSS $ref_rss -> $end_rss KiB (+$grow, allowed $GROWTH_KIB), fds $ref_fds -> $end_fds (+$fgrow, allowed $FD_GROWTH)"
[ "$grow" -le "$GROWTH_KIB" ] || { echo "BREACH: RSS grew by $grow KiB during churn"; fail=1; }
[ "$fgrow" -le "$FD_GROWTH" ] || { echo "BREACH: $fgrow descriptors leaked during churn"; fail=1; }
exit $fail
