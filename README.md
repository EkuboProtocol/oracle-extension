# Oracle extension

This repository implements a time weighted Oracle extension.

The Oracle extension enables developers to create an Oracle pool. Only one Oracle pool may exist per pair--it must have a `0` fee and `MAX_TICK_SPACING` tick spacing. These are the lowest cost trading parameters that make the oracle maximally precise.

The oracle pool collects snapshots of a cumulative tick accumulator, i.e. SUM(seconds passed \* tick) for all time. Developers can then query this via the various methods to get the raw accumulator value at any time, the average tick over any historical time period, or even the geomean average price as a `128.128` fixed point number.
