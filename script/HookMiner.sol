// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice 计算满足 hook 权限标志位（lower 14 bits）的 CREATE2 salt 与目标地址。
/// 适用于在 Base / Mainnet 上由通用 CREATE2 工厂（0x4e59...956C）部署。
library HookMiner {
    uint160 internal constant FLAG_MASK = 0x3FFF; // lower 14 bits

    /// @param deployer CREATE2 工厂地址
    /// @param flags 需要匹配的 permissions 标志位（按位或后的结果）
    /// @param creationCode 合约的 creationCode（不带构造参数）
    /// @param constructorArgs abi.encode 后的构造参数
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddr, bytes32 salt)
    {
        flags = flags & FLAG_MASK;
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);

        for (uint256 i = 0; i < 200_000; ++i) {
            salt = bytes32(i);
            hookAddr = computeAddress(deployer, salt, initCodeHash);
            if ((uint160(hookAddr) & FLAG_MASK) == flags) return (hookAddr, salt);
        }
        revert("HookMiner: address not found");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
