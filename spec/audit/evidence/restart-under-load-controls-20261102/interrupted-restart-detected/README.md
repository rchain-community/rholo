# Interrupted-restart, detected arm — issue #522

**Evidence locality.** `local-devnet`

## Scope

On the producing disposable four-validator devnet, SIGKILL validator 1, start it, wait for a new
`bootId`, SIGKILL it again, and **leave it down**. A bounded 15-second readiness wait must then
raise — the interrupted restart is a visible failure, not a silent pass. The victim is started a
second time afterwards and the network must recover to the same finalized `(height, hash)` on all
four validators.

This is the negative half of the interrupted-restart control: a restart interrupted before
recovery must not be counted as recovered.

## Provenance

| | |
|---|---|
| gate | `n4-restart-under-load-interrupted-restart-detected` |
| source | `d8b19154c4fdfd6a5321610f51935ae8d5fc24e4` |
| binary | `d8bcc09158115cdded6b5b692808743fb5bea60b9616d959efc42a6e9a99d611` |
| run | local disposable devnet; no Actions run URL |
| packaged | `2026-11-02T11:31:32+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

The bounded readiness wait raised while the victim was down:

```
ready_error = "validator 1 did not become ready before the deadline"
```

The recorded process identities are three distinct boots:
`1-1793619033257 → 1-1793619043086 → 1-1793619062535`. After the second start all four validators
finished at height **17**, hash `ea80ae695278…`, identical.

## What this does not establish

- The readiness wait is deliberately short (15 s); it shows that the interrupted state is not
  ready within that bound, not that it can never recover unaided.
- It does not exercise a partition or a second controlled restart order.
- Local devnet only; no live-network or release claim.
- It does not prove the run happened (`execution_proven: false`).

## Reproduce

```sh
tools/devnet.sh up --validators 4 --fresh
python3 tests/consensus-restart-under-load.py --control interrupted-restart \
  --interrupt-expect detected --validators 4 \
  --out target/controls-20261102/interrupted-restart-detected
```
