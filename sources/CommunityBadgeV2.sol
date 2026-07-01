// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CommunityBadgeV2
 * @dev Non-transferable Soulbound ERC-721 badges.
 *      CommunityHub + authorizedMinters can mint.
 */
contract CommunityBadgeV2 {
    // ============================================================
    //  Types
    // ============================================================

    struct BadgeType {
        string  name;
        string  description;
        string  imageURI;
        uint8   tier;        // 1=Bronze 2=Silver 3=Gold 4=Diamond 5=Legendary
        uint8   category;    // 1=CheckIn 2=Holding 3=Activity 4=Governance 5=Special
        uint256 mintedCount;
        uint256 maxSupply;
    }

    // ============================================================
    //  Constants
    // ============================================================

    string public constant name     = "GDC Autonomous Community Badge";
    string public constant symbol   = "GACB";
    bool   public constant SOULBOUND = true;

    // ============================================================
    //  State
    // ============================================================

    address public owner;
    address public hub;
    string  public baseURI;

    uint256 private _nextTokenId;
    uint256 private _nextBadgeTypeId;

    mapping(uint256 => address)      private _tokenOwner;
    mapping(address => uint256)      public  balanceOf;
    mapping(uint256 => string)       private _customTokenURI;
    mapping(uint256 => uint256)      public  mintedAt;
    mapping(uint256 => uint256)      public  badgeTypeOf;
    mapping(uint256 => BadgeType)    public  badgeTypes;
    mapping(address => uint256[])    public  tokensOfOwner;
    mapping(address => mapping(uint256 => bool)) public hasBadge;

    mapping(address => bool) public authorizedMinters;

    // ============================================================
    //  Events
    // ============================================================

    event MinterUpdated(address indexed minter, bool enabled);
    event BadgeTypeCreated(uint256 indexed badgeTypeId, string name, uint8 tier, uint8 category);
    event BadgeMinted(address indexed to, uint256 indexed tokenId, uint256 indexed badgeTypeId, string name);
    event BadgeTypeUpdated(uint256 indexed badgeTypeId, string name, uint256 maxSupply);
    event TokenURIUpdated(uint256 indexed tokenId, string uri);
    event BaseURIUpdated(string uri);

    // ============================================================
    //  Errors
    // ============================================================

    error SoulboundTransfer();
    error NotAuthorized();
    error BadgeTypeNotFound();
    error MaxSupplyReached();
    error AlreadyOwned();
    error TokenNotFound();

    // ============================================================
    //  Modifiers
    // ============================================================

    modifier onlyOwner() { if (msg.sender != owner) revert NotAuthorized(); _; }
    modifier onlyMinter() {
        if (msg.sender != hub && !authorizedMinters[msg.sender]) revert NotAuthorized();
        _;
    }

    // ============================================================
    //  Constructor — Latin names (matching on-chain V1)
    // ============================================================

    constructor(address hubAddr) {
        require(hubAddr != address(0), "Invalid hub");
        owner = msg.sender;
        hub   = hubAddr;

        // Cat 1: Chronos (Check-in)
        _addBadgeType("AURUM",      "First light across the chain. The journey begins.",                         "", 1, 1, 0);
        _addBadgeType("CANDOR",     "Seven dawns. You have learned to keep the flame.",                         "", 2, 1, 0);
        _addBadgeType("FIDES",      "The first moon. What was a choice becomes a covenant.",                    "", 3, 1, 0);
        _addBadgeType("ADAMANT",    "Ninety days. The fire of conviction outlasts the forge.",                   "", 4, 1, 0);
        _addBadgeType("AETERNUS",   "Half a year's watch. The sentinel who never leaves their post.",            "", 4, 1, 0);
        _addBadgeType("INFINITUM",  "A full orbit around the sun. Presence that transcends habit into being.",   "", 5, 1, 0);
        // Cat 2: Gravitas (Holding)
        _addBadgeType("SCRIBE",     "100 GDC. The first entry in the grand ledger.",                            "", 1, 2, 0);
        _addBadgeType("ARCHON",     "500 GDC. A voice that carries weight in the assembly.",                    "", 2, 2, 0);
        _addBadgeType("PRAETOR",    "2,000 GDC. Steward of the growing republic.",                              "", 3, 2, 0);
        _addBadgeType("CONSUL",     "10,000 GDC. Guardian of the city gates.",                                  "", 4, 2, 0);
        _addBadgeType("IMPERATOR",  "50,000 GDC. A pillar upon which civilization stands.",                     "", 5, 2, 0);
        // Cat 3: Momentum (Activity)
        _addBadgeType("EMBER",      "500 activity. A single spark in the dark.",                                "", 1, 3, 0);
        _addBadgeType("WILDFIRE",   "2,000 activity. One spark becomes a thousand.",                             "", 2, 3, 0);
        _addBadgeType("SUPERNOVA",  "10,000 activity. A force reshaping the horizon.",                           "", 3, 3, 0);
        // Cat 4: Civitas (Governance)
        _addBadgeType("VOX",        "Ten votes. Democracy is the breath of the republic.",                       "", 1, 4, 0);
        _addBadgeType("AUCTOR",     "Three proposals. The pen that drafts the future.",                          "", 2, 4, 0);
        // Cat 5: Primordia (Special)
        _addBadgeType("GENESIS",    "Among the first hundred. Before maps, before roads.",                       "", 4, 5, 100);
        _addBadgeType("NEXUS",      "Five souls guided. The network expands. [RESERVED]",                        "", 2, 5, 0);
        _addBadgeType("ODYSSEY",    "Fifty quests. The journey was the destination.",                            "", 3, 5, 0);
    }

    // ============================================================
    //  Mint (Hub + authorized minters)
    // ============================================================

    function mint(address to, uint256 bTypeId) external onlyMinter returns (uint256 tokenId) {
        return _mintWithURI(to, bTypeId, "");
    }

    function mintWithURI(address to, uint256 bTypeId, string memory uri) external onlyMinter returns (uint256 tokenId) {
        return _mintWithURI(to, bTypeId, uri);
    }

    // Owner migration function — mints one user's badge types
    function ownerMint(address to, uint256[] calldata bTypeIds) external onlyOwner {
        uint256 mintedCount = 0;
        for (uint256 i = 0; i < bTypeIds.length; i++) {
            BadgeType storage bt = badgeTypes[bTypeIds[i]];
            if (bytes(bt.name).length == 0) continue;
            if (hasBadge[to][bTypeIds[i]]) continue;
            if (bt.maxSupply > 0 && bt.mintedCount >= bt.maxSupply) continue;

            uint256 tid = _nextTokenId++;
            _tokenOwner[tid] = to;
            balanceOf[to]++;
            mintedAt[tid]     = block.timestamp;
            badgeTypeOf[tid]  = bTypeIds[i];
            tokensOfOwner[to].push(tid);
            hasBadge[to][bTypeIds[i]] = true;
            bt.mintedCount++;
            emit BadgeMinted(to, tid, bTypeIds[i], bt.name);
            mintedCount++;
        }
    }

    // Batch migrate: accepts pre-grouped data (owner+their badgeTypes)
    // owners[i] = address, bTypeIds[j] = types for that address
    // sizes[i] = number of badge types for owners[i]
    function migrateBatch(
        address[] calldata owners,
        uint256[] calldata bTypeIds,
        uint256[] calldata sizes
    ) external onlyOwner {
        uint256 idx = 0;
        for (uint256 o = 0; o < owners.length; o++) {
            address to = owners[o];
            uint256 len = sizes[o];
            for (uint256 j = 0; j < len; j++) {
                uint256 btId = bTypeIds[idx];
                idx++;

                BadgeType storage bt = badgeTypes[btId];
                if (bytes(bt.name).length == 0) continue;
                if (hasBadge[to][btId]) continue;
                if (bt.maxSupply > 0 && bt.mintedCount >= bt.maxSupply) continue;

                uint256 tid = _nextTokenId++;
                _tokenOwner[tid] = to;
                balanceOf[to]++;
                mintedAt[tid]     = block.timestamp;
                badgeTypeOf[tid]  = btId;
                tokensOfOwner[to].push(tid);
                hasBadge[to][btId] = true;
                bt.mintedCount++;
                emit BadgeMinted(to, tid, btId, bt.name);
            }
        }
    }

    function batchMint(address to, uint256[] calldata bTypeIds, string[] calldata uris)
        external onlyMinter returns (uint256[] memory tokenIds)
    {
        require(bTypeIds.length == uris.length, "Length mismatch");
        tokenIds = new uint256[](bTypeIds.length);
        for (uint256 i = 0; i < bTypeIds.length; i++) {
            BadgeType storage bt = badgeTypes[bTypeIds[i]];
            if (bytes(bt.name).length == 0) continue;
            if (hasBadge[to][bTypeIds[i]]) continue;
            if (bt.maxSupply > 0 && bt.mintedCount >= bt.maxSupply) continue;

            uint256 tid = _nextTokenId++;
            _tokenOwner[tid] = to;
            balanceOf[to]++;
            if (bytes(uris[i]).length > 0) _customTokenURI[tid] = uris[i];
            mintedAt[tid]     = block.timestamp;
            badgeTypeOf[tid]  = bTypeIds[i];
            tokensOfOwner[to].push(tid);
            hasBadge[to][bTypeIds[i]] = true;
            bt.mintedCount++;
            tokenIds[i] = tid;
            emit BadgeMinted(to, tid, bTypeIds[i], bt.name);
        }
    }

    // ============================================================
    //  Admin
    // ============================================================

    function createBadgeType(
        string calldata badgeName, string calldata desc, string calldata imgURI,
        uint8 tier, uint8 category, uint256 maxSupply
    ) external onlyOwner returns (uint256 id) {
        id = _addBadgeType(badgeName, desc, imgURI, tier, category, maxSupply);
        emit BadgeTypeCreated(id, badgeName, tier, category);
    }

    function updateBadgeType(uint256 bTypeId, string calldata badgeName, string calldata desc, string calldata imgURI, uint256 maxSupply) external onlyOwner {
        BadgeType storage bt = badgeTypes[bTypeId];
        if (bytes(bt.name).length == 0) revert BadgeTypeNotFound();
        bt.name        = badgeName;
        bt.description = desc;
        bt.imageURI    = imgURI;
        bt.maxSupply   = maxSupply;
        emit BadgeTypeUpdated(bTypeId, badgeName, maxSupply);
    }

    function setHub(address newHub) external onlyOwner {
        require(newHub != address(0), "Invalid hub");
        hub = newHub;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid addr");
        owner = newOwner;
    }

    function setMinter(address minter, bool enabled) external onlyOwner {
        authorizedMinters[minter] = enabled;
        emit MinterUpdated(minter, enabled);
    }

    // ============================================================
    //  NEW: setTokenURI + setBaseURI
    // ============================================================

    function setTokenURI(uint256 tokenId, string calldata uri) external onlyOwner {
        if (_tokenOwner[tokenId] == address(0)) revert TokenNotFound();
        _customTokenURI[tokenId] = uri;
        emit TokenURIUpdated(tokenId, uri);
    }

    function setBaseURI(string calldata uri) external onlyOwner {
        baseURI = uri;
        emit BaseURIUpdated(uri);
    }

    // ============================================================
    //  ERC-721 Queries
    // ============================================================

    function ownerOf(uint256 tokenId) external view returns (address) {
        address a = _tokenOwner[tokenId];
        if (a == address(0)) revert TokenNotFound();
        return a;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_tokenOwner[tokenId] == address(0)) revert TokenNotFound();

        // 1) Custom per-token URI takes priority
        if (bytes(_customTokenURI[tokenId]).length > 0) {
            return _customTokenURI[tokenId];
        }

        // 2) Fallback: baseURI + badgeTypeId + ".json"
        uint256 btId = badgeTypeOf[tokenId];
        // String concatenation without openzeppelin
        return string(
            abi.encodePacked(
                baseURI,
                _uint2str(btId),
                ".json"
            )
        );
    }

    function totalSupply() external view returns (uint256) {
        return _nextTokenId;
    }

    function getBadgeType(uint256 bTypeId) external view returns (BadgeType memory) {
        if (bytes(badgeTypes[bTypeId].name).length == 0) revert BadgeTypeNotFound();
        return badgeTypes[bTypeId];
    }

    function getBadgeTypeCount() external view returns (uint256) {
        return _nextBadgeTypeId;
    }

    function getTokensOfOwner(address a) external view returns (uint256[] memory) {
        return tokensOfOwner[a];
    }

    function userHasBadges(address usr, uint256[] calldata bTypeIds) external view returns (bool[] memory result) {
        result = new bool[](bTypeIds.length);
        for (uint256 i = 0; i < bTypeIds.length; i++) {
            result[i] = hasBadge[usr][bTypeIds[i]];
        }
    }

    // ============================================================
    //  Soulbound
    // ============================================================

    function transferFrom(address, address, uint256) external pure { revert SoulboundTransfer(); }
    function safeTransferFrom(address, address, uint256) external pure { revert SoulboundTransfer(); }
    function safeTransferFrom(address, address, uint256, bytes memory) external pure { revert SoulboundTransfer(); }
    function approve(address, uint256) external pure { revert SoulboundTransfer(); }
    function setApprovalForAll(address, bool) external pure { revert SoulboundTransfer(); }
    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }

    // ============================================================
    //  ERC-165
    // ============================================================

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7  // ERC165
            || interfaceId == 0x80ac58cd  // ERC721
            || interfaceId == 0x5b5e139f; // ERC721Metadata
    }

    // ============================================================
    //  Internal
    // ============================================================

    function _addBadgeType(string memory badgeName, string memory desc, string memory imgURI, uint8 tier, uint8 category, uint256 maxSupply) internal returns (uint256 id) {
        id = _nextBadgeTypeId++;
        badgeTypes[id] = BadgeType(badgeName, desc, imgURI, tier, category, 0, maxSupply);
    }

    function _mintWithURI(address to, uint256 bTypeId, string memory uri) internal returns (uint256 tokenId) {
        BadgeType storage bt = badgeTypes[bTypeId];
        if (bytes(bt.name).length == 0) revert BadgeTypeNotFound();
        if (hasBadge[to][bTypeId]) revert AlreadyOwned();
        if (bt.maxSupply > 0 && bt.mintedCount >= bt.maxSupply) revert MaxSupplyReached();

        tokenId = _nextTokenId++;
        _tokenOwner[tokenId] = to;
        balanceOf[to]++;
        if (bytes(uri).length > 0) _customTokenURI[tokenId] = uri;
        mintedAt[tokenId]    = block.timestamp;
        badgeTypeOf[tokenId] = bTypeId;
        tokensOfOwner[to].push(tokenId);
        hasBadge[to][bTypeId] = true;
        bt.mintedCount++;

        emit BadgeMinted(to, tokenId, bTypeId, bt.name);
    }

    function _uint2str(uint256 n) internal pure returns (string memory) {
        if (n == 0) return "0";
        uint256 len;
        uint256 m = n;
        while (m > 0) { len++; m /= 10; }
        bytes memory b = new bytes(len);
        while (n > 0) {
            b[--len] = bytes1(uint8(48 + n % 10));
            n /= 10;
        }
        return string(b);
    }
}
