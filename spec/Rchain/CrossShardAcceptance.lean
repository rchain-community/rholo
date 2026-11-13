import Rchain.CrossShard
import Mathlib.Data.List.Basic

/-!
# Cross-shard acceptance — Laws 98–100

`Rchain.CrossShard` formalizes the protocol's *shape*: shard-scope ingress (26), the one decision every
prepared leg follows (27), idempotent legs (28), and a decision that is a function of the votes and
durable once terminal (29). This module formalizes the **acceptance language** those rows leave open:

* **Law 98 — value conservation.** A prepare debits exactly the escrow and nothing else; a commit
  credits exactly it; an abort refunds exactly it; the payer + payee + escrow total is invariant, and
  the multi-leg instance is the sum of its legs. `Rchain.txnPrepare`/(`txnCommit`/`txnAbort`) are the
  port's verbs (`rholang/src/native_state.rs:3163-3256`), so the exact-credit theorems are about those
  functions, not a restatement of a definition.

* **Law 99 — the decision precedes its effects and recovery closes.** No phase-two effect without a
  terminal decision; every drive reaches one (including the legless abort); a terminal record is
  returned untouched with nobody contacted; a resume never re-prepares a leg that already voted. The
  model mirrors `GatewayTxn::drive`/`run_under_lock` (`casper/src/gateway/mod.rs`).

* **Law 100 — shard-local scope.** Membership is admitted before a record opens; a phase is anchored at
  the target shard's head, and a genesis anchor is born expired once the chain is past the lifespan
  (the C166/C64 hazard); block and deploy ingress make every merge input one shard; and the router
  dispatches to the named member rather than relaying.

Every clause has a **defect-shape** definition and theorem: the sentence is only worth proving because
doing the neighbouring wrong thing makes it false. Laws 27/28/29 are cited, not reproved.
-/

namespace Rchain
namespace Acceptance

/-! ## Law 98 — a cross-shard transaction conserves value and moves it once -/

/-- The amount the ledger is holding in escrow for `id`: the record's amount when it is `prepared`,
    and zero once it is terminal or absent (the verbs release the record at the same time they move
    the balance). -/
def escrow (g : Ledger) (id : Nat) : Nat :=
  match g.record id with
  | some r =>
    match r.state with
    | TxnState.prepared => r.amount
    | _ => 0
  | none => 0

/-- The payer + payee + escrow total one leg carries. This is the quantity Law 98 says no verb moves. -/
def recordTotal (g : Ledger) (id : Nat) (r : TxnRecord) : Nat :=
  g.vault r.src + g.vault r.dst + escrow g id

/-- The record `txnPrepare` writes for a fresh leg. -/
def preparedRecord (payer payee : String) (amount : Nat) : TxnRecord :=
  { state := TxnState.prepared, amount := amount, src := payer, dst := payee }

/-- **Defect shape for 98a**: record the leg without debiting the payer. -/
def prepareWithoutDebit (g : Ledger) (id : Nat) (payer payee : String) (amount : Nat) : Ledger :=
  g.setRecord id (preparedRecord payer payee amount)

/-- **Defect shape for 98b**: credit the payee but leave the record `prepared`, so the escrow is still
    counted after the move. -/
def commitThatKeepsTheEscrow (g : Ledger) (id : Nat) (r : TxnRecord) : Ledger :=
  (g.setVault r.dst (g.vault r.dst + r.amount)).setRecord id r

/-- **Defect shape for 98b**: credit more than the escrow. -/
def commitWithCredit (g : Ledger) (id : Nat) (r : TxnRecord) (credit : Nat) : Ledger :=
  (g.setVault r.dst (g.vault r.dst + credit)).setRecord id { r with state := TxnState.committed }

/-- A write to the record leaves every vault balance alone. -/
theorem setRecord_vault (g : Ledger) (id : Nat) (r : TxnRecord) (a : String) :
    (g.setRecord id r).vault a = g.vault a := rfl

/-- A vault write is readable at its own key. -/
theorem setVault_same (g : Ledger) (a : String) (v : Nat) :
    (g.setVault a v).vault a = v := by
  simp [Ledger.setVault]

/-- A vault write leaves a different key alone. -/
theorem setVault_other (g : Ledger) (a b : String) (v : Nat) (h : b ≠ a) :
    (g.setVault a v).vault b = g.vault b := by
  simp [Ledger.setVault, h]

/-- `escrow` on an absent record is zero. -/
theorem escrow_none (g : Ledger) (id : Nat) (h : g.record id = none) : escrow g id = 0 := by
  simp [escrow, h]

/-- `escrow` on a prepared record is its amount. -/
theorem escrow_prepared (g : Ledger) (id : Nat) (r : TxnRecord) (h : g.record id = some r)
    (hs : r.state = TxnState.prepared) : escrow g id = r.amount := by
  simp [escrow, h, hs]

/-- `escrow` on a committed record is zero — the commit released it. -/
theorem escrow_committed (g : Ledger) (id : Nat) (r : TxnRecord) (h : g.record id = some r)
    (hs : r.state = TxnState.committed) : escrow g id = 0 := by
  simp [escrow, h, hs]

/-- `escrow` on an aborted record is zero — the abort returned it. -/
theorem escrow_aborted (g : Ledger) (id : Nat) (r : TxnRecord) (h : g.record id = some r)
    (hs : r.state = TxnState.aborted) : escrow g id = 0 := by
  simp [escrow, h, hs]

/-- **Law 98a — `txn_prepare` escrows exactly.** The payer is debited by exactly `amount`, the payee
    is untouched, and the record is the prepared record for that amount. (`rholang/src/native_state.rs:3163-3192`.) -/
theorem prepare_escrows_exactly (g : Ledger) (id : Nat) (payer payee : String) (amount : Nat)
    (g' : Ledger) (hrec : g.record id = none) (hbal : amount ≤ g.vault payer) (hne : payer ≠ payee)
    (h : txnPrepare g id payer payee amount = .ok g') :
    g'.vault payer + amount = g.vault payer ∧
    g'.vault payee = g.vault payee ∧
    g'.record id = some (preparedRecord payer payee amount) := by
  unfold txnPrepare at h
  rw [hrec] at h
  have hb : ¬ g.vault payer < amount := by omega
  rw [if_neg hb] at h
  simp only [Except.ok.injEq] at h
  subst h
  refine ⟨?_, ?_, ?_⟩
  · rw [setRecord_vault, setVault_same]
    omega
  · rw [setRecord_vault, setVault_other g payer payee (g.vault payer - amount) (Ne.symm hne)]
  · exact Ledger.record_setRecord _ _ _

/-- **Law 98a — prepare conserves the leg total.** The debit and the escrow are the same amount, so
    payer + payee + escrow is unchanged. -/
theorem prepare_conserves_the_leg_total (g : Ledger) (id : Nat) (payer payee : String)
    (amount : Nat) (g' : Ledger) (hrec : g.record id = none) (hbal : amount ≤ g.vault payer)
    (hne : payer ≠ payee) (h : txnPrepare g id payer payee amount = .ok g') :
    g'.vault payer + g'.vault payee + escrow g' id
      = g.vault payer + g.vault payee + escrow g id := by
  obtain ⟨hv, hp, hr⟩ := prepare_escrows_exactly g id payer payee amount g' hrec hbal hne h
  have h0 : escrow g id = 0 := escrow_none g id hrec
  have h1 : escrow g' id = amount :=
    escrow_prepared g' id (preparedRecord payer payee amount) hr rfl
  rw [h0, h1]
  omega

/-- **The defect shape is a value-creation theorem**: a prepare that records the leg without debiting
    the payer makes the leg total larger by exactly `amount`. -/
theorem a_prepare_that_does_not_debit_creates_value (g : Ledger) (id : Nat) (payer payee : String)
    (amount : Nat) (hrec : g.record id = none) :
    recordTotal (prepareWithoutDebit g id payer payee amount) id
        (preparedRecord payer payee amount)
      = recordTotal g id (preparedRecord payer payee amount) + amount := by
  rw [recordTotal, recordTotal]
  have hnew : escrow (prepareWithoutDebit g id payer payee amount) id = amount :=
    escrow_prepared _ id (preparedRecord payer payee amount) (Ledger.record_setRecord _ _ _) rfl
  have hold : escrow g id = 0 := escrow_none g id hrec
  rw [hnew, hold]
  simp [prepareWithoutDebit, preparedRecord, setRecord_vault]

/-- **Law 98b — `txn_commit` credits exactly the escrow.** The payee is credited by exactly the
    record's amount, the payer is untouched when the accounts differ, and the record is terminal.
    (`native_state.rs:3196-3224`.) -/
theorem commit_credits_the_payee_exactly (g : Ledger) (id : Nat) (r : TxnRecord) (g' : Ledger)
    (hrec : g.record id = some r) (hs : r.state = TxnState.prepared)
    (h : txnCommit g id = .ok g') :
    g'.vault r.dst = g.vault r.dst + r.amount ∧
    (r.src ≠ r.dst → g'.vault r.src = g.vault r.src) ∧
    g'.record id = some { r with state := TxnState.committed } := by
  unfold txnCommit at h
  simp only [hrec, hs] at h
  simp only [Except.ok.injEq] at h
  subst h
  refine ⟨?_, ?_, ?_⟩
  · rw [setRecord_vault, setVault_same]
  · intro hne
    rw [setRecord_vault, setVault_other g r.dst r.src (g.vault r.dst + r.amount) hne]
  · exact Ledger.record_setRecord _ _ _

/-- **Law 98b — commit conserves the leg total.** The payee gains the escrow and the escrow is
    released, so the total is unchanged. -/
theorem commit_conserves_the_leg_total (g : Ledger) (id : Nat) (r : TxnRecord) (g' : Ledger)
    (hrec : g.record id = some r) (hs : r.state = TxnState.prepared) (hne : r.src ≠ r.dst)
    (h : txnCommit g id = .ok g') :
    g'.vault r.src + g'.vault r.dst + escrow g' id
      = g.vault r.src + g.vault r.dst + escrow g id := by
  obtain ⟨hd, hs', hr⟩ := commit_credits_the_payee_exactly g id r g' hrec hs h
  have h0 : escrow g id = r.amount := escrow_prepared g id r hrec hs
  have h1 : escrow g' id = 0 :=
    escrow_committed g' id { r with state := TxnState.committed } hr rfl
  have hsrc : g'.vault r.src = g.vault r.src := hs' hne
  rw [hsrc, hd, h0, h1]
  omega

/-- **Law 98b — `txn_abort` refunds exactly the escrow.** The payer is credited by exactly the
    record's amount, the payee is untouched when the accounts differ, and the record is terminal.
    (`native_state.rs:3228-3256`.) -/
theorem abort_refunds_the_payer_exactly (g : Ledger) (id : Nat) (r : TxnRecord) (g' : Ledger)
    (hrec : g.record id = some r) (hs : r.state = TxnState.prepared)
    (h : txnAbort g id = .ok g') :
    g'.vault r.src = g.vault r.src + r.amount ∧
    (r.src ≠ r.dst → g'.vault r.dst = g.vault r.dst) ∧
    g'.record id = some { r with state := TxnState.aborted } := by
  unfold txnAbort at h
  simp only [hrec, hs] at h
  simp only [Except.ok.injEq] at h
  subst h
  refine ⟨?_, ?_, ?_⟩
  · rw [setRecord_vault, setVault_same]
  · intro hne
    rw [setRecord_vault, setVault_other g r.src r.dst (g.vault r.src + r.amount) (Ne.symm hne)]
  · exact Ledger.record_setRecord _ _ _

/-- **Law 98b — abort conserves the leg total.** The payer gets the escrow back and the escrow is
    released. -/
theorem abort_conserves_the_leg_total (g : Ledger) (id : Nat) (r : TxnRecord) (g' : Ledger)
    (hrec : g.record id = some r) (hs : r.state = TxnState.prepared) (hne : r.src ≠ r.dst)
    (h : txnAbort g id = .ok g') :
    g'.vault r.src + g'.vault r.dst + escrow g' id
      = g.vault r.src + g.vault r.dst + escrow g id := by
  obtain ⟨hs', hd, hr⟩ := abort_refunds_the_payer_exactly g id r g' hrec hs h
  have h0 : escrow g id = r.amount := escrow_prepared g id r hrec hs
  have h1 : escrow g' id = 0 :=
    escrow_aborted g' id { r with state := TxnState.aborted } hr rfl
  have hdst : g'.vault r.dst = g.vault r.dst := hd hne
  rw [hs', hdst, h0, h1]
  omega

/-- **The defect shape for commit**: crediting the payee while leaving the record `prepared` counts
    the escrow twice, so the leg total grows by `amount`. -/
theorem a_commit_that_keeps_the_escrow_creates_value (g : Ledger) (id : Nat) (r : TxnRecord)
    (hrec : g.record id = some r) (hs : r.state = TxnState.prepared) (hne : r.src ≠ r.dst) :
    recordTotal (commitThatKeepsTheEscrow g id r) id r
      = recordTotal g id r + r.amount := by
  rw [recordTotal, recordTotal]
  have hnew : escrow (commitThatKeepsTheEscrow g id r) id = r.amount :=
    escrow_prepared _ id r (Ledger.record_setRecord _ _ _) hs
  have hold : escrow g id = r.amount := escrow_prepared g id r hrec hs
  rw [hnew, hold]
  simp [commitThatKeepsTheEscrow, setRecord_vault, setVault_same,
    setVault_other g r.dst r.src (g.vault r.dst + r.amount) hne]
  omega

/-- **The defect shape for an over-credit**: one extra REV is one extra REV in the total. -/
theorem an_overcredit_creates_value (g : Ledger) (id : Nat) (r : TxnRecord) (hrec : g.record id = some r)
    (hs : r.state = TxnState.prepared) (hne : r.src ≠ r.dst) :
    recordTotal (commitWithCredit g id r (r.amount + 1)) id r
      = recordTotal g id r + 1 := by
  rw [recordTotal, recordTotal]
  have hnew : escrow (commitWithCredit g id r (r.amount + 1)) id = 0 :=
    escrow_committed _ id { r with state := TxnState.committed }
      (Ledger.record_setRecord _ _ _) rfl
  have hold : escrow g id = r.amount := escrow_prepared g id r hrec hs
  rw [hnew, hold]
  simp [commitWithCredit, setRecord_vault, setVault_same,
    setVault_other g r.dst r.src (g.vault r.dst + (r.amount + 1)) hne]
  omega

/-! ### Law 98c — the instance is the sum of its legs

The per-leg theorems above are the bridge from the port's verbs to this arithmetic. A `Book` is one
leg's accounting shape after the bridge: the payer's balance, the payee's, and the escrow. `commit`
pays the escrow out; `abort` returns it; both release the escrow. The instance theorems are the list
inductions that say an instance of such legs conserves its total and credits exactly the legs'
amounts. -/

structure Book where
  src : Nat
  dst : Nat
  escrow : Nat
deriving DecidableEq, Repr

/-- Pay the escrow to the payee and release it (`txnCommit`'s balance move). -/
def Book.commit (b : Book) : Book :=
  { b with dst := b.dst + b.escrow, escrow := 0 }

/-- Return the escrow to the payer and release it (`txnAbort`'s balance move). -/
def Book.abort (b : Book) : Book :=
  { b with src := b.src + b.escrow, escrow := 0 }

/-- The leg's total, the quantity Law 98 says no verb moves. -/
def Book.total (b : Book) : Nat :=
  b.src + b.dst + b.escrow

/-- A list sum with the shape the instance statement needs. -/
def listSum : List Nat → Nat
  | [] => 0
  | x :: xs => x + listSum xs

/-- A commit conserves one leg's total. -/
theorem a_commit_conserves_one_leg (b : Book) : b.commit.total = b.total := by
  simp [Book.commit, Book.total]
  omega

/-- **Law 98c — a committed instance conserves every leg's total.** -/
theorem a_committed_instance_conserves_the_totals (bs : List Book) :
    (bs.map Book.commit).map Book.total = bs.map Book.total := by
  induction bs with
  | nil => rfl
  | cons b bs ih =>
    simp only [List.map_cons]
    rw [a_commit_conserves_one_leg]
    rw [ih]

/-- **Law 98c — a committed instance credits exactly the legs' escrows**, summed. -/
theorem a_committed_instance_credits_the_leg_amounts (bs : List Book) :
    listSum ((bs.map Book.commit).map (fun b => b.dst))
      = listSum (bs.map (fun b => b.dst)) + listSum (bs.map (fun b => b.escrow)) := by
  induction bs with
  | nil => rfl
  | cons b bs ih =>
    simp only [List.map_cons, Book.commit, listSum]
    rw [ih]
    omega

/-- An abort conserves one leg's total. -/
theorem an_abort_conserves_one_leg (b : Book) : b.abort.total = b.total := by
  simp [Book.abort, Book.total]
  omega

/-- **Law 98c — an aborted instance conserves every leg's total.** -/
theorem an_aborted_instance_conserves_the_totals (bs : List Book) :
    (bs.map Book.abort).map Book.total = bs.map Book.total := by
  induction bs with
  | nil => rfl
  | cons b bs ih =>
    simp only [List.map_cons]
    rw [an_abort_conserves_one_leg]
    rw [ih]

/-- **Law 98c — an aborted instance refunds exactly the legs' escrows**, summed. -/
theorem an_aborted_instance_refunds_the_leg_amounts (bs : List Book) :
    listSum ((bs.map Book.abort).map (fun b => b.src))
      = listSum (bs.map (fun b => b.src)) + listSum (bs.map (fun b => b.escrow)) := by
  induction bs with
  | nil => rfl
  | cons b bs ih =>
    simp only [List.map_cons, Book.abort, listSum]
    rw [ih]
    omega

/-- The one decision a committed instance applies. -/
inductive Decision where
  | commit | abort
deriving DecidableEq, Repr

/-- **The defect shape for 98c**: a per-leg decision is not one decision for the instance. -/
def mixedDecision (i : Nat) : Decision :=
  if i = 0 then Decision.commit else Decision.abort

/-- **The defect shape, decided**: leg 0 commits and leg 1 aborts, so the instance is not one
    decision's — the shape Law 27 forbids. -/
theorem a_mixed_instance_is_not_one_decision :
    mixedDecision 0 = Decision.commit ∧ mixedDecision 1 = Decision.abort := by
  decide

/-- **The defect shape for the total**: a commit that credits both accounts creates the escrow
    again, so the instance's total grows by it. -/
def badCommit (b : Book) : Book :=
  { b with src := b.src + b.escrow, dst := b.dst + b.escrow, escrow := 0 }

theorem a_double_credit_creates_value (b : Book) :
    (badCommit b).total = b.total + b.escrow := by
  simp [badCommit, Book.total]
  omega

/-! ## Law 99 — the decision is durable before its effects, and recovery closes

The model mirrors `GatewayTxn::drive` (`casper/src/gateway/mod.rs:377-410`): phase one records a vote
per leg that has none, a still-undecided record is aborted (**the fallback**), the decision is written,
and phase two is a function of the terminal state and the ready votes. `run_under_lock`'s terminal
return is `resume`. The unguarded variants are the defects: they remove one guard each. -/

/-- Whether the record already has a vote for `s`. -/
def hasVote (r : CoordRecord) (s : ShardId) : Bool :=
  r.votes.any (fun p => p.1 = s)

/-- The vote recorded for `s`, if any. -/
def voteFor (r : CoordRecord) (s : ShardId) : Option Vote :=
  (r.votes.find? (fun p => p.1 = s)).map (fun p => p.2)

/-- The phase-one loop: `voted0` is the initial vote set (fixed), `voted` is the guard set (grows as
    replies are recorded), and `sent` is the operational log of the shards a prepare was sent to. -/
def prepareLoop (r : CoordRecord) (voted0 voted sent : List ShardId)
    (replies : List (ShardId × Vote)) : CoordRecord × List ShardId :=
  match replies with
  | [] => (r, sent)
  | p :: ps =>
    if p.1 ∈ voted then
      prepareLoop r voted0 voted sent ps
    else
      prepareLoop (r.recordVote p.1 p.2) voted0 (voted ++ [p.1]) (sent ++ [p.1]) ps

/-- The record phase one produces. -/
def prepareAll (r : CoordRecord) (replies : List (ShardId × Vote)) : CoordRecord :=
  (prepareLoop r (r.votes.map (fun p => p.1)) (r.votes.map (fun p => p.1)) [] replies).1

/-- The shards a prepare was sent to. -/
def sentBy (r : CoordRecord) (replies : List (ShardId × Vote)) : List ShardId :=
  (prepareLoop r (r.votes.map (fun p => p.1)) (r.votes.map (fun p => p.1)) [] replies).2

/-- The fallback: a record still undecided after phase one is aborted. -/
def decideRecord (r : CoordRecord) : CoordRecord :=
  if r.state.IsTerminal then r else { r with state := TxnState.aborted }

/-- Drive a record: phase one, then the fallback. -/
def drive (r : CoordRecord) (replies : List (ShardId × Vote)) : CoordRecord :=
  decideRecord (prepareAll r replies)

/-- **Defect shape for 99b**: drive without the fallback. -/
def driveNoFallback (r : CoordRecord) (replies : List (ShardId × Vote)) : CoordRecord :=
  prepareAll r replies

/-- Phase two: the one verb goes to exactly the legs that voted ready, and only from a terminal
    record. -/
def phaseTwo (r : CoordRecord) : List ShardId :=
  if r.state.IsTerminal then
    (r.txn.legs.filter (fun l => voteFor r l.shard = some Vote.ready)).map (fun l => l.shard)
  else []

/-- **Defect shape for 99a**: phase two without the terminal guard. -/
def phaseTwoUnguarded (r : CoordRecord) : List ShardId :=
  (r.txn.legs.filter (fun l => voteFor r l.shard = some Vote.ready)).map (fun l => l.shard)

/-- The resume path: a terminal record is returned untouched with nobody contacted. -/
def resume (r : CoordRecord) (replies : List (ShardId × Vote)) :
    CoordRecord × List ShardId :=
  if r.state.IsTerminal then (r, [])
  else (drive r replies, sentBy r replies)

/-- **Defect shape for 99c**: resume without the terminal return. -/
def resumeUnguarded (r : CoordRecord) (replies : List (ShardId × Vote)) :
    CoordRecord × List ShardId :=
  (drive r replies, replies.map (fun p => p.1))

/-- **Defect shape for 99d**: the unguarded prepare log. -/
def sentByUnguarded (replies : List (ShardId × Vote)) : List ShardId :=
  replies.map (fun p => p.1)

/-- A decided, all-ready record. -/
def readyRecord : CoordRecord :=
  { txn := { txn_id := 0, legs := [⟨"/root", 0, 0⟩, ⟨"/root/child", 0, 0⟩] },
    state := TxnState.committed,
    votes := [("/root", Vote.ready), ("/root/child", Vote.ready)] }

/-- A record with one leg still pending. -/
def pendingRecord : CoordRecord :=
  { txn := { txn_id := 1, legs := [⟨"/root", 0, 0⟩, ⟨"/root/child", 0, 0⟩] },
    state := TxnState.prepared,
    votes := [("/root", Vote.ready)] }

/-- A record with no legs at all. -/
def leglessRecord : CoordRecord :=
  { txn := { txn_id := 2, legs := [] }, state := TxnState.prepared, votes := [] }

/-- **Law 99a — an undecided record applies nothing.** -/
theorem an_undecided_record_applies_nothing (r : CoordRecord) (h : ¬ r.state.IsTerminal) :
    phaseTwo r = [] := by
  simp [phaseTwo, h]

/-- **Law 99a — a decided record applies the verb to its ready legs.** -/
theorem a_decided_record_applies_the_ready_legs :
    phaseTwo readyRecord = ["/root", "/root/child"] := by
  decide

/-- **The defect shape for 99a**: without the terminal guard, a prepared record's ready leg is applied
    before a decision exists. -/
theorem a_phase_two_without_the_terminal_guard_applies_before_a_decision :
    phaseTwoUnguarded pendingRecord = ["/root"] := by
  decide

/-- **Law 99b — every drive reaches a terminal state.** -/
theorem a_drive_reaches_a_terminal_state (r : CoordRecord)
    (replies : List (ShardId × Vote)) : (drive r replies).state.IsTerminal := by
  unfold drive decideRecord
  split
  · assumption
  · simp [TxnState.IsTerminal]

/-- **Law 99b — the no-legs record aborts**, which is the branch that makes the previous theorem
    total. -/
theorem a_legless_drive_aborts : (drive leglessRecord []).state = TxnState.aborted := by
  simp [drive, decideRecord, prepareAll, prepareLoop, leglessRecord, TxnState.IsTerminal]

/-- **The defect shape for 99b**: without the fallback, a legless record stays undecided. -/
theorem a_drive_without_the_fallback_can_stay_undecided :
    ¬ (driveNoFallback leglessRecord []).state.IsTerminal := by
  simp [driveNoFallback, prepareAll, prepareLoop, leglessRecord, TxnState.IsTerminal]

/-- **Law 99c — a terminal record is returned untouched.** -/
theorem a_terminal_record_is_returned_untouched (r : CoordRecord)
    (replies : List (ShardId × Vote)) (h : r.state.IsTerminal) :
    resume r replies = (r, []) := by
  simp [resume, h]

/-- **Law 99c — a terminal resume contacts nobody.** -/
theorem a_terminal_resume_contacts_nobody (r : CoordRecord)
    (replies : List (ShardId × Vote)) (h : r.state.IsTerminal) :
    (resume r replies).2 = [] := by
  simp [resume, h]

/-- **The defect shape for 99c**: without the terminal return, a decided record is contacted again. -/
theorem a_resume_without_the_terminal_guard_contacts_a_decided_transaction :
    (resumeUnguarded readyRecord [("/root", Vote.ready)]).2 = ["/root"] := by
  rfl

/-- The list invariant behind 99d: a shard in the initial vote set is never sent a prepare, provided
    the guard set contains the initial set. -/
theorem prepareLoop_never_sends_initial_voted (r : CoordRecord) (voted0 voted sent : List ShardId)
    (replies : List (ShardId × Vote)) (hsub : ∀ x ∈ voted0, x ∈ voted)
    (h : ∀ x ∈ sent, x ∉ voted0) :
    ∀ x ∈ (prepareLoop r voted0 voted sent replies).2, x ∉ voted0 := by
  induction replies generalizing r voted sent with
  | nil => simpa [prepareLoop] using h
  | cons p ps ih =>
    unfold prepareLoop
    split
    · exact ih r voted sent hsub h
    · apply ih (r.recordVote p.1 p.2) (voted ++ [p.1]) (sent ++ [p.1])
      · intro x hx
        exact List.mem_append.mpr (Or.inl (hsub x hx))
      · intro x hx
        rcases List.mem_append.mp hx with hxs | hx1
        · exact h x hxs
        · simp only [List.mem_singleton] at hx1
          subst hx1
          intro hp0
          exact ‹¬ p.1 ∈ voted› (hsub p.1 hp0)

/-- **Law 99d — a voted leg is never prepared.** -/
theorem a_voted_leg_is_never_prepared (r : CoordRecord)
    (replies : List (ShardId × Vote)) (s : ShardId)
    (h : s ∈ r.votes.map (fun p => p.1)) : s ∉ sentBy r replies := by
  unfold sentBy
  exact fun hs =>
    prepareLoop_never_sends_initial_voted r (r.votes.map (fun p => p.1))
      (r.votes.map (fun p => p.1)) [] replies (by intro x hx; exact hx)
      (by intro x hx; simp at hx) s hs h

/-- **Law 99d — a resume does not re-prepare the voted leg.** -/
theorem a_resume_does_not_re_prepare_the_voted_leg :
    sentBy pendingRecord [("/root", Vote.ready)] = [] := by
  decide

/-- **Law 99d — a resume sends the pending leg.** -/
theorem a_resume_sends_only_the_pending_legs :
    sentBy pendingRecord [("/root/child", Vote.ready)] = ["/root/child"] := by
  decide

/-- **The defect shape for 99d**: the unguarded log sends a prepare to a voted shard. -/
theorem an_unguarded_prepare_re_prepares_a_voted_leg :
    "/root" ∈ sentByUnguarded [("/root", Vote.ready)] := by
  simp [sentByUnguarded]

/-! ## Law 100 — every phase is a shard-local deploy, and the DAG is single-shard -/

/-- A `List.all` that is true means every member satisfies the predicate. -/
theorem list_all_eq_true {α : Type} (l : List α) (p : α → Bool)
    (h : l.all p = true) : ∀ x ∈ l, p x = true := by
  induction l with
  | nil => intro x hx; simp at hx
  | cons a as ih =>
    simp only [List.all_cons, Bool.and_eq_true] at h
    intro x hx
    rcases List.mem_cons.mp hx with rfl | hx
    · exact h.1
    · exact ih h.2 x hx

/-- Every shard in `shards` is a member. -/
def allMembers (members : List ShardId) (shards : List ShardId) : Bool :=
  shards.all (fun s => decide (s ∈ members))

/-- Opening a transaction: no legs or any non-member leg opens no record. This is `run_under_lock`
    (`casper/src/gateway/mod.rs:287-332`) before the durable `put`. -/
def openTxn (members : List ShardId) (id : Nat) (legs : List Leg) : Option CoordRecord :=
  if legs.isEmpty then none
  else if allMembers members (legs.map (fun l => l.shard)) then
    some { txn := { txn_id := id, legs := legs }, state := TxnState.prepared, votes := [] }
  else none

/-- **Defect shape for 100a**: open without the membership check. -/
def openTxnUnguarded (_members : List ShardId) (id : Nat) (legs : List Leg) : Option CoordRecord :=
  some { txn := { txn_id := id, legs := legs }, state := TxnState.prepared, votes := [] }

/-- **Law 100a — a non-member leg opens no record.** -/
theorem a_non_member_leg_opens_no_record (members : List ShardId) (id : Nat) (legs : List Leg)
    (h : allMembers members (legs.map (fun l => l.shard)) = false) :
    openTxn members id legs = none := by
  unfold openTxn
  split
  · rfl
  · simp [h]

/-- **Law 100a — an empty leg list opens no record.** -/
theorem an_empty_leg_list_opens_no_record (members : List ShardId) (id : Nat) :
    openTxn members id [] = none := by
  simp [openTxn]

/-- **Law 100a — an opened record names only members.** -/
theorem an_opened_record_names_only_members (members : List ShardId) (id : Nat) (legs : List Leg)
    (r : CoordRecord) (h : openTxn members id legs = some r) :
    ∀ l ∈ r.txn.legs, l.shard ∈ members := by
  unfold openTxn at h
  split at h
  · simp at h
  · split at h
    · simp only [Option.some.injEq] at h
      subst h
      intro l hl
      have hb : (legs.map (fun l => l.shard)).all (fun s => decide (s ∈ members)) = true := by
        simpa [allMembers] using ‹allMembers members (legs.map (fun l => l.shard)) = true›
      have hall : ∀ s ∈ legs.map (fun l => l.shard), s ∈ members := by
        intro s hs
        exact of_decide_eq_true (list_all_eq_true _ _ hb s hs)
      exact hall l.shard (List.mem_map.mpr ⟨l, hl, rfl⟩)
    · simp at h

/-- **The defect shape for 100a**: without the membership check a foreign leg opens a record. -/
theorem an_unguarded_open_records_a_foreign_leg :
    ∃ r, openTxnUnguarded ["/root"] 0 [⟨"/elsewhere", 0, 0⟩] = some r ∧
      ∃ l ∈ r.txn.legs, l.shard ∉ ["/root"] := by
  refine ⟨{ txn := { txn_id := 0, legs := [⟨"/elsewhere", 0, 0⟩] },
            state := TxnState.prepared, votes := [] }, rfl, ?_⟩
  exact ⟨⟨"/elsewhere", 0, 0⟩, by simp, by decide⟩

/-! ### Law 100b — the anchor is the target shard's head -/

/-- What a phase becomes: a refusal (the head could not be read) or a vote. -/
inductive PhaseResult where
  | refused (reason : String)
  | voted (vote : Vote)
deriving DecidableEq, Repr

/-- A phase with the head read it was given. An unreadable head refuses the phase rather than
    anchoring it at genesis (AUDIT C64/C67). -/
def phaseWithHead (head : Except String Nat) (reply : Vote) : PhaseResult :=
  match head with
  | .error e => .refused e
  | .ok _ => .voted reply

/-- **Defect shape for 100b**: ignore the head read and vote anyway. -/
def phaseWithHeadUnguarded (_head : Except String Nat) (reply : Vote) : PhaseResult :=
  .voted reply

/-- The anchor a phase is submitted with, if it has one. -/
def phaseAnchor (head : Except String Nat) : Option Nat :=
  match head with
  | .ok h => some h
  | .error _ => none

/-- The port's expiry (`casper/src/validate.rs:77`): a deploy anchored at `anchor` is expired once the
    chain reaches `anchor + lifespan`. -/
def BornExpired (head anchor lifespan : Nat) : Prop :=
  anchor + lifespan ≤ head

/-- **Law 100b — an unreadable head refuses the phase.** -/
theorem an_unreadable_head_refuses_the_phase (e : String) (reply : Vote) :
    phaseWithHead (.error e) reply = .refused e := by
  rfl

/-- **Law 100b — a refused phase cannot vote ready.** -/
theorem a_refused_phase_is_not_a_ready_vote (e : String) (reply : Vote) :
    phaseWithHead (.error e) reply ≠ .voted Vote.ready := by
  simp [phaseWithHead]

/-- **Law 100b — a readable head votes.** -/
theorem a_readable_head_votes (h : Nat) (v : Vote) :
    phaseWithHead (.ok h) v = .voted v := by
  rfl

/-- **Law 100b — a readable head is anchored at its own height.** -/
theorem a_readable_head_anchors_at_its_height (h : Nat) : phaseAnchor (.ok h) = some h := by
  rfl

/-- **Law 100b — a refused phase has no anchor.** -/
theorem a_refused_phase_has_no_anchor (e : String) : phaseAnchor (.error e) = none := by
  rfl

/-- **The defect shape for 100b**: the unguarded phase votes ready on a failed read. -/
theorem the_unguarded_phase_votes_ready_without_a_head (e : String) :
    phaseWithHeadUnguarded (.error e) Vote.ready = .voted Vote.ready := by
  rfl

/-- **Law 100b — a genesis anchor is born expired once the chain is past the lifespan.** The `0` a
    failed head read used to fall back to is exactly this anchor. -/
theorem a_genesis_anchor_is_born_expired (head lifespan : Nat) (h : lifespan ≤ head) :
    BornExpired head 0 lifespan := by
  simp [BornExpired]
  omega

/-- **Law 100b — the head anchor is admissible while the lifespan is positive.** -/
theorem the_head_anchor_is_admissible (head lifespan : Nat) (h : 0 < lifespan) :
    ¬ BornExpired head head lifespan := by
  simp [BornExpired]
  omega

/-! ### Law 100c — ingress is shard-local, so the merge is single-shard -/

structure Deploy where
  shard : ShardId
deriving Repr

structure Block where
  shard : ShardId
  deploys : List Deploy
deriving Repr

/-- The block-level half of `check_if_of_interest` (`casper/src/blocks/block_receiver.rs:440-459`). -/
def blockShardOk (conf : ShardId) (b : Block) : Bool :=
  decide (b.shard = conf)

/-- The deploy-level half (`casper/src/validate.rs:96-106`). -/
def deployShardOk (conf : ShardId) (b : Block) : Bool :=
  b.deploys.all (fun d => decide (d.shard = conf))

/-- Both halves of the shard gate. -/
def accepted (conf : ShardId) (b : Block) : Bool :=
  blockShardOk conf b && deployShardOk conf b

/-- **Defect shape for 100c**: accept on the block's shard alone. -/
def acceptedByBlockShardOnly (conf : ShardId) (b : Block) : Bool :=
  blockShardOk conf b

/-- **Law 100c — an accepted block carries the node's shard.** -/
theorem an_accepted_block_is_the_nodes_shard (conf : ShardId) (b : Block)
    (h : accepted conf b = true) : b.shard = conf := by
  unfold accepted blockShardOk at h
  exact of_decide_eq_true (Bool.and_eq_true _ _ |>.mp h).1

/-- **Law 100c — every deploy in an accepted block carries the node's shard.** -/
theorem every_deploy_in_an_accepted_block_is_the_nodes_shard (conf : ShardId) (b : Block)
    (h : accepted conf b = true) : ∀ d ∈ b.deploys, d.shard = conf := by
  unfold accepted blockShardOk deployShardOk at h
  have hall := (Bool.and_eq_true _ _ |>.mp h).2
  intro d hd
  exact of_decide_eq_true (list_all_eq_true _ _ hall d hd)

/-- **Law 100c — any list of accepted blocks is one shard**, which is what makes the shard-blind DAG
    and Law 97's merge accounting per-shard. -/
theorem a_merge_input_of_accepted_blocks_is_one_shard (conf : ShardId) (blocks : List Block)
    (h : blocks.all (accepted conf) = true) :
    ∀ b ∈ blocks, b.shard = conf ∧ ∀ d ∈ b.deploys, d.shard = conf := by
  induction blocks with
  | nil => intro b hb; simp at hb
  | cons x xs ih =>
    simp only [List.all_cons, Bool.and_eq_true] at h
    intro b hb
    rcases List.mem_cons.mp hb with hbx | hb
    · exact ⟨an_accepted_block_is_the_nodes_shard conf b (by simpa [hbx] using h.1),
             every_deploy_in_an_accepted_block_is_the_nodes_shard conf b (by simpa [hbx] using h.1)⟩
    · exact ih h.2 b hb

/-- **The defect shape for 100c**: the block-shard check alone accepts a block whose deploy names
    another shard. -/
theorem a_block_shard_check_alone_accepts_a_foreign_deploy :
    acceptedByBlockShardOnly "/root" ⟨"/root", [⟨"/root/child"⟩]⟩ = true := by
  decide

/-! ### Law 100d — routing dispatches, never relays -/

/-- Where a deploy went. -/
inductive Route where
  | dispatched (shard : ShardId)
  | refused
deriving DecidableEq, Repr

structure Router where
  members : List ShardId
  primary : ShardId
deriving Repr

/-- A router needs a primary that is a member (`a_router_needs_a_primary_that_is_a_member`). -/
def mkRouter (members : List ShardId) (primary : ShardId) : Option Router :=
  if primary ∈ members then some ⟨members, primary⟩ else none

/-- Whether `s` is one of the router's shards. -/
def Router.isMember (r : Router) (s : ShardId) : Bool :=
  decide (s ∈ r.members)

/-- **The dispatch rule**: the named member, or a refusal. There is no relay outcome. -/
def routeDeploy (r : Router) (s : ShardId) : Route :=
  if r.isMember s then .dispatched s else .refused

/-- **Defect shape for 100d**: route a non-primary's deploy to the primary. -/
def relayRoute (r : Router) (s : ShardId) : Route :=
  if s ∈ r.members then .dispatched r.primary else .refused

/-- The probe order: the primary first, then the remaining members. -/
def probeOrder (r : Router) : List ShardId :=
  r.primary :: r.members.filter (fun s => decide (s ≠ r.primary))

/-- The first shard that answers. -/
def firstSome {α : Type} : List ShardId → (ShardId → Option α) → Option α
  | [], _ => none
  | s :: ss, f =>
    match f s with
    | some v => some v
    | none => firstSome ss f

def probe (r : Router) (answer : ShardId → Option Nat) : Option Nat :=
  firstSome (probeOrder r) answer

def sampleRouter : Router :=
  { members := ["/root", "/root/child"], primary := "/root" }

def answerChild : ShardId → Option Nat
  | "/root" => none
  | "/root/child" => some 7
  | _ => none

/-- **Law 100d — a deploy is dispatched only to its named member.** -/
theorem a_deploy_is_dispatched_only_to_its_named_member (r : Router) (s t : ShardId)
    (h : routeDeploy r s = .dispatched t) : t = s ∧ s ∈ r.members := by
  by_cases hm : r.isMember s = true
  · simp [routeDeploy, hm] at h
    subst h
    exact ⟨rfl, by simpa [Router.isMember] using of_decide_eq_true hm⟩
  · simp [routeDeploy, hm] at h

/-- **Law 100d — a non-member deploy is refused, not relayed.** -/
theorem a_non_member_deploy_is_refused (r : Router) (s : ShardId) (h : s ∉ r.members) :
    routeDeploy r s = .refused := by
  simp [routeDeploy, Router.isMember, h]

/-- **Law 100d — a router refuses a primary that is not a member.** -/
theorem a_router_needs_a_primary_that_is_a_member (members : List ShardId) (primary : ShardId)
    (h : primary ∉ members) : mkRouter members primary = none := by
  simp [mkRouter, h]

/-- **Law 100d — a member primary makes a router.** -/
theorem a_member_primary_makes_a_router (members : List ShardId) (primary : ShardId)
    (h : primary ∈ members) : mkRouter members primary = some ⟨members, primary⟩ := by
  simp [mkRouter, h]

/-- **Law 100d — the primary is probed first.** -/
theorem the_primary_is_probed_first (r : Router) : (probeOrder r).head? = some r.primary := by
  rfl

/-- **Law 100d — a key on a secondary is found after the primary misses.** -/
theorem a_key_on_a_secondary_is_found_after_the_primary_misses :
    probe sampleRouter answerChild = some 7 := by
  decide

/-- **The defect shape for 100d**: a relay route leaves the named member for the primary. -/
theorem a_relay_route_leaves_the_named_shard :
    relayRoute sampleRouter "/root/child" = .dispatched "/root" := by
  decide

end Acceptance
end Rchain
