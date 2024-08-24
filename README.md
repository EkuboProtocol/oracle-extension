# Oracle extension

This repository implements a permissionless and manipulation resistant price Oracle for any pair that can be traded on Ekubo via [Ekubo Extensions](https://docs.ekubo.org/integration-guides/extensions).

The extension enables developers to create one Oracle pool per pair. This pool must have the parameters `fee = 0` and `tick_spacing = MAX_TICK_SPACING`. In addition, only full range positions may be created on this pool. These are the lowest cost parameters that make the oracle both maximally precise and maximally expensive to manipulate. This also prevents fragmentation of liquidity used for the Oracle. As with any extension, the pool key must also refer to the address of the deployed extension contract.

## How it works

The Oracle extension contract collects snapshots of a cumulative tick accumulator, i.e. `SUM(tick * seconds passed at tick)` for all time from pool initialization. The accumulator value starts at `0` for newly initialized pools. For the first swap of each block on the pool, the accumulator reads the current tick of the pool at the beginning of the block and adds `current tick * seconds elapsed since last update` to the accumulator.

The Oracle exposes a method that allows anyone to query the value of the accumulator at any second starting with the Oracle pool creation via the method `get_tick_cumulative_at`. For convenience, the Oracle contract also has methods that give the time weighted average tick over any period, or the time weighted geomean price as a `128.128` fixed point number for any period.

## Usage

To use this oracle, you must first create the Oracle pool for the pair which has the price you'd like to measure.

Then, you should add sufficient liquidity to the pool. It is important that the pool has enough liquidity to provide manipulation resistance sufficient to protect the value at stake. This is based on 2 factors: the amount of recency you need (e.g. TWAP over last 5 minutes) and the amount of value at stake (e.g. $10m lending market cap). You should keep this liquidity in the pool for as long as you need to use the Oracle, and adjust it according to how much value you need to protect.

Note that while the pools are shared, you cannot rely on others to keep their liquidity in the pool, or increase the liquidity when you need more manipulation resistance. In addition, other protocols may use your liquidity without depositing their own, and all protocols share the same level of manipulation resistance. In some cases, protocols may deposit into the pool and lock the liquidity to provide an Oracle for their token as a public good.

This can all be done from the Ekubo interface. [Join the Discord](https://discord.ekubo.org) if you need help in setting up an Oracle pool for your use case.
