# #564 — how the failure is represented, and under what conditions

**The question.** The incident's observable was a per-deploy `ReplayCostMismatch` (5576 vs 5302). The
root-cause question is not "which of the six missing terms was it?" — that instance is unavailable. It
is: **which conditions can make play and replay disagree, which of them can exist in this code, and
what does the code do with each?** Every condition is dispositioned R1 (make unrepresentable), R2
(detect and bound), R3 (reset/catch-up), or R4 (runbook), with a falsifier.

**The contract.** For the same pre-state, block and seed, play and replay must agree on the post-state
hash (`docs/src/formal/determinism.md`, S1–S6) and on the block's per-deploy accounting. The two
claims are **not the same claim**: the post-state hash is the RSpace checkpoint root; `ProcessedDeploy.
cost` is a block field that is not an RSpace leaf. The protocol checks both, but this code checks the
cost first and the state second — or not at all when the cost fails.

## 1. The condition inventory

`condition-inventory.tsv` is the data. The load-bearing rows:

| id | condition | representable today? | disposition |
|---|---|---|---|
| C01–C07 | pre-state, fringe, participation, block data, seeds, normalizer env, phlo budget | derived or copied; the replay derives them from the same block/DAG | R1/R2; state-hash tests |
| **C08** | cost table / charge arithmetic | yes; only the total is observed | **R2 — per-category census** |
| **C09/C10** | term bytes; execution mode | yes; `RelaxedValidated` and batch-without-verify record a cost the sequential replay may refuse | **R1 — canonical play cost** |
| **C11** | replay trace matching (RCHAIN-3505) | yes; an unused COMM is swallowed for a failed deploy, and a trace difference can surface as cost first | **R2 — trace census + shadow** |
| C12–C15 | native store, refund arithmetic, system deploys, dummy/probe | yes; the replay uses the recorded bytes/sidecar | R1/R2; state-hash + refund counters |
| **C16** | **cost-only vs state-hash ordering** | yes; the code refuses on cost and never compares the state | **R2 + protocol decision** |
| C17 | exclusion/retry state | yes; process-local, unbounded, no prune | R2 — bounded, pruned, durable |
| C18 | concurrent DAG advance | yes; caught as a pre-state divergence | R2 |

## 2. C16 — the centerpiece

**The code path.** `replay_deploy_eval` sets the replay budget, evaluates the deploy, then compares
`processed_deploy.cost.cost` with the replayed cost and returns `ReplayCostMismatch`
(`casper/src/runtime_replay.rs:489-497`). `replay_block` propagates the error; `validate_block_checkpoint`
records `recomputed = replay_result.as_ref().ok().cloned()` (`interpreter_util.rs:1140`), which is `None`;
`handle_errors` compares hashes only on `Ok` (`:127-142`), so the declared post-state is never compared.
`check_replay_data_with_fix` also never runs, because it is called after `replay_deploy_eval` returns
(`runtime_replay.rs:333`). The same order is in `0a1e02362`.

**Why a cost-only difference need not change the state.** On replay, the refund and the executor payment
are built from the **recorded** `ProcessedDeploy` — `refund_amount()` and `burned_amount()`
(`models/src/casper/protocol/casper_message.rs:700-726`), called at `runtime_replay.rs:414,433` — not
from the replayed evaluation cost. The evaluation cost is compared and then discarded; it is not an
RSpace state leaf. A replay that produces the same effects but a different evaluation cost therefore
uses the same refund/pay inputs as play, and its post-state can match. The code never computes that
hash, so it cannot tell a state-correct block from a state divergence.

**What would settle the incident.** The refused block body (its deploy logs and recorded costs) and
A's pre-state. Neither exists (see `incident/unavailable.tsv`). The incident is **not reconstructible by
construction**: `put_block` runs only after validation succeeds, so a refused self-built block is never
stored. The durable refused-block record is the fix that makes the next incident diagnosable.

**What we can test without the incident.** A record tamper (add 274 to `ProcessedDeploy.cost.cost`,
keep the term) shows the ordering: replay returns `ReplayCostMismatch` and never compares the state.
A test-only shadow replay that ignores the cost check (but still uses the record for the refund) shows
that the state hash can match; that is the mechanism, not the incident's state. The operator record
carries `stateHashMatched` so a future occurrence says which case it was.

**Disposition.** R2: compute and report the state verdict beside the cost verdict; keep the production
refusal (the Scala oracle refuses a cost mismatch). Whether a state-correct/cost-mismatched block
should be accepted is a protocol decision, not a local fix; see `cost-criticality.md`.

## 3. P0′ — the play modes that can record a non-canonical cost

- **`RelaxedValidated` play.** `validate_relaxed_block` accepts when the post-state hash, the COMM
  multisets and the Law 11 rig-replay agree; it does **not** compare per-deploy cost, and on acceptance
  it returns the **relaxed** `UserDeployRuntimeResult`s (`runtime_manager.rs:1944-2041`, `:2034-2039`).
  A relaxed run with the same state and logs but a different per-deploy cost is recorded, and a
  Sequential replay refuses it. **R1:** add per-deploy cost equality to `accepted`; the existing failure
  arm already returns the oracle results, so a cost difference falls back to the canonical run.
- **Batched play with `_VERIFY=0`.** The only `raw.deploy.cost == batched.deploy.cost` comparison is
  inside `if self.batch.verify` (`:1832-1838`). **R1:** always run the sequential oracle for the
  recorded cost, and fall back to its full results on any difference.
- **Replay is always Sequential** (`rholang/src/runtime.rs:563-571`). `dfs` is Sequential; `gate` is
  sequential-equivalent. The incident unit's environment is unmeasured, so the matrix tests all modes.

## 4. The stronger trace lead

The early return also masks the trace check. A replay that leaves an unused COMM, or executes fewer
COMM/refund steps, reports `ReplayCostMismatch` and never `UnusedCommEvent`. `check_replay_data_with_fix`
deliberately swallows an unused COMM for a failed deploy (RCHAIN-3505). For a state-neutral deploy (a
transfer plus a `Nil` probe, a failed continuation, a transient produce/consume), the trace/refund
accounting is the most plausible source of a small per-deploy delta. It is measured, not assumed:
matrix M04 (failed deploy with an unused COMM), M15 (transient produce/consume), and the trace census.

## 5. Hypotheses, verdicts, and what would refute them

| # | hypothesis | current verdict | refuting measurement |
|---|---|---|---|
| H1 | A non-canonical play mode records a cost the sequential replay refuses | **representable by construction**; effect on the incident unknown (unit env unmeasured) | a mode matrix with identical per-deploy costs across `dfs`/`gate`/`relaxed-validated`/batch; the R1 fix then makes it unrepresentable |
| H2 | A replay trace/refund reconstruction differs on a state-neutral deploy | **open; leading lead** | identical trace/category census on play and replay for M04/M15, and no `ReplayCostMismatch` |
| H3 | Default Sequential play/replay disagrees (native store, fringe, seed) | **open** | identical category census on `0a1e02362` for the 2-deploy shape with a matching state hash |
| H4 | The refused block was state-correct and refused on cost alone | **mechanism confirmed; incident unestablished** | the shadow replay's `stateHashMatched` on a future occurrence; the missing terms/state preclude it here |
| H5 | The unit environment decides which of H1–H3 is reachable | **unmeasured** | `systemctl show -p Environment,ExecStart rnode` from A |

## 6. Verdict rules

- A disagreeing matrix cell localizes the condition and drives the fix; the fix lands with the cell as
  its regression.
- No disagreeing cell means: the incident's condition is **not represented in the tested set**. The
  verdict names the missing terms/state and the next discriminating experiments. It is not a claim that
  the code is correct.
- A state-correct/cost-mismatched block being refused is not a code bug to fix locally: it is the
  protocol's rule, and the PR records the decision.

## 7. Status

The audit found the ordering (C16) and the two play-mode holes (C10). The ordering has a test and a
shadow; the play-mode holes are closed by construction. Law 93 states that a cost verdict is not a
state verdict. The trace/refund hypothesis (H2) is the leading explanation for the incident's shape and
is the next measurement; the matrix has not yet been run on `0a1e02362`, and the `dev` cells that have
run are reported in `matrix.tsv`. The 274's cause is not established; the pack says so.

The operational fallback is in place: the pool export now carries the signed fields a repost needs
(`signature`, `sigAlgorithm`, attachments, shard), and `tools/recover-pool.sh` reposts a selected set to
a healthy validator. The durable refusal record and the local fault halt remain owed (C359,
F-U22-08/09/10).
