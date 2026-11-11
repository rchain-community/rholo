import Rchain.Casper.Validate

/-!
# Law 94 — a local fault has a bounded exit

The 2026-11-08 incident (#564) was not a cost-arithmetic incident. A validator built block #1115,
its own replay refused it, and the node rebuilt the **same deterministic block** for ~45 hours,
never broadcast it, and capped finality at #1110. The refusal was reproducible, so the retry could
not succeed; the proposer had no transition that changed the input, produced an attestation, reset to
a finalised anchor, or halted every trigger. That is a recovery-state defect, not a replay defect.

**The law.** From the refused state, the model has **no transition back to itself**: a local fault
either changes the proposal input (the refused set is held out; the immediate rebuild is an
attestation with no user deploy), moves to a reset of a **finalised** anchor, or halts. An
unrecognised transition is a halt, which is the safe fallback. Every fault therefore reaches a safe
state in one step, and "retry the unchanged input" has no representation to write.

**What it does not claim.** It does not model the replay's cause (that is RC-B, open), the cost/state
ordering (law 93), or the reset's durable bracket (laws 72/73/76). It says only that the fault state
has an exit and that the exit is not a no-op. The Rust witnesses are the proposer's recovery/halt
tests and the durable-record codec.

Layer `Casper`.
-/

namespace Rchain

/-- The recovery state of a proposer after its own block fails replay. -/
inductive RecoveryState where
  | healthy
  | refused
  | recovering
  | resetRequested
  | halted
deriving DecidableEq, Repr

/-- What the proposer may do next. `retrySameInput` is deliberately **not a constructor**: the state
the incident reached has no representation to write. -/
inductive RecoveryStep where
  | changeInput
  | attestOnly
  | resetFinalised
  | halt
deriving DecidableEq, Repr

/-- The transition. An unrecognised step is a halt — the safe fallback, not a retry. -/
def nextState : RecoveryState → RecoveryStep → RecoveryState
  | .refused, .changeInput => .recovering
  | .refused, .attestOnly => .recovering
  | .recovering, .resetFinalised => .resetRequested
  | .recovering, .halt => .halted
  | _, _ => .halted

/-- The states a fault transition may land in. -/
def RecoverySafe : RecoveryState → Prop
  | .recovering => True
  | .resetRequested => True
  | .halted => True
  | _ => False

/-- **No step retries the refused state.** The incident's loop has no transition. -/
theorem no_unchanged_retry (s : RecoveryState) (step : RecoveryStep) :
    s = .refused → nextState s step ≠ .refused := by
  intro h
  subst h
  cases step <;> decide

/-- **Every fault reaches a safe state in one transition.** -/
theorem every_fault_reaches_safe (step : RecoveryStep) :
    RecoverySafe (nextState .refused step) := by
  cases step <;> trivial

/-- A reset is admitted only when its anchor is finalised. -/
def resetAdmitted (anchorFinalised : Bool) : Prop := anchorFinalised = true

/-- **A non-finalised anchor is refused.** -/
theorem a_non_finalised_anchor_is_refused : ¬ resetAdmitted false := by
  unfold resetAdmitted
  decide

/-- **A finalised anchor is admitted.** -/
theorem a_finalised_anchor_is_admitted : resetAdmitted true := rfl

end Rchain
