// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTestHooks} from "v4-core/src/test/BaseTestHooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBurnGame {
    function notifyFee(uint256 amount) external;
}

/// @notice 在每次 swap 后从 unspecified 侧抽取 1%。如果该侧是 BURN，hook 在同一 unlock
/// 上下文内发起一次反向 swap 把 BURN 兑换成 ETH，再把 ETH 注入 BurnGame；如果该侧是 ETH，
/// 直接 take 给 BurnGame。
///
/// 必须部署到 lower-14-bit 命中 AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG 的地址。
///
/// 池子白名单（C-1）：只接受 currency0=ETH(0x0) & currency1=BURN 的池子。其它池子的
/// swap 会被静默跳过 fee（不抽，不结算），保护 BurnGame 计数不被异币污染。
contract BurnGameHook is BaseTestHooks {
    using SafeCast for uint256;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant HOOK_FEE_BPS = 100; // 1%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IPoolManager public immutable poolManager;
    ERC20Burnable public immutable burnToken;
    address public immutable owner;
    IBurnGame public game;

    /// @dev 防止内部转换 swap 触发递归 fee
    bool private _inConversion;

    error GameAlreadySet();
    error NotOwner();
    error GameNotSet();
    error NotPoolManager();
    error NoEthReceived();

    event GameSet(address game);
    event HookFeeCollected(uint256 amount);
    event ConvertedBurnToEth(uint256 burnIn, uint256 ethOut);
    event Flushed(uint256 burnSent, uint256 ethSent);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _manager, ERC20Burnable _burnToken, address _owner) {
        poolManager = _manager;
        burnToken = _burnToken;
        owner = _owner;
    }

    function setGame(IBurnGame _game) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(game) != address(0)) revert GameAlreadySet();
        game = _game;
        emit GameSet(address(_game));
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // 内部转换 swap 触发的递归：不抽 fee
        if (_inConversion) return (IHooks.afterSwap.selector, 0);

        // 池子白名单：只接受 native ETH / BURN（C-1）
        if (
            Currency.unwrap(key.currency0) != address(0)
                || Currency.unwrap(key.currency1) != address(burnToken)
        ) {
            return (IHooks.afterSwap.selector, 0);
        }

        if (address(game) == address(0)) revert GameNotSet();

        bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        (Currency feeCurrency, int128 swapAmount) =
            specifiedTokenIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (swapAmount < 0) swapAmount = -swapAmount;

        uint256 feeAmount = (uint128(swapAmount) * HOOK_FEE_BPS) / BPS_DENOMINATOR;
        if (feeAmount == 0) return (IHooks.afterSwap.selector, 0);

        if (Currency.unwrap(feeCurrency) == address(burnToken)) {
            _convertBurnToEthAndForward(key, feeCurrency, feeAmount);
        } else {
            poolManager.take(feeCurrency, address(game), feeAmount);
            game.notifyFee(feeAmount);
            emit HookFeeCollected(feeAmount);
        }

        return (IHooks.afterSwap.selector, feeAmount.toInt128());
    }

    /// @dev 在同一 unlock 上下文内：take BURN 给自己 → BURN→ETH swap → 按"实际消耗"
    /// settle BURN（残差留在 hook，可后续 flush）→ take ETH 给 game。
    function _convertBurnToEthAndForward(PoolKey calldata key, Currency burnCurrency, uint256 burnAmount) internal {
        poolManager.take(burnCurrency, address(this), burnAmount);

        bool burnIsZero = Currency.unwrap(burnCurrency) == Currency.unwrap(key.currency0);
        bool conversionZeroForOne = burnIsZero;

        _inConversion = true;
        BalanceDelta swapDelta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: conversionZeroForOne,
                amountSpecified: -int256(burnAmount),
                sqrtPriceLimitX96: conversionZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _inConversion = false;

        // H-1: 按 swapDelta 显示的实际 BURN 消耗量 settle，而不是盲目 settle burnAmount
        int128 burnSideDelta = burnIsZero ? swapDelta.amount0() : swapDelta.amount1();
        // input 侧的 delta 应为负（hook 付出 BURN）
        uint256 actualBurnSpent = burnSideDelta < 0 ? uint256(uint128(-burnSideDelta)) : 0;
        if (actualBurnSpent > 0) {
            burnCurrency.settle(poolManager, address(this), actualBurnSpent, false);
        }
        // 残差（burnAmount - actualBurnSpent）继续留在 hook 的 ERC20 余额，由 flush() 处理

        Currency ethCurrency = burnIsZero ? key.currency1 : key.currency0;
        int128 ethDelta = burnIsZero ? swapDelta.amount1() : swapDelta.amount0();
        if (ethDelta <= 0) revert NoEthReceived();
        uint256 ethReceived = uint256(uint128(ethDelta));

        poolManager.take(ethCurrency, address(game), ethReceived);
        game.notifyFee(ethReceived);
        emit ConvertedBurnToEth(actualBurnSpent, ethReceived);
    }

    /// @notice 任何人可调：把 hook 内残留的 BURN 打到 DEAD，残留的 ETH 转给 BurnGame
    /// 并登记为奖池。无管理员，无信任，纯单向出口（H-2）。
    function flush() external {
        if (address(game) == address(0)) revert GameNotSet();

        uint256 burnBal = burnToken.balanceOf(address(this));
        uint256 ethBal = address(this).balance;

        if (burnBal > 0) {
            IERC20(address(burnToken)).safeTransfer(DEAD, burnBal);
        }
        if (ethBal > 0) {
            (bool ok,) = address(game).call{value: ethBal}("");
            require(ok, "ETH flush failed");
            game.notifyFee(ethBal);
        }
        emit Flushed(burnBal, ethBal);
    }

    receive() external payable {}
}
