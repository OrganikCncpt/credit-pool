// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice PLACEHOLDER: the real Statements assembly interface has not been published yet.
///         Swap this signature for the real one before deploying. The pool only needs
///         "burn these 80 Credit ids, mint one Statement to msg.sender" (msg.sender is the
///         AssemblyVault, which holds approval over exactly those 80 Credits).
interface IStatementAssembler {
    function assemble(uint256[] calldata creditIds) external returns (uint256 statementId);
}
