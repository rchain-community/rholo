# Determinism of the block state transition

**Laws this document carries:** 14–16 and 19 — the fringe, the DAG, block validity, the merge, the height map, and the RNG.

> This document is the **specification of the node's state-transition determinism** — the statement that
> the post-state hash of a block is a *pure function* of its inputs, founded in the law set
> ([`spec/INVENTORY.md`](../../../spec/INVENTORY.md)). It is the target the Lean formalization
> (`spec/Rchain/`) proves, and the target the Rust port's `play` and `replay` paths both implement. The
> prior documents specify the components: [The laws](laws.md), [The concurrency model](concurrency.md),
> and [Effect scheduling](scheduling.md). This page fixes the *block* level: what the block
> creator computes and what block validation must recompute, and why they must agree.

## The invariant in one line

> **`postStateHash = transition(preState, block, seed)` is a pure function.** Block *creation* (play)
> and block *validation* (replay) are two implementations of the **same** function; for every block,
> `play(preState, block, seed) == replay(preState, block, seed)`. Any difference is a consensus
> violation — a block that one honest node accepts and another rejects.

Determinism is not a property of the raw `Reduce` relation (which is not even single-step deterministic
up to `≡`); it is a property of the **chosen canonical schedule**, and of the port faithfully realizing
*one* transition function in both the play and replay paths. The laws turn that into a theorem:

| Law | What it guarantees for the block state transition |
|-----|-----------------------------------------------------|
| **4** — reduction (`⟶`) | The transition is a single deterministic reduction function; `new` yields fresh names deterministically from the seed; first-match-wins. |
| **1** — canonical total order | The post-state hash is order-independent (`sort` is idempotent and commutative). |
| **8** — deterministic COMM | Candidate and waiting-continuation selection is canonical (sorted-first by content hash). |
| **9** + **17** — merge monoid; RNG merge | Log merges and `Blake2b512Random` merges are commutative/associative (order-independent). |
| **10** — Merkle determinism | The state trie is content-addressed and collision-free. |
| **11** — replay determinism | Replay recomputes the recorded COMM trace exactly. |
| **19** — crypto | Canonical `Blake2b256` hash; `Blake2b512Random` is an associative splittable merge. |

## The play/replay sub-invariants

Play and replay are two code paths (`casper/src/runtime_manager.rs` vs `casper/src/runtime_replay.rs`)
that must compute the *same* transition. The following sub-invariants are the concrete obligations both
paths must satisfy. Each is tagged with the law(s) it realizes.

- **S1 — normalizer env.** Both paths normalize the deploy term with `NormalizerEnv(deploy)`, which
  binds `rho:rchain:deployerId → RhoDeployerId(deployer)` and `rho:rchain:deployId → RhoDeployId(sig)`.
  The env is part of the term's denotation, so a term that binds those URIs as
  `new x(`rho:rchain:deployerId`)` must resolve identically on both paths. *(Law 4.)*
- **S2 — seed derivation and split.** The block seed is a pure function of
  `(shard_id, block_number, sender, pre_state_hash)`; the per-deploy splits use the same indices
  `0`/`1`/`2` (pre-charge / user deploy / refund), and the block-level system-deploy splits use
  `deploy_count + k` (slashes) and `deploy_count + to_slash_count` (close). *(Laws 4, 19.)*
- **S3 — cost accounting.** Pre-charge is `phloLimit × phloPrice` (`totalPhloCharge`); refund is
  `max(0, phloLimit − cost) × phloPrice`. Cost is a deterministic function of the reduction. *(Law 4.)*
- **S4 — system-deploy construction.** Slash deploys are built over the sorted validator set, then
  close-block last, with identical arguments and seeds on both paths. *(Law 4.)*
- **S5 — native-store checkpointing.** The native (bonds/vault) overlay drains into the trie identically
  on both paths, so the content-addressed root is the same regardless of checkpoint cadence. *(Law 10.)*
- **S6 — reducer ordering.** Matching, merging, and dispatch iterate canonical (sorted) structures, so
  no `HashMap`/`HashSet` iteration order reaches the state hash. *(Laws 1, 8, 9, 17.)*

## Violations found in the port (and their remediation)

The port split Scala's single evaluator (`legacy/.../RuntimeSyntax.scala:527-535`, which both play and
replay call) into two Rust paths, which drifted. The audit found:

| # | Sub-invariant | Violation | Effect |
|---|---------------|-----------|--------|
| **D1** | S1 | Replay re-normalizes with an **empty** env (`evaluate(term)`), so `new x(`rho:rchain:deployerId`)` fails `add_urn` with `BugFoundError`. | Deterministic `InvalidStateHash` for every REV-transfer/bond/vault deploy. |
| ~~**D2**~~ | S3 | ~~Play refunds `phloLimit`; replay refunds `(phloLimit − cost) × phloPrice`.~~ **Corrected — see below: not a violation, and never was.** | ~~Latent consensus divergence, masked only because the native refund is a no-op.~~ |
| **D3** | S2/S4 | Play uses the *requested* deploy count (`deploys.len()`) for the slash/close seed index; replay uses the *actual* count (`state.deploys.len()`). | Latent divergence if a requested deploy is absent at block-creation time. |
| **S6a** | S6 | `maximum_bipartite_match.rs` returns a `HashMap::into_iter()` in process-randomized order. | Currently commutative, but the only randomized container iteration in the reduction path. |
| **S6b** | S6 | `dispatch.rs` merges branch RNGs in un-sorted `data_list` order. | Correct only because `data_list` order is deterministic; fragile. |

The remediation is in the code (see the plan), and — critically — is pinned by the executable check
below so future drift is caught at compile/test time rather than rediscovered in consensus.

**D2 is retracted (2026-09-23).** It was checked when the native refund stopped being a
no-op — the one change that would have made its "masked only because…" clause load-bearing — and
the divergence it describes is in neither tree. The amount is computed by **one** function used by
both paths (`ProcessedDeploy::refund_amount`, `models/src/casper/protocol/casper_message.rs:512-521`,
mirroring `CasperMessage.scala:216`'s
`(deploy.data.phloLimit - cost.cost).max(0) * deploy.data.phloPrice`), not by a per-path expression:
the play path passes it at `casper/src/runtime_manager.rs:577` and the replay path at
`casper/src/runtime_replay.rs:344`. The two cannot disagree about the *cost* feeding it either, since
replay verifies the recorded cost equals the recomputed one before the refund is constructed
(`runtime_replay.rs:399-407`: `replay_cost_mismatch`) — and the block's `ProcessedDeploy` *is* the play
result. Neither the Scala's play path (`RuntimeSyntax.scala:239`, `refundDiag(pd.refundAmount)`) nor
its replay path (`RuntimeReplaySyntax.scala:188`, `processedDeploy.refundAmount`) ever passed
`phloLimit` on one side only, so "play refunds `phloLimit`" was false when it was written and the
"masked" effect with it. The row is kept, struck through, rather than deleted: a reader who met the
old claim deserves to find the correction where the claim was.

## The executable check

The spec's runnable form is a play↔replay regression test in `casper/tests/`: it plays a deploy that
binds `rho:rchain:deployerId` (the transfer idiom), replays it, and asserts
`play_post_state == replay_post_state` — plus a cost/refund check for a non-trivial-cost deploy. Any
future S1–S4 drift fails that test.

**The #564 arm.** `play_and_replay_agree_per_deploy_for_same_key_multi_transfer` builds a
three-deploy block from one deployer key — two vault transfers and a **failed** deploy whose recorded
trace contains a COMM event — and runs it under both the sequential and the batched play policies.
`replay_compute_state` returning `Ok` is the per-deploy cost assertion: the replay compares
`ProcessedDeploy.cost.cost` with the replayed cost for every deploy, so a single mismatch is a
`ReplayCostMismatch`. The test also compares the costs the two play paths record. It passes, which is
a **negative** for the 2026-11-08 shape in this fixture, not a closure of RC1; the incident's trigger
remains open, and the result is recorded on #564.

## The replay record's order (Law 95)

The replay's record is not a set of COMMs; it is an **ordered** candidate list per consume, and the
order is the play's. RSpace prepends every event to its log (`rspace/src/rspace.rs:202-216`), so
`build_replay_data` must walk it in reverse to file COMMs in execution order
(`rspace/src/replay_rspace.rs:129-167`). Before the fix it filed them newest-first: a later pending
request could bind before the earlier repeated peek's COMM, the peek's `times_repeated` could not match
the produce counter, work was suppressed, and the replay cost fell — the 2026-11-08 incident's
**5576 vs 5302** (274 phlo).

The law (`Rchain/RSpace/ReplayOrder.lean`) models the two builders. The chronological one files the
play's sequence; the newest-first one is the defect's shape, and on a two-request witness it charges
the later COMM's continuation instead of the earlier one's (5 vs 3). The executable tie is
`casper/tests/replay_trace_order.rs::pending_peeks_replay_with_exact_cost_and_state`, which pins the
real play costs 1860 / 2606 / 4844 and requires the strict replay to preserve cost and state. The law
does **not** cover the RCHAIN-3505 workaround that drops the reverse half for a failed deploy (Law 11's
recorded hazard).

## A split does not change the accounting (Law 96)

Three places split work. A **batch** of deploys runs on forks from one base; a batch of
dependency-free **blocks** is validated concurrently on one forked replay runtime per block and
inserted serially; and **nodes** replay one block from one committed pre-state. The rule is the same:
the split may change speed, never the per-deploy cost, COMM log, failure flag or post-state.

- **Verification is not optional.** `canonical_batch_policy` (`casper/src/runtime_manager.rs:501-513`)
  never leaves an enabled batch unverified, and the verification oracle compares all four per-deploy
  fields with the sequential run. C360 measured the pre-fix shape: batched play with verification off
  recorded costs `[986, 984, 984, 984]` and a different post-state.
- **Concurrent validation is per-block.** Each validation forks its own replay runtime at the block's
  committed pre-state (`fork_replay_runtime`), so a dependency-free batch's verdicts are the serial
  verdicts; insertion stays serial (`casper/src/blocks/block_processor.rs:536-620`).
- **A disagreement is not published.** Two nodes' verdicts are reconciled only by agreement; a
  difference is attributed by provenance (Law 92) and bounded by the recovery state machine (Law 94).

The model is `Rchain/SplitAccounting.lean`; the Rust witnesses are the batch-policy test, the
two-path determinism test and the cost-only tamper test named in the register. It does not claim a
speedup or a capacity result — M1/M2 remain measurement gates.

## What determinism does *not* require

Determinism is about the **state hash**, not about the recorded cost field or diagnostic output. Two
documented, non-diverging asymmetries remain and are explicitly out of scope of the hash:

- **Genesis-vault re-seed** — `replay_block` passed no vaults; this *was* recorded here as "safe
  because genesis is trusted and never re-validated (an asserted invariant, not a code path)". **The
  parenthetical was false** (found 2026-09-23, on the 3-validator devnet): `casper/src/merging.rs`
  *does* replay the genesis. A node that did not create it has no mergeable-channel sidecar for it, so
  the sidecar is regenerated by replaying the block — and that replay passed `&[]` for the genesis
  wallet vaults, whose balances are `PREFIX_VAULT` leaves in the genesis post-state. The replay then
  computed a different hash and the validator refused the block:
  `regenerated mergeable channels for block ae620156… but replay computed ad7be2fa… instead of
  052c997a…`, with the bootstrap proposing happily while validators 1 and 2 sat at the height they
  joined at.

  **Fixed (2026-09-24)**, and the fix keeps the check rather than weakening it. The vaults are
  re-installed when the block *is* the genesis — `is_genesis_pre_state(pre_state_hash)`, i.e.
  `pre_state_hash == empty_state_hash_fixed()`, since a non-genesis block's pre-state already holds the
  post-genesis balances and re-installing them would clobber them. The vault list reaches the replay
  path because the genesis files are read as part of the **network configuration** on any node that has
  them, not only on the ceremony node: `genesis_descriptors_from_config` returns the PoS descriptors and
  the vaults together, and a non-ceremony node reads the bonds file *strictly* rather than
  autogenerating a validator set. `tools/devnet.sh` gives validators 1..n−1 the files, which is the
  half that made them the nodes without any genesis config at all. A node genuinely without the files
  still cannot replay the genesis and now fails loudly rather than silently computing a wrong state.
  AUDIT C46 carries the decision and the rejected alternative (reading the sidecar from the post-state
  has no mechanism: the trie has no number-channel leaf kind, and the mergeable channel set is
  execution-derived and absent from the block).
- **Concurrent-mode recorded cost** — under fork-join the *recorded* `PCost` at failure can differ from
  the sequential value; it affects the block's cost field, not the post-state hash.
