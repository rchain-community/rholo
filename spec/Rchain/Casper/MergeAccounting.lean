import Mathlib.Data.Finset.Basic
import Mathlib.Data.List.Basic

/-!
# Law 97 — a merge's accounting is total and single-counted

The multi-parent merge resolves a conflict set into `(kept, rejected)` and reports what it did
(`MergeReport`, `casper/src/merging.rs:262-326`). The report exists because the #280 incident's
rejection was visible nowhere: a chain of a finalised block was rejected, the deploy that rode on it
stayed `ProcessedWithSuccess`, and no counter moved. M5 asks for the ledger in full: the final scope's
rejections, the rejections without a conflict, the unapplied kept writes, and each accepted/rejected
deploy.

**The law.** Every chain in the conflict scope is classified — kept, rejected for a reason, or rejected
by a final-scope decision. Every rejected conflict-scope chain has a reason (I1: it conflicts with a
kept chain or depends on a rejected one). Every kept effect — native slot, datum, continuation —
occurs in the applied batch (I2, including duplicate occurrences on one channel). A cost move is
applied at most once: a chain whose slot winner has seen it is skipped, and a composition that would
take a vault below zero is refused rather than invented. Non-conflicting chains commute (Law 86c) and
their charges add.

**What it does not claim.** It does not decide whether a merge-rejected deploy should be charged or
refunded — that is Law 48's retired fee question. It states what the merge does: the effects are
omitted, the rejection is recorded, the cost move is applied at most once. It also does not restate the
fixture identity `kept + rejected = conflict` as a general theorem: `resolve_conflict_set_with_census`
returns `kept = conflictSet \ enforce_rejected \ resolved` and
`rejected = resolved ∪ enforce_rejected` (`sdk/src/dag/merging.rs:926-978`), so the identity holds only
when the final-scope decisions are inside the conflict set. The model states the set relation and the
per-chain classification, which are the general facts.

Layer `Casper`.
-/

namespace Rchain
namespace MergeAccounting

/-- A native slot, abstracted to a number. -/
abbrev Slot := Nat

/-- A cost-accounting move: a payer, the slot it writes, and the signed delta. This is the shape of
`CostMoves` (`casper/src/merging.rs:214-224`). -/
structure CostMove where
  payer : Nat
  slot : Slot
  amount : Int
deriving DecidableEq, Repr

/-- One deploy chain, as the report sees it. `slots` are its own native writes, `datums`/`konts` the
tuple-space channels it touches (occurrences, not a set: the coverage check is multiset-sensitive), and
`moves` its cost-accounting moves. -/
structure Chain where
  id : Nat
  host : Nat
  slots : Finset Slot
  datums : List Slot
  konts : List Slot
  moves : List CostMove
deriving DecidableEq

/-- What a chain's fate is. `rejected` and `finalRejected` both carry the reason the report names. -/
inductive Verdict where
  | kept
  | rejected (reason : Nat)
  | finalRejected (reason : Nat)
deriving DecidableEq, Repr

/-- **The classification.** A final-scope decision wins (`enforce_rejected`), then the conflict
resolution's rejection set, else kept. The priority mirrors `resolve_conflict_set_with_census`, which
subtracts `enforce_rejected` before the conflict search and unions it into the rejected set afterwards
(`sdk/src/dag/merging.rs:926-978`). -/
def classify (resolved forced : Finset Nat) (reasonOf : Nat → Nat) (id : Nat) : Verdict :=
  if id ∈ forced then .finalRejected (reasonOf id)
  else if id ∈ resolved then .rejected (reasonOf id)
  else .kept

/-- **97a: every chain is classified** — the verdict is total, with no fourth state. -/
theorem every_chain_is_classified (resolved forced : Finset Nat) (reasonOf : Nat → Nat) (id : Nat) :
    classify resolved forced reasonOf id = .kept ∨
      (∃ r, classify resolved forced reasonOf id = .rejected r) ∨
      (∃ r, classify resolved forced reasonOf id = .finalRejected r) := by
  by_cases hf : id ∈ forced
  · exact Or.inr (Or.inr ⟨reasonOf id, by simp [classify, hf]⟩)
  · by_cases hr : id ∈ resolved
    · exact Or.inr (Or.inl ⟨reasonOf id, by simp [classify, hf, hr]⟩)
    · exact Or.inl (by simp [classify, hf, hr])

/-- **97a: a kept chain is neither rejected nor forced out.** -/
theorem a_kept_chain_is_neither_resolved_nor_forced (resolved forced : Finset Nat)
    (reasonOf : Nat → Nat) (id : Nat) (h : classify resolved forced reasonOf id = .kept) :
    id ∉ resolved ∧ id ∉ forced := by
  by_cases hf : id ∈ forced
  · simp [classify, hf] at h
  · by_cases hr : id ∈ resolved
    · simp [classify, hf, hr] at h
    · exact ⟨hr, hf⟩

/-- **97a: every conflict-scope rejection carries a non-zero reason** — the I1 invariant as a hypothesis
(`hreason` is the check that the conflict map named a kept chain or a rejected dependency). -/
theorem every_rejection_has_a_reason (resolved forced : Finset Nat) (reasonOf : Nat → Nat)
    (hreason : ∀ id ∈ resolved, reasonOf id ≠ 0) :
    ∀ id ∈ resolved, id ∉ forced →
      ∃ r, r ≠ 0 ∧ classify resolved forced reasonOf id = .rejected r := by
  intro id hid hf
  exact ⟨reasonOf id, hreason id hid, by simp [classify, hf, hid]⟩

/-! ## 97b — no kept effect is silently lost -/

/-- Multiset coverage: every occurrence in `expected` has at least as many occurrences in `actual`.
This is `covers_occurrences` (`casper/src/merging.rs:391-403`) — a set or a `contains` would lose the
duplicate case the #420 incident lived in. -/
def covers (expected actual : List Slot) : Bool :=
  expected.all (fun s => decide (expected.count s ≤ actual.count s))

/-- The coverage check is reflexive, so an applied batch that carries every kept occurrence passes. -/
theorem coverage_is_reflexive (xs : List Slot) : covers xs xs = true := by
  unfold covers
  simp

/-- **97b's falsifier: dropping one occurrence breaks coverage** — the duplicate case a set-based check
would miss. -/
theorem a_dropped_occurrence_breaks_coverage : covers [1, 1] [1] = false := by
  decide

/-- The duplicate control: both occurrences present passes. -/
theorem duplicate_occurrences_are_counted : covers [1, 1] [1, 1] = true := by
  decide

/-! ## 97c — a cost move is applied at most once -/

/-- The dedup rule: a move whose `(payer, slot)` is already applied is skipped. -/
def applies (seen : Finset (Nat × Slot)) (m : CostMove) : Bool :=
  decide ((m.payer, m.slot) ∉ seen)

/-- Apply one move, updating the seen set. -/
def applyOne (seen : Finset (Nat × Slot)) (m : CostMove) :
    Finset (Nat × Slot) × List CostMove :=
  if applies seen m then (insert (m.payer, m.slot) seen, [m]) else (seen, [])

/-- **97c: a seen move is not re-applied.** -/
theorem a_seen_move_is_not_reapplied (seen : Finset (Nat × Slot)) (m : CostMove)
    (h : (m.payer, m.slot) ∈ seen) : (applyOne seen m).2 = [] := by
  unfold applyOne applies
  simp [h]

/-- **97c: an unseen move is applied** (non-vacuity: the rule is not always the empty list). -/
theorem an_unseen_move_is_applied (seen : Finset (Nat × Slot)) (m : CostMove)
    (h : (m.payer, m.slot) ∉ seen) : (applyOne seen m).2 = [m] := by
  unfold applyOne applies
  simp [h]

/-- **97c: a composition that would take a vault below zero is refused** — the fail-closed branch
`casper/src/merging.rs:1616-1630`, reachable when two accepted blocks spend one payer's REV without
seeing each other. -/
def compose (balance delta : Int) : Option Int :=
  let v := balance + delta
  if v < 0 then none else some v

theorem an_overdraft_is_refused : compose 5 (-10) = none := by
  decide

theorem a_funded_spend_is_composed : compose 15 (-10) = some 5 := by
  decide

/-! ## 97d — independent chains commute and their charges add -/

/-- The total of one chain's cost moves. -/
def moveTotal (ms : List CostMove) : Int :=
  ms.foldl (fun acc m => acc + m.amount) 0

/-- The total of a chain list's cost moves. -/
def totalCost (cs : List Chain) : Int :=
  (cs.map fun c => moveTotal c.moves).foldl (fun acc x => acc + x) 0

/-- The two chains of the independence witness: disjoint native slots, one cost move each. -/
def chainA : Chain where
  id := 0
  host := 0
  slots := {1}
  datums := [1]
  konts := []
  moves := [⟨0, 1, 5⟩]

def chainB : Chain where
  id := 1
  host := 1
  slots := {2}
  datums := [2]
  konts := []
  moves := [⟨1, 2, 3⟩]

/-- **97d: two independent chains' charges add.** The state half is Law 86c's; the cost carrier is this
law's. The disjointness hypothesis is the independence the state half needs, named here so the two
halves are the same claim. -/
theorem independent_merges_commute_and_add :
    chainA.slots ∩ chainB.slots = ∅ ∧
      totalCost [chainA, chainB] = totalCost [chainA] + totalCost [chainB] := by
  decide

end MergeAccounting
end Rchain
