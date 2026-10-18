// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CompanyToken} from "./CompanyToken.sol";
import {IUniswapV3Factory, IUniswapV3Pool, INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";

/**
 * @title CompanyTokenFactory — launches company tokens priced in wNEWS
 * @notice One `launch` call is atomic. It:
 *   1. deploys a fixed-supply CompanyToken, minting every allocation to its
 *      final holder and the LP tranche to this factory,
 *   2. creates and initializes the token/wNEWS Uniswap V3 pool at the
 *      caller's price, reverting if someone else initialized it first at
 *      any other price,
 *   3. deposits the LP tranche as single-sided liquidity (company token
 *      only). The first buyer has to bring wNEWS, which is how the primary
 *      purchase is denominated in wNEWS,
 *   4. sends the LP position NFT to `lpRecipient` and any rounding dust to
 *      the same address. The factory holds nothing afterwards.
 *
 * @dev The factory does no tick math on-chain. The caller supplies the
 *   price and range, computed off-chain by the launcher, and the
 *   factory checks the result instead: the pool sits at exactly the given
 *   price, zero wNEWS went into the position, and the factory's balance is
 *   zero at the end. A wrong range reverts. It cannot launch quietly.
 *
 * @dev Recovery: the LP NFT holder can decreaseLiquidity + collect on the
 *   position manager at any time. That pulls the unsold tokens and any
 *   wNEWS received back out. The factory keeps no rescue function because
 *   it never holds funds between transactions.
 */
contract CompanyTokenFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The only quote asset a company token is ever paired with.
    address public immutable wnews;
    IUniswapV3Factory public immutable uniswapFactory;
    INonfungiblePositionManager public immutable positionManager;

    struct Allocation {
        address recipient;
        uint256 amount;
    }

    struct LaunchParams {
        string name;
        string symbol;
        bytes32 salt;               // CREATE2 salt; final salt is keccak256(msg.sender, salt)
        Allocation[] allocations;   // everything except the LP tranche
        uint256 lpAmount;           // company tokens seeded into the pool
        uint24 fee;                 // Uniswap V3 fee tier (must be enabled)
        uint160 sqrtPriceX96;       // initial pool price, token1/token0, Q64.96
        int24 tickLower;
        int24 tickUpper;
        address lpRecipient;        // receives the LP NFT and rounding dust
    }

    struct Launch {
        address pool;
        uint256 lpTokenId;
        uint64 launchedAt;
    }

    address[] public allTokens;
    mapping(address token => Launch) public launches;

    /// @dev Name and range are omitted to stay within stack limits. Read them
    ///      from token.name() and positionManager.positions(lpTokenId).
    event CompanyTokenLaunched(
        address indexed token,
        address indexed pool,
        uint256 indexed lpTokenId,
        string symbol,
        uint256 totalSupply,
        uint256 lpAmountUsed,
        uint160 sqrtPriceX96,
        address lpRecipient
    );

    error ZeroAddress();
    error NotWNEWS();
    error PositionManagerMismatch();
    error ZeroLpAmount();
    error FeeTierNotEnabled();
    error PoolPreInitialized(uint160 expected, uint160 actual);
    error NotSingleSided(uint256 wnewsUsed);
    error NoLiquidity();
    error FactoryNotEmpty(uint256 balance);

    constructor(
        address initialOwner,
        address _wnews,
        address _uniswapFactory,
        address _positionManager
    ) Ownable(initialOwner) {
        if (_wnews == address(0) || _uniswapFactory == address(0) || _positionManager == address(0)) {
            revert ZeroAddress();
        }
        // On Base Sepolia, 0xEd14… is mUSDC rather than wNEWS. Check the
        // token itself instead of trusting the address.
        if (
            keccak256(bytes(IERC20Metadata(_wnews).symbol())) != keccak256("wNEWS") ||
            IERC20Metadata(_wnews).decimals() != 18
        ) revert NotWNEWS();
        if (INonfungiblePositionManager(_positionManager).factory() != _uniswapFactory) {
            revert PositionManagerMismatch();
        }
        wnews = _wnews;
        uniswapFactory = IUniswapV3Factory(_uniswapFactory);
        positionManager = INonfungiblePositionManager(_positionManager);
    }

    // ============ Launch =====================================================

    function launch(LaunchParams calldata p)
        external
        onlyOwner
        nonReentrant
        returns (address token, address pool, uint256 lpTokenId)
    {
        if (p.lpAmount == 0) revert ZeroLpAmount();
        if (p.lpRecipient == address(0)) revert ZeroAddress();
        if (uniswapFactory.feeAmountTickSpacing(p.fee) == 0) revert FeeTierNotEnabled();

        token = _deployToken(p);
        pool = _createPool(p, token);
        uint256 tokenUsed;
        (lpTokenId, tokenUsed) = _seedLiquidity(p, token);
        _sweep(p, token, tokenUsed);

        allTokens.push(token);
        launches[token] = Launch({pool: pool, lpTokenId: lpTokenId, launchedAt: uint64(block.timestamp)});
        _emitLaunched(p, token, pool, lpTokenId, tokenUsed);
    }

    /// @dev 1. Deploy the token. The LP tranche is minted to this factory, and
    ///         everything else goes straight to its final holder.
    function _deployToken(LaunchParams calldata p) internal returns (address) {
        (address[] memory recipients, uint256[] memory amounts) = _allocations(p);
        return address(
            new CompanyToken{salt: keccak256(abi.encode(msg.sender, p.salt))}(
                p.name, p.symbol, recipients, amounts
            )
        );
    }

    /// @dev 2. Pool at exactly the intended price. If someone created and
    ///         initialized this pool first at another price, revert. Retry
    ///         with a new salt, which gives a new token address and a new pool.
    function _createPool(LaunchParams calldata p, address token) internal returns (address pool) {
        (address token0, address token1) = token < wnews ? (token, wnews) : (wnews, token);
        pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, p.fee, p.sqrtPriceX96);
        (uint160 actual,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (actual != p.sqrtPriceX96) revert PoolPreInitialized(p.sqrtPriceX96, actual);
    }

    /// @dev 3. Single-sided LP, company token only. If the range touches the
    ///         current price, the mint asks for wNEWS, which this factory
    ///         never holds or approves, so the launch reverts.
    function _seedLiquidity(LaunchParams calldata p, address token)
        internal
        returns (uint256 lpTokenId, uint256 tokenUsed)
    {
        bool tokenIsToken0 = token < wnews;
        IERC20(token).forceApprove(address(positionManager), p.lpAmount);
        (uint256 id, uint128 liquidity, uint256 amount0, uint256 amount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: tokenIsToken0 ? token : wnews,
                token1: tokenIsToken0 ? wnews : token,
                fee: p.fee,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                amount0Desired: tokenIsToken0 ? p.lpAmount : 0,
                amount1Desired: tokenIsToken0 ? 0 : p.lpAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: p.lpRecipient,
                deadline: block.timestamp
            })
        );
        if (liquidity == 0) revert NoLiquidity();
        uint256 wnewsUsed = tokenIsToken0 ? amount1 : amount0;
        if (wnewsUsed != 0) revert NotSingleSided(wnewsUsed);
        return (id, tokenIsToken0 ? amount0 : amount1);
    }

    /// @dev 4. Leave nothing behind
    function _sweep(LaunchParams calldata p, address token, uint256 tokenUsed) internal {
        IERC20(token).forceApprove(address(positionManager), 0);
        uint256 dust = p.lpAmount - tokenUsed;
        if (dust != 0) IERC20(token).safeTransfer(p.lpRecipient, dust);
        uint256 left = IERC20(token).balanceOf(address(this));
        if (left != 0) revert FactoryNotEmpty(left);
    }

    function _emitLaunched(
        LaunchParams calldata p,
        address token,
        address pool,
        uint256 lpTokenId,
        uint256 tokenUsed
    ) internal {
        emit CompanyTokenLaunched(
            token, pool, lpTokenId, p.symbol, IERC20(token).totalSupply(),
            tokenUsed, p.sqrtPriceX96, p.lpRecipient
        );
    }

    // ============ Views ======================================================

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }

    function isCompanyToken(address token) external view returns (bool) {
        return launches[token].pool != address(0);
    }

    /// @notice CREATE2 address that `launch(p)` will deploy to when called by `launcher`.
    /// @dev    Off-chain tooling needs it before launch to know the token's
    ///         sort order against wNEWS, which decides price orientation.
    ///         Built with the same _allocations as launch, so the two cannot drift.
    function predictTokenAddress(address launcher, LaunchParams calldata p) external view returns (address) {
        (address[] memory recipients, uint256[] memory amounts) = _allocations(p);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(CompanyToken).creationCode, abi.encode(p.name, p.symbol, recipients, amounts))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), keccak256(abi.encode(launcher, p.salt)), initCodeHash
        )))));
    }

    function _allocations(LaunchParams calldata p)
        internal
        view
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        uint256 n = p.allocations.length;
        recipients = new address[](n + 1);
        amounts = new uint256[](n + 1);
        for (uint256 i = 0; i < n; ++i) {
            recipients[i] = p.allocations[i].recipient;
            amounts[i] = p.allocations[i].amount;
        }
        recipients[n] = address(this);
        amounts[n] = p.lpAmount;
    }
}
