# #583 acceptance: covered-replay freshness and a first-observed work age

**Source under test:** `2fe16f1630458b3c14344137616f3c5353db42bd`. The evidence commit that adds this
file is later and changes only docs/evidence.

**Image:** `rnode:local`
`sha256:14bca1377cacdb9c79ff57d6e43c7f72ea3212aadd02f41e887ca77fa5be161d`, built from that head by
`tools/devnet.sh build`. The N=4 runner records the same source in
`ci-n4-43518312643/final-gap-image/source.txt`.

## Red before, green after

Both falsifiers were committed against a behaviour-preserving harness (U1, `7426d479f`), so the red
run is a failing assertion, not a compile error; the test names below are the final ones.

| Property | Fails pre-fix | Passes post-fix |
|---|---|---|
| **C372** — a block strictly below the closed round, with its parents in the boundary's causal past, is history | `red/a-covered-replay.log` | `green/a-covered-replay.log` |
| **C373** — work first seen at tip 33 is licensed at 48 and refused from 49; no fringe advance or re-observation renews it | `red/b-work-age.log` | `green/b-work-age.log` |

Controls in the green runs: `expired_work_does_not_mask_newer_work`,
`an_unreadable_store_withholds_the_prompt_licence` (including the low-tip edge) and the work-seen
store's reopen test (`green/work-seen-store.log`); the in-process quiet-chain model carries the same
first-observed age (`green/quiet-chain-model.log`).

## N=3 rejoin — the #223 regression (local disposable Docker)

`OUT_ROOT=… CAP=8g spec/audit/evidence/n223-rejoin-run.sh`, source head above.

Run root: `n3-rejoin/2fe16f163-20261113T222209Z/` (manifest with head + image ID, sampled series,
per-node logs, block table, refusals).

- **R1 PASS** — `devnet-validator-2` reached height 12 after returning (the survivors were at 11).
- **R2 PASS** — a deploy sent to the returner afterwards is in finalised block `ed154576`.
- **R3 PASS** — zero `missing justification` refusals on the returner.

This is the live-verified shape `work_age_floor` existed to license; the first-observed age keeps it.

## N=4 quiet finality + partition/rejoin (source-pinned disposable GitHub runner)

`gh workflow run devnet-fuzz.yml --ref fix/583-attestation-policy -f mode=final-gap-recovery -f
recovery_case=n4`; run **43518312643**. The job builds at the dispatched head, records the source and
image pin, and runs `consensus-acceptance-drill.py --validators 4` and
`consensus-partition-rejoin.py --validators 4`.

- **`n4=0`** — the signed marker is present in finalised state on all four validators (height 2,
  hash `992b18ec…`) and retained through two further epoch boundaries
  (`ci-n4-43518312643/final-gap/n4-campaign.log.gz`).
- **`n4-partition=0`** — the partition/rejoin arm
  (`ci-n4-43518312643/final-gap/n4-partition-campaign.log.gz` and its observations).
- Exit codes: `ci-n4-43518312643/final-gap/exit-codes.txt.gz`; per-validator logs and inspect dumps
  are in the same directory, gzipped. The full uncompressed artifact (89 files) is GitHub artifact
  `final-gap-real-nodes-43518312643`.

## What the arms do not cover

No live deployment, public validator or key use; no consensus, block-validity, stake or quorum
change. These runs are not evidence for #428's M1–M6 or #584's frozen live four-validator gate
(G1–G6), which are separate. The N=3 arm is local Docker with an 8g per-node cap; the N=4 arm is the
repository's own disposable runner job.
