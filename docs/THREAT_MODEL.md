# Threat model

What this hook does and does not protect, and where its assumptions live. The hook holds **no user
funds** — it only reads pool state and sets a fee — which keeps the surface small.

## Trust assumptions

- **Owner.** A single `Ownable2Step` owner can retune the fee curve and volatility config and can
  pause. A malicious owner cannot steal funds, but can widen the fee to `maxFee` (bounded at 1%) or
  pin it to the floor. Point the owner at a timelock/multisig for production.
- **PoolManager.** Every callback is `onlyPoolManager` (via the OpenZeppelin `BaseHook`). No
  externally reachable callback mutates state — this is exactly the gap behind the $11M Cork Protocol
  hook exploit (a `beforeSwap` missing `onlyPoolManager`), and it is closed here by construction.

## Guarantees (checked by tests)

- **Bounded fee.** `minFee ≤ fee ≤ maxFee` for any pool state — fuzzed in `FeeCurve` and held as an
  invariant across 128k random swaps/rolls (`test/invariant`).
- **No swap griefing.** The hook never reverts a swap that a vanilla pool would accept; on pause it
  falls back to a fixed floor fee rather than reverting.
- **Dynamic-fee pools only.** `afterInitialize` reverts a pool created without `DYNAMIC_FEE_FLAG`, so
  the hook can never be attached where its fee override would silently do nothing.

## Residual risks / non-goals

- **The volatility estimate is derived from a manipulable price.** A single swap cannot move it (the
  per-block tick delta is clamped, truncated-oracle style, and the EWMA smooths), but an attacker
  willing to sustain a manipulated price across many blocks can bias the fee — always within
  `[minFee, maxFee]`. Do **not** reuse this estimate as an external price oracle.
- **Compensation, not elimination.** The fee returns value to LPs as fee revenue; it does not remove
  the stale-price arbitrage the way a batch auction or FM-AMM does. Inter-block CEX–DEX LVR — the
  largest slice — is not addressable by a per-swap fee and is out of scope.
- **Parameter risk.** A badly tuned curve (slope too high) over-taxes retail; too low and it barely
  helps. The simulation harness exists to size this per pool before deployment.

## Status

Experimental, unaudited. See [`SECURITY.md`](../SECURITY.md).
