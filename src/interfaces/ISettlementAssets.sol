// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20Settlement {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Balance lookup shared by the supported outcome token contracts.
interface IOutcomeBalances {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

