// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

/// @title Sealed-Bid Uniform-Price Batch Auction
/// @notice Single-instance commit-reveal auction. Bidders commit hashed bids with escrowed
/// payment collateral, reveal them, and a permissionless settler submits the canonical sort
/// order for on-chain verification. Fills proceed top-down until `supply` is exhausted and
/// every winner pays one uniform clearing price. Mechanism: SPEC.md; owner amendments: SPEC §12.
///
/// @dev UNITS AND ROUNDING (SPEC §1.7)
/// - `price` is payment wei per 1e18 asset wei (a WAD price); `quantity` and `fill` are asset
///   wei. Both tokens are assumed 18-decimal, WAD-scaled.
/// - Payments always round UP (`mulDivUp`); fills are exact integers. Rounding dust favors
///   solvency, never the claimant.
/// - `uint128 * uint128` fits in 256 bits, so `price * quantity` cannot overflow.
/// - Exact conservation once SETTLED and fully drained:
///   `sum(deposits) == sum(refunds) + proceeds + forfeits` (payment token) and
///   `supply == sum(fills) + sellerRemainder` (asset token). Equalities, not bounds.
///
/// @dev COMPLETENESS LEMMA (SPEC §1.5 — enforced in `settle`)
/// `order` is accepted only if (i) `order.length == R`, the number of revealed bids,
/// (ii) every entry is `< R`, and (iii) no entry repeats (memory bitmap, check-and-set).
/// Any array passing all three is a permutation of [0, R): R distinct values drawn from a
/// universe of exactly R values must hit each value exactly once (pigeonhole). A settler who
/// omits a high bid to drag the clearing price down must therefore violate length, range, or
/// distinctness somewhere — each with its own revert. The ordering predicate (price strictly
/// descending; equal prices -> reveal index strictly ascending) is a strict total order over
/// bids, so exactly ONE permutation passes: any accepted settlement is THE canonical one,
/// regardless of who submits it. Corollary: all checks run over the ENTIRE array, including
/// entries after supply exhaustion — an early exit would let a duplicate hide in the
/// unvalidated tail and reopen the omission attack.
///
/// @dev REFUND-UNDERFLOW LEMMA (SPEC §1.7 — enforced in `claimBidder`)
/// A winner is charged `pay = mulDivUp(clearingPrice, fill, 1e18)`. The canonical order is
/// price-descending and every winner sits at or above the marginal position, so
/// `clearingPrice <= price`; fills never exceed revealed quantity, so `fill <= quantity`.
/// `mulDivUp` is monotone in both multiplicands, hence
/// `pay <= mulDivUp(price, quantity, 1e18) = maxSpend`, and reveal enforced
/// `deposit >= maxSpend`. Therefore `deposit - pay` cannot underflow — plain subtraction,
/// no saturation.
contract SealedBidAuction {
    using SafeTransferLib for ERC20;

    // ---- Types ----

    /// @dev Derived from `block.timestamp` and `settled` — never stored (SPEC §1.2).
    enum Phase {
        Commit,
        Reveal,
        SettleWindow,
        Settled,
        Void
    }

    struct Commitment {
        address bidder;
        uint96 revealIdx; // SPEC §12 A4: set at reveal; meaningful only when `revealed`
        bytes32 commitHash;
        uint256 deposit;
        bool revealed;
        bool claimed;
    }

    struct Bid {
        uint256 commitId;
        uint128 price; // payment wei per 1e18 asset wei
        uint128 quantity; // asset wei
        uint128 fill; // asset wei, written at settle
    }

    // ---- Constants ----

    uint256 internal constant WAD = 1e18;

    /// @dev Forfeited (unrevealed) deposits are burned here, not paid to the seller (SPEC §2).
    address internal constant FORFEIT_SINK = address(0xdEaD);

    // ---- Config (SPEC §1.1, all immutable; requires amended by SPEC §12 A1/A2) ----

    ERC20 public immutable asset;
    ERC20 public immutable payment;
    uint128 public immutable supply;
    uint128 public immutable reservePrice;
    uint64 public immutable commitEnd;
    uint64 public immutable revealEnd;
    uint64 public immutable settleDeadline;
    uint32 public immutable maxBids;
    address public immutable seller;

    // ---- Storage (SPEC §5) ----

    Commitment[] internal commits; // index = commitId
    Bid[] internal bids; // index = revealIdx, dense in [0, R)
    uint256 public totalDeposits;
    uint256 public revealedDeposits;
    bool public settled;
    bool public sellerClaimed;
    bool public forfeitsSwept;
    uint128 public clearingPrice;
    uint128 public totalSold;
    uint256 public proceeds;

    // ---- Errors (SPEC §5; BadConfig added for constructor validation, see PLAN D6) ----

    error BadConfig();
    error WrongPhase();
    error BadCommit(); // exists / already revealed / not yours / hash mismatch
    error BadBid(); // qty == 0 || price < reserve || deposit < maxSpend
    error MaxBidsReached();
    error BadSettlementLength();
    error DuplicateEntry();
    error OutOfRange();
    error BadOrdering();
    error AlreadySettled();
    error AlreadyClaimed();
    error NothingToClaim();

    // ---- Events (SPEC §5) ----

    event Committed(uint256 indexed commitId, address indexed bidder, uint256 deposit);
    event Revealed(
        uint256 indexed commitId, uint256 indexed revealIdx, uint128 price, uint128 quantity
    );
    event Settled(uint128 clearingPrice, uint128 totalSold, uint256 proceeds);
    event BidderClaimed(uint256 indexed commitId, uint256 assetOut, uint256 paymentOut);
    event SellerClaimed(uint256 proceeds, uint256 assetReturned);
    event ForfeitsBurned(uint256 amount);

    // ---- Constructor ----

    /// @notice Deployer is the seller; pulls `supply_` of `asset_` — approve first.
    /// @param asset_ Token being sold.
    /// @param payment_ Token bids are denominated and deposited in.
    /// @param supply_ Amount of `asset_` for sale, in asset wei.
    /// @param reservePrice_ Minimum acceptable WAD bid price; enforced at reveal (SPEC §1.4).
    /// @param commitEnd_ Commit phase closes (inclusive).
    /// @param revealEnd_ Reveal phase closes (inclusive).
    /// @param settleDeadline_ Last moment `settle` may be called; after this, VOID.
    /// @param maxBids_ Cap on total commits (SPEC §2 grief bound; sized from the gas table).
    constructor(
        ERC20 asset_,
        ERC20 payment_,
        uint128 supply_,
        uint128 reservePrice_,
        uint64 commitEnd_,
        uint64 revealEnd_,
        uint64 settleDeadline_,
        uint32 maxBids_
    ) {
        // SPEC §1.1
        if (commitEnd_ >= revealEnd_ || revealEnd_ >= settleDeadline_) revert BadConfig();
        if (supply_ == 0) revert BadConfig();
        // SPEC §12 A1 — deliberate deviation from §1.1, which permits a zero reserve. A zero
        // reserve lets zero-price bids reveal against zero deposits and, in the
        // demand-shortfall case, clears the whole auction at price 0.
        if (reservePrice_ == 0) revert BadConfig();
        // SPEC §12 A2 — misdeployment guards, no mechanism impact.
        if (commitEnd_ <= block.timestamp) revert BadConfig();
        if (maxBids_ == 0) revert BadConfig();

        asset = asset_;
        payment = payment_;
        supply = supply_;
        reservePrice = reservePrice_;
        commitEnd = commitEnd_;
        revealEnd = revealEnd_;
        settleDeadline = settleDeadline_;
        maxBids = maxBids_;
        seller = msg.sender;

        asset_.safeTransferFrom(msg.sender, address(this), supply_);
    }
}
