"""Offline controls for the #487 finality/admission predicates.

Each predicate is fed at least one passing and one failing sample. The failing sample is the point:
a predicate that cannot fail is a test of nothing, and the live harness would then report PASS from
malformed evidence.
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


controls = _load("admission_finality_stall_controls", ROOT / "tests" / "admission_finality_stall_controls.py")


class StakeFractionTests(unittest.TestCase):
    def test_exactly_two_thirds_is_not_a_supermajority(self) -> None:
        self.assertIsNotNone(controls.stake_fraction_verdict(300, 200, must_exceed_two_thirds=True))
        self.assertIsNone(controls.stake_fraction_verdict(300, 200, must_exceed_two_thirds=False))

    def test_two_hundred_and_one_of_three_hundred_is(self) -> None:
        self.assertIsNone(controls.stake_fraction_verdict(300, 201, must_exceed_two_thirds=True))

    def test_impossible_reading_fails(self) -> None:
        self.assertIsNotNone(controls.stake_fraction_verdict(300, 301, must_exceed_two_thirds=True))
        self.assertIsNotNone(controls.stake_fraction_verdict(0, 0, must_exceed_two_thirds=False))


class SettlementTests(unittest.TestCase):
    def test_only_finalized_success_confirms(self) -> None:
        self.assertIsNone(controls.settlement_verdict("finalizedSuccess", True, True))
        self.assertIsNone(controls.settlement_verdict("includedUnfinalized", False, False))
        self.assertIsNone(controls.settlement_verdict("finalityUnknown", False, None))
        self.assertIsNone(controls.settlement_verdict("pooled", False, None))
        self.assertIsNone(controls.settlement_verdict("finalizedError", False, True))

    def test_an_unsettled_stage_cannot_confirm(self) -> None:
        self.assertIsNotNone(controls.settlement_verdict("includedUnfinalized", True, False))
        self.assertIsNotNone(controls.settlement_verdict("pooled", True, None))
        self.assertIsNotNone(controls.settlement_verdict("finalizedSuccess", False, True))
        self.assertIsNotNone(controls.settlement_verdict("made-up", False, None))


class HealthContrastTests(unittest.TestCase):
    def test_a_ready_but_not_finalising_node_is_the_issue_shape(self) -> None:
        self.assertIsNone(
            controls.health_contrast_verdict(
                {
                    "ready": True,
                    "acceptsDeploys": True,
                    "pipelineFaultsOutstanding": 0,
                    "proposalHalted": False,
                    "lastFinalityAgeMs": 9000,
                }
            )
        )

    def test_a_not_ready_or_isolated_node_is_not_the_arm(self) -> None:
        base = {
            "ready": True,
            "acceptsDeploys": True,
            "pipelineFaultsOutstanding": 0,
            "proposalHalted": False,
            "lastFinalityAgeMs": 1,
        }
        for key, value in (
            ("ready", False),
            ("acceptsDeploys", False),
            ("pipelineFaultsOutstanding", 1),
            ("proposalHalted", True),
            ("lastFinalityAgeMs", None),
        ):
            changed = dict(base, **{key: value})
            self.assertIsNotNone(controls.health_contrast_verdict(changed), key)


class FinalityObservationTests(unittest.TestCase):
    def test_unknown_availability_is_the_only_claim(self) -> None:
        self.assertIsNone(
            controls.finality_observation_verdict(
                200,
                {
                    "availability": "unknown",
                    "scope": "nodeLocal",
                    "observedAtUnixMs": 1790000000000,
                    "observedFinalityLag": 34,
                },
            )
        )

    def test_a_quorum_claim_fails(self) -> None:
        self.assertIsNotNone(
            controls.finality_observation_verdict(
                200,
                {
                    "availability": "available",
                    "scope": "nodeLocal",
                    "observedAtUnixMs": 1,
                    "observedFinalityLag": 0,
                },
            )
        )
        self.assertIsNotNone(
            controls.finality_observation_verdict(
                200,
                {
                    "availability": "unknown",
                    "scope": "nodeLocal",
                    "observedAtUnixMs": 1,
                    "observedFinalityLag": -1,
                },
            )
        )

    def test_a_503_carries_nulls(self) -> None:
        self.assertIsNone(controls.finality_observation_verdict(503, None))
        self.assertIsNotNone(
            controls.finality_observation_verdict(
                503, {"finalizedBlockNumber": 7, "finalizedBlockHash": None, "observedFinalityLag": None}
            )
        )


class ArmTests(unittest.TestCase):
    def test_ordinary_lag_requires_a_final_settle(self) -> None:
        self.assertIsNone(
            controls.ordinary_lag_verdict(
                [
                    {"stage": "includedUnfinalized", "settlementConfirmed": False, "finalized": False},
                    {"stage": "finalizedSuccess", "settlementConfirmed": True, "finalized": True},
                ]
            )
        )
        self.assertIsNotNone(
            controls.ordinary_lag_verdict(
                [{"stage": "includedUnfinalized", "settlementConfirmed": False, "finalized": False}]
            )
        )
        self.assertIsNotNone(controls.ordinary_lag_verdict([]))

    def test_partition_never_settles(self) -> None:
        observation = (
            200,
            {
                "availability": "unknown",
                "scope": "nodeLocal",
                "observedAtUnixMs": 1,
                "observedFinalityLag": 5,
            },
        )
        self.assertIsNone(
            controls.partition_stale_verdict(
                [{"stage": "includedUnfinalized", "settlementConfirmed": False, "finalized": False}],
                observation,
            )
        )
        self.assertIsNotNone(
            controls.partition_stale_verdict(
                [{"stage": "finalizedSuccess", "settlementConfirmed": True, "finalized": True}],
                observation,
            )
        )
        self.assertIsNotNone(
            controls.partition_stale_verdict(
                [{"stage": "includedUnfinalized", "settlementConfirmed": False, "finalized": False}],
                (200, {"availability": "available", "scope": "nodeLocal",
                       "observedAtUnixMs": 1, "observedFinalityLag": 0}),
            )
        )

    def test_recovery_needs_the_inclusion_block_finalized(self) -> None:
        settled = {"stage": "finalizedSuccess", "settlementConfirmed": True, "finalized": True}
        self.assertIsNone(controls.recovery_verdict(settled, 10, 10))
        self.assertIsNotNone(controls.recovery_verdict(settled, 10, 9))
        self.assertIsNotNone(
            controls.recovery_verdict(
                {"stage": "includedUnfinalized", "settlementConfirmed": False, "finalized": False},
                10,
                10,
            )
        )

    def test_no_silent_loss(self) -> None:
        self.assertIsNone(
            controls.no_silent_loss_verdict(
                ["a", "b"], {"a": "finalizedSuccess", "b": "finalizedError"}
            )
        )
        self.assertIsNotNone(controls.no_silent_loss_verdict(["a", "b"], {"a": "finalizedSuccess"}))
        self.assertIsNotNone(
            controls.no_silent_loss_verdict(
                ["a"], {"a": "includedUnfinalized"}
            )
        )


if __name__ == "__main__":
    unittest.main()
