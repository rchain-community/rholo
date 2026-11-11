#!/usr/bin/env bash
#
# The three-arm self-replay recovery drill (#564, U23 F-U23-11, register C361/C364).
#
# It drives the recovery state machine a live, three-validator devnet with the devnet-only
# `--self-replay-injection` instrument, so each rung of the ladder is observed rather than reasoned
# about:
#
#   arm 1  `deploy:1`               the deploy-bearing block is refused; the attestation-only block
#                                   over the same pre-state is broadcast and finality advances.
#   arm 2  `all:2`                  both builds are refused; the node resets to its last finalised
#                                   anchor, catches up, and the **automatic** post-catch-up resume
#                                   clears the halt with no operator POST.
#   arm 3  `all:2 --no-self-replay-reset`
#                                   the node halts instead of resetting; every trigger stops, the
#                                   surface says why, and `POST /api/v1/autopropose/resume` is the
#                                   one way out.
#
# The injection arms only once the node has a **finalised anchor** (the incident's precondition), and
# is spent after N refusals, which is what makes arms 2 and 3 deterministic: the build after the
# recovery is clean, so a PASS cannot come from a fault that merely stopped firing.
#
# **A run that stages nothing is not a pass.** Each arm must find its own `[SELF-REPLAY INJECTION]`
# line; otherwise the script exits 3, following `tools/reset-drill.sh`. Assertion failures exit 1.
# Evidence is written under `target/self-replay-drill/` (never `/tmp`), packed separately with
# `tools/evidence-pack.py` once the operator has reviewed it.
#
# Usage: tools/self-replay-drill.sh [--timeout SECONDS] [--keep]
#   --keep  leave the last network running for inspection (default: tear down)
#
set -uo pipefail

cd "$(dirname "$0")/.."

OUT="target/self-replay-drill"
TIMEOUT=240
KEEP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --keep) KEEP=true; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

BOOTSTRAP=devnet-bootstrap
SUBJECT=devnet-validator-1
PEER=devnet-validator-2
B_HTTP=40403
B_ADMIN=40405
S_HTTP=41403
S_ADMIN=41405
P_HTTP=42403

rm -rf "$OUT"
mkdir -p "$OUT"
: >"$OUT/run.log"

say() { printf '%s\n' "$*" | tee -a "$OUT/run.log"; }
fail_arm() { say "ARM FAILED: $*"; }

teardown() { tools/devnet.sh down -v >/dev/null 2>&1 || true; }
cleanup() { if ! $KEEP; then teardown; fi; }
trap cleanup EXIT

logs() { docker logs "$1" 2>&1 || true; }

wait_for_log() { # node pattern seconds
  local node=$1 pattern=$2 seconds=${3:-$TIMEOUT}
  local deadline=$((SECONDS + seconds))
  while ((SECONDS < deadline)); do
    if logs "$node" | grep -q -- "$pattern"; then return 0; fi
    sleep 1
  done
  return 1
}

wait_for() { # description command...
  local what=$1
  shift
  local deadline=$((SECONDS + TIMEOUT))
  while ((SECONDS < deadline)); do
    if "$@"; then return 0; fi
    sleep 1
  done
  say "timed out waiting for: $what"
  return 1
}

get() { curl -fsS --max-time 5 "http://localhost:$1$2" 2>/dev/null | jq -r "$3"; }
status_height() { get "$1" "/api/v1/status" '.latestBlockNumber'; }
finalized() { get "$1" "/health" '.finalizedHeight'; }
operator() { get "$1" "/api/v1/status/operator" "$2"; }

above() { # value baseline
  local value=$1 baseline=$2
  # A `null` baseline is "no height yet" (finality reports null before its first fence), and any
  # numeric reading is then an advance. Keeping this numeric-only avoids `set -u` treating the JSON
  # literal as an unbound shell variable in the arithmetic.
  [[ "$value" =~ ^-?[0-9]+$ ]] || return 1
  [[ "$baseline" =~ ^-?[0-9]+$ ]] || return 0
  ((value > baseline))
}

subject_advanced() { above "$(status_height "$S_HTTP")" "$1"; }
bootstrap_finality_advanced() { above "$(finalized "$B_HTTP")" "$1"; }
peer_finality_advanced() { above "$(finalized "$P_HTTP")" "$1"; }
subject_latch() { operator "$S_ADMIN" '.shards["/root"].proposer.selfReplayFaultHalted'; }
subject_latched() { [[ "$(subject_latch)" == "true" ]]; }
subject_clear() { [[ "$(subject_latch)" == "false" ]]; }

start_net() { # flags dir
  local flags=$1 dir=$2
  teardown
  DEVNET_EXTRA_FLAGS_devnet_validator_1="$flags" \
    tools/devnet.sh up --validators 3 --fresh >"$dir/up.log" 2>&1
  local status=$?
  if ((status != 0)); then
    say "devnet up failed (see $dir/up.log)"
    tail -20 "$dir/up.log" | tee -a "$OUT/run.log"
    return 1
  fi
}

capture() { # dir
  local dir=$1
  for node in "$BOOTSTRAP" "$SUBJECT" "$PEER"; do
    logs "$node" >"$dir/$node.log" 2>&1 || true
  done
  curl -fsS --max-time 5 "http://localhost:$S_ADMIN/api/v1/status/operator" \
    >"$dir/operator-subject.json" 2>/dev/null || true
  curl -fsS --max-time 5 "http://localhost:$S_HTTP/health" \
    >"$dir/health-subject.json" 2>/dev/null || true
  curl -fsS --max-time 5 "http://localhost:$B_HTTP/health" \
    >"$dir/health-bootstrap.json" 2>/dev/null || true
  curl -fsS --max-time 5 "http://localhost:$P_HTTP/health" \
    >"$dir/health-peer.json" 2>/dev/null || true
}

passed() { echo PASS >"$1/result"; }
failed() { echo FAIL >"$1/result"; }

arm1_attestation() {
  local dir="$OUT/arm1-attestation"
  mkdir -p "$dir"
  say "== arm 1: attestation recovery (--self-replay-injection deploy:1)"
  if ! start_net "--self-replay-injection deploy:1" "$dir"; then failed "$dir"; return 1; fi
  if ! wait_for_log "$SUBJECT" '\[SELF-REPLAY INJECTION\]' 60; then
    fail_arm "the injector never fired"; failed "$dir"; return 1
  fi
  if ! wait_for_log "$SUBJECT" "Recovered from the self-replay refusal" 60; then
    fail_arm "no attestation-only recovery line"; failed "$dir"; return 1
  fi
  if ! logs "$SUBJECT" | grep -q "replay-cost-mismatch"; then
    fail_arm "the injected refusal is not the incident's cost-mismatch shape"; failed "$dir"; return 1
  fi
  if logs "$SUBJECT" | grep -qE "reset complete: rewound to|automatic post-catch-up resume"; then
    fail_arm "arm 1 reset; the attestation arm must recover without one"; failed "$dir"; return 1
  fi
  if ! wait_for "the subject's latch to be clear" subject_clear; then
    fail_arm "the subject is halted after an attestation recovery"; failed "$dir"; return 1
  fi
  local h0 f0
  h0="$(status_height "$S_HTTP")"
  f0="$(finalized "$B_HTTP")"
  if ! wait_for "the subject to advance past $h0" subject_advanced "$h0"; then
    failed "$dir"; return 1
  fi
  if ! wait_for "finality to advance past $f0" bootstrap_finality_advanced "$f0"; then
    failed "$dir"; return 1
  fi
  capture "$dir"
  say "arm 1 PASS: recovered by attestation, finality advanced"
  passed "$dir"
}

arm2_reset() {
  local dir="$OUT/arm2-reset"
  mkdir -p "$dir"
  say "== arm 2: reset, catch-up and automatic resume (--self-replay-injection all:2)"
  if ! start_net "--self-replay-injection all:2" "$dir"; then failed "$dir"; return 1; fi
  if ! wait_for_log "$SUBJECT" '\[SELF-REPLAY INJECTION\]' 60; then
    fail_arm "the injector never fired"; failed "$dir"; return 1
  fi
  if ! wait_for_log "$SUBJECT" "the attestation fallback also failed its own replay" 60; then
    fail_arm "the node-level fault never happened"; failed "$dir"; return 1
  fi
  if ! wait_for_log "$SUBJECT" "reset complete: rewound to" 90; then
    fail_arm "no reset completed"; failed "$dir"; return 1
  fi
  if ! wait_for_log "$SUBJECT" "automatic post-catch-up resume" 120; then
    fail_arm "the automatic post-catch-up resume never fired"; failed "$dir"; return 1
  fi
  # The recovery is automatic: this script made no POST in this arm. The second-build budget must
  # be spent, so the post-resume build is clean — the recurrence arm did not run.
  if logs "$SUBJECT" | grep -q "already reset once at the finalised anchor"; then
    fail_arm "the injection was not spent; the run exercised the recurrence arm instead"; failed "$dir"; return 1
  fi
  if ! wait_for "the latch to clear without an operator POST" subject_clear; then
    fail_arm "the latch did not clear without an operator POST"; failed "$dir"; return 1
  fi
  local marker
  marker="$(operator "$S_ADMIN" '.resetMarker')"
  if [[ "$marker" != "null" ]]; then
    fail_arm "the reset marker was not cleared (marker=$marker)"; failed "$dir"; return 1
  fi
  local h0 f0
  h0="$(status_height "$S_HTTP")"
  f0="$(finalized "$B_HTTP")"
  if ! wait_for "the subject to advance past $h0" subject_advanced "$h0"; then
    failed "$dir"; return 1
  fi
  if ! wait_for "finality to advance past $f0" bootstrap_finality_advanced "$f0"; then
    failed "$dir"; return 1
  fi
  capture "$dir"
  say "arm 2 PASS: reset, catch-up and automatic resume, finality advanced"
  passed "$dir"
}

arm3_halt() {
  local dir="$OUT/arm3-halt"
  mkdir -p "$dir"
  say "== arm 3: halt with the reset disabled (--self-replay-injection all:2 --no-self-replay-reset)"
  if ! start_net "--self-replay-injection all:2 --no-self-replay-reset" "$dir"; then
    failed "$dir"; return 1
  fi
  if ! wait_for_log "$SUBJECT" '\[SELF-REPLAY INJECTION\]' 60; then
    fail_arm "the injector never fired"; failed "$dir"; return 1
  fi
  if ! wait_for_log "$SUBJECT" "the attestation fallback also failed its own replay" 60; then
    fail_arm "the node-level fault never happened"; failed "$dir"; return 1
  fi
  if ! wait_for "the subject's latch" subject_latched; then
    fail_arm "the latch never set"; failed "$dir"; return 1
  fi
  local marker
  marker="$(operator "$S_ADMIN" '.resetMarker')"
  if [[ "$marker" != "null" ]]; then
    fail_arm "the reset switch is off, so no marker may exist (marker=$marker)"; failed "$dir"; return 1
  fi
  # **Finality is the liveness witness, not the subject's height.** A halted validator still
  # receives peer blocks, so its DAG height advances; what cannot advance is finality, because with
  # three equal bonds the halted validator's third is required for the strict two-thirds quorum.
  local f0 f1
  f0="$(finalized "$B_HTTP")"
  sleep 20
  f1="$(finalized "$B_HTTP")"
  if [[ "$f1" =~ ^-?[0-9]+$ && "$f0" =~ ^-?[0-9]+$ ]] && ((f1 > f0)); then
    fail_arm "finality advanced while the subject was halted ($f0 -> $f1)"; failed "$dir"; return 1
  fi
  if ! subject_latched; then
    fail_arm "the latch did not stand across the observation window"; failed "$dir"; return 1
  fi
  # The operator's one explicit way out.
  if ! curl -fsS -X POST "http://localhost:$S_ADMIN/api/v1/autopropose/resume" -o /dev/null; then
    fail_arm "POST /api/v1/autopropose/resume failed"; failed "$dir"; return 1
  fi
  if ! wait_for "the latch to clear" subject_clear; then
    fail_arm "the resume did not clear the latch"; failed "$dir"; return 1
  fi
  if ! wait_for "finality to advance after the resume" bootstrap_finality_advanced "$f1"; then
    failed "$dir"; return 1
  fi
  capture "$dir"
  say "arm 3 PASS: halted, frozen, resumed by the operator route, finality advanced"
  passed "$dir"
}

say "self-replay drill: $(git rev-parse HEAD) at $(date -u +%FT%TZ)"
git rev-parse HEAD >"$OUT/source-sha.txt"
if image="$(docker image inspect rnode:local --format '{{.Id}}' 2>/dev/null)"; then
  printf '%s\n' "$image" >"$OUT/binary-sha256.txt"
else
  printf 'unknown\n' >"$OUT/binary-sha256.txt"
fi

overall=0
# A failed arm still leaves its evidence behind: capture before the next arm tears the network down.
arm1_attestation || {
  capture "$OUT/arm1-attestation"
  overall=1
}
arm2_reset || {
  capture "$OUT/arm2-reset"
  overall=1
}
arm3_halt || {
  capture "$OUT/arm3-halt"
  overall=1
}

python3 - "$OUT" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
arms = []
for directory in sorted(out.glob("arm*")):
    result_file = directory / "result"
    result = result_file.read_text().strip() if result_file.exists() else "FAIL"
    arms.append({"control": directory.name, "result": result})
aggregate = "PASS" if len(arms) == 3 and all(a["result"] == "PASS" for a in arms) else "FAIL"
document = {
    "source_sha": (out / "source-sha.txt").read_text().strip(),
    "binary_sha256": (out / "binary-sha256.txt").read_text().strip(),
    "aggregate": aggregate,
    "cycles": arms,
}
(out / "campaign.json").write_text(json.dumps(document, indent=2) + "\n")
print(f"campaign: {aggregate} ({len(arms)} arms)")
PY

if ((overall == 0)); then
  say "PASS: all three arms"
  say "evidence: $OUT (pack it with tools/evidence-pack.py after review)"
  exit 0
fi

say "FAIL: at least one arm failed; see $OUT/run.log and the per-arm logs"
exit 1
