use ekubo_oracle_extension::price_fetcher::{
    IPriceFetcherDispatcher, IPriceFetcherDispatcherTrait, PriceResult
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
            ]
                .span(),
            period: 180,
            // 1000 tokens
            min_token: 1000000000000000000000
        );

    assert_eq!(
        results,
        array![
            PriceResult::Price(815415276759135381622760457421),
            PriceResult::Price(200482767526033139806693734899861547630672),
            PriceResult::Price(339803246924809701849316128108696518322),
            PriceResult::Price(340583626611612588039879434),
            PriceResult::Price(960917390646144486190213038132),
            PriceResult::InsufficientLiquidity,
            PriceResult::NotInitialized
        ]
            .span()
    );
}
