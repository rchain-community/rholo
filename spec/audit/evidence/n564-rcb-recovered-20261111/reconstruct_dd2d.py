#!/usr/bin/env python3
"""Authenticate a bounded DeployData reconstruction using the known signature.

This does not recover contiguous bytes or a processed execution trace. It tests
an explicit metadata search space for the full term already authenticated in
other incident deploys, whose length/prefix survives beside the dd2d pool key.
No private key is required or accessed. A non-match leaves recovery unresolved.
"""
import argparse
import hashlib
import json
import pathlib
import time

from cryptography.hazmat.primitives.asymmetric import ec
from verify_carved import verify


SIG = "3045022100dd2db7e82d159ff1c0be9e7c25702cd73af097562860164ac66225fb9557419402203896bbf5a0bfbeee5a969eb278789bc1807318c0b30d0bf697845e565f92c409"


def vi(n):
    out = bytearray()
    while n > 127:
        out.append((n & 127) | 128)
        n >>= 7
    out.append(n)
    return bytes(out)


def field(n, value):
    if isinstance(value, bytes):
        return vi(n * 8 + 2) + vi(len(value)) + value
    return vi(n * 8) + vi(value) if value else b""


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--lower", type=int, default=1794159381000)
    p.add_argument("--upper", type=int, default=1794159382999)
    p.add_argument("--limits", default="5000000,1000000")
    p.add_argument("--heights", default="1070,1071,1069,1072")
    p.add_argument("--output", type=pathlib.Path, help="write results outside the preserved evidence directory")
    args = p.parse_args()
    root = pathlib.Path(__file__).parent
    output = args.output or root
    output.mkdir(parents=True, exist_ok=True)
    candidates = json.loads((root / "carved-candidates.json").read_text())["candidates"]
    item = next(c for c in candidates if c["wire_sha256"].startswith("ef9e8a0e"))
    term, public_bytes, sig = item["term"].encode(), bytes.fromhex(item["deployer"]), bytes.fromhex(SIG)
    public = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256K1(), public_bytes)
    result = {"scope": "bounded authenticated reconstruction, not a contiguous raw-byte recovery",
              "lower_timestamp": args.lower, "upper_timestamp": args.upper,
              "limits": list(map(int, args.limits.split(','))),
              "heights": list(map(int, args.heights.split(','))),
              "term_sha256": hashlib.sha256(term).hexdigest(), "matched": False}
    start = time.monotonic()
    trials = 0
    for limit in result["limits"]:
        for height in result["heights"]:
            prefix = field(2, term)
            tail = field(7, 1) + field(8, limit) + field(10, height) + field(11, b"/testnet")
            for timestamp in range(args.upper, args.lower - 1, -1):
                signed_data = prefix + field(3, timestamp) + tail
                trials += 1
                if verify(public, sig, signed_data):
                    wire = field(1, public_bytes) + prefix + field(3, timestamp) + field(4, sig) + field(5, b"secp256k1") + tail
                    assert not verify(public, sig, prefix + field(3, timestamp + 1) + tail)
                    result.update(matched=True, timestamp=timestamp, phlo_price=1,
                                  phlo_limit=limit, valid_after=height, shard="/testnet",
                                  wire_sha256=hashlib.sha256(wire).hexdigest(),
                                  wire_bytes=len(wire), signed_data_blake2b256=hashlib.blake2b(signed_data, digest_size=32).hexdigest(),
                                  signature=SIG, deployer=item["deployer"], term=item["term"])
                    (output / "authenticated-reconstruction-dd2d.bin").write_bytes(wire)
                    break
            if result["matched"]:
                break
        if result["matched"]:
            break
    result.update(trials=trials, elapsed_seconds=round(time.monotonic() - start, 3))
    (output / "dd2d-reconstruction-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k not in {"term", "signature", "deployer"}}), flush=True)


if __name__ == "__main__":
    main()
