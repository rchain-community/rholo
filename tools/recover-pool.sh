#!/usr/bin/env bash
# recover-pool — repost the signed deploys a stuck proposer's pool holds (#564).
#
# Why this exists. On 2026-11-08 a validator's pool held the only pending deploys and its own replay
# refused every block it built; the chain could not advance, so the height-keyed deploy expiry could
# not fire and the pool could not drain. The recovery that worked was to route one deploy to a
# validator with an independent pool, let it advance the height, and wait for the stuck deploys to
# expire. This tool makes the first half an operation instead of an improvisation: read the source
# node's pool, reconstruct each signed deploy exactly, and repost it to a healthy validator.
#
# It does not repair the source node's replay. It moves the work to a validator that can propose it;
# the source node's own refusal remains the condition `rnode` must diagnose (the operator surface's
# `selfValidationRefusal`, now with `stateHashMatched` and the cost/trace breakdown).
#
# Usage:
#   tools/recover-pool.sh <source-api> [--ids id1,id2,...] [--all] [--apply <target-api>] [--wait]
#
#   <source-api>   base URL of the node whose pool is stuck, e.g. http://127.0.0.1:40403
#   --ids          repost only these deploy ids (the ids in `selfValidationRefusal.deployIds`);
#                  default is every pooled deploy
#   --all          explicit spelling of the default
#   --apply <url>  POST each reconstructed deploy to <target-api>/api/v1/deploy (default: print only)
#   --wait         after posting, poll the target's pool until every posted id is gone or 120 s pass
#
# Exit: 0 ok · 1 a request/field failed · 2 usage or missing tool.
set -euo pipefail

usage() { sed -n '2,30p' "$0"; }

command -v curl >/dev/null || { echo "recover-pool: curl is required" >&2; exit 2; }
command -v jq   >/dev/null || { echo "recover-pool: jq is required" >&2; exit 2; }

source_api=""
target_api=""
ids=""
wait=0
while (($#)); do
  case "$1" in
    --ids) ids="${2:-}"; shift 2 ;;
    --all) ids=""; shift ;;
    --apply) target_api="${2:-}"; shift 2 ;;
    --wait) wait=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "recover-pool: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) source_api="$1"; shift ;;
  esac
done
[[ -n "$source_api" ]] || { usage >&2; exit 2; }
source_api="${source_api%/}"

pool="$(curl -fsS "$source_api/api/v1/deploys")" || {
  echo "recover-pool: could not read $source_api/api/v1/deploys" >&2
  exit 1
}

if [[ -n "$ids" ]]; then
  filter="$(printf '%s' "$ids" | jq -R 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))')"
else
  filter='[]'
fi

# Reconstruct the DeployRequest the node's own deploy route accepts. Every field is required:
# `signature` is the pool's key, `sigAlgorithm` selects the verifier, `shardId` routes the deploy,
# and the attachments are part of the bytes the client signed. A missing one is a refusal, not a
# best-effort guess — a guessed deploy is a different signed deploy.
mapfile -t requests < <(
  printf '%s' "$pool" | jq -c --argjson ids "$filter" '
    .deploys
    | map(select(($ids | length) == 0 or (.deployId as $id | $ids | index($id)) != null))
    | map(
        if (.signature // "") == "" then error("deploy \(.deployId): no signature field")
        elif (.sigAlgorithm // "") == "" then error("deploy \(.deployId): no sigAlgorithm field")
        elif (.shardId // "") == "" then error("deploy \(.deployId): no shardId field")
        else {
          data: {
            attachments: (.attachments // []),
            term: .term,
            timestamp: .timestamp,
            phloPrice: .phloPrice,
            phloLimit: .phloLimit,
            validAfterBlockNumber: .validAfterBlockNumber,
            shardId: .shardId
          },
          deployer: .deployer,
          signature: .signature,
          sigAlgorithm: .sigAlgorithm
        } end
      )
    | .[]'
) || { echo "recover-pool: the pool response is missing a field a signed deploy needs" >&2; exit 1; }

if ((${#requests[@]} == 0)); then
  echo "recover-pool: no pooled deploy matches the selection; nothing to do"
  exit 0
fi

posted_ids=()
for req in "${requests[@]}"; do
  id="$(printf '%s' "$req" | jq -r '.signature')"
  if [[ -z "$target_api" ]]; then
    printf '%s\n' "$req"
    continue
  fi
  response="$(curl -fsS -X POST -H 'content-type: application/json' \
    --data "$req" "$target_api/api/v1/deploy")" || {
      echo "recover-pool: the target refused deploy $id" >&2
      exit 1
    }
  printf 'posted %s -> %s\n' "$id" "$(printf '%s' "$response" | jq -r '.deployId // .message // .' 2>/dev/null || printf '%s' "$response")"
  posted_ids+=("$id")
done

if ((wait)) && [[ -n "$target_api" ]] && ((${#posted_ids[@]} > 0)); then
  deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    still="$(curl -fsS "$target_api/api/v1/deploys" | jq --argjson ids "$(printf '%s\n' "${posted_ids[@]}" | jq -R . | jq -s .)" \
      '[.deploys[].deployId | select(. as $id | $ids | index($id))] | length')"
    ((still == 0)) && { echo "recover-pool: all posted deploys left the target pool"; exit 0; }
    sleep 5
  done
  echo "recover-pool: $still posted deploy(s) are still pooled after 120 s" >&2
  exit 1
fi

if [[ -n "$target_api" ]]; then
  echo "recover-pool: posted ${#posted_ids[@]} deploy(s) to $target_api"
else
  echo "recover-pool: printed ${#requests[@]} deploy(s); add --apply <target-api> to post" >&2
fi
