#!/bin/bash
# grpc-java's own interop client and server (io.grpc:grpc-interop-testing) against both Nim peers
# (blocking: interop.nim, chronos: ainterop.nim), in plaintext and TLS, in both directions.
# Needs a JDK (21 was used), Maven and network access to Maven Central for the first run.
#   tests/interop/java_interop.sh
# Beyond the official list it runs very_large_request (the Nim server is started with a 16 MiB
# limit on a message, the default is 4 MiB), rpc_soak and channel_soak (200 calls each).
# Environment: OUT (default /tmp/nimgrpc-java-interop), BASEPORT (default 10040), NIMGRPC_FLAGS.
# grpc-java's test server does not check expect_compressed and compresses a whole call or
# nothing, so the Nim client runs with --lenient-compression and --no-per-message-compression
# against it (see docs/interop.md); the Java client runs every case, probes included.
# TLS uses the test certificates from grpc-java itself (RSA, name foo.test.google.fr); mutual TLS
# has no switch in the Java peers and is not run here. Exit status 1 when a case fails.
set -u
cd "$(dirname "$0")/../.."
OUT=${OUT:-/tmp/nimgrpc-java-interop}
case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac   # Maven resolves a relative path against the pom
BASE=${BASEPORT:-10040}
JVERSION=1.85.1
mkdir -p "$OUT/lib" "$OUT/certs"
if [ ! -f "$OUT/lib/grpc-interop-testing-$JVERSION.jar" ]; then
  mvn -q -B -f tests/interop/javapeer/pom.xml dependency:copy-dependencies -DoutputDirectory="$OUT/lib" || exit 1
  [ -f "$OUT/lib/grpc-interop-testing-$JVERSION.jar" ] || { echo "Maven did not fetch the interop jars into $OUT/lib" >&2; exit 1; }
fi
CP="$OUT/lib/*"
# the test certificates are in grpc-testing's jar; the Nim peers expect ca.pem, server.pem, server.key
for n in ca.pem:ca.pem server1.pem:server.pem server1.key:server.key; do
  unzip -qjo "$OUT/lib/grpc-testing-$JVERSION.jar" "certs/${n%%:*}" -d "$OUT/certs.tmp" &&
    mv "$OUT/certs.tmp/${n%%:*}" "$OUT/certs/${n##*:}"
done
rm -rf "$OUT/certs.tmp"
SNI=foo.test.google.fr
CASES="empty_unary large_unary client_streaming server_streaming ping_pong empty_stream
  cancel_after_begin cancel_after_first_response timeout_on_sleeping_server
  status_code_and_message special_status_message unimplemented_method unimplemented_service
  custom_metadata client_compressed_unary server_compressed_unary client_compressed_streaming
  server_compressed_streaming very_large_request rpc_soak channel_soak"
nim c -d:release --hints:off --warnings:off ${NIMGRPC_FLAGS:-} -o:"$OUT/interop" tests/interop/interop.nim || exit 1
nim c -d:release --hints:off --warnings:off ${NIMGRPC_FLAGS:-} -o:"$OUT/ainterop" tests/interop/ainterop.nim || exit 1
FAILED=0
PIDS=
trap 'kill $PIDS 2>/dev/null' EXIT
port=$BASE
wait_port() { for _ in $(seq 100); do (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null && return 0; sleep 0.2; done; return 1; }
report() { # name, failed
  if [ "$2" -eq 0 ]; then echo "PASS  $1"; else echo "FAIL  $1 ($2 failed)"; FAILED=1; fi
}
for mode in plain tls; do
  for peer in interop ainterop; do
    # Java client -> Nim server
    port=$((port + 1))
    nimflag=; jflags=(--use_tls=false)
    if [ $mode = tls ]; then
      nimflag="--tls --certs=$OUT/certs"
      jflags=(--use_tls=true --use_test_ca=true --server_host_override=$SNI)
    fi
    "$OUT/$peer" server $port --max-message=16777216 $nimflag >"$OUT/$peer-server.log" 2>&1 &
    pid=$!; PIDS="$PIDS $pid"
    wait_port $port || { echo "FAIL  $peer server did not start ($mode)"; FAILED=1; continue; }
    bad=0
    for c in $CASES; do
      timeout 120 java -cp "$CP" io.grpc.testing.integration.TestServiceClient \
        --server_host=127.0.0.1 --server_port=$port "${jflags[@]}" --test_case=$c --soak_iterations=200 \
        >"$OUT/java-client-$c.log" 2>&1 || { echo "      $c failed, see $OUT/java-client-$c.log"; bad=$((bad + 1)); }
    done
    report "grpc-java client -> $peer server ($mode), $(echo $CASES | wc -w) cases" $bad
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    # Nim client -> Java server
    port=$((port + 1))
    jflags=(--use_tls=false); nimflag=
    if [ $mode = tls ]; then
      jflags=(--use_tls=true)
      nimflag="--tls --certs=$OUT/certs --server-name=$SNI"
    fi
    java -cp "$CP" io.grpc.testing.integration.TestServiceServer --port=$port "${jflags[@]}" \
      >"$OUT/java-server.log" 2>&1 &
    pid=$!; PIDS="$PIDS $pid"
    wait_port $port || { echo "FAIL  grpc-java server did not start ($mode)"; FAILED=1; continue; }
    res=$(timeout 300 "$OUT/$peer" client 127.0.0.1 $port $nimflag --lenient-compression --no-per-message-compression 2>&1)
    echo "$res" | grep -v '^PASS' | sed 's/^/      /'
    report "$peer client -> grpc-java server ($mode), $(echo "$res" | grep -c '^PASS') passed" "$(echo "$res" | grep -c '^FAIL')"
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
  done
done
exit $FAILED
