import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_pin_probe", ROOT / "tools/release-pin-probe.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


def complete_record(name: str) -> dict:
    return {
        "name": name,
        "version": "rnode 0.1.0 (0123456789abcdef)",
        "source_sha": "0123456789abcdef",
        "binary_sha256": "a" * 64,
        "binary_path": "/usr/local/bin/rnode",
        "network_id": "testnet",
        "shard_id": "/root",
        "genesis_hash": "b" * 64,
        "genesis_raw_sha256": "c" * 64,
        "bonds_sha256": "d" * 64,
        "total_stake": 400,
        "height": 100,
        "finalized_height": 99,
        "finalized_hash": "e" * 64,
        "finalized_lag": 1,
        "ready": True,
        "unset": [],
    }


def complete_operator() -> dict:
    return {
        "release_tag": "v0.2.0",
        "release_branch": "main",
        "source_sha": "0123456789abcdef",
        "window_start_utc": "2026-12-01T10:00:00Z",
        "window_end_utc": "2026-12-01T11:00:00Z",
        "operator": "operator-key",
        "observers": ["observer-a"],
        "independent_reviewer": "reviewer-b",
        "rollback_owner": "rollback-c",
        "test_transfer": {"source": "s", "destination": "d", "amount": 1},
        "rollback": {"build": "previous-sha"},
        "evidence_destination": "spec/audit/evidence/n487-live-postdeployment-20261201",
    }


class VersionParseTests(unittest.TestCase):
    def test_source_sha_is_read_from_the_version_string(self):
        self.assertEqual(
            probe.source_sha_from_version("rholo node 0.1.0 (0123456789abcdef)"),
            "0123456789abcdef",
        )
        self.assertIsNone(probe.source_sha_from_version("rnode 0.1.0"))
        self.assertIsNone(probe.source_sha_from_version(None))


class CanonicalBondsTests(unittest.TestCase):
    def test_canonical_bonds_is_order_independent(self):
        a = [{"validator": "v2", "stake": 200}, {"validator": "v1", "stake": 200}]
        b = [{"validator": "v1", "stake": 200}, {"validator": "v2", "stake": 200}]
        bonds_a, sha_a, total_a = probe.canonical_bonds(a)
        bonds_b, sha_b, total_b = probe.canonical_bonds(b)
        self.assertEqual(sha_a, sha_b)
        self.assertEqual(bonds_a, bonds_b)
        self.assertEqual(total_a, 400)
        self.assertEqual(total_b, 400)

    def test_unparseable_bond_is_kept_in_the_hash(self):
        _, sha_a, _ = probe.canonical_bonds([{"odd": 1}])
        _, sha_b, _ = probe.canonical_bonds([{"odd": 2}])
        self.assertNotEqual(sha_a, sha_b)


class ManifestTests(unittest.TestCase):
    def test_complete_manifest_is_ok(self):
        records = [complete_record(f"validator-{i}") for i in range(4)]
        manifest = probe.build_manifest(records, complete_operator())
        self.assertTrue(manifest["checks"]["ok"], manifest["errors"])
        self.assertEqual(manifest["checks"]["validator_count"], 4)
        self.assertEqual(manifest["unset_observed"], [])
        self.assertEqual(manifest["unset_operator"], [])

    def test_missing_observed_and_operator_fields_fail_closed(self):
        record = complete_record("validator-1")
        record["finalized_hash"] = None
        record["unset"] = ["finalized_hash"]
        manifest = probe.build_manifest([record], {})
        self.assertFalse(manifest["checks"]["ok"])
        self.assertIn("validator-1:finalized_hash", manifest["unset_observed"])
        self.assertIn("operator", manifest["unset_operator"])
        self.assertFalse(manifest["checks"]["all_operator_fields"])

    def test_disagreement_across_validators_is_an_error(self):
        records = [complete_record("validator-1"), complete_record("validator-2")]
        records[1]["genesis_hash"] = "f" * 64
        records[1]["binary_sha256"] = "f" * 64
        manifest = probe.build_manifest(records, complete_operator())
        self.assertFalse(manifest["checks"]["ok"])
        self.assertFalse(manifest["checks"]["genesis_hash_agreement"])
        self.assertFalse(manifest["checks"]["binary_sha256_agreement"])
        self.assertTrue(any("genesis_hash disagrees" in e for e in manifest["errors"]))

    def test_redact_removes_endpoints_and_host_identity(self):
        record = complete_record("validator-1")
        record["http"] = "http://private.example:40403"
        record["admin"] = "http://private.example:40405"
        record["local"] = {"host": "validator-host-1"}
        manifest = probe.build_manifest([record], complete_operator())
        redacted = probe.redact_manifest(manifest)
        self.assertEqual(redacted["validators"][0]["http"], "<redacted>")
        self.assertEqual(redacted["validators"][0]["admin"], "<redacted>")
        self.assertEqual(redacted["validators"][0]["local"]["host"], "<redacted>")
        self.assertEqual(redacted["operator_fields"]["operator"], "<redacted>")
        self.assertEqual(redacted["operator_fields"]["independent_reviewer"], "<redacted>")


class CliTests(unittest.TestCase):
    def run_merge(self, out: Path, operator: Path | None) -> int:
        argv = ["merge", "--out", str(out), "--expect", "4", "--check"]
        if operator:
            argv += ["--operator-json", str(operator)]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return probe.main(argv)

    def test_merge_check_passes_only_with_pins_and_operator_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            for index in range(4):
                (out / f"validator-{index}.json").write_text(
                    json.dumps(complete_record(f"validator-{index}"))
                )
            operator = out / "operator.json"
            operator.write_text(json.dumps(complete_operator()))
            self.assertEqual(self.run_merge(out, operator), 0)
            self.assertTrue((out / "manifest.json").is_file())
            operator.unlink()
            self.assertEqual(self.run_merge(out, None), 1)

    def test_wrong_validator_count_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out / "validator-1.json").write_text(json.dumps(complete_record("validator-1")))
            operator = out / "operator.json"
            operator.write_text(json.dumps(complete_operator()))
            self.assertEqual(self.run_merge(out, operator), 1)


if __name__ == "__main__":
    unittest.main()
