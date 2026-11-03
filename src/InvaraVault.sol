// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISyntheticToken} from "./interfaces/ISyntheticToken.sol";

/// @title InvaraVault
/// @notice Non-custodial, keyless synthetic stock vault with 130% MCR, 105% liquidation incentive, and zero admin pause keys.
contract InvaraVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    IPriceOracle public immutable ORACLE_ADAPTER;
    /// @notice Only allowed to register synthetic tokens; holds no other power (no pause, no funds access)
    address public immutable DEPLOYER;

    uint256 public constant MCR = 130; // Minimum Collateral Ratio: 130%
    uint256 public constant LIQUIDATION_BONUS = 105; // 5% bonus for liquidators
    uint256 public constant PERCENT_BASE = 100;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant USDC_DECIMALS_OFFSET = 1e12; // Scale 6-decimal USDC to 18 decimals
    /// @notice Positions with debt must hold at least 100 units of the 6-decimal collateral (no dust positions)
    uint256 public constant MIN_COLLATERAL = 100 * 1e6;

    struct VaultPosition {
        uint256 collateralAmount; // 6 decimals (USDC)
        uint256 syntheticMinted; // 18 decimals
    }

    mapping(bytes32 => mapping(address => VaultPosition)) public positions;
    mapping(bytes32 => ISyntheticToken) public syntheticTokens;
    /// @notice Maximum outstanding synthetic debt per market, fixed at registration
    mapping(bytes32 => uint256) public debtCeiling;
    /// @notice Outstanding synthetic debt per market
    mapping(bytes32 => uint256) public totalDebt;
    /// @notice Cumulative debt written off per market (synthetic units left unbacked by liquidated positions)
    mapping(bytes32 => uint256) public badDebt;

    error ZeroAddress();
    error ZeroDebtCeiling();
    error BelowMCR();
    error BelowMinCollateral();
    error DebtCeilingExceeded();
    error PositionHealthy();
    error TokenNotRegistered();
    error AlreadyRegistered();
    error OnlyDeployer();
    error VaultMismatch();

    event SyntheticRegistered(bytes32 indexed priceId, address indexed token, uint256 debtCeiling);
    event VaultDeposited(
        bytes32 indexed priceId, address indexed user, uint256 collateralAdded, uint256 syntheticMinted
    );
    event VaultWithdrawn(
        bytes32 indexed priceId, address indexed user, uint256 collateralRemoved, uint256 syntheticBurned
    );
    event PositionLiquidated(
        bytes32 indexed priceId,
        address indexed borrower,
        address indexed liquidator,
        uint256 debtBurned,
        uint256 collateralSeized
    );
    event BadDebtWrittenOff(bytes32 indexed priceId, address indexed borrower, uint256 debtWrittenOff);

    constructor(address _usdc, address _oracleAdapter) {
        if (_usdc == address(0) || _oracleAdapter == address(0)) revert ZeroAddress();
        USDC = IERC20(_usdc);
        ORACLE_ADAPTER = IPriceOracle(_oracleAdapter);
        DEPLOYER = msg.sender;
    }

    /// @notice Binds a synthetic asset token to a Pyth price feed ID, with a permanent debt ceiling
    function registerSyntheticToken(bytes32 priceId, address tokenAddress, uint256 ceiling) external {
        if (msg.sender != DEPLOYER) revert OnlyDeployer();
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (ceiling == 0) revert ZeroDebtCeiling();
        if (ISyntheticToken(tokenAddress).VAULT() != address(this)) revert VaultMismatch();
        if (address(syntheticTokens[priceId]) != address(0)) revert AlreadyRegistered();
        syntheticTokens[priceId] = ISyntheticToken(tokenAddress);
        debtCeiling[priceId] = ceiling;
        emit SyntheticRegistered(priceId, tokenAddress, ceiling);
    }

    /// @notice Deposit USDC collateral and mint synthetic equity token ($iAAPL, $iNVDA)
    function depositAndMint(bytes32 priceId, uint256 collateralAmount, uint256 mintAmount) external {
        ISyntheticToken synToken = syntheticTokens[priceId];
        if (address(synToken) == address(0)) revert TokenNotRegistered();

        VaultPosition storage pos = positions[priceId][msg.sender];

        if (collateralAmount > 0) {
            pos.collateralAmount += collateralAmount;
        }

        if (mintAmount > 0) {
            if (totalDebt[priceId] + mintAmount > debtCeiling[priceId]) revert DebtCeilingExceeded();
            totalDebt[priceId] += mintAmount;
            pos.syntheticMinted += mintAmount;
            _validateHealth(priceId, msg.sender);
        }
        _validateMinCollateral(pos);

        emit VaultDeposited(priceId, msg.sender, collateralAmount, mintAmount);

        if (collateralAmount > 0) {
            USDC.safeTransferFrom(msg.sender, address(this), collateralAmount);
        }

        if (mintAmount > 0) {
            synToken.mint(msg.sender, mintAmount);
        }
    }

    /// @notice Burn synthetic stock tokens and withdraw USDC collateral
    function burnAndWithdraw(bytes32 priceId, uint256 burnAmount, uint256 withdrawAmount) external {
        ISyntheticToken synToken = syntheticTokens[priceId];
        if (address(synToken) == address(0)) revert TokenNotRegistered();

        VaultPosition storage pos = positions[priceId][msg.sender];

        if (burnAmount > 0) {
            pos.syntheticMinted -= burnAmount;
            totalDebt[priceId] -= burnAmount;
        }

        if (withdrawAmount > 0) {
            pos.collateralAmount -= withdrawAmount;
            if (pos.syntheticMinted > 0) {
                _validateHealth(priceId, msg.sender);
            }
        }
        _validateMinCollateral(pos);

        emit VaultWithdrawn(priceId, msg.sender, withdrawAmount, burnAmount);

        if (burnAmount > 0) {
            synToken.burnFrom(msg.sender, burnAmount);
        }

        if (withdrawAmount > 0) {
            USDC.safeTransfer(msg.sender, withdrawAmount);
        }
    }

    /// @notice Permissionless liquidation of undercollateralized positions (< 130% MCR).
    /// @dev The liquidator always receives 105% of the burned debt's value. If the position cannot cover that
    ///      (collateral below 105%), the burn is reduced to what the collateral pays for, all collateral is seized,
    ///      and the remaining debt is written off and recorded in `badDebt`.
    ///      A partial liquidation that would leave debt backed by less than MIN_COLLATERAL liquidates the whole
    ///      position instead, so the liquidator must then burn the full debt.
    function liquidatePosition(bytes32 priceId, address borrower, uint256 burnAmount) external {
        ISyntheticToken synToken = syntheticTokens[priceId];
        if (address(synToken) == address(0)) revert TokenNotRegistered();
        if (_isHealthy(priceId, borrower)) revert PositionHealthy();

        VaultPosition storage pos = positions[priceId][borrower];
        if (burnAmount > pos.syntheticMinted) {
            burnAmount = pos.syntheticMinted;
        }

        uint256 assetPrice = ORACLE_ADAPTER.getAssetPrice(priceId);
        uint256 collateralToSeize;
        (collateralToSeize, burnAmount) = _liquidationAmounts(assetPrice, pos.collateralAmount, burnAmount);

        // Never leave a dust position: if debt would remain on less than MIN_COLLATERAL, liquidate all of it
        if (burnAmount < pos.syntheticMinted && pos.collateralAmount - collateralToSeize < MIN_COLLATERAL) {
            (collateralToSeize, burnAmount) = _liquidationAmounts(assetPrice, pos.collateralAmount, pos.syntheticMinted);
        }

        pos.syntheticMinted -= burnAmount;
        pos.collateralAmount -= collateralToSeize;
        totalDebt[priceId] -= burnAmount;

        emit PositionLiquidated(priceId, borrower, msg.sender, burnAmount, collateralToSeize);

        // No collateral left but debt remains: write it off so the position is closed and the loss is on record
        if (pos.collateralAmount == 0 && pos.syntheticMinted > 0) {
            uint256 writtenOff = pos.syntheticMinted;
            pos.syntheticMinted = 0;
            totalDebt[priceId] -= writtenOff;
            badDebt[priceId] += writtenOff;
            emit BadDebtWrittenOff(priceId, borrower, writtenOff);
        }

        synToken.burnFrom(msg.sender, burnAmount);
        USDC.safeTransfer(msg.sender, collateralToSeize);
    }

    /// @dev Collateral to seize for burning `burnAmount` of debt: 105% of its value in USDC (6 decimals). When the
    ///      collateral can't pay that, all of it is seized and the burn shrinks to the debt it covers (rounded up).
    function _liquidationAmounts(uint256 assetPrice, uint256 collateral, uint256 burnAmount)
        internal
        pure
        returns (uint256 collateralToSeize, uint256 burn)
    {
        burn = burnAmount;
        collateralToSeize = (burn * assetPrice * LIQUIDATION_BONUS) / (PRECISION * USDC_DECIMALS_OFFSET * PERCENT_BASE);
        if (collateralToSeize > collateral) {
            collateralToSeize = collateral;
            uint256 covered =
                _ceilDiv(collateral * PRECISION * USDC_DECIMALS_OFFSET * PERCENT_BASE, assetPrice * LIQUIDATION_BONUS);
            if (covered < burn) burn = covered;
        }
    }

    function _isHealthy(bytes32 priceId, address user) internal view returns (bool) {
        VaultPosition memory pos = positions[priceId][user];
        if (pos.syntheticMinted == 0) return true;

        uint256 assetPrice = ORACLE_ADAPTER.getAssetPrice(priceId);
        uint256 collateralValueUsd = pos.collateralAmount * USDC_DECIMALS_OFFSET;
        uint256 requiredCollateralUsd = (pos.syntheticMinted * assetPrice * MCR) / (PRECISION * PERCENT_BASE);

        return collateralValueUsd >= requiredCollateralUsd;
    }

    function _validateHealth(bytes32 priceId, address user) internal view {
        if (!_isHealthy(priceId, user)) revert BelowMCR();
    }

    function _validateMinCollateral(VaultPosition storage pos) internal view {
        if (pos.syntheticMinted > 0 && pos.collateralAmount < MIN_COLLATERAL) revert BelowMinCollateral();
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
