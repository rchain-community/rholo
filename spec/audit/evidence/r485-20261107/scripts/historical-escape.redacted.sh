# Public reproduction template. Original SHA is recorded in manifest.json.
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
STORE=/var/tmp/r485-historical-escape-20261106
EVIDENCE=/var/tmp/r485-historical-escape-evidence-20261106
BIN=/usr/local/bin/rnode-a5259969
EXPECTED_STORE=a51a2b78551e184d9e4d9cc8c5e8a6ef0edeae78ea26dfe60bf0459a3f2183bd
EXPECTED_BIN=a5b9e9de4f3a75833da50aef67a845ddc350248ec3113040bc727dbcb9bdfa01
HOST="$(printenv R485_REPLAY_HOST)"
R485_DENY_IP="$(printenv R485_DENY_IP)"
test -n "$HOST" && test -n "$R485_DENY_IP"
export R485_DENY_IP

test "$(id -u)" -eq 0
test "$(hostname)" = r485-replay-a-20261103
test -e /etc/replay-freeze
test "$(systemctl is-active rnode)" = inactive
test "$(systemctl is-active r485-isolate.service)" = active
test -d "$STORE"
test ! -e "$EVIDENCE"
ACTUAL_BIN="$(sha256sum "$BIN" | cut -d' ' -f1)"
test "$ACTUAL_BIN" = "$EXPECTED_BIN"
store_hash() {
  ( cd "$1"; find . -type f -name data.mdb -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 )
}
test "$(store_hash /var/lib/rnode)" = "$EXPECTED_STORE"
test "$(store_hash "$STORE")" = "$EXPECTED_STORE"
install -d -m 0700 "$EVIDENCE"

# Read the local credential, without printing it.
set -a
source /etc/rnode/faucet.env
set +a
test -n "$FAUCET_KEY"

echo "HISTORICAL_INPUT=$EXPECTED_STORE"
echo "HISTORICAL_BINARY=$EXPECTED_BIN"
echo "ISOLATION=network_namespace_no_external_route"
echo "OUTPUT_DIR=$EVIDENCE"

export STORE EVIDENCE BIN HOST FAUCET_KEY
set +e
timeout --signal=TERM --kill-after=10 160s unshare --net /bin/bash -c '
  set -Eeuo pipefail
  ip link set lo up
  ip addr add "$HOST"/32 dev lo
  test -z "$(ip route show)"
  if ip route get "$R485_DENY_IP" >/dev/null 2>&1; then
    echo "UNEXPECTED_EXTERNAL_ROUTE" >&2
    exit 91
  fi
  echo "NAMESPACE_ISOLATION=PASS"
  runuser -u rnode -- "$BIN" --profile docker run -s \
    --dev-mode --propose-on-deploy --attest-on-new-blocks --no-upnp \
    --network-id testnet --shard-name testnet --parent-shard-id / \
    --host "$HOST" \
    --protocol-port 40400 --api-port-grpc-external 40401 \
    --api-port-grpc-internal 40402 --api-port-http 40403 \
    --discovery-port 40404 --api-port-admin-http 40405 \
    --data-dir "$STORE" --bonds-file "$STORE/genesis/bonds.txt" \
    --wallets-file "$STORE/genesis/wallets.txt" \
    --pos-multi-sig-public-keys 042d721140c51d83d87503d86fa85e0c835c1b80dcb086251b7c59da497c6ed508625a5c0624741278af944e74f701e4d0f5c2b447b561a1e52f164e895c24b15d \
    --pos-multi-sig-quorum 1 --epoch-length 10 --quarantine-length 10 \
    --bond-minimum 1 --bond-maximum 250 --number-of-active-validators 4 \
    --validator-private-key-path /etc/rnode/validator.key \
    --deployer-private-key "$FAUCET_KEY" >"$EVIDENCE/node.log" 2>&1 &
  node_pid=$!
  trap "kill -TERM $node_pid 2>/dev/null || true; wait $node_pid 2>/dev/null || true" EXIT
  ready=0
  for attempt in $(seq 1 24); do
    if [ "$attempt" -eq 8 ]; then echo SOCKET_SNAPSHOT; ss -lntp | head -25 || true; fi
    if ss -lnt | grep -q "127.0.0.1:40402"; then
      ready=1
      echo "HEALTH_READY_AFTER_POLLS=$attempt"
      break
    fi
    if ! kill -0 "$node_pid" 2>/dev/null; then
      echo "NODE_EXITED_DURING_STARTUP"
      break
    fi
    sleep 3
  done
  if [ "$ready" -eq 1 ] && kill -0 "$node_pid" 2>/dev/null; then
    for pass in 1 2 3; do
      echo "MANUAL_PROPOSE_ATTEMPT=$pass"
      date -u "+attempt_utc=%Y-%m-%dT%H:%M:%SZ"
      timeout 32s runuser -u rnode -- "$BIN" --grpc-host 127.0.0.1 --grpc-port 40402 propose >"$EVIDENCE/propose-$pass.log" 2>&1 || echo "ATTEMPT_${pass}_EXIT_NONZERO=$?"
      grep -m 1 -E "Failure:|Proposal failed:|Propose succeed:|JustificationRegression|justification regressed" "$EVIDENCE/propose-$pass.log" || true
      if grep -Eqi "JustificationRegression|justification regressed" "$EVIDENCE/node.log" "$EVIDENCE/propose-$pass.log"; then
        echo "HISTORICAL_REGRESSION_REPRODUCED_ON_ATTEMPT=$pass"
        break
      fi
      sleep 17
    done
  else
    echo "NODE_NOT_READY_TO_PROPOSE"
  fi
  echo "HISTORICAL_RUN_OBSERVATION_COMPLETE"
'
exit_code=$?
set -e
printf 'REPLAY_EXIT_CODE=%s\n' "$exit_code"
printf 'SOURCE_POST_DIGEST=%s\n' "$(store_hash /var/lib/rnode)"
printf 'COPY_POST_DIGEST=%s\n' "$(store_hash "$STORE")"
if grep -Eqi "JustificationRegression|justification regressed" "$EVIDENCE"/node.log "$EVIDENCE"/propose-*.log 2>/dev/null; then
  echo "HISTORICAL_REGRESSION_DETECTED=YES"
else
  echo "HISTORICAL_REGRESSION_DETECTED=NO"
fi
