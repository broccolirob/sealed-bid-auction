// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
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

    // ---- Bidding ----

    /// @notice Commit a hashed bid, escrowing `deposit` of `payment` (SPEC §1.3).
    /// @dev `h = keccak256(abi.encode(address(this), msg.sender, price, quantity, salt))`.
    /// `address(this)` blocks cross-deployment replay; `msg.sender` makes hash-copying a pure
    /// self-grief (the copier can never open it). Multiple commits per address are
    /// independent bids. Deposits may exceed the bid's max spend — over-depositing is the
    /// bidder's obfuscation lever against the deposit-size leak.
    function commit(bytes32 h, uint256 deposit) external returns (uint256 commitId) {
        if (phase() != Phase.Commit) revert WrongPhase();
        commitId = commits.length;
        if (commitId >= maxBids) revert MaxBidsReached();

        commits.push(
            Commitment({
                bidder: msg.sender,
                revealIdx: 0,
                commitHash: h,
                deposit: deposit,
                revealed: false,
                claimed: false
            })
        );
        totalDeposits += deposit;
        emit Committed(commitId, msg.sender, deposit);

        payment.safeTransferFrom(msg.sender, address(this), deposit);
    }

    /// @notice Open commitment `commitId` as a bid at `price` for `quantity` (SPEC §1.4).
    /// @dev The reserve is enforced here, not at settlement — every bid that reaches
    /// settlement is already eligible. The deposit must cover
    /// `maxSpend = mulDivUp(price, quantity, 1e18)`; uint128 inputs cannot overflow the
    /// product. The bid's reveal index is recorded on the commitment (SPEC §12 A4) so claims
    /// are O(1).
    function reveal(uint256 commitId, uint128 price, uint128 quantity, bytes32 salt)
        external
        returns (uint256 revealIdx)
    {
        if (phase() != Phase.Reveal) revert WrongPhase();
        if (commitId >= commits.length) revert BadCommit();
        Commitment storage c = commits[commitId];
        if (c.revealed) revert BadCommit();
        if (c.bidder != msg.sender) revert BadCommit();
        if (keccak256(abi.encode(address(this), msg.sender, price, quantity, salt)) != c.commitHash)
        {
            revert BadCommit();
        }
        if (quantity == 0 || price < reservePrice) revert BadBid();
        if (c.deposit < FixedPointMathLib.mulDivUp(price, quantity, WAD)) revert BadBid();

        revealIdx = bids.length;
        c.revealed = true;
        c.revealIdx = uint96(revealIdx); // safe: revealIdx < maxBids <= type(uint32).max
        bids.push(Bid({commitId: commitId, price: price, quantity: quantity, fill: 0}));
        revealedDeposits += c.deposit;
        emit Revealed(commitId, revealIdx, price, quantity);
    }

    // ---- Settlement (SPEC §1.5) ----

    /// @notice Settle the auction. Permissionless, once, during SETTLE-WINDOW. `order` must
    /// be the canonical sort of ALL reveal indices: strictly descending price, ties broken
    /// by ascending reveal index. Exactly one permutation passes — settlement output is
    /// deterministic regardless of who calls.
    /// @dev Two O(R) passes: verify + fill, then proceeds. `proceeds` is the exact sum of
    /// per-winner payments (not one rounded product), which makes payment conservation an
    /// equality. No external calls — CEI is trivial here.
    function settle(uint256[] calldata order) external {
        Phase p = phase();
        if (p == Phase.Settled) revert AlreadySettled();
        if (p != Phase.SettleWindow) revert WrongPhase();

        uint256 r = bids.length;
        if (order.length != r) revert BadSettlementLength();

        settled = true;

        if (r == 0) {
            // trivial settle: nothing revealed, seller reclaims everything via claimSeller
            emit Settled(0, 0, 0);
            return;
        }

        // COMPLETENESS LEMMA (SPEC §1.5). `order` is accepted only if
        //   (i)   order.length == R          (checked above),
        //   (ii)  every entry < R            (range check below),
        //   (iii) no entry repeats           (bitmap check-and-set below).
        // R distinct values drawn from a universe of exactly R values must hit each value
        // exactly once (pigeonhole), so any accepted `order` is a permutation of [0, R):
        // omitting a high bid to drag the clearing price down forces a length, range, or
        // duplicate violation somewhere — each with its own revert. The ordering predicate
        // is a strict total order (no two bids tie on (price, revealIdx)), so exactly ONE
        // permutation passes. Corollary (PLAN D2): every check runs over the ENTIRE array,
        // including entries after supply exhaustion — an early exit would let a duplicate
        // hide in the unvalidated tail and reopen the omission attack.
        uint256[] memory seen = new uint256[]((r + 255) >> 8);

        uint128 supply_ = supply;
        uint128 cum = 0;
        uint256 lastFilledPos = 0;
        uint256 prevIdx = 0;
        uint128 prevPrice = 0;

        for (uint256 pos = 0; pos < r; pos++) {
            uint256 idx = order[pos];
            if (idx >= r) revert OutOfRange();

            uint256 word = idx >> 8;
            uint256 bit = 1 << (idx & 0xff);
            if (seen[word] & bit != 0) revert DuplicateEntry();
            seen[word] |= bit;

            Bid storage b = bids[idx];
            uint128 price = b.price;
            // canonical predicate vs the previous entry (SPEC §1.5):
            //   bids[b].price < bids[a].price || (equal && b > a)
            if (pos > 0 && !(price < prevPrice || (price == prevPrice && idx > prevIdx))) {
                revert BadOrdering();
            }
            prevIdx = idx;
            prevPrice = price;

            // Fill top-down. Only the fill SSTORE is skipped once supply is exhausted —
            // validation continues over the whole array (see lemma corollary above).
            if (cum < supply_) {
                uint128 remaining = supply_ - cum;
                uint128 qty = b.quantity;
                uint128 f = qty < remaining ? qty : remaining;
                b.fill = f; // f > 0: remaining > 0 and qty > 0 (reveal enforced)
                cum += f;
                lastFilledPos = pos;
            }
        }

        // The marginal (lowest filled) bid prices everyone. Well-defined: r > 0, supply > 0
        // and every quantity > 0 mean position 0 always fills.
        uint128 clearing = bids[order[lastFilledPos]].price;

        // Pass 2 — proceeds as the exact sum of per-winner payments. Positions
        // 0..lastFilledPos all have fill > 0 (fills are a prefix of the canonical order).
        uint256 total = 0;
        for (uint256 pos = 0; pos <= lastFilledPos; pos++) {
            total += FixedPointMathLib.mulDivUp(clearing, bids[order[pos]].fill, WAD);
        }

        clearingPrice = clearing;
        totalSold = cum;
        proceeds = total;
        emit Settled(clearing, cum, total);
    }

    // ---- Claims (SPEC §1.6: pull-only, CEI, one-shot; §12 A3: permissionless) ----

    /// @notice Pay out commitment `commitId`'s entitlement. Callable by anyone; funds always
    /// go to the recorded bidder. SETTLED: winners receive `fill` of asset plus
    /// `deposit - pay` of payment, revealed losers their full deposit, non-revealers nothing
    /// (deposit forfeited to the sweep). VOID: full deposit back for everyone.
    /// @dev REFUND-UNDERFLOW LEMMA (SPEC §1.7). For any winner `clearingPrice <= price`
    /// (canonical order is price-descending and winners sit at or above the marginal bid)
    /// and `fill <= quantity`; `mulDivUp` is monotone in both multiplicands, so
    /// `pay = mulDivUp(clearingPrice, fill, 1e18) <= mulDivUp(price, quantity, 1e18)
    /// = maxSpend <= deposit` (enforced at reveal). `deposit - pay` cannot underflow.
    function claimBidder(uint256 commitId) external {
        Phase p = phase();
        if (p != Phase.Settled && p != Phase.Void) revert WrongPhase();
        if (commitId >= commits.length) revert BadCommit();
        Commitment storage c = commits[commitId];
        if (c.claimed) revert AlreadyClaimed();

        uint256 assetOut;
        uint256 paymentOut;
        if (p == Phase.Void) {
            paymentOut = c.deposit; // full refund, revealed or not — VOID punishes nobody
        } else if (c.revealed) {
            Bid storage b = bids[c.revealIdx];
            assetOut = b.fill; // 0 for losers, so this branch covers winner and loser alike
            paymentOut = c.deposit - FixedPointMathLib.mulDivUp(clearingPrice, b.fill, WAD);
        } else {
            revert NothingToClaim(); // forfeited; burned in aggregate by sweepForfeits
        }

        c.claimed = true;
        emit BidderClaimed(commitId, assetOut, paymentOut);
        if (assetOut > 0) asset.safeTransfer(c.bidder, assetOut);
        if (paymentOut > 0) payment.safeTransfer(c.bidder, paymentOut);
    }

    /// @notice Pay the seller. Callable by anyone; funds always go to `seller`.
    /// SETTLED: `proceeds` of payment plus the unsold `supply - totalSold` of asset.
    /// VOID: the full supply back.
    function claimSeller() external {
        Phase p = phase();
        if (p != Phase.Settled && p != Phase.Void) revert WrongPhase();
        if (sellerClaimed) revert AlreadyClaimed();
        sellerClaimed = true;

        uint256 paymentOut;
        uint256 assetOut;
        if (p == Phase.Void) {
            assetOut = supply;
        } else {
            paymentOut = proceeds;
            assetOut = supply - totalSold;
        }
        emit SellerClaimed(paymentOut, assetOut);
        if (paymentOut > 0) payment.safeTransfer(seller, paymentOut);
        if (assetOut > 0) asset.safeTransfer(seller, assetOut);
    }

    /// @notice Burn all forfeited (unrevealed) deposits. SETTLED only, once, callable by
    /// anyone. Forfeits go to the sink, not the seller — routing them to the seller would
    /// make phantom demand-signaling commits free (SPEC §2). In VOID forfeits don't exist:
    /// a failed auction punishes nobody.
    /// @dev O(1): `totalDeposits` accrues at commit, `revealedDeposits` at reveal; the
    /// difference is exactly the unrevealed deposits. A zero-forfeit sweep succeeds (burns
    /// nothing) so the function is total in the SETTLED state.
    function sweepForfeits() external {
        if (phase() != Phase.Settled) revert WrongPhase();
        if (forfeitsSwept) revert AlreadyClaimed();
        forfeitsSwept = true;

        uint256 amount = totalDeposits - revealedDeposits;
        emit ForfeitsBurned(amount);
        if (amount > 0) payment.safeTransfer(FORFEIT_SINK, amount);
    }

    // ---- Views (SPEC §5) ----

    /// @notice Current phase, derived from `block.timestamp` and `settled` (SPEC §1.2) —
    /// no stored phase variable to desynchronize. All boundaries are inclusive.
    function phase() public view returns (Phase) {
        if (settled) return Phase.Settled;
        uint256 t = block.timestamp;
        if (t <= commitEnd) return Phase.Commit;
        if (t <= revealEnd) return Phase.Reveal;
        if (t <= settleDeadline) return Phase.SettleWindow;
        return Phase.Void;
    }

    /// @notice Number of revealed bids, R. Reveal indices are dense in [0, R).
    function revealedCount() external view returns (uint256) {
        return bids.length;
    }

    function getBid(uint256 revealIdx) external view returns (Bid memory) {
        return bids[revealIdx];
    }

    function getCommitment(uint256 commitId) external view returns (Commitment memory) {
        return commits[commitId];
    }
}
