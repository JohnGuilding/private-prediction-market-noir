import { type Logger } from "@aztec/foundation/log";
import { TokenContract } from "@aztec/noir-contracts.js/Token";
import { AMMContract } from "@aztec/noir-contracts.js/AMM";
import { SponsoredFeePaymentMethod } from "@aztec/aztec.js/fee";
import type { AztecAddress } from "@aztec/aztec.js/addresses";
import type { EmbeddedWallet } from "@aztec/wallets/embedded";
import type { PredictionMarketContract } from "../artifacts/PredictionMarket.js";
import type { TimeoutConfig } from "../../config/config.js";

export interface MarketAMMSetup {
    outcomeTokens: TokenContract[];
    lpToken: TokenContract;
    amm: AMMContract;
}

export async function deployOutcomeToken(
    wallet: EmbeddedWallet,
    admin: AztecAddress,
    name: string,
    symbol: string,
    paymentMethod: SponsoredFeePaymentMethod,
    timeouts: TimeoutConfig,
    logger: Logger,
): Promise<TokenContract> {
    logger.info(`Deploying outcome token: ${name} (${symbol})...`);
    const deployRequest = TokenContract.deploy(wallet, admin, name, symbol, 18);
    await deployRequest.simulate({ from: admin });
    const { contract } = await deployRequest.send({
        from: admin,
        fee: { paymentMethod },
        wait: { timeout: timeouts.deployTimeout, returnReceipt: true },
    });
    logger.info(`Outcome token ${symbol} deployed at: ${contract.address}`);
    return contract;
}

export async function setupMarketAMM(
    wallet: EmbeddedWallet,
    admin: AztecAddress,
    pm: PredictionMarketContract,
    marketId: bigint | typeof import("@aztec/aztec.js/fields").Fr.prototype,
    paymentMethod: SponsoredFeePaymentMethod,
    timeouts: TimeoutConfig,
    logger: Logger,
): Promise<MarketAMMSetup> {
    // Deploy YES token (outcome 0 = NO, outcome 1 = YES for binary markets)
    const token0 = await deployOutcomeToken(
        wallet, admin, 'Outcome-NO', 'NO', paymentMethod, timeouts, logger,
    );
    const token1 = await deployOutcomeToken(
        wallet, admin, 'Outcome-YES', 'YES', paymentMethod, timeouts, logger,
    );

    // Deploy LP token for AMM
    const lpToken = await deployOutcomeToken(
        wallet, admin, 'AMM-LP', 'LP', paymentMethod, timeouts, logger,
    );

    // Set PM contract as minter on outcome tokens
    logger.info('Setting PM as minter on outcome tokens...');
    await token0.methods.set_minter(pm.address, true).simulate({ from: admin });
    await token0.methods.set_minter(pm.address, true).send({
        from: admin,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });

    await token1.methods.set_minter(pm.address, true).simulate({ from: admin });
    await token1.methods.set_minter(pm.address, true).send({
        from: admin,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });

    // Deploy AMM contract with token0 (NO) and token1 (YES)
    logger.info('Deploying AMM contract...');
    const ammDeploy = AMMContract.deploy(wallet, token0.address, token1.address, lpToken.address);
    await ammDeploy.simulate({ from: admin });
    const { contract: amm } = await ammDeploy.send({
        from: admin,
        fee: { paymentMethod },
        wait: { timeout: timeouts.deployTimeout, returnReceipt: true },
    });
    logger.info(`AMM deployed at: ${amm.address}`);

    // Set AMM as minter/burner on LP token (AMM needs to mint/burn LP tokens)
    await lpToken.methods.set_minter(amm.address, true).simulate({ from: admin });
    await lpToken.methods.set_minter(amm.address, true).send({
        from: admin,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });

    // Register AMM config in PM contract
    logger.info('Registering AMM config in PredictionMarket...');
    await pm.methods.initialize_market_amm(
        marketId, token0.address, token1.address, amm.address,
    ).simulate({ from: admin });
    await pm.methods.initialize_market_amm(
        marketId, token0.address, token1.address, amm.address,
    ).send({
        from: admin,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });

    logger.info('Market AMM setup complete!');
    return { outcomeTokens: [token0, token1], lpToken, amm };
}

export async function createBurnAuthwit(
    wallet: EmbeddedWallet,
    outcomeToken: TokenContract,
    owner: { address: AztecAddress },
    spender: AztecAddress,
    amount: bigint,
) {
    const action = outcomeToken.methods.burn_public(owner.address, amount, 0);
    const call = await action.getFunctionCall();
    const witness = await wallet.createAuthWit(owner.address, {
        caller: spender,
        call,
    });
    return witness;
}

export async function createTransferAuthwit(
    wallet: EmbeddedWallet,
    token: TokenContract,
    owner: { address: AztecAddress },
    spender: AztecAddress,
    recipient: AztecAddress,
    amount: bigint,
) {
    const action = token.methods.transfer_in_public(owner.address, recipient, amount, 0);
    const call = await action.getFunctionCall();
    const witness = await wallet.createAuthWit(owner.address, {
        caller: spender,
        call,
    });
    return witness;
}
