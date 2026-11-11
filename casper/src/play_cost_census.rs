//! **Play-side cost census, keyed by the deploy** (#564).
//!
//! The replay compares a recorded per-deploy cost against its own and, when they differ, can say only
//! the two totals. This module keeps the play path's diagnostic breakdown long enough for the replay
//! to look it up and name the category that moved. It is process-local, bounded, and only used when
//! `RCHAIN_COST_CENSUS` is on; a node with the census off pays one relaxed load per deploy.
//!
//! **Why a side table rather than a field on `ProcessedDeploy`.** The processed deploy is consensus
//! data and its shape is the block's; a diagnostic map belongs beside the path, not inside the value
//! every peer hashes. The key is the block identity plus the deploy id, which is what both paths have.

use std::collections::VecDeque;
use std::sync::{Mutex, OnceLock};

use rchain_rholang::accounting::CostCensusSnapshot;
use rchain_rholang::system_processes::BlockData;
use rchain_shared::lock::Unpoison;

/// The number of recent play entries kept. A block carries at most `MAX_BLOCK_DEPLOYS` (255), so one
/// block's entries fit; the cap is a process-memory bound, not a correctness threshold.
const MAX_ENTRIES: usize = 512;

#[derive(Clone)]
struct Entry {
    block_number: i64,
    seq_num: i64,
    sender: Vec<u8>,
    deploy_id: Vec<u8>,
    snapshot: CostCensusSnapshot,
}

fn table() -> &'static Mutex<VecDeque<Entry>> {
    static TABLE: OnceLock<Mutex<VecDeque<Entry>>> = OnceLock::new();
    TABLE.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn key(block: &BlockData) -> (i64, i64, Vec<u8>) {
    (
        i64::from(block.block_number),
        i64::from(block.seq_num),
        block.sender.bytes().to_vec(),
    )
}

/// Record the play path's per-deploy breakdown. Called only when the census is on.
pub fn remember(block: &BlockData, deploy_id: &[u8], snapshot: CostCensusSnapshot) {
    let (block_number, seq_num, sender) = key(block);
    let mut table = table().lock().unpoison();
    if let Some(entry) = table.iter_mut().find(|e| {
        e.block_number == block_number
            && e.seq_num == seq_num
            && e.sender == sender
            && e.deploy_id == deploy_id
    }) {
        entry.snapshot = snapshot;
        return;
    }
    if table.len() == MAX_ENTRIES {
        table.pop_front();
    }
    table.push_back(Entry {
        block_number,
        seq_num,
        sender,
        deploy_id: deploy_id.to_vec(),
        snapshot,
    });
}

/// The play breakdown for this deploy, if the census recorded one.
pub fn lookup(block: &BlockData, deploy_id: &[u8]) -> Option<CostCensusSnapshot> {
    let (block_number, seq_num, sender) = key(block);
    let table = table().lock().unpoison();
    table
        .iter()
        .rev()
        .find(|e| {
            e.block_number == block_number
                && e.seq_num == seq_num
                && e.sender == sender
                && e.deploy_id == deploy_id
        })
        .map(|e| e.snapshot.clone())
}

/// Drop every entry. Tests use this; a process restart does the same.
pub fn clear() {
    table().lock().unpoison().clear();
}
