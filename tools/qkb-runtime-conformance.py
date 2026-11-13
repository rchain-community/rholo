#!/usr/bin/env python3
"""Run QLF #216 against a fresh, loopback-only, single-validator Rholo node.

Requires a built rnode and pycryptodome (REV-address derivation only). The QLF
reference is imported from an explicitly supplied, source-pinned checkout.
"""
import argparse
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
        self.report = {
            "result": "INCOMPLETE", "runtime_source": RHOLO, "qlf_source": QLF,
            "binary_sha256": hashlib.sha256(Path(self.binary).read_bytes()).hexdigest(),
            "scope": "isolated-single-validator-loopback", "cases": [],
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

    def install(self):
        original = Path(self.args.contract).read_text()
        self.report["contract_sha256"] = hashlib.sha256(original.encode()).hexdigest()
        term = "new outputId(`rho:rchain:deployId`) in {\n" + original + (
            '\n| for (@uri <- outputId) { @"qkb-installed-uri"!(uri) }\n}')
        block, sig = self.submit("install", term)
        reply = self.explore('for (@uri <- @"qkb-installed-uri") { @"out"!(uri) }', block)
        self.save("publication.json", reply)
        uris = set(re.findall(r"rho:id:[a-z0-9]+", json.dumps(reply)))
        if len(uris) != 1:
            raise AssertionError("publication returned no unique registry URI: " + repr(reply))
        self.uri = Uri(uris.pop())
        self.report["publication"] = {"uri": self.uri, "block": block, "deploy": sig}

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
        self.report["python_only_groups"] = {
            "f": "sharded model; current Rholang contract has one state cell",
            "j": "mutable queued callbacks; Rholang values are immutable"}
        self.report["runtime_groups"] = ["a", "b", "c", "d", "e", "g", "h", "i"]

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
        self.save("report.json", self.report)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rnode", required=True)
    ap.add_argument("--rholo", required=True)
    ap.add_argument("--qlf", required=True)
    ap.add_argument("--contract", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    sys.path.insert(0, str(Path(args.qlf).resolve()))
    import qkb_reference as ref
    run = Run(args)
    try:
        ref._selfcheck()
        run.report["python_reference"] = "a-j PASS"
        run.start()
        run.install()
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
