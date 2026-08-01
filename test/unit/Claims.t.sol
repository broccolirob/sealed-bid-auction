// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SealedBidAuction} from "../../src/SealedBidAuction.sol";
import {AuctionTestBase} from "../utils/AuctionTestBase.sol";

contract ClaimsTest is AuctionTestBase {
    address internal dave = makeAddr("dave"); // committed, never reveals
    address internal constant SINK = address(0xdEaD);

    // ---- scenario builders (default SUPPLY = 100e18, RESERVE = 1e18) ----

    /// @dev Full winner + partial marginal + loser + non-revealer, demand > supply.
    /// Canonical order [1, 2, 0]: bob 5e18/60e18 fills 60, carol 4e18/60e18 fills 40
    /// (marginal => clearing 4e18), alice 2e18/10e18 fills 0. dave forfeits 50e18.
    /// proceeds = 4e18 * 100e18 / 1e18 = 400e18. totalDeposits = 610e18.
    function _settledMixed()
        internal
        returns (uint256 idAlice, uint256 idBob, uint256 idCarol, uint256 idDave)
    {
        idAlice = _commit(alice, 2e18, 10e18, "sa", 20e18);
        idBob = _commit(bob, 5e18, 60e18, "sb", 300e18);
        idCarol = _commit(carol, 4e18, 60e18, "sc", 240e18);
        idDave = _commitRaw(auction, dave, bytes32("never-revealed"), 50e18);
        warpToReveal();
        _reveal(alice, idAlice, 2e18, 10e18, "sa"); // revealIdx 0
        _reveal(bob, idBob, 5e18, 60e18, "sb"); // revealIdx 1
        _reveal(carol, idCarol, 4e18, 60e18, "sc"); // revealIdx 2
        warpToSettleWindow();

        uint256[] memory order = new uint256[](3);
        order[0] = 1;
        order[1] = 2;
        order[2] = 0;
        vm.prank(settler);
        auction.settle(order);
    }

    /// @dev Demand < supply: all fill at clearing 2e18 (lowest bid), 40e18 unsold remainder.
    function _settledShortfall()
        internal
        returns (uint256 idAlice, uint256 idBob, uint256 idCarol)
    {
        idAlice = _commit(alice, 5e18, 20e18, "sa", 100e18);
        idBob = _commit(bob, 2e18, 30e18, "sb", 60e18);
        idCarol = _commit(carol, 3e18, 10e18, "sc", 30e18);
        warpToReveal();
        _reveal(alice, idAlice, 5e18, 20e18, "sa"); // revealIdx 0
        _reveal(bob, idBob, 2e18, 30e18, "sb"); // revealIdx 1
        _reveal(carol, idCarol, 3e18, 10e18, "sc"); // revealIdx 2
        warpToSettleWindow();

        uint256[] memory order = new uint256[](3);
        order[0] = 0;
        order[1] = 2;
        order[2] = 1;
        vm.prank(settler);
        auction.settle(order);
    }

    // ---- SETTLED: bidder claims ----

    function test_claim_winner_exactAmounts() public {
        (, uint256 idBob,,) = _settledMixed();
        // pay = mulDivUp(4e18, 60e18, 1e18) = 240e18; refund = 300e18 - 240e18
        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.BidderClaimed(idBob, 60e18, 60e18);
        vm.prank(bob);
        auction.claimBidder(idBob);

        assertEq(asset.balanceOf(bob), 60e18);
        assertEq(payment.balanceOf(bob), 60e18);
        assertTrue(auction.getCommitment(idBob).claimed);
    }

    function test_claim_marginalPartialWinner_exactAmounts() public {
        (,, uint256 idCarol,) = _settledMixed();
        // fill 40e18 of 60e18; pay = mulDivUp(4e18, 40e18, 1e18) = 160e18; refund = 80e18
        vm.prank(carol);
        auction.claimBidder(idCarol);

        assertEq(asset.balanceOf(carol), 40e18);
        assertEq(payment.balanceOf(carol), 80e18);
    }

    function test_claim_loser_fullRefund() public {
        (uint256 idAlice,,,) = _settledMixed();
        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.BidderClaimed(idAlice, 0, 20e18);
        vm.prank(alice);
        auction.claimBidder(idAlice);

        assertEq(asset.balanceOf(alice), 0);
        assertEq(payment.balanceOf(alice), 20e18);
    }

    /// @dev Winners pay the clearing price, not their own bid: alice bid 5e18 but pays 2e18.
    function test_claim_winnerPaysClearingNotOwnPrice() public {
        (uint256 idAlice,,) = _settledShortfall();
        // pay = mulDivUp(2e18, 20e18, 1e18) = 40e18; refund = 100e18 - 40e18 = 60e18
        vm.prank(alice);
        auction.claimBidder(idAlice);

        assertEq(asset.balanceOf(alice), 20e18);
        assertEq(payment.balanceOf(alice), 60e18);
    }

    function test_claim_nonRevealer_revertsNothingToClaim() public {
        (,,, uint256 idDave) = _settledMixed();
        vm.expectRevert(SealedBidAuction.NothingToClaim.selector);
        vm.prank(dave);
        auction.claimBidder(idDave);
    }

    function test_claim_double_reverts() public {
        (, uint256 idBob,,) = _settledMixed();
        vm.prank(bob);
        auction.claimBidder(idBob);
        vm.expectRevert(SealedBidAuction.AlreadyClaimed.selector);
        vm.prank(bob);
        auction.claimBidder(idBob);
    }

    /// @dev SPEC §12 A3: anyone may trigger the claim; funds always reach the recorded
    /// bidder, never the caller.
    function test_claim_permissionless_paysRecordedBidder() public {
        (, uint256 idBob,,) = _settledMixed();
        vm.prank(settler);
        auction.claimBidder(idBob);

        assertEq(asset.balanceOf(bob), 60e18);
        assertEq(payment.balanceOf(bob), 60e18);
        assertEq(asset.balanceOf(settler), 0);
        assertEq(payment.balanceOf(settler), 0);
    }

    function test_claim_revert_nonexistentCommit() public {
        warpToVoid();
        vm.expectRevert(SealedBidAuction.BadCommit.selector);
        auction.claimBidder(42);
    }

    /// @dev Payments round UP at claim time too: clearing 1e18+1, fill 1 wei => pay 2 wei
    /// (floor would charge 1). Refund is 0, the seller collects the dust.
    function test_claim_paymentRoundsUp_dustFavorsSolvency() public {
        uint128 price = 1e18 + 1;
        uint256 id = _commit(alice, price, 1, "sa", 2);
        warpToReveal();
        _reveal(alice, id, price, 1, "sa");
        warpToSettleWindow();
        uint256[] memory order = new uint256[](1);
        vm.prank(settler);
        auction.settle(order);
        assertEq(auction.proceeds(), 2);

        vm.prank(alice);
        auction.claimBidder(id);
        assertEq(asset.balanceOf(alice), 1);
        assertEq(payment.balanceOf(alice), 0); // deposit 2 - pay 2: nothing back

        vm.prank(seller);
        auction.claimSeller();
        assertEq(payment.balanceOf(seller), 2);
        assertEq(payment.balanceOf(address(auction)), 0);
    }

    // ---- SETTLED: seller + sweep ----

    function test_claimSeller_settled_proceedsAndRemainder() public {
        _settledShortfall();
        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.SellerClaimed(120e18, 40e18);
        vm.prank(seller);
        auction.claimSeller();

        assertEq(payment.balanceOf(seller), 120e18); // proceeds
        assertEq(asset.balanceOf(seller), 40e18); // unsold remainder
        assertTrue(auction.sellerClaimed());
    }

    function test_claimSeller_double_reverts() public {
        _settledShortfall();
        vm.prank(seller);
        auction.claimSeller();
        vm.expectRevert(SealedBidAuction.AlreadyClaimed.selector);
        vm.prank(seller);
        auction.claimSeller();
    }

    function test_sweepForfeits_burnsExactAmount_once() public {
        _settledMixed();
        assertEq(auction.totalDeposits() - auction.revealedDeposits(), 50e18);

        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.ForfeitsBurned(50e18);
        vm.prank(settler);
        auction.sweepForfeits();

        assertEq(payment.balanceOf(SINK), 50e18);
        assertTrue(auction.forfeitsSwept());

        vm.expectRevert(SealedBidAuction.AlreadyClaimed.selector);
        vm.prank(settler);
        auction.sweepForfeits();
    }

    /// @dev PLAN D4: a zero-forfeit sweep succeeds (burns nothing) — the function is total.
    function test_sweepForfeits_zeroForfeits_succeeds() public {
        _settledShortfall(); // everyone revealed
        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.ForfeitsBurned(0);
        vm.prank(settler);
        auction.sweepForfeits();
        assertEq(payment.balanceOf(SINK), 0);
    }

    function test_sweepForfeits_revert_outsideSettled() public {
        _commit(alice, 2e18, 10e18, "sa", 20e18);
        warpToSettleWindow(); // not settled yet
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        auction.sweepForfeits();

        warpToVoid(); // forfeits don't exist in VOID
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        auction.sweepForfeits();
    }

    // ---- VOID ----

    /// @dev Every role — revealed, unrevealed, zero-deposit — gets its full deposit back.
    function test_claim_void_allRolesFullRefund() public {
        uint256 idAlice = _commit(alice, 2e18, 10e18, "sa", 20e18); // will reveal
        uint256 idBob = _commitRaw(auction, bob, bytes32("h"), 50e18); // never reveals
        uint256 idCarol = _commitRaw(auction, carol, bytes32("h2"), 0); // zero deposit
        warpToReveal();
        _reveal(alice, idAlice, 2e18, 10e18, "sa");
        warpToVoid();

        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.BidderClaimed(idAlice, 0, 20e18);
        vm.prank(alice);
        auction.claimBidder(idAlice);
        assertEq(payment.balanceOf(alice), 20e18);
        assertEq(asset.balanceOf(alice), 0);

        vm.prank(bob);
        auction.claimBidder(idBob); // unrevealed: still full refund in VOID
        assertEq(payment.balanceOf(bob), 50e18);

        auction.claimBidder(idCarol); // zero-deposit: succeeds, transfers nothing (D4)
        assertTrue(auction.getCommitment(idCarol).claimed);

        assertEq(payment.balanceOf(address(auction)), 0);
    }

    function test_claim_void_double_reverts() public {
        uint256 id = _commit(alice, 2e18, 10e18, "sa", 20e18);
        warpToVoid();
        vm.prank(alice);
        auction.claimBidder(id);
        vm.expectRevert(SealedBidAuction.AlreadyClaimed.selector);
        vm.prank(alice);
        auction.claimBidder(id);
    }

    function test_claimSeller_void_fullSupplyBack() public {
        _commit(alice, 2e18, 10e18, "sa", 20e18);
        warpToVoid();

        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.SellerClaimed(0, SUPPLY);
        vm.prank(seller);
        auction.claimSeller();

        assertEq(asset.balanceOf(seller), SUPPLY);
        assertEq(payment.balanceOf(seller), 0);
        assertEq(asset.balanceOf(address(auction)), 0);
    }

    // ---- phase gates ----

    function test_claims_revert_beforeTerminalPhase() public {
        uint256 id = _commit(alice, 2e18, 10e18, "sa", 20e18);

        // COMMIT
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        auction.claimBidder(id);
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        auction.claimSeller();

        // REVEAL
        warpToReveal();
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        auction.claimBidder(id);

        // SETTLE-WINDOW (not yet settled, not yet void)
        warpToSettleWindow();
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        auction.claimBidder(id);
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        auction.claimSeller();
    }

    /// @dev The `settled` flag takes precedence over the clock (SPEC §1.2): once settled,
    /// warping past settleDeadline must NOT flip the auction to VOID. Claims keep paying
    /// settled amounts, the non-revealer stays forfeited, and the sweep stays available —
    /// under a time-first phase derivation the winner would instead get a full VOID refund
    /// and the forfeit would escape the burn.
    function test_settledStatePersistsPastDeadline() public {
        (, uint256 idBob,, uint256 idDave) = _settledMixed();
        vm.warp(uint256(SETTLE_DEADLINE) + 365 days);

        assertEq(uint8(auction.phase()), uint8(SealedBidAuction.Phase.Settled));

        vm.prank(bob);
        auction.claimBidder(idBob); // settled winner amounts, not a 300e18 VOID refund
        assertEq(asset.balanceOf(bob), 60e18);
        assertEq(payment.balanceOf(bob), 60e18);

        vm.expectRevert(SealedBidAuction.NothingToClaim.selector);
        vm.prank(dave);
        auction.claimBidder(idDave); // in VOID he would get 50e18 back

        vm.prank(settler);
        auction.sweepForfeits();
        assertEq(payment.balanceOf(SINK), 50e18);
    }

    // ---- exact conservation (SPEC §1.7) ----

    /// @dev Full drain in SETTLED: sum(deposits) == sum(refunds) + proceeds + forfeits and
    /// supply == sum(fills) + sellerRemainder — both exact, both token balances end at zero.
    function test_fullDrain_exactConservation() public {
        (uint256 idAlice, uint256 idBob, uint256 idCarol, uint256 idDave) = _settledMixed();

        vm.prank(alice);
        auction.claimBidder(idAlice);
        vm.prank(bob);
        auction.claimBidder(idBob);
        vm.prank(carol);
        auction.claimBidder(idCarol);
        vm.expectRevert(SealedBidAuction.NothingToClaim.selector);
        vm.prank(dave);
        auction.claimBidder(idDave);
        vm.prank(seller);
        auction.claimSeller();
        vm.prank(settler);
        auction.sweepForfeits();

        // payment: 610e18 in == refunds (20 + 60 + 80) + proceeds 400 + forfeits 50
        uint256 refunds =
            payment.balanceOf(alice) + payment.balanceOf(bob) + payment.balanceOf(carol);
        assertEq(refunds, 160e18);
        assertEq(payment.balanceOf(seller), 400e18);
        assertEq(payment.balanceOf(SINK), 50e18);
        assertEq(auction.totalDeposits(), refunds + 400e18 + 50e18);

        // asset: supply == fills (60 + 40) + remainder 0
        assertEq(asset.balanceOf(bob) + asset.balanceOf(carol), SUPPLY);
        assertEq(asset.balanceOf(seller), 0);

        // the auction is fully drained on both tokens
        assertEq(payment.balanceOf(address(auction)), 0);
        assertEq(asset.balanceOf(address(auction)), 0);
    }
}
