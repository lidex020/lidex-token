// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

contract LdxTokenSale {
    uint256 public constant PRICE_USD_18 = 3_500_000_000_000_000;
    uint256 public constant TGE_BPS = 1_000;
    uint256 public constant MONTHLY_BPS = 1_500;
    uint256 public constant BPS = 10_000;
    uint256 public constant CLIFF = 30 days;
    uint256 public constant MONTH = 30 days;
    uint256 public constant MONTHS = 6;

    enum Asset { USDT, USDC, BNB, ETH }
    struct AssetConfig { address token; address feed; bool enabled; }
    struct Allocation { uint256 purchased; uint256 claimed; uint64 tge; }

    IERC20 public immutable ldx;
    address public owner;
    address public pendingOwner;
    address public paymentRecipient;
    bool public paused;
    uint256 public saleStart;
    uint256 public saleEnd;
    uint256 public maxSale;
    uint256 public sold;
    mapping(Asset => AssetConfig) public assets;
    mapping(address => Allocation) public allocations;

    event Purchased(address indexed buyer, Asset indexed asset, uint256 paymentAmount, uint256 ldxAmount);
    event Claimed(address indexed beneficiary, uint256 amount);
    event AssetConfigured(Asset indexed asset, address token, address feed, bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier whenNotPaused() { require(!paused, "paused"); _; }
    modifier nonReentrant() { require(_locked == 1, "reentrant"); _locked = 2; _; _locked = 1; }
    uint256 private _locked = 1;

    constructor(IERC20 ldxToken, address recipient, uint256 start, uint256 end, uint256 cap) {
        require(address(ldxToken) != address(0) && recipient != address(0), "zero address");
        require(start < end && cap > 0, "invalid sale");
        owner = msg.sender;
        ldx = ldxToken;
        paymentRecipient = recipient;
        saleStart = start;
        saleEnd = end;
        maxSale = cap;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function configureAsset(Asset asset, address token, address feed, bool enabled) external onlyOwner {
        require(feed != address(0) && (asset == Asset.BNB || token != address(0)), "invalid asset");
        assets[asset] = AssetConfig(token, feed, enabled);
        emit AssetConfigured(asset, token, feed, enabled);
    }

    function buy(Asset asset, uint256 amount) external payable nonReentrant whenNotPaused {
        require(block.timestamp >= saleStart && block.timestamp <= saleEnd, "sale inactive");
        AssetConfig memory config = assets[asset];
        require(config.enabled, "asset disabled");
        uint256 paid = asset == Asset.BNB ? msg.value : amount;
        require(paid > 0 && (asset == Asset.BNB ? amount == 0 : msg.value == 0), "invalid payment");
        uint256 ldxAmount = quote(asset, paid);
        require(ldxAmount > 0 && sold + ldxAmount <= maxSale, "sale limit");
        require(ldx.balanceOf(address(this)) >= sold + ldxAmount, "insufficient inventory");
        if (asset == Asset.BNB) {
            (bool sent,) = paymentRecipient.call{value: paid}("");
            require(sent, "payment failed");
        } else {
            require(IERC20(config.token).transferFrom(msg.sender, paymentRecipient, paid), "payment failed");
        }
        Allocation storage allocation = allocations[msg.sender];
        if (allocation.tge == 0) allocation.tge = uint64(block.timestamp);
        allocation.purchased += ldxAmount;
        sold += ldxAmount;
        emit Purchased(msg.sender, asset, paid, ldxAmount);
    }

    function claim() external nonReentrant whenNotPaused returns (uint256 amount) {
        amount = claimable(msg.sender);
        require(amount > 0, "nothing to claim");
        allocations[msg.sender].claimed += amount;
        require(ldx.transfer(msg.sender, amount), "transfer failed");
        emit Claimed(msg.sender, amount);
    }

    function claimable(address account) public view returns (uint256) {
        Allocation memory allocation = allocations[account];
        uint256 vested = vestedAmount(account);
        return vested > allocation.claimed ? vested - allocation.claimed : 0;
    }

    function quote(Asset asset, uint256 amount) public view returns (uint256) {
        AssetConfig memory config = assets[asset];
        require(config.enabled, "asset disabled");
        return _toLdx(config, amount);
    }

    function vestedAmount(address account) public view returns (uint256) {
        Allocation memory allocation = allocations[account];
        if (allocation.purchased == 0 || allocation.tge == 0 || block.timestamp < allocation.tge) return 0;
        uint256 vested = allocation.purchased * TGE_BPS / BPS;
        if (block.timestamp < allocation.tge + CLIFF) return vested;
        uint256 monthsElapsed = (block.timestamp - allocation.tge - CLIFF) / MONTH + 1;
        if (monthsElapsed > MONTHS) monthsElapsed = MONTHS;
        vested += allocation.purchased * MONTHLY_BPS * monthsElapsed / BPS;
        return vested > allocation.purchased ? allocation.purchased : vested;
    }

    function nextUnlock(address account) external view returns (uint256) {
        Allocation memory allocation = allocations[account];
        if (allocation.tge == 0 || vestedAmount(account) == allocation.purchased) return 0;
        if (block.timestamp < allocation.tge + CLIFF) return allocation.tge + CLIFF;
        uint256 next = allocation.tge + CLIFF + (((block.timestamp - allocation.tge - CLIFF) / MONTH) + 1) * MONTH;
        return next > allocation.tge + CLIFF + MONTHS * MONTH ? 0 : next;
    }

    function _toLdx(AssetConfig memory config, uint256 amount) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(config.feed).latestRoundData();
        require(answer > 0 && updatedAt >= block.timestamp - 1 days, "stale price");
        uint8 feedDecimals = IPriceFeed(config.feed).decimals();
        uint8 paymentDecimals = config.token == address(0) ? 18 : IERC20(config.token).decimals();
        uint256 usdValue18 = amount * uint256(answer);
        if (paymentDecimals + feedDecimals < 18) usdValue18 *= 10 ** (18 - paymentDecimals - feedDecimals);
        else usdValue18 /= 10 ** (paymentDecimals + feedDecimals - 18);
        return usdValue18 * 1e18 / PRICE_USD_18;
    }

    function setSaleWindow(uint256 start, uint256 end, uint256 cap) external onlyOwner {
        require(start < end && cap >= sold, "invalid sale");
        saleStart = start; saleEnd = end; maxSale = cap;
    }
    function setPaymentRecipient(address recipient) external onlyOwner { require(recipient != address(0), "zero address"); paymentRecipient = recipient; }
    function pause() external onlyOwner { paused = true; emit Paused(msg.sender); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(msg.sender); }
    function rescueToken(IERC20 token, address recipient, uint256 amount) external onlyOwner {
        require(address(token) != address(ldx), "cannot rescue LDX");
        require(recipient != address(0) && token.transfer(recipient, amount), "rescue failed");
    }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        address previousOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, owner);
    }
    receive() external payable { revert("use buy"); }
}