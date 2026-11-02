# Restart-under-load, N=4 — 2026-11-02

**Evidence locality.** `local-devnet`

## Scope

A disposable four-validator Docker devnet on the local host, from source
`d8b19154c4fdfd6a5321610f51935ae8d5fc24e4` and binary
`d8bcc09158115cdded6b5b692808743fb5bea60b9616d959efc42a6e9a99d611`. Four concurrent signed-deploy
streams stay active while one validator is SIGKILLed and restarted; the cycle is repeated for a
non-master validator and then the genesis master.

The question is issue #522's: after a process restart under load, do all four validators agree on
the same **finalized height and hash** at least three heights above the pre-kill baseline, resolve
every deploy submitted in the window, keep zero outstanding pipeline faults, orphan bodies and
proposal halt, avoid a `block receiver state full` line, and see the victim propose again — within
the 240-second window.

## Provenance

| | |
|---|---|
| gate | `n4-restart-under-load` |
| source | `d8b19154c4fdfd6a5321610f51935ae8d5fc24e4` |
| binary | `d8bcc09158115cdded6b5b692808743fb5bea60b9616d959efc42a6e9a99d611` |
| run | local disposable devnet; no Actions run URL |
| packaged | `2026-11-02T11:31:17+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

Both cycles passed. `raw/campaign.json` carries the arms; `raw/observations.jsonl` carries the
per-event record; `raw/result.json` is the verdict.

| cycle | victim | baseline finalized | final finalized (all four) | boot ids (before → after) | streams |
|---|---|---|---|---|---|
| 0 | validator 1 (non-master) | height 7 | height **33**, `f036a1ba1b96…` | `1-1793618550236` → `1-1793618561656` | 50 each |
| 1 | validator 0 (genesis master) | height 33 | height **48**, `bb966245aad8…` | `1-1793618550234` → `1-1793618596558` | 50 each |

For both cycles every validator reported the same finalized `(height, hash)`; every submitted deploy
resolved `ProcessedWithSuccess` on every validator; no finalized height regressed and no fixed height
changed hash; the victim returned with a **new `bootId`** (the process identity, not merely the
container) and proposed again; and no node's log contained `block receiver state full`. The harness
raises on any nonzero `pipelineFaultsOutstanding`, `orphanBodies`, or non-false `proposalHalted`, so
the pass includes those gates.

`blockPipeline` was read on every node after each cycle: `capacity` was 1024 everywhere, `pending`
stayed at 0–1, and the high-water `sampledPeak` was 1–5. The receiver was nowhere near the cap.

## What this does not establish

- It is a **finite devnet witness**, not a universal safety theorem, and not a live-network or
  release-readiness claim.
- The receiver never approached the 1024 cap (`sampledPeak` ≤ 5), so this run does **not** exercise
  saturation, a capacity refusal, or a dropped-body re-offer at the live queue. Those are the
  component fixture's subject, not this arm's.
- It does not exercise a partition, a stale-store joiner, or a second concurrent campaign.
- It speaks for `d8b19154` and binary `d8bcc091` only; a later `dev` needs its own run.
- It does not prove the run happened or that the reading is sound; that judgement remains the
  operator's (`execution_proven: false`).

## Reproduce

```sh
DEVNET_PREFIX=restartload DEVNET_NETWORK=restartload \
DEVNET_GRPC_BASE=42402 DEVNET_HTTP_BASE=42403 DEVNET_ADMIN_BASE=42405 \
DEVNET_NODE_MEMORY=4g DEVNET_THREAD_POOL_SIZE=2 \
  tools/devnet.sh up --validators 4 --fresh

DEVNET_PREFIX=restartload DEVNET_NETWORK=restartload \
DEVNET_HTTP_BASE=42403 DEVNET_ADMIN_BASE=42405 \
  python3 tests/consensus-restart-under-load.py --validators 4 --cycles 2 \
    --out target/restart-under-load-20261102

DEVNET_PREFIX=restartload DEVNET_NETWORK=restartload tools/devnet.sh down -v
```

The node memory ceiling matters: a 2 GiB container fails the restart's resource preflight at a
populated store and never returns a `bootId`; 4 GiB is the floor this store needed.
