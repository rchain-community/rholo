# n564-self-replay-recovery-drill-20261113

**Evidence locality.** `local-devnet`

## Scope

The integrated-build rerun of the #568 self-replay recovery ladder (attestation recovery, reset
plus automatic post-catch-up resume, halt with the reset disabled plus the operator resume), driven
by the devnet-only `--self-replay-injection` instrument on a fresh three-validator devnet. It is the
recovery half of C357's operational arm, run on the same source as the natural-trigger arm
(`n564-natural-trigger-20261113`).

## Provenance

| | |
|---|---|
| gate | `U23-F-11` |
| source | `8cea0db043e2533adad6effa9df4da7d49efb50a` |
| binary | `sha256:b7ce2d60b90326f97f4763b76391dc9ad04540bbe1fae7ae6b75333876dd8e8c` |
| run | local three-validator Docker devnet, 2026-11-13T14:29Z — no actions URL; `raw/campaign.json` and `raw/readout.md` carry the per-arm readings |
| packaged | `2026-11-13T14:30:29+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

All three arms PASS on the integrated build (`8cea0db`, image
`sha256:b7ce2d60…`): arm 1 recovers by an attestation-only block and finality advances; arm 2 resets
to the finalised anchor, catches up and resumes **without an operator POST**; arm 3 halts with the
reset disabled, holds finality frozen for 20 seconds and resumes on the operator route. The
`raw/arm*/operator-*.json` snapshots carry the refused-body and reset-attempt evidence.

## What this does not establish

The injected refusal has the incident's *shape*, not its cause; RC-B's compatibility/operational
acceptance and the §6 lockstep decision remain open. Local Docker on one host,
`execution_proven:false`; this is an integrated-build rerun of the arms first recorded at
`d79651d9c`, not a candidate-binary or live result, and it authorizes no deployment.

## Reproduce

From the repository root, on the pinned source:

```sh
tools/devnet.sh build
tools/self-replay-drill.sh
```

The drill writes `target/self-replay-drill/` and exits 0 only when all three arms pass, 3 when an arm
staged nothing and 1 on an assertion failure. `python3 tools/evidence-pack.py verify --record <this
directory>` checks the hashes.
