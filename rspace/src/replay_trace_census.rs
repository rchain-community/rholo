//! **A diagnostic census of the replay trace** (#564).
//!
//! The replay refuses a cost mismatch before `check_replay_data` runs, so an unused COMM or a
//! filtered datum can surface as a cost difference and never as `UnusedCommEvent`. This counts the
//! trace's own shape — recorded, matched, filtered, leftover, and the RCHAIN-3505 swallow — so the
//! cost refusal can be read against what the trace did. It is process-wide, monotone and diagnostic:
//! no acceptance decision reads it.

use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TraceCensusSnapshot {
    pub recorded_comms: u64,
    pub matched_data: u64,
    pub filtered_data: u64,
    pub leftover_comms: u64,
    pub swallowed_for_failed_deploy: u64,
}

static RECORDED_COMMS: AtomicU64 = AtomicU64::new(0);
static MATCHED_DATA: AtomicU64 = AtomicU64::new(0);
static FILTERED_DATA: AtomicU64 = AtomicU64::new(0);
static LEFTOVER_COMMS: AtomicU64 = AtomicU64::new(0);
static SWALLOWED_FOR_FAILED_DEPLOY: AtomicU64 = AtomicU64::new(0);

pub fn note_rigged(comms: usize) {
    RECORDED_COMMS.fetch_add(comms as u64, Ordering::Relaxed);
}

pub fn note_match(matched: bool) {
    if matched {
        MATCHED_DATA.fetch_add(1, Ordering::Relaxed);
    } else {
        FILTERED_DATA.fetch_add(1, Ordering::Relaxed);
    }
}

pub fn note_leftover(comms: usize) {
    LEFTOVER_COMMS.fetch_add(comms as u64, Ordering::Relaxed);
}

pub fn note_swallowed_for_failed_deploy() {
    SWALLOWED_FOR_FAILED_DEPLOY.fetch_add(1, Ordering::Relaxed);
}

impl TraceCensusSnapshot {
    /// The difference between two cumulative samples, so a shadow replay names only its own work.
    pub fn delta(&self, later: &Self) -> Self {
        Self {
            recorded_comms: later.recorded_comms.saturating_sub(self.recorded_comms),
            matched_data: later.matched_data.saturating_sub(self.matched_data),
            filtered_data: later.filtered_data.saturating_sub(self.filtered_data),
            leftover_comms: later.leftover_comms.saturating_sub(self.leftover_comms),
            swallowed_for_failed_deploy: later
                .swallowed_for_failed_deploy
                .saturating_sub(self.swallowed_for_failed_deploy),
        }
    }
}

pub fn snapshot() -> TraceCensusSnapshot {
    TraceCensusSnapshot {
        recorded_comms: RECORDED_COMMS.load(Ordering::Relaxed),
        matched_data: MATCHED_DATA.load(Ordering::Relaxed),
        filtered_data: FILTERED_DATA.load(Ordering::Relaxed),
        leftover_comms: LEFTOVER_COMMS.load(Ordering::Relaxed),
        swallowed_for_failed_deploy: SWALLOWED_FOR_FAILED_DEPLOY.load(Ordering::Relaxed),
    }
}

/// Reset the counters. Tests use this; a process restart does the same.
pub fn reset() {
    RECORDED_COMMS.store(0, Ordering::Relaxed);
    MATCHED_DATA.store(0, Ordering::Relaxed);
    FILTERED_DATA.store(0, Ordering::Relaxed);
    LEFTOVER_COMMS.store(0, Ordering::Relaxed);
    SWALLOWED_FOR_FAILED_DEPLOY.store(0, Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_trace_census_counts_each_shape() {
        reset();
        note_rigged(3);
        note_match(true);
        note_match(false);
        note_match(false);
        note_leftover(2);
        note_swallowed_for_failed_deploy();
        let snap = snapshot();
        assert_eq!(snap.recorded_comms, 3);
        assert_eq!(snap.matched_data, 1);
        assert_eq!(snap.filtered_data, 2);
        assert_eq!(snap.leftover_comms, 2);
        assert_eq!(snap.swallowed_for_failed_deploy, 1);
        reset();
    }
}
