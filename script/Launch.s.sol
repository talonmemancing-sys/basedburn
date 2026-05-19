// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice 在一个 unlock 上下文里依次执行：
///   1. 添加 1B BURN 单边 LP（msg.value=0 for LP）
///   2. dev buy 0.1 ETH 换 BURN（触发 hook 抽 1% 喂奖池）
/// 池初始化在 unlock 之前完成。
contract Launcher is IUnlockCallback {
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    address public immutable owner;

    struct LaunchData {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 burnAmount;
        uint256 ethBuyAmount;
        address recipient;
    }

    event Launched(uint128 liquidity, int128 ethSpent, int128 burnReceived);

    constructor(IPoolManager _pm) {
        poolManager = _pm;
        owner = msg.sender;
    }

    function launch(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 burnAmount,
        uint256 ethBuyAmount,
        address recipient
    ) external payable {
        require(msg.sender == owner, "only owner");
        require(msg.value == ethBuyAmount, "msg.value != ethBuyAmount");

        // 1) 初始化 pool（pool init 不需要 unlock）
        poolManager.initialize(key, sqrtPriceX96);

        // 2) 把 owner 的 BURN 拉到本合约（owner 必须先 approve）
        IERC20 burnT = IERC20(Currency.unwrap(key.currency1));
        burnT.safeTransferFrom(owner, address(this), burnAmount);

        // 3) 进 unlock 上下文做 LP + dev buy
        LaunchData memory data = LaunchData({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            burnAmount: burnAmount,
            ethBuyAmount: ethBuyAmount,
            recipient: recipient
        });
        poolManager.unlock(abi.encode(data));

        // 4) 还残余资金给 owner（理论上 0）
        uint256 leftover = burnT.balanceOf(address(this));
        if (leftover > 0) burnT.safeTransfer(owner, leftover);
        uint256 ethLeft = address(this).balance;
        if (ethLeft > 0) {
            (bool ok,) = owner.call{value: ethLeft}("");
            require(ok, "eth return failed");
        }
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PoolManager");
        LaunchData memory d = abi.decode(raw, (LaunchData));

        // === 1) Single-sided LP（currency1=BURN）===
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(d.tickLower),
            TickMath.getSqrtPriceAtTick(d.tickUpper),
            d.burnAmount
        );
        (BalanceDelta lpDelta,) = poolManager.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower: d.tickLower,
                tickUpper: d.tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );
        if (lpDelta.amount0() < 0) {
            d.key.currency0.settle(poolManager, address(this), uint256(uint128(-lpDelta.amount0())), false);
        }
        if (lpDelta.amount1() < 0) {
            d.key.currency1.settle(poolManager, address(this), uint256(uint128(-lpDelta.amount1())), false);
        }

        // === 2) Dev buy: ETH→BURN exactInput ===
        BalanceDelta swapDelta = poolManager.swap(
            d.key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(d.ethBuyAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        if (swapDelta.amount0() < 0) {
            d.key.currency0.settle(poolManager, address(this), uint256(uint128(-swapDelta.amount0())), false);
        }
        if (swapDelta.amount1() > 0) {
            poolManager.take(d.key.currency1, d.recipient, uint256(uint128(swapDelta.amount1())));
        }

        emit Launched(liquidity, swapDelta.amount0(), swapDelta.amount1());
        return "";
    }

    receive() external payable {}
}

/// @notice 上线一键发射脚本。
/// 用法（部署完合约后）：
///   1) 把 .env 加 3 行：
///        BURN_TOKEN=0x...
///        BURN_GAME=0x...
///        BURN_HOOK=0x...
///   2) 运行：
///        forge script script/Launch.s.sol:Launch --rpc-url base --broadcast
contract Launch is Script {
    // sqrt(5e8 * 2^192)，对应 2 ETH FDV（1B BURN）。target tick ≈ 200311。
    uint160 constant INIT_SQRT_PRICE_X96 = 1771595571142957102961017161607260;
    int24 constant TICK_SPACING = 200;
    int24 constant TICK_UPPER = 200200; // < 200311 ⇒ 100% currency1 单边
    int24 constant TICK_LOWER = 154400; // tickUpper - 45800（≈100x range）
    uint24 constant LP_FEE = 3000; // 0.3%
    uint256 constant BURN_TOTAL = 1_000_000_000 ether;
    uint256 constant DEV_BUY_ETH = 0.1 ether;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IPoolManager pm = IPoolManager(vm.envAddress("BASE_POOL_MANAGER"));
        address burnToken = vm.envAddress("BURN_TOKEN");
        address hookAddr = vm.envAddress("BURN_HOOK");
        // BURN_GAME read just for log
        address game = vm.envAddress("BURN_GAME");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(burnToken),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        console2.log("=== LAUNCH PLAN ===");
        console2.log("Deployer:", deployer);
        console2.log("PoolManager:", address(pm));
        console2.log("BurnToken:", burnToken);
        console2.log("BurnGame:", game);
        console2.log("Hook:", hookAddr);
        console2.log("sqrtPriceX96:", INIT_SQRT_PRICE_X96);
        console2.log("LP: 1B BURN single-sided");
        console2.log("tickLower:", int256(TICK_LOWER));
        console2.log("tickUpper:", int256(TICK_UPPER));
        console2.log("Dev buy:", DEV_BUY_ETH);

        vm.startBroadcast(pk);

        Launcher launcher = new Launcher(pm);
        console2.log("Launcher deployed:", address(launcher));

        IERC20(burnToken).approve(address(launcher), BURN_TOTAL);
        console2.log("Approved Launcher to spend 1B BURN");

        launcher.launch{value: DEV_BUY_ETH}(
            key, INIT_SQRT_PRICE_X96, TICK_LOWER, TICK_UPPER, BURN_TOTAL, DEV_BUY_ETH, deployer
        );

        vm.stopBroadcast();

        console2.log("=== LAUNCHED ===");
        console2.log("Pool live, LP added, dev bought 0.1 ETH worth of BURN.");
    }
}
