# n576-key-equivocation-guard-20261113

**Evidence locality.** `local-devnet`

## Scope

#576's two acceptance clauses, on one local four-validator devnet: (1) the **supported** recovery —
passive staging with no key, catch-up, then activation — converges with no self-equivocation, as a
regression control; and (2) a validator in the **unsupported** key-present-from-boot shape, when its
own key equivocates, **refuses to propose with a named, operator-visible state** and does not keep
producing.

## Provenance

| | |
|---|---|
| gate | `n576-fail-closed-guard` |
| source | `b01674566edb6fc64d1149ff7f68e3342fa7d537` (the tooling and guard under test) |
| binary | `sha256:855e3af79240f995ea901270d8c1b9644fdc921402694b05e985400e581e3e96` — `rnode:local`, built at `0f331d88`; the Rust workspace is unchanged by the later tooling-only commits |
| run | local four-validator Docker devnet, 2026-11-13T16:50Z — no actions URL; `raw/readout.md` carries the lines and both `raw/*/mature-join.json` the records |
| packaged | `2026-11-13T16:53:37+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

**Supported arm (control).** Passive catch-up **19.6 s**, activation to round **19** in **4.3 s**,
anchor #14 held by the bootstrap, `sync: null`, 0 LFS failures, **0** equivocation refusals, no key
halt, proposals at sequences **15, 16`.

**Unsupported-shape arm (the guard).** The reset validator proposed at sequence **16**; its own
pre-reset block #18 (sequence 16) was refused — **1** refusal, the collision — and the halt was
recorded and logged:
`this validator's key equivocated: block #18 f08c1b0b… (sequence 16) was refused because the DAG
holds a different block by this key at that sequence, so another copy of this validator has signed
twice`. A second proposal (sequence 17) was already building and completed 107 ms later — in
flight, not production continuing. **No block completed more than 10 s after the halt**
(`late_proposals_after_halt` is empty), and the proposer answered the next trigger with
`propose halted: this validator's key equivocated`.

The guard's halt is derived from the durable verdict row and the refused body, so the start-up seed
reconstructs it: a restart does not resume a forked key. The operator resume does not clear it by
design — the key is rotated or the bond withdrawn.

## What this does not establish

`local-devnet`, one host, one run of each arm, `execution_proven:false`. Not the off-host M3
positive, not M3-00 acceptance and not a candidate-binary result. The guard stops the node; it does
not heal the fork, and it is not a substitute for the supported passive-staging procedure when an
operator has a choice. The benign branch of the arm (no offence, convergence) was not the shape this
run produced.

## Reproduce

From the repository root, with the image built at the pinned source and the tooling above:

```sh
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  tools/devnet.sh up --validators 4 --fresh
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  python3 tools/n457-mature-join-arm.py --min-height 16 --timeout 900 \
    --supported-recovery --out target/n576-arms/supported
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  python3 tools/n457-mature-join-arm.py --min-height 16 --timeout 600 \
    --unsupported-shape --out target/n576-arms/guarded
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  tools/devnet.sh down -v
```

The arm exits non-zero when the supported shape equivocates or proposes nothing, and when the
unsupported shape equivocates without the named halt or keeps producing past the settle window.
`python3 tools/evidence-pack.py verify --record <this directory>` checks the hashes.
