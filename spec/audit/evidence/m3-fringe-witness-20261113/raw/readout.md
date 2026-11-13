# M3 fringe witness — local four-validator join

**Instrument PASS; join arm FAIL.** The requester/responder correlation fields work; the join arm's
height-convergence check did not complete, blocked by a post-restore self-equivocation retry (below).

**Source:** `214d78fd` (the witness-log commit). **Image:** `rnode:local`
`sha256:9ac9e21d2d2713f805a6b7b43c088b9b220173abf425f718efcf534e996b2c8d`.
**Network:** four validators on one Docker host (`n457join`), chain warmed to height 16, then
`tools/devnet.sh reset 3` (empty store, `--bootstrap`) and `tools/n457-mature-join-arm.py --min-height 16`.

## Witness lines

Requester (`n457join-validator-3`, the reset node):

```
LFS fringe request 1/10 sent to peer af87a7f05f97553034f038a4e410d10036c9fc97 (anchor latest); awaiting admitted reply
LFS fringe reply admitted for peer af87a7f05f97553034f038a4e410d10036c9fc97 (anchor latest) on attempt 1/10
```

Responder (`n457join-bootstrap`):

```
Received FinalizedFringeRequest from rnode://120e06f1194d0bc661f9e338162779b25d0a8d82@n457join-validator-3
Fringe response: 4 block(s) [29098f52… .. d7bfc66d…], state 87c62c…, requested anchor latest, 93 ancestry block(s) (#139)
```

The reset node also logs `LFS state is successfully restored.` and leaves `NodeSyncing`. The witness
is joinable end to end by peer key, anchor and fringe identity.

## Why the arm failed

The arm requires the reset node's height to reach the bootstrap's pre-reset height (16). It stayed at
15 for the 600 s window. The cause is a post-restore self-equivocation:

```
Block #14 ef7d6965… faulted at dag insert (equivocation detected: sender produced two blocks with the
same sequence number); recorded for retry 1/8 … 5/8
```

The retry schedule (exponential, up to 8 attempts) outlasts the arm's window. This is a separate
join/catch-up behaviour (the stale-snapshot self-equivocation class), not the log change. The
off-host positive remains owed; this run is `local-devnet`, one host, and is not M3-00 acceptance.

## Files

`bootstrap.log`, `validator-3.log`, `arm.log`, `up.log` are the raw captures; `result.txt` is the arm
verdict (FAIL).
