// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISyntheticToken} from "./interfaces/ISyntheticToken.sol";

/// @title InvaraSyntheticToken
/// @notice Non-custodial synthetic stock token ($iAAPL, $iNVDA) controlled exclusively by InvaraVault.
contract InvaraSyntheticToken is ERC20, ISyntheticToken {
    address public immutable override VAULT;

    error OnlyVault();
    error ZeroAddress();

    constructor(string memory name_, string memory symbol_, address vault_) ERC20(name_, symbol_) {
        if (vault_ == address(0)) revert ZeroAddress();
        VAULT = vault_;
    }

    modifier onlyVault() {
        _checkVault();
        _;
    }

    function _checkVault() internal view {
        if (msg.sender != VAULT) revert OnlyVault();
    }

    function mint(address to, uint256 amount) external override onlyVault {
        _mint(to, amount);
    }

    function burnFrom(address account, uint256 amount) external override onlyVault {
        _burn(account, amount);
    }
}
