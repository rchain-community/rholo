# Reset deploy inventory: missing DAG body (C366)

## Finding and scope

At `f4feb1a83862b5b58e682b09ec4188ca59294df6`, `return_unfinalised_deploys`
enumerated `BlockStore.keys()`. A block present in the DAG but absent from the body
store was never visited. The function could return `Ok(0)`, allowing the reset
to rewind metadata without establishing which deploys that block carried.

The correction enumerates the DAG snapshot instead. Missing metadata or a missing
body above the anchor refuses before the reset marker and destructive rewind.
Bodies outside the DAG remain outside this inventory.

This is a reset preflight defect found during #564 follow-up. It does not explain
the incident's 274-phlo discrepancy and does not claim that the incident involved
a missing body.

## Executed dependency probe

`probe.py` extracts the production function text into a std-only Rust test binary
with in-memory storage stubs. The original function failed the missing-body
assertion (3 passed, 1 failed); the corrected function passed all four cases.
The positive controls cover a complete empty inventory, an orphan body, and
returning a known unfinalised deploy without duplication. See `probe-receipt.json`.

This is a source-extracted algorithm probe, not a Casper crate test or a devnet
measurement. The stubs do not verify signatures, expiry, replay, real storage,
the reset lifecycle, or network finality.

From the repository root:

```sh
tmp=$(mktemp -d)
git show f4feb1a83862b5b58e682b09ec4188ca59294df6:casper/src/engine/reset.rs > "$tmp/original.rs"
python3 spec/audit/evidence/n564-reset-inventory/probe.py "$tmp/original.rs" "$tmp/original-probe.rs"
rustc --edition=2021 --test "$tmp/original-probe.rs" -o "$tmp/original-test"
# Expected nonzero: the missing-body assertion fails.
"$tmp/original-test" --nocapture
python3 spec/audit/evidence/n564-reset-inventory/probe.py casper/src/engine/reset.rs "$tmp/fixed-probe.rs"
rustc --edition=2021 --test "$tmp/fixed-probe.rs" -o "$tmp/fixed-test"
"$tmp/fixed-test" --nocapture
```

## Tests against the real reset entry point

`casper/tests/reset.rs` adds:

- `a_self_replay_reset_refuses_a_dag_block_whose_body_is_missing`: refusal leaves the DAG,
  anchor body and pending request intact, and writes no reset marker.
- `a_self_replay_reset_returns_the_deploy_before_purging_its_only_block`: a complete
  inventory permits reset; the exact deploy request returns to the pool, the
  dropped block's deploy index is removed, and its body is purged.

Run `cargo test --locked -p rchain-casper --test reset` with the pinned project toolchain.
At this checkpoint these full crate tests await CI; the probe receipt is not their result.

## Remaining #564 work

The three-arm devnet drill, automatic post-catch-up resume, incident-time
environment evidence, and the exact 274-phlo trigger are not closed by this change.
The original incident terms and refused block were reported unavailable.
The reset's successful-store semantics do not establish durability when a record
write fails; that remains a separate failure-injection question under C365.

— Ω-WITNESS

## Current process observation for RC-B

[The operator snapshot](current-environment.json) was collected read-only on 2026-11-11
at 14:34-14:35 UTC. All four observed processes had the same binary SHA-256, and
no matching batch/scheduler environment variables or explicit effect-scheduler CLI
flag were observed. The binary basename was rnode-0a1e0236; a basename is not proof
of its source revision. A's current process began after the incident, at
2026-11-10 13:52:18 UTC, so these observations do not establish A's November 8
settings. No service was restarted or reconfigured.

The named source revision makes cross-deploy batching opt-in and verification
default-on. The cost comparison in
[the incident source](https://github.com/rhovision-org/rholo/blob/0a1e02362a7c34e474e068ffd47469c8d4be707a/casper/src/runtime_replay.rs#L489)
is per processed deploy; the incident cost pair should not be promoted into a
block-total measurement. RC-B remains open.

## LMDB store-reopen fixture (execution pending)

The integration test
`a_disk_backed_reset_preserves_the_inventory_across_store_reopen` uses the production
LMDB manager and codecs. It removes a body, calls the real reset entry point,
and closes/reopens the disk stores to inspect the unchanged DAG and absent
marker. After an explicit fixture body repair, it resets and reopens again to
check the exact pooled deploy, removed index/body, and completion marker.
The evaluation runtime remains the in-memory test fixture. This is not a full
node restart, a power-loss test, an authentication test, or the three-arm devnet
drill. The test has been added and awaits execution on the pinned compiler.
