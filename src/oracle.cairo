mod snapshot;

#[cfg(test)]
mod snapshot_test;
use ekubo::types::bounds::{Bounds};
use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey};

use starknet::{ContractAddress};

#[starknet::interface]
pub trait IOracle<TStorage> {
    // Returns the cumulative tick value for a given pool, useful for computing a geomean oracle
    // over a period of time.
    fn get_tick_cumulative(
        self: @TStorage, token0: ContractAddress, token1: ContractAddress
    ) -> i129;
}

// Measures the oracle
#[starknet::contract]
pub mod Oracle {
    use core::num::traits::{Zero};
    use core::option::{OptionTrait};
    use core::traits::{Into, TryInto};
    use ekubo::components::owned::{Owned as owned_component};
    use ekubo::components::shared_locker::{check_caller_is_core};
    use ekubo::components::upgradeable::{
        Upgradeable as upgradeable_component, IHasInterface, IUpgradeable, IUpgradeableDispatcher,
        IUpgradeableDispatcherTrait
    };
    use ekubo::interfaces::core::{
        ICoreDispatcher, ICoreDispatcherTrait, IExtension, SwapParameters, UpdatePositionParameters
    };
    use ekubo::types::bounds::{Bounds};
    use ekubo::types::call_points::{CallPoints};
    use ekubo::types::delta::{Delta};
    use ekubo::types::i129::{i129};
    use starknet::storage::StoragePathEntry;
    use starknet::storage::{
        Map, StoragePointerWriteAccess, StorageMapReadAccess, StoragePointerReadAccess,
        StorageMapWriteAccess
    };
    use starknet::{get_block_timestamp, get_caller_address, get_contract_address};
    use super::{IOracle, ContractAddress, PoolKey, snapshot::{Snapshot}};

    component!(path: owned_component, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = owned_component::OwnedImpl<ContractState>;
    impl OwnableImpl = owned_component::OwnableImpl<ContractState>;

    component!(path: upgradeable_component, storage: upgradeable, event: UpgradeableEvent);
    #[abi(embed_v0)]
    impl Upgradeable = upgradeable_component::UpgradeableImpl<ContractState>;

    #[starknet::storage_node]
    struct PoolState {
        count: u64,
        snapshots: Map<u64, Snapshot>,
    }

    #[storage]
    struct Storage {
        pub core: ICoreDispatcher,
        pub pool_state: Map<(ContractAddress, ContractAddress), PoolState>,
        #[substorage(v0)]
        upgradeable: upgradeable_component::Storage,
        #[substorage(v0)]
        owned: owned_component::Storage,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        UpgradeableEvent: upgradeable_component::Event,
        OwnedEvent: owned_component::Event,
    }

    #[abi(embed_v0)]
    impl LimitOrdersHasInterface of IHasInterface<ContractState> {
        fn get_primary_interface_id(self: @ContractState) -> felt252 {
            return selector!("ekubo_oracle_extension::oracle::Oracle");
        }
    }

    #[generate_trait]
    impl PoolKeyToPairImpl of PoolKeyToPairTrait {
        fn to_pair_key(self: PoolKey) -> (ContractAddress, ContractAddress) {
            assert(self.fee.is_zero(), 'Fee must be 0');
            assert(self.tick_spacing == MAX_TICK_SPACING, 'Tick spacing must be max');
            (self.token0, self.token1)
        }

        fn to_pool_key(self: (ContractAddress, ContractAddress)) -> PoolKey {
            let (token0, token1) = self;

            PoolKey {
                token0,
                token1,
                fee: 0,
                tick_spacing: MAX_TICK_SPACING,
                extension: get_contract_address()
            }
        }
    }

    #[constructor]
    fn constructor(ref self: ContractState, core: ICoreDispatcher) {
        self.core.write(core);
        core
            .set_call_points(
                CallPoints {
                    // to record the starting timestamp
                    before_initialize_pool: true,
                    after_initialize_pool: false,
                    // in order to record the price at the end of the last block
                    before_swap: true,
                    after_swap: false,
                    // the same as above
                    before_update_position: true,
                    after_update_position: false,
                    before_collect_fees: false,
                    after_collect_fees: false,
                }
            );
    }

    #[generate_trait]
    impl Internal of InternalTrait {
        fn check_caller_is_core(self: @ContractState) -> ICoreDispatcher {
            let core = self.core.read();
            check_caller_is_core(core);
            core
        }

        fn update_pool(ref self: ContractState, core: ICoreDispatcher, pool_key: PoolKey) {
            let key = pool_key.to_pair_key();
            let state = self.pool_state.entry(key);

            let count = state.count.read();
            let last_snapshot = state.snapshots.read(count - 1);

            let time = get_block_timestamp();
            let time_passed: u128 = (time - last_snapshot.block_timestamp).into();

            if (time_passed.is_zero()) {
                return;
            }

            let tick = core.get_pool_price(pool_key).tick;

            state.count.write(count + 1);
            state
                .snapshots
                .write(
                    count,
                    Snapshot {
                        block_timestamp: time,
                        tick_cumulative: last_snapshot.tick_cumulative
                            + (tick * i129 { mag: time_passed, sign: false }),
                    }
                );
        }
    }

    #[abi(embed_v0)]
    impl OracleImpl of IOracle<ContractState> {
        fn get_tick_cumulative(
            self: @ContractState, token0: ContractAddress, token1: ContractAddress
        ) -> i129 {
            let key = (token0, token1);
            let entry = self.pool_state.entry(key);
            let count = entry.count.read();
            assert(count.is_non_zero(), 'Pool not initialized');

            let time = get_block_timestamp();
            let last_snapshot = entry.snapshots.read(count - 1);

            if (time == last_snapshot.block_timestamp) {
                last_snapshot.tick_cumulative
            } else {
                let price = self.core.read().get_pool_price(key.to_pool_key());
                last_snapshot.tick_cumulative
                    + (price.tick
                        * i129 { mag: (time - last_snapshot.block_timestamp).into(), sign: false })
            }
        }
    }

    const MAX_TICK_SPACING: u128 = 354892;

    #[abi(embed_v0)]
    impl OracleExtension of IExtension<ContractState> {
        fn before_initialize_pool(
            ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129
        ) {
            self.check_caller_is_core();
            let key = pool_key.to_pair_key();

            let state = self.pool_state.entry(key);

            state.count.write(1);
            state
                .snapshots
                .write(
                    0,
                    Snapshot {
                        block_timestamp: get_block_timestamp(), tick_cumulative: Zero::zero(),
                    }
                );
        }

        fn after_initialize_pool(
            ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129
        ) {
            assert(false, 'Call point not used');
        }

        fn before_swap(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: SwapParameters
        ) {
            // update seconds per liquidity
            let core = self.check_caller_is_core();
            self.update_pool(core, pool_key);
        }

        fn after_swap(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: SwapParameters,
            delta: Delta
        ) {
            assert(false, 'Call point not used');
        }

        fn before_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters
        ) {
            let core = self.check_caller_is_core();
            self.update_pool(core, pool_key);
        }

        fn after_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters,
            delta: Delta
        ) {
            assert(false, 'Call point not used');
        }

        fn before_collect_fees(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            salt: felt252,
            bounds: Bounds
        ) {
            assert(false, 'Call point not used');
        }

        fn after_collect_fees(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            salt: felt252,
            bounds: Bounds,
            delta: Delta
        ) {
            assert(false, 'Call point not used');
        }
    }
}
