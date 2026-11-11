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
    let trace_lengths: Vec<usize> = user.iter().map(|r| r.deploy.deploy_log.len()).collect();
    assert_eq!(user.len(), terms.len());
    println!("{label}: trace_lengths={trace_lengths:?}");
    if label == "CONTROL M04 failed COMM" {
        assert!(failed[0]);
        assert!(trace_lengths[0] > 0, "the failed control must execute before failing");
    }
    if label == "M15 transient variant 2" {
        assert_eq!(failed, vec![false, true, false]);
        assert!(trace_lengths[1] > 0, "the failed transient fixture must execute before failing");
    }
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
            assert_eq!(replay_state, post_state, "canonical replay state mismatch: {label}");
        }
        Err(e) => panic!("canonical play/replay refusal in {label}: {e:?}"),
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
async fn omega_rcb_original_transfer_control() {
    run_shape("CONTROL M01 transfer+Nil", &[transfer(1, &target(7), true), deploy(2, "Nil")], None).await;
}

#[tokio::test]
async fn omega_rcb_original_failed_comm_control() {
    let term = r#"new c, return in { c!(42) | for (@x <- c) { return!(1 + "not-a-number") } }"#;
    run_shape("CONTROL M04 failed COMM", &[deploy(4, term)], None).await;
}

#[tokio::test]
async fn omega_rcb_original_transient_comm_m15() {
    for (index, term) in [
        "new c in { c!(42) | for (@x <- c) { Nil } }",
        "new c, d in { c!(42) | for (@x <- c) { d!(x) } | for (@y <- d) { Nil } }",
        r#"new c, d, return in { c!(42) | for (@x <- c) { d!(x) } | for (@y <- d) { return!(1 + "not-a-number") } }"#,
    ].iter().enumerate() {
        let label = format!("M15 transient variant {index}");
        let terms = [transfer(11, &target(21), true), deploy(12, term), transfer(13, &target(22), true)];
        run_shape(&label, &terms, None).await;
    }
}
