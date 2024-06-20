use core::num::traits::{Zero};
use ekubo::types::i129::{i129};
use ekubo_extension::oracle::pool_state::{PoolState};

use starknet::{storage_access::{StorePacking}};

fn assert_round_trip<T, U, +StorePacking<T, U>, +PartialEq<T>, +Drop<T>, +Copy<T>>(value: T) {
    assert(StorePacking::<T, U>::unpack(StorePacking::<T, U>::pack(value)) == value, 'roundtrip');
}

#[test]
fn test_pool_state_packing_round_trip_many_values() {
    assert_round_trip(
        PoolState {
            block_timestamp_last: Zero::zero(),
            tick_cumulative_last: Zero::zero(),
            tick_last: Zero::zero(),
        }
    );
    assert_round_trip(
        PoolState {
            block_timestamp_last: 1,
            tick_cumulative_last: i129 { mag: 2, sign: false },
            tick_last: i129 { mag: 3, sign: false },
        }
    );
    assert_round_trip(
        PoolState {
            block_timestamp_last: 1,
            tick_cumulative_last: i129 { mag: 2, sign: true },
            tick_last: i129 { mag: 3, sign: true },
        }
    );
    assert_round_trip(
        PoolState {
            block_timestamp_last: 0xffffffffffffffff,
            tick_cumulative_last: i129 { mag: 0x7fffffffffffffffffffffff, sign: false },
            tick_last: i129 { mag: 0x7fffffff, sign: false },
        }
    );
    assert_round_trip(
        PoolState {
            block_timestamp_last: 0xffffffffffffffff,
            tick_cumulative_last: i129 { mag: 0x7fffffffffffffffffffffff, sign: true },
            tick_last: i129 { mag: 0x7fffffff, sign: true },
        }
    );
}
