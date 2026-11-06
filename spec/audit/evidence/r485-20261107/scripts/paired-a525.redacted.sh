# Public reproduction template. Original SHA is recorded in manifest.json.
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SIDE="$1"
case "$SIDE" in
  control)
    EXPECTED_BIN=91740c78dbb22bd0b589c8e77b8bee06a1601ee173f9f36abb586ab53cefbe4a
    ;;
  candidate)
    EXPECTED_BIN=442cba52fa9787c572bad74bcbbb3444525b24fa4446101d7242a1ae13b3b932
    ;;
  *)
    echo "Usage: $0 control|candidate" >&2
    exit 2
    ;;
esac

INPUT=/var/lib/rnode
COPY="/var/tmp/r485-a525-$SIDE-20261106"
EVIDENCE="/var/tmp/r485-a525-$SIDE-evidence-20261106"
BIN="/usr/local/bin/rnode-r485-a525-$SIDE"
HOST="$(printenv R485_REPLAY_HOST)"
R485_DENY_IP="$(printenv R485_DENY_IP)"
test -n "$HOST" && test -n "$R485_DENY_IP"
export R485_DENY_IP
EXPECTED_INPUT=a51a2b78551e184d9e4d9cc8c5e8a6ef0edeae78ea26dfe60bf0459a3f2183bd

store_hash() {
  (cd "$1" && find . -type f -name data.mdb -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}
test "$(id -u)" = 0
test "$(hostname)" = r485-replay-a-20261103
test -e /etc/replay-freeze
test "$(systemctl is-active rnode)" = inactive
test "$(systemctl is-active r485-isolate.service)" = active
test -f "$BIN" && test -x "$BIN"
test "$(sha256sum "$BIN" | cut -d' ' -f1)" = "$EXPECTED_BIN"
test "$(store_hash "$INPUT")" = "$EXPECTED_INPUT"
test ! -e "$COPY"
test ! -e "$EVIDENCE"

install -d -m 0700 -o rnode -g rnode "$COPY"
cp -a "$INPUT/." "$COPY/"
test "$(store_hash "$COPY")" = "$EXPECTED_INPUT"
install -d -m 0700 "$EVIDENCE"

set -a
source /etc/rnode/faucet.env
set +a
test -n "$FAUCET_KEY"

echo "ARM=$SIDE"
echo "INPUT_SHA=$EXPECTED_INPUT"
echo "BIN_SHA=$EXPECTED_BIN"
echo "START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "NETWORK_MODE=unshare_no_external_route"
echo "EVIDENCE=$EVIDENCE"

export BIN COPY EVIDENCE HOST FAUCET_KEY

set +e
timeout --signal=TERM --kill-after=12 235s unshare --net /bin/bash -c '
  set -Eeuo pipefail
  ip link set lo up
  ip addr add "$HOST"/32 dev lo
  test -z "$(ip route show)"
  if ip route get "$R485_DENY_IP" >/dev/null 2>&1; then
    echo "ERROR_EXTERNAL_ROUTE" >&2
    exit 91
  fi
  echo "NETWORK_NAMESPACE_ISOLATED=YES"
  runuser -u rnode -- "$BIN" --profile docker run -s \
    --dev-mode --propose-on-deploy --attest-on-new-blocks --no-upnp \
    --network-id testnet --shard-name testnet --parent-shard-id / \
    --host "$HOST" \
    --protocol-port 40400 --api-port-grpc-external 40401 \
    --api-port-grpc-internal 40402 --api-port-http 40403 \
    --discovery-port 40404 --api-port-admin-http 40405 \
    --data-dir "$COPY" --bonds-file "$COPY/genesis/bonds.txt" \
    --wallets-file "$COPY/genesis/wallets.txt" \
    --pos-multi-sig-public-keys 042d721140c51d83d87503d86fa85e0c835c1b80dcb086251b7c59da497c6ed508625a5c0624741278af944e74f701e4d0f5c2b447b561a1e52f164e895c24b15d \
    --pos-multi-sig-quorum 1 --epoch-length 10 --quarantine-length 10 \
    --bond-minimum 1 --bond-maximum 250 --number-of-active-validators 4 \
    --validator-private-key-path /etc/rnode/validator.key \
    --deployer-private-key "$FAUCET_KEY" >"$EVIDENCE/node.log" 2>&1 &
  node_pid=$!
  trap "kill -TERM $node_pid 2>/dev/null || true; wait $node_pid 2>/dev/null || true" EXIT
  ready=0
  for i in $(seq 1 30); do
    if ss -lnt | grep -q "127.0.0.1:40402"; then
      echo "GRPC_READY_POLL=$i"
      ready=1
      break
    fi
    if ! kill -0 "$node_pid" 2>/dev/null; then
      echo "NODE_EXITED_DURING_STARTUP"
      break
    fi
    sleep 2
  done
  if [ "$ready" -ne 1 ]; then
    echo "GRPC_NOT_READY"
    exit 30
  fi
  for i in 1 2 3 4; do
    echo "PROPOSE_ATTEMPT=$i UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set +e
    timeout 25s runuser -u rnode -- "$BIN" --grpc-host 127.0.0.1 --grpc-port 40402 propose >"$EVIDENCE/propose-$i.log" 2>&1
    code=$?
    set -e
    echo "PROPOSE_ATTEMPT=$i EXIT=$code"
    grep -m 1 -Ei "Failure:|Propose succeed:|Proposal failed:|success" "$EVIDENCE/propose-$i.log" || true
    if grep -Eqi "JustificationRegression|justification regressed" "$EVIDENCE/node.log" "$EVIDENCE/propose-$i.log"; then
      echo "ARM_OBSERVATION=JUSTIFICATION_REGRESSION"
      break
    fi
    if grep -Eqi "Propose succeed:|Propose success|ProposeSuccess" "$EVIDENCE/propose-$i.log"; then
      echo "ARM_OBSERVATION=PROPOSAL_SUCCESS"
      break
    fi
    if ! kill -0 "$node_pid" 2>/dev/null; then
      echo "NODE_DIED_AFTER_PROPOSE"
      break
    fi
    sleep 17
  done
  echo "OBSERVATION_DONE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
'
result=$?
set -e

echo "NS_RUN_EXIT=$result"
echo "ORIGINAL_POST_SHA=$(store_hash "$INPUT")"
echo "COPY_POST_SHA=$(store_hash "$COPY")"
if grep -Eqi "JustificationRegression|justification regressed" "$EVIDENCE"/node.log "$EVIDENCE"/propose-*.log 2>/dev/null; then
  echo "JUSTIFICATION_REGRESSION=YES"
else
  echo "JUSTIFICATION_REGRESSION=NO"
fi
if grep -Eqi "Propose succeed:|Propose success|ProposeSuccess" "$EVIDENCE"/propose-*.log 2>/dev/null; then
  echo "PROPOSAL_SUCCESS=YES"
else
  echo "PROPOSAL_SUCCESS=NO"
fi
test "$(store_hash "$INPUT")" = "$EXPECTED_INPUT"
test "$(systemctl is-active rnode)" = inactive
test "$(systemctl is-active r485-isolate.service)" = active
echo "PRISTINE_AND_SERVICE_UNCHANGED=YES"
echo "END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
