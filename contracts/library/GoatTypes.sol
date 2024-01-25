// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract GoatTypes {
    struct Pool {
        uint112 reserveWeth;
        uint112 reserveToken;
        uint32 lastTrade;
        uint112 totalSupply;
        uint112 virtualEth;
        uint32 vestingUntil;
        uint112 bootstrapEth;
        uint112 feesPerTokenStored;
        bool exists;
        uint256 kLast;
    }

    struct UserInfo {
        uint112 fractionalBalance;
        uint112 presaleBalance;
        uint32 lockedUntil;
        uint104 pendingFees;
        uint112 feesPerTokenPaid;
        uint32 lastUpdate;
        uint8 withdrawlLeft;
    }

    struct LaunchParams {
        uint112 virtualEth;
        uint112 bootstrapEth;
        uint112 initialWeth;
    }
}
