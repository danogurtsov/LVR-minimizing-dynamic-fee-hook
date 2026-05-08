# Results

Numbers produced by the simulation harness (`test/sim`) and the fork suite (`test/fork`). They are
a **matched static-vs-dynamic comparison** over an identical, seeded price path — the same market
run twice, once through a fixed-fee pool and once through the dynamic-fee hook. Values are in pool
token units, valued at a 1:1 price; treat them as ratios, not absolute LVR figures.

Fixed curve for every run: `baseFee 0.05% · floor 0.01% · cap 1.00% · slope 5e7`, EWMA `alpha 0.2`,
per-block tick clamp `1000`. Path: 60 blocks, seed 42.

## Offline — one volatile path (step 120)

| Metric | Static 0.05% | Dynamic | Change |
|---|---:|---:|---:|
| LP fee revenue | 0.0861 | 0.4116 | **+4.8×** |
| Avg fee retail paid | 0.050% | 0.249% | +5.0× |
| Arbitrageur net inventory | −1.334 | −1.659 | arb keeps less |

The dynamic fee widens the band exactly in the volatile blocks, so LPs earn far more fee revenue and
the arbitrageur retains less — at the cost of a higher average fee to retail. The cost is shown, not
hidden.

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
