# Interrupted-restart, recovered arm — issue #522

**Evidence locality.** `local-devnet`

## Scope

On a producing disposable four-validator Docker devnet from source `d8b19154…`, SIGKILL validator 1,
start it, wait for a **new `bootId`**, then SIGKILL it again before it can be treated as recovered,
and start it a second time. The control requires two distinct new process identities after the
baseline, then readiness, the same finalized `(height, hash)` on all four validators at least three
heights above the baseline, and the health gates.

This is the positive arm of the interrupted-restart control: an interrupted restart must not be
counted as a pass until a second clean start actually recovers.

## Provenance

| | |
|---|---|
| gate | `n4-restart-under-load-interrupted-restart-recovered` |
| source | `d8b19154c4fdfd6a5321610f51935ae8d5fc24e4` |
| binary | `d8bcc09158115cdded6b5b692808743fb5bea60b9616d959efc42a6e9a99d611` |
| run | local disposable devnet; no Actions run URL |
| packaged | `2026-11-02T11:31:30+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

`raw/interrupted-restart.json` records three distinct process identities:

```
1-1793619022395  →  1-1793619028840  →  1-1793619033257
```

`ready_error` is `null`, and all four validators finished at height **9**, hash
`c88fe1d443e0…`, identical. The control passed only after the third process identity was observed
and the network agreed.

## What this does not establish

- It does not show that every interrupted start is harmless: the detected arm is the one that
  requires a visible readiness failure while the victim is down.
- The second kill is timed after the first new `bootId`, not at a fixed offset; it exercises the
  interrupted-start window on this run, not all possible windows.
- No partition, live-network or release claim; local devnet only.
- It does not prove the run happened (`execution_proven: false`).

## Reproduce

```sh
tools/devnet.sh up --validators 4 --fresh          # producing defaults
python3 tests/consensus-restart-under-load.py --control interrupted-restart \
  --interrupt-expect recovered --validators 4 \
  --out target/controls-20261102/interrupted-restart-recovered
```
