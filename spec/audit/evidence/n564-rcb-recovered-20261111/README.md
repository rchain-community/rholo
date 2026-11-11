# #564 RC-B: exact historical reproduction and replay-order correction

The Nov8 incident's exact **5576-versus-5302** per-deploy mismatch is reproduced from authenticated BYOID deploys and complete Merkle-verified historical state. Both original declared post-state hashes reproduce, three times each, on incident source `0a1e02362a7c34e474e068ffd47469c8d4be707a`.

**Cause:** `RSpace` prepends trace events. `ReplayRSpace::build_replay_data` appended COMMs from that newest-first log into candidate lists. Several pending requests on one persistent contract could therefore be selected in reverse execution order. A later request's inner peek requires a later recorded repetition counter of the same nonpersistent state datum. The replay takes unmatched paths, evaluates less work, and the strict cost guard correctly refuses the different cost.

**Single-variable intervention:** iterate the COMM-binding construction over `log.iter().rev()`. Records, costs, refunds, statuses, counter guards and unused-COMM/state checks are preserved. Both historical cases then strictly accept at the original costs and original post-state roots. The existing trace-corruption controls retain their failures; all192 RSpace tests pass on the incident source.

## Experiment identifiers

The global shared matrix M21–M24 is unchanged. Earlier trace-deletion **raw local M21** is **A-M21**; this pack uses **RCB-R22–RCB-R30** for raw local M22–M30. Logs, Rust test names and original bytes retain their original labels. See `EXPERIMENT_IDS.json`.

## Executed evidence

| Experiments | Run | Result |
|---|---|---|
| RCB-R22–RCB-R24 | [43098851150](https://github.com/aixaria0/rchain-rust/actions/runs/43098851150) | All six production signature checks and tamper controls; repeated synthetic controls. |
| RCB-R25 | [43100598230](https://github.com/aixaria0/rchain-rust/actions/runs/43100598230) | Original unmodified source, exact historical cost mismatch and both declared post-state roots. |
| RCB-R26 | [43101149837](https://github.com/aixaria0/rchain-rust/actions/runs/43101149837) | All274 phlo accounted for; observer ON/OFF preserves results. |
| RCB-R27–RCB-R28 | [43101946226](https://github.com/aixaria0/rchain-rust/actions/runs/43101946226) | Ordering intervention succeeds; strict controls retained;192 RSpace tests pass. |
| RCB-R29–RCB-R30 | [43108778606](https://github.com/aixaria0/rchain-rust/actions/runs/43108778606) | SUCCESS: regression fails before and passes after; historical cases correct;193 RSpace tests and cost register pass. |

`RUNS.json` pins every harness commit, source and job. The logs are committed intact; the diagnostic observer and one-line intervention patches are retained.

## Recovered inputs and limits

- Five signed deploys are contiguous original protobuf records; offsets and hashes are in `carved-candidates.json`.
- The first failing `dd2d…` payload is an **authenticated reconstruction**, using its original signature and an explicit metadata search. Its overwritten raw tail is not claimed to have been recovered. See `dd2d-reconstruction-result.json` and `dd2d-partial-record-provenance.json`.
- `deploys/historical-state.bin.gz` contains only the content-addressed closure of both pre-states, the1073 fringe, and both declared post-states:52 history nodes and252 cold leaves. Every payload hashes to its key. Full root provenance is in `historical-state-provenance.json`.
- `incident-log-excerpts.txt` identifies the first1073 refusal at17:36:26.483Z, earlier than the originally reported1115 refusal at17:37:58.044Z. Both exact block hashes and roots are retained.
- The rejected block bodies and original serialized processed traces were not recovered. RCB-R25–RCB-R27 **regenerate** the trace. Timestamp/sequence/context substitutes are printed explicitly; the block seed's actual shard, height, proposer and pre-state are recovered. RCB-R27's timestamp variants preserve both original post-state roots.
- Original raw logs/database copies remain private. No validator database was opened through LMDB or modified. Published input state is limited to named public testnet roots; raw free pages and unrelated records are excluded.

## Reproduce

Use the immutable harness commit in `RUNS.json` for each experiment. Its workflow checks out the pinned source before adding the test harness. The compiler is Rust1.95.0, dependencies are locked, and protoc21.12 is checksum-pinned.

The following commands apply inside the prepared disposable checkout:

```bash
cargo +1.95.0 test --locked -p rchain-casper --test omega_rcb_recovered omega_m22 -- --nocapture --test-threads=1
cargo +1.95.0 test --locked -p rchain-casper --test omega_rcb_recovered omega_m25 -- --nocapture --test-threads=1
```

RCB-R26 adds only `apply_cost_observer.py` to the original source. RCB-R27 instead adds only `apply_replay_order_correction.py` and runs `omega_m27`. These are separate interventions; do not leave the observer applied when claiming the single-line correction diff. See the retained workflow/patches and the source-commit assertions.

To authenticate the contiguous payloads independently, with Python's `cryptography` package installed:

```bash
python3 verify_state_fixture.py .
python3 verify_carved.py .
python3 reconstruct_dd2d.py --lower 1794159381000 --upper 1794159382999 --limits 5000000,10000000,1000000 --heights 1070,1071,1069,1072 --output /tmp/n564-dd2d-reconstruction
```

An authorized holder of the preserved raw deploy-pool copy can independently re-extract all indexed contiguous occurrences:

```bash
python3 carve_from_index.py /path/to/private/raw-copy.mdb --output ./carved-signed-deploys
```

The raw-copy digest must equal the recorded digest before extraction proceeds. `carve-integrity-check.json` records a completed re-extraction of every indexed occurrence.

## Source-test provenance

The previous current-source run43104341321 did not execute tests: attempt1 failed to acquire a runner; attempt2 failed during shallow-checkout setup. Both receipts are retained. The workflow now fetches the pinned base before comparison. Run43108778606 succeeded with the unchanged production correction. Its artifact manifest was checked before import; corrected source and regression bytes exactly match this branch. The synthetic four-request regression is4844/4554 before the correction; zero/one request controls pass. After the correction all three pass, and both historical cases strictly replay to their original costs and roots. The current RSpace suite has193 passing tests.

This is a source-pinned test evidence pack. Executable binary SHA-256 was not captured; no binary-pinned execution or project evidence-pack.py invocation is claimed. SHA-256 verifies the bytes retained here, not the truth of an assertion by itself.

## Verification boundary

The actual historical states and exact costs are now recovered/reproduced. The original rejected block bytes remain unavailable. Green isolated tests are not a complete formal proof or a live finality drill. The one-line change still needs independent consensus/compatibility review and an approved rollout. Issue564 remains open.

RCB-R28 retains the pre-existing A-M21 boundary: removing a standalone Produce event is accepted for these fixtures; deleting COMM/Consume causes the recorded cost/status failures. This pack does not claim rejection of every possible trace mutation.

— Ω-WITNESS
