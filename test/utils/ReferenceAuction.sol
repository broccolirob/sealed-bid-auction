// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ReferenceAuction — differential oracle for SealedBidAuction (SPEC §6.3)
/// @notice In-memory, gas-oblivious reference for the auction's settlement math. Given the
/// revealed bids in reveal-index order, it computes the canonical sort, fills, clearing
/// price, per-winner payments, and proceeds. O(n²) insertion sort — obviously correct by
/// inspection is the point; the real contract is differential-tested against this.
/// @dev Rounding matches SPEC §1.7 (payments round UP) but is implemented independently of
/// the contract: differential value comes from independent logic under an identical rule.
///
/// Preconditions mirrored from the contract (not re-checked here):
/// - every `quantity > 0` (reveal rejects zero quantities, SPEC §1.4);
/// - `supply > 0` (constructor, SPEC §1.1).
/// Under these, fills are strictly positive on a prefix of the canonical order, so the
/// marginal (lowest filled) bid is always well-defined when there is at least one bid.
library ReferenceAuction {
    uint256 internal constant WAD = 1e18;

    /// @dev A revealed bid; array position = reveal index.
    struct RefBid {
        uint128 price; // payment wei per 1e18 asset wei
        uint128 quantity; // asset wei
    }

    struct RefResult {
        uint256[] order; // the unique canonical permutation of [0, R)
        uint128[] fill; // per reveal index, asset wei (0 for losers)
        uint256[] payment; // per reveal index, payment wei (0 for losers)
        uint128 clearingPrice; // 0 iff nothing sold
        uint128 totalSold;
        uint256 proceeds; // == sum(payment), by construction
    }

    /// @notice Full settlement: canonical sort, top-down fill, uniform clearing, payments.
    function settle(RefBid[] memory bids, uint128 supply)
        internal
        pure
        returns (RefResult memory r)
    {
        uint256 n = bids.length;
        r.order = sortIndices(bids);
        r.fill = new uint128[](n);
        r.payment = new uint256[](n);
        if (n == 0) return r; // trivial settle: clearing 0, nothing sold (SPEC §1.5)

        // Top-down fill along the canonical order.
        uint128 cum = 0;
        uint256 lastFilledPos = 0;
        for (uint256 pos = 0; pos < n; pos++) {
            uint128 remaining = supply - cum;
            uint128 qty = bids[r.order[pos]].quantity;
            uint128 f = qty < remaining ? qty : remaining;
            if (f > 0) {
                r.fill[r.order[pos]] = f;
                cum += f;
                lastFilledPos = pos;
            }
        }
        if (cum == 0) return r; // unreachable under preconditions; kept for totality

        // The marginal (lowest filled) bid prices everyone.
        r.clearingPrice = bids[r.order[lastFilledPos]].price;
        r.totalSold = cum;

        // Proceeds = exact sum of per-winner payments (SPEC §1.5 pass 2). Deliberately
        // iterates reveal indices, not order positions — structurally independent of the
        // contract's implementation.
        for (uint256 i = 0; i < n; i++) {
            if (r.fill[i] > 0) {
                uint256 pay = mulDivUp(r.clearingPrice, r.fill[i], WAD);
                r.payment[i] = pay;
                r.proceeds += pay;
            }
        }
    }

    /// @notice The unique permutation of [0, n) ordered by (price desc, reveal index asc).
    /// @dev Insertion sort. The comparator is a strict total order (no two indices compare
    /// equal), so the output is deterministic and stability is irrelevant.
    function sortIndices(RefBid[] memory bids) internal pure returns (uint256[] memory order) {
        uint256 n = bids.length;
        order = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            order[i] = i;
        }
        for (uint256 i = 1; i < n; i++) {
            uint256 key = order[i];
            uint256 j = i;
            while (j > 0 && precedes(bids, key, order[j - 1])) {
                order[j] = order[j - 1];
                j--;
            }
            order[j] = key;
        }
    }

    /// @dev True iff bid `a` comes strictly before bid `b` in the canonical order:
    /// higher price first; equal prices resolved by lower reveal index (earlier reveal wins).
    function precedes(RefBid[] memory bids, uint256 a, uint256 b) internal pure returns (bool) {
        if (bids[a].price != bids[b].price) return bids[a].price > bids[b].price;
        return a < b;
    }

    /// @notice Ceiling of x*y/d — the SPEC §1.7 payment rounding rule, implemented
    /// independently of the contract (which uses solmate's mulDivUp).
    /// @dev Valid for x, y < 2^128 with d = 1e18: x*y <= (2^128 - 1)^2 = 2^256 - 2^129 + 1,
    /// and adding d - 1 < 2^129 still fits in 256 bits, so the naive form cannot overflow.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }
}
