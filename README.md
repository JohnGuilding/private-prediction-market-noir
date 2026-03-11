# Private Prediction Market

A prediction market built on [Aztec](https://aztec.network) where betting activity is private. Bets are stored as encrypted notes — only the bettor can read them. The on-chain state exposes the total pool size but never reveals who bet on which outcome or how much any individual wagered.

The contract supports multi-outcome markets (up to 8 outcomes), an AMM for price discovery via outcome tokens, optimistic oracle resolution with bonded stakes, and configurable fees.

> **Status**: Proof-of-concept. Compiles and runs end-to-end on a local Aztec network. Not audited, not production-ready.

## Project Structure

```
contracts/prediction_market/       Noir smart contract (aztec.nr)
  src/main.nr                      Contract entry point — public, private, and utility functions
  src/bet_note.nr                  BetNote — encrypted note type for private bets
  src/market.nr                    Market struct — public market state and lifecycle methods
scripts/                           TypeScript deployment and demo scripts
src/artifacts/                     Generated TypeScript bindings (do not edit)
src/utils/                         TypeScript helpers
  token_helpers.ts                 Token deployment, minting, authwits, balance queries
  amm_helpers.ts                   AMM and outcome token deployment, authwit helpers
config/                            Network configuration
frontend/                          Next.js frontend (scaffolding only, not connected)
```

### Prerequisites

- **Aztec toolchain** v4.0.0-devnet.2-patch.1:
  ```bash
  VERSION=4.0.0-devnet.2-patch.1 bash -i <(curl -sL https://install.aztec.network/4.0.0-devnet.2-patch.1)
  aztec-up use 4.0.0-devnet.2-patch.1
  ```
- **Node.js** v18+
- **Yarn** v1

### Setup and Build

```bash
yarn install                # Install dependencies
yarn build                  # Compile Noir contract + generate TypeScript bindings
```

`yarn build` runs `aztec compile` (not `nargo compile` — the Aztec wrapper handles AVM transpilation and verification key generation) followed by `aztec codegen`.

### Running Locally

```bash
yarn network                # Start local Aztec network (L1 anvil + L2 node + PXE)
yarn deploy                 # Deploy Token + PredictionMarket contracts
yarn demo                   # Run full end-to-end demo
```

### Other Commands

```bash
yarn reset                  # Kill processes, clear PXE store
yarn clean                  # Remove build artifacts
yarn clear-store            # Clear PXE store only
yarn test                   # Run JS integration tests + Noir tests
yarn test:nr                # Run Noir contract tests only
yarn get-block              # Print current block number
yarn read-logs              # Read contract debug logs
```

## How It Works

### Tech Stack

- **Smart contract language**: [Noir](https://noir-lang.org) via [aztec.nr](https://github.com/AztecProtocol/aztec-nr)
- **Network**: [Aztec](https://aztec.network) — a zk-rollup L2 with native private state (encrypted UTXO notes, private function execution in client-side PXE)
- **Client SDK**: [@aztec/aztec.js](https://www.npmjs.com/package/@aztec/aztec.js) v4.0.0-devnet.2-patch.1
- **AMM**: Aztec's example AMM contract (Uniswap v2-style constant product, 0.3% swap fee)
- **Token standard**: Aztec Token contract (supports both public balances and private note-based balances)

### Two Ways to Take a Position

**1. Private bets (BetNotes)**

The core privacy mechanism. The user calls `place_bet` (a private function) which:
- Creates an encrypted `BetNote` in the user's private note tree — only their PXE can decrypt it
- Transfers tokens from the user's private balance to the contract's public balance
- Enqueues a public `update_pool` call that increments the aggregate `total_pool` — no outcome index or bettor identity is passed

After resolution, winners call `reveal_bets` during a reveal phase to disclose their winning amounts, then `claim_winnings` to receive a proportional payout.

**2. Outcome tokens (AMM path)**

For public price discovery and trading:
- `buy_complete_set` — pay PRED tokens, receive one of each outcome token (fee deducted)
- Trade outcome tokens on the AMM for price discovery
- `sell_complete_set` — burn a complete set of outcome tokens, receive PRED back
- `redeem_winning_tokens` — after resolution, burn winning outcome tokens 1:1 for PRED

### Market Lifecycle

1. **Create market** — specify question hash, betting deadline (block number), number of outcomes (2–8), oracle bond amount, and fee rate (basis points)
2. **Betting period** — users place private bets and/or buy/trade outcome tokens via the AMM
3. **Propose outcome** — after the betting deadline, anyone can propose a result by staking a bond
4. **Challenge period** (10 blocks) — anyone can dispute the proposal by staking a counter-bond with a different outcome
5. **Resolution** — if unchallenged, `finalize_outcome` locks the result and returns the proposer's bond. If challenged, the admin calls `arbitrate` — the winning side gets both bonds
6. **Reveal phase** (5 blocks after finalization) — private bettors who won call `reveal_bets` to disclose their winning bet amounts, building the `revealed_winning_pool`
7. **Settlement** — after the reveal deadline: private bettors call `claim_winnings` for a proportional payout (`bet_amount * total_pool / revealed_winning_pool`); outcome token holders call `redeem_winning_tokens` for 1:1 PRED redemption

## Comparison to Polymarket

### What Polymarket exposes

On Polymarket (and any EVM-based prediction market), every bet is a public transaction. Anyone can see which address bet on which outcome, the exact amount, when they placed it, and their full betting history. This enables front-running, copy trading, social pressure/doxxing, and market manipulation signalling.

### What this project does differently

Bets are encrypted notes in Aztec's private note hash tree. The zero-knowledge proof system guarantees the bet is valid (correct amount, within deadline) without revealing the bettor's identity or chosen outcome. This is a protocol-level property, not an application-level workaround.

### Feature comparison

| Feature | Polymarket | This Project |
|---------|-----------|-------------|
| **Bet privacy** | None — fully public | Identity and outcome hidden for private bets |
| **Order book** | Central limit order book (CLOB) on Polygon | Constant product AMM (no limit orders, less capital efficient) |
| **Conditional tokens** | Gnosis CTF (USDC-backed) | Complete set model (PRED-backed outcome tokens) |
| **Oracle** | UMA optimistic oracle with escalation to decentralized token vote | Propose/challenge with bonds, admin arbitration as fallback |
| **Multi-outcome** | Binary and multi-outcome | Up to 8 outcomes in the contract; AMM setup currently handles 2 |
| **Market creation** | Permissioned | Open (with optional creation fee) |
| **Liquidity** | Professional market makers on CLOB | AMM LP tokens |
| **Fees** | Trading fees to market makers | Creation fee + per-market fee rate on complete set purchases + AMM swap fee |
| **Settlement** | Polygon (public) | Aztec L2 (private) |

### Missing features for production parity

- **Decentralized oracle** — admin-as-arbiter is a single point of trust. Needs UMA-style DVM, token-weighted voting, or multi-sig arbitration
- **Batch pool updates** — pool updates currently happen one-per-bet; batching would strengthen timing-correlation resistance
- **Market cancellation/refunds** — no way to cancel a market or refund bettors
- **Position management** — no way to view, transfer, or partially exit private positions before resolution
- **Multi-outcome AMM** — the TypeScript setup deploys 2 outcome tokens; 3+ outcomes would need LMSR or multiple CPMM pairs
- **Private outcome token operations** — `buy_complete_set` and `sell_complete_set` are public functions that reveal the caller
- **Fee balance tracking** — no separate accounting of accumulated fees vs pool funds
- **Frontend** — the `frontend/` directory has scaffolding but isn't connected

## Privacy

### What is private

| Data | Visibility | Notes |
|------|-----------|-------|
| Who bet on which outcome | **Private** | BetNote is encrypted; bettor address never appears in public pool updates |
| Individual bet amounts | **Private** | Amount is added to `total_pool` aggregate but not linked to identity or outcome |
| Bet outcome choice | **Private** | `update_pool` receives only `(market_id, amount)` — no outcome index |

### What is public

| Data | Visibility | Notes |
|------|-----------|-------|
| Market metadata | Public | Question hash, deadline, number of outcomes, fee rate, bond amount |
| Total pool size | Public | Aggregate `total_pool` updated with each bet |
| Number of bets | Public | `num_bets` counter incremented per bet |
| Oracle resolution | Public | Proposed outcome, proposer/challenger addresses, finalized result |
| Who claimed winnings | Public | `process_claim` is a public function — reveals claimer address, bet amount, and outcome |
| Who revealed bets | Public | `accumulate_winning_pool` records revealer address and amount |
| AMM trades | Public | `buy_complete_set`, `sell_complete_set`, and AMM swaps reveal the caller |

### Timing correlation

Although bet amounts and outcomes are private, each `place_bet` triggers a public `update_pool` transaction. An observer watching the mempool can see the timing and amount of each pool update. If bets arrive one at a time, the observer can correlate a pool delta with network-level metadata (IP, timing) even though they cannot see the bettor's address or outcome on-chain.

## Known Design Faults

- **10-note claim limit**: `claim_winnings` and `reveal_bets` loop over at most 10 BetNotes. If a user places more than 10 bets on a single market, winnings from bets beyond the 10th are silently lost
- **Arbitrate doesn't validate challenger exists**: calling `arbitrate` when no challenge was filed could transfer double the bond to the proposer from funds that don't belong to them
- **Fee accounting is absent**: `withdraw_fees` lets the admin transfer any amount from the contract — there is no separate tracking of fee balance vs bettor/pool funds, so the admin could withdraw user funds
- **Integer division precision loss**: fee calculations use basis points with integer division — small amounts lose precision (e.g., 30 bps fee on 10 tokens rounds to 0)
- **Reveal phase is honour-based**: nothing forces winners to reveal. If winners don't reveal, `revealed_winning_pool` stays at 0 and no one can claim. There is no fallback mechanism
- **No market cancellation**: once created, a market cannot be cancelled or refunded — if no one proposes an outcome, funds are locked forever
- **AMM hardcoded to 2 outcomes**: the TypeScript `setupMarketAMM` deploys exactly 2 outcome tokens; the contract supports up to 8 outcomes but the AMM setup doesn't
- **Public claim leaks private bet details**: `process_claim` is a public function that receives the claimer's address, bet amount, and expected outcome — fully deanonymising the bet at claim time
