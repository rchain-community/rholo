"""Isolated controls for the #457 mature-join arm's evidence extraction."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "n457_mature_join", Path(__file__).parents[1] / "tools/n457-mature-join-arm.py"
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class MatureJoinEvidence(unittest.TestCase):
    def test_two_digit_sequences_stay_whole(self):
        # The 2026-11-13 defect: one capture group unpacked into `(_, seq)` splits "15" into "1"
        # and "5", so the arm witnessed sequence 5 for a block that used 15.
        log = (
            "INFO proposed and added block #16 (seq 15)\n"
            "INFO proposed and added block #18 (seq 16)\n"
        )
        self.assertEqual(module.proposal_sequences(log), [(16, 15), (18, 16)])

    def test_a_log_without_a_proposal_yields_nothing(self):
        self.assertEqual(
            module.proposal_sequences("LFS state is successfully restored."), []
        )

    def test_a_refusal_line_is_not_a_proposal(self):
        log = (
            "ERROR Block #14 852e11dc faulted at dag insert (equivocation detected)\n"
            "INFO proposed and added block #14 (seq 13)\n"
        )
        self.assertEqual(module.proposal_sequences(log), [(14, 13)])


if __name__ == "__main__":
    unittest.main()
