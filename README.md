# Example extension

This repository implements an example time weighted oracle extension, including tests using [Starknet foundry fork testing](https://foundry-rs.github.io/starknet-foundry/snforge-advanced-features/fork-testing.html). A pool can be created with the oracle extension to allow for measurement of time weighted average prices and liquidity.

Demonstrates a few key facets of writing extensions:

- How creation and registration of an extension works
- How to unit test an extension using state forking
- How an extension should interact with core and validate call points
