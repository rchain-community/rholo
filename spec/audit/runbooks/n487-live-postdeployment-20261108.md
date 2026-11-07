# #487 / #553 — pre-registered public four-validator acceptance runbook

**Status:** DRAFT / NOT EXECUTED. This document is a proposed acceptance protocol, not authorization to touch validators, submit transactions, restart nodes or claim a live result.

**Decision owner:** Jim + Patrick (maintainer go/no-go and final verdict); operator and independent evidence reviewer must be identified before execution. **Scope owner:** Aria (pre-registration/evidence design). Approval of this document alone does not authorize execution.

**Parent:** [#553](https://github.com/rhovision-org/rholo/issues/553). **Local comparator:** [n487-admission-finality-stall-n4-20261102](../evidence/n487-admission-finality-stall-n4-20261102/README.md). **Already satisfied separately:** the scoped #485/#492 historical differential, [merged #557](https://github.com/rhovision-org/rholo/pull/557) at `f5ec8e2b`. This runbook **does not reopen #485**.

## 0. Acceptance contract — freeze before the window

The operator must obtain explicit maintainer approval for a **named window** and the exact **signed, low-value native-REV test transfer** (source, destination, maximum amount/fee, responsible owner and test wallet authorization) before any write. No production secrets, private keys, signing material or validator control endpoints belong in Git. The public testnet, not a disposable DevNet, is the scope.

The existing option-2 contract in [admission.md](../../docs/src/node/admission.md#finality-is-not-admission) is authoritative:

- `acceptsDeploys` is **local pool capacity**, not network finality, health quorum or settlement.
- Deploy **accepted** means the request was admitted; **pooled** means held but not executed; `ProcessedWithSuccess` / `ProcessedWithError` indicates execution in a block, **not finality**.
- Only `GET /api/v1/deploy-settlement/{id}` returning **`stage: "finalizedSuccess"` AND `settlementConfirmed: true`** for the actual **inclusion block** is a positive settlement result; cross-check finalized inclusion by block hash/height and independent validators. Other stages, especially `includedUnfinalized` and `finalityUnknown`, must never be advertised as settled.
- A single node's `GET /api/v1/finality-observation` always has `availability: "unknown"`; its numerical lag is an observation, not a quorum oracle.
- An unresolved, stale or partitioned view must yield unknown/unfinalized; no client may infer settlement from a local tip balance.

This protocol measures the existing behavior. It does **not** redefine admission policy or introduce a consensus or protocol change.

## 1. Immutable preflight pins (required, not populated by this draft)

Create a **signed or maintainer-reviewed, time-stamped preflight manifest** with all fields completed and committed/attached to the resulting evidence record *before* submitting the test deploy. Missing or mismatching pins are **NO-GO**; never infer them from an earlier DevNet run.

| Required field | Pre-registration requirement |
|---|---|
| Approved UTC start/end; operator, observers and rollback owner | Names and approval references, prior to test |
| Release source `SHA`, release/tag and branch | Exact commit deployed to all four public validators; not merely a green PR |
| Release build provenance | CI URL/attempt, artifact SHA-256, executable `rnode` SHA-256, `--version`, packaging/container digest if applicable |
| Four validator identities | Stable ID/alias, bonded stake, host/instance identifier, binary SHA, boot ID, relevant API addresses retained **privately** |
| Chain identity | Network/shard, genesis hash **and** genesis/bonds file digests, live bond set and total weight; verify same network/genesis on all four |
| Current deployment state | Per-node software version, online state, height, finalized height/hash, observed lag, `lastFinalityAgeMs`, `lastBlockAgeMs`, time-sync offset |
| Signed test deploy | Authorized account, designated receiver, test amount/max fee, deploy signature/hash/id, signed payload digest, validity window, non-replay plan |
| Rollback configuration | Approved previous build/config, snapshot/reference and restoration authority, host capacity and rollback location; no unsafe in-place rebuild |
| Evidence destination | Run ID, immutable source pins, capture paths, independent reviewer and redaction policy |

**Do not pin the 2026-11-02 DevNet binary as the live release.** That artifact established the local contract only. A current release build actually installed on the four public validators is mandatory.

**Hard NO-GO:** diverging binary/genesis/bond pins; unverified quorum/validator set; inability to observe finality and settlement surfaces; missing approval to submit the test transfer; unresolved host-capacity or rollback exposure; unstable time sync; unresolved network instability; or any request to run destructive restart/partition experiments during this window.

## 2. Arms / sampling plan — freeze these criteria before execution

Keep this run **non-disruptive**. No deliberate validator shutdown, network partition, bond change or synthetic finality freeze on the public network. The exactly-2/3, recovery and partition negative controls have **already been exercised locally** in n487; they are not a license to recreate those failures in production.

| Arm | Proposed cadence / window | Required evidence | Verdict |
|---|---|---|---|
| A0 — read-only preflight | Sample all four validators at 5-second intervals for **120 seconds** before submitting any deploy | UTC wall-clock plus monotonic/sample sequence, validator boot ID, version/binary hash, latest height, finalized height/hash and lag/ages | All four present; same expected chain/bond set; no unexplained finality divergence |
| A1 — accepted / pooled | Submit **one** approved, bounded, already-signed native-REV test deploy once; poll its ID on all reachable validators every **5 seconds** | Raw redacted submission response; `/api/v1/deploy-status/{id}`; `/api/v1/deploy-settlement/{id}`; `/api/v1/finality-observation`; `/health` | Acceptance alone never marked settled; if `pooled` is seen, it is recorded as pending |
| A2 — inclusion before finality | Continue 5-second samples until inclusion/terminal verdict or approved end of window | Inclusion block hash, height and timestamp; `ProcessedWithSuccess/Error`, `includedUnfinalized` / `finalityUnknown`, `settlementConfirmed`, local and independent finalized frontiers | No `settlementConfirmed=true` for an inclusion block lacking verified finality |
| A3 — finalized and cross-checked | Continue at 5-second cadence until test deploy reaches `finalizedSuccess` (or an explicit failure/timeout); observe 60 more seconds after finalization | `finalizedSuccess` and `settlementConfirmed=true`; inclusion block finalized on independently queried validators with consistent finalized hash; finality frontier and sample IDs | PASS only when the transfer is genuinely finalized; execution success is insufficient |
| A4 — recovery/retention check | Read-only audit of all submitted IDs and previously pooled work before and after the window | No missing accepted deploy, consistent finality observations, no false settlement, final raw captures | Evidence-only confirmation; do not force a network disruption to manufacture recovery |

**Sampling and event model.** Capture the state transition as an ordered event stream with independent UTC timestamps on **each** node and the client. Persist HTTP status and response bodies, headers, observations, block identities, request IDs, boot IDs, node identity and endpoint version for each 5-second sample. Correlate by the **exact deploy signature/id and inclusion block hash**, not by balances or a coincidental block number. Sample all four; if a validator is inaccessible, state that explicitly instead of silently counting fewer.

**Proposed maximum observation window:** 15 minutes after the single authorized submission (plus baseline/post-finalization samples), subject to maintainer pre-registration. At timeout without positive finalization, record **INCONCLUSIVE / NOT ACCEPTED**, not PASS. If A1 or A2 transition occurs between polls, retain the adjacent samples and mark the unobserved stage as **not directly observed**; do not fabricate a pooled or unfinalized observation. If the acceptance criterion requires direct proof of an intermediate state and it was missed, that arm is inconclusive. Do not submit extra deploys simply to manufacture a missing stage without another approved plan.

**Negative safety check:** Throughout A1–A4, all observed stages except `finalizedSuccess` with confirmed inclusion must have `settlementConfirmed=false` (or explicit unknown) and must not be shown as settled by the test client. Fail closed on inconsistent responses; do not trust tip balance alone.

## 3. Abort, containment and rollback

Immediately stop further submissions and mark the run **ABORTED / FAIL-SAFE** if any of these is seen:

1. Any `finalizedSuccess` / `settlementConfirmed=true` without verified finality of the **same inclusion block**, or conflicting finalized hashes at an identical finalized height across validators.
2. A test-client message claiming settlement from `ProcessedWithSuccess`, pool admission, tip balance, or `acceptsDeploys` alone.
3. One or more validator identities unexpectedly absent; version/genesis/bond drift; unstable finality/liveness; or observations too stale to distinguish progress.
4. An unexpected validator restart, repeated 5xx, evidence-capture failure, signing-authorization failure, malformed/duplicate deployment, unexpected fee/amount, or any breach of pre-agreed operational limits.
5. A maintainer/operator withdraws approval, the window expires, or the approved rollback condition is reached.

**Abort is not a consensus rollback.** Halt test submissions, preserve accepted deploy IDs and the full evidence record, and notify Jim/Patrick. Keep all four validators' data volumes intact. Do not delete/rebuild state, restart validators, revert a finalized transfer, or make network changes under this document.

If an operator-approved binary/configuration rollback becomes necessary, only the designated maintainer executes the separately pre-approved rollback procedure on the approved target/region, after confirming that state compatibility, snapshot retention and capacity are safe. If rollback cannot be executed safely, leave systems stable and escalate; never improvise a destructive restore. Record every operational action with timestamp and actor.

## 4. Evidence deliverable and independent human verdict

Publish a **redacted, reviewable** run record in `spec/audit/evidence/n487-live-postdeployment-<UTC-date-or-run-id>/` using the repository's `tools/evidence-pack.py` where applicable, with at minimum:

- `README.md`: exact scope, human verdict, complete preflight pins, arms, observation times, limitations, non-claims, and any abnormal events.
- `manifest.json` (`schema: 1`, `execution_proven: false`) and matching `SHA256SUMS.json`, checked by `python3 tools/evidence-pack.py verify --record <record>`; a conventional `SHA256SUMS` may be retained as well.
- Source SHA, release/image/binary hashes, associated CI artifacts, genesis/bond digests, immutable four-validator membership, and operator/independent reviewer identities (redacting private endpoints/credentials).
- Timestamped raw, redacted samples for `/health`, `/api/v1/finality-observation`, `/api/v1/deploy-status/{id}`, and `/api/v1/deploy-settlement/{id}` from all four validators, with gap/timeout information. Save the raw submission receipt and digest of the signed deploy without publishing signing material.
- Inclusion block identity, finalized frontier/hash, explicit observed transitions, the negative safety assertion (never falsely settled), and post-window accepted-work audit.
- Approved run window and go/no-go record; action log, abort/rollback decision and outcome, if applicable. Retain raw source securely and publish only reviewed redactions.

**Do not call the record PASS because the digests verify**: the hash index attests file identity only. The reviewer must check the actual observed events independently and write a human verdict against the frozen criteria.

### Decision table

- **PASS — live #487 gate:** preflight matches pins; exact current release binary is deployed to all four authorized validators; the approved native-REV deploy is actually observed through the required stages; the inclusion block is independently verified finalized; no premature settlement or lost accepted work; raw evidence is complete and reviewer signs off.
- **FAIL:** a demonstrated safety or contract violation, especially premature settlement, contradictory finalized identity or confirmed loss of accepted work.
- **INCONCLUSIVE:** missing stage sample, missing validator/evidence/pins, no finalization within approved window, observer disagreement or stale data. Never re-label as PASS.
- **ABORTED:** window or operational safety abort before an admissible verdict.

Only after an independent maintainer reviews the **live** record against this document may #553 be closed. A green CI badge, the n487 DevNet result, or merged #557 **alone** does not establish public-network release acceptance.

## 5. Responsibility and immutable boundary

- **Before the run:** Jim/Patrick approve source/binary pins, four-validator identities and stakes, authorized test deploy, UTC window, rollback owners and this exact acceptance matrix. Freeze this runbook revision as the scoring baseline.
- **During the run:** designated operator executes only pre-approved actions; evidence observer collects all four validators' data. Aria may prepare scripts or review evidence **without operating public validators**.
- **After the run:** publish hashed evidence and human verdict in a **separate evidence PR**. If the run reveals a software defect, create a **separate fix PR**; do not amend the pre-registered criteria after observing the outcome.

**Explicit non-claims:** This draft contains **no live-run result**, no current release pin, no authorization, no public transaction, no live testnet changes, and no #553 closure.
