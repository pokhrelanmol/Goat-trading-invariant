// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract GoatTypes {
    struct Pool {
        uint128 reserveWETH;
        uint128 reserveTKN;
        uint128 totalSupply;
        uint96 virtualAmount;
        uint96 presaleAmount;
        uint96 feesCollected;
        uint96 feesDistributed;
        uint40 lastTrade;
        bool exists;
        bool isPresale;
        uint112 price0CumulativeLast;
        uint112 price1CumulativeLast;
    }
    struct UserInfo {
        uint112 fractionalBalance;
        uint112 presaleBalance;
        uint32 lockedUntil;
        uint8 withdrawlLeft;
        uint112 rewardPerTokenPaid;
        uint112 rewardPerTokenCollected;
        uint32 lastUpdate;
    }

    struct LaunchParams {
        uint96 virtualAmount;
        uint96 presaleAmount;
    }
}
