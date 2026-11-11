# #564 — self-replay cost refusal: adversarial audit, representability RCA, HAZOP

**Reviewed revision.** `fix/564-self-replay-classification` on PR #565, starting at `893bd0b8c` and
extended by the commits this pack accompanies. **Incident binary:** `0a1e02362` (the deployed testnet
revision, in git, pinned Rust 1.95.0). Where the two differ the row says which one was read.

**Why this pack exists.** The first #565 unit fixed the liveness consequence of the 2026-11-08 incident
(the self-replay refusal was read as `Divergence`, retried for ~45 hours, and left no operator record)
and added a synthetic determinism test. It did not establish **how the failure is represented, under
what conditions**, or whether the protocol's refusal was a state verdict at all. This pack is the
adversarial audit, the condition inventory and root-cause analysis, and the HAZOP worksheet the issue
asked for. The acceptance frame is the user's: make the condition unrepresentable where possible, and
where it is not, provide a safe fallback state or mitigation.

**What cannot be established here.** The incident's evidence was not captured:

- A's `deploypoolstorage` (the only place the six client terms and the `Nil` probe existed) was not
  snapshotted before the pool expired at height 1170; logs never contained the terms.
- The refused block #1115 body was never stored: `put_block` runs only after validation succeeds
  (`casper/src/blocks/proposer/proposer.rs`), so a refused self-built block leaves no body on any node.
- No peer received #1115 (it was never broadcast).
- A's data directory, unit environment (`systemctl show -p Environment,ExecStart rnode`) and deployed
  binary digest are on the testnet host and are not available to this worktree.

The exact `5576/5302` pair and the 45-hour timeline are therefore **reported facts** from the issue and
the captured log, not artifacts re-derived here. The pack labels every claim `measured`, `read`,
`reported`, or `unavailable`, and no green fixture is called a root cause.

**Layout.**

| path | what it is |
|---|---|
| `audit.md` | the adversarial audit: claim · method · confirmed/refuted/unresolved · evidence · disposition |
| `rca.md` | the condition inventory and the root-cause analysis (representability, not reproduction) |
| `condition-inventory.tsv` | one row per play/replay disagreement condition, with its rung and falsifier |
| `cost-criticality.md` | the protocol decision record: is a recorded-cost mismatch a block-validity rule? |
| `matrix.tsv` | the measurement matrix on `0a1e02362` and `dev`, cell by cell |
| `hazop.md` | the companion HAZOP study (the machine-checked rows are in `docs/src/spec/failure-hazop.md` U22) |
| `incident/` | the incident evidence inventory and the list of what is unavailable |
| `incident-binary/` | the build manifest and the logs the matrix produced on `0a1e02362` |
| `dev/` | the same runs on `dev`, packed with `tools/evidence-pack.py` |

**Current verdict (updated as the units land).**

- **P0 confirmed by reading both revisions and by the cost-only tamper:** the replay decides
  `ReplayCostMismatch` before it compares the declared post-state hash (`runtime_replay.rs:489-497`),
  and the trace check runs after that early return. A state-correct block can be refused on cost alone,
  and the enforcing path never said which case it was. The bounded shadow replay now reports
  `state_hash_matched`, the replayed hash and the category/trace deltas; Law 93 states the independence;
  the acceptance rule remains a protocol decision (`cost-criticality.md`).
- **P0′ closed by R1:** `RelaxedValidated` play now requires per-deploy cost and status equality with
  the sequential oracle (falling back to the oracle's results), and an enabled cross-deploy batch always
  verifies. The play mode changes speed, not the recorded accounting.
- **The stronger trace lead is unresolved:** an unused COMM or a refund-count difference on a
  state-neutral deploy would surface as `ReplayCostMismatch` and never as `UnusedCommEvent`, because of
  the same early return. This is the leading hypothesis for the incident's shape; it is measured in the
  matrix, not assumed.
- **The incident-binary matrix narrows RC1 without closing it.** A plain 30,000,000 transfer costs
  984–986 phlo on `0a1e02362`, six of them 5910; the incident's per-deploy 5576 is not that shape, so
  the missing terms are load-bearing. The failed-COMM, unconsumed-result-channel and 2-deploy shapes
  replay with matching state. **Batched play with verification off produced a state hash the replay
  rejects** (M07 verifies and matches; M08 does not), which is why the R1 normalization is a
  correctness fix. No cost mismatch was reproduced; the effect-scheduler cells and the exact terms are
  still unavailable.
- **RC1 (the 274's cause) is not established.** The matrix and the code conditions are the evidence;
  the missing terms/state are named in `incident/unavailable.tsv` and in the runbook row.
