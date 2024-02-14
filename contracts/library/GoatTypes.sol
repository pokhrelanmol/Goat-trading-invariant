// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

contract GoatTypes {
    struct Pool {
        uint112 reserveBase;
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
        uint112 virtualBase;
        uint112 bootstrapBase;
        uint112 initialBase;
        uint112 initialTokenMatch;
    }

    struct FractionalLiquidity {
        uint112 fractionalBalance;
        uint32 lastWithdraw;
        uint8 withdrawlLeft;
    }

    struct InitParams {
        address liquidiyProvider;
        uint32 lockPeriod;
        uint112 virtualBase;
        uint112 bootstrapBase;
        uint112 initialBase;
        uint112 initialTokenMatch;
    }

    struct LiquidityProvider {
        uint112 fractionalBalance;
        uint32 lockedUntil;
        uint32 lastUpdate;
        uint8 withdrawlLeft;
    }

    struct LocalVariables_AddLiquidity {
        bool isNewPair;
        address pair;
        uint256 actualTokenAmount;
        uint256 wethAmountInitial;
        uint256 tokenAmount;
        uint256 wethAmount;
        uint256 liquidity;
    }
}
