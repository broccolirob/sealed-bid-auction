// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SealedBidAuction} from "../../src/SealedBidAuction.sol";
import {AuctionTestBase} from "../utils/AuctionTestBase.sol";

contract SettleTest is AuctionTestBase {
    // ---- order builders ----

    function _ord0() internal pure returns (uint256[] memory o) {
        o = new uint256[](0);
    }

    function _ord(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1);
        o[0] = a;
    }

    function _ord(uint256 a, uint256 b) internal pure returns (uint256[] memory o) {
        o = new uint256[](2);
        o[0] = a;
        o[1] = b;
    }

    function _ord(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory o) {
        o = new uint256[](3);
        o[0] = a;
        o[1] = b;
        o[2] = c;
    }

    function _settle(uint256[] memory order) internal {
        vm.prank(settler);
        auction.settle(order);
    }

    // ---- case classes (SPEC §6.2 settle row; default SUPPLY = 100e18) ----

    /// @dev Demand 120e18 > supply: the marginal bid (alice, lowest filled) is partially
    /// filled and prices the whole batch.
    function test_settle_demandExceedsSupply_partialMarginalFill() public {
        uint256 idA = _commit(alice, 3e18, 50e18, "sa", 150e18);
        uint256 idB = _commit(bob, 5e18, 30e18, "sb", 150e18);
        uint256 idC = _commit(carol, 4e18, 40e18, "sc", 160e18);
        warpToReveal();
        _reveal(alice, idA, 3e18, 50e18, "sa"); // revealIdx 0
        _reveal(bob, idB, 5e18, 30e18, "sb"); // revealIdx 1
        _reveal(carol, idC, 4e18, 40e18, "sc"); // revealIdx 2
        warpToSettleWindow();

        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.Settled(3e18, 100e18, 300e18);
        _settle(_ord(1, 2, 0));

        assertTrue(auction.settled());
        assertEq(uint8(auction.phase()), uint8(SealedBidAuction.Phase.Settled));
        assertEq(auction.clearingPrice(), 3e18);
        assertEq(auction.totalSold(), 100e18);
        assertEq(auction.proceeds(), 300e18); // 3e18 * (30 + 40 + 30)e18 / 1e18
        assertEq(auction.getBid(1).fill, 30e18); // bob: full
        assertEq(auction.getBid(2).fill, 40e18); // carol: full
        assertEq(auction.getBid(0).fill, 30e18); // alice: marginal, 30 of 50
    }

    function test_settle_demandEqualsSupply() public {
        uint256 idA = _commit(alice, 2e18, 30e18, "sa", 60e18);
        uint256 idB = _commit(bob, 4e18, 70e18, "sb", 280e18);
        warpToReveal();
        _reveal(alice, idA, 2e18, 30e18, "sa"); // revealIdx 0
        _reveal(bob, idB, 4e18, 70e18, "sb"); // revealIdx 1
        warpToSettleWindow();

        _settle(_ord(1, 0));

        assertEq(auction.getBid(1).fill, 70e18);
        assertEq(auction.getBid(0).fill, 30e18); // marginal, fully filled
        assertEq(auction.clearingPrice(), 2e18);
        assertEq(auction.totalSold(), 100e18);
        assertEq(auction.proceeds(), 200e18); // 2e18 * 100e18 / 1e18
    }

    /// @dev Demand 60e18 < supply: everyone fills fully, the lowest revealed bid clears the
    /// batch, remainder returns to the seller at claim time.
    function test_settle_demandBelowSupply_clearsAtLowestBid() public {
        uint256 idA = _commit(alice, 5e18, 20e18, "sa", 100e18);
        uint256 idB = _commit(bob, 2e18, 30e18, "sb", 60e18);
        uint256 idC = _commit(carol, 3e18, 10e18, "sc", 30e18);
        warpToReveal();
        _reveal(alice, idA, 5e18, 20e18, "sa"); // revealIdx 0
        _reveal(bob, idB, 2e18, 30e18, "sb"); // revealIdx 1
        _reveal(carol, idC, 3e18, 10e18, "sc"); // revealIdx 2
        warpToSettleWindow();

        _settle(_ord(0, 2, 1));

        assertEq(auction.getBid(0).fill, 20e18);
        assertEq(auction.getBid(2).fill, 10e18);
        assertEq(auction.getBid(1).fill, 30e18);
        assertEq(auction.clearingPrice(), 2e18); // lowest bid, >= reserve by reveal
        assertEq(auction.totalSold(), 60e18);
        assertEq(auction.proceeds(), 120e18); // everyone pays 2e18, not their own price
    }

    function test_settle_singleBid() public {
        uint256 id = _commit(alice, 2e18, 40e18, "sa", 80e18);
        warpToReveal();
        _reveal(alice, id, 2e18, 40e18, "sa");
        warpToSettleWindow();

        _settle(_ord(0));

        assertEq(auction.getBid(0).fill, 40e18);
        assertEq(auction.clearingPrice(), 2e18);
        assertEq(auction.totalSold(), 40e18);
        assertEq(auction.proceeds(), 80e18);
    }

    /// @dev R == 0: settlement succeeds trivially with all-zero results (SPEC §1.5); the
    /// seller reclaims everything via claimSeller.
    function test_settle_zeroReveals_trivialSettle() public {
        warpToSettleWindow();

        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.Settled(0, 0, 0);
        _settle(_ord0());

        assertTrue(auction.settled());
        assertEq(auction.clearingPrice(), 0);
        assertEq(auction.totalSold(), 0);
        assertEq(auction.proceeds(), 0);
    }

    /// @dev Two identical bids tie at the margin: the earlier reveal index fills, the later
    /// one becomes a price-equal loser (SPEC §2 tie-break).
    function test_settle_tieAtMargin_earlierRevealIndexWins() public {
        uint256 idA = _commit(alice, 5e18, 80e18, "sa", 400e18);
        uint256 idB = _commit(bob, 3e18, 30e18, "sb", 90e18);
        uint256 idC = _commit(carol, 3e18, 30e18, "sc", 90e18);
        warpToReveal();
        _reveal(alice, idA, 5e18, 80e18, "sa"); // revealIdx 0
        _reveal(bob, idB, 3e18, 30e18, "sb"); // revealIdx 1 — earlier tied reveal
        _reveal(carol, idC, 3e18, 30e18, "sc"); // revealIdx 2 — later tied reveal
        warpToSettleWindow();

        _settle(_ord(0, 1, 2)); // tie resolved by ascending reveal index

        assertEq(auction.getBid(0).fill, 80e18);
        assertEq(auction.getBid(1).fill, 20e18); // earlier tied reveal takes the remainder
        assertEq(auction.getBid(2).fill, 0); // margin-tied loser
        assertEq(auction.clearingPrice(), 3e18);
        assertEq(auction.totalSold(), 100e18);
        assertEq(auction.proceeds(), 300e18); // 3e18 * (80 + 20)e18 / 1e18
    }

    /// @dev Pins SPEC §1.5's proceeds definition at the contract level: proceeds are the
    /// SUM of per-winner ceilings, not one ceiling of the total. Two 1-wei fills at clearing
    /// 1e18 + 1: each payment ceils to 2 wei => proceeds 4, while a single-rounding
    /// implementation would report ceil(2 * (1e18 + 1) / 1e18) = 3. A single winner cannot
    /// distinguish the two — this needs at least two dusty fills.
    function test_settle_proceedsAreSumOfPerWinnerCeils() public {
        uint128 price = 1e18 + 1;
        uint256 idA = _commit(alice, price, 1, "sa", 2);
        uint256 idB = _commit(bob, price, 1, "sb", 2);
        warpToReveal();
        _reveal(alice, idA, price, 1, "sa"); // revealIdx 0
        _reveal(bob, idB, price, 1, "sb"); // revealIdx 1
        warpToSettleWindow();

        _settle(_ord(0, 1)); // equal prices: ascending reveal index

        assertEq(auction.clearingPrice(), price);
        assertEq(auction.totalSold(), 2);
        assertEq(auction.proceeds(), 4);
    }

    // ---- phase gates ----

    function test_settle_revert_duringCommitPhase() public {
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        _settle(_ord0());
    }

    function test_settle_revert_duringRevealPhase() public {
        warpToReveal();
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        _settle(_ord0());

        vm.warp(REVEAL_END); // boundary: t == revealEnd is still REVEAL
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        _settle(_ord0());
    }

    function test_settle_revert_afterDeadline() public {
        vm.warp(uint256(SETTLE_DEADLINE) + 1);
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        _settle(_ord0());
    }

    function test_settle_atDeadlineBoundary_succeeds() public {
        vm.warp(SETTLE_DEADLINE); // t <= settleDeadline is still SETTLE-WINDOW
        _settle(_ord0());
        assertTrue(auction.settled());
    }

    function test_settle_revert_double() public {
        warpToSettleWindow();
        _settle(_ord0());
        vm.expectRevert(SealedBidAuction.AlreadySettled.selector);
        _settle(_ord0());
    }
}
