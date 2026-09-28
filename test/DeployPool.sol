// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {CreditPool} from "../src/CreditPool.sol";
import {CreditStore} from "../src/CreditStore.sol";

/// Deploys a CreditStore and a CreditPool wired to it, as the deploy scripts do. Runs in the
/// caller's context, so the caller owns both.
function deployPool(address credits, address statements, address assembler, address feed, uint256 opensAt, address feeRecipient)
    returns (CreditPool pool)
{
    CreditStore store = new CreditStore();
    pool = new CreditPool(credits, statements, assembler, feed, opensAt, feeRecipient, address(store));
    store.setPool(address(pool));
}
