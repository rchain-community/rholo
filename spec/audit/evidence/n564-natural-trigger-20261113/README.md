# n564-natural-trigger-20261113

**Evidence locality.** `local-devnet`

## Scope

The C357 natural-trigger arm on a local two-validator devnet: four `get` requests are left pending
against the registry name, the registry contract is then deployed in the next manually proposed
block, and the question is whether the corrected build's own replay accepts and broadcasts that
block (and a second node strictly replays it at the same accounting), while the pre-#570 build
refuses the same natural sequence. No injection flag is used.

## Provenance

| | |
|---|---|
| gate | `C357-natural-trigger` |
| source | `8cea0db043e2533adad6effa9df4da7d49efb50a` |
| binary | `sha256:b7ce2d60b90326f97f4763b76391dc9ad04540bbe1fae7ae6b75333876dd8e8c` |
| run | local two-validator Docker devnet, 2026-11-13T14:25Z — no actions URL; `raw/campaign.json` and `raw/readout.md` carry the pins and per-arm readings |
| packaged | `2026-11-13T14:30:26+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

Both arms PASS.

- **Green (integrated build):** inclusion block
  `feaa1e6060eae190cfc1cf3d42dd8c1e89b8f2fb70bd64beabb904b191be9e6b`, pre-state
  `9c42af87…`, post-state `0baef9ef…`, one user deploy at recorded cost **13317**, identical deploy
  entry and post-state on both nodes, finalized on both, no `failed its own replay` in the proposer
  log (`raw/green/block-*.json`, `raw/green/devnet-*.log`).
- **Red control (pre-#570, `f4feb1a`):** the same natural sequence makes self-built block #4
  `0e8514f3…` fail its own replay with `ReplayCostMismatch initial_cost=13317 replay_cost=11722`
  (trace census: recorded comms 32, matched data 48, filtered 200, leftover 22); #566's recovery
  then broadcast an attestation-only block, and the registry deploy stayed pooled / not included.
  The green arm's recorded cost equals the red arm's refused play cost
  (`raw/red/devnet-bootstrap.log`).

## What this does not establish

The workload is the synthetic pending-peek shape distilled from the recovered BYOID registry, not
the incident's terms or block; the original rejected `BlockMessage`/processed-trace bytes and the
incident state remain unrecovered. This is **not an incident reproduction**, not a
consensus/compatibility verdict, and not live acceptance: local Docker on one host,
`execution_proven:false`. The red image is #566 (`f4feb1a`, pre-#570, pre-#568), so its recovery
response is the attestation fallback only. The integrated #568 recovery arms are a separate packed
run (`n564-self-replay-recovery-drill-20261113`).

## Reproduce

From the repository root, with the two images built:

```sh
tools/devnet.sh build                                  # green image at 8cea0db
docker tag <pre-#570 image> rnode:n564-pre568          # red control, f4feb1a
tools/n564-natural-trigger-drill.sh \
  --green-image rnode:local --red-image rnode:n564-pre568
```

The drill writes `target/n564-natural-trigger/` and exits 1 on an assertion failure; the packed files
are that directory byte for byte. `python3 tools/evidence-pack.py verify --record <this directory>`
checks the hashes.
