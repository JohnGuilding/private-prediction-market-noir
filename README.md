# Private Prediction Market

A prediction market built on [Aztec](https://aztec.network) where **betting activity is permanently private**. Bets (direction + amount) are stored as encrypted notes — only the bettor can read them. The on-chain state shows total pool size but never reveals who bet which direction.

## How It Works

### Flow

1. **Create market** — anyone creates a market with a question hash and betting deadline (public)
2. **Place bets** — users bet YES or NO with an amount (private). An encrypted `BetNote` is created that only the bettor's PXE can decrypt. Only the aggregate amount goes to the public side — the direction is never revealed
3. **Propose outcome** — after the deadline, an oracle proposes the result (public)
4. **Challenge period** — a window where the proposed outcome can be disputed (10 blocks in demo)
5. **Finalize** — after the challenge period, the outcome is locked (public)
6. **Claim winnings** — winners prove their private bet note matches the outcome and receive a payout, without revealing their bet to anyone else (private)

### What's Public vs Private

| Data | Visibility |
|------|-----------|
| Market exists, question hash, deadline | Public |
| Total pool size | Public |
| Number of bets | Public |
| Proposed/finalized outcome | Public |
| **Who bet what direction** | **Private** |
| **Individual bet amounts** | **Private** |
| **Who claimed winnings** | **Private** (claim is processed via private function) |

The key privacy pattern: `place_bet` is a **private function** that creates an encrypted note and then enqueues a public call to `update_pool` — but only passes the amount, never the direction.

## How This Differs from Polymarket

### What Polymarket exposes

On Polymarket (and any EVM-based prediction market), every bet is a public transaction. Anyone can see:
- Which address bet on which outcome
- The exact amount
- When they placed it
- Their full betting history

This creates real problems:
- **Front-running**: MEV bots see large bets in the mempool and trade ahead
- **Social pressure / doxxing**: public bets linked to identities via ENS or exchange deposits
- **Copy trading**: sophisticated traders' strategies are copied in real-time
- **Market manipulation signals**: large visible bets can be used to mislead

### What this project does differently

On Aztec, bets are encrypted notes stored in a private note hash tree. The zero-knowledge proof system guarantees the bet is valid (correct amount, within deadline) without revealing direction. This is not an application-level hack — it's a structural property of the protocol.

### What's missing compared to Polymarket

This is an MVP / proof-of-concept. A production prediction market would also need:

- **Token integration** — real token transfers (ERC20 bridged to Aztec) instead of abstract "units"
- **Proportional payouts** — currently uses a simple 2x payout; production would calculate proportional shares of the losing pool
- **Order book / AMM** — continuous price discovery instead of fixed-odds betting
- **Multiple outcomes** — support for more than binary YES/NO markets
- **Decentralized oracle** — currently any account can propose outcomes; needs Chainlink, UMA, or a proper oracle network
- **Challenge mechanism** — the challenge period exists in the contract but there's no dispute/slash logic yet
- **Market creation fees / liquidity incentives**
- **Frontend** — the `frontend/` directory has scaffolding but isn't connected to the contract yet
- **Withdrawal mechanism** — winners' claims are tracked but actual token transfers aren't implemented

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

Deploys a Schnorr account and the PredictionMarket contract to the local network.

### Run the full demo

```bash
yarn demo
```

This runs the complete lifecycle (~2 minutes):
1. Deploys two accounts (Alice and Bob)
2. Deploys the PredictionMarket contract
3. Creates a market
4. Alice bets YES (100 units) — private
5. Bob bets NO (150 units) — private
6. Reads on-chain state: total_pool=250, num_bets=2, but no bet directions visible
7. Proposes and finalizes outcome (YES wins)
8. Alice claims winnings

### Reset environment

```bash
yarn reset    # Kills processes, clears PXE store
```

Run this if the network gets into a bad state or before restarting.

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
src/utils/                     Wallet setup, account deployment, FPC
config/                        Network configuration (local, devnet)
target/                        Compiled contract output (gitignored)
src/artifacts/                 Generated TS bindings (gitignored)
```

## Tech Stack

- **Smart contract**: [Noir](https://noir-lang.org) via [aztec.nr](https://github.com/AztecProtocol/aztec-nr)
- **Network**: [Aztec](https://aztec.network) L2 (zk-rollup with native privacy)
- **Client SDK**: [@aztec/aztec.js](https://www.npmjs.com/package/@aztec/aztec.js)
- **Aztec version**: `4.0.0-devnet.2-patch.1`
