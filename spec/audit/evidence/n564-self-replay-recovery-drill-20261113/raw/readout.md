# Self-replay recovery drill — integrated build, three arms PASS

**Source:** `8cea0db0` (the dev head at the run; #568's recovery ladder plus #570/#569/#571/#567/#572).
**Image:** `rnode:local` `sha256:b7ce2d60b90326f97f4763b76391dc9ad04540bbe1fae7ae6b75333876dd8e8c`.

| arm | reading |
|---|---|
| 1 `deploy:1` | refused the deploy-bearing block; recovered by an attestation-only block; finality advanced; no reset. |
| 2 `all:2` | refused both builds; reset to the finalised anchor; caught up and resumed **without a POST**; marker null; finality advanced. |
| 3 `all:2 --no-self-replay-reset` | halted; finality frozen for 20 s; the operator POST cleared the latch and finality advanced. |

Local Docker, one host, `execution_proven:false`. The injected fault has the incident's *shape*, not
its cause; RC-B's compatibility/operational acceptance remains open. This is the integrated-build
rerun of the arms first recorded at `d79651d9c`, not a new candidate-binary or live result.
