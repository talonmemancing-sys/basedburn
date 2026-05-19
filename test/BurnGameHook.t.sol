// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BurnToken} from "../src/BurnToken.sol";
import {BurnGame} from "../src/BurnGame.sol";
import {BurnGameHook, IBurnGame} from "../src/BurnGameHook.sol";

/// @notice 端到端测试：原生 ETH/BURN pool，验证 hook 抽 1% 并在 BURN 侧自动换 ETH。
contract BurnGameHookTest is Test, Deployers {
    BurnGameHook hook;
    BurnGame game;
    BurnToken burnToken;
    PoolKey poolKey;

    Currency ethCurrency;
    Currency burnCurrency;

    address alice = makeAddr("alice");

    function setUp() public {
        deployFreshManagerAndRouters();

        burnToken = new BurnToken(address(this), 1_000_000_000 ether);
        vm.deal(address(this), 200 ether);

        ethCurrency = Currency.wrap(address(0));
        burnCurrency = Currency.wrap(address(burnToken));
        require(address(0) < address(burnToken), "ETH must sort < BURN");

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        address hookAddr = address(flags);
        deployCodeTo("BurnGameHook.sol:BurnGameHook", abi.encode(manager, burnToken, address(this)), hookAddr);
        hook = BurnGameHook(payable(hookAddr));

        game = new BurnGame(burnToken, address(hook), ethCurrency);
        hook.setGame(IBurnGame(address(game)));

        poolKey = PoolKey({
            currency0: ethCurrency,
            currency1: burnCurrency,
            fee: 3_000, // 0.3% LP fee
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        burnToken.approve(address(modifyLiquidityRouter), type(uint256).max);

        // 在 1:1 价格附近双边 LP：~5.8 ETH + ~5.8 BURN（[-1200,1200] 范围内）
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            poolKey,
            ModifyLiquidityParams({tickLower: -1200, tickUpper: 1200, liquidityDelta: 100 ether, salt: 0}),
            ""
        );
    }

    /// 卖 BURN 换 ETH：specified=BURN, unspecified=ETH → hook fee 直接进奖池
    function test_HookFee_EthSide_DirectForward() public {
        burnToken.transfer(alice, 100 ether);

        vm.startPrank(alice);
        burnToken.approve(address(swapRouter), type(uint256).max);

        uint256 gameEthBefore = address(game).balance;
        uint256 swapAmount = 1 ether;

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        uint256 ethCollected = address(game).balance - gameEthBefore;
        assertGt(ethCollected, 0, "ETH should be forwarded to game");
        assertEq(game.prizePool(), ethCollected, "prizePool = collected ETH");
    }

    /// 买 BURN（用 ETH 付）：specified=ETH, unspecified=BURN → hook 内 BURN→ETH 转换后入池
    function test_HookFee_BurnSide_ConvertsToEth() public {
        vm.deal(alice, 10 ether);

        vm.startPrank(alice);
        uint256 gameEthBefore = address(game).balance;
        uint256 swapAmount = 1 ether;

        swapRouter.swap{value: swapAmount}(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        uint256 ethCollected = address(game).balance - gameEthBefore;
        assertGt(ethCollected, 0, "ETH should arrive in game after BURN->ETH conversion");
        assertEq(game.prizePool(), ethCollected, "prizePool = converted ETH");
    }

    /// 综合：跑一系列双向 swap，奖池应稳定累积 ETH
    function test_HookFee_BothDirections_AccumulateEth() public {
        vm.deal(alice, 50 ether);
        burnToken.transfer(alice, 100 ether);
        vm.prank(alice);
        burnToken.approve(address(swapRouter), type(uint256).max);

        uint256 gameBefore = address(game).balance;

        // buy BURN with ETH
        vm.prank(alice);
        swapRouter.swap{value: 1 ether}(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // sell BURN for ETH
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 gameAfter = address(game).balance;
        assertGt(gameAfter - gameBefore, 0, "prize pool accumulates ETH across both directions");
        assertEq(game.prizePool(), gameAfter - gameBefore);
    }
}
