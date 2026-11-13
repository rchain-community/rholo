# #576 close-out: the supported recovery and the fail-closed guard

Two arms on one local four-validator devnet (2026-11-13, ~16:50Z).

**Tooling:** `b01674566edb6fc64d1149ff7f68e3342fa7d537`.
**Image:** `rnode:local` `sha256:855e3af79240f995ea901270d8c1b9644fdc921402694b05e985400e581e3e96`,
built at source `0f331d88` (the Rust workspace is unchanged by the later tooling-only commits).

## Arm 1 — the supported recovery (regression control)

`--supported-recovery`: passive staging (no key), catch-up, `devnet.sh activate`, convergence.

- passive catch-up **19.6 s**, activation to round **19** in **4.3 s**, anchor #14 held by the
  bootstrap, `sync: null`, 0 LFS failures;
- **0** equivocation refusals, **no** key halt, proposals at sequences **15, 16**.

## Arm 2 — the unsupported shape's guard

`--unsupported-shape`: reset with the key present from boot, which is the shape that forks.

- the node proposed at sequence **16**; its own pre-reset block #18 (sequence 16) was refused —
  **1** refusal, the collision;
- the halt is recorded and named:
  `this validator's key equivocated: block #18 f08c1b0b… (sequence 16) was refused because the DAG
  holds a different block by this key at that sequence, so another copy of this validator has
  signed twice`;
- a second proposal (sequence 17) was already building and completed 107 ms later — **in flight,
  not production continuing**;
- **no block more than 10 s after the halt** (`late_proposals_after_halt` empty), and the proposer
  answered the next trigger with `propose halted: this validator's key equivocated`.

The node signed at most the one offending block, stopped, and said so: the acceptance clause for
the unsupported shape — "refuses to propose with a named, operator-visible state".

## Reproduce

```sh
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  tools/devnet.sh up --validators 4 --fresh
# supported
python3 tools/n457-mature-join-arm.py --min-height 16 --timeout 900 \
  --supported-recovery --out target/n576-arms/supported
# guard (same network; validator 3 is reset again with its key)
python3 tools/n457-mature-join-arm.py --min-height 16 --timeout 600 \
  --unsupported-shape --out target/n576-arms/guarded
tools/devnet.sh down -v
```

## Bounds

`local-devnet`, one host, `execution_proven:false`. Not the off-host M3 positive, not M3-00
acceptance, not a candidate-binary result. The guard stops the node; it does not heal the fork — a
validator whose key equivocated rotates the key or withdraws its bond, and the operator resume
deliberately does not clear it.
