// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice 燃烧游戏奖池：每次烧 0.05% (=500,000 BURN) 启动/重置 10 分钟倒计时，
/// 倒计时归零时最后烧的人拿走 80% 奖池，剩余 20% 自动滚入下一轮。
///
/// 三步使用流程：
///   1. burn()              —— 玩家烧 500k BURN 到 dEaD，成为 leader，重置 10 分钟倒计时
///   2. settle()            —— 倒计时归零后任何人可调，把奖金记到 pendingWithdrawals[leader]
///                             （只是结算/翻页，不涉及钱）
///   3. withdrawPrize()     —— 赢家自己调，把记账的奖金真转到自己钱包（pull-payment）
///
/// pull-payment 设计原因：赢家若是 revert on receive 的恶意合约，直接转账会卡死整个游戏；
/// 改成记账 + 自取后，恶意赢家只会卡住自己的提款，对其他人和后续轮次零影响。
///
/// 用户的 BURN 通过 transferFrom 打到 0x...dEaD（黑洞地址）—— totalSupply 不变，
/// 黑洞地址余额累积，Etherscan 上可视化。
///
/// 奖池单一币种：原生 ETH（rewardCurrency=0x0），WETH 模式也支持。
contract BurnGame {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ERC20Burnable public immutable burnToken;
    address public immutable hook;
    Currency public immutable rewardCurrency;

    uint256 public constant BURN_AMOUNT = 500_000 ether;
    uint256 public constant ROUND_DURATION = 10 minutes;
    uint256 public constant WINNER_SHARE_BPS = 8000; // 80%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public currentLeader;
    uint256 public endTime;
    uint256 public roundId;
    uint256 public prizePool;

    /// @notice 赢家可领取的待提余额（pull-payment）。
    mapping(address => uint256) public pendingWithdrawals;
    /// @notice 所有 pendingWithdrawals 的累计和，用于 notifyFee 余额对账。
    uint256 public totalPending;

    event Burned(uint256 indexed roundId, address indexed burner, uint256 newEndTime);
    event RoundEnded(uint256 indexed roundId, address indexed winner, uint256 prizeCredited);
    event Withdrawn(address indexed user, uint256 amount);
    event FeeReceived(uint256 amount);

    error OnlyHook();
    error NoLeader();
    error RoundActive();
    error NothingToWithdraw();
    error BalanceMismatch();

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(ERC20Burnable _burnToken, address _hook, Currency _rewardCurrency) {
        burnToken = _burnToken;
        hook = _hook;
        rewardCurrency = _rewardCurrency;
    }

    /// @notice Hook 在 take 过 ETH/WETH 给本合约后调用。会校验实际余额 >= 已记账负债 防止虚增。
    function notifyFee(uint256 amount) external onlyHook {
        address tok = Currency.unwrap(rewardCurrency);
        uint256 actual = tok == address(0) ? address(this).balance : IERC20(tok).balanceOf(address(this));
        // 合约持有的 reward 应该 >= 当前奖池 + 待提奖金（amount 已经在 actual 里了，因为 take 先于 notifyFee）
        if (actual < prizePool + totalPending + amount) revert BalanceMismatch();
        prizePool += amount;
        emit FeeReceived(amount);
    }

    /// @notice 用户先 approve 本合约消耗 BURN_AMOUNT 的 BURN，然后调本函数。
    /// BURN 被打到 DEAD 黑洞地址，永久无法取回。
    function burn() external {
        if (currentLeader != address(0) && block.timestamp >= endTime) {
            _settleRound();
        }
        IERC20(address(burnToken)).safeTransferFrom(msg.sender, DEAD, BURN_AMOUNT);
        currentLeader = msg.sender;
        endTime = block.timestamp + ROUND_DURATION;
        emit Burned(roundId, msg.sender, endTime);
    }

    /// @notice 倒计时归零后任何人都可触发结算。只把奖金记入 pendingWithdrawals[leader]，
    /// 不发起任何转账（避免恶意合约 leader 卡死整个游戏）。结算后 roundId++，进入下一轮。
    /// @dev 任何调用者都能调，不限定 leader。鼓励社区/赏金机器人帮忙翻页。
    function settle() external {
        if (currentLeader == address(0)) revert NoLeader();
        if (block.timestamp < endTime) revert RoundActive();
        _settleRound();
    }

    /// @notice 赢家自己取奖金（pull-payment）。失败只影响 caller 自己。
    /// 一个地址在多轮里多次中奖的话，pendingWithdrawals 会累计，一次 withdrawPrize 全取走。
    function withdrawPrize() external returns (uint256 amount) {
        amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        totalPending -= amount;

        address tokenAddress = Currency.unwrap(rewardCurrency);
        if (tokenAddress == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(tokenAddress).safeTransfer(msg.sender, amount);
        }
        emit Withdrawn(msg.sender, amount);
    }

    function timeLeft() external view returns (uint256) {
        if (currentLeader == address(0) || block.timestamp >= endTime) return 0;
        return endTime - block.timestamp;
    }

    function _settleRound() internal {
        address winner = currentLeader;
        uint256 total = prizePool;
        uint256 prize = (total * WINNER_SHARE_BPS) / BPS_DENOMINATOR;

        prizePool = total - prize; // 20% 自动滚入下一轮

        uint256 settledRound = roundId;
        roundId += 1;
        currentLeader = address(0);
        endTime = 0;

        if (prize > 0) {
            pendingWithdrawals[winner] += prize;
            totalPending += prize;
        }
        emit RoundEnded(settledRound, winner, prize);
    }

    receive() external payable {}
}
