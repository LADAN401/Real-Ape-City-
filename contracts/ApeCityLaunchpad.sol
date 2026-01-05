// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal ReentrancyGuard inlined
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

// Minimal Uniswap V3 interfaces and constants – fully compatible with Remix
interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params) external payable returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
}

// Inline TickMath constants
library TickMath {
    int24 public constant MIN_TICK = -887272;
    int24 public constant MAX_TICK = 887272;
}

// Production-ready Ape City memecoin launchpad on Base Mainnet
contract ApeCityLaunchpad is ReentrancyGuard {
    // Base Mainnet addresses
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address public constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Economics constants
    uint24 public constant POOL_FEE = 3000; // 0.3%
    uint256 public constant MIGRATION_THRESHOLD = 4.2 ether;
    uint256 public constant LP_ETH_AMOUNT = 4 ether;
    uint256 public constant CREATOR_REWARD = 0.1 ether;
    uint256 public constant PLATFORM_FEE = 0.1 ether;

    address public immutable platformOwner;

    struct LaunchedToken {
        address token;
        address creator;
        uint256 totalSupply;
        uint256 ethRaised;
        bool migrated;
    }

    LaunchedToken[] public launchedTokens;

    event TokenLaunched(address indexed token, address creator, string name, string symbol, uint256 totalSupply);
    event TokensBought(address indexed token, address buyer, uint256 ethIn, uint256 tokensOut);
    event LiquidityMigrated(address indexed token, uint256 positionId);

    constructor() {
        platformOwner = msg.sender;
    }

    // Launch a new memecoin – creator pays only gas
    function launchToken(string memory name, string memory symbol, uint256 totalSupply) external nonReentrant {
        require(totalSupply > 0, "Total supply must be > 0");

        ApeCityToken newToken = new ApeCityToken(name, symbol, totalSupply, address(this));

        launchedTokens.push(LaunchedToken({
            token: address(newToken),
            creator: msg.sender,
            totalSupply: totalSupply,
            ethRaised: 0,
            migrated: false
        }));

        emit TokenLaunched(address(newToken), msg.sender, name, symbol, totalSupply);
    }

    // Buy tokens during bonding curve phase
    function buyTokens(uint256 tokenIndex) external payable nonReentrant {
        LaunchedToken storage data = launchedTokens[tokenIndex];
        require(!data.migrated, "Token has migrated to Uniswap");
        require(msg.value > 0, "Must send ETH");

        ApeCityToken token = ApeCityToken(data.token);
        uint256 remainingTokens = token.balanceOf(address(this));
        require(remainingTokens > 0, "No tokens available");

        // Simple linear bonding curve
        uint256 tokensOut = (msg.value * remainingTokens) / (data.ethRaised + 1 ether);
        require(tokensOut > 0, "Insufficient output amount");

        data.ethRaised += msg.value;
        token.transfer(msg.sender, tokensOut);

        emit TokensBought(data.token, msg.sender, msg.value, tokensOut);

        if (data.ethRaised >= MIGRATION_THRESHOLD) {
            _migrateLiquidity(tokenIndex);
        }
    }

    // Internal: Migrate to Uniswap V3 – full-range, burned LP NFT
    function _migrateLiquidity(uint256 tokenIndex) internal {
        LaunchedToken storage data = launchedTokens[tokenIndex];
        require(!data.migrated, "Already migrated");
        require(data.ethRaised >= MIGRATION_THRESHOLD, "Threshold not reached");
        require(data.ethRaised >= LP_ETH_AMOUNT + CREATOR_REWARD + PLATFORM_FEE, "Insufficient ETH for rewards + LP");

        data.migrated = true;

        ApeCityToken token = ApeCityToken(data.token);
        uint256 tokenBalance = token.balanceOf(address(this));

        // Send rewards
        payable(data.creator).transfer(CREATOR_REWARD);
        payable(platformOwner).transfer(PLATFORM_FEE);

        // Approve
        token.approve(POSITION_MANAGER, tokenBalance);

        // Sort tokens
        address token0 = data.token < WETH ? data.token : WETH;
        address token1 = data.token < WETH ? WETH : data.token;
        uint256 amount0Desired = token0 == data.token ? tokenBalance : LP_ETH_AMOUNT;
        uint256 amount1Desired = token0 == data.token ? LP_ETH_AMOUNT : tokenBalance;

        // Create pool if needed
        IUniswapV3Factory factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        address pool = factory.getPool(data.token, WETH, POOL_FEE);
        if (pool == address(0)) {
            factory.createPool(data.token, WETH, POOL_FEE);
        }

        // Mint position and burn NFT
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: POOL_FEE,
            tickLower: TickMath.MIN_TICK,
            tickUpper: TickMath.MAX_TICK,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: DEAD_ADDRESS,
            deadline: block.timestamp + 600
        });

        (uint256 tokenId, , , ) = INonfungiblePositionManager(POSITION_MANAGER).mint{value: LP_ETH_AMOUNT}(params);

        emit LiquidityMigrated(data.token, tokenId);
    }

    function getLaunchedTokensCount() external view returns (uint256) {
        return launchedTokens.length;
    }

    receive() external payable {}
}

// ERC20 token for each launch
contract ApeCityToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint256 _totalSupply, address launchpad) {
        name = _name;
        symbol = _symbol;
        totalSupply = _totalSupply;
        balanceOf[launchpad] = _totalSupply;
        emit Transfer(address(0), launchpad, _totalSupply);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "Insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(balanceOf[from] >= value, "Insufficient balance");
        require(allowance[from][msg.sender] >= value, "Insufficient allowance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;
        emit Transfer(from, to, value);
        return true;
    }
}
