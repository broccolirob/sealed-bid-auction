// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SealedBidAuction} from "../../src/SealedBidAuction.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Shared fixture (PLAN D9): deploys tokens + auction, funds actors, computes
/// commitment hashes, drives phases. The constructor pulls `supply` from the deployer, so
/// deployment approves the CREATE-predicted address first — same trick the deploy script
/// will use.
abstract contract AuctionTestBase is Test {
    MockERC20 internal asset;
    MockERC20 internal payment;
    SealedBidAuction internal auction;

    address internal seller = makeAddr("seller");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal settler = makeAddr("settler");

    uint128 internal constant SUPPLY = 100e18;
    uint128 internal constant RESERVE = 1e18;
    uint32 internal constant MAX_BIDS = 64;

    uint64 internal T0;
    uint64 internal COMMIT_END;
    uint64 internal REVEAL_END;
    uint64 internal SETTLE_DEADLINE;

    function setUp() public virtual {
        asset = new MockERC20("Asset", "AST", 18);
        payment = new MockERC20("Payment", "PAY", 18);

        T0 = uint64(block.timestamp);
        COMMIT_END = T0 + 1 days;
        REVEAL_END = T0 + 2 days;
        SETTLE_DEADLINE = T0 + 3 days;

        auction = _deployAuction(SUPPLY, RESERVE, COMMIT_END, REVEAL_END, SETTLE_DEADLINE, MAX_BIDS);
    }

    // ---- deployment ----

    /// @dev Mints supply to the seller, approves the predicted auction address, deploys.
    function _deployAuction(
        uint128 supply_,
        uint128 reserve_,
        uint64 commitEnd_,
        uint64 revealEnd_,
        uint64 settleDeadline_,
        uint32 maxBids_
    ) internal returns (SealedBidAuction a) {
        asset.mint(seller, supply_);
        address predicted = vm.computeCreateAddress(seller, vm.getNonce(seller));
        vm.prank(seller);
        asset.approve(predicted, supply_);
        vm.prank(seller);
        a = new SealedBidAuction(
            ERC20(address(asset)),
            ERC20(address(payment)),
            supply_,
            reserve_,
            commitEnd_,
            revealEnd_,
            settleDeadline_,
            maxBids_
        );
        assertEq(address(a), predicted, "CREATE address prediction drifted");
    }

    // ---- commitment helpers ----

    /// @dev The SPEC §1.3 preimage, computed independently of the contract.
    function _hash(SealedBidAuction a, address bidder, uint128 price, uint128 qty, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(address(a), bidder, price, qty, salt));
    }

    /// @dev SPEC §1.4 maxSpend, computed independently: ceil(price * qty / 1e18).
    function _maxSpend(uint128 price, uint128 qty) internal pure returns (uint256) {
        return (uint256(price) * uint256(qty) + 1e18 - 1) / 1e18;
    }

    /// @dev Mint + approve + commit on the default auction with a well-formed hash.
    function _commit(address bidder, uint128 price, uint128 qty, bytes32 salt, uint256 deposit)
        internal
        returns (uint256 commitId)
    {
        return _commitRaw(auction, bidder, _hash(auction, bidder, price, qty, salt), deposit);
    }

    /// @dev Mint + approve + commit an arbitrary hash on an arbitrary auction (grief tests).
    function _commitRaw(SealedBidAuction a, address bidder, bytes32 h, uint256 deposit)
        internal
        returns (uint256 commitId)
    {
        if (deposit > 0) payment.mint(bidder, deposit);
        vm.startPrank(bidder);
        if (deposit > 0) payment.approve(address(a), deposit);
        commitId = a.commit(h, deposit);
        vm.stopPrank();
    }

    function _reveal(address bidder, uint256 commitId, uint128 price, uint128 qty, bytes32 salt)
        internal
        returns (uint256 revealIdx)
    {
        vm.prank(bidder);
        return auction.reveal(commitId, price, qty, salt);
    }

    // ---- phase driving ----

    function warpToReveal() internal {
        vm.warp(uint256(COMMIT_END) + 1);
    }

    function warpToSettleWindow() internal {
        vm.warp(uint256(REVEAL_END) + 1);
    }

    function warpToVoid() internal {
        vm.warp(uint256(SETTLE_DEADLINE) + 1);
    }
}
