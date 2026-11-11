# RC-B authenticated deploy recovery — investigation in progress

Incident source: 0a1e02362a7c34e474e068ffd47469c8d4be707a.

Five contiguous signed protobuf payloads were carved from a read-only raw copy of A's deploy pool and independently authenticated. Production Rust authentication and synthetic-prestate replay are pending in the dedicated fork workflow. These payloads match five signatures from the Nov8 refusal logs; the first failing dd2d deploy has now been reconstructed and authenticated by its original public signature; its raw contiguous tail is still overwritten. The original processed trace and historical pre-state have not been recovered. No historical root-cause closure is claimed.

M22 checks all six payloads with production decoding/signatures and negative controls. M23 repeats strict replay three times per recovered payload on a funded synthetic genesis. M24 explores authenticated registry/probe order and scheduler variations. Diagnostic test completion is distinct from replay acceptance. No production source is modified.

Raw database copies and unrelated logs are retained privately. Only selected incident records and signed public contract payloads are published here.

— Ω-WITNESS

## M22–M24 completed

Run [43098851150](https://github.com/aixaria0/rchain-rust/actions/runs/43098851150) completed successfully on the exact incident source. All six signatures pass the production verifier and all tamper controls fail authentication. Synthetic-genesis cases replay successfully; registry alone costs2460 and one pre-existing probe makes it3239. These do not reproduce5576/5302.

## M25 pending

The complete Merkle closures of both original pre-states, both declared post-states, and the1073 fringe were recovered from read-only copies. The state fixture is content-addressed and validated before loading into a disposable in-memory runtime. The rejected block body/trace and exact informational timestamp remain unavailable; M25 logs all surrogate metadata explicitly and tests regenerated play against the recorded post-state root. No production code or consensus acceptance rule is changed.

## M25 reproduced the exact incident

Run [43100598230](https://github.com/aixaria0/rchain-rust/actions/runs/43100598230) passed on original source0a1e02362. Both original pre-states yield exactly5576 versus5302 and both original declared post-state hashes, in three deterministic repeats each. The rejected block body/recorded trace and exact timestamp are still not recovered; the trace is regenerated from authenticated deploys and complete Merkle-verified state. M26 adds observational charge logging, retaining the same arithmetic, costs, state hashes, and strict rejection.

## M26 cost differential

Run [43101149837](https://github.com/aixaria0/rchain-rust/actions/runs/43101149837) passed. All274 phlo are accounted for:141 play charges sum5576;109 replay charges sum5302. The first differing charge is index29, immediately after the first240-phlo inner consume charge: play matches and refunds, replay bills an unmatched event. Unobserved repetitions retain the same exact costs and original post-state hashes. M27 now tests only the binding-construction iteration order; M28 retains strict trace-corruption controls.
