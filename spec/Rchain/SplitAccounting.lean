import Mathlib.Data.List.Basic

/-!
# Law 96 — a split execution does not change the accounting

The port runs deploys through three kinds of split: a **batched play path** where each deploy runs on a
fork from the base and the batch is certified before it is used
(`casper/src/runtime_manager.rs:1793-1895`), a **concurrent block-validation path** where a batch of
dependency-free blocks is validated on one forked replay runtime per block and inserted serially
(`casper/src/blocks/block_processor.rs:536-620`), and the ordinary **cross-node** path where each
validator replays a block from its committed pre-state. The batch policy already encodes the rule: a
batched play path without verification is not representable (`canonical_batch_policy`,
`casper/src/runtime_manager.rs:501-513`), and the verification oracle compares the batched per-deploy
`cost`, `deploy_log`, `is_failed` and the post-state with the sequential ones. C360 measured what
happens without it: batched play with verification off recorded costs `[986, 984, 984, 984]` and a
different post-state (matrix M08).

**The law.** A split may change **speed**; it may not change the accounting. A canonical policy
publishes the sequential oracle's per-deploy outcomes. A shared replay runtime would change a verdict;
the per-block fork is what makes concurrent validation equal serial validation. A disagreement between
two nodes' verdicts is not reconciled into a publication: the agreed verdict may be published, a
disagreement publishes nothing and is attributed by provenance (Law 92) and bounded by the recovery
state machine (Law 94).

**What it does not claim.** It does not reprove the state half — Law 25 (validated speculation) and Law
86c (independent `StateChange`s commute) own that — and it does not claim a speedup or a capacity gain:
M1/M2 remain measurement gates. It also does not claim arbitrary blocks may validate concurrently; the
hypothesis is the dependency-free batch the processor drains.

Layer `Scheduler`.
-/

namespace Rchain
namespace Split

/-- A deploy, abstracted to its identifier. -/
structure Deploy where
  id : Nat
deriving DecidableEq, Repr

/-- What one deploy records: its per-deploy cost, its COMM log, its failure flag and its post-state.
These are the four fields the batch verification compares
(`casper/src/runtime_manager.rs:1877-1885`). -/
structure Outcome where
  cost : Nat
  log : List Nat
  failed : Bool
  state : Nat
deriving DecidableEq, Repr

/-- The sequential oracle's outcome for one deploy. -/
def seqDeploy (d : Deploy) : Outcome where
  cost := d.id
  log := [d.id]
  failed := false
  state := d.id

/-- The sequential oracle's run — the reference the batch is checked against. -/
def seqRun (ds : List Deploy) : List Outcome :=
  ds.map seqDeploy

/-- **The unverified split's shape.** The model uses a `+1` stand-in for "the batched path recorded a
different cost and state"; C360's real numbers are `[986, 984, 984, 984]` and a different post-state,
and the Rust witness pins them. This is the defect, not the law. -/
def speculative (ds : List Deploy) : List Outcome :=
  (seqRun ds).map (fun o => { o with cost := o.cost + 1, state := o.state + 1 })

/-- The effective batch policy (`casper/src/runtime_manager.rs:482-513`). -/
structure BatchPolicy where
  enabled : Bool
  verify : Bool
deriving DecidableEq, Repr

/-- The effective policy is canonical when it is off, or when it verifies. -/
def BatchPolicy.canonical (p : BatchPolicy) : Bool :=
  (!p.enabled) || p.verify

/-- The port's canonicaliser: an enabled batch always verifies. -/
def canonicalize (p : BatchPolicy) : BatchPolicy :=
  { p with verify := p.enabled || p.verify }

/-- What a policy publishes. The verified batch *is* the sequential oracle (verification accepts only on
equality); a verification failure is the whole-block sequential fallback; the unverified path is the
defect's shape. -/
def publishedBatch (p : BatchPolicy) (ds : List Deploy) : List Outcome :=
  if p.enabled && !p.verify then speculative ds else seqRun ds

/-- **96a: the canonicaliser leaves no unverified enabled batch.** -/
theorem the_canonicaliser_forces_verification (p : BatchPolicy) :
    (canonicalize p).canonical = true := by
  obtain ⟨enabled, verify⟩ := p
  cases enabled <;> cases verify <;> decide

/-- **96a: an unverified enabled policy is not canonical** — the state the canonicaliser exists to make
unreachable. -/
theorem an_unverified_policy_is_not_canonical :
    ({ enabled := true, verify := false } : BatchPolicy).canonical = false := by
  decide

/-- **96b: a canonical policy publishes the sequential oracle's outcomes.** The verified batch and the
off policy both equal the oracle; the unverified branch is excluded by canonicity. -/
theorem a_canonical_policy_publishes_the_oracle (p : BatchPolicy) (h : p.canonical = true)
    (ds : List Deploy) : publishedBatch p ds = seqRun ds := by
  obtain ⟨enabled, verify⟩ := p
  cases enabled <;> cases verify <;> simp [publishedBatch, BatchPolicy.canonical] at *

/-- **96b's falsifier: an unverified split can change the accounting.** With verification off the
published per-deploy cost and state differ from the oracle's — C360's shape. -/
theorem an_unverified_policy_can_change_the_cost :
    publishedBatch { enabled := true, verify := false } [⟨0⟩] ≠ seqRun [⟨0⟩] := by
  decide

/-! ## 96c — concurrent validation of a dependency-free batch -/

/-- A block as validation sees it: the pre-state it replays from and the post-state it claims. -/
structure Block where
  id : Nat
  pre : Nat
  post : Nat
deriving DecidableEq, Repr

/-- A replay verdict. -/
structure Verdict where
  cost : Nat
  state : Nat
  failed : Bool
deriving DecidableEq, Repr

/-- Validate on a fork seeded at the block's own committed pre-state — what
`fork_replay_runtime` gives each block (`casper/src/runtime_manager.rs:670-688`). -/
def validateForked (b : Block) : Verdict where
  cost := b.post - b.pre
  state := b.post
  failed := false

/-- The defect's shape: validate against a **shared** runtime state instead of the block's pre-state.
This is what the per-block fork avoids. -/
def validateShared (shared : Nat) (b : Block) : Verdict where
  cost := shared - b.pre
  state := shared
  failed := false

/-- Serial validation: each block on its own fork, in order. -/
def serialValidation (bs : List Block) : List Verdict :=
  bs.map validateForked

/-- Concurrent validation: the same per-block forks, dispatched together. -/
def concurrentValidation (bs : List Block) : List Verdict :=
  bs.map validateForked

/-- The defect's shape at the batch level: every block validated against one shared state. -/
def sharedValidation (shared : Nat) (bs : List Block) : List Verdict :=
  bs.map (validateShared shared)

/-- **96c: concurrent validation of a dependency-free batch agrees with serial validation.** Each block
reads only its own pre-state, so the dispatch order cannot reach a verdict. -/
theorem concurrent_validation_agrees_with_serial (bs : List Block) :
    concurrentValidation bs = serialValidation bs := rfl

/-- **96c's falsifier: a shared replay runtime changes a verdict.** With a shared state the cost and
state verdict are not the block's own — the reason the fork is load-bearing. -/
theorem a_shared_replay_runtime_changes_a_verdict :
    sharedValidation 0 [⟨1, 0, 5⟩] ≠ serialValidation [⟨1, 0, 5⟩] := by
  decide

/-! ## 96d — a disagreement is not published -/

/-- Publish the agreed verdict: two verdicts are reconciled only by agreement. -/
def publishAgreed (a b : Verdict) : Option Verdict :=
  if a = b then some a else none

/-- The defect's shape: publish the local verdict whatever the peer's says. -/
def publishLocal (a : Verdict) (_b : Verdict) : Option Verdict :=
  some a

/-- **96d: a disagreement publishes nothing.** -/
theorem a_disagreement_publishes_nothing {a b : Verdict} (h : a ≠ b) :
    publishAgreed a b = none := by
  unfold publishAgreed
  rw [if_neg h]

/-- Agreement publishes the agreed verdict (non-vacuity: the rule is not always `none`). -/
theorem an_agreement_publishes_it (a : Verdict) :
    publishAgreed a a = some a := by
  unfold publishAgreed
  rw [if_pos rfl]

/-- **96d's falsifier: the local rule publishes a disagreement** — the pre-fix reading that let a
node's own verdict stand over its peer's. -/
theorem the_local_rule_publishes_a_disagreement (a : Verdict) (_b : Verdict) :
    publishLocal a _b = some a := rfl

end Split
end Rchain
