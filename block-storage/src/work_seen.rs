//! Work first-seen store.
//!
//! **A local, non-consensus record of when this node first saw each piece of unfinalised work**
//! (#583). The proposer ages the prompt-attestation licence from the height at which it first
//! observed a work-bearing block, so an advancing fringe cannot renew the same unresolved work.
//! Nothing here enters block validity or consensus: two nodes disagreeing about whether to attest
//! promptly is the safe direction.

use std::sync::Arc;

use rchain_models::block_hash::BlockHash;
use rchain_shared::store_manager::KeyValueStoreManager;
use rchain_shared::typed_store::{I64Codec, KeyValueTypedStore, KeyValueTypedStoreCodec};

use crate::dag::codecs::BlockHashCodec;

/// Work block hash → the tip height at which this node first observed it as unfinalised work.
///
/// The store is per shard, because the node builds one store manager per shard. A row is written
/// once, on first observation, and is never rewritten while the work is unfinalised: that is what
/// makes the age monotone across fringe advances, re-observation and restart.
pub type WorkSeenStore = Arc<dyn KeyValueTypedStore<BlockHash, i64>>;

/// Open the work-seen store from a store manager.
pub async fn create(kvm: &dyn KeyValueStoreManager) -> Result<WorkSeenStore, String> {
    let store = kvm.store("work-seen-store").await?;
    Ok(Arc::new(KeyValueTypedStoreCodec::new(
        store,
        Arc::new(BlockHashCodec),
        Arc::new(I64Codec),
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rchain_shared::store_manager::InMemoryStoreManager;

    fn hash(byte: u8) -> BlockHash {
        BlockHash::from_slice(&[byte; 32])
    }

    /// The store is opened by *name*, so a reopened handle over the same manager sees what was
    /// written. That is the property a restart relies on: without it, every boot would reset the
    /// first-seen height and renew the licence the fix exists to bound.
    #[tokio::test]
    async fn opening_the_store_again_finds_what_was_written() {
        let kvm = InMemoryStoreManager::default();
        let first = create(&kvm).await.expect("open");
        assert_eq!(
            first.get(&[hash(1)]).await.expect("get")[0],
            None,
            "an empty store has no first-seen row"
        );

        first.put(&[(hash(1), 33)]).await.expect("put");

        let reopened = create(&kvm).await.expect("reopen");
        assert_eq!(
            reopened.get(&[hash(1)]).await.expect("get")[0],
            Some(33),
            "the first-seen height survives a reopen"
        );

        // A different manager starts empty: the row lives in the named store, not in a static.
        let other = create(&InMemoryStoreManager::default())
            .await
            .expect("open");
        assert_eq!(other.get(&[hash(1)]).await.expect("get")[0], None);
    }

    /// `get` is a **batch** call: absent keys come back as `None` in their own slot, so a caller can
    /// zip the work list against the answers.
    #[tokio::test]
    async fn absent_keys_stay_in_their_slot() {
        let store = create(&InMemoryStoreManager::default())
            .await
            .expect("open");
        store.put(&[(hash(1), 33)]).await.expect("put");
        assert_eq!(
            store.get(&[hash(2), hash(1)]).await.expect("get"),
            vec![None, Some(33)]
        );
    }

    /// A manager that cannot open the store surfaces the error instead of handing back a store that
    /// would fail on first use — the node's startup path depends on reporting "the database would
    /// not open".
    #[tokio::test]
    async fn a_manager_that_cannot_open_the_store_surfaces_the_error() {
        struct Broken;
        #[async_trait::async_trait]
        impl rchain_shared::store_manager::KeyValueStoreManager for Broken {
            async fn store(
                &self,
                _name: &str,
            ) -> Result<rchain_shared::typed_store::SharedStore, String> {
                Err("the database would not open".to_string())
            }
            async fn shutdown(&self) {}
        }

        let err = create(&Broken)
            .await
            .map(|_| ())
            .expect_err("broken manager");
        assert_eq!(err, "the database would not open");
    }
}
