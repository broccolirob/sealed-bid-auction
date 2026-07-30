// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReferenceAuction} from "../utils/ReferenceAuction.sol";

/// @notice Direct tests on the differential oracle itself (PLAN M1). The reference must be
/// trusted before the real contract exists: hand-computed fixtures pin sort order, fills,
/// clearing price, and rounding; property fuzzes pin canonical-permutation validity,
/// conservation, and the exact-ceil payment rule for arbitrary bid sets.
contract ReferenceAuctionTest is Test {
    uint256 internal constant WAD = 1e18;

    // ---- Sort: fixtures ----

    function test_sort_descendingByPrice() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](4);
        b[0] = ReferenceAuction.RefBid(3e18, 1e18);
        b[1] = ReferenceAuction.RefBid(5e18, 1e18);
        b[2] = ReferenceAuction.RefBid(1e18, 1e18);
        b[3] = ReferenceAuction.RefBid(4e18, 1e18);

        uint256[] memory order = ReferenceAuction.sortIndices(b);
        assertEq(order.length, 4);
        assertEq(order[0], 1); // 5e18
        assertEq(order[1], 3); // 4e18
        assertEq(order[2], 0); // 3e18
        assertEq(order[3], 2); // 1e18
    }

    function test_sort_tieBreak_earlierRevealIndexFirst() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](5);
        b[0] = ReferenceAuction.RefBid(2e18, 1e18);
        b[1] = ReferenceAuction.RefBid(3e18, 1e18);
        b[2] = ReferenceAuction.RefBid(2e18, 1e18);
        b[3] = ReferenceAuction.RefBid(3e18, 1e18);
        b[4] = ReferenceAuction.RefBid(2e18, 1e18);

        uint256[] memory order = ReferenceAuction.sortIndices(b);
        assertEq(order[0], 1); // price 3e18, earlier index
        assertEq(order[1], 3); // price 3e18, later index
        assertEq(order[2], 0); // price 2e18, indices ascending
        assertEq(order[3], 2);
        assertEq(order[4], 4);
    }

    function test_sort_allEqualPrices_identityOrder() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](4);
        for (uint256 i = 0; i < 4; i++) {
            b[i] = ReferenceAuction.RefBid(2e18, 1e18);
        }
        uint256[] memory order = ReferenceAuction.sortIndices(b);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(order[i], i);
        }
    }

    // ---- Settle: fixtures ----

    function test_settle_empty() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](0);
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, 100e18);
        assertEq(r.order.length, 0);
        assertEq(r.fill.length, 0);
        assertEq(r.payment.length, 0);
        assertEq(r.clearingPrice, 0);
        assertEq(r.totalSold, 0);
        assertEq(r.proceeds, 0);
    }

    function test_settle_singleBid_belowSupply() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](1);
        b[0] = ReferenceAuction.RefBid(2e18, 40e18);
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, 100e18);
        assertEq(r.fill[0], 40e18);
        assertEq(r.clearingPrice, 2e18);
        assertEq(r.totalSold, 40e18);
        assertEq(r.payment[0], 80e18); // 2e18 * 40e18 / 1e18, exact
        assertEq(r.proceeds, 80e18);
    }

    function test_settle_singleBid_exceedsSupply() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](1);
        b[0] = ReferenceAuction.RefBid(2e18, 80e18);
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, 50e18);
        assertEq(r.fill[0], 50e18); // capped at supply
        assertEq(r.clearingPrice, 2e18);
        assertEq(r.totalSold, 50e18);
        assertEq(r.payment[0], 100e18);
        assertEq(r.proceeds, 100e18);
    }

    function test_settle_demandExceedsSupply_marginalPartialFill() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](3);
        b[0] = ReferenceAuction.RefBid(3e18, 50e18);
        b[1] = ReferenceAuction.RefBid(5e18, 30e18);
        b[2] = ReferenceAuction.RefBid(4e18, 40e18);
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, 100e18);

        // canonical order [1, 2, 0]; idx0 is marginal with 30e18 of its 50e18
        assertEq(r.order[0], 1);
        assertEq(r.order[1], 2);
        assertEq(r.order[2], 0);
        assertEq(r.fill[1], 30e18);
        assertEq(r.fill[2], 40e18);
        assertEq(r.fill[0], 30e18);
        assertEq(r.clearingPrice, 3e18); // marginal bid's price, everyone pays it
        assertEq(r.totalSold, 100e18);
        assertEq(r.payment[1], 90e18); // 3e18 * 30e18 / 1e18
        assertEq(r.payment[2], 120e18);
        assertEq(r.payment[0], 90e18);
        assertEq(r.proceeds, 300e18);
    }

    function test_settle_demandEqualsSupply() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](2);
        b[0] = ReferenceAuction.RefBid(2e18, 30e18);
        b[1] = ReferenceAuction.RefBid(4e18, 40e18);
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, 70e18);
        assertEq(r.fill[1], 40e18);
        assertEq(r.fill[0], 30e18); // marginal, fully filled
        assertEq(r.clearingPrice, 2e18);
        assertEq(r.totalSold, 70e18);
        assertEq(r.payment[1], 80e18);
        assertEq(r.payment[0], 60e18);
        assertEq(r.proceeds, 140e18);
    }

    function test_settle_demandBelowSupply_clearsAtLowestBid() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](3);
        b[0] = ReferenceAuction.RefBid(5e18, 20e18);
        b[1] = ReferenceAuction.RefBid(2e18, 30e18);
        b[2] = ReferenceAuction.RefBid(3e18, 10e18);
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, 100e18);

        // everyone fills fully; the lowest revealed bid prices the batch
        assertEq(r.fill[0], 20e18);
        assertEq(r.fill[1], 30e18);
        assertEq(r.fill[2], 10e18);
        assertEq(r.clearingPrice, 2e18);
        assertEq(r.totalSold, 60e18);
        assertEq(r.payment[0], 40e18); // 2e18 * 20e18 / 1e18 — pays clearing, not its own 5e18
        assertEq(r.payment[1], 60e18);
        assertEq(r.payment[2], 20e18);
        assertEq(r.proceeds, 120e18);
    }

    function test_settle_supplyExhausted_zeroFillTail() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](3);
        b[0] = ReferenceAuction.RefBid(5e18, 40e18);
        b[1] = ReferenceAuction.RefBid(4e18, 10e18);
        b[2] = ReferenceAuction.RefBid(3e18, 5e18);
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, 40e18);
        assertEq(r.fill[0], 40e18);
        assertEq(r.fill[1], 0);
        assertEq(r.fill[2], 0);
        assertEq(r.clearingPrice, 5e18); // only the top bid filled — it is marginal
        assertEq(r.totalSold, 40e18);
        assertEq(r.payment[0], 200e18);
        assertEq(r.payment[1], 0);
        assertEq(r.payment[2], 0);
        assertEq(r.proceeds, 200e18);
    }

    function test_settle_tieAtMargin_earlierRevealWins() public pure {
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](2);
        b[0] = ReferenceAuction.RefBid(3e18, 30e18);
        b[1] = ReferenceAuction.RefBid(3e18, 30e18);
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, 30e18);

        // identical bids: the earlier reveal index takes the whole supply
        assertEq(r.fill[0], 30e18);
        assertEq(r.fill[1], 0); // margin-tied loser: price == clearing, fill == 0
        assertEq(r.clearingPrice, 3e18);
        assertEq(r.totalSold, 30e18);
        assertEq(r.payment[0], 90e18);
        assertEq(r.payment[1], 0);
        assertEq(r.proceeds, 90e18);
    }

    // ---- Rounding: fixtures ----

    function test_rounding_paymentRoundsUp() public pure {
        // price 1.000000000000000001, qty 1 wei: exact charge is 1.000...001e-18 payment wei,
        // which must round UP to 2 wei.
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](1);
        b[0] = ReferenceAuction.RefBid(1e18 + 1, 1);
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, 10);
        assertEq(r.fill[0], 1);
        assertEq(r.payment[0], 2);
        assertEq(r.proceeds, 2);
    }

    function test_rounding_proceedsAreSumOfPerWinnerCeils() public pure {
        // Two 1-wei-price, 1-wei-qty bids: each payment ceils to 1 wei, so proceeds are 2 —
        // NOT ceil(clearing * totalSold / WAD) == 1. Pins SPEC §1.5's "sum of per-winner
        // payments" definition, which is what makes conservation an exact equality.
        ReferenceAuction.RefBid[] memory b = new ReferenceAuction.RefBid[](2);
        b[0] = ReferenceAuction.RefBid(1, 1);
        b[1] = ReferenceAuction.RefBid(1, 1);
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, 100);
        assertEq(r.clearingPrice, 1);
        assertEq(r.payment[0], 1);
        assertEq(r.payment[1], 1);
        assertEq(r.proceeds, 2);
    }

    function test_mulDivUp_fixtures() public pure {
        assertEq(ReferenceAuction.mulDivUp(0, 5e18, WAD), 0);
        assertEq(ReferenceAuction.mulDivUp(2e18, 3e18, WAD), 6e18); // exact, no rounding
        assertEq(ReferenceAuction.mulDivUp(1, 1, WAD), 1); // tiniest dust rounds up
        assertEq(ReferenceAuction.mulDivUp(3, 5e17, WAD), 2); // ceil(1.5)
    }

    // ---- Property fuzzes ----

    function testFuzz_mulDivUp_isExactCeil(uint128 x, uint128 y) public pure {
        x = uint128(bound(x, 1, type(uint128).max));
        y = uint128(bound(y, 1, type(uint128).max));
        uint256 r = ReferenceAuction.mulDivUp(x, y, WAD);
        uint256 p = uint256(x) * uint256(y);
        // r is THE ceiling iff (r - 1) * WAD < p <= r * WAD. No overflow: p + WAD fits 256 bits
        // for uint128 inputs (see library natspec).
        assertGe(r * WAD, p);
        assertLt((r - 1) * WAD, p);
    }

    function testFuzz_sort_widePrices_isCanonicalPermutation(uint256 seed) public pure {
        ReferenceAuction.RefBid[] memory b = _genBids(seed, 20, 1, type(uint128).max);
        _assertCanonical(b, ReferenceAuction.sortIndices(b));
    }

    function testFuzz_sort_tieHeavy_isCanonicalPermutation(uint256 seed) public pure {
        // Prices drawn from {1..5} force many ties; the index tie-break must resolve all.
        ReferenceAuction.RefBid[] memory b = _genBids(seed, 20, 1, 5);
        _assertCanonical(b, ReferenceAuction.sortIndices(b));
    }

    function testFuzz_settle_properties(uint256 seed, uint128 supplyRaw) public pure {
        ReferenceAuction.RefBid[] memory b = _genBids(seed, 15, 1, 1e20);
        uint128 supply = uint128(bound(supplyRaw, 1, 2e24));
        ReferenceAuction.RefResult memory r = ReferenceAuction.settle(b, supply);

        _assertCanonical(b, r.order);

        // totalSold == min(supply, total demand)
        uint256 demand;
        for (uint256 i = 0; i < b.length; i++) {
            demand += b[i].quantity;
        }
        assertEq(r.totalSold, demand < supply ? demand : supply);

        uint256 sumFill;
        uint256 sumPay;
        for (uint256 i = 0; i < b.length; i++) {
            assertLe(r.fill[i], b[i].quantity);
            sumFill += r.fill[i];
            sumPay += r.payment[i];
            if (r.fill[i] > 0) {
                // price sandwich, winner side
                assertGe(b[i].price, r.clearingPrice);
                // payment is the exact ceiling of clearing * fill / WAD
                uint256 p = uint256(r.clearingPrice) * r.fill[i];
                assertGe(r.payment[i] * WAD, p);
                assertLt((r.payment[i] - 1) * WAD, p);
            } else {
                assertEq(r.payment[i], 0);
                // price sandwich, loser side (margin-tied losers may touch clearing)
                if (r.totalSold > 0) assertLe(b[i].price, r.clearingPrice);
            }
        }
        assertEq(sumFill, r.totalSold);
        assertEq(sumPay, r.proceeds);

        // winners form a strict prefix of the canonical order
        bool zeroSeen;
        for (uint256 pos = 0; pos < r.order.length; pos++) {
            uint128 f = r.fill[r.order[pos]];
            if (zeroSeen) assertEq(f, 0);
            if (f == 0) zeroSeen = true;
        }

        // under the preconditions (qty > 0, supply > 0), any nonempty bid set sells something
        if (b.length > 0) {
            assertGt(r.totalSold, 0);
            assertGt(r.clearingPrice, 0);
        } else {
            assertEq(r.clearingPrice, 0);
        }
    }

    // ---- helpers ----

    /// @dev Asserts `order` is a permutation of [0, n) satisfying the contract-side canonical
    /// predicate from SPEC §1.5 — deliberately restated here in the contract's form (not via
    /// the library's `precedes`) so the sort is checked against independent logic.
    function _assertCanonical(ReferenceAuction.RefBid[] memory b, uint256[] memory order)
        internal
        pure
    {
        assertEq(order.length, b.length);
        bool[] memory seen = new bool[](b.length);
        for (uint256 i = 0; i < order.length; i++) {
            uint256 idx = order[i];
            assertLt(idx, b.length);
            assertFalse(seen[idx]);
            seen[idx] = true;
            if (i > 0) {
                uint256 a = order[i - 1];
                bool ok = b[idx].price < b[a].price || (b[idx].price == b[a].price && idx > a);
                assertTrue(ok, "canonical predicate violated");
            }
        }
    }

    /// @dev Deterministic bid-set generator: n in [0, maxN], prices in [priceLo, priceHi],
    /// quantities in [1, 1e24].
    function _genBids(uint256 seed, uint256 maxN, uint128 priceLo, uint128 priceHi)
        internal
        pure
        returns (ReferenceAuction.RefBid[] memory b)
    {
        uint256 n = bound(uint256(keccak256(abi.encode(seed, "n"))), 0, maxN);
        b = new ReferenceAuction.RefBid[](n);
        for (uint256 i = 0; i < n; i++) {
            uint128 price =
                uint128(bound(uint256(keccak256(abi.encode(seed, i, "p"))), priceLo, priceHi));
            uint128 qty = uint128(bound(uint256(keccak256(abi.encode(seed, i, "q"))), 1, 1e24));
            b[i] = ReferenceAuction.RefBid(price, qty);
        }
    }
}
