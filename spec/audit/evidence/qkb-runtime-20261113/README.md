# QKB runtime conformance for QLF #216

The unmodified QKB contract at QLF `7667443c7feb14efeb01aa50b86171be0cd38f0a` passed functional signed-deploy
conformance on Rholo `79e550400114b32a0292b9103cb5e83c6e1e1c72`. A separate fresh-node run matched all
968 proposition comparisons. All 384 native-positive length-four gate vectors also matched;
the larger combined execution then exceeded a 90-second propose budget. That TIMEOUT is retained,
not reclassified as a passing run. No contract or production Rust change was made.

This is the execution handoff requested in
[Rholo #24](https://github.com/rhovision-org/rholo/issues/24#issuecomment-6856246997)
for [QLF #216](https://github.com/rhovision-org/quantum-logical-framework/pull/216).

## Merged-head continuation

While these independent checks were running, Jim merged QLF #216 at head
`4bbe2012292ad40d1e01726bd24929f5a7ceb596`. Its only executable QKB change is the
empty/nonempty list-pattern spelling in `validTwists`; the Python reference change is a
docstring, and `twist_core.py` / `qucalc_search.py` are unchanged.
A separate execution on that exact merged head passed **93/93
functional groups**. Its [CI run](https://github.com/aixaria0/rchain-rust/actions/runs/43474233580),
[report](merged-report.json), [raw receipts](raw/merged.tar.gz), [workflow](merged-workflow.yml)
and [source delta](merged-source-delta.patch.gz) are retained.

The exhaustive matrices below were executed at the earlier pinned QLF revision; they are
not represented as executions of the later contract bytes. Both contract spellings parsed
on the Rholo executable used here. Jim's acceptance record used a different runtime binary.

## Completed checks

| Component | Observed result |
|---|---|
| Functional signed-deploy suite | **93/93 groups PASS**, plus the signed installer |
| Registry | Original contract publishes a send-only service; subsequent, separately signed deploys look it up and call it |
| Native identity | Repeated key stays one holder; a second real signing key raises R to two; a fresh unforgeable name is refused |
| Questions | Answer-before-ask, replayed ask, context separation and unrelated-name namespace counterexample match the reference |
| Input validation | Histories, contexts, questions and compound propositions return controlled refusals |
| Solver | Five seeds, competing continuations submitted out of priority order, result agrees with `qucalc_search.solve` |
| Per-axis admission | All **384** native-positive length-four histories: **168** admitted; all **216** aggregate-only histories refused |
| Logic matrix | All **484** ordered pairs of **22** propositions under both compatible and conjoin: **968** comparisons PASS |
| Negative control | Removing only the per-axis guard makes `^^<<` incorrectly pass; the comparator detects it at the intended case |
| Python reference | Unmodified self-checks **(a)–(j)** PASS |

The native `rho:qucalc:zfa([0,0,3,3])` returned `(true,1)`; QKB refused the same
`^^<<` history with the expected residual. Native aggregate semantics were measured, not changed.
The gate census used 12 separately installed QKB instances with 32 histories each.
The successful full logic run used a fresh node and 16 comparisons per signed deploy.

The sharding simulation (f) and mutable queued callbacks (j) remain Python-only. The actual
Rholang contract has one state cell, and Rholang values are immutable.

## Timing boundary

Two growing shared-store runs stopped at a 90-second `rnode propose` budget after **98** and
**97** completed, matching groups. The next run installed separate bounded gate instances:
all 12 gate batches completed, as did two 96-comparison logic batches, before another propose
timed out (**107** completed, matching groups). No result after the timeout is claimed.

The fresh-node functional and smaller-transaction logic runs pass. They establish component
conformance; they do **not** establish that the larger combined workload meets the 90-second
budget or that the contract is ready for production load. These observations do not by themselves
prove a deadlock, permanent stall or root cause.

## Evidence

- [Pinned executable build](https://github.com/aixaria0/rchain-rust/actions/runs/43466083379)
- [Functional, fresh-node logic and negative control](https://github.com/aixaria0/rchain-rust/actions/runs/43473311631)
- [Completed gate census and retained combined TIMEOUT](https://github.com/aixaria0/rchain-rust/actions/runs/43470345603)
- [Exact pins and scope](pins.json), [functional report](functional-report.json),
  [logic report](logic-report.json), [combined report](combined-report.json),
  [negative control](negative-control.json) and [one-condition mutation](guard.patch)
- [Functional receipts](raw/functional.tar.gz), [logic receipts](raw/logic.tar.gz),
  [negative receipts](raw/negative.tar.gz), [combined receipts](raw/combined.tar.gz),
  [shared-store timeout 1](raw/shared-timeout-1.tar.gz) and
  [shared-store timeout 2](raw/shared-timeout-2.tar.gz)
- [Acceptance workflow](acceptance-workflow.yml), [combined workflow](combined-workflow.yml),
  [build workflow](build-workflow.yml)

QLF contract copies in the raw terms retain the [MIT source notice](QLF-LICENSE).

Each completed group retains the signed term, deploy identity, carrying-block receipt and
post-state result. Receipt verification checks exact term inclusion, signature identity,
`errored:false`, carrying block identity and the recorded Boolean comparison.
Run metadata is retained beside the raw archives. Run 43468527888 was a workflow-format setup
failure and supplied no execution result; it is retained as such.

## Reproduce

Use an isolated Linux host with Python 3 and `pycryptodome==3.23.0`. Fetch the exact QLF revision
above into a separate checkout. Download `qkb-rnode-79e5504` from the build run and run:

```sh
python3 tools/qkb-runtime-conformance.py \
  --rnode /absolute/path/to/rnode \
  --expected-binary-sha256 2cffda31f4d7d03cb2e7644340449d153da40e9e5db39f5b4c407791c6504201 \
  --rholo . --qlf /absolute/path/to/pinned-qlf \
  --contract /absolute/path/to/pinned-qlf/rholang/QKB.rho \
  --suite functional --out /absolute/path/to/fresh-functional-receipts
```

Repeat with `--suite logic --logic-batch-size 16` and a different fresh output directory.
The archived workflow provides the exact negative-control command. `--suite all` preserves the
combined workload shape, whose timing limit is recorded above.

The harness starts its own loopback-only standalone node, uses public disposable devnet fixtures,
funds two signing identities and removes its temporary validator key file. Existing node-data
directories are refused. Reads are pinned to actual inclusion-block post-states.

Verify the retained pack from the repository root with:

```sh
sha256sum -c spec/audit/evidence/qkb-runtime-20261113/SHA256SUMS
```

## Scope

Ephemeral single-validator developer-mode nodes, no peers, debug executable on hosted runners.
This is implementation evidence for QLF #216, not multi-host, cross-shard, performance, mainnet or
release acceptance. No public validator was contacted. Byte manifests establish retained file
identity; `execution_proven:false` and independent maintainer review remain explicit.
