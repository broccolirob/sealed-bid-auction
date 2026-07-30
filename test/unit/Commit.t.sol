// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SealedBidAuction} from "../../src/SealedBidAuction.sol";
import {AuctionTestBase} from "../utils/AuctionTestBase.sol";

contract CommitTest is AuctionTestBase {
    // ---- constructor ----

    function test_constructor_storesConfigAndPullsSupply() public view {
        assertEq(address(auction.asset()), address(asset));
        assertEq(address(auction.payment()), address(payment));
        assertEq(auction.supply(), SUPPLY);
        assertEq(auction.reservePrice(), RESERVE);
        assertEq(auction.commitEnd(), COMMIT_END);
        assertEq(auction.revealEnd(), REVEAL_END);
        assertEq(auction.settleDeadline(), SETTLE_DEADLINE);
        assertEq(auction.maxBids(), MAX_BIDS);
        assertEq(auction.seller(), seller);

        assertEq(asset.balanceOf(address(auction)), SUPPLY);
        assertEq(asset.balanceOf(seller), 0);
        assertEq(uint8(auction.phase()), uint8(SealedBidAuction.Phase.Commit));
    }

    function test_constructor_revert_commitEndNotBeforeRevealEnd() public {
        vm.expectRevert(SealedBidAuction.BadConfig.selector);
        new SealedBidAuction(
            ERC20(address(asset)),
            ERC20(address(payment)),
            SUPPLY,
            RESERVE,
            COMMIT_END,
            COMMIT_END, // revealEnd == commitEnd
            SETTLE_DEADLINE,
            MAX_BIDS
        );
    }

    function test_constructor_revert_revealEndNotBeforeDeadline() public {
        vm.expectRevert(SealedBidAuction.BadConfig.selector);
        new SealedBidAuction(
            ERC20(address(asset)),
            ERC20(address(payment)),
            SUPPLY,
            RESERVE,
            COMMIT_END,
            REVEAL_END,
            REVEAL_END, // settleDeadline == revealEnd
            MAX_BIDS
        );
    }

    function test_constructor_revert_zeroSupply() public {
        vm.expectRevert(SealedBidAuction.BadConfig.selector);
        new SealedBidAuction(
            ERC20(address(asset)),
            ERC20(address(payment)),
            0,
            RESERVE,
            COMMIT_END,
            REVEAL_END,
            SETTLE_DEADLINE,
            MAX_BIDS
        );
    }

    /// @dev SPEC §12 A1 — deliberate deviation from §1.1, which permits a zero reserve.
    function test_constructor_revert_zeroReserve() public {
        vm.expectRevert(SealedBidAuction.BadConfig.selector);
        new SealedBidAuction(
            ERC20(address(asset)),
            ERC20(address(payment)),
            SUPPLY,
            0,
            COMMIT_END,
            REVEAL_END,
            SETTLE_DEADLINE,
            MAX_BIDS
        );
    }

    /// @dev SPEC §12 A2. `commitEnd == block.timestamp` must also revert (strictly future).
    function test_constructor_revert_commitEndNotInFuture() public {
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(SealedBidAuction.BadConfig.selector);
        new SealedBidAuction(
            ERC20(address(asset)),
            ERC20(address(payment)),
            SUPPLY,
            RESERVE,
            t,
            REVEAL_END,
            SETTLE_DEADLINE,
            MAX_BIDS
        );
    }

    /// @dev SPEC §12 A2.
    function test_constructor_revert_zeroMaxBids() public {
        vm.expectRevert(SealedBidAuction.BadConfig.selector);
        new SealedBidAuction(
            ERC20(address(asset)),
            ERC20(address(payment)),
            SUPPLY,
            RESERVE,
            COMMIT_END,
            REVEAL_END,
            SETTLE_DEADLINE,
            0
        );
    }

    // ---- commit ----

    function test_commit_happyPath() public {
        bytes32 h = _hash(auction, alice, 2e18, 10e18, "salt");
        uint256 dep = 25e18;
        uint256 id = _commit(alice, 2e18, 10e18, "salt", dep);

        assertEq(id, 0);
        SealedBidAuction.Commitment memory c = auction.getCommitment(0);
        assertEq(c.bidder, alice);
        assertEq(c.commitHash, h);
        assertEq(c.deposit, dep);
        assertFalse(c.revealed);
        assertFalse(c.claimed);

        assertEq(auction.totalDeposits(), dep);
        assertEq(auction.revealedDeposits(), 0);
        assertEq(payment.balanceOf(address(auction)), dep);
        assertEq(payment.balanceOf(alice), 0);
    }

    function test_commit_emitsEvent() public {
        bytes32 h = _hash(auction, alice, 2e18, 10e18, "salt");
        payment.mint(alice, 20e18);
        vm.startPrank(alice);
        payment.approve(address(auction), 20e18);

        vm.expectEmit(true, true, true, true, address(auction));
        emit SealedBidAuction.Committed(0, alice, 20e18);
        auction.commit(h, 20e18);
        vm.stopPrank();
    }

    function test_commit_twoCommitsSameAddress_independent() public {
        uint256 id0 = _commit(alice, 2e18, 10e18, "s0", 20e18);
        uint256 id1 = _commit(alice, 3e18, 5e18, "s1", 15e18);
        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(auction.getCommitment(0).deposit, 20e18);
        assertEq(auction.getCommitment(1).deposit, 15e18);
        assertEq(auction.getCommitment(0).bidder, alice);
        assertEq(auction.getCommitment(1).bidder, alice);
        assertEq(auction.totalDeposits(), 35e18);
        assertEq(payment.balanceOf(address(auction)), 35e18);
    }

    function test_commit_zeroDeposit_allowed() public {
        uint256 id = _commit(alice, 2e18, 10e18, "salt", 0);
        assertEq(id, 0);
        assertEq(auction.getCommitment(0).deposit, 0);
        assertEq(auction.totalDeposits(), 0);
        assertEq(payment.balanceOf(address(auction)), 0);
    }

    function test_commit_atCommitEndBoundary_succeeds() public {
        vm.warp(COMMIT_END); // t <= commitEnd is still COMMIT (SPEC §1.2, inclusive)
        uint256 id = _commit(alice, 2e18, 10e18, "salt", 20e18);
        assertEq(id, 0);
    }

    function test_commit_revert_afterCommitEnd() public {
        vm.warp(uint256(COMMIT_END) + 1);
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        vm.prank(alice);
        auction.commit(bytes32("h"), 0);
    }

    function test_commit_revert_inVoidPhase() public {
        vm.warp(uint256(SETTLE_DEADLINE) + 1);
        vm.expectRevert(SealedBidAuction.WrongPhase.selector);
        vm.prank(alice);
        auction.commit(bytes32("h"), 0);
    }

    function test_commit_revert_maxBidsReached() public {
        SealedBidAuction small =
            _deployAuction(SUPPLY, RESERVE, COMMIT_END, REVEAL_END, SETTLE_DEADLINE, 2);
        _commitRaw(small, alice, bytes32("h0"), 0);
        _commitRaw(small, bob, bytes32("h1"), 0);
        vm.expectRevert(SealedBidAuction.MaxBidsReached.selector);
        vm.prank(carol);
        small.commit(bytes32("h2"), 0);
    }
}
