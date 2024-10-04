use starknet::{ContractAddress};

#[derive(Copy, Drop, PartialEq, Serde, Debug)]
pub enum PriceResult {
    NotInitialized,
    InsufficientLiquidity,
    PeriodTooLong,
    Price: u256
}

#[derive(Copy, Drop, PartialEq, Serde, Debug)]
pub struct CandlestickPoint {
    time: u64,
    min: u256,
    max: u256,
    open: u256,
    close: u256,
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

    // Returns the prices in terms of the oracle token
    fn get_prices_in_oracle_tokens(
        self: @TContractState, base_tokens: Span<ContractAddress>, period: u64, min_token: u128
    ) -> (ContractAddress, Span<PriceResult>);

    // Returns data to populate a candlestick chart
    fn get_candlestick_chart_data(
        self: @TContractState,
        base_token: ContractAddress,
        quote_token: ContractAddress,
        interval_seconds: u32,
        num_intervals: u32,
        max_resolution: u8,
        end_time: u64,
    ) -> Span<CandlestickPoint>;

    // Overload for the other method that uses the current blocktimestamp at the end time and also
    // returns it
    fn get_candlestick_chart_data_now(
        self: @TContractState,
        base_token: ContractAddress,
        quote_token: ContractAddress,
        interval_seconds: u32,
        num_intervals: u32,
        max_resolution: u8
    ) -> (u64, Span<CandlestickPoint>);
}

#[starknet::contract]
mod PriceFetcher {
    use core::cmp::{max};
    use core::num::traits::{Zero};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
    use ekubo::types::keys::{PoolKey};
    use ekubo_oracle_extension::oracle::{
        IOracleDispatcher, IOracleDispatcherTrait, Oracle::{MAX_TICK_SPACING}
    };
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{get_block_timestamp};
    use super::{IPriceFetcher, PriceResult, ContractAddress, CandlestickPoint};

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

    fn get_query_interval(interval_seconds: u32, mut max_resolution: u8) -> (u32, u8) {
        loop {
            let denominator: NonZero<u32> = Into::<u8, u32>::into(max_resolution)
                .try_into()
                .expect('Max resolution must be > 0');

            let (quotient, remainder) = DivRem::div_rem(interval_seconds, denominator);

            if remainder.is_zero() {
                break (quotient, max_resolution);
            }

            max_resolution -= 1;
        }
    }

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

        fn get_prices_in_oracle_tokens(
            self: @ContractState, base_tokens: Span<ContractAddress>, period: u64, min_token: u128
        ) -> (ContractAddress, Span<PriceResult>) {
            let oracle_token = self.oracle.read().get_oracle_token();
            (oracle_token, self.get_prices(oracle_token, base_tokens, period, min_token))
        }

        fn get_candlestick_chart_data(
            self: @ContractState,
            base_token: ContractAddress,
            quote_token: ContractAddress,
            interval_seconds: u32,
            num_intervals: u32,
            max_resolution: u8,
            end_time: u64,
        ) -> Span<CandlestickPoint> {
            let oracle = self.oracle.read();
            let mut result: Array<CandlestickPoint> = array![];

            let (query_interval_seconds, resolution) = get_query_interval(
                interval_seconds, max_resolution
            );
            let query_num_intervals = num_intervals * resolution.into();

            if let Option::Some(earliest) = oracle
                .get_earliest_observation_time(base_token, quote_token) {
                if (earliest < end_time) {
                    let start_time: u64 = (end_time
                        - (query_num_intervals.into() * query_interval_seconds.into()));

                    let available_num_intervals: u64 = (end_time - max(start_time, earliest))
                        / query_interval_seconds.into();

                    if available_num_intervals > 0 {
                        let actual_start = end_time
                            - (available_num_intervals * query_interval_seconds.into());

                        let mut points = oracle
                            .get_average_price_x128_history(
                                base_token,
                                quote_token,
                                end_time,
                                available_num_intervals
                                    .try_into()
                                    .expect('Too many intervals queried'),
                                query_interval_seconds
                            );
                        let mut index: usize = 0;

                        while let Option::Some(next_point) = points.pop_front() {
                            // todo: aggregate all the points in the same interval
                            let price: u256 = *next_point;
                            result
                                .append(
                                    CandlestickPoint {
                                        time: actual_start
                                            + query_interval_seconds.into() * index.into(),
                                        min: price,
                                        max: price,
                                        open: price,
                                        close: price
                                    }
                                );
                            index += 1;
                        }
                    }
                }
            };

            result.span()
        }

        fn get_candlestick_chart_data_now(
            self: @ContractState,
            base_token: ContractAddress,
            quote_token: ContractAddress,
            interval_seconds: u32,
            num_intervals: u32,
            max_resolution: u8
        ) -> (u64, Span<CandlestickPoint>) {
            let block_timestamp = get_block_timestamp();
            (
                block_timestamp,
                self
                    .get_candlestick_chart_data(
                        base_token,
                        quote_token,
                        interval_seconds,
                        num_intervals,
                        max_resolution,
                        block_timestamp
                    )
            )
        }
    }
}
