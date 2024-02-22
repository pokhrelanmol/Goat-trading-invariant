// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseTest} from "../BaseTest.t.sol";
import {GoatErrors} from "../../../contracts/library/GoatErrors.sol";
import {GoatV1Pair} from "../../../contracts/exchange/GoatV1Pair.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GoatTypes} from "../../../contracts/library/GoatTypes.sol";

contract GoatV1RouterTest is BaseTest {
    function testConstructor() public {
        assertEq(address(router.FACTORY()), address(factory));
        assertEq(address(router.WETH()), address(weth));
    }

    /* ------------------------------ SUCCESS TESTS ADD LIQUIDITY ----------------------------- */
    function testAddLiquditySuccessFirstWithoutWeth() public {
        // get the actual amount with view function
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, false);
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);

        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = router.addLiquidity(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );

        // check how much liqudity is minted to the LP
        GoatV1Pair pair = GoatV1Pair(factory.getPool(addLiqParams.token));
        uint256 expectedLiquidity = Math.sqrt(10e18 * 1000e18) - 1000;
        uint256 userLiquidity = pair.balanceOf(addLiqParams.to);
        assertEq(userLiquidity, expectedLiquidity);
        // erc20 changes
        assertEq(pair.totalSupply(), userLiquidity + 1000);
        assertEq(token.balanceOf(address(pair)), 750e18);
        assertEq(weth.balanceOf(address(pair)), 0);
        //Returned values check
        assertEq(tokenAmtUsed, 1000e18);
        assertEq(wethAmtUsed, 10e18);
        assertEq(liquidity, expectedLiquidity);

        (uint256 reserveEth, uint256 reserveToken) = pair.getReserves();
        assertEq(reserveEth, 10e18); // actually we have 0 ETH but we have to show virtual ETH in reserve
        assertEq(reserveToken, 1000e18);
    }

    function testAddLiquiditySuccessFirstWithSomeWeth() public {
        // get the actual amount with view function
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, true);
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);
        weth.approve(address(router), addLiqParams.initParams.initialEth); // 5e18 weth
        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = router.addLiquidity(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );

        // check how much liqudity is minted to the LP
        GoatV1Pair pair = GoatV1Pair(factory.getPool(addLiqParams.token));
        uint256 expectedLiquidity = Math.sqrt(10e18 * 1000e18) - 1000;
        uint256 userLiquidity = pair.balanceOf(addLiqParams.to);
        assertEq(userLiquidity, expectedLiquidity);
        assertEq(pair.totalSupply(), userLiquidity + 1000);
        //SIMPLE AMM LOGIC
        uint256 numerator = 5e18 * 1000e18;
        uint256 denominator = 10e18 + 5e18;
        uint256 tokenAmtOut = numerator / denominator;
        uint256 expectedBalInPair = 750e18 - tokenAmtOut;
        assertEq(token.balanceOf(address(pair)), expectedBalInPair);
        assertEq(weth.balanceOf(address(pair)), 5e18);
        // Returned values check
        assertEq(tokenAmtUsed, 1000e18);
        assertEq(wethAmtUsed, 10e18);
        assertEq(liquidity, expectedLiquidity);
        (uint256 reserveEth, uint256 reserveToken) = pair.getReserves();
        assertEq(reserveEth, 15e18); // 10e18 virtual + 5e18 actual
            // expected = 1000000000000000000000 - 333333333333333333333  =  666666666666666666667
            // actual=  666666666666666666666
            // uint256 expectedReserveToken = 1000e18 - tokenAmtOut;
            // assertEq(reserveToken, expectedReserveToken);
    }

    function testAddLiquiditySuccessFirstWithAllWeth() public {
        // get the actual amount with view function
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, true);
        addLiqParams.initParams.initialEth = 10e18; // set all weth
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);
        weth.approve(address(router), addLiqParams.initParams.initialEth); // 10e18 weth

        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = router.addLiquidity(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );

        // check how much liqudity is minted to the LP
        GoatV1Pair pair = GoatV1Pair(factory.getPool(addLiqParams.token));
        /**
         * @dev if user sends all weth system will automatically get coverted to AMM
         * 10e18 is a real weth reserve and 250e18 is tokens reserve
         * At this point there is nothing vitual in the system
         */
        uint256 expectedLiquidity = Math.sqrt(10e18 * 250e18) - 1000;
        uint256 userLiquidity = pair.balanceOf(addLiqParams.to);
        assertEq(userLiquidity, expectedLiquidity);
        assertEq(pair.totalSupply(), userLiquidity + 1000);

        uint256 tokenAmtOut = actualTokenAmountToSend - 250e18; // 750e18 - 250e18 = 500e18
        uint256 expectedBalInPair = actualTokenAmountToSend - tokenAmtOut; // 750e18 - 500e18 = 250e18
        assertEq(token.balanceOf(address(pair)), expectedBalInPair);
        assertEq(weth.balanceOf(address(pair)), 10e18);
        // Returned values check
        assertEq(tokenAmtUsed, 250e18);
        assertEq(wethAmtUsed, 10e18);
        assertEq(liquidity, expectedLiquidity);
        (uint256 reserveEth, uint256 reserveToken) = pair.getReserves();
        assertEq(reserveEth, 10e18);
        assertEq(reserveToken, 250e18);
    }

    function testAddLiqudityEthSuccessFirstWithoutEth() public {
        // get the actual amount with view function
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, false);
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);

        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = router.addLiquidityETH{
            value: addLiqParams.initParams.initialEth
        }(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );

        // check how much liqudity is minted to the LP
        GoatV1Pair pair = GoatV1Pair(factory.getPool(addLiqParams.token));
        uint256 expectedLiquidity = Math.sqrt(10e18 * 1000e18) - 1000;
        uint256 userLiquidity = pair.balanceOf(addLiqParams.to);
        assertEq(userLiquidity, expectedLiquidity);
        assertEq(pair.totalSupply(), userLiquidity + 1000);
        assertEq(token.balanceOf(address(pair)), 750e18);
        assertEq(weth.balanceOf(address(pair)), 0);
        //Returned values check
        assertEq(tokenAmtUsed, 1000e18);
        assertEq(wethAmtUsed, 10e18);
        assertEq(liquidity, expectedLiquidity);
        (uint256 reserveEth, uint256 reserveToken) = pair.getReserves();
        assertEq(reserveEth, 10e18); // actually we have 0 ETH but we have to show virtual ETH in reserve
        assertEq(reserveToken, 1000e18);
    }

    function testAddLiqudityEthSuccessFirstWithSomeEth() public {
        // get the actual amount with view function
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, true);
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);

        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = router.addLiquidityETH{value: 5e18}(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );

        // check how much liqudity is minted to the LP
        GoatV1Pair pair = GoatV1Pair(factory.getPool(addLiqParams.token));
        uint256 expectedLiquidity = Math.sqrt(10e18 * 1000e18) - 1000;
        uint256 userLiquidity = pair.balanceOf(addLiqParams.to);
        assertEq(userLiquidity, expectedLiquidity);
        assertEq(pair.totalSupply(), userLiquidity + 1000);
        //SIMPLE AMM LOGIC
        uint256 numerator = 5e18 * 1000e18;
        uint256 denominator = 10e18 + 5e18;
        uint256 tokenAmtOut = numerator / denominator;
        uint256 expectedBalInPair = 750e18 - tokenAmtOut;
        assertEq(token.balanceOf(address(pair)), expectedBalInPair);
        assertEq(weth.balanceOf(address(pair)), 5e18);
        // Returned values check
        assertEq(tokenAmtUsed, 1000e18);
        assertEq(wethAmtUsed, 10e18);
        assertEq(liquidity, expectedLiquidity);

        (uint256 reserveEth, uint256 reserveToken) = pair.getReserves();
        assertEq(reserveEth, 15e18); // 10e18 virtual + 5e18 actual
            // expected = 1000000000000000000000 - 333333333333333333333  = 666666666666666666667
            // actual=  666666666666666666666
            // uint256 expectedReserveToken = 1000e18 - tokenAmtOut;
            // assertEq(reserveToken, expectedReserveToken);
    }

    function testAddLiqudityEthSuccessFirstWithAllEth() public {
        // get the actual amount with view function
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, true);
        addLiqParams.initParams.initialEth = 10e18; // set all weth
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);

        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = router.addLiquidityETH{value: 10e18}(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );

        // check how much liqudity is minted to the LP
        GoatV1Pair pair = GoatV1Pair(factory.getPool(addLiqParams.token));
        /**
         * @dev if user sends all weth system will automatically get coverted to AMM
         * 10e18 is a real weth reserve and 250e18 is tokens reserve
         * At this point there is nothing vitual in the system
         */
        uint256 expectedLiquidity = Math.sqrt(10e18 * 250e18) - 1000;
        uint256 userLiquidity = pair.balanceOf(addLiqParams.to);
        assertEq(userLiquidity, expectedLiquidity);
        assertEq(pair.totalSupply(), userLiquidity + 1000);

        uint256 tokenAmtOut = actualTokenAmountToSend - 250e18; // 750e18 - 250e18 = 500e18
        uint256 expectedBalInPair = actualTokenAmountToSend - tokenAmtOut; // 750e18 - 500e18 = 250e18
        assertEq(token.balanceOf(address(pair)), expectedBalInPair);
        assertEq(weth.balanceOf(address(pair)), 10e18);
        // Returned values check
        assertEq(tokenAmtUsed, 250e18);
        assertEq(wethAmtUsed, 10e18);
        assertEq(liquidity, expectedLiquidity);
        (uint256 reserveEth, uint256 reserveToken) = pair.getReserves();
        assertEq(reserveEth, 10e18);
        assertEq(reserveToken, 250e18);
    }

    function testAddLiquidityWethAfterPesale() public {
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, true);
        addLiqParams.initParams.initialEth = 10e18; // set all weth
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);
        weth.approve(address(router), addLiqParams.initParams.initialEth); // 10e18 weth

        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = router.addLiquidity(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
        GoatV1Pair pair = GoatV1Pair(factory.getPool(addLiqParams.token));
        uint256 lpTotalSupply = pair.totalSupply();
        //AT THIS POINT PRESALE IS ENDED
        addLiqParams = addLiquidityParams(false, false); // new params
        // mint tokens to lp
        token.mint(lp_1, 100e18);
        weth.transfer(lp_1, 1e18);
        // Lp provides liqudity
        vm.startPrank(lp_1);
        token.approve(address(router), 100e18);
        weth.approve(address(router), 1e18);
        addLiqParams.to = lp_1; // change to lp
        // (uint256 reserveEth, uint256 reserveToken) = pair.getReserves(); // get reserves before adding liquidity to check for Lp minted later

        (tokenAmtUsed, wethAmtUsed, liquidity) = router.addLiquidity(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
        vm.stopPrank();

        // checks
        assertEq(weth.balanceOf(address(pair)), 11e18); // 10e18 + 1e18
        uint256 optimalTokenAmt = (1e18 * 250e18) / 10e18; // calculate optimal token amount using current reserves
        assertEq(token.balanceOf(address(pair)), 250e18 + optimalTokenAmt);

        // check liquidity
        //TODO: I'm using hardcoded reseves beacasue of stack to deep error, need to change it later wit local vars
        uint256 amtWeth = token.balanceOf(address(pair)) - 10e18; // balance - reserve
        uint256 amtToken = token.balanceOf(address(pair)) - 250e18; // balance - reserve

        uint256 expectedLiquidity = Math.min((amtWeth * lpTotalSupply) / 10e18, (amtToken * lpTotalSupply) / 250e18);
        assertEq(pair.balanceOf(lp_1), expectedLiquidity);
    }

    /* ------------------- CHECK PAIR STATE AFTER ADDLIQUIDITY ------------------ */

    function testCheckPairStateAfterAddLiquidityIfWethSentIsZero() public {
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, false);
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);

        router.addLiquidity(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );

        // check  state of pair
        GoatV1Pair pair = GoatV1Pair(factory.getPool(address(token)));
        (
            uint112 reserveEth,
            uint112 reserveToken,
            uint112 virtualEth,
            uint112 initialTokenMatch,
            uint32 vestingUntil,
            uint32 lastTrade,
            uint256 bootstrapEth,
            uint32 genesis
        ) = pair.getStateInfo();

        assertEq(reserveEth, 0); // this is a raw reserve, so it reflect the balance, virtual eth is set in getReserves
        assertEq(reserveToken, 750e18);
        assertEq(virtualEth, 10e18);
        assertEq(initialTokenMatch, 1000e18);
        assertEq(vestingUntil, type(uint32).max);
        assertEq(lastTrade, 0);
        assertEq(bootstrapEth, 10e18);
        assertEq(genesis, block.timestamp);
        assertEq(pair.getPresaleBalance(addLiqParams.to), 0);
        GoatTypes.InitialLPInfo memory lpInfo = pair.getInitialLPInfo();
        assertEq(lpInfo.liquidityProvider, addLiqParams.to);
        // assertEq(lpInfo.fractionalBalance, 25e18);
        assertEq(lpInfo.withdrawlLeft, 4);
        assertEq(lpInfo.lastWithdraw, 0);
    }

    function testAddLiqudityEthAfterPresale() public {
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, true);
        addLiqParams.initParams.initialEth = 10e18; // set all weth
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);
        weth.approve(address(router), addLiqParams.initParams.initialEth); // 10e18 weth

        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = router.addLiquidityETH{value: 10e18}(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
        GoatV1Pair pair = GoatV1Pair(factory.getPool(addLiqParams.token));
        uint256 lpTotalSupply = pair.totalSupply();
        //AT THIS POINT PRESALE IS ENDED
        addLiqParams = addLiquidityParams(false, false); // new params
        // mint tokens to lp
        token.mint(lp_1, 100e18);
        vm.deal(lp_1, 1e18);
        // Lp provides liqudity
        vm.startPrank(lp_1);
        token.approve(address(router), 100e18);
        addLiqParams.to = lp_1; // change to lp
        // (uint256 reserveEth, uint256 reserveToken) = pair.getReserves(); // get reserves before adding liquidity to check for Lp minted later

        (tokenAmtUsed, wethAmtUsed, liquidity) = router.addLiquidityETH{value: 1e18}(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
        vm.stopPrank();

        // checks
        assertEq(weth.balanceOf(address(pair)), 11e18); // 10e18 + 1e18
        uint256 optimalTokenAmt = (1e18 * 250e18) / 10e18; // calculate optimal token amount using current reserves
        assertEq(token.balanceOf(address(pair)), 250e18 + optimalTokenAmt);

        // check liquidity
        //TODO: I'm using hardcoded reseves beacasue of stack to deep error, need to change it later wit local vars
        uint256 amtWeth = token.balanceOf(address(pair)) - 10e18; // balance - reserve
        uint256 amtToken = token.balanceOf(address(pair)) - 250e18; // balance - reserve

        uint256 expectedLiquidity = Math.min((amtWeth * lpTotalSupply) / 10e18, (amtToken * lpTotalSupply) / 250e18);
        assertEq(pair.balanceOf(lp_1), expectedLiquidity);
        assertEq(lp_1.balance, 0); // No balance left
    }
    /* ------------------------------ REVERTS TESTS ADD LIQUIDITY AT ROUTER LEVEL----------------------------- */

    function testRevertIfTokenIsWeth() public {
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, false);
        addLiqParams.token = address(weth);
        token.approve(address(router), addLiqParams.tokenDesired);
        weth.approve(address(router), addLiqParams.wethDesired);
        vm.expectRevert(GoatErrors.WrongToken.selector);
        router.addLiquidity(
            address(weth),
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
    }

    function testRevertIfTokenIsZeroAddress() public {
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, false);
        addLiqParams.token = address(weth);
        token.approve(address(router), addLiqParams.tokenDesired);
        weth.approve(address(router), addLiqParams.wethDesired);
        vm.expectRevert(GoatErrors.WrongToken.selector);
        router.addLiquidity(
            address(0),
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
    }

    function testRevertIfDeadlineIsPassed() public {
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, false);
        vm.expectRevert(GoatErrors.Expired.selector);
        router.addLiquidity(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            block.timestamp - 1,
            addLiqParams.initParams
        );
    }

    function testRevertIfNotEnoughTokenIsApprovedToRouter() public {
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, false);
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend - 1);
        vm.expectRevert("ERC20: insufficient allowance"); // erc20 revert
        router.addLiquidity(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
    }

    function testRevertIfNotEnoughEthIsSent() public {
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, true);
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);
        vm.expectRevert(GoatErrors.InvalidEthAmount.selector);
        router.addLiquidityETH{value: addLiqParams.initParams.initialEth - 1}(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
    }

    function testRevertIfInitialAmountIsSetToZeroButSomeEthIsSent() public {
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, false); // no initial eth
        addLiqParams.initParams.initialEth = 0;
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);
        vm.expectRevert(); // throw panic revert
        router.addLiquidityETH{value: 1e18}( // some eth is sent which is not needed
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
    }

    /* ------------------------------ REVERTS TESTS ADD LIQUIDITY AT PAIR LEVEL----------------------------- */

    function testRevertIfAddLiquidityInPresalePeriod() public {
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, false);

        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
            addLiqParams.initParams.initialEth,
            addLiqParams.initParams.initialTokenMatch
        );

        token.approve(address(router), actualTokenAmountToSend);
        router.addLiquidity(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
        // Still in presale period
        // Try to add liquidity again
        addLiqParams = addLiquidityParams(false, false);
        vm.startPrank(lp_1);
        token.approve(address(router), addLiqParams.tokenDesired);
        weth.approve(address(router), addLiqParams.wethDesired);
        vm.expectRevert(GoatErrors.PresalePeriod.selector);
        router.addLiquidity(
            addLiqParams.token,
            addLiqParams.tokenDesired,
            addLiqParams.wethDesired,
            addLiqParams.tokenMin,
            addLiqParams.wethMin,
            addLiqParams.to,
            addLiqParams.deadline,
            addLiqParams.initParams
        );
        vm.stopPrank();
    }
}
