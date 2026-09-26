// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockCredits is ERC721 {
    mapping(address => uint256[]) private _owned;
    mapping(uint256 => uint256) private _ownedAt; // 1-based

    constructor() ERC721("Credits", "CREDIT") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
    function tokensOf(address o) external view returns (uint256[] memory) { return _owned[o]; }
    /// Mirrors real Credits.burn(owner, ids): caller must be owner or approved-for-all.
    function burn(address owner_, uint256[] calldata ids) external {
        require(msg.sender == owner_ || isApprovedForAll(owner_, msg.sender), "not approved");
        for (uint256 i; i < ids.length; ++i) {
            require(_ownerOf(ids[i]) == owner_, "not owner");
            _burn(ids[i]);
        }
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        if (from != address(0)) {
            uint256 i = _ownedAt[id] - 1;
            uint256[] storage a = _owned[from];
            uint256 last = a[a.length - 1];
            a[i] = last;
            _ownedAt[last] = i + 1;
            a.pop();
            delete _ownedAt[id];
        }
        if (to != address(0)) {
            _owned[to].push(id);
            _ownedAt[id] = _owned[to].length;
        }
    }
}

/// Stand-in for the real Statement assembler: burns 80 Credits owned by caller, safe-mints a Statement.
contract MockStatements is ERC721 {
    MockCredits public credits;
    uint256 public next = 1;
    uint256 public cap = 1526;
    constructor(MockCredits c) ERC721("Statements", "STMT") { credits = c; }
    function setCap(uint256 c) external { cap = c; }
    function assemble(uint256[] calldata ids) external returns (uint256 sid) {
        require(ids.length == 80, "need 80");
        require(next <= cap, "cap");
        credits.burn(msg.sender, ids);
        sid = next++;
        _safeMint(msg.sender, sid);
    }
}

contract MockFeed {
    int256 public price; uint256 public updatedAt;
    /// updatedAt == 0 means "always fresh" (local dev); tests set it explicitly.
    constructor(int256 p) { price = p; }
    function set(int256 p, uint256 t) external { price = p; updatedAt = t; }
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 t = updatedAt == 0 ? block.timestamp : updatedAt;
        return (1, price, t, t, 1);
    }
}
