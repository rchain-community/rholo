#!/usr/bin/env python3
"""Verify every content hash and the full closure of each recovered root.

The radix framing is the pinned source's encode/decode format: index byte,
prefix-length/type byte, prefix, 32-byte child or leaf hash. This verifier reads
only the compact evidence fixture; it never opens a database or a network.
"""
import gzip
import hashlib
import json
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent
provenance = json.loads((root / "historical-state-provenance.json").read_text())
compressed = (root / "deploys/historical-state.bin.gz").read_bytes()
assert hashlib.sha256(compressed).hexdigest() == provenance["gzip_sha256"]
raw = gzip.decompress(compressed)
assert hashlib.sha256(raw).hexdigest() == provenance["raw_sha256"]
assert raw[:4] == b"RCB1"
at = 4


def read_count():
    global at
    count = struct.unpack_from("<I", raw, at)[0]
    at += 4
    return count


roots = []
for _ in range(read_count()):
    roots.append(raw[at:at + 32])
    at += 32
stores = []
for _ in range(2):
    store = {}
    for _ in range(read_count()):
        key = raw[at:at + 32]
        at += 32
        length = read_count()
        value = raw[at:at + length]
        at += length
        assert len(key) == 32 and len(value) == length
        assert hashlib.blake2b(value, digest_size=32).digest() == key
        assert key not in store
        store[key] = value
    stores.append(store)
assert at == len(raw)
history, cold = stores
assert len(history) == provenance["nodes"] and len(cold) == provenance["leaves"]

results = {}
for state_root in roots:
    visited = set()
    leaf_hashes = set()
    paths = []

    def walk(key, prefix, ancestors):
        assert key not in ancestors, "cyclic radix graph"
        node = history[key]
        visited.add(key)
        position = 0
        indices = set()
        while position < len(node):
            assert position + 2 <= len(node)
            index, tag = node[position:position + 2]
            assert index not in indices
            indices.add(index)
            size = tag & 127
            end = position + 2 + size
            assert end + 32 <= len(node)
            path = prefix + bytes([index]) + node[position + 2:end]
            value = node[end:end + 32]
            position = end + 32
            if tag & 128:
                walk(value, path, ancestors | {key})
            else:
                assert value in cold, "missing cold leaf"
                assert len(path) == 33, "unexpected RSpace key length"
                paths.append(path)
                leaf_hashes.add(value)
        assert position == len(node)

    walk(state_root, b"", set())
    assert len(set(paths)) == len(paths), "duplicate logical key"
    result = {"nodes": len(visited), "leaf_paths": len(paths),
              "unique_leaves": len(leaf_hashes), "missing": 0, "invalid_hashes": 0}
    assert result == provenance["roots"][state_root.hex()]
    results[state_root.hex()] = result
print(json.dumps({"all_hashes_and_root_closures_valid": True, "roots": results}, indent=2))
