#!/bin/sh
# grpc-go's health client against the health service of nimgrpc (Check, List, Watch).
# Needs Go (1.25 or later for grpc-go 1.84; GOTOOLCHAIN picks one) and the grpc-go module.
#   tests/interop/health_interop.sh
set -e
cd "$(dirname "$0")/../.."
PORT=${PORT:-10031}
OUT=${OUT:-/tmp/nimgrpc-health-interop}
mkdir -p "$OUT/go"
cp tests/interop/gohealth/main.go "$OUT/go/main.go"
cp tests/interop/gohealth/go.mod.example "$OUT/go/go.mod"
(cd "$OUT/go" && go mod tidy && go build -o "$OUT/gohealth" .)
nim c -d:release --hints:off --warnings:off $NIMGRPC_FLAGS -o:"$OUT/healthserver" tests/interop/healthserver.nim
"$OUT/healthserver" "$PORT" 1500 > "$OUT/server.log" &
SRV=$!
sleep 1
"$OUT/gohealth" -addr "127.0.0.1:$PORT"
wait $SRV
