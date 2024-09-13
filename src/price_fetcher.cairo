use starknet::{ContractAddress};

#[derive(Copy, Drop, PartialEq, Serde, Debug)]
pub enum PriceResult {
    NotInitialized,
    InsufficientLiquidity,
    PeriodTooLong,
    Price: u256
}

#[starknet::interface]
pub trait IPriceFetcher<TContractState> {
    // Returns the prices in terms of quote token, but only if the oracle pool has sufficient
    // liquidity denominated in the oracle token.
    fn get_prices(
        self: @TContractState,
        quote_token: ContractAddress,
        base_tokens: Span<ContractAddress>,
        period: u64,
        min_token: u128
    ) -> Span<PriceResult>;
}

#[starknet::contract]
mod PriceFetcher {
    use core::num::traits::{Zero};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
    use ekubo::types::keys::{PoolKey};
    use ekubo_oracle_extension::oracle::{
        IOracleDispatcher, IOracleDispatcherTrait, Oracle::{MAX_TICK_SPACING}
    };
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{get_block_timestamp};
    use super::{IPriceFetcher, PriceResult, ContractAddress};

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        oracle: IOracleDispatcher,
    }

    #[constructor]
    fn constructor(ref self: ContractState, core: ICoreDispatcher, oracle: IOracleDispatcher) {
        self.core.write(core);
        self.oracle.write(oracle);
    }

    const MIN_SQRT_RATIO: u256 = 18446748437148339061;
    const MAX_SQRT_RATIO: u256 = 6277100250585753475930931601400621808602321654880405518632;

    #[abi(embed_v0)]
    impl PriceFetcherImpl of IPriceFetcher<ContractState> {
        fn get_prices(
            self: @ContractState,
            quote_token: ContractAddress,
            mut base_tokens: Span<ContractAddress>,
            period: u64,
            min_token: u128
        ) -> Span<PriceResult> {
            let core = self.core.read();
            let oracle = self.oracle.read();
            let oracle_token = oracle.get_oracle_token();
            let math = mathlib();

            let mut result: Array<PriceResult> = array![];

            let time = get_block_timestamp();

            while let Option::Some(next) = base_tokens.pop_front() {
                let is_token0 = *next < oracle_token;
                let (token0, token1) = if is_token0 {
                    (*next, oracle_token)
                } else {
                    (oracle_token, *next)
                };
                let pool_key = PoolKey {
                    token0,
                    token1,
                    fee: 0,
                    tick_spacing: MAX_TICK_SPACING,
                    extension: oracle.contract_address,
                };
                let price = core.get_pool_price(pool_key);
                if price.sqrt_ratio.is_zero() {
                    result.append(PriceResult::NotInitialized);
                } else {
                    let liquidity = core.get_pool_liquidity(pool_key);
                    let amount_ekubo = if is_token0 {
                        // oracle token is token1
                        math.amount1_delta(MIN_SQRT_RATIO, price.sqrt_ratio, liquidity, false)
                    } else {
                        math.amount0_delta(price.sqrt_ratio, MAX_SQRT_RATIO, liquidity, false)
                    };

                    if amount_ekubo < min_token {
                        result.append(PriceResult::InsufficientLiquidity)
                    } else {
                        if let Option::Some(earliest) = oracle
                            .get_earliest_observation_time(*next, quote_token) {
                            if time - earliest < period {
                                result.append(PriceResult::PeriodTooLong);
                            } else {
                                result
                                    .append(
                                        PriceResult::Price(
                                            oracle
                                                .get_price_x128_over_last(
                                                    *next, quote_token, period
                                                )
                                        )
                                    );
                            }
                        } else {
                            result.append(PriceResult::NotInitialized);
                        }
                    }
                };
            };

            result.span()
        }
    }
}
