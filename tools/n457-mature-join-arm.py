#!/usr/bin/env python3
"""The #457 mature-join arm: a reset validator must LFS-sync a chain that is already 28+ blocks long.

What this asserts, and what it does not. `tools/devnet.sh reset 3` discards validator-3's container and
store and starts it again with `--bootstrap`, so the node must restore the bootstrap's finalized state
from scratch. Before #457 the walk stopped at 3 finished of 28 and failed after three idle rounds; this
arm runs the same shape on a disposable four-validator network and requires the reset node to reach the
bootstrap's height and finalized block, with the sync surface cleared and no `LFS state sync failed` in
its log.

**Fault/acceptance boundary.** A pass is a finite witness on a local Docker bridge: it says the walk now
restores this chain, not that the live testnet join is fixed. The live chain is the observation that
counts, and it is not run here.

Network (a port base and bridge of its own, so it can run beside another devnet):

  DEVNET_PREFIX=n457join DEVNET_NETWORK=n457net \\
  DEVNET_GRPC_BASE=55402 DEVNET_HTTP_BASE=55403 DEVNET_ADMIN_BASE=55405 \\
  tools/devnet.sh up --validators 4 --fresh

**Two recovery shapes, and only one of them is supported.** By default the reset node is started with
`--bootstrap` *and* the devnet's validator key, so it signs from the moment it starts. That is the
shape #576 diagnosed: the node's parent set does not yet contain its own pre-reset blocks, so the
proposer can derive a sequence number the chain already used and sign a genuine second block. With
`--supported-recovery` the node is staged as a passive replicator instead (`DEVNET_RESET_PASSIVE=1`),
allowed to restore and catch up with **no** key, and only then activated with its key from a DAG that
holds its own history (`tools/devnet.sh activate`). The supported shape additionally requires that
the reset node's log contains no `equivocation detected` line.

Usage: tools/n457-mature-join-arm.py [--min-height 28] [--timeout 600] [--out DIR]
                                    [--supported-recovery]
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

PREFIX = os.environ.get("DEVNET_PREFIX", "n457join")
CONTAINERS = [f"{PREFIX}-bootstrap"] + [f"{PREFIX}-validator-{i}" for i in (1, 2, 3)]
RESET_TARGET = f"{PREFIX}-validator-3"
RESET_INDEX = "3"


def run(cmd, check=True, env=None):
    return subprocess.run(cmd, check=check, text=True, capture_output=True, env=env)


def docker(*args, check=True):
    return run(["docker", *args], check=check)


def get(container, path):
    out = run(
        ["docker", "exec", container, "curl", "-sS", f"http://127.0.0.1:40403{path}"]
    ).stdout
    payload = json.loads(out)
    # A node that has just been started answers a plain string (`"No block ..."`) on some endpoints
    # until its state is loaded; the arm treats that as "not ready", not as a malformed record.
    return payload if isinstance(payload, dict) else {}


def status(container):
    return get(container, "/api/status")


def finalized(container):
    data = get(container, "/api/last-finalized-block")
    block_info = data.get("blockInfo", {})
    return block_info if isinstance(block_info, dict) else {}


def wait_heights(containers, minimum, deadline):
    while time.time() < deadline:
        try:
            heights = {c: status(c)["latestBlockNumber"] for c in containers}
            if all(h >= minimum for h in heights.values()):
                return heights
        except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError):
            pass
        time.sleep(2)
    raise SystemExit(f"the devnet did not reach height {minimum} on every node")


def proposal_sequences(log):
    """`(block number, sequence)` for every successful local proposal in `log`.

    **Both groups stay whole.** The sequences are two digits from height 10 on, and a helper that
    unpacked the match into `(_, seq)` over one capture group would split "15" into "1" and "5" —
    a witness that reads 5 for a block that used 15. The arm records the raw lines beside these
    pairs so the two cannot disagree silently (found exactly that way, 2026-11-13)."""
    return [
        (int(block), int(seq))
        for block, seq in re.findall(
            r"proposed and added block #(\d+) \(seq (\d+)\)", log
        )
    ]


def wait_recovered(container, minimum, deadline, what):
    """Wait until a node has restored, left the sync surface, and reached `minimum`.

    A passive replica is held to the same height as a validator here: it receives and validates
    blocks like any peer; what it must not do is propose, which is the property the supported shape
    buys."""
    last_seen = {}
    while time.time() < deadline:
        try:
            st = status(container)
            fin = finalized(container)
            last_seen = {"status": st, "finalized": fin}
            if (
                st.get("latestBlockNumber", 0) >= minimum
                and st.get("sync") is None
                and fin.get("blockHash")
            ):
                return st, fin, last_seen
        except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError):
            pass
        time.sleep(2)
    raise SystemExit(f"{what} within the deadline; last seen: {json.dumps(last_seen)[:600]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--min-height", type=int, default=28)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--out", default="target/issue457-evidence/mature-join")
    parser.add_argument(
        "--supported-recovery",
        action="store_true",
        help="stage the reset validator passively (no key), wait for its catch-up, then activate "
        "its key and require convergence: the supported shape (#576). Without this the node signs "
        "from the moment it starts, which is the shape the issue diagnosed.",
    )
    args = parser.parse_args()

    missing = [c for c in CONTAINERS if docker("inspect", c, check=False).returncode != 0]
    if missing:
        raise SystemExit(
            "missing containers "
            + ", ".join(missing)
            + "; start the network first (see the module docstring)"
        )

    deadline = time.time() + args.timeout
    # The reset target is about to be wiped, so it is not part of the pre-check: waiting on a dead
    # container would turn "the chain is mature" into "the node we are resetting is healthy".
    heights = wait_heights([c for c in CONTAINERS if c != RESET_TARGET], args.min_height, deadline)
    boot_final = finalized(CONTAINERS[0])
    boot_status = status(CONTAINERS[0])
    print(
        f"chain at {heights}; bootstrap finalized {boot_final.get('blockNumber')} "
        f"({str(boot_final.get('blockHash'))[:12]})",
        flush=True,
    )
    if not boot_final.get("blockHash"):
        raise SystemExit("the bootstrap has no finalized block to sync to")

    reset_env = os.environ.copy()
    if args.supported_recovery:
        reset_env["DEVNET_RESET_PASSIVE"] = "1"
        print(
            f"== reset {RESET_TARGET} (empty store, passive replicator, no key)",
            flush=True,
        )
    else:
        print(f"== reset {RESET_TARGET} (empty store, --bootstrap)", flush=True)
    run(["tools/devnet.sh", "reset", RESET_INDEX], env=reset_env)

    # **The supported recovery is two steps** (#576): restore and catch up with no signing key, so
    # the proposer cannot derive a sequence from a parent set that lacks the node's own pre-reset
    # blocks, then give the key back from a DAG that holds them.
    passive_seconds = None
    if args.supported_recovery:
        passive_started = time.time()
        _, _, last_seen = wait_recovered(
            RESET_TARGET,
            boot_status.get("latestBlockNumber", 0),
            deadline,
            "the passive replica did not restore and catch up to the bootstrap's height",
        )
        passive_seconds = time.time() - passive_started
        # **The passive phase's log dies with the container** (`activate` recreates it), so it is
        # captured here: it is the evidence that the node restored and followed with no signing key.
        passive_log = run(["docker", "logs", RESET_TARGET], check=False)
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, "passive.log"), "w") as handle:
            handle.write(passive_log.stdout + passive_log.stderr)
        print(
            f"== passive replica caught up in {passive_seconds:.1f}s; activating its key",
            flush=True,
        )
        run(["tools/devnet.sh", "activate", RESET_INDEX], env=reset_env)

    started = time.time()
    # **The claim under test is the restore plus the follow, not equality with a moving tip.** The
    # chain keeps producing while this runs, so the node is required to reach the height captured
    # before the reset, leave `NodeSyncing`, and hold a finalized block the bootstrap also holds.
    recovered, restored_anchor, last_seen = wait_recovered(
        RESET_TARGET,
        boot_status.get("latestBlockNumber", 0),
        deadline,
        "the reset node did not catch up to the bootstrap's height and finalized block",
    )
    elapsed = time.time() - started

    # The restored anchor must be a block the bootstrap holds: a node that left `NodeSyncing` on a
    # state the bootstrap never had is not a join.
    anchor_hex = str(restored_anchor.get("blockHash"))
    held_by_bootstrap = False
    try:
        held = get(CONTAINERS[0], f"/api/block/{anchor_hex}")
        held_by_bootstrap = bool(held.get("blockInfo"))
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        held_by_bootstrap = False

    # **A second proposal makes the sequence witness non-vacuous** (a reactivated validator must not
    # reuse or regress its own sequence). Best-effort within two minutes: one proposal already
    # witnesses that the key serves, and the sequence check simply has nothing to compare below two.
    if args.supported_recovery:
        second_by = min(deadline, time.time() + 120)
        while time.time() < second_by:
            seen = run(["docker", "logs", RESET_TARGET], check=False)
            if (seen.stdout + seen.stderr).count("proposed and added block") >= 2:
                break
            time.sleep(2)

    # **One capture, written down, and every count read from it** — a witness counted from a second
    # `docker logs` call can disagree with the log beside it in the pack, which is a contradiction an
    # auditor cannot resolve. The container's identity travels with it for the same reason.
    logs = run(["docker", "logs", RESET_TARGET], check=False)
    combined = (logs.stdout + logs.stderr)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "activated.log"), "w") as handle:
        handle.write(combined)
    container = run(
        ["docker", "inspect", "-f", "{{.Id}} {{.Created}}", RESET_TARGET], check=False
    ).stdout.strip()
    sync_failures = combined.count("LFS state sync failed")
    give_ups = combined.count("no block finished in")
    equivocations = combined.count("equivocation detected")
    # **The sequence witness the reactivation test already uses**: a validator that re-signs one of
    # its own sequences shows it here even if the DAG refusal happened to be quiet.
    proposals = proposal_sequences(combined)
    proposed = len(proposals)
    sequences = [seq for _, seq in proposals]
    proposed_lines = [
        f"proposed and added block #{block} (seq {seq})" for block, seq in proposals
    ]

    record = {
        "boundary": "finite local devnet witness; not a live-testnet join and not a certification",
        "chain_height": heights,
        "bootstrap_finalized": {
            "number": boot_final.get("blockNumber"),
            "hash": boot_final.get("blockHash"),
        },
        "reset_target": RESET_TARGET,
        "recovery_shape": (
            "passive-then-activate" if args.supported_recovery else "key-present-from-boot"
        ),
        "passive_catch_up_seconds": passive_seconds,
        "recovered": {
            "latest_block_number": recovered.get("latestBlockNumber"),
            "restored_anchor_number": restored_anchor.get("blockNumber"),
            "restored_anchor_hash": restored_anchor.get("blockHash"),
            "anchor_held_by_bootstrap": held_by_bootstrap,
            "sync": recovered.get("sync"),
        },
        "catch_up_seconds": elapsed,
        "sync_failures_in_log": sync_failures,
        "give_ups_in_log": give_ups,
        "reset_container_id_created": container,
        "self_equivocations_in_log": equivocations,
        "blocks_proposed_in_log": proposed,
        "proposed_sequences": sequences,
        "proposed_lines": proposed_lines,
        "manual_reset": True,
        "non_claims": [
            "one local four-validator devnet; a finite witness, not a universal join theorem",
            "the chain is this build's own; the live testnet replay is #421/#429's",
            (
                "the reset node is staged as a passive replicator and then activated, the "
                "supported recovery (#576)"
                if args.supported_recovery
                else "the reset node is started with `--bootstrap` and the devnet's validator key, "
                "the unsupported shape #576 diagnosed"
            ),
        ],
    }
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "mature-join.json"), "w") as handle:
        json.dump(record, handle, indent=2)

    problems = []
    if sync_failures:
        problems.append(f"the reset node logged {sync_failures} LFS sync failure(s)")
    if recovered.get("sync") is not None:
        problems.append("the sync surface is not cleared")
    if not held_by_bootstrap:
        problems.append("the restored anchor is not a block the bootstrap holds")
    if args.supported_recovery and equivocations:
        problems.append(
            f"the supported shape logged {equivocations} equivocation line(s); the staging did "
            "not keep the proposer off a sequence the chain already used (#576)"
        )
    if args.supported_recovery and proposed == 0:
        problems.append(
            "the activated validator proposed no block, so the arm does not witness it serving"
        )
    if args.supported_recovery and any(b <= a for a, b in zip(sequences, sequences[1:])):
        problems.append(
            f"the activated validator reused or regressed its own sequence: {sequences}"
        )
    print(
        f"recovered ({record['recovery_shape']}) in {elapsed:.1f}s to round "
        f"{recovered.get('latestBlockNumber')}, anchor {restored_anchor.get('blockNumber')} "
        f"({anchor_hex[:12]}, held by bootstrap={held_by_bootstrap}); "
        f"sync={recovered.get('sync')}; sync failures={sync_failures}; "
        f"self-equivocations={equivocations}; proposed={proposed}",
        flush=True,
    )
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}", file=sys.stderr)
        sys.exit(1)
    print(f"ok: evidence at {args.out}/mature-join.json")


if __name__ == "__main__":
    main()
