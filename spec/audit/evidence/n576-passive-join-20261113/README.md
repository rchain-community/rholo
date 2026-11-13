# n576-passive-join-20261113

**Evidence locality.** `local-devnet`

## Scope

The supported recovery for a validator whose store was reset: stage it as a passive replicator with
**no signing key** until it has restored and caught up, then give it the key from a DAG that holds
its own pre-reset blocks (`DEVNET_RESET_PASSIVE=1 tools/devnet.sh reset 3`, then
`tools/devnet.sh activate 3`). The question: does the reset validator recover its validator role,
converge to the chain, and sign only new sequence numbers — the shape that forked when the same
reset was started with the key from boot (#576).

## Provenance

| | |
|---|---|
| gate | `n576-passive-activation` |
| source | `da473e0162334fe2a2a9ef47e39fa2210e66fa93` (the tooling under test: `tools/devnet.sh activate`, the arm's `--supported-recovery`) |
| binary | `sha256:cdf2e5c0f6d608e409f9f72a119c46d700a3610bde743b49ac3169119f1cdb0c` — `rnode:local`, built at source `79e550400`; the Rust workspace is unchanged by the tooling commit |
| run | local four-validator Docker devnet, 2026-11-13T16:18Z — no actions URL; `raw/readout.md` carries the lines and `raw/mature-join.json` the record |
| packaged | `2026-11-13T16:19:01+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

The passive replica caught up in **17.4 s** — `LFS state is successfully restored.` at
16:18:14.246Z, the sync surface clear at the bootstrap's captured height. After
`tools/devnet.sh activate 3` the node was in the running phase with `sync: null` in **4.3 s**, at
round **19**, holding finalized anchor #14 `d67ffe73623d…` which the bootstrap also holds. It
proposed four blocks with strictly increasing own sequences **15, 16, 17, 18** (`activated.log`) and
logged **zero** `equivocation detected` lines; `passive.log` and `activated.log` are the arm's own
single captures, and `mature-join.json`'s counts are read from the latter.

The sequences start at 15, not 13: the restored DAG holds the validator's own pre-reset blocks, so
the proposer derives its next sequence from them. That is exactly what the key-present shape lacks,
and why it can sign a second block at a used sequence (#576).

## What this does not establish

One local four-validator devnet on one host, one packed run (two earlier development runs of the
same arm reached the same outcome and are not packed), `execution_proven:false`. This is not the
off-host M3 positive, not M3-00 acceptance and not a candidate-binary result, and it is not a
universal join theorem. The **unsupported** shape — key present from boot — still signs a second
block at a used sequence; the fail-closed guard or operational rule for it remains open in #576.

## Reproduce

From the repository root, with the image built at the pinned source and the tooling at the source
above:

```sh
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  tools/devnet.sh up --validators 4 --fresh
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  python3 tools/n457-mature-join-arm.py --min-height 16 --timeout 900 \
    --supported-recovery --out target/n576-passive-join
DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \
DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \
  tools/devnet.sh down -v
```

The arm exits non-zero when the staging did not keep the proposer off a used sequence, when the
activated validator proposed nothing, or when the restored anchor is not a block the bootstrap
holds. `python3 tools/evidence-pack.py verify --record <this directory>` checks the hashes.
