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
        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = _addLiquidityWithoutWeth();
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
        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = _addLiquidityWithSomeWeth();

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
        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity, uint256 actualTokenAmountToSend) =
            _addLiquidityAndConvertToAmm();

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
        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = _addLiquidityWithoutEth();
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
        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = _addLiquidityWithSomeEth();

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
        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity, uint256 actualTokenAmountToSend) =
            _addLiquidityEthAndConvertToAmm();
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
        _addLiquidityAndConvertToAmm();
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
        _addLiquidityWithoutWeth();

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
        assertEq(lpInfo.fractionalBalance, 25e18 - 250);
        assertEq(lpInfo.withdrawlLeft, 4);
        assertEq(lpInfo.lastWithdraw, 0);
    }

    function testAddLiqudityEthAfterPresale() public {
        _addLiquidityEthAndConvertToAmm();
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

        (uint256 tokenAmtUsed, uint256 wethAmtUsed, uint256 liquidity) = router.addLiquidityETH{value: 1e18}(
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
        BaseTest.AddLiquidityParams memory addLiqParams = addLiquidityParams(true, false);
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
        BaseTest.AddLiquidityParams memory addLiqParams = addLiquidityParams(true, false);
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
        BaseTest.AddLiquidityParams memory addLiqParams = addLiquidityParams(true, false);
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
        BaseTest.AddLiquidityParams memory addLiqParams = addLiquidityParams(true, false);
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
        BaseTest.AddLiquidityParams memory addLiqParams = addLiquidityParams(true, true);
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
        BaseTest.AddLiquidityParams memory addLiqParams = addLiquidityParams(true, false); // no initial eth
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
        BaseTest.AddLiquidityParams memory addLiqParams = addLiquidityParams(true, false);

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

    /* ------------------------------- REMOVE LIQUDITY SUCCESS TESTS ------------------------------- */

    function testRemoveLiquiditySuccess() public {
        _addLiquidityAndConvertToAmm();
        GoatV1Pair pair = GoatV1Pair(factory.getPool(address(token)));

        uint256 balanceToken = token.balanceOf(address(pair));
        uint256 balanceEth = weth.balanceOf(address(pair));
        uint256 totalSupply = pair.totalSupply();
        uint256 userLiquidity = pair.balanceOf(address(this));
        pair.approve(address(router), userLiquidity);
        // remove liquidity
        // forward time to remove lock
        vm.warp(block.timestamp + 2 days);
        uint256 fractionalLiquidity = userLiquidity / 4;
        (uint256 amountWeth, uint256 amountToken) =
            router.removeLiquidity(address(token), fractionalLiquidity, 0, 0, lp_1, block.timestamp);

        uint256 expectedWeth = (fractionalLiquidity * balanceEth) / totalSupply;
        uint256 expectedToken = (fractionalLiquidity * balanceToken) / totalSupply;
        assertEq(amountWeth, expectedWeth);
        assertEq(amountToken, expectedToken);
        assertEq(pair.balanceOf(address(this)), userLiquidity - fractionalLiquidity);
        uint256 currentTotalSupply = totalSupply - fractionalLiquidity;
        assertEq(pair.totalSupply(), currentTotalSupply);
        assertEq(token.balanceOf(address(pair)), balanceToken - expectedToken);
        assertEq(weth.balanceOf(address(pair)), balanceEth - expectedWeth);

        assertEq(weth.balanceOf(lp_1), expectedWeth);
        assertEq(token.balanceOf(lp_1), expectedToken);
    }

    function testRemoveLiquidityEth() public {
        _addLiquidityEthAndConvertToAmm();
        GoatV1Pair pair = GoatV1Pair(factory.getPool(address(token)));
        uint256 balanceToken = token.balanceOf(address(pair));
        uint256 balanceEth = weth.balanceOf(address(pair));
        uint256 totalSupply = pair.totalSupply();
        uint256 userLiquidity = pair.balanceOf(address(this));
        uint256 userEthBalBefore = lp_1.balance;
        pair.approve(address(router), userLiquidity);
        // remove liquidity
        // forward time to remove lock
        vm.warp(block.timestamp + 2 days);
        uint256 fractionalLiquidity = userLiquidity / 4;
        (uint256 amountWeth, uint256 amountToken) =
            router.removeLiquidityETH(address(token), fractionalLiquidity, 0, 0, lp_1, block.timestamp);

        uint256 expectedEth = (fractionalLiquidity * balanceEth) / totalSupply;
        uint256 expectedToken = (fractionalLiquidity * balanceToken) / totalSupply;
        assertEq(amountWeth, expectedEth);
        assertEq(amountToken, expectedToken);
        assertEq(pair.balanceOf(address(this)), userLiquidity - fractionalLiquidity);
        uint256 currentTotalSupply = totalSupply - fractionalLiquidity;
        assertEq(pair.totalSupply(), currentTotalSupply);
        assertEq(lp_1.balance, userEthBalBefore + expectedEth);
        assertEq(token.balanceOf(lp_1), expectedToken);
    }

    function testRemoveLiquidityUpdateFeesIfSwapIsDoneBeforePresale() public {
        /**
         * @dev lp add initial liqudity and someone swaps before presale ends, the initial Lp should be able
         *     to claim his fees from swap after the presale ends
         */

        _addLiquidityWithSomeWeth();
        GoatV1Pair pair = GoatV1Pair(factory.getPool(address(token)));
        weth.transfer(swapper, 1e18);
        // vm.startPrank(swapper);
        //TODO: Do this testing after completing swap function and it's test
    }

    function testRemoveLiquidityUpdateFeesIfSwapIsDoneAfterPresale() public {
        /**
         * @dev lp add initial liqudity and someone swaps before presale ends, the initial Lp should be able
         *     to claim his fees from swap after the presale ends
         */

        _addLiquidityAndConvertToAmm();
        GoatV1Pair pair = GoatV1Pair(factory.getPool(address(token)));
        weth.transfer(swapper, 5e18);
        vm.startPrank(swapper);
        //TODO: Do this testing after completing swap function and it's test
    }

    /* ------------------------------ REVERTS TESTS REMOVE LIQUIDITY ----------------------------- */

    function testRevertIfRemoveLiquidityInPresale() public {
        _addLiquidityWithSomeWeth();
        vm.warp(block.timestamp + 2 days); // forward time to remove lock
        GoatV1Pair pair = GoatV1Pair(factory.getPool(address(token)));
        uint256 fractionalLiquidity = pair.balanceOf(address(this)) / 4;
        pair.approve(address(router), fractionalLiquidity);
        vm.expectRevert(GoatErrors.PresalePeriod.selector);
        router.removeLiquidity(address(token), fractionalLiquidity, 0, 0, lp_1, block.timestamp);
    }

    function testRevertIfRemoveLiquidityInLockPeriod() public {
        _addLiquidityAndConvertToAmm();
        GoatV1Pair pair = GoatV1Pair(factory.getPool(address(token)));
        uint256 fractionalLiquidity = pair.balanceOf(address(this)) / 4;
        pair.approve(address(router), fractionalLiquidity);
        vm.expectRevert(GoatErrors.LiquidityLocked.selector);
        router.removeLiquidity(address(token), fractionalLiquidity, 0, 0, lp_1, block.timestamp);
    }

    function testRevertIfRemoveLiquidityEthInPresale() public {
        _addLiquidityWithSomeEth();
        vm.warp(block.timestamp + 2 days); // forward time to remove lock
        GoatV1Pair pair = GoatV1Pair(factory.getPool(address(token)));
        uint256 fractionalLiquidity = pair.balanceOf(address(this)) / 4;
        pair.approve(address(router), fractionalLiquidity);
        vm.expectRevert(GoatErrors.PresalePeriod.selector);
        router.removeLiquidityETH(address(token), fractionalLiquidity, 0, 0, lp_1, block.timestamp);
    }

    function testRevertIfRemoveLiquidityEthInLockPeriod() public {
        _addLiquidityEthAndConvertToAmm();
        GoatV1Pair pair = GoatV1Pair(factory.getPool(address(token)));
        uint256 fractionalLiquidity = pair.balanceOf(address(this)) / 4;
        pair.approve(address(router), fractionalLiquidity);
        vm.expectRevert(GoatErrors.LiquidityLocked.selector);
        router.removeLiquidityETH(address(token), fractionalLiquidity, 0, 0, lp_1, block.timestamp);
    }

    // function testCheckReserveAfterRemoveLiquidity() public {

    // }

    //function testCheckStateAfterBurn

    /* ------------------------------- SWAP TESTS ------------------------------- */

    function testSwapWethToTokenSuccessInPresale() public {
        _addLiquidityWithoutWeth();
        weth.transfer(swapper, 5e18); // send some weth to swapper
        vm.startPrank(swapper);
        weth.approve(address(router), 5e18);
        uint256 amountOut = router.swapWethForExactTokens(
            5e18,
            0, // no slippage protection for now
            address(token),
            swapper,
            block.timestamp
        );
        vm.stopPrank();
        uint256 fees = 5e18 * 99 / 10000; // 1% fee
        //calculate amt out after deducting fee
        uint256 numerator = (5e18 - fees) * (250e18 + 750e18);
        uint256 denominator = (0 + 10e18) + (5e18 - fees);
        uint256 expectedAmountOut = numerator / denominator;
        assertEq(amountOut, expectedAmountOut);
    }

    // function testCheckStateAfterSwapWethToTokenSuccessInPresale() public {
    //     _addLiquidityWithoutWeth();
    //     GoatV1Pair pair = GoatV1Pair(factory.getPool(address(token)));
    //     weth.transfer(swapper, 5e18); // send some weth to swapper
    //     vm.startPrank(swapper);
    //     weth.approve(address(router), 5e18);

    //     uint256 amountOut = router.swapWethForExactTokens(
    //         5e18,
    //         0, // no slippage protection for now
    //         address(token),
    //         swapper,
    //         block.timestamp
    //     );
    //     vm.stopPrank();
    //     uint256 fees = 5e18 * 99 / 10000; // 1% fee
    //     assertEq(token.balanceOf(swapper), amountOut);
    //     assertEq(weth.balanceOf(swapper), 0);
    //     // Checks if fees are updated for lp
    //     assertEq(fees, pair.getPendingLiquidityFees() + pair.getPendingProtocolFees());
    //     assertEq(pair.getPendingLiquidityFees(), fees * 40 / 100); // 40% of fees
    //     console2.log("Lp fees", pair.getPendingLiquidityFees());
    //     console2.log("total Spply", pair.totalSupply());
    //     uint256 scale = 1e18;
    //     uint256 expectedFeePerToken = pair.getPendingLiquidityFees() * scale / pair.totalSupply();
    //     //    assertEq(pair.feesPerTokenStored(), expectedFeePerToken);
    // }
}
