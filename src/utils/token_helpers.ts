import { type Logger } from "@aztec/foundation/log";
import { TokenContract } from "@aztec/noir-contracts.js/Token";
import { SponsoredFeePaymentMethod } from "@aztec/aztec.js/fee";
import type { AztecAddress } from "@aztec/aztec.js/addresses";
import type { AccountManager } from "@aztec/aztec.js/wallet";
import type { EmbeddedWallet } from "@aztec/wallets/embedded";
import type { PredictionMarketContract } from "../artifacts/PredictionMarket.js";
import type { TimeoutConfig } from "../../config/config.js";

export async function deployToken(
    wallet: EmbeddedWallet,
    admin: AztecAddress,
    paymentMethod: SponsoredFeePaymentMethod,
    timeouts: TimeoutConfig,
    logger: Logger,
): Promise<TokenContract> {
    logger.info('Deploying Token contract...');
    const deployRequest = TokenContract.deploy(wallet, admin, 'PredMarket', 'PRED', 18);
    await deployRequest.simulate({ from: admin });
    const { contract } = await deployRequest.send({
        from: admin,
        fee: { paymentMethod },
        wait: { timeout: timeouts.deployTimeout, returnReceipt: true },
    });
    logger.info(`Token deployed at: ${contract.address}`);
    return contract;
}

export async function mintTokensToPrivate(
    token: TokenContract,
    minter: AztecAddress,
    recipient: AztecAddress,
    amount: bigint,
    paymentMethod: SponsoredFeePaymentMethod,
    timeouts: TimeoutConfig,
    logger: Logger,
): Promise<void> {
    logger.info(`Minting ${amount} tokens to ${recipient}...`);
    await token.methods.mint_to_private(recipient, amount).simulate({ from: minter });
    await token.methods.mint_to_private(recipient, amount).send({
        from: minter,
        fee: { paymentMethod },
        wait: { timeout: timeouts.txTimeout },
    });
    logger.info(`Minted ${amount} tokens to ${recipient}`);
}

export async function createBetAuthwit(
    wallet: EmbeddedWallet,
    token: TokenContract,
    bettor: AccountManager,
    pmContract: PredictionMarketContract,
    amount: bigint,
) {
    const action = token.methods.transfer_to_public(
        bettor.address,
        pmContract.address,
        amount,
        0,
    );
    const call = await action.getFunctionCall();
    const witness = await wallet.createAuthWit(bettor.address, {
        caller: pmContract.address,
        call,
    });
    return witness;
}

export async function getPrivateBalance(
    token: TokenContract,
    owner: AztecAddress,
): Promise<bigint> {
    return await token.methods.balance_of_private(owner).simulate({ from: owner });
}
