# Capacity-refused body, re-offer log line — issue #522

**Evidence locality.** `local-devnet`

## Scope

The component fixture
`block_disposition::tests::a_capacity_refused_body_survives_the_full_receiver_and_reoffers_once`
at source `b0303c8f5dbfbd4d7f9a4956f72750d4b2821d23`. It exercises the **real** 1,024-entry
`BlockReceiverState`, not an empty receiver standing in for an overflow:

1. fill the receiver to `MAX_PENDING_BLOCKS` (asserted to be 1024);
2. offer a 1,025th body whose parent is not in the DAG — the receiver refuses it with
   `block receiver state full (1024 blocks)`; the body is stored and a durable `Pending{Stored}`
   row is written, and the in-memory claim is released;
3. free one slot, and ask the runtime sweep to re-offer: it must **not** dispatch while the parent
   is missing;
4. insert the parent, and ask again: exactly one dispatch, no duplicate;
5. capture the runtime log and require exactly one operator-visible line:
   `re-offering stored pending body <hash> after its parents entered the DAG`.

This is the third close bullet of issue #522 at component level: a body refused for receiver
capacity is re-offered after its parent arrives, with the log line as evidence.

## Provenance

| | |
|---|---|
| gate | `n522-capacity-reoffer` |
| source | `b0303c8f5dbfbd4d7f9a4956f72750d4b2821d23` |
| test binary | `2726acea179dd4817fcb2af9b35a60f173181bf0d61aeb4c321b84b0be8262db` |
| run | local `cargo test`; no Actions run URL |
| packaged | `2026-11-02T12:34:19+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound. The binary pin is the test executable, not the node binary.

## Result

```
REOFFER_LOG_LINE re-offering stored pending body 2b2b2b…2b2b after its parents entered the DAG
test block_disposition::tests::a_capacity_refused_body_survives_the_full_receiver_and_reoffers_once ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 590 filtered out
```

The test asserts, in addition to the dispatch count: no re-offer line before the parent arrives; the
line names the refused block; the line names the cause; and exactly one such line exists.

## What this does not establish

- **It is a component witness, not an end-to-end saturation run.** No four-validator network is
  filled to 1024 pending receivers here; the N4 restart campaign's receiver peaked at 5 of 1024.
- It does not prove the runtime sweep's cadence or behaviour under a live backlog, only the state
  machine and the line it emits.
- The binary pin is a test executable built from the source; it is not a node release artifact.
- It does not prove the run happened (`execution_proven: false`).

## Reproduce

```sh
cargo test -p rchain-casper --lib \
  a_capacity_refused_body_survives_the_full_receiver_and_reoffers_once -- --nocapture
```
