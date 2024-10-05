use ekubo_oracle_extension::price_fetcher::{
    CandlestickPoint, IPriceFetcherDispatcher, IPriceFetcherDispatcherTrait, PriceResult
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
            PriceResult::NotInitialized(())
        ]
            .span()
    );
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
            interval_seconds: 300,
            num_intervals: 3,
            max_resolution: 8,
        );

    assert_eq!(
        data,
        (
            1728138584,
            array![
                CandlestickPoint {
                    time: 1728137400,
                    min: 820025569988684352501158936387,
                    max: 820025569988684352501158936387,
                    open: 820025569988684352501158936387,
                    close: 820025569988684352501158936387
                },
                CandlestickPoint {
                    time: 1728137700,
                    min: 819688608898146940505286773935,
                    max: 820635075085537219190804730931,
                    open: 819688608898146940505286773935,
                    close: 820635075085537219190804730931
                },
                CandlestickPoint {
                    time: 1728138000,
                    min: 819599267753628438695203216437,
                    max: 819723036525481965055071105763,
                    open: 820635075085537219190804730931,
                    close: 819599267753628438695203216437
                },
                CandlestickPoint {
                    time: 1728138300,
                    min: 819599267753628438695203216437,
                    max: 820215837896011624867022664333,
                    open: 819599267753628438695203216437,
                    close: 820215837896011624867022664333
                }
            ]
                .span()
        )
    );
}
