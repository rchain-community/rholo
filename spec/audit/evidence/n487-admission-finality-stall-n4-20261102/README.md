# n487-admission-finality-stall-n4-20261102

**Evidence locality.** `local-devnet`

## Scope

A disposable four-validator DevNet at **200 of 300 bonded stake live - exactly 2/3, which is not a
strict supermajority** (`--stakes 100,100,50,50`; the two 50-stake validators stopped). The question
is whether #487's contract holds at that boundary: finality freezes while production continues, the
deploy-settlement route never calls an unfinalized deploy settled, restarting the stopped validators
finalizes the same deploy without resubmission, and a partitioned node says `unknown` rather than
settled.

This is the local half of #487. The live post-deployment on the public testnet is not part of this
record.

## Provenance

| | |
|---|---|
| gate | `n487-admission-finality-stall` |
| source | `80d2a8fac21bc5c4a4e3e2ff782ba101e2981e19` |
| binary | `0f07efeab722cabc30ace442c0fbb0bfd0e35569771175407c084334d1bf226a` |
| run | none - local disposable devnet; the source, image and binary hashes are the provenance |
| packaged | `2026-11-02T14:32:44+00:00` |
| verdict | **PASS** |

The image is `rnode:487-local`, id `sha256:a585d6ac1626caad2e6a9066c5cad37c113d1524ed53eb5edab4c8f05ef21c7d`,
built from the source above with `tools/devnet.sh build`. The bond set is `stakes` in
`result.json`; the genesis capture in `provenance.json` is **empty** for this run (the harness read
`/var/lib/rnode/genesis/...` while the devnet mounts it at `/genesis`). The harness path is corrected
for future runs; this record does not claim a captured genesis file.

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

All five arms passed (`result.json`, `campaign.json`):

| arm | reading |
|---|---|
| `accepted-not-settled` | first settlement sample of a submitted deploy: `stage: "pooled"`, `settlementConfirmed: false` |
| `ordinary-lag` | on >2/3, the deploy was included and then `finalizedSuccess`; the intermediate `includedUnfinalized` samples never confirmed |
| `stall-exactly-two-thirds` | **200/300 live**: height 17 -> 18 on both live validators while the finalized height stayed 13 -> 13; the stall deploy's settlement stayed `includedUnfinalized` at block 17 with `settlementConfirmed: false` |
| `recovery` | both stopped validators restarted; all four became ready; the same deploy (inclusion block 17) settled at finalized height 24 with `stage: "finalizedSuccess"` and `settlementConfirmed: true`; every accepted deploy ended `finalizedSuccess` or `finalizedError` (no silent loss) |
| `partition-stale` | after `docker network disconnect`, the victim's own loopback answered `includedUnfinalized` and `/api/v1/finality-observation` `availability: "unknown"`; never `finalizedSuccess` |

The finality that had already been sent by the stopped validators was allowed to settle for five
seconds before the stall baseline; a step after that window would have failed the arm.

## What this does not establish

- A finite four-validator disposable devnet, not a universal liveness/safety theorem, not a public
  testnet or mainnet-readiness claim, and not a reproduction of the historical block-1781 incident
  (older binary and genesis; the assertion here is the contract, not that incident).
- The node-local finality observation is not quorum proof; the campaign asserts the client contract,
  not that any single node can see network quorum.
- No consensus parameter, admission bound, or retry policy changed. `acceptsDeploys` remains pool
  capacity (Law 86a).
- No live validator or production store was touched.

## Reproduce

```sh
RNODE_IMAGE=rnode:487-local tools/devnet.sh build
RNODE_IMAGE=rnode:487-local DEVNET_PREFIX=admissionstall DEVNET_NETWORK=admissionstall \
  DEVNET_GRPC_BASE=44402 DEVNET_HTTP_BASE=44403 DEVNET_ADMIN_BASE=44405 DEVNET_NODE_MEMORY=4g \
  tools/devnet.sh up --validators 4 --stakes 100,100,50,50 --fresh \
    --no-autopropose --no-propose-on-deploy
RNODE_IMAGE=rnode:487-local DEVNET_PREFIX=admissionstall DEVNET_NETWORK=admissionstall \
  DEVNET_HTTP_BASE=44403 DEVNET_ADMIN_BASE=44405 \
  python3 tests/admission-finality-stall.py --validators 4 --stakes 100,100,50,50 \
  --out target/admission-finality-stall-<date> --window 240 --recovery-window 360
tools/devnet.sh down -v
```

The offline predicates run without a devnet:
`python3 -m unittest discover -s tests -p 'test_admission_finality_stall_controls.py' -v`.
