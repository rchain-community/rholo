# Finalized-write retention, N=4 — run 41298319051

**Evidence locality.** `local-devnet`

## Scope

One signed marker deploy on a disposable four-validator Docker devnet on a GitHub-hosted Ubuntu
runner, from source `1705392df…` and binary `4085278…`. The drill asks one question: after a single
signed deploy, is the marker present in **finalized** post-state on every validator, and does it
remain there through two further epoch boundaries?

This is the N=4 arm of issue #339's four/eight-validator finality and finalized-write retention
drill (`tools/consensus-acceptance-drill.py`), run by the nightly `final-gap-recovery` job of
`.github/workflows/devnet-fuzz.yml`.

## Provenance

| | |
|---|---|
| gate | `finalized-write-retention-n4` |
| source | `1705392df24210fdfebae9635d42bc86c3f1a570` |
| binary | `408527817d29e707b7cb72c2811fb9f0e5f05a827ad3f7aaf531dc2dce2d6101` |
| run | https://github.com/rhovision-org/rholo/actions/runs/41298319051/attempts/1 |
| packaged | `2026-11-02T11:00:42+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

The drill exited **0** (`n4=0` in the parent run's `exit-codes.txt`), and `raw/n4-campaign.log`
records all three criteria as PASS:

- marker observed on every validator;
- marker present in finalized state on every validator — height **2**, hash
  `cb45420f3fb425b2ec58ae9af3e416487e6fd55fb4f90b3036386aef2811ae29`, identical on all four;
- marker retained through two further epoch boundaries — height **26** (the drill's
  `target_height` is 24), hash
  `896b05e36ba0694d3e6ec7ddc7e2039d2fe6cf34b275c3f6d2b13134f7413b01`, identical on all four.

`raw/workload-result.json` is the same reading in machine form. `raw/observations.jsonl` carries
the per-validator marker reads, the absent-marker control (the marker is absent before the deploy),
and the original finalized-snapshot reads. The drill's `fixed_snapshots` step re-asks
`/api/is-finalized` for each original finalized block and raises on anything other than `true`;
the arm passing is that check's result, although the individual boolean answers are not logged.

**The upstream job is red, and that is a different arm.** Run 41298319051's `final-gap-recovery` job
records `lfs=0, n4=0, n4-partition=1, n8=0, n8-partition=1`. The partition/rejoin arms failed for
their own reasons — N4 with `INCONCLUSIVE_EPOCH_COVERAGE: the victim's missing range (60, 68] does
not cross an epoch boundary`, N8 with `FAIL_PRECONDITION_ready` at partition-install on node 1. They
are a different drill: neither is evidence against this finality/retention arm, and this arm is not
evidence for them.

The per-node causal dumps (`causal/node-*.json`, `causal/node-*.log`) are omitted from this bundle
and recorded as redactions; the upstream artifact carries them until its expiry. The causal summary
(`causal/comparison.json`, `causal/manifest.json`) is retained.

## What this does not establish

- It is a **finite devnet witness**, not a universal safety theorem, and not a proof that no
  conflicting finalized block can exist.
- It speaks for source `1705392df` and binary `4085278` only. It is not a claim about current `dev`
  or about any deployed or live binary.
- It does not establish a partition/rejoin pass; both partition arms failed in the same job.
- It does not establish public-network, mixed-version, store-upgrade, on-host rollback or
  release-readiness acceptance.
- The earlier N8 finality failure is not root-caused here; the marker is not reproduced as failed at
  this pin, which is weaker than an explanation.
- It does not prove that the run happened or that the reading is sound; that judgement remains the
  operator's (`execution_proven: false`).

## Reproduce

```sh
tools/devnet.sh up --validators 4 --fresh --no-autopropose --epoch-length 10
GITHUB_ACTIONS=true python3 tools/consensus-acceptance-drill.py \
  --validators 4 --window 180 --out target/final-gap/n4
```

The drill refuses to run outside GitHub Actions. The artifact is preserved as
`final-gap-real-nodes-41298319051` on the run above; download it with
`gh run download 41298319051 --repo rhovision-org/rholo -n final-gap-real-nodes-41298319051`.
The source and binary pins above are the ones the run recorded.
