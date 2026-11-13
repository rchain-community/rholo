# RC-B / #564 — causal trace-divergence falsifier (2026-11-11)

## Verdict and scope

**Established (mechanism):** On the exact deployed incident-source revision `0a1e02362a7c34e474e068ffd47469c8d4be707a`, deleting a single recorded COMM event (or one Consume event) from the deterministic transfer fixture, while holding the signed term, recorded per-deploy cost, initial state, and failure status constant, causes strict replay to execute a different cost path and refuse with `ReplayCostMismatch`.

**Not established (incident attribution):** This is not proof that the missing/altered COMM trace caused the actual `5576 vs 5302` discrepancy in block #1115 on 2026-11-08. The test yields `986 vs 947` (39 phlo) or `986 vs 910` (76 phlo); neither equals 274. The original six unaccepted client deploy terms and their exact replay traces were not captured before expiration. The issue remains OPEN for RC-B. Do not equate the synthetic intervention with the historical event.

**No consensus-rule change, validator deployment, data deletion, reset, or public-chain interaction was performed.** All execution was in isolated, ephemeral GitHub Actions runners using synthetic inputs. The repo changes here are only a fork-side test fixture, workflow and evidence.

## Source and provenance

| Item | Exact reference |
| --- | --- |
| Incident binary source | `0a1e02362a7c34e474e068ffd47469c8d4be707a` |
| Strict historical M21 run | https://github.com/aixaria0/rchain-rust/actions/runs/43080270095 — SUCCESS |
| Historical test source branch / tested head | `verify/n564-trace-historical-20261111` at `fc7f1b8fbd54cb24faa4279d4b3691b0427a03a5` |
| Post-#566 M21 corroboration | https://github.com/aixaria0/rchain-rust/actions/runs/43079412530 — SUCCESS |
| Post-#566 tested head | `c4018f47f316734dfe03306d29232cbb3e61fcb5`, based on `f4feb1a83862b5b58e682b09ec4188ca59294df6` |
| Isolated M19/M20 run | https://github.com/aixaria0/rchain-rust/actions/runs/43069621501 — SUCCESS |
| Toolchain | Ubuntu 24.04; Rust 1.95.0; checksum-pinned protobuf protoc 3.21.12 |
| Immutable raw readouts | Six log files in this directory; `SHA256SUMS` checked against exact copies of action artifacts |

Historical workflow checks out the exact source commit into a detached state and copies only the test fixture onto it. It asserts the commit SHA before compiling. It does not alter casper/src, rholang/src or rspace/src. The original M11 unsafe-relaxed-mode negative control is expected to fail at `OMEGA_UNSAFE_RELAXED_BLOCK_ACCEPTED`; the workflow verifies that exact assertion and records it separately instead of misreporting it as a build failure.

## M21 — controlled intervention on the exact incident revision

Each case first performs a clean play and strict replay, asserts equal post-state, then reruns an independently instantiated fixture with exactly one trace mutation. Every mutation asserts `ProcessedDeploy.cost.cost`, `is_failed`, and `deploy.data.term` are unchanged.

| Fixture | Single change to recorded trace | Recorded cost | Replay cost / verdict | Interpretation |
| --- | --- | ---: | --- | --- |
| REV transfer + result consumer | Delete first COMM | 986 | 947; `ReplayCostMismatch` | **39 phlo cost divergence caused without editing recorded cost** |
| REV transfer + result consumer | Delete first Consume | 986 | 947; `ReplayCostMismatch` | Same class, 39 phlo |
| REV transfer + result consumer | Delete all COMM | 986 | 910; `ReplayCostMismatch` | Multiple missed reductions, 76 phlo |
| REV transfer + result consumer | Delete first Produce | 986 | Replay accepted; state matches | A trace-completeness observation; NOT the incident discrepancy |
| Failed COMM fixture | Delete first COMM | 599 | `ReplayStatusMismatch` | Cost check is not reached as the first refusal |
| Failed COMM fixture | Delete first Consume | 599 | `ReplayStatusMismatch` | Same |
| Failed COMM fixture | Delete all COMM | 599 | `ReplayStatusMismatch` | Same |
| Failed COMM fixture | Delete first Produce | 599 | Replay accepted; state matches | No cost mismatch in this fixture |

The post-#566 runner independently confirms the same eight outcomes; that newer implementation adds a trace-census readout, but the historical conclusion above does not depend on that instrumentation.

## Existing differential controls

- M19, post-#566: cost census OFF and ON both recorded `[984, 599, 737]`, with equal status, state, trace lengths, and replay trace. Diagnostic instrumentation did not perturb this fixture.
- M20, post-#566: a failed COMM deploy recorded cost 599 and replayed with matching state; trace census reported one recorded COMM, one match, zero leftovers, and zero swallowed events.
- M09/M10 on the historical revision: Sequential, Gate, RelaxedValidated, and relevant ForkJoin controls had equal costs for the tested transfer/Nil and transfer/failed-COMM sets. These controls are not an exhaustive proof about every term.
- M11 on the historical revision: the Relaxed block entry did accept an invocation that the off-chain boundary should reject. This is an independently demonstrated safety boundary defect, addressed separately in Rholo PR #569, but it is not evidence that the incident validator used Relaxed mode.

## Source-level causality

1. Original `casper/src/runtime_replay.rs` lines 481–495 checks failed/succeeded status and then compares `processed_deploy.cost.cost` against the value produced by replay. A mismatch is returned before the block post-state verdict, so it is an *early observable*, not a diagnosis of a cost-table defect.
2. Original `rspace/src/replay_rspace.rs` lines 166–176 filters candidate data to those whose source the **recorded COMM** names; a missing/changed trace may therefore change what the replay matcher executes.
3. M21 demonstrates the actual causal intervention: perturb *only* the trace, obtain `ReplayCostMismatch` while preserving the producer's declared cost and term. Missing COMM can skip charged evaluation work.
4. This proves **sufficiency of a trace mismatch for this failure class**, not occurrence of such a mismatch in the historical self-built block.

Historical issue: https://github.com/rhovision-org/rholo/issues/564

## Unresolved historical attribution — required evidence

- The actual signed terms (and parsed deploy logs) in the rejected #1115, *particularly the deploy whose recorded cost was 5576*; this was a per-deploy comparison, not a 5576-phlo block total.
- The exact historical pre-state / fringe and native sidecar needed to replay those terms.
- Incident-time effective scheduling and batching policy. The 2026-11-11 read-only process configuration observation is post-restart and cannot prove the 2026-11-08 settings.
- A per-event cost/trace census that isolates precisely 274 phlo in that original execution without manual edits.

Until these are available, the strongest valid conclusion is: **trace/evaluation asymmetry is an experimentally proven producer–replay mismatch mechanism on the original source; the precise historical 274-phlo trigger remains unknown**. Do not close RC-B or change consensus acceptance on this basis.

## Evidence integrity

Run `sha256sum -c SHA256SUMS` in this directory. Logs were copied byte-for-byte from completed GitHub Actions artifacts; no line edits were made. Artifact retention is finite, so the copy here preserves the readouts. For independent reproduction, use the test source and workflow in the linked fork commits and verify the detached checkout SHA. The synthetic event-deletion test intentionally does not claim that the altered trace is a valid broadcast block.
