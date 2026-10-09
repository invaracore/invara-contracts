// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployInvara} from "../script/DeployInvara.s.sol";
import {InvaraVault} from "../src/InvaraVault.sol";
import {InvaraChainlinkOracle} from "../src/InvaraChainlinkOracle.sol";
import {InvaraSyntheticToken} from "../src/InvaraSyntheticToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

contract DeployInvaraTest is Test {
    DeployInvara public deployer;
    MockUSDC public usdc;
    MockAggregator public feed;

    bytes32 public constant AAPL_PRICE_ID = bytes32(uint256(1));

    function setUp() public {
        usdc = new MockUSDC();
        feed = new MockAggregator(8);
        feed.setPrice(332e8, block.timestamp);
        deployer = new DeployInvara();

        vm.setEnv("DEPLOYER_PRIVATE_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
        vm.setEnv("USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("AAPL_CHAINLINK_FEED", vm.toString(address(feed)));
        vm.setEnv("AAPL_PRICE_ID", vm.toString(AAPL_PRICE_ID));
    }

    function testDeploymentScript() public {
        (address vaultAddr, address oracleAddr, address iaaplAddr) = deployer.run();

        assertTrue(vaultAddr != address(0));
        assertTrue(oracleAddr != address(0));
        assertTrue(iaaplAddr != address(0));

        InvaraVault vault = InvaraVault(vaultAddr);
        assertEq(address(vault.USDC()), address(usdc));
        assertEq(address(vault.ORACLE_ADAPTER()), oracleAddr);

        InvaraSyntheticToken iaapl = InvaraSyntheticToken(iaaplAddr);
        assertEq(iaapl.VAULT(), vaultAddr);
        assertEq(vault.debtCeiling(AAPL_PRICE_ID), 1000e18);

        InvaraChainlinkOracle oracle = InvaraChainlinkOracle(oracleAddr);
        (AggregatorV3Interface agg, uint32 maxAge,) = oracle.feeds(AAPL_PRICE_ID);
        assertEq(address(agg), address(feed));
        assertEq(maxAge, 26 hours);
        assertEq(oracle.getAssetPrice(AAPL_PRICE_ID), 332e18);
    }
}
