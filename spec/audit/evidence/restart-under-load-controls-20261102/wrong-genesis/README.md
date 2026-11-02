# Wrong-genesis negative control — issue #522

**Evidence locality.** `local-devnet`

## Scope

On a quiet disposable four-validator Docker devnet (no autopropose, no propose-on-deploy) built from
source `d8b19154…`, start a **non-signing** control node from the validator argv with its validator
key, deployer key, autopropose, propose-on-deploy and hostname removed. The control node keeps the
network and genesis binds, a fresh data directory, and the bootstrap address, and is given
`--expected-genesis-hash` set to a **flipped** genesis hash.

The question: does the node refuse visibly, without entering `Running`, and leave the real network
untouched?

## Provenance

| | |
|---|---|
| gate | `n4-restart-under-load-wrong-genesis` |
| source | `d8b19154c4fdfd6a5321610f51935ae8d5fc24e4` |
| binary | `d8bcc09158115cdded6b5b692808743fb5bea60b9616d959efc42a6e9a99d611` |
| run | local disposable devnet; no Actions run URL |
| packaged | `2026-11-02T11:31:43+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

Control exit code **1**. The log names the refusal and the fatal stop:

```
ERROR [casper.engine.NodeSyncing] LFS state sync failed ...:
  recovery genesis a0962e6d… differs from pinned genesis 00962e6d…
...
Fatal: NodeLaunch exited with error: LFS state sync is terminal: ...
```

`entered_running` is `false`: no `Making a transition to Running state` appears. The real validators
kept serving and agreeing throughout; the control container was removed after its log and inspect
were preserved.

## What this does not establish

- It proves the **refusal** of a wrongly-pinned node on this devnet, not the correctness of any
  genesis, chain or store.
- The pinned value is a flipped block hash, not a second chain: this is a pin-mismatch control, not
  a wrong-genesis chain test.
- Local only; no live-network, release-readiness or mixed-version claim.
- It does not prove the run happened (`execution_proven: false`).

## Reproduce

```sh
DEVNET_PREFIX=restartload DEVNET_NETWORK=restartload \
DEVNET_GRPC_BASE=42402 DEVNET_HTTP_BASE=42403 DEVNET_ADMIN_BASE=42405 \
DEVNET_NODE_MEMORY=4g DEVNET_THREAD_POOL_SIZE=2 \
  tools/devnet.sh up --validators 4 --fresh --no-autopropose --no-propose-on-deploy

DEVNET_PREFIX=restartload DEVNET_NETWORK=restartload \
DEVNET_HTTP_BASE=42403 DEVNET_ADMIN_BASE=42405 \
  python3 tests/consensus-restart-under-load.py --control wrong-genesis \
    --validators 4 --out target/controls-20261102/wrong-genesis
```
