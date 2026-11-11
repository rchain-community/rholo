import Rchain.Casper.Validate

/-!
# Law 93 — a cost verdict is not a state verdict

The 2026-11-08 incident (#564) reached an operator as `ReplayCostMismatch initial_cost=5576
replay_cost=5302`. The enforcing replay returns that refusal **before** it compares the block's
declared post-state hash, so the evidence carried no state verdict at all. The determinism page
(`docs/src/formal/determinism.md`) says determinism is about the state hash, not the recorded cost
field; the recorded cost is still consensus-carried (the refund and executor payment are built from it),
so the protocol may refuse on it — but that refusal is an **accounting** verdict, and it must not be
read as a statement that the replay failed to reproduce the state.

**The law.** A replay's evidence has two independent components: a state verdict
(`matched`, `mismatched`, or `notComputed` when the enforcing path stopped before the checkpoint) and a
cost verdict. A cost mismatch does not imply a state mismatch; a state-correct block can carry a cost
mismatch. The Rust shadow replay computes the missing state verdict on a bounded second pass, and the
operator record carries both.

This is deliberately a small model: it says what the evidence **may** contain, not which verdict is
correct for any block. The acceptance rule (whether a cost mismatch invalidates a block) is a protocol
decision, recorded in `spec/audit/evidence/n564-self-replay/cost-criticality.md`; this law does not
decide it.

Layer `Casper`.
-/

namespace Rchain

/-- What the replay learned about the declared post-state. `notComputed` is the enforcing path's
answer when it stopped at the cost check: the absence of a verdict, not a mismatch. -/
inductive StateVerdict where
  | matched
  | mismatched
  | notComputed
deriving DecidableEq, Repr

/-- The two independent verdicts a replay can report. -/
structure ReplayEvidence where
  state : StateVerdict
  costMatched : Bool
deriving DecidableEq, Repr

/-- The state was reproduced. -/
def StateCorrect (e : ReplayEvidence) : Prop := e.state = StateVerdict.matched

/-- **The incident's mechanism.** A cost mismatch can coexist with a state-correct replay. The model is
inhabited, so the statement is not vacuous. -/
theorem cost_mismatch_does_not_imply_state_mismatch :
    ∃ e : ReplayEvidence, e.costMatched = false ∧ StateCorrect e :=
  ⟨⟨StateVerdict.matched, false⟩, rfl, rfl⟩

/-- **Independence, both ways.** For every cost verdict there is a state-correct replay carrying it;
the cost verdict does not determine the state verdict. -/
theorem every_cost_verdict_admits_a_state_correct_replay (b : Bool) :
    ∃ e : ReplayEvidence, e.costMatched = b ∧ StateCorrect e := by
  cases b
  · exact ⟨⟨StateVerdict.matched, false⟩, rfl, rfl⟩
  · exact ⟨⟨StateVerdict.matched, true⟩, rfl, rfl⟩

/-- **The enforcing path's silence is not a mismatch.** `notComputed` is distinct from `mismatched`, so
an operator reading a cost refusal cannot conclude the state failed. -/
theorem not_computed_is_not_a_mismatch :
    StateVerdict.notComputed ≠ StateVerdict.mismatched := by decide

end Rchain
