use core::num::traits::{Zero};
use ekubo::components::owned::{IOwnedDispatcher, IOwnedDispatcherTrait};
use ekubo::interfaces::core::{ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher};
use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount};
use ekubo::types::bounds::{Bounds};
use ekubo::types::call_points::{CallPoints};
use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey};
use ekubo_oracle_extension::oracle::{
    IOracleDispatcher, IOracleDispatcherTrait,
    Oracle::{MAX_TICK_SPACING, quote_amount_from_tick, tick_to_price_x128}
};
use ekubo_oracle_extension::test_token::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{declare, ContractClassTrait, cheat_block_timestamp, CheatSpan, ContractClass};
use starknet::{get_contract_address, get_block_timestamp, contract_address_const, ContractAddress};

fn deploy_token(
    class: ContractClass, recipient: ContractAddress, amount: u256
) -> IERC20Dispatcher {
    let (contract_address, _) = class
        .deploy(@array![recipient.into(), amount.low.into(), amount.high.into()])
        .expect('Deploy token failed');

    IERC20Dispatcher { contract_address }
}

fn default_owner() -> ContractAddress {
    contract_address_const::<0xdeadbeefdeadbeef>()
}


fn deploy_oracle(owner: ContractAddress, core: ICoreDispatcher) -> IExtensionDispatcher {
    let contract = declare("Oracle").unwrap();
    let (contract_address, _) = contract
        .deploy(@array![default_owner().into(), core.contract_address.into()])
        .expect('Deploy failed');

    IExtensionDispatcher { contract_address }
}

fn ekubo_core() -> ICoreDispatcher {
    ICoreDispatcher {
        contract_address: contract_address_const::<
            0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b
        >()
    }
}

fn positions() -> IPositionsDispatcher {
    IPositionsDispatcher {
        contract_address: contract_address_const::<
            0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067
        >()
    }
}

fn router() -> IRouterDispatcher {
    IRouterDispatcher {
        contract_address: contract_address_const::<
            0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e
        >()
    }
}

fn setup() -> PoolKey {
    let oracle = deploy_oracle(default_owner(), ekubo_core());
    let token_class = declare("TestToken").unwrap();
    let owner = get_contract_address();
    let (tokenA, tokenB) = (
        deploy_token(
            token_class,
            owner,
            amount: 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
        ),
        deploy_token(
            token_class,
            owner,
            amount: 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
        )
    );
    let (token0, token1) = if (tokenA.contract_address < tokenB.contract_address) {
        (tokenA, tokenB)
    } else {
        (tokenB, tokenA)
    };

    let pool_key = PoolKey {
        token0: token0.contract_address,
        token1: token1.contract_address,
        fee: 0,
        tick_spacing: 354892,
        extension: oracle.contract_address,
    };

    pool_key
}

#[test]
#[fork("mainnet")]
fn test_oracle_sets_call_points() {
    let pool_key = setup();
    assert_eq!(
        ekubo_core().get_call_points(pool_key.extension),
        CallPoints {
            before_initialize_pool: true,
            after_initialize_pool: false,
            before_swap: true,
            after_swap: false,
            before_update_position: true,
            after_update_position: false,
            before_collect_fees: false,
            after_collect_fees: false,
        }
    );
    assert_eq!(
        IOwnedDispatcher { contract_address: pool_key.extension }.get_owner(), default_owner()
    );
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Position must be full range',))]
fn test_position_must_be_full_range() {
    let pool_key = setup();
    ekubo_core().initialize_pool(pool_key, i129 { mag: 0, sign: false });
    IERC20Dispatcher { contract_address: pool_key.token0 }
        .transfer(positions().contract_address, 100);
    positions()
        .mint_and_deposit(
            pool_key,
            Bounds { lower: Zero::zero(), upper: i129 { mag: MAX_TICK_SPACING, sign: false } },
            Zero::zero()
        );
}

#[test]
#[fork("mainnet")]
fn test_get_tick_cumulative_increases_over_time() {
    let pool_key = setup();
    let oracle = IOracleDispatcher { contract_address: pool_key.extension };

    ekubo_core().initialize_pool(pool_key, i129 { mag: 693147, sign: false });

    assert_eq!(oracle.get_tick_cumulative(pool_key.token0, pool_key.token1), Zero::zero());

    cheat_block_timestamp(pool_key.extension, get_block_timestamp() + 10, CheatSpan::Indefinite);

    assert_eq!(
        oracle.get_tick_cumulative(pool_key.token0, pool_key.token1),
        i129 { mag: 6931470, sign: false }
    );

    assert_eq!(
        oracle.get_average_tick_over_last(pool_key.token0, pool_key.token1, period: 10),
        i129 { mag: 693147, sign: false }
    );

    // flip the tokens and you should get the negative tick
    assert_eq!(
        oracle.get_average_tick_over_last(pool_key.token1, pool_key.token0, period: 10),
        i129 { mag: 693147, sign: true }
    );

    assert_eq!(
        oracle.get_price_x128_over_last(pool_key.token0, pool_key.token1, period: 10),
        // approximately equal to 2 ** 2 ** 128
        680564375093695818504095915961505477038
    );
    assert_eq!(
        oracle.get_price_x128_over_last(pool_key.token1, pool_key.token0, period: 10),
        // approximately equal to 0.5 ** 2 ** 128
        170141273147561785870265730329854047831
    );
}


#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Time before first snapshot',))]
fn test_get_tick_cumulative_at_past() {
    let pool_key = setup();
    let oracle = IOracleDispatcher { contract_address: pool_key.extension };

    let start = get_block_timestamp() + 10;
    cheat_block_timestamp(pool_key.extension, start, CheatSpan::Indefinite);
    ekubo_core().initialize_pool(pool_key, i129 { mag: 693147, sign: false });

    oracle.get_tick_cumulative_at(pool_key.token0, pool_key.token1, start - 1);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Time in future',))]
fn test_get_tick_cumulative_at_future() {
    let pool_key = setup();
    let oracle = IOracleDispatcher { contract_address: pool_key.extension };

    let start = get_block_timestamp() + 10;
    cheat_block_timestamp(pool_key.extension, start, CheatSpan::Indefinite);
    ekubo_core().initialize_pool(pool_key, i129 { mag: 693147, sign: false });

    oracle.get_tick_cumulative_at(pool_key.token0, pool_key.token1, start + 1);
}

// assumes there is 0 liquidity so swaps are free
fn move_price_to_tick(pool_key: PoolKey, tick: i129) {
    let tick_current = ekubo_core().get_pool_price(pool_key).tick;
    if tick_current < tick {
        router()
            .swap(
                RouteNode {
                    pool_key, sqrt_ratio_limit: mathlib().tick_to_sqrt_ratio(tick), skip_ahead: 0,
                },
                TokenAmount { token: pool_key.token1, amount: i129 { mag: 1, sign: false }, }
            );
    } else if tick_current > tick {
        router()
            .swap(
                RouteNode {
                    pool_key,
                    sqrt_ratio_limit: mathlib().tick_to_sqrt_ratio(tick) + 1,
                    skip_ahead: 0,
                },
                TokenAmount { token: pool_key.token0, amount: i129 { mag: 1, sign: false }, }
            );
    }
}

#[test]
#[fork("mainnet")]
fn test_get_tick_cumulative_changes_with_swaps_up() {
    let pool_key = setup();
    let oracle = IOracleDispatcher { contract_address: pool_key.extension };

    ekubo_core().initialize_pool(pool_key, i129 { mag: 693147, sign: false });
    move_price_to_tick(pool_key, i129 { mag: 693147 * 2, sign: false });

    assert_eq!(oracle.get_tick_cumulative(pool_key.token0, pool_key.token1), Zero::zero());

    cheat_block_timestamp(pool_key.extension, get_block_timestamp() + 10, CheatSpan::Indefinite);

    assert_eq!(
        oracle.get_tick_cumulative(pool_key.token0, pool_key.token1),
        i129 { mag: 13862940, sign: false }
    );

    assert_eq!(
        oracle.get_average_tick_over_last(pool_key.token0, pool_key.token1, period: 10),
        i129 { mag: 1386294, sign: false }
    );
}

#[test]
#[fork("mainnet")]
fn test_get_tick_cumulative_changes_with_swaps_down() {
    let pool_key = setup();
    let oracle = IOracleDispatcher { contract_address: pool_key.extension };

    ekubo_core().initialize_pool(pool_key, i129 { mag: 693147, sign: false });
    move_price_to_tick(pool_key, i129 { mag: 693147 * 2, sign: true });

    assert_eq!(oracle.get_tick_cumulative(pool_key.token0, pool_key.token1), Zero::zero());

    cheat_block_timestamp(pool_key.extension, get_block_timestamp() + 10, CheatSpan::Indefinite);

    assert_eq!(
        oracle.get_tick_cumulative(pool_key.token0, pool_key.token1),
        i129 { mag: 13862940, sign: true }
    );

    assert_eq!(
        oracle.get_average_tick_over_last(pool_key.token0, pool_key.token1, period: 10),
        i129 { mag: 1386294, sign: true }
    );
}

#[test]
#[fork("mainnet")]
fn test_get_tick_cumulative_at_history() {
    let pool_key = setup();
    let oracle = IOracleDispatcher { contract_address: pool_key.extension };

    let start_time = get_block_timestamp();
    ekubo_core().initialize_pool(pool_key, i129 { mag: 100, sign: false });
    move_price_to_tick(pool_key, i129 { mag: 200, sign: false });
    cheat_block_timestamp(pool_key.extension, start_time + 3, CheatSpan::Indefinite);
    move_price_to_tick(pool_key, i129 { mag: 400, sign: true });
    cheat_block_timestamp(pool_key.extension, start_time + 5, CheatSpan::Indefinite);
    move_price_to_tick(pool_key, i129 { mag: 100, sign: false });
    cheat_block_timestamp(pool_key.extension, start_time + 8, CheatSpan::Indefinite);

    assert_eq!(
        oracle.get_tick_cumulative_at(pool_key.token0, pool_key.token1, start_time), Zero::zero()
    );

    assert_eq!(
        oracle.get_tick_cumulative_at(pool_key.token0, pool_key.token1, start_time + 1),
        i129 { mag: 200, sign: false }
    );

    assert_eq!(
        oracle.get_tick_cumulative_at(pool_key.token0, pool_key.token1, start_time + 4),
        i129 { mag: 200, sign: false }
    );

    assert_eq!(
        oracle.get_tick_cumulative_at(pool_key.token0, pool_key.token1, start_time + 5),
        i129 { mag: 200, sign: true }
    );

    assert_eq!(
        oracle.get_tick_cumulative_at(pool_key.token0, pool_key.token1, start_time + 7),
        Zero::zero()
    );

    // 2 * 3 + (-4 * 2) + (1 * 3)
    assert_eq!(
        oracle.get_tick_cumulative(pool_key.token0, pool_key.token1), i129 { mag: 100, sign: false }
    );
}

#[test]
#[fork("mainnet")]
fn test_get_price_history() {
    let pool_key = setup();
    let oracle = IOracleDispatcher { contract_address: pool_key.extension };

    let start_time = 100;
    cheat_block_timestamp(pool_key.extension, start_time, CheatSpan::Indefinite);
    ekubo_core().initialize_pool(pool_key, i129 { mag: 100, sign: false });
    move_price_to_tick(pool_key, i129 { mag: 200, sign: false });
    cheat_block_timestamp(pool_key.extension, start_time + 30, CheatSpan::Indefinite);
    move_price_to_tick(pool_key, i129 { mag: 400, sign: true });
    cheat_block_timestamp(pool_key.extension, start_time + 50, CheatSpan::Indefinite);
    move_price_to_tick(pool_key, i129 { mag: 100, sign: false });
    cheat_block_timestamp(pool_key.extension, start_time + 80, CheatSpan::Indefinite);
    let end_time = start_time + 100;
    cheat_block_timestamp(pool_key.extension, end_time, CheatSpan::Indefinite);

    assert_eq!(
        oracle
            .get_average_tick_history(
                pool_key.token0,
                pool_key.token1,
                end_time: end_time,
                num_intervals: 5,
                interval_seconds: 20
            ),
        array![
            i129 { mag: 200, sign: false },
            i129 { mag: 100, sign: true },
            i129 { mag: 150, sign: true },
            i129 { mag: 100, sign: false },
            i129 { mag: 100, sign: false },
        ]
            .span()
    );

    assert_eq!(
        oracle
            .get_average_price_x128_history(
                pool_key.token0,
                pool_key.token1,
                end_time: end_time,
                num_intervals: 5,
                interval_seconds: 20
            ),
        array![
            340350430166388701755467421055154484122,
            340248340402613897589817814458911858594,
            340231328419402881519580289477549909252,
            340316396842083298561446798436459715947,
            340316396842083298561446798436459715947,
        ]
            .span()
    );
}

#[test]
#[fork("mainnet")]
fn test_tick_to_price_one_half() {
    assert_eq!(
        tick_to_price_x128(i129 { mag: 693148, sign: false }),
        680565055658070912199914420057421438541
    );
    assert_eq!(
        tick_to_price_x128(i129 { mag: 693148, sign: true }),
        170141103006458779411486318843535204296
    );
}

#[test]
#[fork("mainnet")]
fn test_tick_to_price_one() {
    assert_eq!(tick_to_price_x128(Zero::zero()), u256 { high: 1, low: 0 });
}

#[test]
#[fork("mainnet")]
fn test_tick_to_price_max() {
    assert_eq!(
        tick_to_price_x128(i129 { mag: 88722883, sign: false }),
        115792034457837262086784631235862882081404018044140045679084062790953130557576
    );
}

#[test]
#[fork("mainnet")]
fn test_tick_to_price_min() {
    assert_eq!(tick_to_price_x128(i129 { mag: 88722883, sign: true }), 1);
}

#[test]
#[fork("mainnet")]
fn test_quote_amount_from_tick() {
    assert_eq!(quote_amount_from_tick(100, i129 { mag: 693148, sign: false }), 200);
    assert_eq!(quote_amount_from_tick(100, i129 { mag: 693148, sign: true }), 49);
}
