#!/bin/sh
# grpc-go's reflection client against the reflection service of nimgrpc (v1 and v1alpha).
# Needs Go (1.25 or later for grpc-go 1.84; GOTOOLCHAIN picks one) and the grpc-go module.
#   tests/interop/reflection_interop.sh
set -e
cd "$(dirname "$0")/../.."
PORT=${PORT:-10032}
OUT=${OUT:-/tmp/nimgrpc-reflection-interop}
mkdir -p "$OUT/go"
cp tests/interop/goreflect/main.go "$OUT/go/main.go"
cp tests/interop/goreflect/go.mod.example "$OUT/go/go.mod"
(cd "$OUT/go" && go mod tidy && go build -o "$OUT/goreflect" .)
nim c -d:release --hints:off --warnings:off $NIMGRPC_FLAGS -o:"$OUT/reflectionserver" tests/interop/reflectionserver.nim
"$OUT/reflectionserver" "$PORT" 8 > "$OUT/server.log" &
SRV=$!
sleep 1
"$OUT/goreflect" -addr "127.0.0.1:$PORT"
kill $SRV 2>/dev/null || true
wait $SRV 2>/dev/null || true
