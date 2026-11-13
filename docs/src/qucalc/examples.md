# QuCalc examples

Each example is a runnable demo, ported to mirror a quantum-os demo. The rholang
examples are driven end-to-end through the real `RhoRuntime` (parse → normalize →
reduce) by the smoke test in
[`rholang/tests/rho_examples.rs`](../../../rholang/tests/rho_examples.rs).

## Rholang examples (`qucalc/examples/`)

| Example | quantum-os demo | What it demonstrates |
|---|---|---|
| [`syllogism.rho`](../../../qucalc/examples/syllogism.rho) | SyllogismDemo | Collaborative dialectical synthesis — two peers name ZFA-balanced premises, fuse them through the shared middle term, and seal the conclusion as an unforgeable capability. |
| [`multisig.rho`](../../../qucalc/examples/multisig.rho) | MultisigDemo | N-of-M quorum co-signature over a nonce-keyed confirmation set, self-signed by `*deployerId`. |
| [`promissory_note.rho`](../../../qucalc/examples/promissory_note.rho) | PromissoryNoteDemo | Bearer-capability lifecycle: declare an issuer authority, grant a note, redeem a receipt. |
| [`atomic_swap.rho`](../../../qucalc/examples/atomic_swap.rho) | AtomicSwapDemo | All-or-nothing two-party exchange via a rholang `for`-join — no escrow, no third party. |
| [`dining_philosophers.rho`](../../../qucalc/examples/dining_philosophers.rho) | DiningPhilosophersDemo | Deadlock-free resource acquisition: forks are capability channels; both-or-neither acquisition by construction. |
| [`liquid_democracy.rho`](../../../qucalc/examples/liquid_democracy.rho) | Governance / Group_Decisions | The worked exemplar of `rho:gov:*` — transitive delegation and weighted ranked-choice tally. |

## Rust example (`qucalc/examples/`)

| Example | What it demonstrates |
|---|---|
| [`ai_coprocessor.rs`](../../../qucalc/examples/ai_coprocessor.rs) | The neuro-symbolic coprocessor (`qlf_ai_coprocessor`): dialectical synthesis walked through the Aristotle syllogism (`Socrates → Man → Mortal`). Run with `cargo run --example ai_coprocessor`. |

## Rholang libraries (`qucalc/rholang/`)

These are the reusable contracts the examples are built from:

| Library | Purpose |
|---|---|
| [`qucalc.rho`](../../../qucalc/rholang/qucalc.rho) | The ZFA proof substrate: `zfa`, `grant`, `verify`, `fuse`, `ratify`. |
| [`gov.rho`](../../../qucalc/rholang/gov.rho) | Liquid-democracy governance: groups, membership, self-signed envelopes, tallies, decision-of-record. |
| [`Directory.rho`](../../../qucalc/rholang/Directory.rho) | Capability-facet key/value store (rgov `Directory.rho` port). |
| [`Inbox.rho`](../../../qucalc/rholang/Inbox.rho) | Capability-facet message store (rgov `Inbox.rho` port). |
| [`Chat.rho`](../../../qucalc/rholang/Chat.rho) | Publish/subscribe mailbox (rgov `Chat.rho` port). |

See [`Governance.md`](../../../qucalc/rholang/Governance.md) for the governance
semantics these libraries compose.

## External QKB contract conformance

[`tools/qkb-runtime-conformance.py`](../../../tools/qkb-runtime-conformance.py)
installs the pinned QLF #216 contract on a fresh loopback-only validator and
calls the registered service from separately signed deploys. It compares actual
results with the pinned Python reference, including native deployer identity,
question replay, answer ordering, per-axis admission and compound propositions.

The [runtime acceptance record](../../../spec/audit/evidence/qkb-runtime-20261113/README.md)
contains the source and executable digests, carrying-block receipts, bounded
vector census, deliberately weakened admission control and the retained
larger-state timeout. Sharding and mutable-client callback checks remain
reference-model checks; the deployed contract has one state cell.
