use ekubo_oracle_extension::price_fetcher::{
    CandlestickPoint, IPriceFetcherDispatcher, IPriceFetcherDispatcherTrait, PriceResult,
    PriceFetcher::{get_query_interval}
};
use snforge_std::{ContractClassTrait, DeclareResultTrait, declare};
use starknet::{contract_address_const};

fn deploy_price_fetcher() -> IPriceFetcherDispatcher {
    let (contract_address, _) = declare("PriceFetcher")
        .unwrap()
        .contract_class()
        .deploy(
            @array![
                // oracle
                0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b,
                // core
                0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f
            ]
        )
        .expect('Deploy fetcher failed');

    IPriceFetcherDispatcher { contract_address }
}


#[test]
#[fork("mainnet_live_oracle")]
fn test_get_usdc_prices_for_common_tokens() {
    let fetcher = deploy_price_fetcher();

    let results = fetcher
        .get_prices(
            // USDC
            quote_token: contract_address_const::<
                0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
            >(),
            base_tokens: array![
                // ETH
                contract_address_const::<
                    0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                >(),
                // WBTC
                contract_address_const::<
                    0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac
                >(),
                // USDT
                contract_address_const::<
                    0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
                >(),
                // DAI
                contract_address_const::<
                    0x05574eb6b8789a91466f902c380d978e472db68170ff82a5b650b95a58ddf4ad
                >(),
                // wstETH
                contract_address_const::<
                    0x042b8f0484674ca266ac5d08e4ac6a3fe65bd3129795def2dca5c34ecc5f96d2
                >(),
                // LORDS
                contract_address_const::<
                    0x0124aeb495b947201f5fac96fd1138e326ad86195b98df6dec9009158a533b49
                >(),
                // UNI
                contract_address_const::<
                    0x049210ffc442172463f3177147c1aeaa36c51d152c1b0630f2364c300d4f48ee
                >(),
                // PAPER
                contract_address_const::<
                    0x0410466536b5ae074f7fea81e5533b8134a9fa08b3dd077dd9db08f64997d113
                >(),
                // USDC
                contract_address_const::<
                    0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                >(),
                // EKUBO
                contract_address_const::<
                    0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87
                >(),
            ]
                .span(),
            period: 180,
            // 1000 tokens
            min_token: 1000000000000000000000
        );

    assert_eq!(
        results,
        array![
            PriceResult::Price(820147762840657655831089373900), // 2,410.1976551468
            PriceResult::Price(210417630260930196314357434054318828199387), // 61,836.1839212841
            PriceResult::Price(340602382569627424951526649747978013144), // 1.000940441468022
            PriceResult::Price(340163265669238322215064375), // 0.999649992878627
            PriceResult::Price(967957750124759482814198120731), // 2,844.5721677658
            PriceResult::InsufficientLiquidity(()),
            PriceResult::InsufficientLiquidity(()),
            PriceResult::NotInitialized(()),
            PriceResult::Price(u256 { high: 1, low: 0 }),
            PriceResult::Price(785271311015162638041721084), // 2.3077049749
        ]
            .span()
    );
}

#[test]
#[fork("mainnet_live_oracle")]
fn test_get_prices_in_oracle_tokens() {
    let fetcher = deploy_price_fetcher();

    let results = fetcher
        .get_prices_in_oracle_tokens(
            base_tokens: array![
                // ETH
                contract_address_const::<
                    0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                >(),
                // WBTC
                contract_address_const::<
                    0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac
                >(),
                // USDT
                contract_address_const::<
                    0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
                >(),
                // DAI
                contract_address_const::<
                    0x05574eb6b8789a91466f902c380d978e472db68170ff82a5b650b95a58ddf4ad
                >(),
                // wstETH
                contract_address_const::<
                    0x042b8f0484674ca266ac5d08e4ac6a3fe65bd3129795def2dca5c34ecc5f96d2
                >(),
                // LORDS
                contract_address_const::<
                    0x0124aeb495b947201f5fac96fd1138e326ad86195b98df6dec9009158a533b49
                >(),
                // UNI
                contract_address_const::<
                    0x049210ffc442172463f3177147c1aeaa36c51d152c1b0630f2364c300d4f48ee
                >(),
                // PAPER
                contract_address_const::<
                    0x0410466536b5ae074f7fea81e5533b8134a9fa08b3dd077dd9db08f64997d113
                >(),
                // USDC
                contract_address_const::<
                    0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                >(),
                // EKUBO
                contract_address_const::<
                    0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87
                >(),
            ]
                .span(),
            period: 180,
            // 1000 tokens
            min_token: 1000000000000000000000
        );

    assert_eq!(
        results,
        (
            contract_address_const::<
                0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87
            >(),
            array![
                PriceResult::Price(
                    355395413087926698286416877619833981826258
                ), // 1044.413250982527739
                PriceResult::Price(
                    91180472612097855129854929619507045633068680889345393
                ), // 26795.532615206833488
                PriceResult::Price(
                    147593555620760360485730100015613216838443180609755
                ), // 0.433738477124947
                PriceResult::Price(147403272675078540394540354320183477288), // 0.4331792858
                PriceResult::Price(
                    419446055995746884435998184558650369079219
                ), // 1232.641173244223347
                PriceResult::InsufficientLiquidity(()),
                PriceResult::InsufficientLiquidity(()),
                PriceResult::NotInitialized(()),
                PriceResult::Price(
                    147454882934186793952740691994182378842699197124933
                ), // 0.433330954725746
                PriceResult::Price(u256 { high: 1, low: 0 })
            ]
                .span()
        )
    );
}

#[test]
fn test_get_query_interval() {
    assert_eq!(get_query_interval(300, 8), (50, 6));
    assert_eq!(get_query_interval(300, 10), (30, 10));
    assert_eq!(get_query_interval(263, 30), (263, 1));
}

#[test]
#[fork("mainnet_live_oracle")]
fn test_get_candlestick_chart_eth_usdc() {
    let fetcher = deploy_price_fetcher();

    let data = fetcher
        .get_candlestick_chart_data_now(
            // ETH
            base_token: contract_address_const::<
                0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
            >(),
            // USDC
            quote_token: contract_address_const::<
                0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
            >(),
            interval_seconds: 3600,
            num_intervals: 3,
            max_resolution: 10,
        );

    assert_eq!(
        data,
        (
            1728138584,
            array![
                CandlestickPoint {
                    time: 1728127784,
                    low: 823443156570528826146437523704,
                    high: 824403850786627945301703919980,
                    open: 823443156570528826146437523704,
                    close: 823949729613777479902644609622
                },
                CandlestickPoint {
                    time: 1728131384,
                    low: 823602919959569493485072420146,
                    high: 824638014612858886488344812926,
                    open: 823949729613777479902644609622,
                    close: 824638014612858886488344812926
                },
                CandlestickPoint {
                    time: 1728134984,
                    low: 819919793565769978220410180411,
                    high: 823481035808007237524429035770,
                    open: 824638014612858886488344812926,
                    close: 819919793565769978220410180411
                }
            ]
                .span()
        )
    );
}
