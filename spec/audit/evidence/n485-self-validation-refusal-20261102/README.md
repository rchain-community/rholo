# n485-self-validation-refusal-20261102

**Evidence locality.** `local-devnet`

## Scope

The component witness for #485's named diagnostic: when the proposer refuses a block it built, does
`/health` (and the operator surface) name the **reason** and the refused block, with a closed code,
and does the same success or operator resume that clears the counter clear it?

This is not the snapshot replay. The preserved droplet snapshot `252064726` is not reachable from
this host; the replay remains the human-verdict question.

## Provenance

| | |
|---|---|
| gate | `n485-self-validation-refusal` |
| source | `80d2a8fac21bc5c4a4e3e2ff782ba101e2981e19` |
| binary | `64abf7d434501d622c692f12811806f32af448734ed45369e3e4b8839c9f6705` (the node test binary; `binary-sha256.txt` carries all three) |
| run | none - cargo tests; the source and test-binary hashes are the provenance |
| packaged | `2026-11-02T14:34:33+00:00` |
| verdict | **PASS** |

Every file listed in `manifest.json` is hashed in `SHA256SUMS.json`. **`execution_proven` is
false**: the digests prove the bytes are the bytes, not that the run happened or that its verdict is
sound.

## Result

- `cargo-casper.log`: 15 tests, 0 failed - the 21-variant `BlockStatus::code()` uniqueness/shape
  test; `a_self_validation_refusal_records_its_code_and_block` (code, height, seq, counter 1);
  `a_successful_propose_clears_the_refusal`; `an_internal_error_records_internal_error`; the
  divergence arm records nothing; the live-cell/`clear_halt` test.
- `cargo-node.log`: 39 tests, 0 failed - the `/health` key-set contract, the route's
  `health_names_the_self_validation_refusal` and `..._is_null_when_none_stands`, the operator
  conversion carrying the record, and the public status still forbidding it.
- `cargo-envelope.log`: the emitted Lean envelope corpus matches the served operator key set,
  including `selfValidationRefusal`.

## What this does not establish

- A component witness, **not** a replay of the preserved height-3122 snapshot and not a root-cause
  diagnosis of that incident.
- Process-local: the record is absent after a restart until the next counted refusal, and it is not
  durable and not a readiness term.
- Not a claim that the #522 restart-under-load arm was re-run on this source; that record is at
  `d8b19154` (the post-`d8b19154` delta is assurance/test records and a dependency bump only).
- No consensus rule, validation verdict, or admission bound changed.

## Reproduce

```sh
cargo test -p rchain-casper --lib -- self_validation refusal block_status internal_error_records --test-threads 10
cargo test -p rchain-node --lib -- health conversion self_validation --test-threads 10
cargo test -p rchain-node --test lean_envelope_corpus -- --test-threads 10
tools/emit-lean-corpus.sh
git diff --exit-code -- spec/conformance   # envelope.tsv is the only expected change
```
