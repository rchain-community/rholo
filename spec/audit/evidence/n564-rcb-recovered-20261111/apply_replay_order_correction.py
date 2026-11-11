#!/usr/bin/env python3
"""Single-variable replay-order intervention on pinned source; not a cost waiver."""
import hashlib
import json
import pathlib

path = pathlib.Path("rspace/src/replay_rspace.rs")
original = path.read_bytes()
source = original.decode()
before = "        let mut data = ReplayData::default();\n        for event in log {\n"
after = "        let mut data = ReplayData::default();\n        for event in log.iter().rev() {\n"
assert source.count(before) == 1, "single known replay binding-construction loop"
path.write_text(source.replace(before, after))
print(json.dumps({"file": str(path), "original_sha256": hashlib.sha256(original).hexdigest(),
                  "corrected_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                  "change": "one iteration order only; records, costs, state and validation guards unchanged"}))
