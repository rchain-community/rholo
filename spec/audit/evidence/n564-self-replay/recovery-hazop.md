# #564 — HAZOP study of the self-replay fault recovery

**Reviewed revision.** `fix/564-recovery-state-machine` (this branch), against the merged trigger
study (`hazop.md`, PR #565) and the incident binary `0a1e02362`. The machine-checked rows are
**U23** in `docs/src/spec/failure-hazop.md`; this is the companion study in the OCapN format
(`spec/audit/evidence/ocapn-hazop.md`), with the measured/reasoned distinction, severity, likelihood,
the steelman and the fault tree.

**Why this study exists.** The trigger study answered *why the block was refused*. It did not answer
*why the node stayed in that state for 45 hours*. That second fact is the incident. The refusal was
deterministic, the only modelled response was to rebuild the same deterministic input, the refused
block was never stored or broadcast, the halt was timer-only, the reset was wired only to exhausted
divergence records, and a restart cleared the in-memory retry state and re-entered the same input.
There was no safe exit. This study is the recovery function's HAZOP.

## §1 The recovery state machine, as it existed

| # | exit from a self-replay refusal | what it did | safe? | reachable? |
|---|---|---|---|---|
| E1 | deploy-scoped, attempts < 3 | returned `NotEnoughNewBlocks`; **no counter, no latch, no durable state**; `needs_retry` re-queued in ~16 s | no | always |
| E2 | the 2 s autopropose timer | the same rebuild | no | with `--autopropose` |
| E3 | after 3 identical refusals | a **selection filter**; a broken replay worked through the pool to the 256 cap | partly | deploy-scoped only |
| E4 | cap overflow | one increment of `consecutive_failures`; the timer halted after 3 such events | no | with the timer |
| E5 | restart | tracker rebuilt fresh; pool re-derived; same deploy set, pre-state and seed, only the wall-clock timestamp changed | no | always |
| E6 | `casper.self-reset` R3 | rewound to the last finalised anchor — **raised only by an exhausted divergence record** | yes | **no** for this fault |
| E7 | operator deletes the shard data dir | a source comment | yes | manual, destructive |

E1–E5 are retries; E6 is the only safe reset the tree had and no self-replay path raised it. That is
the finding the 45-hour freeze follows from. The liveness condition that makes it a **chain** halt
rather than a node wedge: `liveness.rs` ages a silent validator out of the partition after five
heights, but the finality denominator stays the whole bonded map, so a silent validator whose stake is
needed for `> 2/3` caps finality for everyone.

## §2 Hazard inventory

| id | hazard | sharpest fact | how known |
|---|---|---|---|
| **H1** | No recovery transition — the same block is rebuilt | `SelfReplayFailed` → `NotEnoughNewBlocks` → `needs_retry` → the same selection; no attest-only mode existed | read |
| **H2** | The retry is unbounded for a node-level fault | the deploy-scoped arm set no counter; the halt counter was read only by the autopropose timer; `NotEnoughNewBlocks` always re-queued | read |
| **H3** | The exclusion was three-strikes and scoped to the deploy set | exclusion at three; a node-level fault has nothing to exclude; a restart lost it | read; the tracker test |
| **H4** | The refusal destroyed its own evidence | the block was never stored; the body is unreconstructible; the tracker was process-local | read; `incident/unavailable.tsv` |
| **H5** | The reset was divergence-only | `ResetRequest` had one reason and one producer (`note_unrestorable_if_exhausted`) | read |
| **H6** | The halt was timer-only | the attest-on-new-blocks tap and the explicit path never consulted it | read |
| **H7** | A recovery that withholds the attestation makes the cap permanent | `attestation_suppressed` returns true when there is nothing to finalise, which is exactly the state a failed deploy block leaves | read |
| **H8** | The reset could drop a deploy only an unfinalised local block held | inclusion removes a deploy from the pool; the rewind purges the blocks above the anchor | read |
| **H9** | The 274's cause is not this study's subject | the trigger is RC-B and remains open; the recovery is RC-A and is established | reported/unavailable |

## §3 Hypotheses

| # | hypothesis | evidence that would confirm it | verdict |
|---|---|---|---|
| R1 | The fault state had no safe exit, so the node retried until an operator noticed | the code paths above and the issue's 45-hour timeline | **established (RC-A)** |
| R2 | A state-correct block was refused on cost alone | the shadow's `stateHashMatched`; the mechanism is confirmed, the incident's state is unavailable | open (RC-B) |
| R3 | The 274 was a play-mode or trace-accounting difference | the trigger study's matrix and census | open (RC-B) |
| R4 | A finalised-anchor reset clears a node-level self-replay fault | the devnet drill (owed if it cannot run) | mechanism; drill owed |
| R5 | The safe exit is an attestation, not a reset, for a deploy-scoped fault | the proposer test: one refusal → an attestation, refused set still pooled | **confirmed (unit)** |

## §4 Table A — the U23 rows, with severity and steelman

| row | word | known | severity | likelihood | steelman |
|---|---|---|---|---|---|
| F-U23-01 | NO | measured (recovery test) | S1 (chain halt when this validator is the quorum member) | L-D | fixed: one refusal produces a different input |
| F-U23-02 | MORE | measured (tracker test) | S1 | L-D | fixed: the three-strike is gone; the stage is keyed by pre-state |
| F-U23-03 | LESS | measured (halt test) | S1 | L-C | fixed: the latch is read by every trigger and parks the timer |
| F-U23-04 | AS WELL AS | measured (recovery test) | S2 | L-D | fixed: the suspect set and the record survive the recovery |
| F-U23-05 | PART OF | measured (reset boot test) | S2 | L-C | fixed: a `ResetRequested`/`Halted` stage seeds the halt |
| F-U23-06 | OTHER THAN | measured (recovery test) | S1 | L-D | fixed: selection-only, attestation-only, refused block never inserted |
| F-U23-07 | REVERSE | measured (pace-rule test) | S1 | L-D | fixed: `AttestOnly` bypasses the pace rule |
| F-U23-08 | EARLY | measured (tracker test) | S3 | L-D | fixed: suspect at one pre-state, retried at another |
| F-U23-09 | LATE | measured (reset/halt test) | S1 | L-C | fixed: one finalised-anchor reset, recorded first |
| F-U23-10 | BEFORE | measured (record codec + reset/halt test) | S2 | L-D | fixed: body, verdict and ids are durable before the transition |
| F-U23-11 | AFTER | measured (latch/resume + boot test) | S2 | L-C | fixed: the boot seed obeys the stage; the automatic post-catch-up resume is owed |

## §5 Table B — barriers that held

| attack / condition | defence |
|---|---|
| a self-built replay failure becoming `Divergence` | `ValidationOrigin` + `refusal_for` (Law 92) |
| the refused block being broadcast | `propose_effect` is called only after `validate_block` succeeds; the recovery test asserts one broadcast, the attestation |
| the recovery block carrying the refused deploy | `ProposalMode::AttestOnly` clears the user-deploy list before `BlockCreator::create`; the system deploys stay |
| a recovered refusal re-selecting the same set at the same pre-state | the suspect map is keyed by the refusing pre-state; selection reads `effective_exclusion` |
| a node-level fault retrying | the latch stops `do_propose` before any build; the timer parks; the tap is suppressed |
| the reset dropping a deploy | `return_unfinalised_deploys` re-admits them before the marker, or refuses the reset |
| the record being unreadable | version, bounded lengths, truncation/trailing-byte refusal; a read error is "unknown", not "empty" |
| a second reset storm | `reset_attempted` on the record; the stage is `Halted` after one attempt at the anchor |

## §6 Fault tree

```
            the node cannot leave the self-replay fault state safely
                                  │
   ┌──────────────┬───────────────┼────────────────┬────────────────┐
   no exit        too many      wrong/partial     no evidence     no post-check
   H1/F-01        H2/H3          H7/H8             H4/F-10         H6/F-11
       │              │               │                 │               │
  same input     ../../loop      exclude-vs-reset  body lost      restart re-enters
  same refusal   16 s forever     mix               context gone   the loop
       └──────────────┴───────────────┴─────────────────┴───────────────┘
                                  │
                  refused block → no latest message → finality capped
                     TE-5 (node wedge) · TE-1 (chain halt) when the
                     silent validator's stake is needed for > 2/3
```

Top events: **TE-5** is the primary; **TE-1** when the refusing validator's stake is needed for the
two-thirds quorum. TE-4 is bounded by the record's body cap and the exclusion cap. TE-2/TE-6 are not
reached by this fault; the node never broadcasts the refused block.

## §7 Verdict

**RC-A is established.** The incident's harm — 45 hours of refusals, no broadcast, finality frozen at
#1110 — is caused by the absence of a safe recovery state for a deterministic self-replay fault. The
handler had no transition that changed the input, produced an attestation, reset to a finalised
anchor, or halted every trigger loudly; the only safe reset in the tree was wired to a different
fault. The code paths are in §1 and the issue timeline is the measurement.

**RC-B is open.** Why the replay computed 5302 against 5576 is the trigger study's subject
(`hazop.md`, `rca.md`, `matrix.tsv`). It is not the cause of the freeze, and this study does not
claim it. The prior pass's sentence "the cause of the 274 is not established" was true of RC-B and
wrong as a statement about the incident.

**What was owed, and what closed it.** The follow-on closes the automatic post-catch-up resume: a
completed reset's catch-up moves the record to `Recovered` store-first and clears the latch with the
operator route's own wake, while the operator POST remains the fallback when the reset was disabled,
no anchor existed, or the anchor has had its one attempt. The one-reset-per-anchor bound, which was
written but never read, is enforced in the reset closure and carried across the refusal record's
overwrite. The refused body's availability and the reset attempt are on the operator surface and are
seeded from the record at boot. The tests are
`casper/tests/reset.rs::a_caught_up_self_replay_reset_resumes_without_an_operator_post`,
`casper/tests/reset.rs::an_over_cap_refused_body_is_visible_as_unavailable_with_its_length` and
`casper/src/blocks/proposer/proposer.rs::a_reset_at_an_anchor_already_attempted_is_refused`; the
pace-rule override is
`casper/src/blocks/proposer/proposer.rs::an_attestation_only_build_is_not_withheld_by_the_pace_rule`.

**Still owed.** The devnet drill's packed evidence (`tools/self-replay-drill.sh`, three arms:
attestation recovery, reset after an attestation failure, halt with the reset disabled) and **RC-B**,
the trigger, which is Aria's and is blocked on validator A's runtime environment.
