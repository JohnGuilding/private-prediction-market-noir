// Full demo script: create market, place private bets from two wallets,
// resolve via oracle, claim winnings.
//
// This demonstrates the core privacy property:
// After placing bets, on-chain state shows total pool size but NO individual bet directions.

import { PredictionMarketContract } from "../src/artifacts/PredictionMarket.js";
import { type Logger, createLogger } from "@aztec/foundation/log";
import { SponsoredFeePaymentMethod } from "@aztec/aztec.js/fee";
import { createAztecNodeClient } from "@aztec/aztec.js/node";
import { setupWallet } from "../src/utils/setup_wallet.js";
import { getSponsoredFPCInstance } from "../src/utils/sponsored_fpc.js";
import { SponsoredFPCContractArtifact } from "@aztec/noir-contracts.js/SponsoredFPC";
import { deploySchnorrAccount } from "../src/utils/deploy_account.js";
import { getTimeouts, getAztecNodeUrl } from "../config/config.js";
import { Fr } from "@aztec/aztec.js/fields";

// Local network only produces blocks when transactions are sent.
// This helper sends dummy market creations to advance the block number.
async function advanceBlocks(
    contract: any, sender: any, paymentMethod: any, targetBlock: number,
    node: any, logger: Logger, timeouts: any,
) {
    let blockNum = await node.getBlockNumber();
    let counter = 0;
    while (blockNum < targetBlock) {
        logger.info(`Advancing blocks: ${blockNum} -> ${targetBlock} (sending dummy tx ${++counter})...`);
        const dummyId = Fr.random();
        const dummyHash = Fr.random();
        // Create a throwaway market just to mine a block
        await contract.methods.create_market(dummyId, dummyHash, 999999).simulate({ from: sender.address });
        await contract.methods.create_market(dummyId, dummyHash, 999999).send({
            from: sender.address,
            fee: { paymentMethod },
            wait: { timeout: timeouts.txTimeout },
        });
        blockNum = await node.getBlockNumber();
    }
    logger.info(`Block target reached: ${blockNum}`);
}

async function main() {
    const logger: Logger = createLogger('aztec:prediction-market:demo');
    const timeouts = getTimeouts();
    const node = createAztecNodeClient(getAztecNodeUrl());

    // =========================================================================
    // Step 1: Setup wallets and deploy contract
    // =========================================================================
    logger.info('=== Step 1: Setup ===');

    const wallet = await setupWallet();
    const sponsoredFPC = await getSponsoredFPCInstance();
    await wallet.registerContract(sponsoredFPC, SponsoredFPCContractArtifact);
    const paymentMethod = new SponsoredFeePaymentMethod(sponsoredFPC.address);

    // Deploy two accounts (two bettors)
    logger.info('Deploying account 1 (Alice)...');
    const alice = await deploySchnorrAccount(wallet);
    logger.info(`Alice: ${alice.address}`);

    logger.info('Deploying account 2 (Bob)...');
    const bob = await deploySchnorrAccount(wallet);
    logger.info(`Bob: ${bob.address}`);

    // Deploy contract with Alice as admin
    logger.info('Deploying PredictionMarket contract...');
    const deployRequest = PredictionMarketContract.deploy(wallet, alice.address);
    await deployRequest.simulate({ from: alice.address });
    const { contract } = await deployRequest.send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.deployTimeout, returnReceipt: true },
    });
    logger.info(`Contract deployed at: ${contract.address}`);

    // =========================================================================
    // Step 2: Create a market
    // =========================================================================
    logger.info('=== Step 2: Create Market ===');

    const marketId = Fr.random();
    const questionHash = Fr.random();
    const currentBlock = await node.getBlockNumber();
    // Set deadline just 5 blocks out so we can resolve quickly
    const bettingDeadline = currentBlock + 5;

    logger.info(`Creating market ${marketId} with deadline at block ${bettingDeadline} (current: ${currentBlock})...`);
    await contract.methods.create_market(marketId, questionHash, bettingDeadline).simulate({
        from: alice.address,
    });
    await contract.methods.create_market(marketId, questionHash, bettingDeadline).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Market created!');

    // =========================================================================
    // Step 3: Place private bets
    // =========================================================================
    logger.info('=== Step 3: Place Private Bets ===');

    // Alice bets YES with 100 units
    logger.info('Alice placing private bet: YES, 100 units...');
    await contract.methods.place_bet(marketId, true, 100).simulate({
        from: alice.address,
    });
    await contract.methods.place_bet(marketId, true, 100).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Alice bet placed privately!');

    // Bob bets NO with 150 units
    logger.info('Bob placing private bet: NO, 150 units...');
    await contract.methods.place_bet(marketId, false, 150).simulate({
        from: bob.address,
    });
    await contract.methods.place_bet(marketId, false, 150).send({
        from: bob.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Bob bet placed privately!');

    // =========================================================================
    // Step 4: Inspect on-chain state (privacy demo)
    // =========================================================================
    logger.info('=== Step 4: Privacy Verification ===');
    logger.info('Reading on-chain market state...');

    const market = await contract.methods.get_market(marketId).simulate({ from: alice.address });
    logger.info(`Market state: total_pool=${market.total_pool}, num_bets=${market.num_bets}`);

    logger.info('KEY PRIVACY PROPERTY:');
    logger.info('  - Total pool shows 250 (100 + 150)');
    logger.info('  - Number of bets shows 2');
    logger.info('  - But WHO bet WHAT DIRECTION is nowhere on-chain!');

    // =========================================================================
    // Step 5: Wait for betting deadline, then resolve
    // =========================================================================
    logger.info('=== Step 5: Oracle Resolution ===');

    // Advance blocks past the deadline by sending dummy transactions
    await advanceBlocks(contract, alice, paymentMethod, bettingDeadline + 1, node, logger, timeouts);

    // Propose outcome: YES wins
    logger.info('Proposing outcome: YES...');
    await contract.methods.propose_outcome(marketId, true).simulate({
        from: alice.address,
    });
    await contract.methods.propose_outcome(marketId, true).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Outcome proposed!');

    // Advance blocks past the challenge period (10 blocks)
    logger.info('Advancing past challenge period (10 blocks)...');
    const proposalBlock = await node.getBlockNumber();
    await advanceBlocks(contract, alice, paymentMethod, proposalBlock + 10, node, logger, timeouts);

    // Finalize
    logger.info('Finalizing outcome...');
    await contract.methods.finalize_outcome(marketId).simulate({
        from: alice.address,
    });
    await contract.methods.finalize_outcome(marketId).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Market finalized! YES wins.');

    // =========================================================================
    // Step 6: Claim winnings
    // =========================================================================
    logger.info('=== Step 6: Claim Winnings ===');

    logger.info('Alice claiming winnings (she bet YES, YES won)...');
    await contract.methods.claim_winnings(marketId).simulate({
        from: alice.address,
    });
    await contract.methods.claim_winnings(marketId).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Alice claimed winnings!');

    logger.info('');
    logger.info('=== Demo Complete ===');
    logger.info('The full lifecycle worked: create -> bet -> resolve -> claim');
    logger.info('At no point did anyone know what anyone else bet.');
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        const logger = createLogger('aztec:prediction-market:demo');
        logger.error(`Demo failed: ${error.message}`);
        logger.error(error.stack);
        process.exit(1);
    });
