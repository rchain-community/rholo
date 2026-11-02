# Incomplete-ancestry negative control — issue #522

**Evidence locality.** `local-devnet`

## Scope

On the same quiet disposable four-validator Docker devnet as the wrong-genesis control, start a
**non-signing** control node with the validator argv minus its identity and a fresh data directory,
pointed at the bootstrap, with `--sync-anchor` set to an **absent** 32-byte hash. The node is asked
to restore an ancestry that no peer holds.

The question: does the node refuse visibly, without entering `Running`, rather than serving a chain
it never synced?

## Provenance

| | |
|---|---|
| gate | `n4-restart-under-load-incomplete-ancestry` |
| source | `d8b19154c4fdfd6a5321610f51935ae8d5fc24e4` |
| binary | `d8bcc09158115cdded6b5b692808743fb5bea60b9616d959efc42a6e9a99d611` |
| run | local disposable devnet; no Actions run URL |
| packaged | `2026-11-02T11:31:26+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

Control exit code **1**, with the bounded LFS request spent and the node stopping:

```
ERROR [coop.rchain.node.runtime.Setup] NodeLaunch exited with error:
  LFS bootstrap supplied no authenticated nonempty fringe after 10 requests; refusing to enter Running
Fatal: NodeLaunch exited with error: ...
```

`entered_running` is `false`. The real validators kept serving and agreeing; the control container
was removed after its log and inspect were preserved.

## What this does not establish

- This is a **named-root ancestry-unavailable** control: the node asks for an anchor no peer holds.
  It is not a corrupted local store with a missing interior block, and it does not prove recovery
  from that separate condition.
- It does not establish that the LFS retry policy is optimal, only that exhaustion is fatal and named.
- Local only; no live-network or release claim.
- It does not prove the run happened (`execution_proven: false`).

## Reproduce

```sh
DEVNET_PREFIX=restartload DEVNET_NETWORK=restartload \
DEVNET_GRPC_BASE=42402 DEVNET_HTTP_BASE=42403 DEVNET_ADMIN_BASE=42405 \
DEVNET_NODE_MEMORY=4g DEVNET_THREAD_POOL_SIZE=2 \
  tools/devnet.sh up --validators 4 --fresh --no-autopropose --no-propose-on-deploy

DEVNET_PREFIX=restartload DEVNET_NETWORK=restartload \
DEVNET_HTTP_BASE=42403 DEVNET_ADMIN_BASE=42405 \
  python3 tests/consensus-restart-under-load.py --control incomplete-ancestry \
    --validators 4 --out target/controls-20261102/incomplete-ancestry
```
