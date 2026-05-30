# Results

Numbers produced by the simulation harness (`test/sim`) and the fork suite (`test/fork`). They are
a **matched static-vs-dynamic comparison** over an identical, seeded price path — the same market
run twice, once through a fixed-fee pool and once through the dynamic-fee hook. Values are in pool
token units, valued at a 1:1 price; treat them as ratios, not absolute LVR figures.

Fixed curve for every run: `baseFee 0.05% · floor 0.01% · cap 1.00% · slope 5e7`, EWMA `alpha 0.2`,
per-block tick clamp `1000`. Path: 60 blocks, seed 42.

## Reality check — annualization (`test_annualizedLVR`)

The bps figures below are per-run (60 blocks) at a **deliberately high** synthetic volatility, chosen so
the mechanics are visible. Annualized with a 12s block clock, that regime implies an absurd LVR
(~16,000 %/yr) — so **treat the absolute magnitudes as illustrative, not real.** Re-run at a realistic
volatility (≈ ETH 5%/day) the annualized LVR is **~19 %/yr**, the same order as the literature's ~11 %/yr
— a check that the harness is grounded. All the comparisons in this doc are **matched** (same path both
sides), so their *direction and ranking* are robust even though their absolute size is not calibrated.

## LP net welfare — the metric that matters (`test_lpNetWelfare`)

Fee revenue is a proxy; the quantity that decides whether an LP should provide liquidity is **LP net
vs a rebalancing benchmark = fees − LVR**, computed per-trade as −Σ (each counterparty's inventory
gain valued at the *trade-time* external price) — the canonical Milionis et al. measure. Reported as
**basis points of LP capital** (high-volatility regime, 60 blocks):

| | LVR extracted | **LP net vs rebalancing** | Residual mispricing |
|---|---:|---:|---:|
| static 0.05% | 36.5 bps | **−36.2 bps** | 4 ticks |
| dynamic | 23.1 bps | **−21.7 bps** | 38 ticks |

The arbitrageur here is **rational** — it trades only to the no-arbitrage band (stops when mispricing
= fee). Both fees leave the LP **net-negative**: LVR dwarfs fee income, the well-documented "most
passive LPs lose to arbitrageurs" result, and the fee *mitigates* it (−36 → −22 bps) but does not erase
it. The dynamic fee reduces the LVR the arb keeps — **but at a cost**: a wider fee makes the arb stop
earlier, leaving the pool ~38 ticks (~0.38%) **mispriced**, so retail inherits staler prices. Less LVR,
more staleness.

> **Remaining caveats.** (1) LVR is normalized to total (wide-range) capital, so it is a **floor** — a
> concentrated LP faces more. (2) Parameters (elasticity, depth, curve) are uncalibrated. (3) Prices
> are synthetic and single-seed (no jumps, no confidence intervals). (4) No annualization. Direction is
> robust; exact bps are not.

## The honest baseline — dynamic vs the BEST static fee (`test_bestStaticBaseline*`)

The comparison above is against a naive 0.05% fee. The fair question is whether adaptivity beats the
*best fixed* fee. Sweeping the static fee to find the best, then comparing the dynamic fee (LP net, bps):

| Path | Best static fee | Best static LP net | Dynamic LP net |
|---|---:|---:|---:|
| constant high vol | 1.0% | −14.0 bps | −21.7 bps |
| time-varying (calm↔burst) | 1.0% | −12.5 bps | −18.4 bps |

**The dynamic fee does not beat the best static fee** — not at constant volatility (nothing to adapt
to) and not on a time-varying path. With a rational arb every fee is LP-negative; the best static fee
simply loses least, and the dynamic fee loses more. On the varying path the realized-vol EWMA is
*anti-phase* with the regime: the estimate is still low entering a burst (fee too low exactly when LVR
is realized) and still high entering a calm (fee too high for retail). A faster EWMA makes it worse,
not better — lag is structural to a backward-looking signal, not a tuning knob.

The premise (a16z: optimal fee rises with volatility) holds; the instrument is wrong. The design's real
value is **composability** and this measurement framework, and the open problem is a **forward-looking**
volatility signal.

**Robust across seeds (Monte Carlo, `test_monteCarlo_varyingVol`).** Over 5 seeds the dynamic fee loses
to the best static fee every time — gap (dynamic − best-static) mean **−6.1 bps**, range [−8.0, −4.3],
**0 / 5** seeds where dynamic wins. So the negative result is not a single-path fluke. *Caveat:
uncalibrated params; synthetic regime-switching prices (Monte Carlo covers seed-variance, not real
historical/jump prices) — direction robust, magnitudes not final.*

### Why: the fee is one block late (`test_lagIsExploitable`)

The single clearest number in the study. After a calm stretch the estimate is low, so the fee is at
base; a large informed move then pays that pre-jump fee, and the deterrent fee only appears on the next
block — after the value has left:

| | Fee (pips) |
|---|---:|
| charged **on** the jump | 526 (0.05%) |
| the block **after** the jump | 10,000 (1.0%) |

A **19× undercharge on the exact block that matters** — and no manipulation is required, just timing.
This lag is the mechanism behind every result above: a backward-looking estimator cannot price a move
it has not seen yet.

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
