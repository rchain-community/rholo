#!/usr/bin/env python3
"""Independent verifier for contiguous DeployDataProto candidates.

No signing keys or chain connection. The production Rust verifier is a separate
check. ECDSA receives the BLAKE2b-256 digest through a 32-byte Prehashed interface;
the SHA256 name selects digest length only and does not rehash that digest.
"""
import hashlib
import json
import pathlib
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils


def varint(data, at):
    value = 0
    for shift in range(0, 70, 7):
        byte = data[at]
        at += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, at
    raise ValueError("oversized varint")


def fields(data):
    at = 0
    out = []
    while at < len(data):
        start = at
        tag, at = varint(data, at)
        if tag & 7 == 0:
            value, at = varint(data, at)
        elif tag & 7 == 2:
            size, at = varint(data, at)
            value = data[at:at + size]
            if len(value) != size:
                raise ValueError("truncated field")
            at += size
        else:
            raise ValueError("unexpected wire type")
        out.append((tag >> 3, value, data[start:at]))
    return out


def verify(public, signature, data):
    digest = hashlib.blake2b(data, digest_size=32).digest()
    try:
        public.verify(signature, digest, ec.ECDSA(utils.Prehashed(hashes.SHA256())))
        return True
    except InvalidSignature:
        return False


def main(root):
    candidates = json.loads((root / "carved-candidates.json").read_text())
    results = []
    for item in candidates["candidates"]:
        matches = list((root / "carved-signed-deploys").glob(item["sig"] + "-*.bin"))
        if not matches:
            matches = [p for p in (root / "deploys").glob("*.bin")
                       if hashlib.sha256(p.read_bytes()).hexdigest() == item["wire_sha256"]]
        assert len(matches) == 1
        wire = matches[0].read_bytes()
        assert hashlib.sha256(wire).hexdigest() == item["wire_sha256"]
        parsed = fields(wire)
        by_id = {n: value for n, value, _ in parsed}
        assert len(by_id) == len(parsed), "no duplicate fields in this fixture set"
        assert set(by_id) == {1, 2, 3, 4, 5, 7, 8, 10, 11}
        assert by_id[1].hex() == item["deployer"]
        assert by_id[4].hex() == item["sig"]
        assert by_id[5] == b"secp256k1"
        assert by_id[2].decode() == item["term"]
        assert hashlib.sha256(by_id[2]).hexdigest() == item["term_sha256"]
        assert by_id[3] == item["timestamp"]
        assert by_id[7] == item["phlo_price"]
        assert by_id[8] == item["phlo_limit"]
        assert by_id[10] == item["valid_after"]
        assert by_id[11].decode() == item["shard"]
        # DeployData::to_proto_data has empty deployer/signature/algorithm fields.
        signed_data = b"".join(chunk for n, _, chunk in parsed if n not in {1, 4, 5})
        public = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256K1(), by_id[1])
        ok = verify(public, by_id[4], signed_data)
        assert ok, "candidate does not authenticate"
        mutated_data = bytearray(signed_data)
        mutated_data[3] ^= 1
        mutated_signature = bytearray(by_id[4])
        mutated_signature[-1] ^= 1
        data_control = verify(public, by_id[4], bytes(mutated_data))
        signature_control = verify(public, bytes(mutated_signature), signed_data)
        assert not data_control and not signature_control
        results.append({"signature": item["sig"], "wire_sha256": item["wire_sha256"],
                        "signed_data_blake2b256": hashlib.blake2b(signed_data, digest_size=32).hexdigest(),
                        "signature_valid": ok, "mutated_data_valid": data_control,
                        "mutated_signature_valid": signature_control})
    print(json.dumps({"implementation": "independent Python cryptography/OpenSSL ECDSA verifier",
                      "count": len(results), "results": results}, indent=2))


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent)
