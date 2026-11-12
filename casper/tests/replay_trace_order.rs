//! #564 RC-B: pending requests and repeated peeks must replay at the play cost.
//! Synthetic regression distilled from the recovered BYOID registry shape.
mod common;

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
use std::collections::BTreeMap;

fn deploy(id: u8, term: String) -> SignedDeployData {
    // Runtime-level fixture, not an admission/signature-verification test.
    SignedDeployData {
        data: DeployData {
            attachments: Vec::new(),
            term,
            timestamp: 0,
            phlo_price: 1,
            phlo_limit: 500_000,
            valid_after_block_number: 0,
            shard_id: "root".to_string(),
        },
        deployer: vec![0; 65],
        sig: vec![id; 65],
        sig_algorithm: "secp256k1".to_string(),
    }
}

const REGISTRY: &str = r#"new state in {
  state!({}) |
  contract @"replay-order:registry"(@action, @address, @payload, @resultName) = {
    match action {
      "publish" => {
        for (@store <- state) {
          state!(store.set(address, payload)) | @resultName!("OK")
        }
      }
      "get" => {
        for (@store <<- state) {
          match store.get(address) {
            Nil => { @resultName!("MISS") }
            value => { @resultName!(value) }
          }
        }
      }
    }
  }
}"#;

#[tokio::test]
async fn pending_peeks_replay_with_exact_cost_and_state() {
    // Zero and one pending request are controls. Four expose a persistent
    // consume choosing a later COMM before an earlier peek repetition exists.
    for (count, expected_cost) in [(0u8, 1860), (1, 2606), (4, 4844)] {
        let rm = common::build_runtime_manager().await;
        let rand = Blake2b512Random::from_init(&[7; 32]);
        let vault = Vault {
            rev_address: RevAddress::from_public_key(&PublicKey::new(vec![0; 65])).unwrap(),
            initial_balance: NonNegI64::try_from(1_000_000_000).unwrap(),
        };
        let (_, genesis, _) = rm
            .compute_genesis(
                &[],
                &rand,
                BlockData::empty(),
                &PosGenesis::default(),
                &[vault],
            )
            .await
            .unwrap();
        let probes: Vec<_> = (0..count)
            .map(|i| {
                deploy(
                    i + 1,
                    format!(r#"@"replay-order:registry"!("get", "missing", "x", "reply-{i:011}")"#),
                )
            })
            .collect();
        let (pre, setup, setup_systems) = rm
            .compute_state(
                &genesis,
                &probes,
                &[],
                &rand,
                BlockData::empty(),
                &common::fringe_state(1),
            )
            .await
            .unwrap();
        let setup: Vec<ProcessedDeploy> = setup.into_iter().map(|x| x.deploy).collect();
        let setup_systems: Vec<ProcessedSystemDeploy> =
            setup_systems.into_iter().map(|x| x.deploy).collect();
        let setup_replay = rm
            .replay_compute_state(
                &genesis,
                &setup,
                &setup_systems,
                &rand,
                BlockData::empty(),
                &common::fringe_state(1),
                &BTreeMap::new(),
                true,
                &PosGenesis::default(),
                &[],
            )
            .await
            .expect("unmatched probe setup replays");
        assert_eq!(setup_replay.0, pre);

        let registry = deploy(100, REGISTRY.to_string());
        let rand = Blake2b512Random::from_init(&[9; 32]);
        let (post, users, systems) = rm
            .compute_state(
                &pre,
                &[registry],
                &[],
                &rand,
                BlockData::empty(),
                &common::fringe_state(2),
            )
            .await
            .unwrap();
        let users: Vec<ProcessedDeploy> = users.into_iter().map(|x| x.deploy).collect();
        let systems: Vec<ProcessedSystemDeploy> = systems.into_iter().map(|x| x.deploy).collect();
        assert_eq!(users.len(), 1);
        assert!(!users[0].is_failed);
        assert_eq!(
            users[0].cost.cost, expected_cost,
            "play accounting must remain fixed for {count} pending requests"
        );
        println!(
            "REPLAY_ORDER pending={count} play_cost={} trace_events={}",
            users[0].cost.cost,
            users[0].deploy_log.len()
        );
        let replay = rm
            .replay_compute_state(
                &pre,
                &users,
                &systems,
                &rand,
                BlockData::empty(),
                &common::fringe_state(2),
                &BTreeMap::new(),
                true,
                &PosGenesis::default(),
                &[],
            )
            .await
            .unwrap_or_else(|e| panic!("REPLAY_ORDER_FAILURE pending={count}: {e:?}"));
        assert_eq!(
            replay.0, post,
            "the complete strict replay must preserve state for {count} pending requests"
        );
    }
}
