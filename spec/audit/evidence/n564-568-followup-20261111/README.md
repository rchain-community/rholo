# Rholo #568 — recovery review and RC-B follow-up

**Assessment: request changes before treating the recovery close-out as verified.**
The follow-on implements the missing recovery exits and its existing focused tests pass. The
review found a reset-history read-error path that can defeat the one-reset bound, reproduced a
false durable-body availability reading, and could not verify the committed live-drill pack
because thirteen listed logs are absent. These findings do not establish that the reported local
drill was not run.

## Sources and verification scope

- Reviewed application source: [`4be008d3df9ecec25162dc01f2843e57bba2b17e`](https://github.com/rhovision-org/rholo/commit/4be008d3df9ecec25162dc01f2843e57bba2b17e), PR [#568](https://github.com/rhovision-org/rholo/pull/568).
- The subsequently inspected [`cd56dfb`](https://github.com/rhovision-org/rholo/commit/cd56dfb59883397daffc4697057ab6e9d2a05e80) changes the apt helper; it does not change the reviewed recovery implementation.
- Request and ownership context: [Patrick's #564 comment](https://github.com/rhovision-org/rholo/issues/564#issuecomment-6799852722).
- Independent fork execution: [run 43054121454](https://github.com/aixaria0/rchain-rust/actions/runs/43054121454/job/130638879775), workflow commit [`096433d`](https://github.com/aixaria0/rchain-rust/commit/096433d35fe8f474f5677ad840cd187fb35aab03).
- Rust 1.95.0; official protoc 3.21.12 with the observed release-download SHA-256 pinned; two build jobs and test threads, debug information disabled. No upstream CI workflow or live validator configuration was changed by this work.
- The downloaded run artifact's SHA-256 was independently matched to GitHub's reported digest: `84404b354ef1409940a1e1b98c33f79594dfb5c1e4ede911e0705124ce8fb4ef`.

**VERIFIED** below means inspected source or the named execution/receipt. A source-derived failure
sequence is distinguished from an executed regression. None of this is an implementation-refinement
proof or universal operational verification.

## Findings

### P1 — an unreadable reset history becomes a fresh reset allowance

**VERIFIED source flow; the multi-reset failure sequence is a SUPPORTED INFERENCE, not a completed
network fault-injection drill.** The new loader [returns `None` on a storage read error](https://github.com/rhovision-org/rholo/blob/4be008d3df9ecec25162dc01f2843e57bba2b17e/casper/src/blocks/proposer/proposer.rs#L1612).
The refusal arm then [defaults the carried attempt to `(false, None)`](https://github.com/rhovision-org/rholo/blob/4be008d3df9ecec25162dc01f2843e57bba2b17e/casper/src/blocks/proposer/proposer.rs#L825)
and persists a fresh `Refused` record before the recurrence check.

A previous `Recovered` record can already say that anchor A had its reset. If that read fails once
and the subsequent write succeeds, the fresh record overwrites that history. A second attestation
failure at unchanged anchor A consequently reaches the reset closure as an unattempted anchor.
This defeats the proposed one-reset-per-anchor guarantee precisely on the unknown-history path.
The separate [reset-request write-error arm](https://github.com/rhovision-org/rholo/blob/4be008d3df9ecec25162dc01f2843e57bba2b17e/casper/src/blocks/proposer/proposer.rs#L1543)
also continues to raise a reset after its durable attempt record fails to write.

Required correction: preserve read errors distinctly from `Ok(None)`, keep the prior record intact
when its history is unknown, and prevent a fresh destructive reset without a successfully recorded
attempt. Add regressions for a failed history read and a failed attempt write. Successful-store
tests and the abstract Law 94 transition table do not discharge those I/O cases.

### P2 — `refusedBodyAvailable=true` survives complete persistence failure

**VERIFIED by an executed counterexample.** The refusal sink receives
[`record.body.is_some()` before persistence](https://github.com/rhovision-org/rholo/blob/4be008d3df9ecec25162dc01f2843e57bba2b17e/casper/src/blocks/proposer/proposer.rs#L867).
The [failed-write arm](https://github.com/rhovision-org/rholo/blob/4be008d3df9ecec25162dc01f2843e57bba2b17e/casper/src/blocks/proposer/proposer.rs#L893)
logs the error but does not correct that availability reading. Yet the
[field's contract](https://github.com/rhovision-org/rholo/blob/4be008d3df9ecec25162dc01f2843e57bba2b17e/casper/src/api/block_api.rs#L149)
says it describes the durable record.

The test uses the real proposer recovery path and its existing fixture, with a persistence callback
that always returns an error. Both writes fail. Attestation recovery succeeds, while the surviving
operator refusal says:

```text
OMEGA_OBSERVATION failed_writes=2 refusedBodyAvailable=true refusedBodyLen=363
```

The desired false-availability assertion fails with exit 101: **0 passed, 1 failed**. The execution
checks for that exact assertion, rather than accepting a compilation failure. The original source
is restored afterwards. See [the receipt](availability-negative.json) and [the raw test output](availability-negative.txt).
This is an injected callback failure, not a physical disk or crash test.

Required correction: confirm the availability field only after a successful write/read, or expose
an explicit unknown/durability state. The true body length can remain available independently.

### P2 — thirteen files required by the live-drill manifest are not committed

**VERIFIED on a fresh checkout.** Of the [manifest's 35 files](https://github.com/rhovision-org/rholo/blob/4be008d3df9ecec25162dc01f2843e57bba2b17e/spec/audit/evidence/n564-self-replay-recovery-drill-20261111/manifest.json),
22 are present and match their digests. Thirteen are absent: all nine node logs, the three `up.log`
files and `raw/run.log`. The repository's `.gitignore:86` rule, `*.log`, matches the missing node log.

The advertised command returns exit 1:

```text
python3 tools/evidence-pack.py verify --record spec/audit/evidence/n564-self-replay-recovery-drill-20261111
FAIL  missing file: raw/arm1-attestation/devnet-bootstrap.log
```

See [the independent pack check](pack-check.json). Publish the actual missing files, or a complete
accessible archive with its manifest, and verify a fresh checkout/download before closing the live
evidence debt. No missing log was reconstructed or substituted in this review. The present JSON
snapshots corroborate fault/surface states, but they do not replace the missing chronological logs.

## What passed, and how #567 relates

| Execution | Observed result |
|---|---|
| #568 self-replay unit witnesses | 8 passed |
| Existing same-anchor recurrence decision test | 1 passed |
| #568 reset integration suite | 13 passed |
| Failed-storage availability regression | Intended assertion failure; confirms the finding above |
| #568 plus #567's two Rust-file changes | **16 reset tests passed**, including missing-body refusal and the LMDB reopen case |

The combination applies only the Rust diff from #567 source `1d17ebc` over the reviewed #568 source.
It does not claim that a full branch merge was performed. An independent `git merge-tree` check
found content conflicts in `spec/AUDIT.md`, `spec/audit/passes.md` and `spec/findings.tsv`; both
branches also use pass 156. The Rust files merge automatically. The authored register and pass
references need reconciliation, followed by regeneration of `AUDIT.md`.

**#567 remains complementary.** #568's reset inventory still enumerates surviving body-store keys;
it does not include #567's DAG-inventory correction. A missing DAG body must remain a reset refusal.
See [the combined reset output](combined-reset.txt) and [the exact applied Rust diff](c366-rust.patch).
Neither upstream PR was merged or approved by this work.

## RC-B — the requested observation and additional original-source measurements

### Validator A: current runtime, not November 8 configuration

**VERIFIED, read-only at 2026-11-11 16:07:17 UTC**, using the existing operator SSH/service mapping.
On-chain validator identity was not re-attested. [The observation](runtime-A.json) records:

- Running executable SHA-256: `a07d41aa010e446c95f59cf2764cccc3a63070410ee6c314487617b0057897fd`.
- Its `--version` first line reports `rnode 0.1.0 (0a1e02362a7c34e474e068ffd47469c8d4be707a)`. This is a binary self-report, not a signed build-provenance proof.
- No `RNODE_CROSS_DEPLOY_BATCHING`, `RNODE_CROSS_DEPLOY_BATCH_VERIFY` or `RNODE_CROSS_DEPLOY_BATCH_MAX` in the running process or current unit environment; no explicit effect-scheduler CLI flag.
- A's process started **2026-11-10 13:52:19 UTC**, after the incident began.
- A bounded historical journal query for batch/scheduler messages returned no matches. It does not establish the old settings.

A configuration file can set `casper.effect-scheduler` even when the CLI flag is absent, as the
[incident options](https://github.com/rhovision-org/rholo/blob/0a1e02362a7c34e474e068ffd47469c8d4be707a/node/src/configuration/commandline/options.rs#L254)
specify. A separate read at **16:16:53 UTC** found the explicitly selected config file present,
with no scheduler literal and no leading include directives; its reported mtime was October 29.
Together with the absent CLI flag, this **SUPPORTS the default `dfs`/Sequential reading** under the
[source fallback](https://github.com/rhovision-org/rholo/blob/0a1e02362a7c34e474e068ffd47469c8d4be707a/node/src/configuration/hocon.rs#L486).
It is a selected-file observation, not a dump of the running configuration or proof of its past
contents. The unsafe batch combination is not present in the observed process; the configuration
on November 8 remains **OPEN**.

### M15: transient communications on the incident source

The same fork run checks out **`0a1e02362a7c34e474e068ffd47469c8d4be707a`** and leaves every tracked
production file unchanged. The only addition is [this integration fixture](omega_rcb_m15.rs),
adapted from the existing incident-matrix harness. It uses in-memory runtime fixtures and opaque
signature bytes; no authentication or original incident-state claim is made.

| Fixture | Recorded play costs, per deploy | Strict replay and post-state |
|---|---|---|
| Transfer + `Nil` control | `[984, 3]` | Accepted; matching state |
| Failed COMM control | `[599]` | Accepted; matching state |
| Transfer / transient COMM / transfer | `[984, 444, 984]` | Accepted; matching state |
| Transfer / two transient COMM steps / transfer | `[984, 926, 984]` | Accepted; matching state |
| Transfer / failed transient continuation / transfer | `[984, 1081, 984]` | Accepted; matching state |

All three test functions pass; the M15 function exercises three variants. The failed continuation
is asserted failed with a non-empty recorded trace. [Raw output](incident-m15.txt) and
[source/probe receipt](incident-probe.json) preserve the
result. These are negative reproductions within this fixture set. No category census was run, no
trace-mask hypothesis was exhausted, and the incident's missing terms/pre-state were not recovered.
**The cause of the 274-phlo discrepancy remains OPEN.**

## Decision

The recovery additions and C366 compose at the tested Rust boundary. Keep #567 Draft, preserve its
missing-body guard, and address the three review findings before accepting the claimed recovery
close-out. RC-B proceeds from the current-runtime observation and the bounded negative M15 result;
neither is a diagnosis of the historical trigger. The primary CI/formal runs on `cd56dfb` were still
in progress when checked; the successful fork run is the focused execution described above.

— Ω-WITNESS
