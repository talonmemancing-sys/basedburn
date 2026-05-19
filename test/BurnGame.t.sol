// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {BurnToken} from "../src/BurnToken.sol";
import {BurnGame} from "../src/BurnGame.sol";

contract MockWETH is ERC20 {
    constructor() ERC20("Mock WETH", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// 模拟一个 revert on receive 的恶意 leader。
contract RevertingReceiver {
    BurnGame public game;
    BurnToken public token;

    constructor(BurnGame _game, BurnToken _token) {
        game = _game;
        token = _token;
    }

    function doBurn() external {
        token.approve(address(game), type(uint256).max);
        game.burn();
    }

    function doWithdraw() external {
        game.withdrawPrize();
    }

    receive() external payable {
        revert("reject");
    }

    fallback() external payable {
        revert("reject");
    }
}

contract BurnGameTest is Test {
    BurnToken burnToken;
    MockWETH weth;
    BurnGame game;

    address hook = makeAddr("hook");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        burnToken = new BurnToken(address(this), 1_000_000_000 ether);
        weth = new MockWETH();

        game = new BurnGame(burnToken, hook, Currency.wrap(address(weth)));

        burnToken.transfer(alice, 10_000_000 ether);
        burnToken.transfer(bob, 10_000_000 ether);

        vm.prank(alice);
        burnToken.approve(address(game), type(uint256).max);
        vm.prank(bob);
        burnToken.approve(address(game), type(uint256).max);
    }

    function _seedPrize(uint256 amount) internal {
        weth.mint(address(game), amount);
        vm.prank(hook);
        game.notifyFee(amount);
    }

    function test_FirstBurn_StartsRound() public {
        vm.prank(alice);
        game.burn();

        assertEq(game.currentLeader(), alice);
        assertEq(game.endTime(), block.timestamp + 10 minutes);
        assertEq(burnToken.balanceOf(alice), 10_000_000 ether - 500_000 ether);
        assertEq(game.timeLeft(), 10 minutes);
    }

    function test_SecondBurn_ResetsTimer() public {
        vm.prank(alice);
        game.burn();
        uint256 firstEnd = game.endTime();

        skip(5 minutes);

        vm.prank(bob);
        game.burn();

        assertEq(game.currentLeader(), bob);
        assertEq(game.endTime(), block.timestamp + 10 minutes);
        assertGt(game.endTime(), firstEnd);
    }

    function test_Claim_BeforeEndTime_Reverts() public {
        vm.prank(alice);
        game.burn();
        skip(5 minutes);

        vm.expectRevert(BurnGame.RoundActive.selector);
        game.settle();
    }

    function test_Claim_NoLeader_Reverts() public {
        vm.expectRevert(BurnGame.NoLeader.selector);
        game.settle();
    }

    function test_Claim_CreditsPendingAndRollsOver() public {
        _seedPrize(100 ether);

        vm.prank(alice);
        game.burn();
        skip(10 minutes + 1);

        game.settle();

        assertEq(game.pendingWithdrawals(alice), 80 ether, "alice credited 80%");
        assertEq(game.totalPending(), 80 ether);
        assertEq(game.prizePool(), 20 ether, "20% rollover");
        assertEq(game.currentLeader(), address(0));
        assertEq(game.endTime(), 0);
        assertEq(game.roundId(), 1);
    }

    function test_Withdraw_PullsCredit() public {
        _seedPrize(100 ether);

        vm.prank(alice);
        game.burn();
        skip(10 minutes + 1);
        game.settle();

        uint256 aliceBefore = weth.balanceOf(alice);
        vm.prank(alice);
        uint256 received = game.withdrawPrize();

        assertEq(received, 80 ether);
        assertEq(weth.balanceOf(alice) - aliceBefore, 80 ether);
        assertEq(game.pendingWithdrawals(alice), 0);
        assertEq(game.totalPending(), 0);
    }

    function test_Withdraw_NothingReverts() public {
        vm.expectRevert(BurnGame.NothingToWithdraw.selector);
        game.withdrawPrize();
    }

    function test_NewBurn_AfterEndTime_AutoSettlesPreviousRound() public {
        _seedPrize(100 ether);
        vm.prank(alice);
        game.burn();
        skip(10 minutes + 1);

        vm.prank(bob);
        game.burn();

        assertEq(game.currentLeader(), bob);
        assertEq(game.roundId(), 1);
        assertEq(game.prizePool(), 20 ether);
        assertEq(game.pendingWithdrawals(alice), 80 ether, "alice credited on auto-settle");
    }

    function test_NotifyFee_OnlyHook() public {
        vm.expectRevert(BurnGame.OnlyHook.selector);
        game.notifyFee(100 ether);

        weth.mint(address(game), 100 ether);
        vm.prank(hook);
        game.notifyFee(100 ether);
        assertEq(game.prizePool(), 100 ether);
    }

    function test_NotifyFee_BalanceMismatch_Reverts() public {
        // 没 mint 就 notify：余额不够
        vm.prank(hook);
        vm.expectRevert(BurnGame.BalanceMismatch.selector);
        game.notifyFee(100 ether);
    }

    function test_Burn_SendsExactAmountToDead() public {
        address dead = game.DEAD();
        uint256 supplyBefore = burnToken.totalSupply();
        uint256 deadBefore = burnToken.balanceOf(dead);
        uint256 aliceBefore = burnToken.balanceOf(alice);

        vm.prank(alice);
        game.burn();

        assertEq(burnToken.totalSupply(), supplyBefore);
        assertEq(burnToken.balanceOf(dead) - deadBefore, 500_000 ether);
        assertEq(aliceBefore - burnToken.balanceOf(alice), 500_000 ether);
    }

    function test_Rollover_AccumulatesAcrossRounds() public {
        _seedPrize(1000 ether);

        vm.prank(alice);
        game.burn();
        skip(10 minutes + 1);
        game.settle();
        assertEq(game.prizePool(), 200 ether);
        assertEq(game.pendingWithdrawals(alice), 800 ether);

        _seedPrize(500 ether);
        assertEq(game.prizePool(), 700 ether);

        vm.prank(bob);
        game.burn();
        skip(10 minutes + 1);
        game.settle();
        assertEq(game.prizePool(), 140 ether);
        assertEq(game.pendingWithdrawals(bob), 560 ether);
        assertEq(game.totalPending(), 800 ether + 560 ether);
    }

    function test_Payout_NativeEth_PullPattern() public {
        BurnGame ethGame = new BurnGame(burnToken, hook, Currency.wrap(address(0)));
        vm.deal(address(ethGame), 100 ether);
        vm.prank(hook);
        ethGame.notifyFee(100 ether);

        burnToken.transfer(alice, 1_000_000 ether);
        vm.prank(alice);
        burnToken.approve(address(ethGame), type(uint256).max);

        vm.prank(alice);
        ethGame.burn();
        skip(10 minutes + 1);
        ethGame.settle();
        assertEq(ethGame.pendingWithdrawals(alice), 80 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        ethGame.withdrawPrize();
        assertEq(alice.balance - aliceBefore, 80 ether);
        assertEq(ethGame.prizePool(), 20 ether);
    }

    /// 上一轮赢家不领奖，他的份额冻结不变；下一轮跑下来不会"重复支付"他第二份
    function test_UnclaimedPrize_FrozenAcrossRounds() public {
        // Round 0: alice 赢 80 ETH，不取
        _seedPrize(100 ether);
        vm.prank(alice);
        game.burn();
        skip(10 minutes + 1);
        game.settle();
        assertEq(game.pendingWithdrawals(alice), 80 ether);
        assertEq(game.prizePool(), 20 ether);     // rollover

        // Round 1: 新喂 60 ETH，bob 赢
        _seedPrize(60 ether);                      // prizePool = 20 + 60 = 80
        assertEq(game.prizePool(), 80 ether);
        // alice 的待提余额必须纹丝不动，跟新喂费完全无关
        assertEq(game.pendingWithdrawals(alice), 80 ether, "alice's credit must NOT change");

        vm.prank(bob);
        game.burn();
        skip(10 minutes + 1);
        game.settle();

        // Round 1 结算：bob 拿 80% × 80 = 64 ETH
        assertEq(game.pendingWithdrawals(bob), 64 ether);
        assertEq(game.prizePool(), 16 ether);      // 20% × 80 = 16 滚到 round 2
        // 再次确认 alice 的份额没动
        assertEq(game.pendingWithdrawals(alice), 80 ether, "alice's credit STILL unchanged");

        // 几轮过后 alice 才来领，依然能拿到当初的 80 ETH
        uint256 aliceBefore = weth.balanceOf(alice);
        vm.prank(alice);
        game.withdrawPrize();
        assertEq(weth.balanceOf(alice) - aliceBefore, 80 ether);

        // bob 也能正常领
        uint256 bobBefore = weth.balanceOf(bob);
        vm.prank(bob);
        game.withdrawPrize();
        assertEq(weth.balanceOf(bob) - bobBefore, 64 ether);

        // 16 ETH 还在池子里等下一轮
        assertEq(game.prizePool(), 16 ether);
        assertEq(game.totalPending(), 0);
    }

    /// ⭐ C-2: 恶意 leader 合约 revert on receive，不能 brick 游戏
    function test_C2_MaliciousLeader_DoesNotBrickGame() public {
        // 用一个 ETH 奖励币种的 game 实例（malicious 合约 revert on ETH）
        BurnGame ethGame = new BurnGame(burnToken, hook, Currency.wrap(address(0)));
        vm.deal(address(ethGame), 100 ether);
        vm.prank(hook);
        ethGame.notifyFee(100 ether);

        RevertingReceiver mal = new RevertingReceiver(ethGame, burnToken);
        burnToken.transfer(address(mal), 1_000_000 ether);

        mal.doBurn();
        assertEq(ethGame.currentLeader(), address(mal));

        skip(10 minutes + 1);

        // claim 应当成功（结算只记账，不直接转），即使赢家是恶意合约
        ethGame.settle();
        assertEq(ethGame.pendingWithdrawals(address(mal)), 80 ether);
        assertEq(ethGame.currentLeader(), address(0));

        // 接下来 alice 可以正常 burn 起新一轮 —— 游戏没卡死
        burnToken.transfer(alice, 1_000_000 ether);
        vm.prank(alice);
        burnToken.approve(address(ethGame), type(uint256).max);
        vm.prank(alice);
        ethGame.burn();
        assertEq(ethGame.currentLeader(), alice, "game not bricked");

        // 恶意合约自己 withdraw 会 revert，但只影响它自己
        vm.expectRevert();
        mal.doWithdraw();
        // pendingWithdrawals 还在，未消费
        assertEq(ethGame.pendingWithdrawals(address(mal)), 80 ether);
    }
}
