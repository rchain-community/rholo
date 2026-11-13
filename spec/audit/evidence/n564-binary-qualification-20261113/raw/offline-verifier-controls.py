#!/usr/bin/env python3
"""Offline positive/adversarial controls for the retained C357 independent capture harness."""
import contextlib
import copy
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
from unittest.mock import patch
from urllib.parse import urlsplit

Path = pathlib.Path
record = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("capture", record/"c357-verify-capture.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
base = json.loads((record/"natural/raw/green/block-bootstrap.json").read_text())

class Response:
    status = 200
    headers = {}
    def __init__(self, body): self.body = body
    def read(self): return self.body
    def __enter__(self): return self
    def __exit__(self, *args): pass

for fault in ["none", "missing-state", "empty-deploys", "wrong-deploy", "zero-cost", "errored", "unfinalized", "raw-disagreement", "binary-mismatch"]:
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)/"receipts"
        (root/"runtime").mkdir(parents=True)
        (root/"runtime/rnode.sha256").write_text("a"*64+"  rnode\n")
        source = Path(temp)/"source"
        arm = source/"target/n564-natural-trigger/green"
        arm.mkdir(parents=True)
        (arm/"inclusion-block.txt").write_text(base["blockInfo"]["blockHash"])
        (arm/"registry-deploy-id.txt").write_text(base["deploys"][0]["sig"])
        def fetch(url, timeout):
            parsed = urlsplit(url)
            block = copy.deepcopy(base)
            if fault == "missing-state": block["blockInfo"].pop("postStateHash")
            if fault == "empty-deploys": block["deploys"] = []
            if fault == "wrong-deploy": block["deploys"][0]["sig"] = "wrong"
            if fault == "zero-cost": block["deploys"][0]["cost"] = 0
            if fault == "errored": block["deploys"][0]["errored"] = True
            if parsed.path.endswith("/raw"):
                body = json.dumps({"fixture":"x"*200, "node":parsed.port if fault=="raw-disagreement" else 0}).encode()
            elif "/is-finalized/" in parsed.path: body = json.dumps(fault!="unfinalized").encode()
            elif "/block/" in parsed.path: body = json.dumps(block).encode()
            else: body = b"{}"
            return Response(body)
        def docker(args, text):
            if args[1] == "exec":
                return ("b" if fault=="binary-mismatch" else "a")*64+"  /usr/local/bin/rnode\n"
            return json.dumps([{"Id":"fixture","Image":"fixture","Created":"fixture","State":{"StartedAt":"fixture"}}])
        def redirect_path(*parts):
            return source if parts==("/tmp/c357-source",) else Path(*parts)
        refused = False
        with patch.object(m.pathlib, "Path", side_effect=redirect_path), patch.object(m.urllib.request, "urlopen", side_effect=fetch), patch.object(m.subprocess, "check_output", side_effect=docker), patch.object(m.sys, "argv", ["capture", str(root)]), contextlib.redirect_stdout(io.StringIO()):
            try: m.main()
            except AssertionError: refused = True
        assert refused == (fault != "none"), (fault, refused)
        print(f"{fault}: " + ("REJECTED" if refused else "PASS"))
print("PASS: positive fixture plus 8 adversarial capture controls; offline harness checks only")
