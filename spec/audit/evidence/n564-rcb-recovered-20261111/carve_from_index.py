#!/usr/bin/env python3
"""Re-extract all five contiguous records from the preserved raw pool copy.

Reads ordinary file bytes only. The raw database copy remains a private input;
this script never opens LMDB or a validator directory. All indexed occurrences
must match their recorded SHA-256, not just the first occurrence selected.
"""
import argparse
import hashlib
import json
import pathlib

p = argparse.ArgumentParser()
p.add_argument("raw_copy", type=pathlib.Path)
p.add_argument("--index", type=pathlib.Path, default=pathlib.Path(__file__).parent / "carved-candidates.json")
p.add_argument("--output", type=pathlib.Path, required=True)
args = p.parse_args()
index = json.loads(args.index.read_text())
raw = args.raw_copy.read_bytes()
assert hashlib.sha256(raw).hexdigest() == index["source_raw_sha256"]
args.output.mkdir(parents=True, exist_ok=True)
out = []
for c in index["candidates"]:
    for span in c["offsets"]:
        wire = raw[span["start"]:span["end"]]
        assert len(wire) == c["wire_bytes"]
        assert hashlib.sha256(wire).hexdigest() == c["wire_sha256"]
    first = c["offsets"][0]
    name = c["sig"] + "-" + c["wire_sha256"][:12] + ".bin"
    (args.output / name).write_bytes(raw[first["start"]:first["end"]])
    out.append({"signature": c["sig"], "sha256": c["wire_sha256"],
                "verified_occurrences": len(c["offsets"])})
print(json.dumps({"contiguous_records": len(out), "records": out}, indent=2))
