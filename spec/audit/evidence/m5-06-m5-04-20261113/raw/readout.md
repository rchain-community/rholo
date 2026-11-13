# M5-06 / M5-04 verification — component tests on the integrated build

**Question.** The M3×M5 Pareto review (`spec/audit/evidence/m3-m5-pareto-20261101/README.md`) ranked
M5-06 (the tuple-space counterpart to I2: every kept chain's datum/kont change appears in the combined
batch) and M5-04 (`final_scope_rejected_deploys`, fringe slot winners) as the highest reward/risk M5
pieces. Both landed in `9d985fc1a`; this run verifies them on the integrated tree. It does **not**
recompute the live 840→841 merge, which remains blocked on M5-01's authenticated bundle.

**Source:** `71e71f886` (dev `8cea0db` plus the C357-arm evidence commit).
**Test binary:** `n420_boundary_merge` `sha256:5f31e89c840b1b188cc1784f6860da8f4ef18a61f1f83c4724628aecbaf3322a`.

| suite | result |
|---|---|
| `casper/tests/n420_boundary_merge.rs` | **7 passed** |
| `casper` lib `merging` tests | **51 passed** (includes `a_boundary_round_does_not_lose_a_contained_deploys_charge`, `a_boundary_round_merge_keeps_the_base_states_user_write`, `merging_a_tuple_space_rmw_block_duplicates_its_produce`, the native-merge pairs) |

Logs are `n420_boundary_merge.log` and `merging.log`; `result.txt` is the arm verdict.

**Scope.** Component-test verification only. The M5 gate is not closed: the historical four-parent
840→841 Root/merge replay still needs the authenticated source bundle (M5-01), the merge-replay
surface (M5-02) and the per-chain fates DTO (M5-03). This record is `local-devnet`,
`execution_proven:false`, and covers the landed code, not a candidate binary or live state.
