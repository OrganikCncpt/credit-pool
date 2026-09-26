// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CreditArt} from "./CreditArt.sol";

/// @title Credits
/// @notice One token per $8 X Money payment. The seed is the 21-char transaction
///         id; SHA-256 defines four plates and payment time selects which print.
///         After close: distribute from the export, then seal(). The holder may
///         then burn credits. Seeds stay readable after burn.
contract Credits is ERC721, Ownable {
    CreditArt public immutable art;

    uint256 public supply;
    bool public isSealed;
    uint256 public sealedAt;

    mapping(uint256 id => bytes21 seed) public seedOf;
    mapping(uint256 id => uint64 timestamp) public timestampOf;
    mapping(bytes21 seed => uint256 id) public tokenOf;

    mapping(address owner => uint256[] ids) private _owned;
    mapping(uint256 id => uint256 indexPlusOne) private _ownedAt;

    error Sealed();
    error LengthMismatch();
    error EmptyDrop();
    error NoAddress();
    error BadSeed();
    error BadTimestamp();
    error TimestampMismatch();
    error KnownSeed();
    error NotOwner();
    error Duplicate();
    error NotSealed();
    error EmptyBurn();
    error NotApproved();

    event Distributed(uint256 indexed tokenId, address indexed to, bytes21 seed, uint64 paidAt);
    event EditionSealed(uint256 supply);

    constructor(address owner_) ERC721("Credits", "CREDIT") Ownable(owner_) {
        art = new CreditArt();
    }

    /// @notice Mint one token per payment. `seeds` are the transaction ids,
    ///         `to` are the ETH addresses from the memos. Same order, same length.
    function distribute(address[] calldata to, bytes21[] calldata seeds, uint64[] calldata timestamps)
        external
        onlyOwner
    {
        if (isSealed) revert Sealed();
        if (to.length != seeds.length || seeds.length != timestamps.length) revert LengthMismatch();
        if (to.length == 0) revert EmptyDrop();

        uint256 id = supply;
        for (uint256 i; i < to.length; ++i) {
            address recipient = to[i];
            bytes21 seed = seeds[i];
            if (timestamps[i] == 0 || timestamps[i] > block.timestamp) revert BadTimestamp();
            if (recipient == address(0)) revert NoAddress();
            if (!art.valid(seed)) revert BadSeed();
            if (tokenOf[seed] != 0) revert KnownSeed();

            id += 1;
            supply = id;
            seedOf[id] = seed;
            timestampOf[id] = timestamps[i];
            tokenOf[seed] = id;
            _mint(recipient, id);
            emit Distributed(id, recipient, seed, timestamps[i]);
        }
    }

    /// @notice Close the edition. Further distribute calls revert.
    function seal() external onlyOwner {
        if (isSealed) revert Sealed();
        isSealed = true;
        sealedAt = block.timestamp;
        emit EditionSealed(supply);
    }

    /// @notice Burn a batch of credits after the edition is sealed.
    ///         The holder must call, or must have approved the caller for all.
    ///         Seeds remain in seedOf. Returns seeds in the same order.
    function burn(address owner_, uint256[] calldata ids) external returns (bytes21[] memory seeds) {
        if (!isSealed) revert NotSealed();
        if (ids.length == 0) revert EmptyBurn();
        if (msg.sender != owner_ && !isApprovedForAll(owner_, msg.sender)) revert NotApproved();
        seeds = new bytes21[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            for (uint256 j; j < i; ++j) {
                if (ids[j] == id) revert Duplicate();
            }
            if (_ownerOf(id) != owner_) revert NotOwner();
            seeds[i] = seedOf[id];
            _burn(id);
        }
    }

    function tokensOf(address owner_) external view returns (uint256[] memory) {
        return _owned[owner_];
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return art.tokenJSON(tokenId, seedOf[tokenId], timestampOf[tokenId]);
    }

    /// @notice Metadata for a payment id, minted or not. Edition number is 0 until distributed.
    function preview(bytes21 seed, uint64 paidAt) external view returns (string memory) {
        if (!art.valid(seed)) revert BadSeed();
        if (paidAt == 0 || paidAt > block.timestamp) revert BadTimestamp();
        uint256 id = tokenOf[seed];
        if (id != 0 && timestampOf[id] != paidAt) revert TimestampMismatch();
        return art.tokenJSON(id, seed, paidAt);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (from != address(0)) _removeOwned(from, tokenId);
        if (to != address(0)) _addOwned(to, tokenId);
        return from;
    }

    function _addOwned(address owner_, uint256 id) private {
        _owned[owner_].push(id);
        _ownedAt[id] = _owned[owner_].length;
    }

    function _removeOwned(address owner_, uint256 id) private {
        uint256 index = _ownedAt[id] - 1;
        uint256 last = _owned[owner_].length - 1;
        if (index != last) {
            uint256 moved = _owned[owner_][last];
            _owned[owner_][index] = moved;
            _ownedAt[moved] = index + 1;
        }
        _owned[owner_].pop();
        delete _ownedAt[id];
    }
}
