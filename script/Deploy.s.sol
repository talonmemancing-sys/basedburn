// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {BurnToken} from "../src/BurnToken.sol";
import {BurnGame} from "../src/BurnGame.sol";
import {BurnGameHook, IBurnGame} from "../src/BurnGameHook.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice 部署到 Base：
///   - Pool = native ETH (currency0=0x0) / BURN (currency1)
///   - LP fee = 3000 (0.3%)
///   - hook fee = 1%（BURN 侧 fee 在 hook 内换成 ETH 再进奖池）
///   - tickSpacing = 200
///
/// 部署完成后需要手动通过 PositionManager 初始化 Pool（建议参数见 README）。
contract Deploy is Script {
    /// 通用 CREATE2 deployer（Arachnid's deterministic deployment proxy），多链同地址
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint24 constant LP_FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 200;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address poolManager = vm.envAddress("BASE_POOL_MANAGER");

        vm.startBroadcast(pk);

        // 1. BurnToken
        BurnToken token = new BurnToken(deployer, 1_000_000_000 ether);
        console2.log("BurnToken:", address(token));

        // 2. currencies：ETH(0x0) 永远是 c0，BURN 永远是 c1
        Currency ethCurrency = Currency.wrap(address(0));
        Currency burnCurrency = Currency.wrap(address(token));
        require(address(0) < address(token), "ETH must sort < BURN");

        // 3. 挖出符合 permissions flags 的 hook 地址
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(BurnGameHook).creationCode,
            abi.encode(IPoolManager(poolManager), token, deployer)
        );
        console2.log("Hook (mined):", hookAddr);

        // 4. BurnGame 用 ETH 作 reward currency
        BurnGame game = new BurnGame(token, hookAddr, ethCurrency);
        console2.log("BurnGame:", address(game));

        // 5. CREATE2 部署 hook
        BurnGameHook hook = new BurnGameHook{salt: salt}(IPoolManager(poolManager), token, deployer);
        require(address(hook) == hookAddr, "hook address mismatch");
        console2.log("BurnGameHook:", address(hook));

        // 6. 绑定
        hook.setGame(IBurnGame(address(game)));

        vm.stopBroadcast();

        PoolKey memory key = PoolKey({
            currency0: ethCurrency,
            currency1: burnCurrency,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        console2.log("--- PoolKey ---");
        console2.log("currency0 (ETH):", Currency.unwrap(key.currency0));
        console2.log("currency1 (BURN):", Currency.unwrap(key.currency1));
        console2.log("fee:", uint256(key.fee));
        console2.log("tickSpacing:", uint256(int256(key.tickSpacing)));
        console2.log("hooks:", address(key.hooks));
    }
}
