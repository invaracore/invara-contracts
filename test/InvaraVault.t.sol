// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {InvaraChainlinkOracle} from "../src/InvaraChainlinkOracle.sol";
import {InvaraVault} from "../src/InvaraVault.sol";
import {InvaraSyntheticToken} from "../src/InvaraSyntheticToken.sol";

contract InvaraVaultTest is Test {
    MockUSDC public usdc;
    InvaraChainlinkOracle public oracle;
    mapping(bytes32 => MockAggregator) public feeds;
    InvaraVault public vault;
    InvaraSyntheticToken public iaaplToken;

    bytes32 public constant AAPL_PRICE_ID = bytes32(uint256(1));
    bytes32 public constant UNREGISTERED_PRICE_ID = bytes32(uint256(99));
    uint256 public constant ONE_THOUSAND_USDC = 1000 * 1e6;
    uint256 public constant THREE_HUNDRED_USDC = 300 * 1e6;
    uint256 public constant TWO_HUNDRED_SEVENTY_USDC = 270 * 1e6;
    uint256 public constant ONE_HUNDRED_USDC = 100 * 1e6;
    uint256 public constant FIVE_HUNDRED_USDC = 500 * 1e6;
    uint256 public constant SIX_HUNDRED_FIFTY_USDC = 650 * 1e6;
    uint256 public constant ONE_SYNTHETIC = 1e18;
    uint256 public constant HALF_SYNTHETIC = 0.5e18;
    uint256 public constant CEILING = 1000e18;
    int64 public constant FEED_UNIT = 1e8; // 8-decimal feed answers
    uint32 public constant MAX_AGE = 26 hours;

    address public user = address(0x1);
    address public liquidator = address(0x2);

    function setUp() public {
        vm.warp(10000);
        usdc = new MockUSDC();
        oracle = new InvaraChainlinkOracle();
        vault = new InvaraVault(address(usdc), address(oracle));
        iaaplToken = new InvaraSyntheticToken("Invara AAPL", "iAAPL", address(vault));

        vault.registerSyntheticToken(AAPL_PRICE_ID, address(iaaplToken), CEILING);

        _setPrice(AAPL_PRICE_ID, 200 * FEED_UNIT);
        usdc.mint(user, ONE_THOUSAND_USDC);
    }

    function testDepositAndMint() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);
        vm.stopPrank();

        assertEq(iaaplToken.balanceOf(user), ONE_SYNTHETIC);
        assertEq(usdc.balanceOf(address(vault)), THREE_HUNDRED_USDC);
    }

    function testDepositMoreToExistingPosition() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, HALF_SYNTHETIC);
        vm.stopPrank();

        (, uint256 syntheticMinted) = vault.positions(AAPL_PRICE_ID, user);
        assertEq(syntheticMinted, ONE_SYNTHETIC + HALF_SYNTHETIC);
    }

    function testBurnAndWithdraw() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);

        assertTrue(iaaplToken.approve(address(vault), ONE_SYNTHETIC));
        vault.burnAndWithdraw(AAPL_PRICE_ID, ONE_SYNTHETIC, THREE_HUNDRED_USDC);
        vm.stopPrank();

        assertEq(iaaplToken.balanceOf(user), 0);
        assertEq(usdc.balanceOf(user), ONE_THOUSAND_USDC);
    }

    function testPartialBurnAndWithdraw() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);

        assertTrue(iaaplToken.approve(address(vault), HALF_SYNTHETIC));
        vault.burnAndWithdraw(AAPL_PRICE_ID, HALF_SYNTHETIC, ONE_HUNDRED_USDC);
        vm.stopPrank();

        (, uint256 syntheticMinted) = vault.positions(AAPL_PRICE_ID, user);
        assertEq(syntheticMinted, HALF_SYNTHETIC);
    }

    function testBurnOnly() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);

        assertTrue(iaaplToken.approve(address(vault), ONE_SYNTHETIC));
        vault.burnAndWithdraw(AAPL_PRICE_ID, ONE_SYNTHETIC, 0);
        vm.stopPrank();

        (, uint256 syntheticMinted) = vault.positions(AAPL_PRICE_ID, user);
        assertEq(syntheticMinted, 0);
    }

    function testWithdrawOnly() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);

        vault.burnAndWithdraw(AAPL_PRICE_ID, 0, 30 * 1e6);
        vm.stopPrank();

        (uint256 collateralAmount,) = vault.positions(AAPL_PRICE_ID, user);
        assertEq(collateralAmount, THREE_HUNDRED_USDC - 30 * 1e6);
    }

    function testRevertWhenUndercollateralized() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));

        vm.expectRevert();
        vault.depositAndMint(AAPL_PRICE_ID, ONE_HUNDRED_USDC, ONE_SYNTHETIC);
        vm.stopPrank();
    }

    function testRevertWhenAssetNotRegistered() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));

        vm.expectRevert();
        vault.depositAndMint(UNREGISTERED_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);
        vm.stopPrank();
    }

    function testLiquidationWhenPriceSpikes() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, TWO_HUNDRED_SEVENTY_USDC, ONE_SYNTHETIC);
        vm.stopPrank();

        _setPrice(AAPL_PRICE_ID, 220 * FEED_UNIT);

        vm.startPrank(liquidator);
        usdc.mint(liquidator, ONE_THOUSAND_USDC);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, FIVE_HUNDRED_USDC, ONE_SYNTHETIC);

        assertTrue(iaaplToken.approve(address(vault), ONE_SYNTHETIC));
        vault.liquidatePosition(AAPL_PRICE_ID, user, ONE_SYNTHETIC);
        vm.stopPrank();

        (uint256 remainingCollateral, uint256 syntheticMinted) = vault.positions(AAPL_PRICE_ID, user);
        assertEq(syntheticMinted, 0);
        assertGt(remainingCollateral, 0);
    }

    function testLiquidateWithExcessBurn() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, TWO_HUNDRED_SEVENTY_USDC, ONE_SYNTHETIC);
        vm.stopPrank();

        _setPrice(AAPL_PRICE_ID, 220 * FEED_UNIT);

        vm.startPrank(liquidator);
        usdc.mint(liquidator, ONE_THOUSAND_USDC);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, FIVE_HUNDRED_USDC, ONE_SYNTHETIC);

        assertTrue(iaaplToken.approve(address(vault), ONE_SYNTHETIC * 2));
        vault.liquidatePosition(AAPL_PRICE_ID, user, ONE_SYNTHETIC * 2);
        vm.stopPrank();
    }

    function testLiquidateSeizeExceedsCollateral() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, TWO_HUNDRED_SEVENTY_USDC, ONE_SYNTHETIC);
        vm.stopPrank();

        _setPrice(AAPL_PRICE_ID, 500 * FEED_UNIT);

        vm.startPrank(liquidator);
        usdc.mint(liquidator, ONE_THOUSAND_USDC);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, SIX_HUNDRED_FIFTY_USDC, ONE_SYNTHETIC);

        assertTrue(iaaplToken.approve(address(vault), ONE_SYNTHETIC));
        vault.liquidatePosition(AAPL_PRICE_ID, user, ONE_SYNTHETIC);
        vm.stopPrank();

        (uint256 remainingCollateral,) = vault.positions(AAPL_PRICE_ID, user);
        assertEq(remainingCollateral, 0);
    }

    function testRevertLiquidateHealthyPosition() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);
        vm.stopPrank();

        vm.startPrank(liquidator);
        usdc.mint(liquidator, ONE_THOUSAND_USDC);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, FIVE_HUNDRED_USDC, ONE_SYNTHETIC);
        assertTrue(iaaplToken.approve(address(vault), ONE_SYNTHETIC));

        vm.expectRevert();
        vault.liquidatePosition(AAPL_PRICE_ID, user, ONE_SYNTHETIC);
        vm.stopPrank();
    }

    function testRevertWhenStalePrice() public {
        vm.warp(block.timestamp + 7 days);

        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vm.expectRevert();
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);
        vm.stopPrank();
    }

    function testRevertWhenInvalidPrice() public {
        _setPrice(AAPL_PRICE_ID, 0);

        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vm.expectRevert();
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);
        vm.stopPrank();
    }

    function testRevertRegisterDuplicateToken() public {
        vm.expectRevert();
        vault.registerSyntheticToken(AAPL_PRICE_ID, address(iaaplToken), CEILING);
    }

    function testRevertConstructorUSDCZeroAddress() public {
        vm.expectRevert();
        new InvaraVault(address(0), address(oracle));
    }

    function testRevertConstructorOracleZeroAddress() public {
        vm.expectRevert();
        new InvaraVault(address(usdc), address(0));
    }

    function testRevertRegisterSyntheticZeroAddress() public {
        vm.expectRevert();
        vault.registerSyntheticToken(AAPL_PRICE_ID, address(0), CEILING);
    }

    function testRevertRegisterNotDeployer() public {
        InvaraVault fresh = new InvaraVault(address(usdc), address(oracle));
        InvaraSyntheticToken tok = new InvaraSyntheticToken("X", "X", address(fresh));
        vm.prank(address(0xBAD));
        vm.expectRevert(InvaraVault.OnlyDeployer.selector);
        fresh.registerSyntheticToken(bytes32(uint256(2)), address(tok), CEILING);
    }

    function testRevertRegisterVaultMismatch() public {
        InvaraSyntheticToken foreign = new InvaraSyntheticToken("X", "X", address(0xBEEF));
        vm.expectRevert(InvaraVault.VaultMismatch.selector);
        vault.registerSyntheticToken(bytes32(uint256(2)), address(foreign), CEILING);
    }

    // ── debt ceiling ─────────────────────────────────────────────────────

    function testRevertRegisterZeroCeiling() public {
        InvaraSyntheticToken tok = new InvaraSyntheticToken("X", "X", address(vault));
        vm.expectRevert(InvaraVault.ZeroDebtCeiling.selector);
        vault.registerSyntheticToken(bytes32(uint256(3)), address(tok), 0);
    }

    function testRevertMintAboveDebtCeiling() public {
        bytes32 id = bytes32(uint256(4));
        InvaraSyntheticToken tok = new InvaraSyntheticToken("X", "X", address(vault));
        vault.registerSyntheticToken(id, address(tok), ONE_SYNTHETIC);
        _setPrice(id, 200 * FEED_UNIT);

        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(id, FIVE_HUNDRED_USDC, ONE_SYNTHETIC); // exactly at the ceiling
        vm.expectRevert(InvaraVault.DebtCeilingExceeded.selector);
        vault.depositAndMint(id, 0, 1);
        vm.stopPrank();
        assertEq(vault.totalDebt(id), ONE_SYNTHETIC);
    }

    function testTotalDebtTracksMintAndBurn() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, ONE_SYNTHETIC);
        assertEq(vault.totalDebt(AAPL_PRICE_ID), ONE_SYNTHETIC);
        vault.burnAndWithdraw(AAPL_PRICE_ID, HALF_SYNTHETIC, 0);
        vm.stopPrank();
        assertEq(vault.totalDebt(AAPL_PRICE_ID), HALF_SYNTHETIC);
    }

    // ── minimum position size ────────────────────────────────────────────

    function testRevertMintBelowMinCollateral() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        // 50 USDC backs 0.1 iAAPL ($20) at 250%: healthy, but below the 100 USDC minimum
        vm.expectRevert(InvaraVault.BelowMinCollateral.selector);
        vault.depositAndMint(AAPL_PRICE_ID, 50 * 1e6, 0.1e18);
        vm.stopPrank();
    }

    function testRevertWithdrawBelowMinCollateral() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, THREE_HUNDRED_USDC, 0.1e18);
        vm.expectRevert(InvaraVault.BelowMinCollateral.selector);
        vault.burnAndWithdraw(AAPL_PRICE_ID, 0, 205 * 1e6); // would leave 95 USDC with debt open
        vm.stopPrank();
    }

    function testDepositWithoutDebtHasNoMinimum() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, 10 * 1e6, 0);
        vm.stopPrank();
        (uint256 collateralAmount,) = vault.positions(AAPL_PRICE_ID, user);
        assertEq(collateralAmount, 10 * 1e6);
    }

    // ── bad debt ─────────────────────────────────────────────────────────

    function testBadDebtWrittenOffAndLiquidatorKeepsBonus() public {
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, TWO_HUNDRED_SEVENTY_USDC, ONE_SYNTHETIC);
        vm.stopPrank();

        // liquidator holds iAAPL from a healthy position; then AAPL jumps to $500: user is at 54% collateral
        vm.startPrank(liquidator);
        usdc.mint(liquidator, ONE_THOUSAND_USDC);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, SIX_HUNDRED_FIFTY_USDC, ONE_SYNTHETIC);
        vm.stopPrank();
        _setPrice(AAPL_PRICE_ID, 500 * FEED_UNIT);

        uint256 iaaplBefore = iaaplToken.balanceOf(liquidator);
        uint256 usdcBefore = usdc.balanceOf(liquidator);
        vm.prank(liquidator);
        vault.liquidatePosition(AAPL_PRICE_ID, user, ONE_SYNTHETIC);

        uint256 burned = iaaplBefore - iaaplToken.balanceOf(liquidator);
        uint256 seized = usdc.balanceOf(liquidator) - usdcBefore;
        assertEq(seized, TWO_HUNDRED_SEVENTY_USDC); // all collateral
        assertApproxEqAbs(burned, 514285714285714286, 1); // 270 / (500 * 1.05), rounded up
        // liquidator receives 105% of the burned debt's value (within one unit of rounding)
        assertGe((seized + 1) * 1e12 * 100, burned * 500 * 105);

        (uint256 coll, uint256 debt) = vault.positions(AAPL_PRICE_ID, user);
        assertEq(coll, 0);
        assertEq(debt, 0);
        assertEq(vault.badDebt(AAPL_PRICE_ID), ONE_SYNTHETIC - burned);
        assertEq(vault.totalDebt(AAPL_PRICE_ID), ONE_SYNTHETIC); // only the liquidator's own position remains
    }

    function testFuzzLiquidationAlwaysPaysBonus(uint256 priceUsd) public {
        priceUsd = bound(priceUsd, 208, 5000); // 270 USDC per 1 iAAPL is below 130% above ~$207.7
        vm.startPrank(user);
        assertTrue(usdc.approve(address(vault), ONE_THOUSAND_USDC));
        vault.depositAndMint(AAPL_PRICE_ID, TWO_HUNDRED_SEVENTY_USDC, ONE_SYNTHETIC);
        vm.stopPrank();

        vm.startPrank(liquidator);
        usdc.mint(liquidator, 100_000 * 1e6);
        assertTrue(usdc.approve(address(vault), type(uint256).max));
        vault.depositAndMint(AAPL_PRICE_ID, 50_000 * 1e6, ONE_SYNTHETIC);
        vm.stopPrank();
        // forge-lint: disable-next-line(unsafe-typecast)
        _setPrice(AAPL_PRICE_ID, int64(int256(priceUsd)) * FEED_UNIT);

        uint256 iaaplBefore = iaaplToken.balanceOf(liquidator);
        uint256 usdcBefore = usdc.balanceOf(liquidator);
        vm.prank(liquidator);
        vault.liquidatePosition(AAPL_PRICE_ID, user, ONE_SYNTHETIC);
        uint256 burned = iaaplBefore - iaaplToken.balanceOf(liquidator);
        uint256 seized = usdc.balanceOf(liquidator) - usdcBefore;

        // value received >= 105% of value burned, allowing one unit of rounding
        assertGe((seized + 1) * 1e12 * 100, burned * priceUsd * 105);
        (uint256 coll, uint256 debt) = vault.positions(AAPL_PRICE_ID, user);
        assertEq(debt + vault.badDebt(AAPL_PRICE_ID) + burned, ONE_SYNTHETIC); // all debt accounted for
        assertTrue(debt == 0 || coll > 0); // never leaves debt with zero collateral
    }

    /// @dev Sets a market's on-chain price (8 decimals), binding a mock feed to it on first use
    function _setPrice(bytes32 id, int256 answer) internal {
        if (address(feeds[id]) == address(0)) {
            feeds[id] = new MockAggregator(8);
            oracle.setFeed(id, address(feeds[id]), MAX_AGE);
        }
        feeds[id].setPrice(answer, block.timestamp);
    }
}
