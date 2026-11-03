// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {InvaraChainlinkOracle} from "../src/InvaraChainlinkOracle.sol";
import {InvaraVault} from "../src/InvaraVault.sol";
import {InvaraSyntheticToken} from "../src/InvaraSyntheticToken.sol";

/// @dev Random sequences of borrowing, repaying, price moves and liquidations against one market
contract VaultHandler is Test {
    InvaraVault public vault;
    MockUSDC public usdc;
    InvaraSyntheticToken public token;
    MockAggregator public feed;
    bytes32 public id;

    address[] public actors;
    /// @notice Holds iAAPL from a deeply collateralized position, so liquidations can always be paid for
    address public constant LIQUIDATOR = address(0xB0B);

    uint256 public liquidations;

    constructor(InvaraVault vault_, MockUSDC usdc_, InvaraSyntheticToken token_, MockAggregator feed_, bytes32 id_) {
        vault = vault_;
        usdc = usdc_;
        token = token_;
        feed = feed_;
        id = id_;
        for (uint160 i = 1; i <= 3; i++) {
            address a = address(0x1000 + i);
            actors.push(a);
            usdc.mint(a, 10_000_000e6);
            vm.prank(a);
            usdc.approve(address(vault), type(uint256).max);
        }
        usdc.mint(LIQUIDATOR, 10_000_000e6);
        vm.startPrank(LIQUIDATOR);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositAndMint(id, 10_000_000e6, 300e18);
        vm.stopPrank();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function borrow(uint256 actorSeed, uint256 collateral, uint256 mintBps) external {
        address a = actors[actorSeed % actors.length];
        collateral = bound(collateral, 0, 100_000e6);
        (uint256 coll, uint256 debt) = vault.positions(id, a);
        // mint up to the 130% limit (in basis points of the room left), so most calls succeed
        uint256 maxDebt = ((coll + collateral) * 1e12 * 1e18 * 100) / (_price() * 130);
        uint256 room = maxDebt > debt ? maxDebt - debt : 0;
        uint256 mintAmount = (room * bound(mintBps, 0, 10_000)) / 10_000;
        vm.prank(a);
        try vault.depositAndMint(id, collateral, mintAmount) {} catch {}
    }

    function repay(uint256 actorSeed, uint256 burnBps, uint256 withdrawBps) external {
        address a = actors[actorSeed % actors.length];
        (uint256 coll, uint256 debt) = vault.positions(id, a);
        uint256 burnAmount = (debt * bound(burnBps, 0, 10_000)) / 10_000;
        if (burnAmount > token.balanceOf(a)) burnAmount = token.balanceOf(a);
        uint256 withdrawAmount = (coll * bound(withdrawBps, 0, 10_000)) / 10_000;
        vm.prank(a);
        try vault.burnAndWithdraw(id, burnAmount, withdrawAmount) {} catch {}
    }

    function movePrice(uint256 priceUsd) external {
        feed.setPrice(int256(bound(priceUsd, 50, 1000)) * 1e8, block.timestamp);
    }

    function liquidate(uint256 actorSeed, uint256 burnAmount) external {
        address a = actors[actorSeed % actors.length];
        (, uint256 debt) = vault.positions(id, a);
        if (debt == 0) return;
        burnAmount = bound(burnAmount, 1, debt);
        vm.prank(LIQUIDATOR);
        try vault.liquidatePosition(id, a, burnAmount) {
            liquidations++;
        } catch {}
    }

    function _price() internal view returns (uint256) {
        return uint256(feed.answer()) * 1e10;
    }
}

contract InvaraVaultInvariantTest is Test {
    InvaraVault public vault;
    MockUSDC public usdc;
    InvaraSyntheticToken public token;
    VaultHandler public handler;

    bytes32 public constant ID = bytes32(uint256(1));
    uint256 public constant CEILING = 1000e18;

    function setUp() public {
        vm.warp(10000);
        usdc = new MockUSDC();
        InvaraChainlinkOracle oracle = new InvaraChainlinkOracle();
        vault = new InvaraVault(address(usdc), address(oracle));
        token = new InvaraSyntheticToken("Invara AAPL", "iAAPL", address(vault));
        vault.registerSyntheticToken(ID, address(token), CEILING);
        MockAggregator feed = new MockAggregator(8);
        oracle.setFeed(ID, address(feed), 26 hours);
        feed.setPrice(200e8, block.timestamp);

        handler = new VaultHandler(vault, usdc, token, feed, ID);
        targetContract(address(handler));
    }

    /// @notice The vault holds exactly the collateral recorded in positions
    function invariant_collateralMatchesBalance() public view {
        assertEq(usdc.balanceOf(address(vault)), _sumCollateral());
    }

    /// @notice Recorded debt equals the sum of every position's debt, and never exceeds the ceiling
    function invariant_debtAccounting() public view {
        assertEq(vault.totalDebt(ID), _sumDebt());
        assertLe(vault.totalDebt(ID), CEILING);
    }

    /// @notice Every iAAPL in circulation is either backed by open debt or recorded as bad debt
    function invariant_supplyMatchesDebt() public view {
        assertEq(token.totalSupply(), vault.totalDebt(ID) + vault.badDebt(ID));
    }

    /// @notice No position with debt has less than MIN_COLLATERAL (no dust, no debt on zero collateral)
    function invariant_noDustPositions() public view {
        for (uint256 i = 0; i <= handler.actorCount(); i++) {
            (uint256 coll, uint256 debt) = vault.positions(ID, _account(i));
            assertTrue(debt == 0 || coll >= vault.MIN_COLLATERAL());
        }
    }

    function _sumCollateral() internal view returns (uint256 sum) {
        for (uint256 i = 0; i <= handler.actorCount(); i++) {
            (uint256 coll,) = vault.positions(ID, _account(i));
            sum += coll;
        }
    }

    function _sumDebt() internal view returns (uint256 sum) {
        for (uint256 i = 0; i <= handler.actorCount(); i++) {
            (, uint256 debt) = vault.positions(ID, _account(i));
            sum += debt;
        }
    }

    /// @dev Index 0..n-1 are the borrowers, n is the liquidator
    function _account(uint256 i) internal view returns (address) {
        return i < handler.actorCount() ? handler.actors(i) : handler.LIQUIDATOR();
    }
}
