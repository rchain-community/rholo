# C357 natural-trigger arm — local devnet, PASS

**Source:** `8cea0db0` (the dev head at the run; contains #568, #570, #567 and #572).
**Green image:** `rnode:local` `sha256:b7ce2d60b90326f97f4763b76391dc9ad04540bbe1fae7ae6b75333876dd8e8c`.
**Red image:** `rnode:n564-pre568` `sha256:7e1b5c5c4404a27228e12582971116b8517c7271d255da31eab13d2506e3dde2`
(`f4feb1a`, #566 — pre-#570).

## Workload

Four `get` requests to `@"replay-order:registry"` are deployed **before** the contract exists, so they
stay pending in the tuple space; the registry contract is then deployed in the next manually proposed
block. No injector is used. This is the synthetic pending-peek shape distilled from the recovered
BYOID registry (`casper/tests/replay_trace_order.rs`), not the incident's terms.

## Green — integrated build

| reading | value |
|---|---|
| inclusion block | `feaa1e6060eae190cfc1cf3d42dd8c1e89b8f2fb70bd64beabb904b191be9e6b` |
| pre-state | `9c42af870797d433ea6188235cee3228be73dbb70e50bc9bffce1c1efb9f294e` |
| post-state | `0baef9ef4c6be9a0221fe665ea95d9f173dc7e8f888e2cff776cad5b53e45ddd` |
| user deploy | recorded cost **13317**, `errored=false` |
| second node | holds the same block, identical deploy entry and post-state |
| finality | **finalized on both nodes**; no `failed its own replay` in the proposer log |

## Red control — pre-#570

The same natural sequence makes the self-built block #4 `0e8514f36e7ce58ac2c44f34b5cbdb3f4c25c8aa436394a8b21f84dd75384458`
fail its own replay:

```
kind=ReplayCostMismatch initial_cost=13317 replay_cost=11722 state_hash_matched=None
trace=recorded_comms=32 matched_data=48 filtered_data=200 leftover_comms=22
```

The green arm's recorded cost (13317) equals the red arm's refused play cost. #566's recovery then
broadcast an attestation-only block; the registry deploy stayed pooled and was not included.

## Limits

The original rejected block/trace bytes and the incident terms/state remain unrecovered; this is a
synthetic analogue, not an incident reproduction. Local Docker on one host, `execution_proven:false`;
it is not a consensus/compatibility verdict and not live acceptance. The integrated #568 recovery
arms are recorded separately in `n564-self-replay-recovery-drill-20261113`.
