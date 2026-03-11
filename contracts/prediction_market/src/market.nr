use ::aztec::oracle::logging::debug_log_format;
use ::aztec::protocol::{
    address::AztecAddress,
    traits::{Deserialize, Serialize, Packable, ToField},
};

// Maximum number of outcomes per market
pub global MAX_OUTCOMES: u32 = 8;

// Market status enum
global STATUS_OPEN: u8 = 0;
global STATUS_PROPOSED: u8 = 2;
global STATUS_CHALLENGED: u8 = 3;
global STATUS_FINALIZED: u8 = 4;

// Market stores the public state of a prediction market.
// Privacy: no per-outcome breakdown is stored. Only total_pool is visible during betting.
// After finalization, winners reveal bets to build revealed_winning_pool for payout calculation.
#[derive(Deserialize, Serialize, Eq, Packable)]
pub struct Market {
    pub question_hash: Field,
    pub creator: AztecAddress,
    pub betting_deadline: u32,
    pub num_outcomes: u8,
    pub total_pool: Field,
    pub num_bets: u32,
    pub status: u8,
    pub winning_outcome: u8,
    pub proposer: AztecAddress,
    pub proposed_outcome: u8,
    pub proposal_block: u32,
    pub challenge_period: u32,
    pub bond_amount: Field,
    pub challenger: AztecAddress,
    pub challenged_outcome: u8,
    pub fee_rate: u32,
    pub revealed_winning_pool: Field,
    pub reveal_deadline: u32,
    pub reveal_period: u32,
}

impl Market {
    pub fn new(
        question_hash: Field,
        creator: AztecAddress,
        betting_deadline: u32,
        num_outcomes: u8,
        challenge_period: u32,
        bond_amount: Field,
        fee_rate: u32,
        reveal_period: u32,
    ) -> Self {
        assert(num_outcomes >= 2, "Must have at least 2 outcomes");
        assert(num_outcomes as u32 <= MAX_OUTCOMES, "Too many outcomes");

        Self {
            question_hash,
            creator,
            betting_deadline,
            num_outcomes,
            total_pool: 0,
            num_bets: 0,
            status: STATUS_OPEN,
            winning_outcome: 0,
            proposer: AztecAddress::zero(),
            proposed_outcome: 0,
            proposal_block: 0,
            challenge_period,
            bond_amount,
            challenger: AztecAddress::zero(),
            challenged_outcome: 0,
            fee_rate,
            revealed_winning_pool: 0,
            reveal_deadline: 0,
            reveal_period,
        }
    }

    pub fn add_bet(self, amount: Field) -> Self {
        assert(self.status == STATUS_OPEN, "Market not open for betting");

        Self {
            question_hash: self.question_hash,
            creator: self.creator,
            betting_deadline: self.betting_deadline,
            num_outcomes: self.num_outcomes,
            total_pool: self.total_pool + amount,
            num_bets: self.num_bets + 1,
            status: self.status,
            winning_outcome: self.winning_outcome,
            proposer: self.proposer,
            proposed_outcome: self.proposed_outcome,
            proposal_block: self.proposal_block,
            challenge_period: self.challenge_period,
            bond_amount: self.bond_amount,
            challenger: self.challenger,
            challenged_outcome: self.challenged_outcome,
            fee_rate: self.fee_rate,
            revealed_winning_pool: self.revealed_winning_pool,
            reveal_deadline: self.reveal_deadline,
            reveal_period: self.reveal_period,
        }
    }

    pub fn propose(self, proposer: AztecAddress, outcome: u8, current_block: u32) -> Self {
        assert(self.status == STATUS_OPEN, "Cannot propose in current state");
        assert(self.proposer.eq(AztecAddress::zero()), "Outcome already proposed");
        assert((outcome as u32) < (self.num_outcomes as u32), "Invalid outcome");

        Self {
            question_hash: self.question_hash,
            creator: self.creator,
            betting_deadline: self.betting_deadline,
            num_outcomes: self.num_outcomes,
            total_pool: self.total_pool,
            num_bets: self.num_bets,
            status: STATUS_PROPOSED,
            winning_outcome: self.winning_outcome,
            proposer,
            proposed_outcome: outcome,
            proposal_block: current_block,
            challenge_period: self.challenge_period,
            bond_amount: self.bond_amount,
            challenger: self.challenger,
            challenged_outcome: self.challenged_outcome,
            fee_rate: self.fee_rate,
            revealed_winning_pool: self.revealed_winning_pool,
            reveal_deadline: self.reveal_deadline,
            reveal_period: self.reveal_period,
        }
    }

    pub fn challenge(
        self,
        challenger: AztecAddress,
        counter_outcome: u8,
        current_block: u32,
    ) -> Self {
        assert(self.status == STATUS_PROPOSED, "Not in proposed state");
        assert(
            current_block < self.proposal_block + self.challenge_period,
            "Challenge period expired",
        );
        assert((counter_outcome as u32) < (self.num_outcomes as u32), "Invalid counter outcome");
        assert(counter_outcome != self.proposed_outcome, "Cannot challenge with same outcome");

        Self {
            question_hash: self.question_hash,
            creator: self.creator,
            betting_deadline: self.betting_deadline,
            num_outcomes: self.num_outcomes,
            total_pool: self.total_pool,
            num_bets: self.num_bets,
            status: STATUS_CHALLENGED,
            winning_outcome: self.winning_outcome,
            proposer: self.proposer,
            proposed_outcome: self.proposed_outcome,
            proposal_block: self.proposal_block,
            challenge_period: self.challenge_period,
            bond_amount: self.bond_amount,
            challenger,
            challenged_outcome: counter_outcome,
            fee_rate: self.fee_rate,
            revealed_winning_pool: self.revealed_winning_pool,
            reveal_deadline: self.reveal_deadline,
            reveal_period: self.reveal_period,
        }
    }

    pub fn finalize(self, current_block: u32) -> Self {
        assert(self.status == STATUS_PROPOSED, "Not in proposed state");
        assert(!self.proposer.eq(AztecAddress::zero()), "No outcome proposed");
        assert(
            current_block >= self.proposal_block + self.challenge_period,
            "Challenge period not over",
        );

        Self {
            question_hash: self.question_hash,
            creator: self.creator,
            betting_deadline: self.betting_deadline,
            num_outcomes: self.num_outcomes,
            total_pool: self.total_pool,
            num_bets: self.num_bets,
            status: STATUS_FINALIZED,
            winning_outcome: self.proposed_outcome,
            proposer: self.proposer,
            proposed_outcome: self.proposed_outcome,
            proposal_block: self.proposal_block,
            challenge_period: self.challenge_period,
            bond_amount: self.bond_amount,
            challenger: self.challenger,
            challenged_outcome: self.challenged_outcome,
            fee_rate: self.fee_rate,
            revealed_winning_pool: self.revealed_winning_pool,
            reveal_deadline: current_block + self.reveal_period,
            reveal_period: self.reveal_period,
        }
    }

    pub fn arbitrate(self, winning_outcome: u8, current_block: u32) -> Self {
        assert(self.status == STATUS_CHALLENGED, "Not in challenged state");
        assert((winning_outcome as u32) < (self.num_outcomes as u32), "Invalid outcome");

        Self {
            question_hash: self.question_hash,
            creator: self.creator,
            betting_deadline: self.betting_deadline,
            num_outcomes: self.num_outcomes,
            total_pool: self.total_pool,
            num_bets: self.num_bets,
            status: STATUS_FINALIZED,
            winning_outcome,
            proposer: self.proposer,
            proposed_outcome: self.proposed_outcome,
            proposal_block: self.proposal_block,
            challenge_period: self.challenge_period,
            bond_amount: self.bond_amount,
            challenger: self.challenger,
            challenged_outcome: self.challenged_outcome,
            fee_rate: self.fee_rate,
            revealed_winning_pool: self.revealed_winning_pool,
            reveal_deadline: current_block + self.reveal_period,
            reveal_period: self.reveal_period,
        }
    }

    pub fn accumulate_reveal(self, amount: Field) -> Self {
        Self {
            question_hash: self.question_hash,
            creator: self.creator,
            betting_deadline: self.betting_deadline,
            num_outcomes: self.num_outcomes,
            total_pool: self.total_pool,
            num_bets: self.num_bets,
            status: self.status,
            winning_outcome: self.winning_outcome,
            proposer: self.proposer,
            proposed_outcome: self.proposed_outcome,
            proposal_block: self.proposal_block,
            challenge_period: self.challenge_period,
            bond_amount: self.bond_amount,
            challenger: self.challenger,
            challenged_outcome: self.challenged_outcome,
            fee_rate: self.fee_rate,
            revealed_winning_pool: self.revealed_winning_pool + amount,
            reveal_deadline: self.reveal_deadline,
            reveal_period: self.reveal_period,
        }
    }

    pub fn is_in_reveal_phase(self, current_block: u32) -> bool {
        self.is_finalized() & (current_block <= self.reveal_deadline)
    }

    pub fn is_claimable(self, current_block: u32) -> bool {
        self.is_finalized() & (current_block > self.reveal_deadline)
    }

    pub fn is_finalized(self) -> bool {
        self.status == STATUS_FINALIZED
    }

    pub fn is_open(self) -> bool {
        self.status == STATUS_OPEN
    }

    pub fn log_state(self, market_id: Field) {
        debug_log_format("=== Market {0} ===", [market_id]);
        debug_log_format("Question hash: {0}", [self.question_hash]);
        debug_log_format("Creator: {0}", [self.creator.to_field()]);
        debug_log_format("Deadline block: {0}", [self.betting_deadline as Field]);
        debug_log_format("Num outcomes: {0}", [self.num_outcomes as Field]);
        debug_log_format("Status: {0}", [self.status as Field]);
        debug_log_format("Total pool: {0}", [self.total_pool]);
        debug_log_format("Num bets: {0}", [self.num_bets as Field]);
        debug_log_format("Winning outcome: {0}", [self.winning_outcome as Field]);
        debug_log_format("Bond amount: {0}", [self.bond_amount]);
        debug_log_format("Fee rate (bps): {0}", [self.fee_rate as Field]);
        debug_log_format("Revealed winning pool: {0}", [self.revealed_winning_pool]);
        debug_log_format("Reveal deadline: {0}", [self.reveal_deadline as Field]);
    }
}
