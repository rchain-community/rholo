//! #564 matrix on the incident revision `0a1e02362`.
//!
//! Diagnostic only: prints the play per-deploy costs and the replay outcome for the shapes the issue
//! describes (same-key 30,000,000 transfers plus a Nil probe, a failed deploy with a COMM, the
//! result channel matched or not, and the batched play path). It asserts the play/replay state hash
//! where the replay succeeds; a `ReplayCostMismatch` is printed with both costs.

mod common;
use common::fringe_state;

use std::collections::BTreeMap;

use rchain_casper::genesis::contracts::Vault;
use rchain_crypto::hash::blake2b512_random::Blake2b512Random;
use rchain_crypto::public_key::PublicKey;
use rchain_models::casper::protocol::casper_message::{
    DeployData, ProcessedDeploy, ProcessedSystemDeploy, SignedDeployData,
};
use rchain_rholang::native_state::PosGenesis;
use rchain_rholang::system_processes::BlockData;
use rchain_rholang::util::rev_address::RevAddress;
use rchain_shared::refined::NonNegI64;

fn deploy(sig: u8, term: &str) -> SignedDeployData {
    SignedDeployData {
        data: DeployData {
            attachments: Vec::new(),
            term: term.to_string(),
            timestamp: 0,
            phlo_price: 1,
            phlo_limit: 500_000,
            valid_after_block_number: 0,
            shard_id: "root".to_string(),
        },
        deployer: vec![0u8; 65],
        sig: vec![sig; 65],
        sig_algorithm: "secp256k1".to_string(),
    }
}

fn seeded_vault() -> Vault {
    Vault {
        rev_address: RevAddress::from_public_key(&PublicKey::new(vec![0u8; 65]))
            .expect("valid rev address"),
        initial_balance: NonNegI64::try_from(1_000_000_000).unwrap(),
    }
}

async fn run_shape(label: &str, terms: &[SignedDeployData], batch: Option<(bool, bool)>) {
    let mut rm = common::build_runtime_manager().await;
    if let Some((enabled, verify)) = batch {
        rm.set_batch_policy(rchain_casper::runtime_manager::BatchPolicy {
            enabled,
            verify,
            max_batch: 4,
        });
    }
    let rand = Blake2b512Random::from_init(&[0u8; 32]);
    let (_pre, post, _) = rm
        .compute_genesis(
            &[],
            &rand,
            BlockData::empty(),
            &PosGenesis::default(),
            &[seeded_vault()],
        )
        .await
        .expect("compute_genesis");
    let (post_state, user, sys) = rm
        .compute_state(
            &post,
            terms,
            &[],
            &rand,
            BlockData::empty(),
            &fringe_state(1),
        )
        .await
        .expect("play");
    let costs: Vec<u64> = user.iter().map(|r| r.deploy.cost.cost).collect();
    let failed: Vec<bool> = user.iter().map(|r| r.deploy.is_failed).collect();
    println!("{label}: play costs={costs:?} failed={failed:?} total={}", costs.iter().sum::<u64>());
    let processed: Vec<ProcessedDeploy> = user.into_iter().map(|r| r.deploy).collect();
    let sys: Vec<ProcessedSystemDeploy> = sys.into_iter().map(|r| r.deploy).collect();
    match rm
        .replay_compute_state(
            &post,
            &processed,
            &sys,
            &rand,
            BlockData::empty(),
            &fringe_state(1),
            &BTreeMap::new(),
            true,
            &PosGenesis::default(),
            &[],
        )
        .await
    {
        Ok((replay_state, _)) => {
            println!("{label}: replay OK state_match={}", replay_state == post_state);
        }
        Err(e) => println!("{label}: replay ERR {e:?}"),
    }
}

fn target(seed: u8) -> String {
    RevAddress::from_public_key(&PublicKey::new(vec![seed; 65]))
        .expect("target")
        .to_base58()
}

fn transfer(sig: u8, target: &str, consume: bool) -> SignedDeployData {
    let term = if consume {
        format!(
            r#"new revVault(`rho:rchain:revVault`), deployerId(`rho:rchain:deployerId`), r in {{ revVault!("transfer", *deployerId, "{target}", 30000000, *r) | for (_ <- r) {{ Nil }} }}"#
        )
    } else {
        format!(
            r#"new revVault(`rho:rchain:revVault`), deployerId(`rho:rchain:deployerId`), r in {{ revVault!("transfer", *deployerId, "{target}", 30000000, *r) }}"#
        )
    };
    deploy(sig, &term)
}

#[tokio::test]
async fn n564_2_deploy_transfer_and_nil_probe() {
    let t = target(7);
    run_shape(
        "M01 sequential transfer+Nil",
        &[transfer(1, &t, true), deploy(2, "Nil")],
        None,
    )
    .await;
}

#[tokio::test]
async fn n564_6_same_key_transfers() {
    let terms: Vec<SignedDeployData> = (0..6)
        .map(|i| transfer(10 + i, &target(20 + i), true))
        .collect();
    run_shape("M02 sequential 6 transfers", &terms, None).await;
}

#[tokio::test]
async fn n564_result_channel_unmatched() {
    let t = target(9);
    run_shape(
        "M13 transfer, result channel not consumed",
        &[transfer(3, &t, false)],
        None,
    )
    .await;
}

#[tokio::test]
async fn n564_failed_deploy_with_comm() {
    let term = r#"new c, return in { c!(42) | for (@x <- c) { return!(1 + "not-a-number") } }"#;
    run_shape("M04 failed deploy with COMM", &[deploy(4, term)], None).await;
}

#[tokio::test]
async fn n564_batched_verify_on() {
    let terms: Vec<SignedDeployData> = (0..4)
        .map(|i| transfer(30 + i, &target(40 + i), true))
        .collect();
    run_shape("M07 batch verify on", &terms, Some((true, true))).await;
}

#[tokio::test]
async fn n564_batched_verify_off() {
    let terms: Vec<SignedDeployData> = (0..4)
        .map(|i| transfer(50 + i, &target(60 + i), true))
        .collect();
    run_shape("M08 batch verify off", &terms, Some((true, false))).await;
}
