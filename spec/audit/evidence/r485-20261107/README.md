# #485 — height-3122 round-escape differential

## Scope and verdict

The preserved height-3122 JustificationRegression is reproduced by the historical binary.
In a same-input, source-pinned isolated differential, the control (historical a5259969)
rejects its own #3122, while the candidate (a5259969 plus only the #492
round-escape repair) successfully proposes and adds #3122, #3123 and #3124.

**Targeted #485/#492 isolated replay: PASS.** This is not a full public-testnet
release acceptance. Four-validator restart, distributed finality, and #487 remain open.

## Evidence layout

- historical/: original historical reproduction node and propose logs
- control/: separate, freshly copied pristine-store control logs
- candidate/: separate, freshly copied pristine-store repaired candidate logs
- manifest.json: exact source refs, action run IDs, binary and copy digests
- SHA256SUMS: checksums for every published evidence file
- patches/a525-plus492.diff: the one-commit source difference (two files only)
- scripts/: public reproduction templates with private network addresses replaced
  by environment variables R485_REPLAY_HOST and R485_DENY_IP.

The two scripts are NOT byte-identical to the executed originals because
the network addresses have been replaced. Original script hashes are in
manifest.json. All published log bytes are unchanged from the original run.

## Reproduction conditions

1. Authenticate the replay SSH host; never bypass host-key verification.
2. Keep the original /var/lib/rnode untouched; /etc/replay-freeze present;
   rnode inactive; r485-isolate.service active.
3. One validator identity may run at a time; use a no-route network namespace
   with no external validator contact.
4. Independently copy the same pristine eight-file LMDB input for each arm.
5. Verify source SHA, binary SHA-256, original and copied store digests.
6. Use identical runtime flags and round-escape timing. A single propose is
   insufficient: ROUND_STALL_ESCAPE is 15 seconds.
7. Use node.log to distinguish the actual validation result from a client
   transport error or a NotEnoughNewBlocks pacing refusal.

## Results

| Arm | Source | Observed behavior |
|---|---|---|
| Historical | a5259969 | Self-created #3122 rejected: justification regressed |
| Control | a5259969 | Same rejection at #3122 |
| Candidate | 7f1d4814 | #3122, #3123, #3124 proposed and added |

The original LMDB digest stayed unchanged after the runs:
a51a2b78551e184d9e4d9cc8c5e8a6ef0edeae78ea26dfe60bf0459a3f2183bd.

Candidate and control copy digests differ after execution because the copies
are mutable. This is expected and does not affect original-input equality.

This establishes the targeted repair under one isolated historical state. It
does not by itself prove broader consensus safety, liveness, or that production
validators should be restarted. #487 is a separate operational acceptance gate.

## Links

- Original incident: https://github.com/rhovision-org/rholo/issues/485
- Repair: https://github.com/rhovision-org/rholo/pull/492
- Human verdict: https://github.com/rhovision-org/rholo/issues/553

No validator on the public network was deployed or restarted for this record.
