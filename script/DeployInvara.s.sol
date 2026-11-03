// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {InvaraChainlinkOracle} from "../src/InvaraChainlinkOracle.sol";
import {InvaraVault} from "../src/InvaraVault.sol";
import {InvaraSyntheticToken} from "../src/InvaraSyntheticToken.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

contract DeployInvara is Script {
    // Robinhood Chain mainnet (4663), verified on-chain
    address constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant RH_CHAINLINK_AAPL_USD = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    function run() external returns (address vaultAddr, address oracleAddr, address iaaplAddr) {
        // Signs with the encrypted keystore (`--account <name>`); DEPLOYER_PRIVATE_KEY is only for tests
        uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address usdcAddress = vm.envOr("USDC_ADDRESS", RH_USDG);
        address aaplFeed = vm.envOr("AAPL_CHAINLINK_FEED", RH_CHAINLINK_AAPL_USD);
        // Market id for AAPL in the vault (a fixed bytes32 key the app uses)
        bytes32 aaplMarketId =
            vm.envOr("AAPL_PRICE_ID", bytes32(0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688));
        // Feed updates at least every 24h on trading days; 26h tolerates a late heartbeat, weekends pause
        uint256 maxAge = vm.envOr("AAPL_MAX_PRICE_AGE", uint256(26 hours));
        // Permanent cap on outstanding iAAPL (18 decimals); default 50 iAAPL (low cap until a formal audit)
        uint256 aaplCeiling = vm.envOr("AAPL_DEBT_CEILING", uint256(50e18));

        // Robinhood Chain mainnet: refuse anything but USDG and the official Chainlink AAPL/USD feed
        if (block.chainid == 4663) {
            require(usdcAddress == RH_USDG, "USDC_ADDRESS is not USDG on 4663");
            require(aaplFeed == RH_CHAINLINK_AAPL_USD, "AAPL feed is not Chainlink AAPL/USD on 4663");
        }
        require(usdcAddress.code.length > 0, "collateral token has no code on this chain");
        require(aaplFeed.code.length > 0, "AAPL feed has no code on this chain");
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(aaplFeed).latestRoundData();
        require(answer > 0 && updatedAt > 0, "AAPL feed returned no price");

        if (deployerPrivateKey != 0) vm.startBroadcast(deployerPrivateKey);
        else vm.startBroadcast();

        InvaraChainlinkOracle oracle = new InvaraChainlinkOracle();
        oracle.setFeed(aaplMarketId, aaplFeed, uint32(maxAge));
        InvaraVault vault = new InvaraVault(usdcAddress, address(oracle));
        InvaraSyntheticToken iaapl = new InvaraSyntheticToken("Invara AAPL", "iAAPL", address(vault));
        vault.registerSyntheticToken(aaplMarketId, address(iaapl), aaplCeiling);

        vm.stopBroadcast();

        console.log("InvaraChainlinkOracle deployed at:", address(oracle));
        console.log("InvaraVault deployed at:", address(vault));
        console.log("InvaraSyntheticToken deployed at:", address(iaapl));

        return (address(vault), address(oracle), address(iaapl));
    }
}
