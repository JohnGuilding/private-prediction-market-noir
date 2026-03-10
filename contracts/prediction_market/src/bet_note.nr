use aztec::{macros::notes::note, protocol::{traits::Packable, address::AztecAddress}};

// BetNote stores a user's private bet on a prediction market.
// This note is encrypted and stored in the note hash tree - only the owner's PXE can decrypt it.
// The direction (yes/no) and amount are never revealed on-chain.
#[derive(Eq, Packable)]
#[note]
pub struct BetNote {
    // The market this bet is for
    pub market_id: Field,
    // true = YES, false = NO
    pub direction: bool,
    // Amount wagered
    pub amount: Field,
    // The bettor - only they can read this note
    pub owner: AztecAddress,
}

impl BetNote {
    pub fn new(market_id: Field, direction: bool, amount: Field, owner: AztecAddress) -> Self {
        Self { market_id, direction, amount, owner }
    }
}
