// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The slice of IPOR Fusion's PlasmaVault this router needs.
interface IPlasmaVault {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function maxRedeem(address owner) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @notice The slice of IPOR Fusion's WithdrawManager this router needs.
/// @dev `requestInfo` returns the shares a user has queued and the timestamp their
///      withdraw window closes. The router reads it only to learn how much the user
///      asked for; every timing and release rule stays enforced by the protocol.
interface IWithdrawManager {
    function requestInfo(address account) external view returns (uint256 shares, uint256 endWithdrawWindowTimestamp);
    function getPlasmaVaultAddress() external view returns (address);
}
