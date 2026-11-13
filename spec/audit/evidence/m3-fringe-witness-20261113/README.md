# m3-fringe-witness-20261113

**Evidence locality.** `local-devnet`

## Scope

The M3-04/M3-06 correlation fields on the LFS fringe exchange: does a reset validator's request and
the bootstrap's response name the same peer key, anchor and fringe identity, and can a local
four-validator reset/join exercise them? The witness lines are present; the join arm's own
height-convergence check did not complete (see Result).

## Provenance

| | |
|---|---|
| gate | `M3-04-M3-06` |
| source | `214d78fd973c62041b58729a2f32cae4ab803a29` |
| binary | `sha256:9ac9e21d2d2713f805a6b7b43c088b9b220173abf425f718efcf534e996b2c8d` |
| run | local four-validator Docker devnet, 2026-11-13T15:11Z — no actions URL; `raw/readout.md` carries the lines and the arm result |
| packaged | `2026-11-13T15:22:18+00:00` |
| verdict | **FAIL** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

**Instrument PASS, join arm FAIL.** The reset validator logged
`LFS fringe request ... sent to peer af87a7f0… (anchor latest)` and
`LFS fringe reply admitted for peer af87a7f0… on attempt 1/10`; the bootstrap logged
`Received FinalizedFringeRequest from rnode://120e06f1…@n457join-validator-3` and
`Fringe response: 4 block(s) [29098f52… .. d7bfc66d…], state 87c62c…, requested anchor latest, 93
ancestry block(s) (#139)`. The reset node also logged `LFS state is successfully restored.` and left
`NodeSyncing`.

The arm failed because the reset node's height stayed at 15 against the pre-reset capture of 16 for
the 600 s window. Cause: a post-restore self-equivocation —
`Block #14 ef7d6965… faulted at dag insert (equivocation detected: sender produced two blocks with the
same sequence number); recorded for retry 1/8 … 5/8` — whose exponential retry schedule outlasts the
arm's window. That is a separate join/catch-up behaviour, not the log change; it is recorded here for
follow-up.

## What this does not establish

Local Docker on one host (`local-devnet`), `execution_proven:false`. This is **not** the off-host
M3-01 positive, not M3-00 acceptance, and not a candidate-binary result; no second host was used. The
post-restore self-equivocation retry stall is a separate blocker, not evidence about the witness
fields. The off-host positive and failover remain owed and Jim's envelope.

## Reproduce

From the repository root, with the image built at the pinned source:

```sh
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  tools/devnet.sh up --validators 4 --fresh
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  python3 tools/n457-mature-join-arm.py --min-height 16 --timeout 600 \
    --out target/m3-fringe-witness/run
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  tools/devnet.sh down -v
```

The arm exits non-zero when the reset node does not reach the captured height; the packed logs and
`raw/readout.md` are the capture. `python3 tools/evidence-pack.py verify --record <this directory>`
checks the hashes.
