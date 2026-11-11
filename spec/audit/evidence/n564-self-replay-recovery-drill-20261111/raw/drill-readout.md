# Self-replay recovery drill — three arms, PASS

**Run:** 2026-11-11, `tools/self-replay-drill.sh`, source `d79651d9c`, image `rnode:local`
`sha256:7e1b5c5c…` (recorded in `campaign.json`). Fresh three-validator devnet per arm; every node
launched by `tools/devnet.sh` in dev mode. Subject: `devnet-validator-1`.

**What the instrument is.** A devnet-only `--self-replay-injection` flag refuses the node's own
blocks with the incident's own `ReplayCostMismatch` (1 vs 0), through the ordinary proposal path. It
is refused without `--dev-mode`, applies only to `SelfBuilt` blocks, arms only once a finalised
anchor exists, and its `:N` budget is spent after N refusals so the build after the recovery is
clean.

| arm | flags | PASS means |
|---|---|---|
| 1 | `--self-replay-injection deploy:1` | the deploy-bearing block was refused; the attestation-only block over the same pre-state was broadcast; the latch stayed clear; finality advanced; no reset. Surface at recovery: `refusedBodyAvailable=true`, `refusedBodyLen=786`, `resetAttempted=false`. |
| 2 | `--self-replay-injection all:2` | both builds were refused; one reset to the finalised anchor completed (`rewound 9 block(s) above height 1`); catch-up passed the anchor; `automatic post-catch-up resume: frontier 5 passed the reset anchor at height 1`; the latch cleared **without any operator POST**; the marker was null; finality advanced. Surface at halt: `selfReplayFaultHalted=true`, `resetAttempted=true`, an anchor, body available. |
| 3 | `--self-replay-injection all:2 --no-self-replay-reset` | both builds were refused; the node halted and logged `propose halted: a self-replay fault is latched` on the next trigger; no reset marker existed; finality did not advance for 20 s; `POST /api/v1/autopropose/resume` cleared the latch and finality advanced. Surface at halt: the same evidence as arm 2. |

**Falsifier.** Each arm had to find its own `[SELF-REPLAY INJECTION]` line; a run that stages nothing
exits 3. A failed arm writes `result=FAIL` and `campaign.json` refuses a PASS aggregate over it.

**What this does not establish.** It is not an incident reproduction: validator A's store, the
incident's terms and its refused body are unavailable. It does not close RC-B (the 274-phlo
trigger): the injected failure is the incident's *shape*, not its cause. It is local-devnet evidence,
not an off-host claim.
