// Full demo script: create market, place private bets, trade on AMM,
// resolve via oracle, reveal winning bets, claim winnings and redeem outcome tokens.
//
// Demonstrates:
// 1. Private betting via BetNotes (bet direction hidden on-chain)
// 2. AMM price discovery via outcome tokens (complete set model)
// 3. Optimistic oracle resolution with bonds
// 4. Market fees (creation fee + per-market fee rate)
// 5. Deferred pool reveal: no per-outcome data visible during betting

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
import { deriveKeys } from "@aztec/aztec.js/keys";
import { TokenContract } from "@aztec/noir-contracts.js/Token";
import { deployToken, mintTokensToPrivate, createBetAuthwit, getPrivateBalance } from "../src/utils/token_helpers.js";
import { setupMarketAMM, createBurnAuthwit, createTransferAuthwit } from "../src/utils/amm_helpers.js";

// Local network only produces blocks when transactions are sent.
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
        await contract.methods.create_market(dummyId, dummyHash, 999999, 2, 0, 0).simulate({ from: sender.address });
        await contract.methods.create_market(dummyId, dummyHash, 999999, 2, 0, 0).send({
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
    // Step 1: Setup wallets, deploy Token and PredictionMarket contracts
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

    // Deploy Token contract with Alice as admin/minter
    const token = await deployToken(wallet, alice.address, paymentMethod, timeouts, logger);

    // Deploy PredictionMarket with public keys (so it can hold private token notes)
    logger.info('Deploying PredictionMarket contract...');
    const pmSecretKey = Fr.random();
    const pmPublicKeys = (await deriveKeys(pmSecretKey)).publicKeys;

    const deployRequest = PredictionMarketContract.deployWithPublicKeys(
        pmPublicKeys, wallet, alice.address, token.address,
    );
    await deployRequest.simulate({ from: alice.address });

    const pmInstance = await deployRequest.getInstance();
    await wallet.registerContract(pmInstance, PredictionMarketContract.artifact, pmSecretKey);

    const { contract } = await deployRequest.send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.deployTimeout, returnReceipt: true },
    });
    logger.info(`PredictionMarket deployed at: ${contract.address}`);

    // =========================================================================
    // Step 2: Mint tokens to Alice and Bob
    // =========================================================================
    logger.info('=== Step 2: Mint Tokens ===');

    const ALICE_MINT = 1000n;
    const BOB_MINT = 1000n;
    await mintTokensToPrivate(token, alice.address, alice.address, ALICE_MINT, paymentMethod, timeouts, logger);
    await mintTokensToPrivate(token, alice.address, bob.address, BOB_MINT, paymentMethod, timeouts, logger);

    // Also mint public tokens for AMM operations
    logger.info('Minting public tokens for AMM operations...');
    await token.methods.mint_to_public(alice.address, 500n).simulate({ from: alice.address });
    await token.methods.mint_to_public(alice.address, 500n).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    await token.methods.mint_to_public(bob.address, 500n).simulate({ from: alice.address });
    await token.methods.mint_to_public(bob.address, 500n).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });

    const aliceBalBefore = await getPrivateBalance(token, alice.address);
    const bobBalBefore = await getPrivateBalance(token, bob.address);
    const alicePubBefore = await token.methods.balance_of_public(alice.address).simulate({ from: alice.address });
    const bobPubBefore = await token.methods.balance_of_public(bob.address).simulate({ from: bob.address });
    logger.info(`Alice private: ${aliceBalBefore}, public: ${alicePubBefore}`);
    logger.info(`Bob private: ${bobBalBefore}, public: ${bobPubBefore}`);

    // =========================================================================
    // Step 3: Create a market with fee rate
    // =========================================================================
    logger.info('=== Step 3: Create Market ===');

    const marketId = Fr.random();
    const questionHash = Fr.random();
    const currentBlock = await node.getBlockNumber();
    const bettingDeadline = currentBlock + 10;

    // Binary market: outcome 0 = NO, outcome 1 = YES. Bond = 0, fee = 30 bps (0.3%)
    const NUM_OUTCOMES = 2;
    const BOND_AMOUNT = 0n;
    const FEE_RATE = 30; // 0.3% fee on complete set purchases
    logger.info(`Creating binary market with deadline at block ${bettingDeadline}, fee rate: ${FEE_RATE} bps...`);
    await contract.methods.create_market(marketId, questionHash, bettingDeadline, NUM_OUTCOMES, BOND_AMOUNT, FEE_RATE).simulate({
        from: alice.address,
    });
    await contract.methods.create_market(marketId, questionHash, bettingDeadline, NUM_OUTCOMES, BOND_AMOUNT, FEE_RATE).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Market created!');

    // =========================================================================
    // Step 4: Setup AMM for this market
    // =========================================================================
    logger.info('=== Step 4: Setup AMM ===');

    const ammSetup = await setupMarketAMM(
        wallet, alice.address, contract, marketId, paymentMethod, timeouts, logger,
    );
    const [noToken, yesToken] = ammSetup.outcomeTokens;
    const { amm, lpToken } = ammSetup;

    // =========================================================================
    // Step 5: Place private bets (BetNote-based, fully private)
    // =========================================================================
    logger.info('=== Step 5: Place Private Bets ===');

    const ALICE_BET = 100n;
    const BOB_BET = 150n;
    const OUTCOME_NO = 0;
    const OUTCOME_YES = 1;

    // Alice bets YES (outcome 1) with 100 tokens (private)
    logger.info('Alice placing private bet: YES (outcome 1), 100 tokens...');
    const aliceAuthwit = await createBetAuthwit(wallet, token, alice, contract, ALICE_BET);
    await contract.methods.place_bet(marketId, OUTCOME_YES, ALICE_BET).simulate({
        from: alice.address,
    });
    await contract.methods.place_bet(marketId, OUTCOME_YES, ALICE_BET).send({
        from: alice.address,
        fee: { paymentMethod },
        authWitnesses: [aliceAuthwit],
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Alice bet placed privately!');

    // Bob bets NO (outcome 0) with 150 tokens (private)
    logger.info('Bob placing private bet: NO (outcome 0), 150 tokens...');
    const bobAuthwit = await createBetAuthwit(wallet, token, bob, contract, BOB_BET);
    await contract.methods.place_bet(marketId, OUTCOME_NO, BOB_BET).simulate({
        from: bob.address,
    });
    await contract.methods.place_bet(marketId, OUTCOME_NO, BOB_BET).send({
        from: bob.address,
        fee: { paymentMethod },
        authWitnesses: [bobAuthwit],
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Bob bet placed privately!');

    // =========================================================================
    // Step 6: AMM - Buy complete sets and trade outcome tokens
    // =========================================================================
    logger.info('=== Step 6: AMM Trading ===');

    // Alice buys a complete set (200 of each outcome token) using public PRED
    const COMPLETE_SET_AMOUNT = 200n;
    logger.info(`Alice buying complete set: ${COMPLETE_SET_AMOUNT} of each outcome token...`);

    // Alice needs authwit for PM to pull her public PRED
    const alicePredAuthwit = await createTransferAuthwit(
        wallet, token, alice, contract.address, contract.address, COMPLETE_SET_AMOUNT,
    );
    await contract.methods.buy_complete_set(marketId, COMPLETE_SET_AMOUNT).simulate({
        from: alice.address,
    });
    await contract.methods.buy_complete_set(marketId, COMPLETE_SET_AMOUNT).send({
        from: alice.address,
        fee: { paymentMethod },
        authWitnesses: [alicePredAuthwit],
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Complete set purchased!');

    // Check outcome token balances
    const aliceNoBalance = await noToken.methods.balance_of_public(alice.address).simulate({ from: alice.address });
    const aliceYesBalance = await yesToken.methods.balance_of_public(alice.address).simulate({ from: alice.address });
    logger.info(`Alice outcome tokens: NO=${aliceNoBalance}, YES=${aliceYesBalance}`);
    logger.info(`(Fee of 0.3% deducted: ${COMPLETE_SET_AMOUNT} PRED -> ~${COMPLETE_SET_AMOUNT - COMPLETE_SET_AMOUNT * 30n / 10000n} outcome tokens each)`);

    // Alice seeds AMM liquidity with her outcome tokens
    // She adds equal amounts of NO and YES tokens to the AMM
    const LIQUIDITY_AMOUNT = 100n;
    logger.info(`Alice adding ${LIQUIDITY_AMOUNT} of each outcome token as AMM liquidity...`);

    // Create authwits for AMM to spend Alice's outcome tokens
    const aliceNoAmmAuthwit = await createTransferAuthwit(
        wallet, noToken, alice, amm.address, amm.address, LIQUIDITY_AMOUNT,
    );
    const aliceYesAmmAuthwit = await createTransferAuthwit(
        wallet, yesToken, alice, amm.address, amm.address, LIQUIDITY_AMOUNT,
    );
    await amm.methods.add_liquidity(LIQUIDITY_AMOUNT, LIQUIDITY_AMOUNT, 0n, 0n, 0).simulate({
        from: alice.address,
    });
    await amm.methods.add_liquidity(LIQUIDITY_AMOUNT, LIQUIDITY_AMOUNT, 0n, 0n, 0).send({
        from: alice.address,
        fee: { paymentMethod },
        authWitnesses: [aliceNoAmmAuthwit, aliceYesAmmAuthwit],
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('AMM liquidity added!');

    // Check AMM state - prices reflect 50/50 since equal liquidity
    const ammNoReserve = await noToken.methods.balance_of_public(amm.address).simulate({ from: alice.address });
    const ammYesReserve = await yesToken.methods.balance_of_public(amm.address).simulate({ from: alice.address });
    logger.info(`AMM reserves: NO=${ammNoReserve}, YES=${ammYesReserve}`);
    logger.info(`Implied YES price: ${Number(ammNoReserve) / (Number(ammNoReserve) + Number(ammYesReserve)) * 100}%`);

    // Bob buys YES tokens from AMM (he thinks YES will win)
    // First Bob needs some outcome tokens to trade - buy a complete set
    const BOB_COMPLETE_SET = 100n;
    logger.info(`Bob buying complete set: ${BOB_COMPLETE_SET}...`);
    const bobPredAuthwit = await createTransferAuthwit(
        wallet, token, bob, contract.address, contract.address, BOB_COMPLETE_SET,
    );
    await contract.methods.buy_complete_set(marketId, BOB_COMPLETE_SET).simulate({
        from: bob.address,
    });
    await contract.methods.buy_complete_set(marketId, BOB_COMPLETE_SET).send({
        from: bob.address,
        fee: { paymentMethod },
        authWitnesses: [bobPredAuthwit],
        wait: { timeout: timeouts.txTimeout },
    });

    // Bob swaps NO tokens for YES tokens on AMM (bullish on YES)
    const BOB_SWAP_AMOUNT = 50n;
    logger.info(`Bob swapping ${BOB_SWAP_AMOUNT} NO -> YES on AMM...`);
    const bobNoSwapAuthwit = await createTransferAuthwit(
        wallet, noToken, bob, amm.address, amm.address, BOB_SWAP_AMOUNT,
    );
    await amm.methods.swap_exact_tokens_for_tokens(
        noToken.address, yesToken.address, BOB_SWAP_AMOUNT, 0n, 0,
    ).simulate({ from: bob.address });
    await amm.methods.swap_exact_tokens_for_tokens(
        noToken.address, yesToken.address, BOB_SWAP_AMOUNT, 0n, 0,
    ).send({
        from: bob.address,
        fee: { paymentMethod },
        authWitnesses: [bobNoSwapAuthwit],
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Bob swapped NO for YES!');

    // Check new AMM state - YES price should have increased
    const ammNoReserve2 = await noToken.methods.balance_of_public(amm.address).simulate({ from: alice.address });
    const ammYesReserve2 = await yesToken.methods.balance_of_public(amm.address).simulate({ from: alice.address });
    logger.info(`AMM reserves after Bob's trade: NO=${ammNoReserve2}, YES=${ammYesReserve2}`);
    logger.info(`Implied YES price: ${Number(ammNoReserve2) / (Number(ammNoReserve2) + Number(ammYesReserve2)) * 100}%`);

    // =========================================================================
    // Step 7: Inspect state (privacy verification)
    // =========================================================================
    logger.info('=== Step 7: Privacy Verification ===');

    const market = await contract.methods.get_market(marketId).simulate({ from: alice.address });
    logger.info(`Market state: total_pool=${market.total_pool}, num_bets=${market.num_bets}`);
    logger.info(`Market has NO per-outcome breakdown: revealed_winning_pool=${market.revealed_winning_pool} (zero during betting)`);

    logger.info('KEY PRIVACY PROPERTY:');
    logger.info('  - Total pool shows 250 (100 + 150) from private bets');
    logger.info('  - But NO per-outcome pools are stored — outcome_index is never written to public state');
    logger.info('  - An observer cannot see which outcomes are receiving money');
    logger.info('  - AMM prices reflect public sentiment from traders who chose to trade publicly');
    logger.info('  - Per-outcome breakdown only appears AFTER finalization via reveal phase');

    // =========================================================================
    // Step 8: Wait for betting deadline, then resolve
    // =========================================================================
    logger.info('=== Step 8: Oracle Resolution ===');

    await advanceBlocks(contract, alice, paymentMethod, bettingDeadline + 1, node, logger, timeouts);

    // Propose outcome: YES (outcome 1) wins
    logger.info('Proposing outcome: YES (outcome 1)...');
    await contract.methods.propose_outcome(marketId, OUTCOME_YES).simulate({
        from: alice.address,
    });
    await contract.methods.propose_outcome(marketId, OUTCOME_YES).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Outcome proposed!');

    // Advance past challenge period (10 blocks)
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
    // Step 8b: Reveal Phase — winners disclose bets to build revealed_winning_pool
    // =========================================================================
    logger.info('=== Step 8b: Reveal Phase ===');

    const marketAfterFinalize = await contract.methods.get_market(marketId).simulate({ from: alice.address });
    logger.info(`Reveal deadline: block ${marketAfterFinalize.reveal_deadline}`);
    logger.info(`Current revealed_winning_pool: ${marketAfterFinalize.revealed_winning_pool}`);

    // Alice reveals her winning bets (she bet YES, YES won)
    logger.info('Alice revealing winning bets...');
    await contract.methods.reveal_bets(marketId, OUTCOME_YES).simulate({
        from: alice.address,
    });
    await contract.methods.reveal_bets(marketId, OUTCOME_YES).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Alice revealed!');

    const marketAfterReveal = await contract.methods.get_market(marketId).simulate({ from: alice.address });
    logger.info(`revealed_winning_pool after Alice's reveal: ${marketAfterReveal.revealed_winning_pool}`);
    logger.info('(Should be 100 — Alice bet 100 on YES)');

    // Advance past reveal deadline
    logger.info('Advancing past reveal deadline...');
    await advanceBlocks(contract, alice, paymentMethod, Number(marketAfterFinalize.reveal_deadline) + 1, node, logger, timeouts);

    // =========================================================================
    // Step 9: Claim winnings (private bets) + Redeem outcome tokens
    // =========================================================================
    logger.info('=== Step 9: Claim & Redeem ===');

    // Alice claims private bet winnings (she bet YES, YES won, and she revealed)
    logger.info('Alice claiming private bet winnings...');
    await contract.methods.claim_winnings(marketId, OUTCOME_YES).simulate({
        from: alice.address,
    });
    await contract.methods.claim_winnings(marketId, OUTCOME_YES).send({
        from: alice.address,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info('Alice claimed private bet winnings!');
    logger.info('Payout: 100 * 250 / 100 = 250 (Alice gets entire pool since she is the only revealer)');

    // Bob redeems his YES outcome tokens (from AMM trading)
    const bobYesBalance = await yesToken.methods.balance_of_public(bob.address).simulate({ from: bob.address });
    if (bobYesBalance > 0n) {
        logger.info(`Bob redeeming ${bobYesBalance} YES tokens for PRED...`);
        const bobBurnAuthwit = await createBurnAuthwit(wallet, yesToken, bob, contract.address, bobYesBalance);
        await contract.methods.redeem_winning_tokens(marketId, bobYesBalance).simulate({
            from: bob.address,
        });
        await contract.methods.redeem_winning_tokens(marketId, bobYesBalance).send({
            from: bob.address,
            fee: { paymentMethod },
            authWitnesses: [bobBurnAuthwit],
            wait: { timeout: timeouts.txTimeout },
        });
        logger.info('Bob redeemed YES tokens!');
    }

    // Alice also redeems any YES tokens she still holds
    const aliceYesFinal = await yesToken.methods.balance_of_public(alice.address).simulate({ from: alice.address });
    if (aliceYesFinal > 0n) {
        logger.info(`Alice redeeming ${aliceYesFinal} YES tokens for PRED...`);
        const aliceBurnAuthwit = await createBurnAuthwit(wallet, yesToken, alice, contract.address, aliceYesFinal);
        await contract.methods.redeem_winning_tokens(marketId, aliceYesFinal).simulate({
            from: alice.address,
        });
        await contract.methods.redeem_winning_tokens(marketId, aliceYesFinal).send({
            from: alice.address,
            fee: { paymentMethod },
            authWitnesses: [aliceBurnAuthwit],
            wait: { timeout: timeouts.txTimeout },
        });
        logger.info('Alice redeemed YES tokens!');
    }

    // =========================================================================
    // Step 10: Verify final token balances
    // =========================================================================
    logger.info('=== Step 10: Final Token Balances ===');

    const alicePrivFinal = await getPrivateBalance(token, alice.address);
    const alicePubFinal = await token.methods.balance_of_public(alice.address).simulate({ from: alice.address });
    const bobPrivFinal = await getPrivateBalance(token, bob.address);
    const bobPubFinal = await token.methods.balance_of_public(bob.address).simulate({ from: bob.address });

    logger.info(`Alice private: started=${aliceBalBefore}, final=${alicePrivFinal}`);
    logger.info(`Alice public: started=${alicePubBefore}, final=${alicePubFinal}`);
    logger.info(`Alice total: ${alicePrivFinal + alicePubFinal}`);
    logger.info(`Bob private: started=${bobBalBefore}, final=${bobPrivFinal}`);
    logger.info(`Bob public: started=${bobPubBefore}, final=${bobPubFinal}`);
    logger.info(`Bob total: ${bobPrivFinal + bobPubFinal}`);

    logger.info('');
    logger.info('=== Demo Complete ===');
    logger.info('Full lifecycle: deploy tokens -> mint -> create market (with fees) -> setup AMM');
    logger.info('  -> private bets (BetNotes) -> AMM trading (outcome tokens) -> price discovery');
    logger.info('  -> oracle resolution -> REVEAL PHASE -> claim private winnings + redeem outcome tokens');
    logger.info('Privacy preserved: during betting, only total_pool visible. No per-outcome data on-chain.');
    logger.info('Winners reveal after finalization (cannot influence betting). Non-revealers forfeit their share.');
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        const logger = createLogger('aztec:prediction-market:demo');
        logger.error(`Demo failed: ${error.message}`);
        logger.error(error.stack);
        process.exit(1);
    });
