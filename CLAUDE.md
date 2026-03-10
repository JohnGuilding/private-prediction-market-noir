# Private Prediction Market - Aztec Project

## Aztec Development Rules

### Compilation & Testing
- **ALWAYS use `aztec compile` instead of `nargo compile`** — the aztec wrapper handles artifact postprocessing (AVM transpilation, verification key generation) that raw nargo does not.
- **ALWAYS use `aztec test` instead of `nargo test`** — same reason.
- Other nargo commands (formatting, docs) are fine to use directly.
- **Simulate before send**: Always call `.simulate()` before `.send()` for every state-changing transaction.

### Local Development Setup
- Install toolchain: `VERSION=4.0.0-devnet.2-patch.1 bash -i <(curl -sL https://install.aztec.network/4.0.0-devnet.2-patch.1)`
- Activate version: `aztec-up use 4.0.0-devnet.2-patch.1`
- PATH must include: `~/.aztec/current/bin` and `~/.aztec/current/node_modules/.bin`
- Start local network: `aztec start --local-network`
- Clear PXE store after network restart: `rm -rf ./store`

### Build Commands
```bash
aztec compile               # Compile Noir contract + postprocess (transpile + VK gen)
aztec codegen target --outdir src/artifacts  # Generate TS bindings
```

### MCP Servers (AI Tooling)
```
claude mcp add aztec -- npx @aztec/mcp-server@latest
claude mcp add noir -- npx noir-mcp-server@latest
```

### Key References
- Aztec docs: https://docs.aztec.network
- LLM-friendly docs: https://docs.aztec.network/llms.txt
- Reference repo: https://github.com/AztecProtocol/aztec-starter

## Project Structure
```
contracts/prediction_market/   -- Noir smart contract (aztec.nr)
  src/main.nr                  -- Core contract
  src/bet_note.nr              -- Custom encrypted note type
  src/market.nr                -- Market state struct
frontend/                      -- Next.js frontend
scripts/                       -- Deploy and demo scripts
src/                           -- TypeScript utilities
src/artifacts/                 -- Generated TS bindings (do not edit)
config/                        -- Network configuration
target/                        -- Compiled contract output
```

## Build Pipeline
1. `aztec compile` — compiles + transpiles + generates VKs
2. `aztec codegen target --outdir src/artifacts` — generates TypeScript bindings
3. Deploy via aztec.js SDK scripts

## Quick Start (Local)
```bash
yarn reset              # Kill processes, clear store
yarn network            # Start local Aztec network (wait for ready)
yarn build              # Compile contract + generate TS bindings
yarn deploy             # Deploy contract to local network
yarn demo               # Run full demo (create market, bet, resolve, claim)
```

## API Patterns (aztec.js v4.0.0-devnet.2-patch.1)
- **Wait for tx**: pass `wait` inside `.send()` options: `.send({ fee: ..., wait: { timeout: 60000 } })`
  - Do NOT chain `.send().wait()` — `wait` is not a method on the return value
- **Get block number**: use `node.getBlockNumber()` via `createAztecNodeClient`, NOT `wallet.getBlockNumber()`
- **Local network blocks**: only produced when transactions are pending — send dummy txs to advance blocks
- **EmbeddedWallet type**: `NodeEmbeddedWallet` — use `EmbeddedWallet` from `@aztec/wallets/embedded`

## Version
- **Aztec version: `4.0.0-devnet.2-patch.1`** — pinned across Nargo.toml, package.json, and config
- All @aztec/* npm packages must match this version
- aztec-nr dependency tag must match: `v4.0.0-devnet.2-patch.1`
