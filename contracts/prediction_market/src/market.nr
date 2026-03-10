use ::aztec::oracle::logging::debug_log_format;
use ::aztec::protocol::{
    address::AztecAddress,
    traits::{Deserialize, Serialize, Packable, ToField},
};

// Market stores the public state of a prediction market.
// All fields here are visible on-chain. Notably, individual bet directions are NOT stored here.
#[derive(Deserialize, Serialize, Eq, Packable)]
pub struct Market {
    // Hash of the market question (e.g. keccak("Will ETH be above $5000?"))
    pub question_hash: Field,
    // Creator of the market
    pub creator: AztecAddress,
    // Block number after which no more bets are accepted
    pub betting_deadline: u32,
    // Total pool size (sum of all bet amounts, without direction info)
    pub total_pool: Field,
    // Number of bets placed (for stats, no direction leaked)
    pub num_bets: u32,

    // Oracle resolution fields
    pub resolved: bool,
    pub outcome: bool, // true = YES won, false = NO won
    pub proposer: AztecAddress,
    pub proposed_outcome: bool,
    pub proposal_block: u32,
    // Challenge period length in blocks
    pub challenge_period: u32,
}

impl Market {
    pub fn new(
        question_hash: Field,
        creator: AztecAddress,
        betting_deadline: u32,
        challenge_period: u32,
    ) -> Self {
        Self {
            question_hash,
            creator,
            betting_deadline,
            total_pool: 0,
            num_bets: 0,
            resolved: false,
            outcome: false,
            proposer: AztecAddress::zero(),
            proposed_outcome: false,
            proposal_block: 0,
            challenge_period,
        }
    }

    // Add a bet amount to the pool (direction is NOT passed - privacy preserved)
    pub fn add_bet(self, amount: Field) -> Self {
        Self {
            question_hash: self.question_hash,
            creator: self.creator,
            betting_deadline: self.betting_deadline,
            total_pool: self.total_pool + amount,
            num_bets: self.num_bets + 1,
            resolved: self.resolved,
            outcome: self.outcome,
            proposer: self.proposer,
            proposed_outcome: self.proposed_outcome,
            proposal_block: self.proposal_block,
            challenge_period: self.challenge_period,
        }
    }

    // Set the proposed outcome for oracle resolution
    pub fn propose(self, proposer: AztecAddress, outcome: bool, current_block: u32) -> Self {
        assert(!self.resolved, "Market already resolved");
        assert(self.proposer.eq(AztecAddress::zero()), "Outcome already proposed");
        Self {
            question_hash: self.question_hash,
            creator: self.creator,
            betting_deadline: self.betting_deadline,
            total_pool: self.total_pool,
            num_bets: self.num_bets,
            resolved: false,
            outcome: self.outcome,
            proposer,
            proposed_outcome: outcome,
            proposal_block: current_block,
            challenge_period: self.challenge_period,
        }
    }

    // Finalize the outcome after the challenge period has passed
    pub fn finalize(self, current_block: u32) -> Self {
        assert(!self.resolved, "Market already resolved");
        assert(!self.proposer.eq(AztecAddress::zero()), "No outcome proposed");
        assert(
            current_block >= self.proposal_block + self.challenge_period,
            "Challenge period not over",
        );
        Self {
            question_hash: self.question_hash,
            creator: self.creator,
            betting_deadline: self.betting_deadline,
            total_pool: self.total_pool,
            num_bets: self.num_bets,
            resolved: true,
            outcome: self.proposed_outcome,
            proposer: self.proposer,
            proposed_outcome: self.proposed_outcome,
            proposal_block: self.proposal_block,
            challenge_period: self.challenge_period,
        }
    }

    pub fn log_state(self, market_id: Field) {
        debug_log_format("=== Market {0} ===", [market_id]);
        debug_log_format("Question hash: {0}", [self.question_hash]);
        debug_log_format("Creator: {0}", [self.creator.to_field()]);
        debug_log_format("Deadline block: {0}", [self.betting_deadline as Field]);
        debug_log_format("Total pool: {0}", [self.total_pool]);
        debug_log_format("Num bets: {0}", [self.num_bets as Field]);
        debug_log_format("Resolved: {0}", [self.resolved as Field]);
        debug_log_format("Outcome: {0}", [self.outcome as Field]);
    }
}
