# m5-06-m5-04-20261113

**Evidence locality.** `local-devnet`

## Scope

Component-test verification of the landed M5-06 (tuple-space counterpart to I2: every kept chain's
datum/kont change appears in the combined batch) and M5-04 (`final_scope_rejected_deploys`; fringe
slot winners) on the integrated tree. It does **not** recompute the live 840→841 merge, which remains
blocked on M5-01's authenticated bundle.

## Provenance

| | |
|---|---|
| gate | `M5-06-M5-04` |
| source | `71e71f886af0aac17318752091b1cde3780bb524` |
| binary | `5f31e89c840b1b188cc1784f6860da8f4ef18a61f1f83c4724628aecbaf3322a` |
| run | local `cargo test`, 2026-11-13 — no actions URL; the logs and `raw/readout.md` carry the suites and results |
| packaged | `2026-11-13T14:49:34+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

Both suites pass on the integrated tree: `casper/tests/n420_boundary_merge.rs` **7/7** and the
`merging` library tests **51/51**, including `a_boundary_round_does_not_lose_a_contained_deploys_charge`
(M5-04), `a_boundary_round_merge_keeps_the_base_states_user_write`,
`merging_a_tuple_space_rmw_block_duplicates_its_produce` and the native-merge pairs. The code landed
in `9d985fc1a`; this run is the merged-tree verification. `raw/n420_boundary_merge.log` and
`raw/merging.log` are the raw outputs; `raw/result.txt` is PASS.

## What this does not establish

Component tests only. The M5 gate is not closed: the historical four-parent 840→841 Root/merge
replay still needs M5-01's authenticated source bundle, M5-02's merge-replay surface and M5-03's
per-chain fates DTO. This record covers the landed code on a local tree
(`execution_proven:false`); it is not a candidate-binary or live-state result, and the synthetic
fork-point/hot-cell witnesses do not substitute for the historical replay.

## Reproduce

From the repository root at the pinned source:

```sh
cargo test --locked -p rchain-casper --test n420_boundary_merge
cargo test --locked -p rchain-casper --lib merging
python3 tools/evidence-pack.py verify --record spec/audit/evidence/m5-06-m5-04-20261113
```
