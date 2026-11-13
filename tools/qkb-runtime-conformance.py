#!/usr/bin/env python3
"""Run QLF #216 against a fresh, loopback-only, single-validator Rholo node.

Requires a built rnode and pycryptodome (REV-address derivation only). The QLF
reference is imported from an explicitly supplied, source-pinned checkout.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

RHOLO = "79e550400114b32a0292b9103cb5e83c6e1e1c72"
QLF = "7667443c7feb14efeb01aa50b86171be0cd38f0a"
ALPHABET = "ybndrfg8ejkmcpqxot1uwisza345h769"


class Raw(str):
    pass


class Uri(str):
    pass


def registry_uri(digest):
    bits = "".join(f"{v:08b}" for v in bytes.fromhex(digest))
    return Uri("rho:id:" + "".join(ALPHABET[int(bits[i:i+5].ljust(5, "0"), 2)]
                                 for i in range(0, len(bits), 5)))


def rho(value):
    if isinstance(value, Raw):
        return str(value)
    if isinstance(value, Uri):
        return "`" + value + "`"
    if value is None:
        return "Nil"
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, list):
        return "[" + ", ".join(rho(v) for v in value) + "]"
    if isinstance(value, tuple):
        return "(" + ", ".join(rho(v) for v in value) + ("," if len(value) == 1 else "") + ")"
    if isinstance(value, dict):
        return "{" + ", ".join(rho(k) + ": " + rho(v) for k, v in value.items()) + "}"
    raise TypeError(type(value).__name__)


def expected_value(value, field=None):
    if field == "id":
        return registry_uri(value)
    if isinstance(value, dict):
        return {k: expected_value(v, k) for k, v in value.items()}
    if field == "q":
        return (list(value[0]), value[1])
    if field == "residual":
        return list(value)
    if isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value):
        return registry_uri(value)
    return value


def rev_address(public_key):
    from Crypto.Hash import keccak
    def keccak256(data):
        k = keccak.new(digest_bits=256)
        k.update(data)
        return k.digest()
    key_hash = keccak256(keccak256(bytes.fromhex(public_key)[1:])[-20:])
    payload = b"\x00" * 4 + key_hash
    data = payload + hashlib.blake2b(payload, digest_size=32).digest()[:4]
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    n, result = int.from_bytes(data, "big"), ""
    while n:
        n, digit = divmod(n, 58)
        result = alphabet[digit] + result
    return "1" * (len(data) - len(data.lstrip(b"\x00"))) + result


class Run:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.out).resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.binary = str(Path(args.rnode).resolve())
        digest = hashlib.sha256(Path(self.binary).read_bytes()).hexdigest()
        if digest != args.expected_binary_sha256:
            raise ValueError("runtime executable does not match the expected artifact digest")
        version = subprocess.check_output([self.binary, "--version"], text=True).strip()
        if RHOLO not in version:
            raise ValueError("runtime version does not identify the pinned Rholo revision")
        self.report = {
            "started_utc": datetime.now(timezone.utc).isoformat(), "version": version,
            "result": "INCOMPLETE", "runtime_source": RHOLO, "qlf_source": QLF,
            "binary_sha256": digest,
            "scope": "isolated-single-validator-loopback", "suite": args.suite, "cases": [],
        }
        self.node = None
        self.url = "http://127.0.0.1:40403"

    def save(self, name, value):
        p = self.out / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def http(self, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url + path, data=data,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.load(response)

    def cli(self, args, timeout=90):
        return subprocess.run([self.binary, "--grpc-host", "127.0.0.1", *args],
                              capture_output=True, text=True, timeout=timeout)

    def start(self):
        source = (Path(self.args.rholo) / "tools/devnet.sh").read_text()
        priv = re.search(r"VALIDATOR_PRIV=\(\s*\n(.*?)\n\)", source, re.S).group(1)
        pub = re.search(r"VALIDATOR_PUB=\(\s*\n(.*?)\n\)", source, re.S).group(1)
        self.private = re.findall(r'"([0-9a-f]{64})"', priv)[:2]
        self.public = re.findall(r'"([0-9a-f]{130})"', pub)[:2]
        data = self.out / "node-data"
        if data.exists():
            raise RuntimeError("refusing to reuse an existing node data directory")
        data.mkdir()
        key = self.out / "validator.hex"
        key.write_text(self.private[0])
        key.chmod(0o600)
        bonds, wallets = self.out / "bonds.txt", self.out / "wallets.txt"
        bonds.write_text(self.public[0] + " 100\n")
        wallets.write_text("".join(rev_address(pk) + ",1000000000000\n" for pk in self.public))
        self.report["funded_fixture_addresses"] = wallets.read_text().splitlines()
        self.node_log = (self.out / "node.log").open("w")
        self.node = subprocess.Popen([
            self.binary, "run", "-s", "--dev-mode",
            "--validator-private-key-path", str(key),
            "--data-dir", str(data), "--bonds-file", str(bonds),
            "--wallets-file", str(wallets), "--host", "127.0.0.1",
            "--api-host", "127.0.0.1", "--no-upnp",
        ], stdout=self.node_log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if self.node.poll() is not None:
                raise RuntimeError("node exited; see node.log")
            try:
                s = self.http("/api/status")
                if s.get("latestBlockNumber", 0) >= 1:
                    self.report["initial_status"] = s
                    return
            except Exception:
                pass
            time.sleep(1)
        raise RuntimeError("node startup timed out")

    def explore(self, term, block):
        return self.http("/api/v1/explore-deploy-by-block-hash",
                         {"term": term, "blockHash": block, "usePreStateHash": False})

    def submit(self, label, term, signer=0):
        path = self.out / "terms" / (label + ".rho")
        path.parent.mkdir(exist_ok=True)
        path.write_text(term)
        height = self.http("/api/status")["latestBlockNumber"] - 1
        shard = self.http("/api/status")["shardId"]
        result = self.cli(["deploy", "--phlo-limit", "100000000", "--phlo-price", "1",
                           "--private-key", self.private[signer], "--shard-id", shard,
                           "--valid-after-block-number", str(height), str(path)])
        (self.out / (label + "-deploy.log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise AssertionError(label + ": signed deploy rejected: " +
                                 (result.stdout + result.stderr)[-1600:])
        match = re.search(r"DeployId is:\s*([0-9a-f]+)", result.stdout + result.stderr)
        if not match:
            raise AssertionError("missing signed deploy ID: " + result.stdout[-1000:])
        sig = match.group(1)
        deadline = time.monotonic() + 90
        receipt = None
        while time.monotonic() < deadline:
            try:
                receipt = self.http("/api/deploy/" + sig)
                block = (receipt.get("blockHash") or receipt.get("blockInfo", {}).get("blockHash")) if isinstance(receipt, dict) else None
                if block:
                    body = self.http("/api/block/" + block)
                    entries = [d for d in body.get("deploys", []) if d.get("term") == term]
                    if len(entries) != 1:
                        raise AssertionError("carrying block lacks exactly one matching deploy")
                    self.save(label + "-receipt.json",
                              {"receipt": receipt, "block": body, "term_sha256":
                               hashlib.sha256(term.encode()).hexdigest()})
                    return block, sig
            except urllib.error.HTTPError:
                pass
            propose = self.cli(["propose"])
            (self.out / (label + "-propose.log")).write_text(propose.stdout + propose.stderr)
            time.sleep(0.3)
        raise AssertionError(label + ": not included: " + repr(receipt))

    def install(self, label="install"):
        channel = "qkb-installed-uri-" + label
        original = Path(self.args.contract).read_text()
        self.report["contract_sha256"] = hashlib.sha256(original.encode()).hexdigest()
        term = "new outputId(`rho:rchain:deployId`) in {\n" + original + (
            f'\n| for (@uri <- outputId) {{ @"{channel}"!(uri) }}\n}}')
        block, sig = self.submit(label, term)
        reply = self.explore(f'for (@uri <- @"{channel}") {{ @"out"!(uri) }}', block)
        self.save(label + "-publication.json", reply)
        uris = set(re.findall(r"rho:id:[a-z0-9]+", json.dumps(reply)))
        if len(uris) != 1:
            raise AssertionError("publication returned no unique registry URI: " + repr(reply))
        self.uri = Uri(uris.pop())

        publication = {"uri": self.uri, "block": block, "deploy": sig}
        self.report.setdefault("publications", {})[label] = publication
        if label == "install":
            self.report["publication"] = publication

    def case(self, label, op, values, expected, signer=0, fake=False):
        expected = expected_value(expected)
        rendered = [rho(v) for v in values]
        if op in ("assert", "answer"):
            rendered += ["*impostor" if fake else "*deployerId"]
        args = ", ".join([rho(op), *rendered, "*reply"])
        term = (
            "new lookup(`rho:registry:lookup`), deployerId(`rho:rchain:deployerId`),"
            " service, reply, impostor in {\n"
            f"lookup!({rho(self.uri)}, *service) |\n"
            f'for (QKB <- service) {{ QKB!({args}) | for (@actual <- reply) {{ '
            f'@"qkb-case-{label}"!((actual == {rho(expected)}, actual)) }} }} }}')
        block, sig = self.submit(label, term, signer)
        self.finish_case(label, op, expected, block, sig)

    def finish_case(self, label, op, expected, block, sig):
        reply = self.explore(f'for (@(ok, actual) <- @"qkb-case-{label}") {{ @"out"!(ok) }}', block)
        actual = self.explore(f'for (@(ok, actual) <- @"qkb-case-{label}") {{ @"out"!(actual) }}', block)
        passed = reply.get("replySource") == "out" and any(
            x.get("ExprBool", {}).get("data") is True for x in reply.get("expr", []))
        self.save(label + "-result.json", {"assertion": reply, "actual": actual,
                                         "expected_rholang": rho(expected)})
        row = {"id": label, "operation": op, "pass": passed, "block": block, "deploy": sig}
        self.report["cases"].append(row)
        self.save("report.json", self.report)
        print(json.dumps(row), flush=True)
        if not passed:
            raise AssertionError(label + ": runtime/reference mismatch: " + repr(actual))


    def native_semantic_vector(self):
        label = "native-aggregate-counterexample"
        expected = (True, 1)
        term = (
            "new zfa(`rho:qucalc:zfa`), reply in { "
            "zfa!([0, 0, 3, 3], *reply) | for (@actual <- reply) { "
            '@"qkb-case-' + label + '"!((actual == (true, 1), actual)) } }')
        block, sig = self.submit(label, term)
        self.finish_case(label, "rho:qucalc:zfa", expected, block, sig)

    def logic_batch(self, label, rows):
        term = (
            "new lookup(`rho:registry:lookup`), service, check in { "
            "lookup!(" + rho(self.uri) + ", *service) | for (QKB <- service) { "
            "contract check(@rows, @i) = { "
            "if (i == rows.length()) { "
            '@"qkb-case-' + label + '"!((true, i)) } else { '
            "new reply in { let @row <- rows.nth(i) in { "
            "QKB!(row.nth(0), row.nth(1), row.nth(2), *reply) | "
            "for (@actual <- reply) { if (actual == row.nth(3)) { check!(rows, i + 1) } "
            'else { @"qkb-case-' + label + '"!((false, (i, actual))) } } } } } } | '
            "check!(" + rho(rows) + ", 0) } }")
        block, sig = self.submit(label, term)
        self.finish_case(label, "logic-vector-batch", len(rows), block, sig)

    def gate_batch(self, label, rows):
        term = (
            "new lookup(`rho:registry:lookup`), deployerId(`rho:rchain:deployerId`), "
            "zfa(`rho:qucalc:zfa`), service, check in { "
            "lookup!(" + rho(self.uri) + ", *service) | for (QKB <- service) { "
            "contract check(@rows, @i) = { "
            "if (i == rows.length()) { "
            '@"qkb-case-' + label + '"!((true, i)) } else { '
            "new nativeReply, qkbReply in { let @row <- rows.nth(i) in { "
            "zfa!(row.nth(0), *nativeReply) | "
            'QKB!("assert", "gate-census", row.nth(0), *deployerId, *qkbReply) | '
            "for (@native <- nativeReply & @actual <- qkbReply) { "
            "if (actual == row.nth(1) and native == row.nth(2)) { check!(rows, i + 1) } "
            'else { @"qkb-case-' + label + '"!((false, (i, native, actual))) } } } } } } | '
            "check!(" + rho(rows) + ", 0) } }")
        block, sig = self.submit(label, term)
        self.finish_case(label, "native-vs-per-axis-gate-batch", len(rows), block, sig)

    def suite(self, ref):
        kb = ref.KB()
        identities = [ref.DeployerId(bytes.fromhex(k)) for k in self.public]
        def apply(label, op, values, signer=0, fake=False):
            who = object() if fake else identities[signer]
            if op == "assert":
                expected = kb.assert_closure(*values, who)
            elif op == "answer":
                expected = kb.answer(*values, who)
            elif op == "compatible":
                expected = ref.compatible(*values)
                if expected is None:
                    expected = "invalid proposition"
            elif op == "conjoin":
                expected = ref.conjoin(*values)
            else:
                expected = getattr(kb, op)(*values)
            contract_values = list(values)
            if op in ("answer", "solve") and isinstance(contract_values[0], tuple) and len(contract_values[0]) == 2:
                q = contract_values[0]
                contract_values[0] = (list(q[0]), q[1])
            if op == "assert" and isinstance(contract_values[0], tuple) and len(contract_values[0]) == 2 and isinstance(contract_values[0][0], tuple):
                name = contract_values[0]
                contract_values[0] = (list(name[0]), name[1])
            if op == "redundancy":
                contract_values[0] = registry_uri(contract_values[0])
            self.case(label, op, contract_values, expected, signer, fake)
            return expected
        apply("unknown-ways", "ways", ["missing"])
        a = apply("closed-assert", "assert", ["plaquette", ref.from_str("^<v>")])
        for i in range(4):
            apply("repeat-" + str(i), "assert", ["plaquette", ref.from_str("^<v>")])
        apply("second-signer", "assert", ["plaquette", ref.from_str("^<v>")], signer=1)
        apply("second-way", "assert", ["plaquette", ref.from_str("^>v<")])
        apply("ways-two", "ways", ["plaquette"])
        apply("holders-two", "redundancy", [a["id"]])
        apply("first-cascade", "first", ["plaquette"])
        apply("aggregate-counterexample", "assert", ["bad", [0, 0, 3, 3]])
        apply("short-closure", "assert", ["bad", [0, 1]])
        apply("forged-attester", "assert", ["forged", [0, 3, 1, 2]], fake=True)
        apply("forged-no-write", "ways", ["forged"])
        q = ref.question_id(ref.from_str("^>"), 0)
        apply("answer-before-ask", "answer", [q, ref.from_str("<v")])
        apply("solve-before-ask", "solve", [q])
        apply("ask-after-answer", "ask", [list(q[0]), q[1]])
        apply("ask-replayed", "ask", [list(q[0]), q[1]])
        apply("solve-after-replay", "solve", [q])
        apply("unrelated-name", "assert", [q, ref.from_str("+-+-")])
        apply("solve-namespace", "solve", [q])
        q2 = ref.question_id(ref.from_str("^>"), 1)
        apply("other-context", "ask", [list(q2[0]), q2[1]])
        apply("other-context-empty", "solve", [q2])
        for i, bad in enumerate([[8], [-1], [True], "bad", None, (0, 1, 2, 3), [0, 1] * 33]):
            apply(f"invalid-assert-{i}", "assert", ["invalid", bad])
            apply(f"invalid-answer-{i}", "answer", [q, bad])
            apply(f"invalid-ask-{i}", "ask", [bad, 0])
        apply("invalid-context", "ask", [[0], 4])
        apply("invalid-context-type", "ask", [[0], "0"])
        apply("invalid-question-answer", "answer", [("bad",), [3, 1]])
        apply("invalid-question-solve", "solve", [("bad",)])
        for i, (p, q_) in enumerate([
            ("bot", "top"), ((0, 1), (0, -1)), ((0, 1), (1, 1)),
            ((0, 1), (3, 1)), (("and", (0, 1), (3, 1)), "top"),
            (("and", (0, 1), (3, 1)), (3, -1)),
            ((4, 1), "top"), ((0, 0), "top"), (("and", (3, 1), (0, 1)), "top"),
        ]):
            apply(f"compatible-{i}", "compatible", [p, q_])
            apply(f"conjoin-{i}", "conjoin", [p, q_])

        # All five reference seeds, with competing closures submitted out of priority order.
        import qucalc_search as qs
        self.native_semantic_vector()
        for index, seed in enumerate(["^", "^>", "+^", "^<", "/+"]):
            seed_ts = ref.from_str(seed)
            qid = ref.question_id(seed_ts, 2)
            apply(f"solver-{index}-ask", "ask", [seed_ts, 2])
            candidates = [ref.from_str(x["cont"]) for x in
                          qs.search(seed, max_depth=4, limit=None, absorbing=False)]
            candidates.sort(key=lambda c: ref.cascade_key(seed_ts + c))
            selected = []
            for c in (candidates[-1], candidates[len(candidates)//2], candidates[0]):
                if c not in selected:
                    selected.append(c)
            for j, c in enumerate(selected):
                apply(f"solver-{index}-answer-{j}", "answer", [qid, c])
            got = apply(f"solver-{index}-result", "solve", [qid])
            oracle = qs.solve(seed, max_depth=4)
            if not oracle["solved"] or got != ref.from_str(oracle["cont"]):
                raise AssertionError(f"solver reference mismatch on {seed}")

        self.report["python_only_groups"] = {
            "f": "sharded model; current Rholang contract has one state cell",
            "j": "mutable queued callbacks; Rholang values are immutable"}
        if self.args.suite == "functional":
            self.report["runtime_vectors"] = {"solver_seeds": 5}
            return

        # Runtime coverage of every length-4 history admitted by the native bit:
        # 168 actual per-axis closures and all 216 aggregate-only false positives.
        main_service = self.uri
        words = [list(word) for word in itertools.product(range(8), repeat=4)
                 if ref.rholo_native_zfa(list(word))]
        positives = sum(ref.is_closure(ts) for ts in words)
        phase_code = {"+1": 1, "-1": -1, "+i": 2, "-i": -2}
        if len(words) != 384 or positives != 168:
            raise AssertionError("unexpected native-positive census")
        for offset in range(0, len(words), 32):
            # This is an admission conformance census, not a growing-store benchmark.
            # Each bounded batch has its own installed QKB and independent reference.
            label = f"gate-census-{offset//32}"
            self.install(label + "-install")
            batch_kb = ref.KB()
            rows = [[ts, expected_value(batch_kb.assert_closure("gate-census", ts, identities[0])),
                     (True, phase_code[ref.phase(ts)])]
                    for ts in words[offset:offset+32]]
            self.gate_batch(label, rows)
        self.uri = main_service

        # All 22 well-formed propositions, both operations on every ordered pair.
        props = ["bot", "top"] + [(a, s) for a in range(4) for s in (1, -1)]
        props += [("and", sp, g) for sp in ref.SPATIAL_ATOMS for g in [(3, 1), (3, -1)]]
        if len(props) != 22:
            raise AssertionError("unexpected proposition census")
        logic_rows = []
        for p, q_ in itertools.product(props, repeat=2):
            logic_rows.append(["compatible", p, q_, ref.compatible(p, q_)])
            logic_rows.append(["conjoin", p, q_, ref.conjoin(p, q_)])
        for offset in range(0, len(logic_rows), 96):
            self.logic_batch(f"logic-census-{offset//96}", logic_rows[offset:offset+96])
        self.report["runtime_vectors"] = {
            "native_positive_length4": 384, "per_axis_admitted": 168,
            "aggregate_only_refused": 216, "proposition_pairs": 484,
            "logic_comparisons": 968, "solver_seeds": 5,
            "gate_batch_size": 32, "gate_instances": 12}
        self.report["python_only_groups"] = {
            "f": "sharded model; current Rholang contract has one state cell",
            "j": "mutable queued callbacks; Rholang values are immutable"}
        self.report["runtime_groups"] = ["a", "b", "c", "d", "e", "g", "h", "i"]

    def logic_only(self, ref):
        props = ["bot", "top"] + [(a, sign) for a in range(4) for sign in (1, -1)]
        props += [("and", sp, gauge) for sp in ref.SPATIAL_ATOMS
                  for gauge in [(3, 1), (3, -1)]]
        assert len(props) == 22
        rows = []
        for p, q in itertools.product(props, repeat=2):
            rows += [["compatible", p, q, ref.compatible(p, q)],
                     ["conjoin", p, q, ref.conjoin(p, q)]]
        size = self.args.logic_batch_size
        for offset in range(0, len(rows), size):
            self.logic_batch(f"logic-only-{offset//size}", rows[offset:offset+size])
        self.report["runtime_vectors"] = {
            "proposition_pairs": 484, "logic_comparisons": len(rows),
            "logic_batch_size": size}

    def close(self):
        if self.node is not None:
            self.node.terminate()
            try:
                self.node.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.node.kill()
                self.node.wait()
            self.node_log.close()
        key = self.out / "validator.hex"
        key.unlink(missing_ok=True)
        self.report["finished_utc"] = datetime.now(timezone.utc).isoformat()
        self.save("report.json", self.report)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rnode", required=True)
    ap.add_argument("--expected-binary-sha256", required=True)
    ap.add_argument("--rholo", required=True)
    ap.add_argument("--qlf", required=True)
    ap.add_argument("--contract", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--suite", choices=["functional", "logic", "all"], default="functional")
    ap.add_argument("--logic-batch-size", type=int, default=16)
    args = ap.parse_args()
    if not 1 <= args.logic_batch_size <= 96:
        ap.error("--logic-batch-size must be in 1..96")

    qlf_sha = subprocess.check_output(
        ["git", "-C", args.qlf, "rev-parse", "HEAD"], text=True).strip()
    if qlf_sha != QLF:
        raise SystemExit("QLF checkout does not match the pinned reference")
    sys.path.insert(0, str(Path(args.qlf).resolve()))
    import qkb_reference as ref
    run = Run(args)
    try:
        ref._selfcheck()
        run.report["python_reference"] = "a-j PASS"
        run.start()
        run.install()
        if args.suite == "logic":
            run.logic_only(ref)
        else:
            run.suite(ref)
        run.report["result"] = "PASS"
    except Exception as exc:
        run.report["result"] = "FAIL"
        run.report["error"] = type(exc).__name__ + ": " + str(exc)
        raise
    finally:
        run.close()


if __name__ == "__main__":
    main()
