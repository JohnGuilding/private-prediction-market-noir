import { PredictionMarketContract } from "../src/artifacts/PredictionMarket.js";
import { type Logger, createLogger } from "@aztec/foundation/log";
import { SponsoredFeePaymentMethod } from "@aztec/aztec.js/fee";
import { setupWallet } from "../src/utils/setup_wallet.js";
import { getSponsoredFPCInstance } from "../src/utils/sponsored_fpc.js";
import { SponsoredFPCContractArtifact } from "@aztec/noir-contracts.js/SponsoredFPC";
import { deploySchnorrAccount } from "../src/utils/deploy_account.js";
import { getTimeouts } from "../config/config.js";

async function main() {
    const logger: Logger = createLogger('aztec:prediction-market');
    logger.info('Starting contract deployment...');

    const timeouts = getTimeouts();

    // Setup wallet
    const wallet = await setupWallet();
    logger.info('Wallet set up');

    // Setup sponsored FPC
    const sponsoredFPC = await getSponsoredFPCInstance();
    await wallet.registerContract(sponsoredFPC, SponsoredFPCContractArtifact);
    const sponsoredPaymentMethod = new SponsoredFeePaymentMethod(sponsoredFPC.address);
    logger.info(`Sponsored FPC at: ${sponsoredFPC.address}`);

    // Deploy account
    const accountManager = await deploySchnorrAccount(wallet);
    const address = accountManager.address;
    logger.info(`Account deployed at: ${address}`);

    // Deploy prediction market contract
    logger.info('Deploying PredictionMarket contract...');
    const deployRequest = PredictionMarketContract.deploy(wallet, address);
    await deployRequest.simulate({ from: address });
    const { contract, instance } = await deployRequest.send({
        from: address,
        fee: { paymentMethod: sponsoredPaymentMethod },
        wait: { timeout: timeouts.deployTimeout, returnReceipt: true },
    });

    logger.info(`PredictionMarket deployed at: ${contract.address}`);
    logger.info(`Admin: ${address}`);

    if (instance) {
        logger.info(`Salt: ${instance.salt}`);
        logger.info(`Deployer: ${instance.deployer}`);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        const logger = createLogger('aztec:prediction-market');
        logger.error(`Deployment failed: ${error.message}`);
        logger.error(error.stack);
        process.exit(1);
    });
