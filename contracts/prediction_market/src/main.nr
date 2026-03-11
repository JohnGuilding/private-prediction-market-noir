// Private Prediction Market Contract
//
// A prediction market where betting activity is permanently private using Aztec's native privacy.
// Supports multi-outcome markets (up to 8 outcomes).
// Uses optimistic oracle resolution with bonds: proposers and challengers stake tokens.
// AMM price discovery via outcome tokens (complete set model).
//
// Two position mechanisms:
// 1. Private bets (place_bet): Fully private via BetNotes, claims via claim_winnings
// 2. Outcome tokens (buy_complete_set): Tradeable on AMM, redeems via redeem_winning_tokens
//
// Privacy model:
// - During betting: only total_pool is visible. No per-outcome breakdown on-chain.
// - After finalization: winners reveal bets in a reveal phase, then claim payouts.
// - This prevents front-running, copy trading, and sentiment-based manipulation.
//
// Token flow:
// - place_bet: bettor's PRIVATE -> contract's PUBLIC (total pool, no outcome info)
// - buy_complete_set: buyer's PUBLIC -> contract's PUBLIC, mints outcome tokens
// - sell_complete_set: burns outcome tokens, contract's PUBLIC -> seller's PUBLIC
// - redeem_winning_tokens: burns winning tokens, contract's PUBLIC -> redeemer's PUBLIC
// - propose/challenge: bond from proposer/challenger's PUBLIC -> contract's PUBLIC
// - finalize/arbitrate: bond returned/distributed from contract's PUBLIC
// - reveal_bets: winners disclose winning bet amounts (builds revealed_winning_pool)
// - claim_winnings: payout from contract's PUBLIC -> claimer's PUBLIC (after reveal deadline)

mod bet_note;
mod market;

use ::aztec::macros::aztec;

#[aztec]
pub contract PredictionMarket {
    use ::aztec::{
        macros::{functions::{external, initializer, only_self}, storage::storage},
        messages::message_delivery::MessageDelivery,
        note::note_getter_options::NoteGetterOptions,
        oracle::logging::debug_log_format,
    };
    use ::aztec::protocol::{address::AztecAddress, traits::ToField};
    use ::aztec::state_vars::{Map, Owned, PrivateSet, PublicImmutable, PublicMutable};

    use crate::{bet_note::BetNote, market::{Market, MAX_OUTCOMES}};
    use token::Token;

    global DEFAULT_CHALLENGE_PERIOD: u32 = 10;
    global DEFAULT_REVEAL_PERIOD: u32 = 5;
    global FEE_DENOMINATOR: u32 = 10000;

    #[storage]
    struct Storage<Context> {
        admin: PublicMutable<AztecAddress, Context>,
        token: PublicImmutable<AztecAddress, Context>,
        markets: Map<Field, PublicMutable<Market, Context>, Context>,
        bets: Map<Field, Owned<PrivateSet<BetNote, Context>, Context>, Context>,
        claimed: Map<Field, Map<AztecAddress, PublicMutable<bool, Context>, Context>, Context>,
        revealed: Map<Field, Map<AztecAddress, PublicMutable<bool, Context>, Context>, Context>,
        // AMM: per-market outcome token addresses (market_id -> outcome_index -> token_address)
        outcome_tokens: Map<Field, Map<Field, PublicMutable<AztecAddress, Context>, Context>, Context>,
        // AMM: per-market AMM contract address
        market_amms: Map<Field, PublicMutable<AztecAddress, Context>, Context>,
        // Global creation fee in PRED tokens
        creation_fee: PublicMutable<Field, Context>,
    }

    #[external("public")]
    #[initializer]
    fn constructor(admin: AztecAddress, token_address: AztecAddress) {
        debug_log_format("Initializing PredictionMarket with admin {0}", [admin.to_field()]);
        self.storage.admin.write(admin);
        self.storage.token.initialize(token_address);
        self.storage.creation_fee.write(0);
    }

    // =========================================================================
    // PUBLIC FUNCTIONS
    // =========================================================================

    #[external("public")]
    fn create_market(
        market_id: Field,
        question_hash: Field,
        betting_deadline: u32,
        num_outcomes: u8,
        bond_amount: Field,
        fee_rate: u32,
    ) {
        let creator = self.context.maybe_msg_sender().unwrap();

        // Charge creation fee if set
        let creation_fee = self.storage.creation_fee.read();
        if creation_fee != 0 {
            let token_addr = self.storage.token.read();
            self.call(Token::at(token_addr).transfer_in_public(
                creator, self.context.this_address(), creation_fee as u128, 0,
            ));
        }

        debug_log_format(
            "Creating market {0} by {1} with {2} outcomes, bond {3}",
            [market_id, creator.to_field(), num_outcomes as Field, bond_amount],
        );

        let existing = self.storage.markets.at(market_id).read();
        assert(existing.creator.eq(AztecAddress::zero()), "Market already exists");

        assert(fee_rate <= FEE_DENOMINATOR, "Fee rate too high");

        let market = Market::new(
            question_hash, creator, betting_deadline, num_outcomes,
            DEFAULT_CHALLENGE_PERIOD, bond_amount, fee_rate, DEFAULT_REVEAL_PERIOD,
        );
        self.storage.markets.at(market_id).write(market);
    }

    #[external("public")]
    #[only_self]
    fn update_pool(market_id: Field, amount: Field) {
        let market = self.storage.markets.at(market_id).read();
        assert(
            self.context.block_number() <= market.betting_deadline,
            "Betting deadline passed",
        );
        debug_log_format(
            "Updating pool for market {0}, adding {1}",
            [market_id, amount],
        );
        self.storage.markets.at(market_id).write(market.add_bet(amount));
    }

    #[external("public")]
    #[only_self]
    fn accumulate_winning_pool(market_id: Field, revealer: AztecAddress, amount: Field) {
        let market = self.storage.markets.at(market_id).read();
        assert(market.is_finalized(), "Market not finalized");
        assert(
            market.is_in_reveal_phase(self.context.block_number()),
            "Not in reveal phase",
        );

        let already_revealed = self.storage.revealed.at(market_id).at(revealer).read();
        assert(!already_revealed, "Already revealed");
        self.storage.revealed.at(market_id).at(revealer).write(true);

        debug_log_format(
            "Accumulating reveal for market {0}, revealer {1}, amount {2}",
            [market_id, revealer.to_field(), amount],
        );
        self.storage.markets.at(market_id).write(market.accumulate_reveal(amount));
    }

    // =========================================================================
    // AMM / OUTCOME TOKEN FUNCTIONS
    // =========================================================================

    // Admin initializes AMM for a market by registering outcome token addresses and AMM address.
    // Outcome tokens must be deployed separately and PM set as minter on each.
    #[external("public")]
    fn initialize_market_amm(
        market_id: Field,
        outcome_token_0: AztecAddress,
        outcome_token_1: AztecAddress,
        amm_address: AztecAddress,
    ) {
        let caller = self.context.maybe_msg_sender().unwrap();
        let admin = self.storage.admin.read();
        assert(caller.eq(admin), "Only admin can initialize AMM");

        let market = self.storage.markets.at(market_id).read();
        assert(!market.creator.eq(AztecAddress::zero()), "Market does not exist");

        // Verify AMM is not already initialized
        let existing_amm = self.storage.market_amms.at(market_id).read();
        assert(existing_amm.eq(AztecAddress::zero()), "AMM already initialized");

        self.storage.outcome_tokens.at(market_id).at(0).write(outcome_token_0);
        self.storage.outcome_tokens.at(market_id).at(1).write(outcome_token_1);
        self.storage.market_amms.at(market_id).write(amm_address);

        debug_log_format(
            "AMM initialized for market {0}, tokens: {1}, {2}",
            [market_id, outcome_token_0.to_field(), outcome_token_1.to_field()],
        );
    }

    // Buy a complete set of outcome tokens. Pays `amount` PRED, receives `amount` of each outcome token.
    // Fee is deducted: net_amount = amount - (amount * fee_rate / 10000)
    #[external("public")]
    fn buy_complete_set(market_id: Field, amount: Field) {
        let buyer = self.context.maybe_msg_sender().unwrap();
        let market = self.storage.markets.at(market_id).read();
        assert(market.is_open(), "Market not open");
        assert(
            self.context.block_number() <= market.betting_deadline,
            "Betting deadline passed",
        );

        // Calculate fee
        let fee = if market.fee_rate > 0 {
            (amount as u128 * market.fee_rate as u128) / FEE_DENOMINATOR as u128
        } else {
            0 as u128
        };
        let net_amount = amount as u128 - fee;

        // Take PRED from buyer (full amount including fee)
        let token_addr = self.storage.token.read();
        self.call(Token::at(token_addr).transfer_in_public(
            buyer, self.context.this_address(), amount as u128, 0,
        ));

        // Mint outcome tokens (net amount after fee)
        for i in 0..MAX_OUTCOMES {
            if i < market.num_outcomes as u32 {
                let outcome_token = self.storage.outcome_tokens.at(market_id).at(i as Field).read();
                if !outcome_token.eq(AztecAddress::zero()) {
                    self.call(Token::at(outcome_token).mint_to_public(buyer, net_amount));
                }
            }
        }

        debug_log_format(
            "Complete set bought for market {0}, amount {1}, fee {2}",
            [market_id, amount, fee as Field],
        );
    }

    // Sell a complete set of outcome tokens. Burns `amount` of each outcome token, returns `amount` PRED.
    #[external("public")]
    fn sell_complete_set(market_id: Field, amount: Field) {
        let seller = self.context.maybe_msg_sender().unwrap();
        let market = self.storage.markets.at(market_id).read();
        assert(!market.is_finalized(), "Market already finalized");

        // Burn outcome tokens from seller (requires authwits from seller)
        for i in 0..MAX_OUTCOMES {
            if i < market.num_outcomes as u32 {
                let outcome_token = self.storage.outcome_tokens.at(market_id).at(i as Field).read();
                if !outcome_token.eq(AztecAddress::zero()) {
                    self.call(Token::at(outcome_token).burn_public(seller, amount as u128, 0));
                }
            }
        }

        // Return PRED to seller
        let token_addr = self.storage.token.read();
        self.call(Token::at(token_addr).transfer_in_public(
            self.context.this_address(), seller, amount as u128, 0,
        ));

        debug_log_format(
            "Complete set sold for market {0}, amount {1}",
            [market_id, amount],
        );
    }

    // Redeem winning outcome tokens for PRED after market finalization.
    // Burns winning outcome tokens 1:1 for PRED.
    #[external("public")]
    fn redeem_winning_tokens(market_id: Field, amount: Field) {
        let redeemer = self.context.maybe_msg_sender().unwrap();
        let market = self.storage.markets.at(market_id).read();
        assert(market.is_finalized(), "Market not finalized");

        // Burn winning outcome tokens from redeemer
        let winning_token = self.storage.outcome_tokens.at(market_id).at(
            market.winning_outcome as Field,
        ).read();
        assert(!winning_token.eq(AztecAddress::zero()), "No outcome tokens for this market");
        self.call(Token::at(winning_token).burn_public(redeemer, amount as u128, 0));

        // Pay PRED 1:1
        let token_addr = self.storage.token.read();
        self.call(Token::at(token_addr).transfer_in_public(
            self.context.this_address(), redeemer, amount as u128, 0,
        ));

        debug_log_format(
            "Redeemed {0} winning tokens for market {1} by {2}",
            [amount, market_id, redeemer.to_field()],
        );
    }

    // =========================================================================
    // FEE MANAGEMENT
    // =========================================================================

    // Admin sets the global creation fee
    #[external("public")]
    fn set_creation_fee(fee: Field) {
        let caller = self.context.maybe_msg_sender().unwrap();
        let admin = self.storage.admin.read();
        assert(caller.eq(admin), "Only admin can set creation fee");
        self.storage.creation_fee.write(fee);
        debug_log_format("Creation fee set to {0}", [fee]);
    }

    // Admin withdraws accumulated fees to a recipient
    #[external("public")]
    fn withdraw_fees(recipient: AztecAddress, amount: Field) {
        let caller = self.context.maybe_msg_sender().unwrap();
        let admin = self.storage.admin.read();
        assert(caller.eq(admin), "Only admin can withdraw fees");

        let token_addr = self.storage.token.read();
        self.call(Token::at(token_addr).transfer_in_public(
            self.context.this_address(), recipient, amount as u128, 0,
        ));

        debug_log_format("Fees withdrawn: {0} to {1}", [amount, recipient.to_field()]);
    }

    // =========================================================================
    // ORACLE RESOLUTION
    // =========================================================================

    // Propose an outcome after betting deadline. Requires staking bond_amount tokens.
    #[external("public")]
    fn propose_outcome(market_id: Field, outcome: u8) {
        let proposer = self.context.maybe_msg_sender().unwrap();
        let market = self.storage.markets.at(market_id).read();
        assert(
            self.context.block_number() > market.betting_deadline,
            "Betting still open",
        );

        // Transfer bond from proposer to contract
        if market.bond_amount != 0 {
            let token_addr = self.storage.token.read();
            self.call(Token::at(token_addr).transfer_in_public(
                proposer, self.context.this_address(), market.bond_amount as u128, 0,
            ));
        }

        debug_log_format(
            "Proposing outcome {0} for market {1} by {2}",
            [outcome as Field, market_id, proposer.to_field()],
        );
        self.storage.markets.at(market_id).write(
            market.propose(proposer, outcome, self.context.block_number()),
        );
    }

    // Challenge a proposed outcome. Requires staking bond_amount tokens.
    #[external("public")]
    fn challenge_outcome(market_id: Field, counter_outcome: u8) {
        let challenger = self.context.maybe_msg_sender().unwrap();
        let market = self.storage.markets.at(market_id).read();

        // Transfer bond from challenger to contract
        if market.bond_amount != 0 {
            let token_addr = self.storage.token.read();
            self.call(Token::at(token_addr).transfer_in_public(
                challenger, self.context.this_address(), market.bond_amount as u128, 0,
            ));
        }

        debug_log_format(
            "Challenging market {0} with outcome {1} by {2}",
            [market_id, counter_outcome as Field, challenger.to_field()],
        );
        self.storage.markets.at(market_id).write(
            market.challenge(challenger, counter_outcome, self.context.block_number()),
        );
    }

    // Admin arbitrates a challenged market. Loser's bond goes to winner.
    #[external("public")]
    fn arbitrate(market_id: Field, winning_outcome: u8) {
        let caller = self.context.maybe_msg_sender().unwrap();
        let admin = self.storage.admin.read();
        assert(caller.eq(admin), "Only admin can arbitrate");

        let market = self.storage.markets.at(market_id).read();

        debug_log_format(
            "Arbitrating market {0}, winning outcome {1}",
            [market_id, winning_outcome as Field],
        );

        // Distribute bonds: winner gets both bonds
        if market.bond_amount != 0 {
            let token_addr = self.storage.token.read();
            let double_bond = (market.bond_amount as u128) * 2;

            let bond_winner = if winning_outcome == market.proposed_outcome {
                market.proposer
            } else {
                market.challenger
            };

            self.call(Token::at(token_addr).transfer_in_public(
                self.context.this_address(), bond_winner, double_bond, 0,
            ));
        }

        self.storage.markets.at(market_id).write(
            market.arbitrate(winning_outcome, self.context.block_number()),
        );
    }

    // Finalize outcome after challenge period (no dispute). Returns proposer's bond.
    #[external("public")]
    fn finalize_outcome(market_id: Field) {
        let market = self.storage.markets.at(market_id).read();
        debug_log_format("Finalizing market {0}", [market_id]);

        // Return bond to proposer
        if market.bond_amount != 0 {
            let token_addr = self.storage.token.read();
            self.call(Token::at(token_addr).transfer_in_public(
                self.context.this_address(), market.proposer, market.bond_amount as u128, 0,
            ));
        }

        self.storage.markets.at(market_id).write(
            market.finalize(self.context.block_number()),
        );
    }

    // Process claim: verify, calculate payout, transfer tokens (from private bet pool)
    // Only callable after reveal deadline. Uses revealed_winning_pool for payout calculation.
    #[external("public")]
    #[only_self]
    fn process_claim(
        market_id: Field,
        claimer: AztecAddress,
        bet_amount: Field,
        expected_outcome: u8,
    ) {
        let market = self.storage.markets.at(market_id).read();
        assert(market.is_finalized(), "Market not finalized");
        assert(
            market.is_claimable(self.context.block_number()),
            "Reveal phase not over",
        );
        assert(market.winning_outcome == expected_outcome, "Outcome does not match");

        let already_claimed = self.storage.claimed.at(market_id).at(claimer).read();
        assert(!already_claimed, "Already claimed");
        self.storage.claimed.at(market_id).at(claimer).write(true);

        let winning_pool = market.revealed_winning_pool;
        assert(winning_pool != 0, "Winning pool is empty");
        let payout = (bet_amount as u128 * market.total_pool as u128) / winning_pool as u128;

        debug_log_format(
            "Claim processed for {0} on market {1}, payout: {2}",
            [claimer.to_field(), market_id, payout as Field],
        );

        let token_addr = self.storage.token.read();
        self.call(Token::at(token_addr).transfer_in_public(
            self.context.this_address(),
            claimer,
            payout,
            0,
        ));
    }

    // =========================================================================
    // PRIVATE FUNCTIONS
    // =========================================================================

    #[external("private")]
    fn place_bet(market_id: Field, outcome_index: u8, amount: Field) {
        let bettor = self.context.maybe_msg_sender().unwrap();
        let token_addr = self.storage.token.read();
        debug_log_format(
            "Placing private bet on market {0}, outcome {1}, amount {2}",
            [market_id, outcome_index as Field, amount],
        );

        Token::at(token_addr).transfer_to_public(
            bettor, self.context.this_address(), amount as u128, 0,
        ).call(self.context);

        self
            .storage
            .bets
            .at(market_id)
            .at(bettor)
            .insert(BetNote::new(market_id, outcome_index, amount, bettor))
            .deliver(MessageDelivery.ONCHAIN_CONSTRAINED);

        // Only enqueue total amount -- no outcome_index leaked to public state
        self.enqueue(PredictionMarket::at(self.context.this_address()).update_pool(
            market_id,
            amount,
        ));
    }

    // Reveal winning bets after finalization. Sums winning bet amounts from BetNotes
    // and enqueues accumulate_winning_pool to build the revealed_winning_pool.
    // Must be called during the reveal phase (before reveal_deadline).
    #[external("private")]
    fn reveal_bets(market_id: Field, expected_outcome: u8) {
        let revealer = self.context.maybe_msg_sender().unwrap();
        debug_log_format(
            "Revealing bets for {0} on market {1}, outcome {2}",
            [revealer.to_field(), market_id, expected_outcome as Field],
        );

        let notes = self.storage.bets.at(market_id).at(revealer).get_notes(
            NoteGetterOptions::new(),
        );

        let mut total_winning_amount: Field = 0;
        let mut has_winning_bet = false;

        for i in 0..10 {
            if i < notes.len() {
                let note = notes.get(i as u32).note;
                if note.outcome_index == expected_outcome {
                    total_winning_amount = total_winning_amount + note.amount;
                    has_winning_bet = true;
                }
            }
        }

        assert(has_winning_bet, "No winning bets found for this market");

        self.enqueue(PredictionMarket::at(self.context.this_address()).accumulate_winning_pool(
            market_id,
            revealer,
            total_winning_amount,
        ));
    }

    #[external("private")]
    fn claim_winnings(market_id: Field, expected_outcome: u8) {
        let claimer = self.context.maybe_msg_sender().unwrap();
        debug_log_format(
            "Claiming winnings for {0} on market {1}",
            [claimer.to_field(), market_id],
        );

        let notes = self.storage.bets.at(market_id).at(claimer).get_notes(
            NoteGetterOptions::new(),
        );

        let mut total_winning_amount: Field = 0;
        let mut has_winning_bet = false;

        for i in 0..10 {
            if i < notes.len() {
                let note = notes.get(i as u32).note;
                if note.outcome_index == expected_outcome {
                    total_winning_amount = total_winning_amount + note.amount;
                    has_winning_bet = true;
                }
            }
        }

        assert(has_winning_bet, "No winning bets found for this market");

        self.enqueue(PredictionMarket::at(self.context.this_address()).process_claim(
            market_id,
            claimer,
            total_winning_amount,
            expected_outcome,
        ));
    }

    // =========================================================================
    // UTILITY FUNCTIONS
    // =========================================================================

    #[external("utility")]
    unconstrained fn get_market(market_id: Field) -> pub Market {
        self.storage.markets.at(market_id).read()
    }

    #[external("utility")]
    unconstrained fn has_revealed(market_id: Field, user: AztecAddress) -> pub bool {
        self.storage.revealed.at(market_id).at(user).read()
    }

    #[external("utility")]
    unconstrained fn get_outcome_token(market_id: Field, outcome_index: Field) -> pub AztecAddress {
        self.storage.outcome_tokens.at(market_id).at(outcome_index).read()
    }

    #[external("utility")]
    unconstrained fn get_market_amm_address(market_id: Field) -> pub AztecAddress {
        self.storage.market_amms.at(market_id).read()
    }

    #[external("utility")]
    unconstrained fn get_creation_fee() -> pub Field {
        self.storage.creation_fee.read()
    }

    #[external("utility")]
    unconstrained fn debug_market(market_id: Field) {
        let market = self.storage.markets.at(market_id).read();
        market.log_state(market_id);
    }
}
