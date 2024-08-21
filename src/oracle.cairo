mod pool_state;

#[cfg(test)]
mod pool_state_test;

use ekubo::types::bounds::{Bounds};
use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey};

#[starknet::interface]
pub trait IOracle<TStorage> {
    // Returns the seconds per liquidity within the given bounds. Must be used only as a snapshot
    // You cannot rely on this snapshot to be consistent across positions
    fn get_seconds_per_liquidity_inside(
        self: @TStorage, pool_key: PoolKey, bounds: Bounds
    ) -> felt252;

    // Returns the cumulative tick value for a given pool, useful for computing a geomean oracle for
    // the duration of a position
    fn get_tick_cumulative(self: @TStorage, pool_key: PoolKey) -> i129;
}

// This extension can be used with pools to track the liquidity-seconds per liquidity over time.
// This measure can be used to incentive positions in this pool.
#[starknet::contract]
pub mod Oracle {
    use core::num::traits::{Zero};
    use core::option::{OptionTrait};
    use core::traits::{Into, TryInto};
    use ekubo::components::shared_locker::{check_caller_is_core};
    use ekubo::interfaces::core::{
        ICoreDispatcher, ICoreDispatcherTrait, IExtension, SwapParameters, UpdatePositionParameters
    };
    use ekubo::types::bounds::{Bounds};
    use ekubo::types::call_points::{CallPoints};
    use ekubo::types::delta::{Delta};
    use ekubo::types::i129::{i129};
    use starknet::storage::{
        Map, StoragePointerWriteAccess, StorageMapReadAccess, StoragePointerReadAccess,
        StorageMapWriteAccess
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use super::{IOracle, PoolKey, pool_state::{PoolState}};

    #[storage]
    struct Storage {
        pub core: ICoreDispatcher,
        pub pool_state: Map<PoolKey, PoolState>,
        pub pool_seconds_per_liquidity: Map<PoolKey, felt252>,
        pub tick_seconds_per_liquidity_outside: Map<(PoolKey, i129), felt252>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, core: ICoreDispatcher) {
        self.core.write(core);
        core
            .set_call_points(
                CallPoints {
                    // to record the initial tick
                    before_initialize_pool: true,
                    after_initialize_pool: false,
                    // in order to record the seconds that have passed / liquidity
                    before_swap: true,
                    // to update the per-tick seconds per liquiidty
                    after_swap: true,
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
            let state = self.pool_state.read(pool_key);

            let time = get_block_timestamp();
            let time_passed: u128 = (time - state.block_timestamp_last).into();

            if (time_passed.is_zero()) {
                return;
            }

            let liquidity = core.get_pool_liquidity(pool_key);

            if (liquidity.is_non_zero()) {
                self
                    .pool_seconds_per_liquidity
                    .write(
                        pool_key,
                        self.pool_seconds_per_liquidity.read(pool_key)
                            + (u256 { low: 0, high: time_passed }
                                / u256 { low: liquidity, high: 0 })
                                .try_into()
                                .unwrap()
                    )
            }

            let price = core.get_pool_price(pool_key);

            let tick_cumulative_next = state.tick_cumulative_last
                + (price.tick * i129 { mag: time_passed, sign: false });

            self
                .pool_state
                .write(
                    pool_key,
                    PoolState {
                        block_timestamp_last: time,
                        tick_cumulative_last: tick_cumulative_next,
                        tick_last: state.tick_last,
                    }
                );
        }
    }

    #[abi(embed_v0)]
    impl OracleImpl of IOracle<ContractState> {
        // Returns the number of seconds that the position has held the full liquidity of the pool,
        // as a fixed point number with 128 bits after the radix
        fn get_seconds_per_liquidity_inside(
            self: @ContractState, pool_key: PoolKey, bounds: Bounds
        ) -> felt252 {
            let core = self.core.read();
            let time = get_block_timestamp();
            let price = core.get_pool_price(pool_key);

            // subtract the lower and upper tick of the bounds based on the price
            let lower = self.tick_seconds_per_liquidity_outside.read((pool_key, bounds.lower));
            let upper = self.tick_seconds_per_liquidity_outside.read((pool_key, bounds.upper));

            if (price.tick < bounds.lower) {
                upper - lower
            } else if (price.tick < bounds.upper) {
                // get the global seconds per liquidity
                let state = self.pool_state.read(pool_key);
                let seconds_per_liquidity_global = if (time == state.block_timestamp_last) {
                    self.pool_seconds_per_liquidity.read(pool_key)
                } else {
                    let liquidity = core.get_pool_liquidity(pool_key);
                    if (liquidity.is_zero()) {
                        self.pool_seconds_per_liquidity.read(pool_key)
                    } else {
                        self.pool_seconds_per_liquidity.read(pool_key)
                            + (u256 { low: 0, high: (time - state.block_timestamp_last).into() }
                                / u256 { low: liquidity, high: 0 })
                                .try_into()
                                .unwrap()
                    }
                };

                (seconds_per_liquidity_global - lower) - upper
            } else {
                upper - lower
            }
        }

        fn get_tick_cumulative(self: @ContractState, pool_key: PoolKey) -> i129 {
            let time = get_block_timestamp();
            let state = self.pool_state.read(pool_key);

            if (time == state.block_timestamp_last) {
                state.tick_cumulative_last
            } else {
                let price = self.core.read().get_pool_price(pool_key);
                state.tick_cumulative_last
                    + (price.tick
                        * i129 { mag: (time - state.block_timestamp_last).into(), sign: false })
            }
        }
    }

    #[abi(embed_v0)]
    impl OracleExtension of IExtension<ContractState> {
        fn before_initialize_pool(
            ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129
        ) {
            self.check_caller_is_core();

            self
                .pool_state
                .write(
                    pool_key,
                    PoolState {
                        block_timestamp_last: get_block_timestamp(),
                        tick_cumulative_last: Zero::zero(),
                        tick_last: initial_tick,
                    }
                );
        }

        fn after_initialize_pool(
            ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129
        ) {
            assert(false, 'NOT_USED');
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
            let core = self.check_caller_is_core();

            let price = core.get_pool_price(pool_key);
            let state = self.pool_state.read(pool_key);

            if (state.tick_last != price.tick) {
                let increasing = params.amount.sign != params.is_token1;

                let mut tick = state.tick_last;

                let current = self.tick_seconds_per_liquidity_outside.read((pool_key, tick));

                let seconds_per_liquidity_global = self.pool_seconds_per_liquidity.read(pool_key);

                // update all the ticks between the last updated tick to the starting tick
                loop {
                    let (next, initialized) = if (increasing) {
                        core.next_initialized_tick(pool_key, tick, params.skip_ahead)
                    } else {
                        core.prev_initialized_tick(pool_key, tick, params.skip_ahead)
                    };

                    if ((next > price.tick) == increasing) {
                        break ();
                    }

                    if (initialized) {
                        self
                            .tick_seconds_per_liquidity_outside
                            .write((pool_key, tick), current - seconds_per_liquidity_global);
                    }

                    tick = if (increasing) {
                        next
                    } else {
                        next - i129 { mag: 1, sign: false }
                    };
                };

                // we are just updating tick last to indicate we processed all the ticks that were
                // crossed in the swap
                self
                    .pool_state
                    .write(
                        pool_key,
                        PoolState {
                            block_timestamp_last: state.block_timestamp_last,
                            tick_cumulative_last: state.tick_cumulative_last,
                            tick_last: price.tick,
                        }
                    );
            }
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
            assert(false, 'NOT_USED');
        }

        fn before_collect_fees(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            salt: felt252,
            bounds: Bounds
        ) {
            assert(false, 'NOT_USED');
        }

        fn after_collect_fees(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            salt: felt252,
            bounds: Bounds,
            delta: Delta
        ) {
            assert(false, 'NOT_USED');
        }
    }
}
