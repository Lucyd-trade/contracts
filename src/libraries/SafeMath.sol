// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Shared checked unsigned arithmetic for settlement calculations.
/// @dev Uses Solidity's native checks: overflow/underflow panic with 0x11 and
/// division/modulo by zero with 0x12. Internal functions require no deployment.
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return a % b;
    }
}
