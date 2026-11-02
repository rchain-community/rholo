"""Offline falsifiers for issue #522: executable control-flow witnesses."""
import importlib.util
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
s = importlib.util.spec_from_file_location("restart_load_harness", ROOT / "consensus-restart-under-load.py")
harness = importlib.util.module_from_spec(s)
s.loader.exec_module(harness)


class RestartLoadHarnessTests(unittest.TestCase):
    def test_restart_schedule_includes_genesis_master(self):
        self.assertEqual([harness.victim_for_cycle(c) for c in range(2)], [1, 0])

    def test_bootstrap_http_400_is_recorded_and_retried_before_kill(self):
        from urllib.error import HTTPError
        with tempfile.TemporaryDirectory() as folder:
            events = Path(folder) / "events.jsonl"
            not_finalized = HTTPError(
                "http://127.0.0.1:40403/api/last-finalized-block",
                400, "no finalized block yet", {}, None,
            )
            agreed = [(2, "a"), (2, "a")]
            with (
                patch.object(harness, "agreement", side_effect=[not_finalized, agreed]),
                patch.object(harness.time, "sleep", return_value=None),
            ):
                self.assertEqual(
                    harness.wait_baseline(2, time.monotonic() + 2, events), agreed
                )
            self.assertIn("baseline_read_error", events.read_text())
            self.assertIn("baseline_ready", events.read_text())

    def test_bootstrap_permanent_http_400_never_passes(self):
        from urllib.error import HTTPError
        with tempfile.TemporaryDirectory() as folder:
            events = Path(folder) / "events.jsonl"
            not_finalized = HTTPError(
                "http://127.0.0.1:40403/api/last-finalized-block",
                400, "no finalized block", {}, None,
            )
            with patch.object(harness, "agreement", side_effect=not_finalized):
                with self.assertRaisesRegex(RuntimeError, "initial finalized baseline unavailable"):
                    harness.wait_baseline(2, time.monotonic() - 1, events)

    def test_finalized_height_regression_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            events = Path(folder) / "events.jsonl"
            with patch.object(harness, "agreement", return_value=[(9, "a"), (10, "a")]):
                with self.assertRaisesRegex(RuntimeError, "regressed"):
                    harness.observed_finality(2, {0: (10, "a"), 1: (10, "a")}, events)

    def test_same_height_conflicting_hash_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            events = Path(folder) / "events.jsonl"
            with patch.object(harness, "agreement", return_value=[(10, "a"), (10, "b")]):
                with self.assertRaisesRegex(RuntimeError, "conflicting finalized"):
                    harness.observed_finality(2, {}, events)

    def test_deploy_status_waits_for_a_delayed_success(self):
        with tempfile.TemporaryDirectory() as folder:
            events = Path(folder) / "events.jsonl"
            responses = iter([{"NotProcessed": {}}, {"ProcessedWithSuccess": {}}])
            with (
                patch.object(harness, "observed_finality", return_value=[(10, "a")]),
                patch.object(harness, "get", side_effect=lambda *_: next(responses)),
                patch.object(harness.time, "sleep", return_value=None),
            ):
                harness.wait_deploys_resolved(1, [("deploy1", "marker", 0, 0)],
                                              time.monotonic() + 1, events, {})


    def test_wait_new_boot_requires_a_different_process_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            events = Path(folder) / "events.jsonl"
            seen = iter(["1-1", "1-1", "2-2"])
            with (
                patch.object(harness, "boot_id", side_effect=lambda _: next(seen)),
                patch.object(harness.time, "sleep", return_value=None),
            ):
                self.assertEqual(
                    harness.wait_new_boot(0, "1-1", time.monotonic() + 1, events), "2-2"
                )
            self.assertIn("new_boot_id", events.read_text())

    def test_wait_new_boot_fails_when_the_process_identity_never_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            events = Path(folder) / "events.jsonl"
            with (
                patch.object(harness, "boot_id", return_value="1-1"),
                patch.object(harness.time, "sleep", return_value=None),
            ):
                with self.assertRaisesRegex(RuntimeError, "did not restart with a new bootId"):
                    harness.wait_new_boot(0, "1-1", time.monotonic() - 1, events)

    def test_control_node_spec_drops_the_validator_identity(self):
        config = {
            "Entrypoint": ["rnode"],
            "Cmd": ["run", "--bootstrap", "rnode://abc@bootstrap:40400",
                    "--validator-private-key", "deadbeef",
                    "--validator-private-key-path", "/var/lib/rnode/validator.hex",
                    "--validator-public-key=04aa", "--deployer-private-key", "cafe",
                    "--autopropose", "--propose-on-deploy", "--host", "old-name",
                    "--port", "40400"],
        }
        inspected = type("R", (), {
            "returncode": 0, "stdout": json.dumps([{"Config": config}]), "stderr": "",
        })()
        with patch.object(harness, "docker", return_value=inspected):
            entrypoint, cmd = harness.control_node_spec()
        self.assertEqual(entrypoint, ["rnode"])
        self.assertIn("--bootstrap", cmd)
        for dropped in ("--validator-private-key", "--validator-private-key-path",
                        "--deployer-private-key", "--autopropose", "--propose-on-deploy",
                        "--host", "deadbeef", "cafe", "old-name",
                        "/var/lib/rnode/validator.hex", "--validator-public-key=04aa"):
            self.assertNotIn(dropped, cmd)

    def test_flipped_is_a_different_same_shape_hash(self):
        value = "ab" * 32
        self.assertNotEqual(harness.flipped(value), value)
        self.assertEqual(len(harness.flipped(value)), 64)


if __name__ == "__main__":
    unittest.main()
