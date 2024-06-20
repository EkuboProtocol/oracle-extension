use core::option::{OptionTrait};
use core::traits::{TryInto, Into};
use ekubo::interfaces::core::ICoreDispatcherTrait;
use ekubo::types::bounds::{Bounds};
use ekubo::types::i129::{i129, i129Trait};
use ekubo::types::keys::{PoolKey, PositionKey};
use starknet::storage_access::{StorePacking};

// 192 bits total, fits in a single felt
#[derive(Copy, Drop, PartialEq)]
pub struct PoolState {
    // 64 bits
    pub block_timestamp_last: u64,
    // 96 bits
    pub tick_cumulative_last: i129,
    // 32 bits
    pub tick_last: i129,
}


const DENOM_x160: NonZero<u256> = 0x10000000000000000000000000000000000000000;
const DENOM_x64: NonZero<u256> = 0x10000000000000000;

impl PoolStatePacking of StorePacking<PoolState, felt252> {
    fn pack(value: PoolState) -> felt252 {
        assert(
            value.tick_cumulative_last.mag < 0x800000000000000000000000,
            'TICK_CUMULATIVE_LAST_TOO_LARGE'
        );
        assert(value.tick_last.mag < 0x80000000, 'TICK_LAST_TOO_LARGE');

        let mut total: u256 = value.block_timestamp_last.into();

        total +=
            (if value.tick_cumulative_last.is_negative() {
                value.tick_cumulative_last.mag + 0x800000000000000000000000
            } else {
                value.tick_cumulative_last.mag
            })
            .into()
            * 0x10000000000000000;

        total +=
            u256 {
                high: (if value.tick_last.is_negative() {
                    value.tick_last.mag + 0x80000000
                } else {
                    value.tick_last.mag
                })
                    * 0x100000000,
                low: 0
            };

        total.try_into().unwrap()
    }

    fn unpack(value: felt252) -> PoolState {
        let value: u256 = value.into();

        let (tick_last_packed, value) = DivRem::div_rem(value, DENOM_x160);

        let tick_last = if (tick_last_packed > 0x80000000) {
            i129 { mag: (tick_last_packed - 0x80000000).try_into().unwrap(), sign: true }
        } else {
            i129 { mag: tick_last_packed.try_into().unwrap(), sign: false }
        };

        let (tick_cumulative_last_packed, block_timestamp_last) = DivRem::div_rem(value, DENOM_x64);

        let tick_cumulative_last = if (tick_cumulative_last_packed > 0x800000000000000000000000) {
            i129 {
                mag: (tick_cumulative_last_packed - 0x800000000000000000000000).try_into().unwrap(),
                sign: true
            }
        } else {
            i129 { mag: tick_cumulative_last_packed.try_into().unwrap(), sign: false }
        };

        PoolState {
            block_timestamp_last: block_timestamp_last.try_into().unwrap(),
            tick_cumulative_last,
            tick_last,
        }
    }
}
