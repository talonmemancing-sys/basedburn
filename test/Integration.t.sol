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
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BurnToken} from "../src/BurnToken.sol";
import {BurnGame} from "../src/BurnGame.sol";
import {BurnGameHook, IBurnGame} from "../src/BurnGameHook.sol";

/// @notice 端到端集成：真实 v4 PoolManager + 多人 swap + 多人 burn + 计时器 + 派奖
contract IntegrationTest is Test, Deployers {
    BurnGameHook hook;
    BurnGame game;
    BurnToken burnToken;
    PoolKey poolKey;

    Currency ethCurrency;
    Currency burnCurrency;

    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        deployFreshManagerAndRouters();

        burnToken = new BurnToken(address(this), 1_000_000_000 ether);
        vm.deal(address(this), 200 ether);

        ethCurrency = Currency.wrap(address(0));
        burnCurrency = Currency.wrap(address(burnToken));

        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        address hookAddr = address(flags);
        deployCodeTo("BurnGameHook.sol:BurnGameHook", abi.encode(manager, burnToken, address(this)), hookAddr);
        hook = BurnGameHook(payable(hookAddr));

        game = new BurnGame(burnToken, address(hook), ethCurrency);
        hook.setGame(IBurnGame(address(game)));

        poolKey = PoolKey({
            currency0: ethCurrency,
            currency1: burnCurrency,
            fee: 3_000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        burnToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            poolKey,
            ModifyLiquidityParams({tickLower: -1200, tickUpper: 1200, liquidityDelta: 100 ether, salt: 0}),
            ""
        );

        // 给玩家充值
        burnToken.transfer(alice, 5_000_000 ether);
        burnToken.transfer(bob, 5_000_000 ether);
        burnToken.transfer(carol, 5_000_000 ether);
        vm.prank(alice);
        burnToken.approve(address(game), type(uint256).max);
        vm.prank(bob);
        burnToken.approve(address(game), type(uint256).max);
        vm.prank(carol);
        burnToken.approve(address(game), type(uint256).max);
    }

    /// 卖 BURN 换 ETH：手工算理论 hook fee，对比 game 实收
    function test_HookFee_Precise_SellBurn() public {
        burnToken.transfer(trader1, 10 ether);
        vm.startPrank(trader1);
        burnToken.approve(address(swapRouter), type(uint256).max);

        uint256 gameBefore = address(game).balance;

        BalanceDelta delta = swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // 卖 BURN：amount1<0（trader 付 BURN），amount0>0（trader 收 ETH）
        int128 ethOut = delta.amount0();
        assertGt(ethOut, 0, "trader received ETH");

        // hook fee 在 afterSwap 里抽，返回 +feeAmount 给 unspecified（ETH）
        // 所以 trader 实收 = pool 给的 ETH - hook fee = ethOutWithoutHookFee × 99%
        // 反推：hook 实收 ≈ ethOut / 99 （约 1% 的 trader 收到额）
        uint256 ethCollected = address(game).balance - gameBefore;
        assertGt(ethCollected, 0);

        // 验证 hook fee ≈ 1%（容差 ±5%，因为 LP fee 等会有细微差异）
        uint256 expected = uint256(uint128(ethOut)) / 99; // trader 收到 99%，hook 收到 1/99
        assertApproxEqRel(ethCollected, expected, 0.05e18, "hook fee within 5% of 1/99 of trader output");

        assertEq(game.prizePool(), ethCollected);
        console2.log("trader ETH out:", uint256(uint128(ethOut)));
        console2.log("hook ETH fee:  ", ethCollected);
    }

    /// 买 BURN 用 ETH：BURN 侧 fee 触发 hook 内嵌反向 swap
    function test_HookFee_Precise_BuyBurn() public {
        vm.deal(trader1, 10 ether);
        vm.startPrank(trader1);

        uint256 gameBefore = address(game).balance;
        uint256 burnBefore = burnToken.balanceOf(trader1);

        BalanceDelta delta = swapRouter.swap{value: 1 ether}(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        int128 burnOut = delta.amount1();
        assertGt(burnOut, 0, "trader received BURN");
        assertEq(burnToken.balanceOf(trader1) - burnBefore, uint256(uint128(burnOut)));

        // trader 实收 BURN = pool 产出 BURN - 1% hook fee
        // hook 把那 1% BURN 反向 swap 回 ETH 入池
        uint256 ethCollected = address(game).balance - gameBefore;
        assertGt(ethCollected, 0, "ETH ended up in game after BURN->ETH conversion");
        assertEq(game.prizePool(), ethCollected);

        // 转换会损失 LP fee + 滑点；预期 ethCollected ≈ 0.01 ETH × (1-0.3%) × pricing slippage
        // 给 ±20% 容差（来自 LP fee + 滑点 + 路径再算价）
        assertApproxEqRel(ethCollected, 0.01 ether, 0.2e18, "BURN-side fee converted to ~1% ETH");
        console2.log("trader BURN out:", uint256(uint128(burnOut)));
        console2.log("hook ETH fee:   ", ethCollected);
    }

    /// 完整抽奖流程：多人 swap 喂奖池 → 多人 burn 接力 → 计时器到期 → claim 派奖
    function test_FullLottery_MultiplePlayersAndSwaps() public {
        // === Phase 1：trader 们 swap，hook 累积奖池 ===
        burnToken.transfer(trader1, 5 ether);
        burnToken.transfer(trader2, 5 ether);
        vm.deal(trader1, 5 ether);
        vm.deal(trader2, 5 ether);

        vm.prank(trader1);
        burnToken.approve(address(swapRouter), type(uint256).max);
        vm.prank(trader2);
        burnToken.approve(address(swapRouter), type(uint256).max);

        // 一买一卖各几笔
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader1);
            swapRouter.swap{value: 0.5 ether}(
                poolKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );

            vm.prank(trader2);
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -0.5 ether,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }

        uint256 poolAfterSwaps = game.prizePool();
        assertGt(poolAfterSwaps, 0, "prize pool should be funded by swaps");
        console2.log("Pool after 6 swaps (ETH):", poolAfterSwaps);

        // === Phase 2：alice 第一个 burn，成为 leader ===
        uint256 t0 = block.timestamp;
        vm.prank(alice);
        game.burn();

        assertEq(game.currentLeader(), alice);
        assertEq(game.endTime(), t0 + 10 minutes);
        assertEq(game.roundId(), 0);

        // 5 分钟后 bob 接管
        uint256 t1 = t0 + 5 minutes;
        vm.warp(t1);
        vm.prank(bob);
        game.burn();

        assertEq(game.currentLeader(), bob, "bob becomes leader");
        assertEq(game.endTime(), t1 + 10 minutes, "timer reset to 10 min from bob's burn");

        // 7 分钟后 carol 接管
        uint256 t2 = t1 + 7 minutes;
        vm.warp(t2);
        vm.prank(carol);
        game.burn();
        assertEq(game.currentLeader(), carol);
        assertEq(game.endTime(), t2 + 10 minutes);

        // 再期间还能 swap 喂池
        vm.prank(trader1);
        swapRouter.swap{value: 0.5 ether}(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.5 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 poolBeforeClaim = game.prizePool();
        assertGt(poolBeforeClaim, poolAfterSwaps, "pool grew between burns");
        console2.log("Pool before settlement (ETH):", poolBeforeClaim);

        // === Phase 3：等倒计时归零，触发 claim（pull-payment：只记账） ===
        vm.warp(t2 + 10 minutes + 1);
        assertEq(game.timeLeft(), 0);

        game.settle();

        uint256 expectedPrize = (poolBeforeClaim * 8000) / 10000;
        uint256 expectedRollover = poolBeforeClaim - expectedPrize;

        assertEq(game.pendingWithdrawals(carol), expectedPrize, "carol credited 80%");
        assertEq(game.prizePool(), expectedRollover, "20% rolls over");
        assertEq(game.currentLeader(), address(0));
        assertEq(game.roundId(), 1, "round advanced");

        // carol 显式提款拿 ETH
        uint256 carolBefore = carol.balance;
        vm.prank(carol);
        game.withdrawPrize();
        assertEq(carol.balance - carolBefore, expectedPrize, "carol withdraws her prize");

        console2.log("Carol prize (ETH):    ", expectedPrize);
        console2.log("Round-1 rollover (ETH):", expectedRollover);

        // === Phase 4：alice 起 round 1，新一轮叠加滚存奖池 ===
        uint256 t3 = block.timestamp;
        vm.prank(alice);
        game.burn();
        assertEq(game.currentLeader(), alice);
        assertEq(game.prizePool(), expectedRollover, "rollover preserved into round 1");

        vm.warp(t3 + 10 minutes + 1);
        game.settle();
        assertEq(
            game.pendingWithdrawals(alice),
            (expectedRollover * 8000) / 10000,
            "round-1 alice credited 80% of rollover"
        );
    }

    /// 自动结算：超时后没人 claim，下一个 burn 会触发上一轮派奖
    function test_AutoSettle_OnNextBurn() public {
        // 喂池
        burnToken.transfer(trader1, 5 ether);
        vm.prank(trader1);
        burnToken.approve(address(swapRouter), type(uint256).max);
        vm.prank(trader1);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -2 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 pool0 = game.prizePool();
        assertGt(pool0, 0);

        // alice burn 后超时无人 claim
        uint256 t = block.timestamp;
        vm.prank(alice);
        game.burn();
        vm.warp(t + 15 minutes);

        // bob 直接 burn，应自动结算上一轮 → alice 被记入 pendingWithdrawals
        vm.prank(bob);
        game.burn();

        uint256 aliceCredit = (pool0 * 8000) / 10000;
        assertEq(game.pendingWithdrawals(alice), aliceCredit, "alice credited 80% on auto-settle");
        assertEq(game.currentLeader(), bob, "bob now leads round 1");
        assertEq(game.roundId(), 1);
        assertEq(game.prizePool(), pool0 - aliceCredit, "20% rolled into round 1");

        // alice 拿钱
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        game.withdrawPrize();
        assertEq(alice.balance - aliceBefore, aliceCredit);
    }

    /// ⭐ C-1: 攻击者用同一 hook 起一个 BURN/USDC（伪 ETH）池，hook 应静默跳过 fee
    function test_C1_HookRejectsForeignPool() public {
        // 部署一个伪 "WETH"（实际是普通 ERC20），跟 BURN 配对，attached 我们的 hook
        FakeERC20 fakeWeth = new FakeERC20();
        fakeWeth.mint(address(this), 1_000_000 ether);

        Currency fakeC = Currency.wrap(address(fakeWeth));
        Currency burnC = Currency.wrap(address(burnToken));
        (Currency c0, Currency c1) =
            address(fakeWeth) < address(burnToken) ? (fakeC, burnC) : (burnC, fakeC);

        PoolKey memory badKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3_000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });

        // 初始化恶意池
        manager.initialize(badKey, SQRT_PRICE_1_1);

        fakeWeth.approve(address(modifyLiquidityRouter), type(uint256).max);
        // burnToken 已 approve
        modifyLiquidityRouter.modifyLiquidity(
            badKey,
            ModifyLiquidityParams({tickLower: -1200, tickUpper: 1200, liquidityDelta: 100 ether, salt: 0}),
            ""
        );

        // 喂攻击者
        fakeWeth.mint(trader1, 10 ether);
        burnToken.transfer(trader1, 10 ether);
        vm.startPrank(trader1);
        fakeWeth.approve(address(swapRouter), type(uint256).max);
        burnToken.approve(address(swapRouter), type(uint256).max);

        uint256 prizeBefore = game.prizePool();
        uint256 gameBalBefore = address(game).balance;
        uint256 gameFakeBefore = fakeWeth.balanceOf(address(game));

        swapRouter.swap(
            badKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // hook 必须没动：prizePool 不变，game 既没收到 ETH 也没收到 fake token
        assertEq(game.prizePool(), prizeBefore, "prizePool must not change for foreign pool");
        assertEq(address(game).balance, gameBalBefore, "no ETH leaked");
        assertEq(fakeWeth.balanceOf(address(game)), gameFakeBefore, "no fake token leaked");
    }

    /// ⭐ H-2: flush() 把残留 BURN 打 dEaD、残留 ETH 给 game
    function test_H2_FlushSendsResidualsCorrectly() public {
        address dead = hook.DEAD();
        uint256 deadBefore = burnToken.balanceOf(dead);

        // 模拟 hook 里有残留 BURN + ETH
        burnToken.transfer(address(hook), 1 ether);
        vm.deal(address(hook), 0.5 ether);

        uint256 prizeBefore = game.prizePool();
        hook.flush();

        assertEq(burnToken.balanceOf(address(hook)), 0, "hook BURN swept");
        assertEq(burnToken.balanceOf(dead) - deadBefore, 1 ether, "DEAD got the BURN");
        assertEq(address(hook).balance, 0, "hook ETH swept");
        assertEq(address(game).balance, prizeBefore + 0.5 ether, "game received residual ETH");
        assertEq(game.prizePool(), prizeBefore + 0.5 ether, "prizePool incremented");
    }
}

contract FakeERC20 is IERC20 {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
