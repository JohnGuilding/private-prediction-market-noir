# Private Prediction Market

A prediction market built on [Aztec](https://aztec.network) that uses encrypted notes for bet privacy. Users can place bets without revealing their identity or bet direction on-chain. The contract supports multi-outcome markets (up to 8 outcomes), token-backed bets, AMM price discovery via outcome tokens, optimistic oracle resolution with bonds, and market fees.

> **Status**: Proof-of-concept / MVP. Compiles and runs end-to-end on a local Aztec network. Not audited, not production-ready.

## How It Works

### Two Ways to Take a Position

**1. Private bets (BetNotes)** — the core privacy mechanism:
- User calls `place_bet` (private function)
- An encrypted `BetNote` is created in the user's private note tree — only their PXE can read it
- Tokens move from the user's private balance to the contract's public balance
- The contract enqueues a public `update_pool` call that updates aggregate totals
- After resolution, winners call `claim_winnings` (private) which reads their encrypted notes and enqueues a public payout

**2. Outcome tokens (AMM path)** — for price discovery and trading:
- User calls `buy_complete_set` (public) to purchase one of each outcome token for PRED
- Outcome tokens can be traded on an AMM (Uniswap v2-style constant product market maker) for price discovery
- After resolution, holders of winning outcome tokens call `redeem_winning_tokens` to exchange them 1:1 for PRED
- Losing outcome tokens become worthless

### Market Lifecycle

1. **Create market** — specify question hash, betting deadline, number of outcomes (2-8), oracle bond amount, and fee rate
2. **Betting period** — users place private bets and/or buy/trade outcome tokens
3. **Propose outcome** — after the deadline, anyone proposes a result (staking a bond)
4. **Challenge period** — a window (10 blocks) where the proposed outcome can be disputed by staking a counter-bond
5. **Resolution** — if unchallenged, the proposer's outcome is finalized and their bond returned. If challenged, an admin arbitrates and the loser's bond goes to the winner
6. **Settlement** — private bettors claim proportional payouts; outcome token holders redeem winning tokens

## Privacy Model (Honest Assessment)

### What's actually private

| Data | Visibility | Notes |
|------|-----------|-------|
| Market metadata (question, deadline, outcomes) | **Public** | Necessary for market operation |
| Total pool size, number of bets | **Public** | Aggregate statistics |
| **Per-outcome pool breakdown** | **Public** | Updated with each bet — see privacy leak below |
| Proposed/finalized outcome | **Public** | Oracle resolution is public |
| **Who bet on which outcome (via BetNotes)** | **Private** | Bettor address never appears in public pool updates |
| **Individual bet amounts (via BetNotes)** | **Partially private** | Amount appears as pool delta, but not linked to identity |
| **Who claimed winnings** | **Public** | `process_claim` is a public function that reveals the claimer's address |
| AMM trades (buy/sell/swap) | **Public** | All outcome token operations reveal the caller |

### The privacy leak

Each `place_bet` enqueues a public `update_pool(market_id, amount, outcome_index)` call. This means:

- An observer watching on-chain state sees each bet's **direction and amount** as a pool delta
- They do **not** see **who** placed it — the `msg_sender` in the enqueued public call is the contract itself, not the user
- But if bets arrive one at a time, the observer can correlate timing and amounts

**What the privacy actually gives you**: *Identity privacy* — "someone bet 100 on YES" is visible, but "Alice bet 100 on YES" is not. This is weaker than "bet direction is private" but still stronger than any EVM-based prediction market where everything is fully transparent.

**What would fix it**: Batching pool updates (accumulate bets and update pools periodically), or hiding per-outcome pools entirely until resolution, or adding noise to pool updates.

## Comparison to Polymarket

### What Polymarket exposes

On Polymarket (and any EVM-based prediction market), every bet is a public transaction. Anyone can see:
- Which address bet on which outcome
- The exact amount
- When they placed it
- Their full betting history

This creates real problems: front-running, social pressure/doxxing, copy trading, and market manipulation signals.

### What this project does differently

On Aztec, bets are encrypted notes stored in a private note hash tree. The zero-knowledge proof system guarantees the bet is valid (correct amount, within deadline) without revealing the bettor's identity. This is a protocol-level property, not an application-level workaround.

### Feature comparison

| Feature | Polymarket | This Project | Gap |
|---------|-----------|-------------|-----|
| **Betting privacy** | None (fully public) | Identity hidden for private bets | Per-outcome pool amounts still leak per-bet |
| **Order book** | Central limit order book (CLOB) on Polygon | Constant product AMM (Uniswap v2-style) | No limit orders, less capital efficient |
| **Conditional tokens** | Gnosis CTF (USDC-backed) | Complete set model (PRED-backed outcome tokens) | Equivalent design |
| **Oracle** | UMA optimistic oracle with economic guarantees, escalation to DVM token vote | Propose/challenge with bonds, admin arbitration | Centralized fallback — admin is trusted arbiter |
| **Resolution escalation** | Propose → dispute → UMA DVM decentralized vote | Propose → challenge → admin decides | No decentralized dispute resolution |
| **Multi-outcome** | Binary and multi-outcome | Up to 8 outcomes | AMM currently hardcoded to 2 outcomes |
| **Market creation** | Permissioned | Open (with optional fee) | — |
| **Liquidity provision** | Professional market makers on CLOB | AMM LP tokens | — |
| **Fees** | Trading fees to market makers | Creation fee + per-market fee rate (basis points) on complete set purchases + AMM 0.3% swap fee | — |
| **Settlement** | Polygon (public) | Aztec L2 (privacy-preserving) | — |

## Known Issues and Limitations

### Bugs

- **10-note claim limit**: `claim_winnings` loops over at most 10 BetNotes. If a user places >10 bets on one market, winnings from bets 11+ are permanently lost
- **Arbitrate doesn't validate challenger exists**: If `arbitrate` is called when no challenge was filed, it could transfer double the bond to the proposer from funds that don't exist
- **Fee accounting absent**: `withdraw_fees` lets admin transfer arbitrary amounts from the contract — no separate tracking of fee balance vs bettor funds

### Architectural limitations

- **AMM hardcoded to 2 outcomes**: `setupMarketAMM` deploys only 2 outcome tokens. Multi-outcome markets (3+) would need multiple AMMs or a different market maker (e.g., LMSR)
- **Outcome token functions are public**: `buy_complete_set`, `sell_complete_set`, and `redeem_winning_tokens` are public functions that reveal the caller. The underlying Aztec AMM contract uses private entry points for identity privacy, but our wrapper doesn't
- **No partial exit for private bets**: BetNotes are all-or-nothing at claim time — no way to sell or transfer a private position before resolution
- **Integer division precision loss**: Fee calculations using basis points lose precision for small amounts (e.g., 30 bps fee on 10 tokens rounds to 0)

### Missing features (for production parity with Polymarket)

- **Decentralized oracle**: Admin-as-arbiter is a single point of trust. Needs integration with a real oracle (UMA-style DVM, token-weighted vote, or multi-sig arbitration)
- **Batch pool updates**: To fix the privacy leak, pool updates should be batched or deferred rather than one-per-bet
- **Market cancellation/refunds**: No way to cancel a market or refund bettors if something goes wrong
- **Position management**: No way to view, transfer, or partially exit private bet positions before resolution
- **Multi-outcome AMM**: Support for 3+ outcome token AMMs (requires LMSR or multiple CPMM pairs)
- **Private outcome token operations**: `buy_complete_set` and `sell_complete_set` should be private functions (like the AMM's own swap functions) to preserve identity privacy
- **Fee balance tracking**: Separate accounting for accumulated fees vs bettor/pool funds
- **Integration tests**: No automated test suite
- **Frontend**: The `frontend/` directory has scaffolding but isn't connected to the contract

## Contract API

### Public functions

| Function | Description |
|----------|-------------|
| `create_market(market_id, question_hash, betting_deadline, num_outcomes, bond_amount, fee_rate)` | Create a new market. Charges creation fee if set. |
| `initialize_market_amm(market_id, token0, token1, amm_address)` | Admin registers outcome tokens and AMM for a market |
| `buy_complete_set(market_id, amount)` | Buy one of each outcome token for PRED (fee deducted) |
| `sell_complete_set(market_id, amount)` | Burn all outcome tokens, receive PRED back |
| `redeem_winning_tokens(market_id, amount)` | Post-resolution: burn winning tokens for PRED 1:1 |
| `propose_outcome(market_id, outcome)` | Propose winning outcome (stakes bond) |
| `challenge_outcome(market_id, counter_outcome)` | Challenge proposed outcome (stakes bond) |
| `finalize_outcome(market_id)` | Finalize after challenge period (returns proposer bond) |
| `arbitrate(market_id, winning_outcome)` | Admin resolves disputed market (loser's bond to winner) |
| `set_creation_fee(fee)` | Admin sets global creation fee |
| `withdraw_fees(recipient, amount)` | Admin withdraws fees |

### Private functions

| Function | Description |
|----------|-------------|
| `place_bet(market_id, outcome_index, amount)` | Place a private bet (creates encrypted BetNote, transfers tokens) |
| `claim_winnings(market_id, expected_outcome)` | Claim proportional payout from private bet pool |

### Payout formulas

- **Private bet payout**: `payout = bet_amount * total_pool / winning_pool` (proportional share of entire pool)
- **Outcome token redemption**: 1 winning token = 1 PRED (complete set model)
- **AMM swap pricing**: constant product (x * y = k) with 0.3% fee

## Running the Project

### Prerequisites

- **Aztec toolchain** (v4.0.0-devnet.2-patch.1):
  ```bash
  VERSION=4.0.0-devnet.2-patch.1 bash -i <(curl -sL https://install.aztec.network/4.0.0-devnet.2-patch.1)
  aztec-up use 4.0.0-devnet.2-patch.1
  ```
- **Node.js** (v18+)
- **Yarn** (v1)

### Setup

```bash
yarn install
```

### Build the contract

```bash
yarn build    # Compiles Noir contract + generates TypeScript bindings
```

This runs `aztec compile` (NOT `nargo compile`) followed by `aztec codegen`.

### Start local network

```bash
yarn network
```

Wait until you see the network is accepting connections on `http://localhost:8080`. This runs Aztec's local L1 (anvil) + L2 node + PXE.

### Deploy

```bash
yarn deploy
```

Deploys a Schnorr account, Token contract, and PredictionMarket contract to the local network.

### Run the full demo

```bash
yarn demo
```

This runs the complete lifecycle:
1. Deploys two accounts (Alice and Bob) and Token + PredictionMarket contracts
2. Mints PRED tokens (private and public) to both accounts
3. Creates a binary market with 0.3% fee rate
4. Sets up AMM (deploys outcome tokens, LP token, AMM contract)
5. Alice and Bob place private bets via BetNotes (Alice: YES/100, Bob: NO/150)
6. Alice buys a complete set of outcome tokens and seeds AMM liquidity
7. Bob buys a complete set and swaps NO→YES on AMM (price discovery)
8. Reads on-chain state: pool totals visible, but bettor identities hidden
9. Proposes and finalizes outcome (YES wins)
10. Alice claims private bet winnings; Bob and Alice redeem outcome tokens

### Reset environment

```bash
yarn reset    # Kills processes, clears PXE store
```

### Other commands

```bash
yarn compile        # Just compile the Noir contract
yarn codegen        # Just regenerate TypeScript bindings
yarn clean          # Remove build artifacts
yarn clear-store    # Clear PXE store only
yarn get-block      # Print current block number
yarn read-logs      # Read debug logs from contract execution
```

## Project Structure

```
contracts/prediction_market/   Noir smart contract (aztec.nr)
  src/main.nr                  Core contract — public + private functions
  src/bet_note.nr              Encrypted note type for private bets
  src/market.nr                Market state struct (public)
scripts/                       TypeScript scripts (deploy, demo, etc.)
  env.sh                       PATH wrapper for aztec CLI
  reset-local.sh               Reset local dev environment
src/utils/                     TypeScript utilities
  token_helpers.ts             Token deploy, mint, authwit, balance helpers
  amm_helpers.ts               AMM setup, outcome token deployment, burn authwits
  setup_wallet.ts              Wallet initialization
  deploy_account.ts            Schnorr account deployment
  sponsored_fpc.ts             Fee payment contract setup
config/                        Network configuration (local, devnet)
target/                        Compiled contract output (gitignored)
src/artifacts/                 Generated TS bindings (gitignored)
frontend/                      Next.js frontend (scaffolding only)
```

## Tech Stack

- **Smart contract**: [Noir](https://noir-lang.org) via [aztec.nr](https://github.com/AztecProtocol/aztec-nr)
- **Network**: [Aztec](https://aztec.network) L2 (zk-rollup with native privacy)
- **Client SDK**: [@aztec/aztec.js](https://www.npmjs.com/package/@aztec/aztec.js)
- **AMM**: Example AMM contract from [aztec-packages](https://github.com/AztecProtocol/aztec-packages) (Uniswap v2-style CPMM, 0.3% fee, identity-private swaps)
- **Aztec version**: `4.0.0-devnet.2-patch.1`
