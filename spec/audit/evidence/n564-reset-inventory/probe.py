"""Extract the actual inventory function into a std-only dependency probe.

This executes the production function text against deliberately small storage stubs.
It does not run the Casper crate, replay, signatures, expiry, or a network reset.
"""
from pathlib import Path
import argparse
import hashlib
import json

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
source = args.source.read_text()
start = source.index("async fn return_unfinalised_deploys(")
opening = source.index("{", start)
depth = 1
end = opening + 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
function = source[start:end]

prefix = r'''
#![allow(dead_code)]
use std::collections::{BTreeMap, BTreeSet};
use std::future::{ready, Future, Ready};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Wake, Waker};
type BlockHeight = i64;
type DeployId = Vec<u8>;
const DEPLOY_LIFESPAN: i64 = 50;
// All probe deploys are unexpired. Real expiry is outside this probe's scope.
fn deploy_expired_at_block(_: i64, _: i64, _: i64) -> bool { false }
mod rchain_shared { pub mod base16 {
    pub fn encode(v: &[u8]) -> String { v.iter().map(|b| format!("{b:02x}")).collect() }
}}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct BlockHash(u8);
impl BlockHash { fn to_hex(self) -> String { format!("{:02x}", self.0) } }
#[derive(Clone)] struct BlockMetadata { block_num: BlockHeight }
#[derive(Clone)] struct DeployData { valid_after_block_number: i64 }
#[derive(Clone)] struct SignedDeployData { data: DeployData, sig: DeployId }
#[derive(Clone)] struct ProcessedDeploy { deploy: SignedDeployData }
#[derive(Clone, Default)] struct State { deploys: Vec<ProcessedDeploy> }
#[derive(Clone, Default)] struct BlockMessage { state: State }
struct DagRepresentation { dag_set: Arc<BTreeSet<BlockHash>> }
trait BlockDagStorage: Send + Sync {
    fn get_representation(&self) -> Ready<Arc<DagRepresentation>>;
    fn lookup(&self, h: &BlockHash) -> Ready<Result<Option<BlockMetadata>, String>>;
    fn contains_deploy_in_pool(&self, id: &DeployId) -> Ready<Result<bool, String>>;
    fn add_deploy(&self, d: SignedDeployData) -> Ready<Result<(), String>>;
}
struct Dag {
    metadata: BTreeMap<BlockHash, BlockMetadata>,
    pool: Mutex<BTreeSet<DeployId>>,
}
impl BlockDagStorage for Dag {
    fn get_representation(&self) -> Ready<Arc<DagRepresentation>> {
        ready(Arc::new(DagRepresentation { dag_set: Arc::new(self.metadata.keys().copied().collect()) }))
    }
    fn lookup(&self, h: &BlockHash) -> Ready<Result<Option<BlockMetadata>, String>> {
        ready(Ok(self.metadata.get(h).cloned()))
    }
    fn contains_deploy_in_pool(&self, id: &DeployId) -> Ready<Result<bool, String>> {
        ready(Ok(self.pool.lock().unwrap().contains(id)))
    }
    fn add_deploy(&self, d: SignedDeployData) -> Ready<Result<(), String>> {
        self.pool.lock().unwrap().insert(d.sig); ready(Ok(()))
    }
}
struct BlockStore { bodies: BTreeMap<BlockHash, BlockMessage> }
impl BlockStore {
    fn keys(&self) -> Ready<Result<Vec<BlockHash>, String>> {
        ready(Ok(self.bodies.keys().copied().collect()))
    }
    fn get(&self, keys: &[BlockHash]) -> Ready<Result<Vec<Option<BlockMessage>>, String>> {
        ready(Ok(keys.iter().map(|k| self.bodies.get(k).cloned()).collect()))
    }
}
struct NoWake;
impl Wake for NoWake { fn wake(self: Arc<Self>) {} }
fn run<F: Future>(f: F) -> F::Output {
    let waker = Waker::from(Arc::new(NoWake));
    let mut context = Context::from_waker(&waker);
    let mut f = std::pin::pin!(f);
    match f.as_mut().poll(&mut context) { Poll::Ready(v) => v, Poll::Pending => panic!("stub unexpectedly suspended") }
}
fn fixture(metadata: &[u8], bodies: &[u8]) -> (Arc<Dag>, BlockStore) {
    let dag = Arc::new(Dag {
        metadata: metadata.iter().map(|n| (BlockHash(*n), BlockMetadata { block_num: i64::from(*n) })).collect(),
        pool: Mutex::new(BTreeSet::new()),
    });
    let store = BlockStore { bodies: bodies.iter().map(|n| (BlockHash(*n), BlockMessage::default())).collect() };
    (dag, store)
}
'''

tests = r'''
#[test]
fn missing_dag_body_must_refuse_inventory() {
    let (dag, store) = fixture(&[0, 1], &[0]);
    let dag: Arc<dyn BlockDagStorage> = dag;
    let result = run(return_unfinalised_deploys(&dag, &store, 0));
    assert!(result.is_err(), "DAG block 01 has no body; successful inventory is unsafe, got {result:?}");
}
#[test]
fn complete_empty_inventory_is_allowed() {
    let (dag, store) = fixture(&[0, 1], &[0, 1]);
    let dag: Arc<dyn BlockDagStorage> = dag;
    assert_eq!(run(return_unfinalised_deploys(&dag, &store, 0)), Ok(0));
}
#[test]
fn body_without_dag_metadata_is_outside_rewind_inventory() {
    let (dag, store) = fixture(&[0], &[0, 2]);
    let dag: Arc<dyn BlockDagStorage> = dag;
    assert_eq!(run(return_unfinalised_deploys(&dag, &store, 0)), Ok(0));
}
#[test]
fn known_unfinalised_deploy_is_returned_and_not_duplicated() {
    let (dag, mut store) = fixture(&[0, 1], &[0, 1]);
    store.bodies.get_mut(&BlockHash(1)).unwrap().state.deploys.push(ProcessedDeploy {
        deploy: SignedDeployData { data: DeployData { valid_after_block_number: 0 }, sig: vec![7] },
    });
    let dynamic: Arc<dyn BlockDagStorage> = dag.clone();
    assert_eq!(run(return_unfinalised_deploys(&dynamic, &store, 0)), Ok(1));
    assert!(dag.pool.lock().unwrap().contains(&vec![7]));
    assert_eq!(run(return_unfinalised_deploys(&dynamic, &store, 0)), Ok(0));
}
'''
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(prefix + "\n" + function + "\n" + tests)
print(json.dumps({"output": str(args.output), "function_sha256": hashlib.sha256(function.encode()).hexdigest(), "scope": "source-extracted function with storage stubs; not a Casper or devnet run"}))
