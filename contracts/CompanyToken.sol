// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title CompanyToken — fixed-supply ERC-20 for one company
 * @notice The entire supply is minted once, in the constructor, directly to
 *   its final holders. There is no owner, no mint, no pause, no blacklist, no
 *   fee and no upgrade path. Nothing can change after deployment.
 *
 * @dev Deployed by CompanyTokenFactory with `new` (CREATE2). It is not a
 *   proxy or a clone: each deployment is a complete, independent contract,
 *   so there is no implementation address to trust and nothing for a token
 *   scanner to flag as proxied.
 *
 * @dev Every allocation is delivered in the same transaction that creates the
 *   supply. A holder is never asked to arm its balance with a second call, so
 *   there is no window in which tokens exist but are not yet usable by the
 *   contract meant to hold them.
 */
contract CompanyToken is ERC20 {
    error NoAllocations();
    error LengthMismatch();
    error ZeroRecipient();
    error ZeroAmount();

    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory recipients,
        uint256[] memory amounts
    ) ERC20(name_, symbol_) {
        uint256 n = recipients.length;
        if (n == 0) revert NoAllocations();
        if (n != amounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < n; ++i) {
            if (recipients[i] == address(0)) revert ZeroRecipient();
            if (amounts[i] == 0) revert ZeroAmount();
            _mint(recipients[i], amounts[i]);
        }
    }
}
