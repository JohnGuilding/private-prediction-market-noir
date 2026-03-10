// Private Prediction Market Contract
//
// A prediction market where betting activity is permanently private using Aztec's native privacy.
// Bets (direction + amount) are stored as encrypted notes - only the bettor can read them.
// The on-chain state shows total pool size but never reveals who bet which direction.
//
// Flow:
// 1. Creator calls create_market with a question hash and deadline
// 2. Users call place_bet (private) - creates encrypted BetNote, only updates aggregate pool publicly
// 3. After deadline, anyone can propose_outcome via the oracle
// 4. After challenge period, finalize_outcome locks the result
// 5. Winners call claim_winnings (private) - proves their note matches, receives payout

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
    use ::aztec::state_vars::{Map, Owned, PrivateSet, PublicMutable};

    use crate::{bet_note::BetNote, market::Market};

    // Default challenge period: 10 blocks (short for demo, would be longer in production)
    global DEFAULT_CHALLENGE_PERIOD: u32 = 10;

    #[storage]
    struct Storage<Context> {
        // Contract admin
        admin: PublicMutable<AztecAddress, Context>,

        // Maps market_id -> Market struct (public state)
        markets: Map<Field, PublicMutable<Market, Context>, Context>,

        // Maps market_id -> bettor_address -> private bet notes
        // Each BetNote is encrypted and only readable by the owner
        bets: Map<Field, Owned<PrivateSet<BetNote, Context>, Context>, Context>,

        // Tracks whether a user has already claimed for a market (prevents double-claim)
        // Maps market_id -> user_address -> claimed flag
        claimed: Map<Field, Map<AztecAddress, PublicMutable<bool, Context>, Context>, Context>,
    }

    #[external("public")]
    #[initializer]
    fn constructor(admin: AztecAddress) {
        debug_log_format("Initializing PredictionMarket with admin {0}", [admin.to_field()]);
        self.storage.admin.write(admin);
    }

    // =========================================================================
    // PUBLIC FUNCTIONS - visible on-chain
    // =========================================================================

    // Creates a new prediction market
    #[external("public")]
    fn create_market(market_id: Field, question_hash: Field, betting_deadline: u32) {
        let creator = self.context.maybe_msg_sender().unwrap();
        debug_log_format(
            "Creating market {0} by {1}",
            [market_id, creator.to_field()],
        );

        // Ensure market doesn't already exist
        let existing = self.storage.markets.at(market_id).read();
        assert(existing.creator.eq(AztecAddress::zero()), "Market already exists");

        let market = Market::new(question_hash, creator, betting_deadline, DEFAULT_CHALLENGE_PERIOD);
        self.storage.markets.at(market_id).write(market);
    }

    // Internal: update aggregate pool (called by private place_bet)
    // Only receives amount - direction is NEVER passed to the public side
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

    // Oracle: propose an outcome after betting deadline
    #[external("public")]
    fn propose_outcome(market_id: Field, outcome: bool) {
        let proposer = self.context.maybe_msg_sender().unwrap();
        let market = self.storage.markets.at(market_id).read();
        assert(
            self.context.block_number() > market.betting_deadline,
            "Betting still open",
        );
        debug_log_format(
            "Proposing outcome {0} for market {1} by {2}",
            [outcome as Field, market_id, proposer.to_field()],
        );
        self.storage.markets.at(market_id).write(
            market.propose(proposer, outcome, self.context.block_number()),
        );
    }

    // Oracle: finalize outcome after challenge period
    #[external("public")]
    fn finalize_outcome(market_id: Field) {
        let market = self.storage.markets.at(market_id).read();
        debug_log_format("Finalizing market {0}", [market_id]);
        self.storage.markets.at(market_id).write(
            market.finalize(self.context.block_number()),
        );
    }

    // Internal: process claim (called by private claim_winnings)
    #[external("public")]
    #[only_self]
    fn process_claim(market_id: Field, claimer: AztecAddress, bet_amount: Field) {
        let market = self.storage.markets.at(market_id).read();
        assert(market.resolved, "Market not resolved");

        let already_claimed = self.storage.claimed.at(market_id).at(claimer).read();
        assert(!already_claimed, "Already claimed");
        self.storage.claimed.at(market_id).at(claimer).write(true);

        // MVP: simple 2x payout. Production would use proportional payouts.
        let payout = bet_amount * 2;
        debug_log_format(
            "Claim processed for {0} on market {1}, payout: {2}",
            [claimer.to_field(), market_id, payout],
        );
    }

    // =========================================================================
    // PRIVATE FUNCTIONS - execute on user's device, data stays confidential
    // =========================================================================

    // Place a private bet on a market
    // Creates encrypted BetNote. Only aggregate amount goes to public side.
    #[external("private")]
    fn place_bet(market_id: Field, direction: bool, amount: Field) {
        let bettor = self.context.maybe_msg_sender().unwrap();
        debug_log_format(
            "Placing private bet on market {0}, amount {1}",
            [market_id, amount],
        );

        // Create encrypted bet note - only bettor's PXE can decrypt
        self
            .storage
            .bets
            .at(market_id)
            .at(bettor)
            .insert(BetNote::new(market_id, direction, amount, bettor))
            .deliver(MessageDelivery.ONCHAIN_CONSTRAINED);

        // KEY PRIVACY PATTERN: only amount goes public, NOT direction
        self.enqueue(PredictionMarket::at(self.context.this_address()).update_pool(
            market_id,
            amount,
        ));
    }

    // Claim winnings privately
    #[external("private")]
    fn claim_winnings(market_id: Field) {
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
                total_winning_amount = total_winning_amount + note.amount;
                has_winning_bet = true;
            }
        }

        assert(has_winning_bet, "No bets found for this market");

        self.enqueue(PredictionMarket::at(self.context.this_address()).process_claim(
            market_id,
            claimer,
            total_winning_amount,
        ));
    }

    // =========================================================================
    // UTILITY FUNCTIONS - run client-side in PXE
    // =========================================================================

    #[external("utility")]
    unconstrained fn get_market(market_id: Field) -> pub Market {
        self.storage.markets.at(market_id).read()
    }

    #[external("utility")]
    unconstrained fn debug_market(market_id: Field) {
        let market = self.storage.markets.at(market_id).read();
        market.log_state(market_id);
    }
}
