//! #564 M22–M24: authenticated recovered deploys, SYNTHETIC pre-state.
//! The original block body, its processed trace, and its pre-state are not
//! supplied by these tests. A matching cost is not historical closure.
mod common;
use common::fringe_state;
use std::collections::BTreeMap;

use rchain_casper::genesis::contracts::Vault;
use rchain_crypto::hash::blake2b512_random::Blake2b512Random;
use rchain_crypto::public_key::PublicKey;
use rchain_models::casper::protocol::casper_message::{
    Event, ProcessedDeploy, ProcessedSystemDeploy, SignedDeployData,
};
use rchain_rholang::native_state::PosGenesis;
use rchain_rholang::scheduler::EffectMode;
use rchain_rholang::system_processes::BlockData;
use rchain_rholang::util::rev_address::RevAddress;
use rchain_shared::refined::NonNegI64;

const FIXTURES: &[(&str, &[u8])] = &[
    (
        "registry-1e4f",
        include_bytes!("rcb_recovered/registry-1e4f.bin"),
    ),
    (
        "registry-7c03",
        include_bytes!("rcb_recovered/registry-7c03.bin"),
    ),
    (
        "registry-short-9915",
        include_bytes!("rcb_recovered/registry-short-9915.bin"),
    ),
    (
        "simple-2e37",
        include_bytes!("rcb_recovered/simple-2e37.bin"),
    ),
    ("probe-98dd", include_bytes!("rcb_recovered/probe-98dd.bin")),
    // Semantically authenticated reconstruction; not a contiguous pool carve.
    (
        "registry-dd2d-reconstructed",
        include_bytes!("rcb_recovered/registry-dd2d-reconstructed.bin"),
    ),
];

fn fixtures() -> Vec<(&'static str, SignedDeployData)> {
    FIXTURES
        .iter()
        .map(|(name, bytes)| {
            let d = SignedDeployData::from_bytes(bytes).expect("production protobuf decode");
            assert_eq!(d.to_bytes().as_slice(), *bytes, "canonical wire round trip");
            assert!(d.verify_signature(), "authentic recovered signature");
            (*name, d)
        })
        .collect()
}

#[test]
fn omega_m22_production_signature_verification() {
    for (name, d) in fixtures() {
        let mut term_control = d.clone();
        term_control.data.term.push(' ');
        let mut timestamp_control = d.clone();
        timestamp_control.data.timestamp += 1;
        let mut sig_control = d.clone();
        *sig_control.sig.last_mut().unwrap() ^= 1;
        assert!(!term_control.verify_signature());
        assert!(!timestamp_control.verify_signature());
        assert!(!sig_control.verify_signature());
        println!("OMEGA_M22 name={name} signature_valid=true term_tamper=false timestamp_tamper=false signature_tamper=false term_bytes={} timestamp={} phlo_limit={} valid_after={} shard={}",
            d.data.term.len(), d.data.timestamp, d.data.phlo_limit,
            d.data.valid_after_block_number, d.data.shard_id);
    }
}

#[derive(Debug, PartialEq, Eq)]
struct Observation {
    costs: Vec<u64>,
    failed: Vec<bool>,
    traces: Vec<String>,
    pre: String,
    post: String,
    verdict: String,
}

async fn run_case(
    label: &str,
    terms: &[SignedDeployData],
    mode: EffectMode,
    verbose: bool,
) -> Observation {
    let rm = common::build_runtime_manager_with_mode(mode).await;
    let rand = Blake2b512Random::from_init(&[0u8; 32]);
    let vault = Vault {
        rev_address: RevAddress::from_public_key(&PublicKey::new(terms[0].deployer.clone()))
            .expect("REV address"),
        initial_balance: NonNegI64::try_from(1_000_000_000).unwrap(),
    };
    let (_, pre, _) = rm
        .compute_genesis(
            &[],
            &rand,
            BlockData::empty(),
            &PosGenesis::default(),
            &[vault],
        )
        .await
        .expect("synthetic genesis");
    let (post, users, systems) = rm
        .compute_state(
            &pre,
            terms,
            &[],
            &rand,
            BlockData::empty(),
            &fringe_state(1),
        )
        .await
        .expect("play must execute");
    let processed: Vec<ProcessedDeploy> = users.into_iter().map(|x| x.deploy).collect();
    let systems: Vec<ProcessedSystemDeploy> = systems.into_iter().map(|x| x.deploy).collect();
    let costs = processed.iter().map(|x| x.cost.cost).collect();
    let failed = processed.iter().map(|x| x.is_failed).collect();
    let traces = processed
        .iter()
        .map(|x| format!("{:?}", x.deploy_log))
        .collect();
    for (i, d) in processed.iter().enumerate() {
        let mut produce = 0;
        let mut consume = 0;
        let mut comm = 0;
        for event in &d.deploy_log {
            match event {
                Event::Produce(_) => produce += 1,
                Event::Consume(_) => consume += 1,
                Event::Comm(_) => comm += 1,
            }
        }
        println!("OMEGA_M23_COST label={label} mode={mode:?} deploy={i} cost={} failed={} produce={produce} consume={consume} comm={comm}", d.cost.cost, d.is_failed);
        if verbose {
            for (at, event) in d.deploy_log.iter().enumerate() {
                println!("OMEGA_M23_TRACE label={label} deploy={i} at={at} event={event:?}");
            }
        }
    }
    let replay = rm
        .replay_compute_state(
            &pre,
            &processed,
            &systems,
            &rand,
            BlockData::empty(),
            &fringe_state(1),
            &BTreeMap::new(),
            true,
            &PosGenesis::default(),
            &[],
        )
        .await;
    let verdict = match replay {
        Ok((state, _)) => {
            assert_eq!(state, post, "successful strict replay must match state");
            "ACCEPT state_match=true".to_string()
        }
        Err(e) => format!("REJECT {e:?}"),
    };
    println!("OMEGA_M23_RESULT label={label} mode={mode:?} scope=synthetic-prestate pre={pre:?} post={post:?} costs={costs:?} failed={failed:?} verdict={verdict}");
    Observation {
        costs,
        failed,
        traces,
        pre: format!("{pre:?}"),
        post: format!("{post:?}"),
        verdict,
    }
}

#[tokio::test]
async fn omega_m23_recovered_terms_on_synthetic_prestate() {
    for (name, d) in fixtures() {
        let first = run_case(name, &[d.clone()], EffectMode::Sequential, true).await;
        for repeat in 2..=3 {
            let next = run_case(name, &[d.clone()], EffectMode::Sequential, false).await;
            assert_eq!(first, next, "deterministic repeat {repeat} for {name}");
        }
    }
}

#[tokio::test]
async fn omega_m24_registry_and_pending_probe_controls() {
    let fs = fixtures();
    let registry = &fs[0].1;
    let probe = &fs[4].1;
    // Vary only order of two authenticated recovered deploys. Neither order is
    // asserted to be the historical pre-state or original block deploy order.
    for (label, terms) in [
        ("registry-then-probe", vec![registry.clone(), probe.clone()]),
        (
            "pending-probe-then-registry",
            vec![probe.clone(), registry.clone()],
        ),
        ("two-registries", vec![registry.clone(), fs[1].1.clone()]),
    ] {
        for mode in [
            EffectMode::Sequential,
            EffectMode::Gate,
            EffectMode::RelaxedValidated,
            EffectMode::ForkJoin,
        ] {
            run_case(label, &terms, mode, false).await;
        }
    }
}

// M25 uses recovered content-addressed historical state, without opening LMDB.
// The rejected block's timestamp and serialized ProcessedDeploy were not found.
// BlockRandomSeed excludes timestamp/sequence; all supplied substitutes are logged.
fn unhex(s: &str) -> Vec<u8> {
    assert_eq!(s.len() % 2, 0);
    s.as_bytes()
        .chunks_exact(2)
        .map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap())
        .collect()
}

fn hex_bytes(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn read_u32(raw: &[u8], at: &mut usize) -> usize {
    let n = u32::from_le_bytes(raw[*at..*at + 4].try_into().unwrap()) as usize;
    *at += 4;
    n
}

async fn historical_runtime(root: &str) -> rchain_casper::runtime_manager::RuntimeManager {
    use rchain_crypto::hash::blake2b256_hash::Blake2b256Hash;
    use rchain_models::runtime::{BindPattern, ListParWithRandom, TaggedContinuation};
    use rchain_models::sorted::SortedProc;
    use rchain_rholang::merging::{DeployMergeableDataCodec, NativeSidecarCodec};
    use rchain_rholang::runtime::{ReplayRhoRuntime, RhoRuntime};
    use rchain_rholang::storage::RhoMatch;
    use rchain_rspace::factory::create_history_repository;
    use rchain_rspace::hot_store::InMemHotStore;
    use rchain_rspace::rspace::RSpace;
    use rchain_shared::store_manager::{database, InMemoryStoreManager, KeyValueStoreManager};
    use rchain_shared::typed_store::BytesCodec;
    use std::sync::Arc;

    let raw = include_bytes!("rcb_recovered/historical-state.bin");
    assert_eq!(&raw[..4], b"RCB1");
    let manager = InMemoryStoreManager::default();
    let mut at = 4;
    let roots = read_u32(raw, &mut at);
    let mut root_pairs = Vec::new();
    for _ in 0..roots {
        root_pairs.push((raw[at..at + 32].to_vec(), b"root".to_vec()));
        at += 32;
    }
    let requested = unhex(root);
    assert!(root_pairs.iter().any(|(k, _)| k == &requested));
    root_pairs.push((b"current-root".to_vec(), requested.clone()));
    manager
        .store("rspace-roots")
        .await
        .unwrap()
        .lock()
        .await
        .put(root_pairs)
        .unwrap();
    for name in ["rspace-history", "rspace-cold"] {
        let count = read_u32(raw, &mut at);
        let mut pairs = Vec::new();
        for _ in 0..count {
            let key = raw[at..at + 32].to_vec();
            at += 32;
            let len = read_u32(raw, &mut at);
            let value = raw[at..at + len].to_vec();
            at += len;
            assert_eq!(
                Blake2b256Hash::create(&value).as_bytes().as_slice(),
                key.as_slice(),
                "content-addressed fixture integrity"
            );
            pairs.push((key, value));
        }
        manager
            .store(name)
            .await
            .unwrap()
            .lock()
            .await
            .put(pairs)
            .unwrap();
        println!("OMEGA_M25_LOAD store={name} records={count} all_hashes_valid=true");
    }
    assert_eq!(at, raw.len(), "no unparsed fixture tail");
    let history = create_history_repository::<
        SortedProc,
        BindPattern,
        ListParWithRandom,
        TaggedContinuation,
    >(&manager, "rspace")
    .await
    .unwrap();
    assert_eq!(history.root().as_bytes().as_slice(), requested.as_slice());
    let reader = history.get_history_reader(history.root()).await;
    let hot = Arc::new(InMemHotStore::new(reader.base()));
    let (play, replay) = RSpace::create_with_replay(history.clone(), hot, Arc::new(RhoMatch));
    let rho = RhoRuntime::create_with_effect_mode(
        play,
        history.clone(),
        SortedProc::default(),
        true,
        EffectMode::Sequential,
    )
    .await
    .unwrap();
    let replay = ReplayRhoRuntime::create(Arc::new(replay), history.clone(), SortedProc::default())
        .await
        .unwrap();
    let mergeable: rchain_casper::runtime_manager::MergeableStore = Arc::new(
        database(
            &manager,
            "mergeable",
            Arc::new(BytesCodec),
            Arc::new(DeployMergeableDataCodec),
        )
        .await
        .unwrap(),
    );
    let native_changes: rchain_casper::runtime_manager::NativeChangesStore = Arc::new(
        database(
            &manager,
            "native-changes",
            Arc::new(BytesCodec),
            Arc::new(NativeSidecarCodec),
        )
        .await
        .unwrap(),
    );
    rchain_casper::runtime_manager::RuntimeManager::new(
        rho,
        replay,
        history,
        mergeable,
        native_changes,
        EffectMode::Sequential,
    )
}

async fn historical_matrix() {
    use rchain_block_storage::dag::codecs::{BlockMessageCodec, BlockMetadataCodec};
    use rchain_casper::block_random_seed::BlockRandomSeed;
    use rchain_casper::system_deploy::SystemDeploy;
    use rchain_crypto::hash::blake2b256_hash::Blake2b256Hash;
    use rchain_shared::refined::{BlockHeight, SeqNum};
    use rchain_shared::typed_store::Codec;

    let parent = BlockMessageCodec
        .decode(include_bytes!("rcb_recovered/accepted-A-1071.bin"))
        .unwrap();
    assert_eq!(
        hex_bytes(parent.block_hash.as_bytes()),
        "bd6d3e5e312d16f3c60b467c9ff47f2f49cc86e1146b9545f644f9313a5ae389"
    );
    assert_eq!(i64::from(parent.block_number), 1071);
    println!(
        "OMEGA_M25_PARENT sender={} sequence={} timestamp={}",
        hex_bytes(parent.sender.as_bytes()),
        i64::from(parent.seq_num),
        parent.timestamp
    );
    let mut participation = BTreeMap::new();
    for raw in [
        include_bytes!("rcb_recovered/fringe-1073-0.bin").as_slice(),
        include_bytes!("rcb_recovered/fringe-1073-1.bin").as_slice(),
        include_bytes!("rcb_recovered/fringe-1073-2.bin").as_slice(),
        include_bytes!("rcb_recovered/fringe-1073-3.bin").as_slice(),
    ] {
        let m = BlockMetadataCodec.decode(raw).unwrap();
        participation
            .entry(m.sender)
            .and_modify(|h: &mut BlockHeight| *h = (*h).max(m.block_num))
            .or_insert(m.block_num);
    }
    println!("OMEGA_M25_FRINGE_PARTICIPATION {participation:?}");
    let fs = fixtures();
    let cases = [
        (
            "1073",
            1073,
            "bcc2ae1c219466ca33bee5c05bef2033af8ecfe2c97eeb0576cbccfa6b72ff07",
            "53d8c26858bfdaf609e1f5bab8b601db2ac372b03693705b3e0fdec6fca0ed10",
            "daef89b3479de6730588948a8f035d3cc9a8067614cbbd58f18698347871100a",
            vec![fs[5].1.clone()],
        ),
        // The 1115 user-deploy order is the signature order printed in the refusal log.
        // Participation here is a surrogate (the 1073 fringe), explicitly reported.
        (
            "1115",
            1115,
            "83622575f2cc14cefe3cac00c9b833f53514f92219d95df4ee177aef4dfcb1fa",
            "83622575f2cc14cefe3cac00c9b833f53514f92219d95df4ee177aef4dfcb1fa",
            "14cbed18ffb12ac22ab5253fe9dd8f0bc72ccf3cefb2bd4282fa16a86b4447f2",
            vec![fs[0].1.clone(), fs[5].1.clone()],
        ),
    ];
    for (label, height, pre, fringe, expected_post, terms) in cases {
        let mut prior = None;
        for repeat in 1..=3 {
            let rm = historical_runtime(pre).await;
            let observing =
                std::env::var_os("OMEGA_RCB_OBSERVER").is_some() && label == "1073" && repeat == 1;
            if observing {
                std::env::set_var("OMEGA_RCB_COST_TRACE", "1");
            } else {
                std::env::remove_var("OMEGA_RCB_COST_TRACE");
            }
            let pre = Blake2b256Hash::from_byte_array(&unhex(pre));
            let fringe = Blake2b256Hash::from_byte_array(&unhex(fringe));
            let sender = PublicKey::new(parent.sender.as_bytes().to_vec());
            let rand =
                BlockRandomSeed::random_generator_from("/testnet", height, sender.clone(), pre)
                    .unwrap();
            let metadata_control = std::env::var_os("OMEGA_RCB_EXPECT_CORRECTED").is_some();
            let timestamp = if metadata_control {
                [0, 1794159386253, 1794159386483][repeat - 1]
            } else {
                0
            };
            let data = BlockData {
                block_number: BlockHeight::try_from(height).unwrap(),
                sender,
                seq_num: SeqNum::try_from(i64::from(parent.seq_num) + 1).unwrap(),
                timestamp,
            };
            let systems = vec![SystemDeploy::close_block(
                height,
                fringe,
                participation.clone(),
                rand.split_byte(terms.len() as u8),
            )];
            println!("OMEGA_M26_PHASE play case={label} repeat={repeat} observing={observing}");
            let (post, users, systems) = rm
                .compute_state(&pre, &terms, &systems, &rand, data.clone(), &fringe)
                .await
                .expect("historical-state play");
            let users: Vec<ProcessedDeploy> = users.into_iter().map(|x| x.deploy).collect();
            let systems: Vec<ProcessedSystemDeploy> =
                systems.into_iter().map(|x| x.deploy).collect();
            let costs: Vec<u64> = users.iter().map(|x| x.cost.cost).collect();
            let traces: Vec<String> = users
                .iter()
                .map(|x| format!("{:?}", x.deploy_log))
                .collect();
            if repeat == 1 {
                for (i, d) in users.iter().enumerate() {
                    for (n, event) in d.deploy_log.iter().enumerate() {
                        println!(
                            "OMEGA_M25_TRACE height={height} deploy={i} at={n} event={event:?}"
                        );
                    }
                }
            }
            println!("OMEGA_M26_PHASE replay case={label} repeat={repeat} observing={observing}");
            let verdict = match rm
                .replay_compute_state(
                    &pre,
                    &users,
                    &systems,
                    &rand,
                    data,
                    &fringe,
                    &BTreeMap::new(),
                    true,
                    &PosGenesis::default(),
                    &[],
                )
                .await
            {
                Ok((state, _)) => format!("ACCEPT state_match={}", state == post),
                Err(e) => format!("REJECT {e:?}"),
            };
            let post_hex = hex_bytes(post.as_bytes());
            assert_eq!(
                post_hex, expected_post,
                "exact original declared post-state"
            );
            assert_eq!(costs[0], 5576, "exact original play cost");
            if metadata_control {
                assert_eq!(
                    verdict, "ACCEPT state_match=true",
                    "corrected replay must preserve cost and state"
                );
            } else {
                assert_eq!(
                    verdict, "REJECT ReplayCostMismatch { initial_cost: 5576, replay_cost: 5302 }",
                    "exact original replay mismatch"
                );
            }
            println!("OMEGA_M25_RESULT case={label} repeat={repeat} scope=actual-historical-prestate timestamp_substitute={timestamp} sequence_substitute={} participation_source=1073-fringe costs={costs:?} post={post_hex} declared_post_match={} verdict={verdict}",i64::from(parent.seq_num)+1,post_hex==expected_post);
            let observation = (costs, traces, post_hex, verdict);
            if let Some(p) = &prior {
                assert_eq!(p, &observation, "deterministic historical-state repeat");
            }
            prior = Some(observation);
        }
    }
    std::env::remove_var("OMEGA_RCB_COST_TRACE");
}

#[tokio::test]
async fn omega_m25_actual_historical_prestate() {
    historical_matrix().await;
}

#[tokio::test]
async fn omega_m26_observer_preserves_historical_results() {
    std::env::set_var("OMEGA_RCB_OBSERVER", "1");
    historical_matrix().await;
    std::env::remove_var("OMEGA_RCB_OBSERVER");
}

#[tokio::test]
async fn omega_m27_chronological_replay_correction() {
    std::env::set_var("OMEGA_RCB_EXPECT_CORRECTED", "1");
    historical_matrix().await;
    std::env::remove_var("OMEGA_RCB_EXPECT_CORRECTED");
}
