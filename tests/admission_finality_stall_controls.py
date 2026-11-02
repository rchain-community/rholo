"""Pure predicates for the #487 admission/finality campaign.

The live harness (`tests/admission-finality-stall.py`) collects samples and feeds them here; the
offline tests in `tests/test_admission_finality_stall_controls.py` feed each predicate a failing
sample, so a predicate that stops discriminating fails without a devnet.

Every function returns `None` on pass, or a string naming the failed invariant.
"""

from __future__ import annotations

SETTLED = "finalizedSuccess"
UNSETTLED_STAGES = {"pooled", "notProcessed", "includedUnfinalized", "finalityUnknown"}
ALL_STAGES = UNSETTLED_STAGES | {SETTLED, "finalizedError"}


def stake_fraction_verdict(total: int, live: int, must_exceed_two_thirds: bool) -> str | None:
    """The measured live bonded stake must be on the intended side of the strict 2/3 line."""
    if total <= 0 or live < 0 or live > total:
        return f"impossible stake reading: live={live} total={total}"
    # A strict supermajority is 3*live > 2*total; exactly 2/3 is NOT one.
    supermajority = 3 * live > 2 * total
    if must_exceed_two_thirds and not supermajority:
        return f"live stake {live}/{total} is not a strict supermajority"
    if not must_exceed_two_thirds and supermajority:
        return f"live stake {live}/{total} is a strict supermajority, not the intended <=2/3"
    return None


def settlement_verdict(stage: str, confirmed: bool, finalized: bool | None) -> str | None:
    """`settlementConfirmed` is true only for a finalized successful inclusion."""
    if stage not in ALL_STAGES:
        return f"unknown settlement stage {stage!r}"
    if confirmed and not (stage == SETTLED and finalized is True):
        return f"settlementConfirmed=true on stage={stage!r} finalized={finalized!r}"
    if stage == SETTLED and (confirmed is not True or finalized is not True):
        return "finalizedSuccess without settlementConfirmed/finalized both true"
    if stage in UNSETTLED_STAGES and confirmed:
        return f"unsettled stage {stage!r} claims settlement"
    return None


def health_contrast_verdict(health: dict) -> str | None:
    """A ready, accepting node whose finality is not advancing: the issue's shape."""
    for key in ("ready", "acceptsDeploys"):
        if health.get(key) is not True:
            return f"expected {key}=true on the local-healthy arm, got {health.get(key)!r}"
    if health.get("pipelineFaultsOutstanding") not in (0, None):
        return f"pipelineFaultsOutstanding={health.get('pipelineFaultsOutstanding')!r}"
    if health.get("proposalHalted") is True:
        return "the proposer is isolated, so the arm is not the finality case"
    if health.get("lastFinalityAgeMs") is None:
        return "lastFinalityAgeMs is unknown: the arm has no finality reading to contrast"
    return None


def finality_observation_verdict(http_status: int, body: dict | None) -> str | None:
    """A node-local observation never claims live quorum."""
    if http_status == 503:
        if body:
            for key in ("finalizedBlockNumber", "finalizedBlockHash", "observedFinalityLag"):
                if body.get(key) is not None:
                    return f"503 body claims {key}={body.get(key)!r}"
        return None
    if http_status != 200 or not body:
        return f"unexpected finality-observation status {http_status}"
    if body.get("availability") != "unknown":
        return f"availability={body.get('availability')!r}, not 'unknown'"
    if body.get("scope") != "nodeLocal":
        return f"scope={body.get('scope')!r}, not 'nodeLocal'"
    if not isinstance(body.get("observedAtUnixMs"), int):
        return "observedAtUnixMs is not an integer timestamp"
    lag = body.get("observedFinalityLag")
    if lag is not None and (not isinstance(lag, int) or lag < 0):
        return f"observedFinalityLag={lag!r}"
    return None


def ordinary_lag_verdict(samples: list[dict]) -> str | None:
    """On a >2/3 network a deploy may be briefly unfinalised and must then settle."""
    if not samples:
        return "no settlement samples"
    for sample in samples:
        verdict = settlement_verdict(
            sample.get("stage"), sample.get("settlementConfirmed"), sample.get("finalized")
        )
        if verdict:
            return verdict
    if samples[-1].get("stage") != SETTLED:
        return f"the deploy did not settle on a >2/3 network: {samples[-1].get('stage')!r}"
    return None


def partition_stale_verdict(samples: list[dict], observation: tuple[int, dict | None]) -> str | None:
    """A partitioned node may say unknown; it may never say settled."""
    for sample in samples:
        if sample.get("stage") == SETTLED or sample.get("settlementConfirmed") is True:
            return "a partitioned node claimed settlement"
        verdict = settlement_verdict(
            sample.get("stage"), sample.get("settlementConfirmed"), sample.get("finalized")
        )
        if verdict:
            return verdict
    return finality_observation_verdict(*observation)


def recovery_verdict(
    settlement: dict, inclusion_height: int, finalized_height: int
) -> str | None:
    """After >2/3 returns, the same deploy finalizes without resubmission."""
    if finalized_height < inclusion_height:
        return f"finalized {finalized_height} is behind the inclusion block {inclusion_height}"
    stage = settlement.get("stage")
    if stage != SETTLED:
        return f"the deploy is {stage!r} after recovery, not settled"
    return settlement_verdict(
        stage, settlement.get("settlementConfirmed"), settlement.get("finalized")
    )


def no_silent_loss_verdict(accepted_ids: list[str], final_stages: dict[str, str]) -> str | None:
    """Every accepted deploy has a terminal settlement after recovery."""
    missing = [deploy_id for deploy_id in accepted_ids if deploy_id not in final_stages]
    if missing:
        return f"accepted deploys with no settlement reading: {missing}"
    stuck = {
        deploy_id: stage
        for deploy_id, stage in final_stages.items()
        if stage not in (SETTLED, "finalizedError")
    }
    if stuck:
        return f"accepted deploys left unsettled after recovery: {stuck}"
    return None
