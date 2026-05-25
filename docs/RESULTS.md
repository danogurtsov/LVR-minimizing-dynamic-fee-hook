# Results

Numbers produced by the simulation harness (`test/sim`) and the fork suite (`test/fork`). They are
a **matched static-vs-dynamic comparison** over an identical, seeded price path — the same market
run twice, once through a fixed-fee pool and once through the dynamic-fee hook. Values are in pool
token units, valued at a 1:1 price; treat them as ratios, not absolute LVR figures.

Fixed curve for every run: `baseFee 0.05% · floor 0.01% · cap 1.00% · slope 5e7`, EWMA `alpha 0.2`,
per-block tick clamp `1000`. Path: 60 blocks, seed 42.

## LP net welfare — the metric that matters (`test_lpNetWelfare`)

Fee revenue is a proxy; the quantity that decides whether an LP should provide liquidity is **LP net
vs a rebalancing benchmark = fees − LVR**, computed per-trade as −Σ (each counterparty's inventory
gain valued at the *trade-time* external price) — the canonical Milionis et al. measure. Reported as
**basis points of LP capital** (high-volatility regime, 60 blocks):

| | LVR extracted | **LP net vs rebalancing** |
|---|---:|---:|
| static 0.05% | 36.3 bps | **−36.0 bps** |
| dynamic | 0.2 bps | +0.9 bps |

Under a static fee the LP is **net-negative** — LVR (36 bps) dwarfs fee income. This reproduces the
well-documented result that most passive LPs lose to arbitrageurs; fee revenue never showed it, LP net
does. The dynamic fee neutralizes it.

> **Three honest caveats (work in progress).**
> 1. **The arbitrageur is fee-inelastic** — it realigns the price fully each block regardless of the
>    fee, so a wide fee just extracts a large fee on full volume. The dynamic figure is therefore an
>    **upper bound**; a rational arb (trading only to the no-arbitrage band) would extract less and
>    leave the pool mispriced. The **sign** is robust; the **magnitude** is not yet final.
> 2. **LVR is normalized to total (wide-range) capital**, so it is a **floor** — a concentrated LP
>    faces materially more (concentrated liquidity amplifies LVR).
> 3. **No annualization** — bps are per-60-block window at synthetic volatility, fine for a matched
>    comparison, not an absolute rate.

## Offline — fee-aggressiveness sweep (`test_feeAggressivenessSweep`)

Volatility fixed; the fee curve's `slope` is cranked. Retail is fee-elastic (demand falls linearly
to zero at 1.05%). LP fee revenue is split into the part paid by arbitrageurs and the part paid by
retail. Values are token units at P=1.

| Avg fee | Arb fees (LVR recapture) | Retail fees | Retail volume |
|---:|---:|---:|---:|
| 0.05% | 0.100 | 0.0138 | 27.5 |
| 0.21% | 0.399 | 0.0467 | 23.3 |
| 0.36% | 0.700 | **0.0648** ← peak | 19.0 |
| 0.67% | 1.303 | 0.0568 | 10.6 |
| 0.93% | 1.822 | 0.0237 | 3.4 |
| 0.98% | 1.943 | 0.0170 | 2.0 |

Arbitrage recapture rises monotonically with the fee, but retail fee revenue is a **Laffer curve** —
it peaks near ~0.35% and then falls as the fee drives volume away (retail volume collapses ~93% across
the sweep). The optimum fee balances the two; the maximum fee is *not* optimal. This is asserted, not
just plotted: the test requires the arb series to be monotone and the retail series to peak in the
interior.

## Offline — volatility sweep (`test_scenarioSweep`)

The external path's per-block volatility (in ticks) is swept; everything else is fixed. Each row is a
matched static-vs-dynamic run over the same seeded path.

| Volatility (ticks/block) | LP fees static | LP fees dynamic | LP lift | Retail fee static | Retail fee dynamic |
|---:|---:|---:|---:|---:|---:|
| 20 (stable)  | 0.01488 | 0.01672 | 1.12× | 0.050% | 0.057% |
| 60 (low)     | 0.04086 | 0.08090 | 1.98× | 0.050% | 0.100% |
| 120 (mid)    | 0.08613 | 0.41160 | 4.78× | 0.050% | 0.249% |
| 200 (high)   | 0.15257 | 1.99857 | 13.10× | 0.050% | 0.673% |
| 300 (extreme)| 0.21517 | 4.05883 | 18.86× | 0.050% | 0.970% |

The dynamic fee widens the band exactly in the volatile blocks, so LPs earn far more fee revenue (and
the arbitrageur retains less) — at the cost of a higher average fee to retail. Both sides scale
monotonically with volatility: the recapture grows, and so does the retail cost. The cost is shown,
not hidden.

## Fork — seeded by live mainnet pools

Each pool's live tick is read from mainnet (proving real access); the run then uses that pool's
volatility regime. Requires `ETH_RPC_URL`; skips cleanly without it.

| Pool | Live tick | Regime (step) | LP fees static | LP fees dynamic | Change | Avg retail fee (dyn) |
|---|---:|---:|---:|---:|---:|---:|
| WBTC/ETH 0.30% | 265,598 | volatile (200) | 0.1526 | 1.9986 | **+13.1×** | 0.673% |
| ETH/USDC 0.05% | 200,965 | mid (120) | 0.0861 | 0.4116 | +4.8× | 0.249% |
| USDC/USDT 0.01% | 7 | stable (20) | 0.01488 | 0.01672 | **+1.1×** | 0.057% |

## Reading

- **Where it helps most:** volatile, arbitrage-heavy pools (WBTC/ETH). The fee tracks the σ² shape of
  LVR, so the more volatile the pool, the more value the fee keeps in it.
- **Where it is near-neutral:** stable pools (USDC/USDT). Low realized volatility keeps the fee at the
  floor, so retail pays essentially the base fee (0.057% ≈ 0.05%) and LP revenue barely moves — the
  hook does no harm where there is little LVR to recapture.
- **The tradeoff is real:** in volatile regimes the average fee retail pays rises. Whether the extra
  LP revenue is worth it is a per-pool decision; the harness is here to make that decision measurable.
