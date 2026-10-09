// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {InvaraChainlinkOracle} from "../src/InvaraChainlinkOracle.sol";
import {InvaraVault} from "../src/InvaraVault.sol";
import {InvaraSyntheticToken} from "../src/InvaraSyntheticToken.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract InvaraChainlinkOracleTest is Test {
    InvaraChainlinkOracle oracle;
    MockAggregator feed;
    bytes32 constant AAPL = keccak256("AAPL");
    uint32 constant MAX_AGE = 26 hours;

    function setUp() public {
        vm.warp(1_800_000_000);
        oracle = new InvaraChainlinkOracle();
        feed = new MockAggregator(8);
        feed.setPrice(332_50511802, block.timestamp);
        oracle.setFeed(AAPL, address(feed), MAX_AGE);
    }

    function testNormalizesEightDecimalsTo18() public view {
        assertEq(oracle.getAssetPrice(AAPL), 332.50511802e18);
    }

    function testNormalizesOtherDecimals() public {
        MockAggregator f18 = new MockAggregator(18);
        f18.setPrice(100e18, block.timestamp);
        MockAggregator f20 = new MockAggregator(20);
        f20.setPrice(100e20, block.timestamp);
        oracle.setFeed(keccak256("A"), address(f18), MAX_AGE);
        oracle.setFeed(keccak256("B"), address(f20), MAX_AGE);
        assertEq(oracle.getAssetPrice(keccak256("A")), 100e18);
        assertEq(oracle.getAssetPrice(keccak256("B")), 100e18);
    }

    function testAcceptsPriceAtMaxAge() public {
        vm.warp(block.timestamp + MAX_AGE);
        assertEq(oracle.getAssetPrice(AAPL), 332.50511802e18);
    }

    function testRevertsWhenStale() public {
        uint256 updatedAt = block.timestamp;
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(InvaraChainlinkOracle.StalePrice.selector, updatedAt));
        oracle.getAssetPrice(AAPL);
    }

    function testRevertsOnFutureTimestamp() public {
        feed.setPrice(1e8, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(InvaraChainlinkOracle.StalePrice.selector, block.timestamp + 1));
        oracle.getAssetPrice(AAPL);
    }

    function testRevertsOnZeroUpdatedAt() public {
        feed.setPrice(1e8, 0);
        vm.expectRevert(abi.encodeWithSelector(InvaraChainlinkOracle.StalePrice.selector, 0));
        oracle.getAssetPrice(AAPL);
    }

    function testRevertsOnNonPositivePrice() public {
        feed.setPrice(0, block.timestamp);
        vm.expectRevert(InvaraChainlinkOracle.InvalidPrice.selector);
        oracle.getAssetPrice(AAPL);
        feed.setPrice(-1, block.timestamp);
        vm.expectRevert(InvaraChainlinkOracle.InvalidPrice.selector);
        oracle.getAssetPrice(AAPL);
    }

    function testRevertsForUnknownMarket() public {
        vm.expectRevert(InvaraChainlinkOracle.FeedNotSet.selector);
        oracle.getAssetPrice(keccak256("TSLA"));
    }

    function testOnlyDeployerCanSetFeed() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(InvaraChainlinkOracle.OnlyDeployer.selector);
        oracle.setFeed(keccak256("TSLA"), address(feed), MAX_AGE);
    }

    function testFeedCannotBeReplaced() public {
        MockAggregator other = new MockAggregator(8);
        vm.expectRevert(InvaraChainlinkOracle.FeedAlreadySet.selector);
        oracle.setFeed(AAPL, address(other), MAX_AGE);
    }

    function testSetFeedValidation() public {
        vm.expectRevert(InvaraChainlinkOracle.ZeroAddress.selector);
        oracle.setFeed(keccak256("X"), address(0), MAX_AGE);
        vm.expectRevert(InvaraChainlinkOracle.InvalidMaxAge.selector);
        oracle.setFeed(keccak256("X"), address(feed), 0);
        vm.expectRevert(InvaraChainlinkOracle.InvalidMaxAge.selector);
        oracle.setFeed(keccak256("X"), address(feed), uint32(7 days + 1));
    }

    // ── Vault running on the Chainlink oracle ──

    function _vault() internal returns (InvaraVault vault, InvaraSyntheticToken token, MockUSDC usdc) {
        usdc = new MockUSDC();
        vault = new InvaraVault(address(usdc), address(oracle));
        token = new InvaraSyntheticToken("Invara AAPL", "iAAPL", address(vault));
        vault.registerSyntheticToken(AAPL, address(token), 1000e18);
    }

    function testVaultMintAndRepayOnChainlink() public {
        (InvaraVault vault, InvaraSyntheticToken token, MockUSDC usdc) = _vault();
        address alice = address(0xA11CE);
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        // 1 iAAPL at $332.51 needs >= $432.26 collateral at 130%
        vault.depositAndMint(AAPL, 450e6, 1e18);
        assertEq(token.balanceOf(alice), 1e18);

        vm.expectRevert(InvaraVault.BelowMCR.selector);
        vault.depositAndMint(AAPL, 0, 0.1e18);

        vault.burnAndWithdraw(AAPL, 1e18, 450e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(vault.totalDebt(AAPL), 0);
    }

    function testVaultPausesPricedActionsWhenStaleButFullExitWorks() public {
        (InvaraVault vault, InvaraSyntheticToken token, MockUSDC usdc) = _vault();
        address alice = address(0xA11CE);
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositAndMint(AAPL, 900e6, 1e18);

        vm.warp(block.timestamp + 3 days); // weekend: no feed updates
        vm.expectRevert();
        vault.depositAndMint(AAPL, 0, 0.1e18);
        vm.expectRevert();
        vault.burnAndWithdraw(AAPL, 0, 100e6);

        // Repaying everything and withdrawing everything needs no price
        vault.burnAndWithdraw(AAPL, 1e18, 900e6);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 1000e6);
    }

    function testVaultLiquidationOnChainlink() public {
        (InvaraVault vault, InvaraSyntheticToken token, MockUSDC usdc) = _vault();
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositAndMint(AAPL, 450e6, 1e18);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositAndMint(AAPL, 900e6, 1e18);
        vm.stopPrank();

        vm.expectRevert(InvaraVault.PositionHealthy.selector);
        vault.liquidatePosition(AAPL, alice, 1e18);

        feed.setPrice(400_00000000, block.timestamp); // AAPL to $400: alice at 112.5%
        vm.prank(bob);
        vault.liquidatePosition(AAPL, alice, 1e18);
        // Bob burns 1 iAAPL and receives $400 * 105% = $420
        assertEq(token.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(bob), 100e6 + 420e6);
        (uint256 col, uint256 debt) = vault.positions(AAPL, alice);
        assertEq(debt, 0);
        assertEq(col, 30e6);
    }
}
