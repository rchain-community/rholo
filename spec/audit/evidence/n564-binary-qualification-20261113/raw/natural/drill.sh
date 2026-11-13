#!/usr/bin/env bash
#
# The C357 natural-trigger arm (#564, #570): a pending-peek block is built by a proposer with **no
# injector**, accepted by its own replay on the corrected build, and strictly replayed by a second
# node. A pre-#570 image is the red control: the same natural sequence makes the proposer refuse its
# own block with `ReplayCostMismatch`.
#
# The workload is the synthetic fixture distilled from the recovered BYOID registry shape
# (`casper/tests/replay_trace_order.rs`): four `get` requests are sent to the registry name before the
# contract exists, the requests stay pending, and the registry deploy then triggers the COMM-binding
# order ambiguity. This is the natural trigger's *shape*, not an incident reproduction: the original
# rejected block/trace bytes and the incident terms/state remain unrecovered.
#
# Evidence is local Docker (`local-devnet`, one host, execution_proven false). Pack it with
# `tools/evidence-pack.py` after review; a script run is tooling until the packed evidence is
# committed.
#
# Usage: tools/n564-natural-trigger-drill.sh [--green-image IMG] [--red-image IMG]
#          [--timeout SECONDS] [--keep] [--arms green,red]
#
set -uo pipefail

cd "$(dirname "$0")/.."

OUT="target/n564-natural-trigger"
GREEN_IMAGE="rnode:local"
RED_IMAGE="rnode:n564-pre568"
TIMEOUT=180
KEEP=false
ARMS="green,red"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --green-image) GREEN_IMAGE="${2:?}"; shift 2 ;;
    --red-image) RED_IMAGE="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --arms) ARMS="${2:?}"; shift 2 ;;
    --keep) KEEP=true; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

BOOTSTRAP=devnet-bootstrap
PEER=devnet-validator-1
B_HTTP=40403
B_ADMIN=40405
P_HTTP=41403

rm -rf "$OUT"
mkdir -p "$OUT"
: >"$OUT/run.log"

say() { printf '%s\n' "$*" | tee -a "$OUT/run.log"; }
fail_arm() { say "ARM FAILED: $*"; }

teardown() { tools/devnet.sh down -v >/dev/null 2>&1 || true; }
cleanup() {
  rm -f examples/.n564-*.rho
  if ! $KEEP; then teardown; fi
}
trap cleanup EXIT

logs() { docker logs "$1" 2>&1 || true; }
get() { curl -fsS --max-time 5 "http://localhost:$1$2" 2>/dev/null; }
jget() { get "$1" "$2" | jq -r "$3"; }
status_height() { jget "$1" "/api/status" '.latestBlockNumber'; }
tip_height() { local h; h="$(status_height "$1")"; [[ -n "$h" ]] && echo $((h - 1)); }
is_finalized() { get "$1" "/api/is-finalized/$2" | jq -r '.' 2>/dev/null; }
find_deploy() { get "$1" "/api/deploy/$2"; }
block_at() { get "$1" "/api/blocks/$2/$2" | jq '.[0]' 2>/dev/null; }

write_fixtures() {
  mkdir -p examples
  cat >examples/.n564-registry.rho <<'EOF'
new state in {
  state!({}) |
  contract @"replay-order:registry"(@action, @address, @payload, @resultName) = {
    match action {
      "publish" => {
        for (@store <- state) {
          state!(store.set(address, payload)) | @resultName!("OK")
        }
      }
      "get" => {
        for (@store <<- state) {
          match store.get(address) {
            Nil => { @resultName!("MISS") }
            value => { @resultName!(value) }
          }
        }
      }
    }
  }
}
EOF
  local i
  for i in 0 1 2 3; do
    cat >"examples/.n564-probe-$i.rho" <<EOF
@"replay-order:registry"!("get", "missing", "x", "reply-$i")
EOF
  done
}

deploy() { # file log
  tools/devnet.sh deploy "$1" >"$2" 2>&1
}

deploy_id_of() { # log
  sed -n 's/.*DeployId is: *//p' "$1" | head -1
}

wait_tip_above() { # port baseline
  local deadline=$((SECONDS + TIMEOUT)) height
  while ((SECONDS < deadline)); do
    height="$(tip_height "$1")"
    if [[ "$height" =~ ^-?[0-9]+$ ]] && ((height > $2)); then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_finalized() { # port hash seconds
  local deadline=$((SECONDS + ${3:-$TIMEOUT}))
  while ((SECONDS < deadline)); do
    if [[ "$(is_finalized "$1" "$2")" == "true" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_inclusion() { # port deploy-id; echoes the inclusion block hash
  local deadline=$((SECONDS + TIMEOUT)) json hash
  while ((SECONDS < deadline)); do
    json="$(find_deploy "$1" "$2")"
    if [[ -n "$json" && "$json" != "null" ]]; then
      hash="$(jq -r '.blockHash // .blockInfo.blockHash // empty' <<<"$json" 2>/dev/null)"
      if [[ -n "$hash" ]]; then
        echo "$hash"
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

capture() { # dir
  local dir=$1
  for node in "$BOOTSTRAP" "$PEER"; do
    logs "$node" >"$dir/$node.log" 2>&1 || true
  done
  get "$B_HTTP" "/api/status" >"$dir/status-bootstrap.json" 2>/dev/null || true
  get "$P_HTTP" "/api/status" >"$dir/status-peer.json" 2>/dev/null || true
  get "$B_HTTP" "/health" >"$dir/health-bootstrap.json" 2>/dev/null || true
  get "$P_HTTP" "/health" >"$dir/health-peer.json" 2>/dev/null || true
}

run_arm() { # name image expected dir
  local name=$1 image=$2 expected=$3 dir=$4
  mkdir -p "$dir"
  say "== $name ($image, expect $expected)"
  teardown
  RNODE_IMAGE=$image tools/devnet.sh up --validators 2 --fresh --no-autopropose --no-propose-on-deploy \
    >"$dir/up.log" 2>&1
  if (( $? != 0 )); then
    say "devnet up failed (see $dir/up.log)"
    tail -20 "$dir/up.log" | tee -a "$OUT/run.log"
    return 1
  fi

  local h0 h1 h2
  h0="$(tip_height "$B_HTTP")"
  if [[ -z "$h0" ]]; then fail_arm "no height from the bootstrap"; return 1; fi

  # 1. The four pending requests, in one block.
  local i
  for i in 0 1 2 3; do
    if ! deploy ".n564-probe-$i.rho" "$dir/deploy-probe-$i.log"; then
      fail_arm "probe $i deploy was not accepted"; return 1
    fi
  done
  tools/devnet.sh propose >"$dir/propose-probes.log" 2>&1
  if ! wait_tip_above "$B_HTTP" "$h0"; then
    fail_arm "the probe block was not proposed"; return 1
  fi
  h1="$(tip_height "$B_HTTP")"
  sleep 2

  # 2. The registry deploy — the natural trigger.
  if ! deploy ".n564-registry.rho" "$dir/deploy-registry.log"; then
    fail_arm "the registry deploy was not accepted"; return 1
  fi
  local deploy_id
  deploy_id="$(deploy_id_of "$dir/deploy-registry.log")"
  printf '%s\n' "$deploy_id" >"$dir/registry-deploy-id.txt"
  say "registry deploy id: ${deploy_id:-<not printed>}"
  tools/devnet.sh propose >"$dir/propose-registry.log" 2>&1
  sleep 15
  h2="$(tip_height "$B_HTTP")"

  local refused=false
  if logs "$BOOTSTRAP" | grep -q "failed its own replay"; then refused=true; fi

  if [[ "$expected" == "green" ]]; then
    if [[ "$refused" == "true" ]]; then
      fail_arm "the corrected proposer refused its own natural-trigger block"; capture "$dir"; return 1
    fi
    # **The registry deploy's inclusion block is the natural-trigger block.** The attestation tap
    # may add carrier blocks after it, so the tip is not a reliable identity.
    local inclusion_hash
    if [[ -z "$deploy_id" ]]; then
      fail_arm "the CLI did not print the registry deploy id"; capture "$dir"; return 1
    fi
    if ! inclusion_hash="$(wait_inclusion "$B_HTTP" "$deploy_id")"; then
      fail_arm "the registry deploy is not recorded in any block"; capture "$dir"; return 1
    fi
    printf '%s\n' "$inclusion_hash" >"$dir/inclusion-block.txt"
    say "inclusion block: $inclusion_hash"
    # The second node must hold the same block with the same replay accounting.
    local bootstrap_block peer_block b_deploys p_deploys
    bootstrap_block="$(get "$B_HTTP" "/api/v1/block/$inclusion_hash")"
    peer_block="$(get "$P_HTTP" "/api/v1/block/$inclusion_hash")"
    if [[ -z "$peer_block" ]]; then
      fail_arm "the second node does not hold block $inclusion_hash"; capture "$dir"; return 1
    fi
    printf '%s\n' "$bootstrap_block" | jq . >"$dir/block-bootstrap.json" 2>/dev/null || true
    printf '%s\n' "$peer_block" | jq . >"$dir/block-peer.json" 2>/dev/null || true
    b_deploys="$(jq -c '.deploys // empty' <<<"$bootstrap_block" 2>/dev/null)"
    p_deploys="$(jq -c '.deploys // empty' <<<"$peer_block" 2>/dev/null)"
    if [[ -n "$b_deploys" && "$b_deploys" != "$p_deploys" ]]; then
      fail_arm "the two nodes disagree on the per-deploy accounting"; capture "$dir"; return 1
    fi
    if [[ "$(jq -r '.postStateHash // .blockInfo.postStateHash // empty' <<<"$bootstrap_block")" != \
          "$(jq -r '.postStateHash // .blockInfo.postStateHash // empty' <<<"$peer_block")" ]]; then
      fail_arm "the two nodes disagree on the post-state"; capture "$dir"; return 1
    fi
    if ! wait_finalized "$B_HTTP" "$inclusion_hash"; then
      fail_arm "the bootstrap did not finalize $inclusion_hash"; capture "$dir"; return 1
    fi
    if ! wait_finalized "$P_HTTP" "$inclusion_hash"; then
      fail_arm "the second node did not finalize $inclusion_hash"; capture "$dir"; return 1
    fi
    say "green PASS: natural-trigger block $inclusion_hash accepted by both nodes and finalized"
  else
    if [[ "$refused" != "true" ]]; then
      fail_arm "the pre-#570 proposer did not refuse its own natural-trigger block"; capture "$dir"; return 1
    fi
    if ! logs "$BOOTSTRAP" | grep -q "ReplayCostMismatch"; then
      fail_arm "the refusal is not a ReplayCostMismatch"; capture "$dir"; return 1
    fi
    if [[ -n "$deploy_id" ]]; then
      local included
      included="$(find_deploy "$B_HTTP" "$deploy_id")"
      if [[ -n "$included" && "$included" != "null" ]]; then
        fail_arm "the pre-#570 build included the natural-trigger deploy"; capture "$dir"; return 1
      fi
    fi
    say "red PASS: the pre-#570 proposer refused its own natural-trigger block (ReplayCostMismatch)"
  fi

  capture "$dir"
  return 0
}

write_fixtures
say "natural-trigger drill: $(git rev-parse HEAD) at $(date -u +%FT%TZ)"
git rev-parse HEAD >"$OUT/source-sha.txt"
if image="$(docker image inspect "$GREEN_IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  printf '%s\n' "$image" >"$OUT/green-image.txt"
fi
if image="$(docker image inspect "$RED_IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  printf '%s\n' "$image" >"$OUT/red-image.txt"
fi

overall=0
case ",$ARMS," in
  *,green,*)
    if run_arm green "$GREEN_IMAGE" green "$OUT/green"; then
      echo PASS >"$OUT/green/result"
    else
      capture "$OUT/green"
      echo FAIL >"$OUT/green/result"
      overall=1
    fi
    ;;
esac
case ",$ARMS," in
  *,red,*)
    if run_arm red "$RED_IMAGE" red "$OUT/red"; then
      echo PASS >"$OUT/red/result"
    else
      capture "$OUT/red"
      echo FAIL >"$OUT/red/result"
      overall=1
    fi
    ;;
esac

python3 - "$OUT" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
arms = []
for name in ("green", "red"):
    directory = out / name
    result_file = directory / "result"
    if directory.is_dir():
        result = result_file.read_text().strip() if result_file.exists() else "FAIL"
        arms.append({"control": name, "result": result})
document = {
    "source_sha": (out / "source-sha.txt").read_text().strip() if (out / "source-sha.txt").exists() else "unknown",
    "green_image": (out / "green-image.txt").read_text().strip() if (out / "green-image.txt").exists() else "unknown",
    "red_image": (out / "red-image.txt").read_text().strip() if (out / "red-image.txt").exists() else "unknown",
    "aggregate": "PASS" if arms and all(a["result"] == "PASS" for a in arms) else "FAIL",
    "cycles": arms,
}
(out / "campaign.json").write_text(json.dumps(document, indent=2) + "\n")
print(f"campaign: {document['aggregate']}")
PY

if ((overall == 0)); then
  say "PASS: all selected natural-trigger arms"
  exit 0
fi
say "FAIL: at least one arm failed; see $OUT/run.log"
exit 1
