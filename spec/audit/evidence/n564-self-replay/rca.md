# #564 — how the failure is represented, and under what conditions

**Current finding, 2026-11-11.** The continuation recovered authenticated BYOID deploys and
complete historical Merkle states. Sequential execution on `0a1e02362` now reproduces the exact
per-deploy **5576 versus 5302** refusal and both original declared post-state hashes. Changing only
the COMM-binding iteration order makes strict replay succeed at those original costs and roots.
See §9 and scoped cells RCB-R25–RCB-R28. The original serialized rejected blocks/traces remain
unrecovered; this is a regenerated trace, not a recovered byte-for-byte block.

**Original scope.** While the inputs were unavailable, this audit investigated which conditions can
make play and replay disagree and what the code does with each. The inventory below retains that
analysis with R1 (unrepresentable), R2 (detect/bound), R3 (reset/catch-up) and R4 (runbook) dispositions.
Historical analogue results are not silently promoted to incident evidence.

**The contract.** For the same pre-state, block and seed, play and replay must agree on the post-state
hash (`docs/src/formal/determinism.md`, S1–S6) and on the block's per-deploy accounting. The two
claims are **not the same claim**: the post-state hash is the RSpace checkpoint root; `ProcessedDeploy.
cost` is a block field that is not an RSpace leaf. The protocol checks both, but this code checks the
cost first and the state second — or not at all when the cost fails.

**Correction, 2026-11-11 — this document studies the trigger, not the incident's cause.** The
`ReplayCostMismatch` is **RC-B**: why the block was refused. The incident is the 45-hour freeze, and
its cause is **RC-A**: the node had no safe recovery state under that fault — no transition changed
the input, produced an attestation, reset to a finalised anchor, or halted every trigger, so the only
modelled response was to rebuild the same deterministic block and never broadcast. RC-A is
established by the code paths in `recovery-hazop.md` §1 and the issue timeline. RC-B was open at that initial audit; §9 records the subsequent exact reconstruction.
The two are layered: RC-B is the stress condition; RC-A is the reason it became a 45-hour chain halt.
The earlier sentence, "the cause of the 274 is not established", described RC-B at that stage,
not the already established RC-A recovery failure.

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

**The availability boundary changed.** `incident/unavailable.tsv` records the earlier search.
It was too broad to infer that the instance was not reconstructible by construction: `put_block`
running after validation explains the absent rejected body, not the availability of expired deploy
bytes or content-addressed state. Five signed protobufs survived in old pool pages; a sixth was
reconstructed and authenticated by its original signature. All required Merkle roots are complete.
The archived processed trace is still absent. Natural trace regeneration now yields the exact cost
mismatch and original declared state; an order-only intervention removes the mismatch. Future durable
refused-body capture remains necessary for direct archival diagnosis.

**The separate C16 policy control.** A record tamper (add 274 to `ProcessedDeploy.cost.cost`,
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
deliberately swallows an unused COMM for a failed deploy (RCHAIN-3505). The initial transfer/Nil, failed-continuation and transient-COMM analogues localized the failure
class but did not establish the274 instance. A-M21 confirms a trace-to-cost mechanism without
editing the recorded cost. RCB-R25–RCB-R27 establish the recovered instance and binding-order trigger
without deleting any event. M04 is a failed-COMM control; its unused-COMM-specific condition is not
established by the retained control output.

## 5. Hypotheses, verdicts, and what would refute them

| # | hypothesis | current verdict | refuting measurement |
|---|---|---|---|
| H1 | A non-canonical play mode records a cost the sequential replay refuses | **representable by construction**; effect on the incident unknown (unit env unmeasured) | a mode matrix with identical per-deploy costs across `dfs`/`gate`/`relaxed-validated`/batch; the R1 fix then makes it unrepresentable |
| H2 | Replay reconstruction selects COMM candidates in the wrong order | **mechanism confirmed by A-M21; historical instance reproduced by RCB-R25–R27** | order-only correction fails to preserve original cost/post-state or strict controls |
| H3 | Default Sequential execution disagrees | **reproduced on recovered states; C11 candidate order is sufficient** | same historical inputs do not reproduce5576/5302, or another source change is required to restore strict replay |
| H4 | The uncorrected failed replay would have matched the declared state | **still unestablished**; old replay returns before a state verdict; corrected replay matches the declared root | a full uncorrected shadow-state verdict; corrected replay does not establish the uncorrected replay state |
| H5 | The incident process mode is independently attested | **not established**; later observations support defaults but do not prove November8 settings | a contemporaneous environment record; source/state reproduction here uses Sequential |

## 6. Verdict rules

- A disagreeing matrix cell localizes the condition and drives the fix; the fix lands with the cell as
  its regression.
- No disagreeing cell means: the incident's condition is **not represented in the tested set**. The
  verdict names the missing terms/state and the next discriminating experiments. It is not a claim that
  the code is correct.
- A state-correct/cost-mismatched block being refused is not a code bug to fix locally: it is the
  protocol's rule, and the PR records the decision.

## 7. Initial incident-source analogue results (before artifact recovery)

Run on `0a1e02362` (`incident-binary/n564_matrix.rs`, results in `matrix.tsv`):

- A plain `revVault!("transfer", ..., 30000000, ...)` deploy costs **984–986**; a `Nil` probe costs
  **3**; six same-key transfers cost **5910** in total. The incident's per-deploy **5576** is therefore
  **not** the plain-transfer shape — it is roughly 5.6× a transfer. The six missing terms are
  load-bearing, not interchangeable with an analogous fixture.
- A failed deploy with a COMM event costs **599** and replays with a matching state; an unconsumed
  result channel costs **739** and replays with a matching state. The transfer/COMM/result-channel
  shapes do **not** reproduce the cost mismatch on the incident binary.
- **Batched play with `verify = 0` produces a state hash the replay rejects** (`state_match=false`)
  while recording costs `[986, 984, 984, 984]`. With `verify = 1`, the same shape matches. This is a
  confirmed play/replay divergence on the incident binary and is why the R1 normalization (an enabled
  batch always verifies) is a correctness fix, not a preference.
- At that stage no cost mismatch was reproduced. Later retained controls populate M09–M11,
  M19/M20 and A-M21; actual recovered inputs and the exact instance are in §9.

## 8. Current status and identifier discipline

RC-A recovery containment and RC-B replay correctness remain separate. The historical RC-B trigger
is now explained by the recovered execution and single-variable correction. Independent review,
compatibility/activation assessment and operational acceptance remain open under C357. Issue564 is
not closed by source-level evidence. No validator deployment or live finality drill is claimed here.

The shared matrix's **M21** remains the pre-state/fringe tamper cell, and **M22–M24** retain their
existing meanings. The old trace-deletion harness's raw M21 is canonically **A-M21**. New recovery
experiments are **RCB-R22–RCB-R30**; raw M22–M30 labels are local aliases. Raw logs are preserved.

Both the [prior trace pack](../n564-rcb-trace-20261111/README.md) and the
[recovered-instance pack](../n564-rcb-recovered-20261111/README.md) are retained in this repository.
Source/run pins and digest manifests are explicit. Digests establish byte integrity, not execution
or universal safety by themselves.

## 9. Exact recovered instance and causal intervention

### Recovered inputs

- The first exact refusal in the recovered log is block1073 at2026-11-08T17:36:26.483Z, with one
  deploy, dd2d…. The originally reported block1115 at17:37:58.044Z has1e4f… then dd2d….
- Both use the same1092-byte BYOID registry term. The six incident signatures authenticate registry
  definitions and probes, not the unrelated six transfers in the current faucet ledger.
- Five payloads are contiguous protobuf carves. The dd2d payload is an authenticated reconstruction;
  its overwritten raw tail is not claimed as recovered.
- Both pre-states, the1073 fringe and both declared post-states have complete Merkle closures:
 52 history nodes and252 cold leaves in the deduplicated fixture, with no missing/bad hashes.
- The rejected BlockMessage and archived processed trace remain unavailable. Natural play
  regenerates the trace using signed data and the actual shard/height/proposer/pre-state seed.
  Informational timestamp/sequence substitutes and the1115 participation surrogate are printed.

### Executed results

| Cell | Intervention | Result |
|---|---|---|
|RCB-R25|original0a1e02362, no production edit|1073 [5576],1115 [5576,2460]; strict refusal5576/5302; both original post-state roots; three repeats each|
|RCB-R26|charge observer ON/OFF|141 charges sum5576 vs109 sum5302; first difference29 after inner consume240; same costs/roots without observer|
|RCB-R27|reverse COMM-binding iteration only|strict ACCEPT at original costs/declared roots, both cases and three timestamp variants each|
|RCB-R28|same correction, strict negative controls|COMM/Consume deletion retains original cost/status failures; Produce deletion remains accepted in these fixtures;192 RSpace tests pass|

### Source-to-symptom chain

RSpace log methods prepend events. build_replay_data previously appended COMMs while traversing
that newest-first log. Several pending requests match one persistent registry continuation, so the
newest request can run first. Its inner peek requires a later repetition counter of the same
nonpersistent state datum. The unchanged equality predicate cannot match that later recorded counter
at the earlier runtime counter. Replay suspends work and bills a different path.

The recorded shared-state peek COMMs have counters1,2,3,4 in execution order, hence4,3,2,1 in the
stored vector. The first source-derived conflict is a later request requiring4 while the initial
produce counter is1. The first observed billing difference is an unmatched inner consume. The full
category/charge census accounts for all274 phlo.

The one-line intervention changes the COMM-binding loop to:

```rust
for event in log.iter().rev() {
```

It changes neither the record, IO-presence scan, occurrence multiplicity, cost table/refunds nor the
cost/status/state/counter/unused-COMM guards. R27 gives the causal intervention; R28 retains the
strict failure controls. This is a replay-selection defect, not a cost waiver.

### Remaining boundary

The exact archived block/timestamp is not claimed. Complete compatibility for every historical block
and live operational recovery are not claimed. Law11 proves COMM-occurrence agreement over supplied
traces; it does not prove that this Rust selection implementation recomputes the correct trace.
Independent review and controlled operational acceptance remain required. Strict replay verdicts
can differ for previously accepted blocks with ambiguous pending-request/peek patterns; no
complete accepted-chain compatibility sweep is supplied. Section 6 records the hard-fork-class
boundary, ungated implementation and mandatory lockstep upgrade. See the
[compatibility/rollout and C357 operational acceptance conditions](../n564-rcb-recovered-20261111/README.md#compatibility-and-rollout).

Current-source red/green run [43108778606](https://github.com/aixaria0/rchain-rust/actions/runs/43108778606) succeeded. The uncorrected synthetic regression fails4844/4554 with four pending requests, while zero/one controls pass. Both recovered historical cases reproduce5576/5302 on87583050. Applying the exact production correction makes the regression and both historical strict cost/state replays pass;193 current RSpace tests and the cost register also pass. Prior run43104341321 executed no tests (runner/setup failures). Artifact checksums and source-byte equality were verified before import.

— Ω-WITNESS
