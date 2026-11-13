# #576 supported recovery: passive staging, then activation

**PASS (local four-validator devnet).** A validator reset with an empty store recovers its validator
role when it is staged as a passive replicator until catch-up, and only then given its signing key.
The same shape started with the key from boot is the one that forked in
`spec/audit/evidence/m3-fringe-witness-20261113/` (#575/#576).

**Tooling:** `da473e01` (`tools/devnet.sh activate`, the arm's `--supported-recovery`).
**Image:** `rnode:local` `sha256:cdf2e5c0f6d608e409f9f72a119c46d700a3610bde743b49ac3169119f1cdb0c`,
built at source `79e550400` (the Rust workspace is unchanged by the tooling commit).

## Run

Four validators, one Docker host; chain warmed to 16 on the three survivors, then
`DEVNET_RESET_PASSIVE=1 tools/devnet.sh reset 3`, the arm's passive wait, `tools/devnet.sh activate 3`.

| | |
|---|---|
| reset container | `522f514b5763…`, created 2026-11-13T16:18:18.260Z |
| passive catch-up | **17.4 s** to the bootstrap's captured height, sync surface clear |
| activation | recovered to round **19** in **4.3 s**; restored anchor #14 `d67ffe73623d…`, held by the bootstrap |
| self-equivocation lines | **0** |
| own proposals | **4**, sequences **15, 16, 17, 18** (strictly increasing) |
| LFS sync failures | 0 |

Passive phase (`passive.log`, captured before `activate` recreates the container):

```
2026-11-13T16:18:14.246Z INFO [casper.engine.NodeSyncing] LFS state is successfully restored.
```

Activated phase (`activated.log` — one capture, the source of every count in `mature-join.json`):

```
proposed and added block #16 (seq 15)
proposed and added block #18 (seq 16)
proposed and added block #19 (seq 17)
proposed and added block #20 (seq 18)
```

The proposing sequences start at 15, not 13: the restored DAG holds the validator's own pre-reset
blocks, so the proposer derives the next sequence from them. That is the property the key-present
shape lacks.

## Bounds

`local-devnet`, one host, one packed run (two earlier development runs of the same arm reached the
same outcome and are not packed), `execution_proven:false`. Not the off-host M3 positive, not M3-00
acceptance, not a candidate-binary result. The **unsupported** shape — key present from boot — still
signs a second block at a used sequence; the fail-closed guard for it remains open in #576.
