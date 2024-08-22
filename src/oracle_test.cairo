use core::num::traits::{Zero};
use core::option::{OptionTrait};
use core::traits::{TryInto};
use ekubo::interfaces::core::{
    ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher, IExtensionDispatcherTrait
};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount};
use ekubo::types::bounds::{Bounds};
use ekubo::types::call_points::{CallPoints};
use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey, PositionKey};
use ekubo_oracle_extension::oracle::{
    IOracleDispatcher, IOracleDispatcherTrait, Oracle, Oracle::{quote_amount_from_tick}
};
use ekubo_oracle_extension::test_token::{TestToken, IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    declare, ContractClassTrait, cheat_caller_address, cheat_block_timestamp, CheatSpan,
    ContractClass
};
use starknet::{
    get_contract_address, get_block_timestamp, contract_address_const,
    storage_access::{StorePacking}, syscalls::{deploy_syscall}, ContractAddress
};

fn deploy_token(
    class: ContractClass, recipient: ContractAddress, amount: u256
) -> IERC20Dispatcher {
    let (contract_address, _) = class
        .deploy(@array![recipient.into(), amount.low.into(), amount.high.into()])
        .expect('Deploy token failed');

    IERC20Dispatcher { contract_address }
}

fn deploy_oracle(core: ICoreDispatcher) -> IExtensionDispatcher {
    let contract = declare("Oracle").unwrap();
    let (contract_address, _) = contract
        .deploy(@array![core.contract_address.into()])
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
    let oracle = deploy_oracle(ekubo_core());
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
fn test_quote_amount_from_tick() {
    assert_eq!(quote_amount_from_tick(100, i129 { mag: 693148, sign: false }), 200);
    assert_eq!(quote_amount_from_tick(100, i129 { mag: 693148, sign: true }), 49);
}
