# Reset deploy inventory: missing DAG body (C366)

## Result

**VERIFIED, scoped to the tested reset implementation.** The original inventory
enumerated surviving body-store keys, so a block present in the DAG but missing
from the body store was never visited. The corrected function enumerates DAG
candidate hashes and refuses incomplete metadata or a missing body above the
anchor before writing the reset marker or performing the destructive rewind.

The shared DAG snapshot is released after collecting the hashes. The candidate
set is fixed for this check; no claim about arbitrary concurrent DAG mutation is
made.

## Pinned Rust verification

- Tested source: `a2497f0ea1f3b68fe2045e2adf6f7868fdaef39d`.
- Fork-only workflow commit: `4e71ad53d8275dd66b8ba038ba7ef35b20f78401`.
- [Successful run](https://github.com/aixaria0/rchain-rust/actions/runs/43047546442/job/130615425007).
- Compiler: Rust **1.95.0**; official protoc **3.21.12**, downloaded from the
  upstream v21.12 release with its observed SHA-256 pinned in the workflow.
- Environment: Linux x86-64, two build jobs, two test threads, debug information
  disabled. These are recorded test settings, not a production performance claim.

The workflow checked production-source equivalence before execution. It then
replaced only `casper/src/engine/reset.rs` with the original file from
`f4feb1a83862b5b58e682b09ec4188ca59294df6` and ran the new real integration test.
The intended missing-body assertion failed: **0 passed, 1 failed**, exit 101.
A compile error would not satisfy the negative-control step. The candidate file
was restored and checked before the successful full workspace run.

| Check | Observed result |
|---|---|
| Original real reset implementation, missing-body regression | Expected assertion failure |
| Candidate `cargo test --locked --workspace --all-features` | Success; no failing executed test |
| Candidate reset integration binary | **11 passed**, including the new LMDB fixture |
| Pinned formatter | Success |
| Repository Clippy contract, all targets and features | Success |

[The verification receipt](pinned-verification-receipt.json),
[the real negative control](integration-negative-control.json), and
[the scoped summary and log hashes](verified-results.json) preserve the source
identity, settings and results. The full logs are in the linked run and its
artifact. Ignored tests are not claimed as executed.

## Merged-tree verification (2026-11-13)

The branch was merged with `dev` at `dfc2e1fea` (the #555 merge, containing #568,
#570, #569 and #571) at merge commit `d62f93b9c`, and the changed surface was
re-run on that tree. This is a merged-tree rerun of the same tests, not a second
independent verification; the original pinned receipts above are unchanged.

| Check | Observed result |
|---|---|
| `cargo test --locked -p rchain-casper --test reset` | **16 passed**, including the three C366 cases |
| `tools/emit-findings-register.sh --check` | ok — 401 rows: 0 todo, 6 in progress, 395 done |
| `tools/audit-status.sh --quiet` | `TODO 0`, all 89 T1 modules read |
| `cargo fmt --all -- --check` | success |
| CI-equivalent workspace Clippy (`-D warnings`, workflow debt list) | success |

The merge conflicted only in `spec/audit/passes.md` (this pass and the #570 RC-B
continuation); the resolution keeps both. No production code changed during the
merge beyond the merge itself.


## What the reset tests establish

- `a_self_replay_reset_refuses_a_dag_block_whose_body_is_missing`: the real reset
  entry point refuses without a reset marker or destructive rewind, preserving
  the DAG, anchor body and pending request.
- `a_self_replay_reset_returns_the_deploy_before_purging_its_only_block`: a
  complete inventory permits reset; the exact deploy request returns to the pool,
  its dropped-block index is removed, and the old body is purged.
- `a_disk_backed_reset_preserves_the_inventory_across_store_reopen`: the production
  LMDB manager and codecs preserve the refused reset state across normal store
  close/reopen. After an explicit fixture body repair, a successful reset's
  pooled deploy, purge and completion marker survive another close/reopen.

The evaluation runtime is the in-memory fixture. The LMDB test is not a node
process restart, power-loss test, cryptographic signature-validation test, or the
three-arm devnet drill.

## Earlier dependency probe

`probe.py` extracts the production function into a std-only Rust binary with
storage stubs. The original function failed the missing-body assertion (3 passed,
1 failed); the corrected function passed four cases. Its historical receipt is
`probe-receipt.json`. This smaller probe is not the full crate verification above.

## Upstream CI and remaining #564 work

The upstream workflow's protobuf installation failed resolving
`azure.archive.ubuntu.com`. The successful fork-only lane uses the checksum-pinned
official compiler release instead; it does not turn the upstream checks green.
No upstream workflow or live validator was changed.

C366 closes the incomplete-inventory defect at the tested function and LMDB
store-reopen level. #564 remains open for the three-arm devnet drill, failed
record-write behavior, automatic post-catch-up resume, and RC-B, the original
274-phlo discrepancy. The incident inputs were reported unavailable.

## Current process observation for RC-B

[The read-only operator snapshot](current-environment.json) was collected on
2026-11-11 at 14:34–14:35 UTC. All four observed services had the same binary
SHA-256 and no matching batch/scheduler environment overrides or explicit
effect-scheduler CLI flag. The basename rnode-0a1e0236 does not prove a source
revision. A's current process began after the incident, so the observation does
not establish its November 8 settings.

The [incident source cost comparison](https://github.com/rhovision-org/rholo/blob/0a1e02362a7c34e474e068ffd47469c8d4be707a/casper/src/runtime_replay.rs#L489)
is per processed deploy; the incident cost pair is not a measured block total.
No original trigger reproduction is claimed.

— Ω-WITNESS

## Recovery follow-on and RC-B verification

[The #568 follow-up record](../n564-568-followup-20261111/README.md) preserves the focused review,
failed-storage counterexample, sixteen-case combined reset result, original-source M15 probes and
read-only validator-A observation. It distinguishes proposed #568 behavior from the merged base
and leaves the historical 274-phlo trigger open.
