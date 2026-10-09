// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title InvaraChainlinkOracle
/// @notice Reads Chainlink Data Feeds (Robinhood Chain's official oracle) and normalizes prices to 18 decimals.
/// @dev Each market is bound to one feed exactly once by the deployer; bindings can never be changed or removed.
contract InvaraChainlinkOracle is IPriceOracle {
    /// @notice Only allowed to bind a feed to a new market; holds no other power
    address public immutable DEPLOYER;

    /// @notice Upper bound for a feed's staleness limit
    uint256 public constant MAX_ALLOWED_AGE = 7 days;
    uint256 private constant TARGET_DECIMALS = 18;

    struct Feed {
        AggregatorV3Interface aggregator;
        uint32 maxAge; // seconds a price may be old before it is rejected
        uint8 decimals;
    }

    mapping(bytes32 => Feed) public feeds;

    error OnlyDeployer();
    error ZeroAddress();
    error InvalidMaxAge();
    error FeedAlreadySet();
    error FeedNotSet();
    error InvalidPrice();
    error StalePrice(uint256 updatedAt);

    event FeedSet(bytes32 indexed marketId, address indexed aggregator, uint32 maxAge, uint8 decimals);

    constructor() {
        DEPLOYER = msg.sender;
    }

    /// @notice Binds a market to a Chainlink feed, permanently
    function setFeed(bytes32 marketId, address aggregator, uint32 maxAge) external {
        if (msg.sender != DEPLOYER) revert OnlyDeployer();
        if (aggregator == address(0)) revert ZeroAddress();
        if (maxAge == 0 || maxAge > MAX_ALLOWED_AGE) revert InvalidMaxAge();
        if (address(feeds[marketId].aggregator) != address(0)) revert FeedAlreadySet();

        uint8 dec = AggregatorV3Interface(aggregator).decimals();
        feeds[marketId] = Feed(AggregatorV3Interface(aggregator), maxAge, dec);
        emit FeedSet(marketId, aggregator, maxAge, dec);
    }

    /// @inheritdoc IPriceOracle
    function getAssetPrice(bytes32 marketId) external view returns (uint256 priceNormalized) {
        Feed memory f = feeds[marketId];
        if (address(f.aggregator) == address(0)) revert FeedNotSet();

        (, int256 answer,, uint256 updatedAt,) = f.aggregator.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > f.maxAge) {
            revert StalePrice(updatedAt);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer);
        if (f.decimals <= TARGET_DECIMALS) {
            priceNormalized = price * 10 ** (TARGET_DECIMALS - f.decimals);
        } else {
            priceNormalized = price / 10 ** (f.decimals - TARGET_DECIMALS);
        }
    }
}
