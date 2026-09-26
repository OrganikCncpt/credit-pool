// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IStatementAssembler} from "./IStatementAssembler.sol";

/// @title AssemblyVault
/// @notice Custody firewall between the pool and the Statements contract. Assembly needs the
///         Statements contract to hold approval over the Credits it burns. If the pool granted
///         that approval directly, the assembler could reach every Credit in the pool. Instead,
///         for each assembly the pool moves exactly one batch's 80 Credits here, and only this
///         vault ever approves the assembler. Nothing of any depositor's is in the vault before or
///         after a call (only stray tokens someone donated, which belong to no batch), so even a
///         malicious assembler can reach nothing of value but the 80 Credits being assembled.
/// @dev    Created by CreditPool in its constructor; only the pool can call it.
contract AssemblyVault is IERC721Receiver {
    IERC721 public immutable credits;
    IERC721 public immutable statements;
    IStatementAssembler public immutable assembler;
    address public immutable pool;

    bool private _active;
    bool private _got;
    uint256 private _gotId;

    // Same names as CreditPool's errors, so their selectors match when they bubble up.
    error OnlyPool();
    error UnexpectedToken();
    error StatementNotReceived();
    error CreditsNotBurned();

    constructor(IERC721 credits_, IERC721 statements_, IStatementAssembler assembler_) {
        credits = credits_;
        statements = statements_;
        assembler = assembler_;
        pool = msg.sender;
    }

    /// @notice Burns `ids` (already moved here by the pool) into one Statement and sends it to the pool.
    /// @dev    All checks are deltas from the start of the call. Anyone can plain-transfer a Credit
    ///         here (no callback), so an absolute "balance must be N" check would let one donated
    ///         token block every future assembly (external audit #1, H-01). Stray tokens are
    ///         simply ignored: they can never be part of a batch.
    function assemble(uint256[] calldata ids) external returns (uint256 sid) {
        if (msg.sender != pool) revert OnlyPool();
        uint256 heldCredits = credits.balanceOf(address(this)); // includes this batch, moved in by the pool
        if (heldCredits < ids.length) revert CreditsNotBurned();
        uint256 heldStatements = statements.balanceOf(address(this));

        credits.setApprovalForAll(address(assembler), true);
        _active = true;
        sid = assembler.assemble(ids);
        _active = false;
        credits.setApprovalForAll(address(assembler), false);

        // If the Statement arrived through onERC721Received, the assembler's return value must agree.
        if (_got) {
            if (_gotId != sid) revert StatementNotReceived();
            _got = false;
        }
        // Exactly this batch left, nothing was pushed in to make the numbers work, and each id is burned.
        if (credits.balanceOf(address(this)) != heldCredits - ids.length) revert CreditsNotBurned();
        for (uint256 i = 0; i < ids.length; ++i) {
            if (!_burned(ids[i])) revert CreditsNotBurned();
        }
        // Exactly one new Statement, and it's the one we were told about.
        if (statements.balanceOf(address(this)) != heldStatements + 1 || statements.ownerOf(sid) != address(this)) {
            revert StatementNotReceived();
        }
        statements.transferFrom(address(this), pool, sid);
    }

    /// @dev Only the Statement minted during an assembly may arrive by safe transfer.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (!_active || msg.sender != address(statements)) revert UnexpectedToken();
        _gotId = tokenId;
        _got = true;
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Burned tokens make ownerOf revert (OZ ERC721, and the real Credits contract).
    ///      If the real Statements contract escrows Credits instead of burning them, relax this
    ///      to "not owned by the vault or the pool" when wiring it in.
    function _burned(uint256 id) internal view returns (bool) {
        try credits.ownerOf(id) returns (address) {
            return false;
        } catch {
            return true;
        }
    }
}
