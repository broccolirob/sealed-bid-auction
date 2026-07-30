// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SealedBidAuction} from "../../src/SealedBidAuction.sol";
import {AuctionTestBase} from "../utils/AuctionTestBase.sol";

contract RevealTest is AuctionTestBase {
    uint128 internal constant PRICE = 2e18;
    uint128 internal constant QTY = 10e18;
    bytes32 internal constant SALT = "salt";

    /// @dev One well-formed commitment from alice, deposit exactly maxSpend (20e18).
    function _commitAlice() internal returns (uint256 commitId) {
        return _commit(alice, PRICE, QTY, SALT, _maxSpend(PRICE, QTY));
    }

    // ---- happy paths ----

    function test_reveal_happyPath_exactMaxSpendDeposit() public {
        uint256 id = _commitAlice();
        warpToReveal();

        uint256 revealIdx = _reveal(alice, id, PRICE, QTY, SALT);
        assertEq(revealIdx, 0);

        SealedBidAuction.Bid memory b = auction.getBid(0);
        assertEq(b.commitId, id);
        assertEq(b.price, PRICE);
        assertEq(b.quantity, QTY);
        assertEq(b.fill, 0);

        SealedBidAuction.Commitment memory c = auction.getCommitment(id);
        assertTrue(c.revealed);
        assertEq(c.revealIdx, 0);

        assertEq(auction.revealedCount(), 1);
        assertEq(auction.revealedDeposits(), _maxSpend(PRICE, QTY));
    }

    function test_reveal_overDeposit_allowed() public {
        uint256 id = _commit(alice, PRICE, QTY, SALT, 1000e18); // >> maxSpend of 20e18
        warpToReveal();
        _reveal(alice, id, PRICE, QTY, SALT);
        assertEq(auction.revealedDeposits(), 1000e18);
    }

    function test_reveal_emitsEvent() public {
        uint256 id = _commitAlice();
        warpToReveal();

        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.Revealed(id, 0, PRICE, QTY);
        vm.prank(alice);
        auction.reveal(id, PRICE, QTY, SALT);
    }

    /// @dev Exact-division dust bid: price = reserve (1e18), qty = 1 wei => maxSpend is
    /// exactly 1 wei (no rounding involved); a 1-wei deposit suffices.
    function test_reveal_dustBid_exactDivisionMaxSpend() public {
        uint256 id = _commit(alice, RESERVE, 1, SALT, 1);
        warpToReveal();
        _reveal(alice, id, RESERVE, 1, SALT);
        assertEq(auction.getBid(0).quantity, 1);
    }

    /// @dev Pins SPEC §1.4 step 5's round-UP direction with a product NOT divisible by 1e18:
    /// price = 1e18 + 1, qty = 1 => maxSpend = ceil((1e18 + 1) / 1e18) = 2 wei, while floor
    /// division would accept 1. Both arms fail under a mulDivDown implementation — this is
    /// what keeps the refund-underflow lemma's `maxSpend <= deposit` link intact.
    function test_reveal_maxSpendRoundsUp_nonDivisibleProduct() public {
        uint128 price = 1e18 + 1;
        uint256 idShort = _commit(alice, price, 1, "s-short", 1); // floor would accept this
        uint256 idExact = _commit(alice, price, 1, "s-exact", 2); // the true ceil
        warpToReveal();

        vm.expectRevert(SealedBidAuction.BadBid.selector);
        vm.prank(alice);
        auction.reveal(idShort, price, 1, "s-short");

        uint256 idx = _reveal(alice, idExact, price, 1, "s-exact");
        assertEq(auction.getBid(idx).price, price);
    }

    function test_reveal_atRevealEndBoundary_succeeds() public {
        uint256 id = _commitAlice();
        vm.warp(REVEAL_END); // t <= revealEnd is still REVEAL (SPEC §1.2, inclusive)
        uint256 revealIdx = _reveal(alice, id, PRICE, QTY, SALT);
        assertEq(revealIdx, 0);
    }

    /// @dev N reveals produce indices 0..N-1 in reveal order, not commit order.
    function test_reveal_indexDensity_byRevealOrder() public {
        uint256 idA = _commit(alice, 2e18, 10e18, "sa", 20e18);
        uint256 idB = _commit(bob, 3e18, 10e18, "sb", 30e18);
        uint256 idC = _commit(carol, 4e18, 10e18, "sc", 40e18);
        warpToReveal();

        assertEq(_reveal(bob, idB, 3e18, 10e18, "sb"), 0);
        assertEq(_reveal(carol, idC, 4e18, 10e18, "sc"), 1);
        assertEq(_reveal(alice, idA, 2e18, 10e18, "sa"), 2);

        assertEq(auction.revealedCount(), 3);
        assertEq(auction.getBid(0).commitId, idB);
        assertEq(auction.getBid(1).commitId, idC);
        assertEq(auction.getBid(2).commitId, idA);
        assertEq(auction.getCommitment(idB).revealIdx, 0);
        assertEq(auction.getCommitment(idC).revealIdx, 1);
        assertEq(auction.getCommitment(idA).revealIdx, 2);
        assertEq(auction.revealedDeposits(), 90e18);
    }

    /// @dev Identical (price, qty, salt) from the same bidder: same hash, but the commits
    /// are independent bids and both reveal.
    function test_reveal_duplicateCommitments_bothReveal() public {
        uint256 id0 = _commit(alice, PRICE, QTY, SALT, 20e18);
        uint256 id1 = _commit(alice, PRICE, QTY, SALT, 20e18);
        warpToReveal();
        assertEq(_reveal(alice, id0, PRICE, QTY, SALT), 0);
        assertEq(_reveal(alice, id1, PRICE, QTY, SALT), 1);
        assertEq(auction.revealedCount(), 2);
    }

    // ---- hash binding (threat rows 5-7) ----

    function test_reveal_revert_wrongSalt() public {
        uint256 id = _commitAlice();
        warpToReveal();
        vm.expectRevert(SealedBidAuction.BadCommit.selector);
        vm.prank(alice);
        auction.reveal(id, PRICE, QTY, "wrong");
    }

    function test_reveal_revert_wrongPrice() public {
        uint256 id = _commitAlice();
        warpToReveal();
        vm.expectRevert(SealedBidAuction.BadCommit.selector);
        vm.prank(alice);
        auction.reveal(id, PRICE + 1, QTY, SALT);
    }

    function test_reveal_revert_wrongQuantity() public {
        uint256 id = _commitAlice();
        warpToReveal();
        vm.expectRevert(SealedBidAuction.BadCommit.selector);
        vm.prank(alice);
        auction.reveal(id, PRICE, QTY - 1, SALT);
    }

    function test_reveal_revert_notYourCommit() public {
        uint256 id = _commitAlice();
        warpToReveal();
        // bob knows alice's full preimage but the commit is bound to her
        vm.expectRevert(SealedBidAuction.BadCommit.selector);
        vm.prank(bob);
        auction.reveal(id, PRICE, QTY, SALT);
    }

    /// @dev Threat row 5: a front-runner who copies alice's hash owns a commitment whose
    /// preimage embeds HER address — he can never open it, even knowing the full preimage.
    function test_reveal_revert_copiedHashCannotBeOpened() public {
        bytes32 aliceHash = _hash(auction, alice, PRICE, QTY, SALT);
        uint256 copiedId = _commitRaw(auction, bob, aliceHash, 100e18);
        warpToReveal();
        vm.expectRevert(SealedBidAuction.BadCommit.selector);
        vm.prank(bob);
        auction.reveal(copiedId, PRICE, QTY, SALT);
    }

    /// @dev Threat row 6: a hash computed for one deployment embeds that deployment's
    /// address and cannot be opened on another.
    function test_reveal_revert_crossDeploymentReplay() public {
        SealedBidAuction other =
            _deployAuction(SUPPLY, RESERVE, COMMIT_END, REVEAL_END, SETTLE_DEADLINE, MAX_BIDS);
        bytes32 hashForDefault = _hash(auction, alice, PRICE, QTY, SALT);
        uint256 id = _commitRaw(other, alice, hashForDefault, 100e18);
        warpToReveal();
        vm.expectRevert(SealedBidAuction.BadCommit.selector);
        vm.prank(alice);
        other.reveal(id, PRICE, QTY, SALT);
    }

    // ---- state guards ----

    function test_reveal_revert_doubleReveal() public {
        uint256 id = _commitAlice();
        warpToReveal();
        _reveal(alice, id, PRICE, QTY, SALT);
        vm.expectRevert(SealedBidAuction.BadCommit.selector);
        vm.prank(alice);
        auction.reveal(id, PRICE, QTY, SALT);
    }

    function test_reveal_revert_nonexistentCommit() public {
        warpToReveal();
        vm.expectRevert(SealedBidAuction.BadCommit.selector);
        vm.prank(alice);
        auction.reveal(0, PRICE, QTY, SALT);
    }

    // ---- bid validity (SPEC §1.4 step 4-5) ----

    function test_reveal_revert_depositBelowMaxSpend() public {
        uint256 id = _commit(alice, PRICE, QTY, SALT, _maxSpend(PRICE, QTY) - 1);
        warpToReveal();
        vm.expectRevert(SealedBidAuction.BadBid.selector);
        vm.prank(alice);
        auction.reveal(id, PRICE, QTY, SALT);
    }

    /// @dev A zero-deposit commit can never reveal: reserve > 0 (SPEC §12 A1) forces
    /// maxSpend >= 1 wei.
    function test_reveal_revert_zeroDepositCannotReveal() public {
        uint256 id = _commit(alice, RESERVE, 1, SALT, 0);
        warpToReveal();
        vm.expectRevert(SealedBidAuction.BadBid.selector);
        vm.prank(alice);
        auction.reveal(id, RESERVE, 1, SALT);
    }

    function test_reveal_revert_priceBelowReserve() public {
        uint128 price = RESERVE - 1;
        uint256 id = _commit(alice, price, QTY, SALT, 100e18);
        warpToReveal();
        vm.expectRevert(SealedBidAuction.BadBid.selector);
        vm.prank(alice);
        auction.reveal(id, price, QTY, SALT);
    }

    function test_reveal_revert_zeroQuantity() public {
        uint256 id = _commit(alice, PRICE, 0, SALT, 100e18);
        warpToReveal();
        vm.expectRevert(SealedBidAuction.BadBid.selector);
        vm.prank(alice);
        auction.reveal(id, PRICE, 0, SALT);
    }

    // ---- phase gates ----

    function test_reveal_revert_duringCommitPhase() public {
        uint256 id = _commitAlice();
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        vm.prank(alice);
        auction.reveal(id, PRICE, QTY, SALT);
    }

    function test_reveal_revert_afterRevealEnd() public {
        uint256 id = _commitAlice();
        vm.warp(uint256(REVEAL_END) + 1);
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        vm.prank(alice);
        auction.reveal(id, PRICE, QTY, SALT);
    }
}
