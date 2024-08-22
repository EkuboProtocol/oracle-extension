mod snapshot;

#[cfg(test)]
mod snapshot_test;

use ekubo::types::i129::{i129};
use starknet::{ContractAddress};

#[starknet::interface]
pub trait IOracle<TContractState> {
    // Returns the cumulative tick value for a given pool, useful for computing a geomean oracle
    // over a period of time.
    fn get_tick_cumulative(
        self: @TContractState, token0: ContractAddress, token1: ContractAddress
    ) -> i129;

    // Returns the cumulative tick at the given time. The time must be in between the initialization
    // time of the pool and the current block timestamp.
    fn get_tick_cumulative_at(
        self: @TContractState, token0: ContractAddress, token1: ContractAddress, time: u64
    ) -> i129;

    // Returns the time weighted average tick between the given start and end time
    fn get_average_tick_over_period(
        self: @TContractState,
        token0: ContractAddress,
        token1: ContractAddress,
        start_time: u64,
        end_time: u64
    ) -> i129;

    // Returns the time weighted average tick over the last `period` seconds
    fn get_average_tick_over_last(
        self: @TContractState, token0: ContractAddress, token1: ContractAddress, period: u64
    ) -> i129;

    // Returns the geomean average price of a token as a 128.128 between the given start and end
    // time
    fn get_price_x128_over_period(
        self: @TContractState,
        base_token: ContractAddress,
        quote_token: ContractAddress,
        start_time: u64,
        end_time: u64
    ) -> u256;

    // Returns the geomean average price of a token as a 128.128 over the last `period` secon
    fn get_price_x128_over_last(
        self: @TContractState,
        base_token: ContractAddress,
        quote_token: ContractAddress,
        period: u64
    ) -> u256;
}


// Measures the oracle
#[starknet::contract]
pub mod Oracle {
    use core::integer::{u512_safe_div_rem_by_u256};
    use core::num::traits::{WideMul};
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
    use ekubo::interfaces::mathlib::{
        IMathLibLibraryDispatcher, IMathLibDispatcherTrait, dispatcher as mathlib
    };
    use ekubo::types::bounds::{Bounds};
    use ekubo::types::call_points::{CallPoints};
    use ekubo::types::delta::{Delta};
    use ekubo::types::i129::{i129};
    use ekubo::types::keys::{PoolKey};
    use starknet::storage::StoragePathEntry;
    use starknet::storage::{
        Map, StoragePointerWriteAccess, StorageMapReadAccess, StoragePointerReadAccess,
        StorageMapWriteAccess
    };

    use starknet::{get_block_timestamp, get_caller_address, get_contract_address};

    use super::{IOracle, ContractAddress, snapshot::{Snapshot}};

    // Given the average tick (corresponding to a geomean average price) from one of the average
    // tick methods, quote an amount of one token for another at that tick
    pub fn quote_amount_from_tick(amount: u128, tick: i129) -> u256 {
        let math = mathlib();
        let sqrt_ratio = math.tick_to_sqrt_ratio(tick);
        // this is a 128.256 number, i.e. limb3 is always 0. we can shift it right 128 bits by
        // just taking limb2 and limb1 and get a 128.128 number
        let ratio = WideMul::wide_mul(sqrt_ratio, sqrt_ratio);

        let result_x128 = WideMul::wide_mul(
            u256 { high: ratio.limb2, low: ratio.limb1 }, amount.into()
        );

        u256 { high: result_x128.limb2, low: result_x128.limb1 }
    }

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
    impl HasInterfaceImpl of IHasInterface<ContractState> {
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
    fn constructor(ref self: ContractState, owner: ContractAddress, core: ICoreDispatcher) {
        self.initialize_owned(owner);
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
            let time_passed = (time - last_snapshot.block_timestamp);

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
                            + (tick * i129 { mag: time_passed.into(), sign: false }),
                    }
                );
        }
    }

    #[abi(embed_v0)]
    impl OracleImpl of IOracle<ContractState> {
        fn get_tick_cumulative(
            self: @ContractState, token0: ContractAddress, token1: ContractAddress
        ) -> i129 {
            self.get_tick_cumulative_at(token0, token1, get_block_timestamp())
        }

        fn get_tick_cumulative_at(
            self: @ContractState, token0: ContractAddress, token1: ContractAddress, time: u64
        ) -> i129 {
            let key = (token0, token1);
            let entry = self.pool_state.entry(key);
            let count = entry.count.read();
            assert(count.is_non_zero(), 'Pool not initialized');

            let mut l = 0_u64;
            let mut r = count;
            let (index, snapshot) = loop {
                let mid = (l + r) / 2;
                let snap = entry.snapshots.read(mid);
                if snap.block_timestamp == time {
                    break (mid, snap);
                } else if snap.block_timestamp > time {
                    assert(mid.is_non_zero(), 'Time before first snapshot');
                    r = mid;
                } else {
                    let next = mid + 1;
                    // this is the last snapshot, and it's before the specified time
                    if (next >= count) {
                        break (mid, snap);
                    } else {
                        let next_snap = entry.snapshots.read(next);
                        if next_snap.block_timestamp > time {
                            break (mid, snap);
                        } else {
                            l = next;
                        }
                    }
                }
            };

            if snapshot.block_timestamp == time {
                snapshot.tick_cumulative
            } else {
                let tick = if index == count - 1 {
                    self.core.read().get_pool_price(key.to_pool_key()).tick
                } else {
                    let next = entry.snapshots.read(index + 1);
                    (next.tick_cumulative - snapshot.tick_cumulative)
                        / i129 {
                            mag: (next.block_timestamp - snapshot.block_timestamp).into(),
                            sign: false
                        }
                };
                snapshot.tick_cumulative
                    + tick * i129 { mag: (time - snapshot.block_timestamp).into(), sign: false }
            }
        }

        fn get_average_tick_over_period(
            self: @ContractState,
            token0: ContractAddress,
            token1: ContractAddress,
            start_time: u64,
            end_time: u64
        ) -> i129 {
            assert(end_time > start_time, 'Period must be > 0 seconds long');
            let start_cumulative = self.get_tick_cumulative_at(token0, token1, start_time);
            let end_cumulative = self.get_tick_cumulative_at(token0, token1, end_time);
            let difference = end_cumulative - start_cumulative;
            difference / i129 { mag: (end_time - start_time).into(), sign: false }
        }

        fn get_average_tick_over_last(
            self: @ContractState, token0: ContractAddress, token1: ContractAddress, period: u64
        ) -> i129 {
            let now = get_block_timestamp();
            self.get_average_tick_over_period(token0, token1, now - period, now)
        }

        fn get_price_x128_over_period(
            self: @ContractState,
            base_token: ContractAddress,
            quote_token: ContractAddress,
            start_time: u64,
            end_time: u64,
        ) -> u256 {
            let (token0, token1, flipped) = if base_token < quote_token {
                (base_token, quote_token, false)
            } else {
                (quote_token, base_token, true)
            };
            let mut average_tick = self
                .get_average_tick_over_period(token0, token1, start_time, end_time);

            if flipped {
                average_tick = -average_tick;
            }

            let math = mathlib();
            let sqrt_ratio = math.tick_to_sqrt_ratio(average_tick);
            let ratio = WideMul::wide_mul(sqrt_ratio, sqrt_ratio);
            u256 { high: ratio.limb2, low: ratio.limb1 }
        }

        fn get_price_x128_over_last(
            self: @ContractState,
            base_token: ContractAddress,
            quote_token: ContractAddress,
            period: u64
        ) -> u256 {
            let now = get_block_timestamp();
            self.get_price_x128_over_period(base_token, quote_token, now - period, now)
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
