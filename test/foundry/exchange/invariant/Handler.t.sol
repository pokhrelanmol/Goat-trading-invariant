// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {GoatV1Pair} from "../../../../contracts/exchange/GoatV1Pair.sol";
import {GoatV1Factory} from "../../../../contracts/exchange/GoatV1Factory.sol";
import {GoatTypes} from "../../../../contracts/library/GoatTypes.sol";
import {GoatLibrary} from "../../../../contracts/library/GoatLibrary.sol";
import {MockERC20} from "../../../../contracts/mock/MockERC20.sol";
import {MockWETH} from "../../../../contracts/mock/MockWETH.sol";
//TODO: Do code cleanup

struct LocalVariable_Reserves {
    uint256 reserveWethBefore;
    uint256 reserveTokenBefore;
    uint256 reserveWethAfter;
    uint256 reserveTokenAfter;
}

struct LocalVariables_swapWethToTokenInPresale {
    uint256 fees;
    uint256 lpFees;
    uint256 protocolFee;
    uint256 amountTokenOut;
    uint256 amountWethOut;
}

struct SwapperInfo {
    address swapper;
    uint256 presaleBalance;
}

contract Handler is Test {
    //contracts
    GoatV1Pair pair;
    GoatV1Factory factory;
    MockERC20 token;
    MockWETH weth;

    // Users
    address swapper = makeAddr("swapper");
    address liquidityProvider = makeAddr("liquidityProvider");

    int256 startingWethReserve;
    int256 startingTokenReserve;
    int256 public expectedDeltaWethReserve;
    int256 public expectedDeltaTokenReserve;
    int256 public actualDeltaWethReserve;
    int256 public actualDeltaTokenReserve;
    uint256 public expectedTotalFees;
    uint256 public actualTotalFees;
    uint256 public totalLpTokenBalanceInPresale;

    uint256 lastWithdrawlTimeForInitialLP;
    uint256 lastSwapTimestamp;
    address[] lps;
    SwapperInfo[] swappers;

    constructor(
        GoatV1Factory _factory,
        MockERC20 _token,
        MockWETH _weth,
        GoatV1Pair _pair
    ) {
        factory = _factory;
        token = _token;
        weth = _weth;
        pair = _pair;
    }

    function swapWethToToken(uint256 amountWethIn) public {
        vm.warp(lastSwapTimestamp + 3);
        GoatTypes.LocalVariables_PairStateInfo memory vars;
        LocalVariable_Reserves memory reserves;
        LocalVariables_swapWethToTokenInPresale memory swapVars;
        uint256 pendingProtocolFeesExpectedAfterSwap;
        // swapper = msg.sender; // random address from foundry
        amountWethIn = bound(amountWethIn, 1e10, 1000e18);

        if (swapper == address(pair)) return;
        (reserves.reserveWethBefore, reserves.reserveTokenBefore) = pair
            .getReserves();
        startingWethReserve = int256(reserves.reserveWethBefore);
        startingTokenReserve = int256(reserves.reserveTokenBefore);

        uint256 amountAfterFees = (amountWethIn * 9901) / 10000;
        swapVars.fees = amountWethIn - amountAfterFees;
        swapVars.lpFees = (swapVars.fees * 40) / 100;
        swapVars.protocolFee = swapVars.fees - swapVars.lpFees;

        if (pair.vestingUntil() == type(uint32).max) {
            /* --------------------  CALCULATION PRESALE ------------------- */
            (
                vars.reserveEth,
                vars.reserveToken,
                vars.virtualEth,
                vars.initialTokenMatch,
                vars.bootstrapEth,
                vars.virtualToken
            ) = pair.getStateInfoForPresale();
            uint256 tokenAmountForAmm = GoatLibrary.getTokenAmountForAmm(
                vars.virtualEth,
                vars.bootstrapEth,
                vars.initialTokenMatch
            );
            swapVars.amountTokenOut = GoatLibrary.getTokenAmountOutPresale(
                amountWethIn,
                vars.virtualEth,
                vars.reserveEth,
                vars.bootstrapEth,
                vars.reserveToken,
                vars.virtualToken,
                tokenAmountForAmm
            );
            if (swapVars.amountTokenOut == 0) return;
            expectedDeltaWethReserve = int256(
                amountWethIn - swapVars.protocolFee
            );
            swappers.push(SwapperInfo(swapper, swapVars.amountTokenOut));
            totalLpTokenBalanceInPresale += swapVars.amountTokenOut;
            // liquidityProvider = msg.sender; // random address
            expectedDeltaTokenReserve = int256(swapVars.amountTokenOut);
            // pending + current
            pendingProtocolFeesExpectedAfterSwap =
                pair.getPendingProtocolFees() +
                swapVars.protocolFee;

            if (pendingProtocolFeesExpectedAfterSwap > 0.1 ether) {
                // In this case protocolFee is transferred to treasury
                expectedTotalFees = 0;
            } else {
                expectedTotalFees = pendingProtocolFeesExpectedAfterSwap;
            }

            deal(address(weth), swapper, amountWethIn);
            vm.startPrank(swapper);
            weth.transfer(address(pair), amountWethIn);
            pair.swap(swapVars.amountTokenOut, 0, swapper);
            vm.stopPrank();

            (reserves.reserveWethAfter, reserves.reserveTokenAfter) = pair
                .getReserves();

            actualTotalFees =
                pair.getPendingLiquidityFees() +
                pair.getPendingProtocolFees();

            if (pair.vestingUntil() != type(uint32).max) {
                // If the swap is converting the presale to AMM, the reserve we get here will be a actual reserve not a virtual reserve, so adjust the actualDeltaWethReserve and actualDeltaTokenReserve accordingly
                uint256 reserveAfterVirtualDecreased = reserves
                    .reserveWethBefore - vars.virtualEth;

                actualDeltaWethReserve =
                    int256(reserves.reserveWethAfter) -
                    int256(reserveAfterVirtualDecreased);
            } else {
                actualDeltaWethReserve =
                    int256(reserves.reserveWethAfter) -
                    startingWethReserve;
            }

            actualDeltaTokenReserve =
                int256(reserves.reserveTokenAfter) -
                startingTokenReserve;
        } else {
            /* -------------------- CALCULATIONS AMM------------------- */

            (vars.reserveEth, vars.reserveToken) = pair.getStateInfoAmm();
            swapVars.amountTokenOut = GoatLibrary.getTokenAmountOutAmm(
                amountWethIn,
                vars.reserveEth,
                vars.reserveToken
            );
            if (swapVars.amountTokenOut == 0) return;

            expectedDeltaWethReserve = int256(amountWethIn - swapVars.fees);
            expectedDeltaTokenReserve = int256(swapVars.amountTokenOut);

            pendingProtocolFeesExpectedAfterSwap =
                pair.getPendingProtocolFees() +
                swapVars.protocolFee;

            if (pendingProtocolFeesExpectedAfterSwap > 0.1 ether) {
                expectedTotalFees =
                    pair.getPendingLiquidityFees() +
                    swapVars.lpFees;
            } else {
                expectedTotalFees =
                    pair.getPendingLiquidityFees() +
                    pair.getPendingProtocolFees() +
                    swapVars.fees;
            }

            deal(address(weth), swapper, amountWethIn);
            vm.startPrank(swapper);
            weth.transfer(address(pair), amountWethIn);
            pair.swap(swapVars.amountTokenOut, 0, swapper);
            vm.warp(block.timestamp + 100);
            vm.stopPrank();

            (reserves.reserveWethAfter, reserves.reserveTokenAfter) = pair
                .getReserves();
            actualDeltaWethReserve =
                int256(reserves.reserveWethAfter) -
                int256(reserves.reserveWethBefore);
            actualDeltaTokenReserve =
                int256(reserves.reserveTokenAfter) -
                int256(reserves.reserveTokenBefore);

            actualTotalFees =
                pair.getPendingLiquidityFees() +
                pair.getPendingProtocolFees();
        }
        lastSwapTimestamp = block.timestamp;
    }

    function swapTokenToWeth(uint256 amountTokenIn, uint256 rand) public {
        vm.warp(lastSwapTimestamp + 3);
        if (swappers.length == 0) return;
        rand = bound(rand, 0, swappers.length - 1);
        vm.warp(block.timestamp + 100);
        GoatTypes.LocalVariables_PairStateInfo memory vars;
        LocalVariable_Reserves memory reserves;
        LocalVariables_swapWethToTokenInPresale memory swapVars;
        uint256 pendingProtocolFeesExpectedAfterSwap;

        swapper = swappers[rand].swapper;
        amountTokenIn = pair.getPresaleBalance(swapper);

        if (token.balanceOf(swapper) < 10) return;
        if (amountTokenIn < 10) return;
        if (swapper == address(pair)) return;

        (reserves.reserveWethBefore, reserves.reserveTokenBefore) = pair
            .getReserves();
        startingWethReserve = int256(reserves.reserveWethBefore);
        startingTokenReserve = int256(reserves.reserveTokenBefore);
        if (pair.vestingUntil() == type(uint32).max) {
            /* ---------------------------- CALCULATE PRESALE --------------------------- */
            // Only allow  from those who have bought in presale
            if (pair.getUserPresaleBalance(swapper) < amountTokenIn) return;
            (
                vars.reserveEth,
                vars.reserveToken,
                vars.virtualEth,
                vars.initialTokenMatch,
                vars.bootstrapEth,
                vars.virtualToken
            ) = pair.getStateInfoForPresale();

            swapVars.amountWethOut = GoatLibrary.getWethAmountOutPresale(
                amountTokenIn,
                vars.reserveEth,
                vars.reserveToken,
                vars.virtualEth,
                vars.virtualToken
            );

            if (swapVars.amountWethOut == 100) return;

            swapVars.fees =
                (swapVars.amountWethOut * 10000) /
                9901 -
                swapVars.amountWethOut;
            swapVars.lpFees = (swapVars.fees * 40) / 100;
            swapVars.protocolFee = swapVars.fees - swapVars.lpFees;
            expectedDeltaWethReserve =
                int256(swapVars.amountWethOut) +
                int256(swapVars.protocolFee);

            expectedDeltaTokenReserve = int256(amountTokenIn);
            pendingProtocolFeesExpectedAfterSwap =
                pair.getPendingProtocolFees() +
                swapVars.protocolFee;

            if (pendingProtocolFeesExpectedAfterSwap > 0.1 ether) {
                expectedTotalFees = 0;
            } else {
                expectedTotalFees = pendingProtocolFeesExpectedAfterSwap;
            }

            vm.startPrank(swapper);
            console2.log("Token in test presale", amountTokenIn);
            token.transfer(address(pair), amountTokenIn);
            vm.warp(block.timestamp + 100);
            pair.swap(0, swapVars.amountWethOut, swapper);
            vm.stopPrank();

            (reserves.reserveWethAfter, reserves.reserveTokenAfter) = pair
                .getReserves();
            actualTotalFees =
                pair.getPendingLiquidityFees() +
                pair.getPendingProtocolFees();
            actualDeltaWethReserve =
                startingWethReserve -
                int256(reserves.reserveWethAfter);

            actualDeltaTokenReserve =
                int256(reserves.reserveTokenAfter) -
                startingTokenReserve;
        } else {
            /* ----------------------------- CALCULATION AMM ---------------------------- */

            (vars.reserveEth, vars.reserveToken) = pair.getStateInfoAmm();
            swapVars.amountWethOut = GoatLibrary.getWethAmountOutAmm(
                amountTokenIn,
                vars.reserveEth,
                vars.reserveToken
            );

            swapVars.fees =
                (swapVars.amountWethOut * 10000) /
                9901 -
                swapVars.amountWethOut;
            swapVars.lpFees = (swapVars.fees * 40) / 100;
            swapVars.protocolFee = swapVars.fees - swapVars.lpFees;
            expectedDeltaWethReserve =
                int256(swapVars.amountWethOut) +
                int256(swapVars.fees);

            expectedDeltaTokenReserve = int256(amountTokenIn);
            pendingProtocolFeesExpectedAfterSwap =
                pair.getPendingProtocolFees() +
                swapVars.protocolFee;

            if (pendingProtocolFeesExpectedAfterSwap > 0.1 ether) {
                expectedTotalFees =
                    pair.getPendingLiquidityFees() +
                    swapVars.lpFees;
            } else {
                expectedTotalFees =
                    pair.getPendingLiquidityFees() +
                    pair.getPendingProtocolFees() +
                    swapVars.fees;
            }

            if (swapVars.amountWethOut < 100) return;

            vm.startPrank(swapper);
            token.transfer(address(pair), amountTokenIn);
            vm.warp(block.timestamp + 100);
            pair.swap(0, swapVars.amountWethOut, swapper);
            vm.stopPrank();

            (reserves.reserveWethAfter, reserves.reserveTokenAfter) = pair
                .getReserves();
            actualDeltaWethReserve =
                int256(reserves.reserveWethBefore) -
                int256(reserves.reserveWethAfter);

            actualDeltaTokenReserve =
                int256(reserves.reserveTokenAfter) -
                int256(reserves.reserveTokenBefore);
            actualTotalFees =
                pair.getPendingLiquidityFees() +
                pair.getPendingProtocolFees();
        }
        lastSwapTimestamp = block.timestamp;
    }

    /* ----------------------- MINT AFTER PRESALE FOR REGULAR LPs---------------------- */

    function mintLiquidity(uint256 amountWethIn) public {
        if (pair.vestingUntil() == type(uint32).max) return;
        liquidityProvider = msg.sender;
        lps.push(liquidityProvider);
        if (liquidityProvider == address(pair)) return;
        LocalVariable_Reserves memory reserves;
        amountWethIn = bound(amountWethIn, 1, 1000e18);
        (reserves.reserveWethBefore, reserves.reserveTokenBefore) = pair
            .getReserves();
        uint256 quoteTokenAmt = GoatLibrary.quote(
            amountWethIn,
            reserves.reserveWethBefore,
            reserves.reserveTokenBefore
        );

        deal(address(weth), liquidityProvider, amountWethIn);
        deal(address(token), liquidityProvider, quoteTokenAmt);
        expectedDeltaWethReserve = int256(amountWethIn);
        expectedDeltaTokenReserve = int256(quoteTokenAmt);
        vm.startPrank(liquidityProvider);
        weth.transfer(address(pair), amountWethIn);
        token.transfer(address(pair), quoteTokenAmt);
        pair.mint(liquidityProvider);
        vm.stopPrank();

        (reserves.reserveWethAfter, reserves.reserveTokenAfter) = pair
            .getReserves();
        actualDeltaWethReserve =
            int256(reserves.reserveWethAfter) -
            int256(reserves.reserveWethBefore);
        actualDeltaTokenReserve =
            int256(reserves.reserveTokenAfter) -
            int256(reserves.reserveTokenBefore);
    }

    function burnLiquidity(uint256 randomNumber, uint256 rand) public {
        if (pair.vestingUntil() == type(uint32).max) return;
        if (lps.length == 0) return;
        rand = bound(rand, 0, lps.length - 1);
        liquidityProvider = lps[rand];
        uint256 liquidity = pair.balanceOf(liquidityProvider);
        GoatTypes.InitialLPInfo memory initialLpInfo = pair.getInitialLPInfo();
        if (liquidity == 0) return;
        /**
         * @note We also want to check what happen if initialLP tries to burn
         * normally they should only be allwed to burn 25% or less of their liquidity at once in every 7 days
         * To do so  i'm getting a radom number and if it's 7 then i'm setting the liquidityProvider to initialLp
         * There is nothing special in number 7, You can set any number you want
         */
        randomNumber = bound(randomNumber, 1, 1000);

        if (
            randomNumber == 7 ||
            liquidityProvider == initialLpInfo.liquidityProvider
        ) {
            liquidityProvider = initialLpInfo.liquidityProvider;
            uint256 initialLpBal = pair.balanceOf(liquidityProvider);
            if (initialLpInfo.withdrawalLeft == 1) {
                // If this is last withdrawal then we should allow initialLp to withdraw all
                liquidity = initialLpBal;
            } else {
                liquidity = initialLpInfo.fractionalBalance;
            }

            if (lastWithdrawlTimeForInitialLP == 0) {
                lastWithdrawlTimeForInitialLP = block.timestamp + 7 days;
                vm.warp(lastWithdrawlTimeForInitialLP);
            } else {
                lastWithdrawlTimeForInitialLP =
                    lastWithdrawlTimeForInitialLP +
                    7 days;
                vm.warp(lastWithdrawlTimeForInitialLP);
            }
        }

        LocalVariable_Reserves memory reserves;
        (reserves.reserveWethBefore, reserves.reserveTokenBefore) = pair
            .getReserves();
        if (liquidity <= 1e18) return;
        uint256 balanceEth = reserves.reserveWethBefore;
        uint256 balanceToken = token.balanceOf(address(pair));

        uint256 totalSupply_ = pair.totalSupply();
        uint256 amountWethOut = (liquidity * balanceEth) / totalSupply_;
        uint256 amountTokenOut = (liquidity * balanceToken) / totalSupply_;

        expectedDeltaWethReserve = int256(amountWethOut);
        expectedDeltaTokenReserve = int256(amountTokenOut);
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(liquidityProvider);
        console2.log("Timestamp", block.timestamp);
        console2.log(
            "Block timestamp + 2 days test",
            block.timestamp + 30 days
        );
        pair.transfer(address(pair), liquidity);
        pair.burn(liquidityProvider);
        vm.stopPrank();

        (reserves.reserveWethAfter, reserves.reserveTokenAfter) = pair
            .getReserves();

        actualDeltaWethReserve =
            int256(reserves.reserveWethBefore) -
            int256(reserves.reserveWethAfter);
        actualDeltaTokenReserve =
            int256(reserves.reserveTokenBefore) -
            int256(reserves.reserveTokenAfter);
    }

    function withdrawExcessToken() public {
        if (pair.vestingUntil() != type(uint32).max) return;
        if (weth.balanceOf(address(pair)) == 0) return;
        GoatTypes.InitialLPInfo memory initialLpInfo = pair.getInitialLPInfo();
        LocalVariable_Reserves memory reserves;
        liquidityProvider = initialLpInfo.liquidityProvider;
        vm.warp(block.timestamp + 30 days);
        (reserves.reserveWethBefore, reserves.reserveTokenBefore) = pair
            .getReserves();

        (uint256 virtualWeth, , uint256 initialTokenMatch) = pair
            .getInitParams();
        expectedDeltaWethReserve =
            int256(reserves.reserveWethBefore) -
            int256(virtualWeth);
        (, uint256 tokenAmountAmm) = pair._tokenAmountsForLiquidityBootstrap(
            virtualWeth,
            uint256(expectedDeltaWethReserve),
            uint256(expectedDeltaWethReserve),
            initialTokenMatch
        );

        expectedDeltaTokenReserve = int256(tokenAmountAmm);
        expectedTotalFees = pair.getPendingProtocolFees();

        vm.startPrank(liquidityProvider);
        pair.withdrawExcessToken();
        vm.stopPrank();

        (reserves.reserveWethAfter, reserves.reserveTokenAfter) = pair
            .getReserves();

        actualDeltaWethReserve = int256(reserves.reserveWethAfter);

        actualDeltaTokenReserve = int256(reserves.reserveTokenAfter);
        actualTotalFees = pair.getPendingProtocolFees();
    }

    function withdrawFees() public {
        if (pair.vestingUntil() == type(uint32).max) return;
        LocalVariable_Reserves memory reserves;
        (reserves.reserveWethBefore, reserves.reserveTokenBefore) = pair
            .getReserves();
        // liquidityProvider = msg.sender;
        if (pair.balanceOf(liquidityProvider) == 0) return;
        expectedDeltaWethReserve = 0;
        expectedDeltaTokenReserve = 0;
        uint256 earnedFees = pair.earned(liquidityProvider);
        console2.log("Earned fees", earnedFees);
        console2.log("Pending fees", pair.getPendingLiquidityFees());
        expectedTotalFees =
            pair.getPendingProtocolFees() +
            pair.getPendingLiquidityFees() -
            earnedFees;
        vm.startPrank(liquidityProvider);
        pair.withdrawFees(liquidityProvider);
        vm.stopPrank();
        actualTotalFees =
            pair.getPendingLiquidityFees() +
            pair.getPendingProtocolFees();
        (reserves.reserveWethAfter, reserves.reserveTokenAfter) = pair
            .getReserves();
        actualDeltaWethReserve =
            int256(reserves.reserveWethAfter) -
            int256(reserves.reserveWethBefore);
        actualDeltaTokenReserve =
            int256(reserves.reserveTokenAfter) -
            int256(reserves.reserveTokenBefore);
    }
}
