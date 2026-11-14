# Cross-shard transactions: two-phase commit (Laws 26–29, 98–100)

**Laws this document carries:** 26–29 — shard scope, cross-shard atomicity, leg idempotency, and the durable decision record; 98–100 — the acceptance language: value conservation, the decision-before-effect ordering and recovery closure, and shard-local ingress/routing.

[Cross-shard invoke](../node/shard-invoke.md) specifies the *primitive*: a remote deploy is an ordinary
caller-signed deploy submitted to a **different shard**'s deploy service, and `deployerId` is
shard-independent, so the same key is the same account on every shard. That primitive can *reach*
another shard, but it cannot make a pair of legs **atomic**: the escrow example
([`qucalc/examples/shard_exchange.rho`](../../../qucalc/examples/shard_exchange.rho)) is explicitly
non-atomic — two idempotent legs plus a joint-check monitor, with the client orchestrating the order
and retrying on crash.

This page specifies the **transaction layer** that lifts that primitive to atomicity: a
**two-phase commit (2PC)**, framed as a **Git pull request**. It is formalized in
[`spec/Rchain/CrossShard.lean`](../../../spec/Rchain/CrossShard.lean) as Laws 26–29, with the acceptance
laws in [`spec/Rchain/CrossShardAcceptance.lean`](../../../spec/Rchain/CrossShardAcceptance.lean) as
Laws 98–100.

## The Git pull-request analogy

A cross-shard transaction is a PR that spans two (or more) branches — one per shard.

| Git | Transaction |
|-----|-------------|
| open a PR | the initiator opens a transaction (`txn_id`), naming the shards and legs |
| push commits to each branch | each participant runs **PREPARE** — it locks its resources and votes |
| CI / review | the coordinator collects the votes (all `ready` = green) |
| merge | the coordinator records **COMMITTED** and sends COMMIT to every participant — the atomic merge commit |
| close without merge | the coordinator records **ABORTED** and sends ABORT; each participant compensates |

The merge commit is a single, content-addressed decision: after it exists, every participant has the
same terminal outcome. That is the atomicity the primitive lacks.

## Roles

- **Coordinator** — a gateway that can sign deploys to every participant shard (the "merger"). It
  owns a durable, content-addressed **transaction record**. A coordinator may be an off-chain client
  (`casper/src/txn_coordinator.rs`) or the node itself when it is a member of the shards involved
  (`casper/src/gateway/`).
- **Initiator** — the client that opens the transaction (the "author").
- **Participant** — a shard whose state the transaction spans (a "branch"); usually two: source and
  target.

## States

There are two state types, because there are two records:

```lean
-- The participant's record (`rholang/src/native_state.rs`), modelled in CrossShard.lean:
inductive TxnState where
  | prepared | committed | aborted

-- The coordinator's record (`casper/src/gateway/ledger.rs`), a separate Rust type:
--   CoordState = Proposed | Prepared | Committed | Aborted
```

- `prepared` (participant) — the leg's escrow is locked and a vote is recorded.
- `committed` / `aborted` (both records) — terminal. The participant has applied or compensated the
  escrow; the coordinator has made the decision durable.
- `Proposed` (coordinator only) — the transaction's legs are recorded and no leg has voted yet. The
  Lean model does not need a `proposed` constructor: "no record" is `Ledger.record = none` on the
  participant side, and the acceptance laws (99) only distinguish terminal from undecided, which
  `TxnState.IsTerminal` supplies.

The coordinator's mapping keeps `commit_record_deterministic` exact: `committed` is written only
when every leg has voted `ready`, so a `prepared` record can never hold a complete all-`ready` vote
list, and the biconditional holds verbatim on a stored record
(`casper/src/gateway/ledger.rs`, `CoordRecord::decision_is_deterministic`).

## Messages

Each message is a signed remote deploy (reusing the
[`shard_invoke`](../node/shard-invoke.md) primitive), **idempotent under `txn_id`** so re-delivery and client
retry are safe (Law 28).

| Message | Effect on the participant |
|---------|---------------------------|
| `PREPARE(txn_id, leg)` | lock the leg's resources; write a vote (`ready`/`abort`) into the shard's content-addressed state |
| `VOTE_READY(txn_id)` / `VOTE_ABORT(txn_id)` | the vote the coordinator observes |
| `COMMIT(txn_id)` | apply the effect, release the lock |
| `ABORT(txn_id)` | run the compensation, release the lock |

## The decision and recovery

The coordinator collects votes under a timeout:

- **all `ready` ⇒ COMMIT** — record `committed`, send COMMIT to every participant.
- **any `abort` or timeout ⇒ ABORT** — record `aborted`, send ABORT to every participant.

A `prepared` participant that loses the coordinator **holds its lock** and recovers the decision from
the coordinator's durable record. That is the classic 2PC **blocking** caveat — the model is *atomic*
(no mixed outcome) at the cost of a blocking recovery window; there is deliberately no non-blocking
3PC or presumed-abort, because those trade atomicity for liveness. The honest consequence is Law 29:
the record must be durable, so recovery always terminates. Law 99 carries the two operational halves:
the decision is written **before** phase two, and a drive from any non-terminal record reaches a
terminal one — including the no-legs abort — so a restart has a record to finish rather than an
in-flight transaction with no decision.

## The cross-shard laws

- **Law 26 — shard scope determinism.** A deploy/block's effects bind to exactly one shard; the shard
  id is a validated, ordered value, and the RNG seed + unforgeable names are shard-scoped. This is
  the *sharding* half: the id is the typed `ShardId` newtype (`shared/src/refined.rs`) — non-empty
  ASCII, ordered, with the `parent-shard-id`/`shard-name` hierarchy resolved into a full id by
  `ShardSpec` (`/root` for the default `root` shard, `/root/child` for a child named `child`; the
  depth is unbounded, e.g. `/root/child/leaf`) — and the
  boundary is enforced at deploy admission and block validation (`casper/src/validate.rs`).
  A node's *memberships* are a non-empty, duplicate-free list (`ShardMemberships`), which is what
  lets one node validate several shards while every request still resolves to exactly one.

- **Law 27 — cross-shard atomicity (2PC).** A transaction commits on every participant or aborts on
  every participant — no run leaves a strict subset committed.

- **Law 28 — leg idempotency.** `prepare`/`commit`/`abort` are idempotent under `txn_id`.

- **Law 29 — decision durability & record determinism.** The coordinator's decision is a durable,
  content-addressed record; a `prepared` participant can always recover it, and the merge/close
  record is re-derivable on replay (the Laws 11/16 content-addressing analog).

- **Law 98 — value conservation.** A prepare debits exactly the escrow, a commit credits exactly it,
  an abort refunds exactly it, and the payer + payee + escrow total is unchanged by every verb; the
  multi-shard instance is the sum of its legs under one decision. Commit is not a mint and abort is
  not a second payment.

- **Law 99 — the decision precedes its effect, and recovery closes.** An undecided record applies
  nothing; every drive reaches a terminal state (the no-legs abort is the fallback); a terminal record
  is returned untouched with no participant contacted; and a resume never re-prepares a leg that
  already voted.

- **Law 100 — shard-local scope.** Membership is checked before a record opens; a phase is anchored
  at the target shard's head, and an unreadable head refuses it (a genesis anchor is born expired);
  block/deploy ingress is shard-local, so the shard-blind DAG only ever merges one shard; and the
  router dispatches to the named member rather than relaying.

## The formalization

The Lean model defines the shard id, the lifecycle, a leg (a shard's effect + its compensating
inverse), the transaction, the coordinator record, and a run's terminal configuration:

```lean
abbrev ShardId := String
def ValidShardId (s : ShardId) : Prop := s ≠ ""

inductive TxnState where
  | prepared | committed | aborted

inductive Vote where
  | ready | abort

structure Leg where
  shard : ShardId
  effect : Nat          -- opaque content-addressed effect handle
  compensation : Nat    -- opaque content-addressed compensation handle

structure Txn where
  txn_id : Nat
  legs : List Leg

inductive Outcome where
  | committed | aborted

structure CoordRecord where
  txn : Txn
  state : TxnState
  votes : List (ShardId × Vote)

abbrev Run := List Outcome
```

**Three of the four laws were stated as axioms over freely-constructible model types, and all three
statements were FALSE** (found and refuted 2026-09-23, the consolidation pass's own remedy: a false
axiom is worse than an owed one, because anything follows from it). Each is deleted rather than kept
beside its own refutation, and the refutation is published in its place:

```lean
-- Law 26: `Leg` is `{shard, effect, compensation}` and `ValidShardId s := s ≠ ""`
theorem shard_scope_deterministic_is_false :
    ¬ (∀ l : Leg, ValidShardId l.shard) :=
  fun h => (h ⟨"", 0, 0⟩) rfl

-- Law 27: `Run := List Outcome`, so a mixed run is an inhabitant
theorem txn_atomic_is_false : ¬ (∀ r : Run, uniform r)   -- witness: [committed, aborted]

-- Law 29: `CoordRecord` is `{txn, state, votes}`, so a record can contradict its own state
theorem commit_record_deterministic_is_false :
    ¬ (∀ r : CoordRecord, r.state = TxnState.committed ↔ ∀ v ∈ r.votes, v.2 = Vote.ready)
```

**What each law is actually about**, read off the port rather than the type:

- **26** — the *gateway's ingress*: a leg's shard id is validated at the boundary
  (`ShardId::try_from` on `TxnLegDto.shard_id`, `node/src/web/http.rs:203-218`), so the claim is about
  the function that admits a leg. Stating it needs that function modelled.
- **27** — `run_2pc`'s *outcomes*, not `List Outcome`'s: the coordinator decides once (`all_ready`) and
  phase two applies that one decision to every leg that voted ready; a leg that did not prepare never
  locked, so it has no outcome to be uniform about.
- **29** — split in two, and **the decision half is proved**: `allReady` and `coordinatorDecision` are
  the port's own two lines (`txn_coordinator.rs:177-179`), and `coordinator_decision_committed_iff`
  gives `committed` iff every vote is ready — so the recorded decision *is* a function of the votes. The
  durability half is modelled in the same module (`CoordRecord.recordVote` and the absorbing
  theorems: a terminal record ignores a later vote, the C160 fix); the ordering and recovery
  acceptance is Law 99.

Law 28 is different in kind: `leg_idempotent` is a **theorem** about the model's own `applyEffect`
(that row is `proved-model`), not an axiom.

The acceptance module `CrossShardAcceptance.lean` continues from these types: `escrow`/`recordTotal`
and the exact-debit/exact-credit theorems over the participant's `txnPrepare`/`txnCommit`/`txnAbort`
(98); `prepareAll`/`drive`/`phaseTwo`/`resume` over `CoordRecord` (99); and `openTxn`,
`phaseWithHead`/`BornExpired`, `accepted` and the router model (100). Each clause has a defect-shape
definition and theorem, so the statement can fail against the neighbouring wrong implementation.

## Acceptance

There is **no M1–M6 gate for cross-shard transactions**: #428's mainnet gate does not mention them, and
its M5 "merge" is DAG state merge. Acceptance here is the law register — Laws 26–29 plus 98–100 — and
the resolution of the cross-shard primitive issue #33. Two boundaries are worth stating plainly:

- The invoke-layer primitive remains **non-atomic across shards** (#33's own resolution); atomicity is
  the 2PC layer, and the `rho:txn` escrow is what moves value, per shard.
- No deploy is **relayed** to a shard the node does not validate; a foreign shard is a caller error
  (Law 100a/100d), and per-shard bootstrap remains deferred because the LFS fringe exchange carries no
  shard id.

The register's rows do not substitute for the live/candidate acceptance arms, and #33 stays open.

## Rust realization (status)

- **Participant** (`rholang/src/system_processes.rs` `rho:txn`, `rholang/src/native_state.rs`
  `PREFIX_TXN`): the per-shard REV escrow — `prepare` (lock + vote), `commit` (apply), `abort`
  (compensate), `recover` (query), idempotent under `txn_id` (Law 28) and coordinator-gated via
  `RhoDeployerId` (the `bond` capability pattern).
- **Coordinator** (`casper/src/txn_coordinator.rs`): the client-side driver — `txn_term` builds the
  phase terms and `TxnCoordinator::run_2pc` signs → submits → collects the `prepare` votes → commits
  all or aborts the prepared legs (Law 27). The transport is the existing
  `casper/src/shard_invoke.rs` primitive (`invoke_term` → `signed_invoke` → submit → `await_reply`).
- **Shard scoping** (`shared/src/refined.rs` `ShardId`, `casper/src/conf.rs` `ShardSpec`/`ShardMemberships`,
  `casper/src/block_random_seed.rs`, `casper/src/validate.rs`,
  `casper/src/api/block_api_impl.rs`): the shard id is a validated, ordered newtype in the RNG seed
  and the unforgeable names, the full id is derived from the `parent-shard-id`/`shard-name`
  hierarchy, and the boundary is enforced at admission/validation.
- **Gateway** (`casper/src/gateway/`): a node that is itself a member of several shards can drive the
  transaction **on the node**, with no off-chain client. `GatewayTxn` submits each leg to the shard
  that owns it (`LocalShardDeployService`, over that shard's real `BlockApi` — a pooled deploy, not a
  side evaluation), collects the votes, decides, and applies phase two. `casper/src/conf.rs`'s
  `ShardMemberships` and the node's per-shard assembly (`node/src/runtime/node_runtime.rs`) supply the
  memberships; `node/src/api/shard_routing.rs` routes the one client surface across them. Reachable as
  `POST /api/v1/txn` (plus `GET /api/v1/txn` and `/api/v1/txn/{txnId}`), served only on the **admin**
  HTTP listener of a node that is a gateway. It is not on the public API port: the coordinator signs
  every leg with the node's validator key and escrows out of that key's own REV account, so the route
  is privileged like `/api/propose` and binds loopback unless `enable-devnet-admin-public` is set
  (AUDIT C121).
- **The coordinator's record is durable but *not* consensus state**
  (`casper/src/gateway/ledger.rs`): votes and the commit decision belong to one node — no other
  validator runs a coordinator — so they live in a node-local database (`<data-dir>/gateway/`) rather
  than the content-addressed RSpace trie, where they would make a shard's state hash depend on one
  node's off-chain coordination. Law 29 asks for *durable*, not *consensus*. On boot the gateway
  re-issues what an interrupted transaction still needs (`recover_in_flight`), so a participant that
  locked its escrow is not left holding it.
- **Still deferred**: relaying a deploy to a shard this node does **not** validate (an explicit
  non-goal, [`../node/shard-invoke.md`](../node/shard-invoke.md)), and per-shard bootstrap — a
  multi-shard node must therefore start from its own genesis or from existing state, since the LFS
  fringe exchange carries no shard id.
- **The acceptance witnesses** (Laws 98–100): the participant's exact debit/credit balances
  (`txn_prepare_commit_round_trip`, `txn_prepare_abort_returns_escrow`), the gateway's per-shard
  totals on both outcomes (`gateway_moves_the_escrow_on_every_leg`,
  `gateway_aborts_every_leg_when_one_cannot_prepare`), the ordering (`a_decision_that_cannot_be_written_sends_no_phase_two`),
  the resume (`run_resumes_an_existing_non_terminal_record`, `gateway_is_idempotent_under_txn_id`), the
  anchor refusal (`current_height_refuses_a_head_it_cannot_read`,
  `an_unreadable_head_refuses_the_leg_and_aborts`), and the ingress/routing cases
  (`a_block_from_another_shard_is_not_of_interest_at_the_receiver`,
  `a_block_whose_deploy_is_from_another_shard_is_refused`, the `shard_routing` table).
- **C370, fixed in the same pass**: `common::ShardFaults.head_error` and `reported_height` were
  declared but never read, so the previous "unreadable head anchors at 0" test could not fail for the
  reason its name gave and asserted `Committed`, the opposite of C64/C67. The knobs are wired and the
  case now asserts the refusal, the empty deploy list and the readable shard's head anchor.
- **A recorded boundary**: `current_height` returns `Ok(0)` for a shard the node does not hold. A fresh
  `run` cannot reach it (membership is checked first). After a membership change, recovery reaches a
  leg that left the membership, but the deploy service's `member()` gate refuses it and the leg
  aborts (`recover_in_flight_refuses_a_leg_that_left_the_membership`). A leg already voted `ready` on
  a removed shard keeps its escrow locked; that residual is outside the law and recorded here rather
  than claimed closed.

The end-to-end two-shard path — uniform commit, and abort on partial failure — is exercised by
`casper/tests/cross_shard_txn.rs` over a `DeployService` test double. The same file also takes the
*production* phase terms (`txn_coordinator::txn_term`) through the block pipeline
(`compute_state` → `replay_compute_state`) and asserts the replay re-derives the play post-state hash
(Law 29): the escrow and the transaction record live in the native mergeable state that feeds the
state hash, so a nondeterministic 2PC write fails there rather than in consensus. The gateway itself
is covered by `casper/tests/gateway_txn.rs` (commit, compensation, idempotency under a repeated
`txn_id`, restart recovery from the ledger) and by `node/tests/gateway.rs`, which runs one `rnode`
over two shards and drives the transaction through `POST /api/v1/txn`. `casper/tests/gateway_faults.rs`
takes the *failure* half of that surface — a deploy rejected, a reply that never comes, a head that
cannot be read, a ledger that cannot be written — since those branches are the ones that decide
whether a cross-shard transaction can leave funds stranded. The acceptance pass added the direct
ordering case (`a_decision_that_cannot_be_written_sends_no_phase_two`), the membership-loss recovery
case, and the receiver/validator shard-ingress cases listed above.
