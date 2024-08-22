use core::option::{OptionTrait};
use core::traits::{TryInto, Into};
use ekubo::types::i129::{i129, i129Trait};
use starknet::storage_access::{StorePacking};

// 192 bits total, fits in a single felt
#[derive(Copy, Drop, PartialEq)]
pub struct Snapshot {
    // 64 bits
    pub block_timestamp: u64,
    // 96 bits
    pub tick_cumulative: i129,
}

const DENOM_x160: NonZero<u256> = 0x10000000000000000000000000000000000000000;
const DENOM_x64: NonZero<u256> = 0x10000000000000000;

impl SnapshotPacking of StorePacking<Snapshot, felt252> {
    fn pack(value: Snapshot) -> felt252 {
        assert(value.tick_cumulative.mag < 0x800000000000000000000000, 'TICK_CUMULATIVE_TOO_LARGE');

        let mut total: u256 = value.block_timestamp.into();

        total +=
            (if value.tick_cumulative.is_negative() {
                value.tick_cumulative.mag + 0x800000000000000000000000
            } else {
                value.tick_cumulative.mag
            })
            .into()
            * 0x10000000000000000;

        total.try_into().unwrap()
    }

    fn unpack(value: felt252) -> Snapshot {
        let value: u256 = value.into();

        let (_tick_packed, value) = DivRem::div_rem(value, DENOM_x160);

        let (tick_cumulative_packed, block_timestamp) = DivRem::div_rem(value, DENOM_x64);

        let tick_cumulative = if (tick_cumulative_packed > 0x800000000000000000000000) {
            i129 {
                mag: (tick_cumulative_packed - 0x800000000000000000000000).try_into().unwrap(),
                sign: true
            }
        } else {
            i129 { mag: tick_cumulative_packed.try_into().unwrap(), sign: false }
        };

        Snapshot { block_timestamp: block_timestamp.try_into().unwrap(), tick_cumulative }
    }
}
