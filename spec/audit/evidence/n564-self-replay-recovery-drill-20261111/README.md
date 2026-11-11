# n564-self-replay-recovery-drill-20261111

**Evidence locality.** `local-devnet`

## Scope

A three-arm drill of the #564 recovery ladder on a fresh three-validator devnet, using the
devnet-only `--self-replay-injection` instrument. It answers: **is each rung reachable and bounded on
a live net** — attestation recovery, reset plus automatic post-catch-up resume, and halt plus the
operator resume — and does a recurrence at the same finalised anchor stop instead of resetting again.
The instrument refuses only the node's own blocks, with the incident's own `ReplayCostMismatch`
shape, and arms only once a finalised anchor exists.

## Provenance

| | |
|---|---|
| gate | `U23-C361-C364` |
| source | `d79651d9c9085ab255c5a1864e8fe0933e8b5ec1` |
| binary | `sha256:7e1b5c5c4404a27228e12582971116b8517c7271d255da31eab13d2506e3dde2` |
| run | local devnet, 2026-11-11T15:01Z — no actions URL; `raw/campaign.json` carries the source and image pins |
| packaged | `2026-11-11T15:05:22+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

All three arms PASS; `raw/campaign.json` is the aggregate and each `raw/armN-*/result` is the arm's
verdict.

| arm | flags | reading |
|---|---|---|
| 1 | `deploy:1` | the deploy-bearing block was refused; the attestation-only block over the same pre-state was broadcast; the latch stayed clear; finality advanced; no reset. Surface at recovery: `refusedBodyAvailable=true`, `refusedBodyLen=786`, `resetAttempted=false` (`raw/arm1-attestation/operator-at-recovery.json`). |
| 2 | `all:2` | both builds were refused; one reset to the finalised anchor completed (`rewound 9 block(s) above height 1`); catch-up passed the anchor; `automatic post-catch-up resume: frontier 5 passed the reset anchor at height 1`; the latch cleared **without any operator POST**; the marker was null; finality advanced. Surface at halt: `selfReplayFaultHalted=true`, `resetAttempted=true`, an anchor, body available (`raw/arm2-reset/operator-at-halt.json`). |
| 3 | `all:2 --no-self-replay-reset` | both builds were refused; the node halted and logged `propose halted: a self-replay fault is latched` on the next trigger; no reset marker existed; finality did not advance for 20 s; `POST /api/v1/autopropose/resume` cleared the latch and finality advanced. Surface at halt: the same evidence as arm 2 (`raw/arm3-halt/operator-at-halt.json`). |

The `:2` budget is spent by the two refusals, so the post-recovery build is clean: a PASS cannot
come from a fault that merely stopped firing. The recurrence line (`already reset once at the
finalised anchor`) is absent in arm 2 for the same reason; the one-reset bound has separate unit and
integration tests.

## What this does not establish

It is **not an incident reproduction**: validator A's store, the incident's terms and its refused
body are unavailable, so the injected failure has the incident's *shape*, not its cause. **RC-B (the
274-phlo trigger) remains open** and is not claimed here. It is local-devnet evidence
(`locality: local-devnet`), not an off-host claim. It witnesses three executions of the ladder; it
is not a universal safety theorem, and `execution_proven` is false by construction. The
attestation-recovery arm does not assert the refused-body surface after the first ordinary success,
because that success clears the in-process refusal cell by design; the surface assertions are taken
at the points the JSON files name.

## Reproduce

From the repository root, on the image pinned above:

```sh
tools/devnet.sh build            # rnode:local at source d79651d9c
tools/self-replay-drill.sh       # ~3–5 minutes; evidence under target/self-replay-drill/
```

Each arm tears the network down and starts a fresh three-validator devnet with its own
`DEVNET_EXTRA_FLAGS_devnet_validator_1`. The script exits 0 only when all three arms pass, 3 when an
arm staged nothing, and 1 on an assertion failure. The packed files are the run directory byte for
byte; `python3 tools/evidence-pack.py verify --record <this directory>` checks the hashes.
