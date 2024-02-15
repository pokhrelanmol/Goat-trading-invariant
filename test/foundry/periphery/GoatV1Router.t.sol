// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseTest} from "../BaseTest.t.sol";
import {GoatErrors} from "../../../contracts/library/GoatErrors.sol";
import {GoatV1Pair} from "../../../contracts/exchange/GoatV1Pair.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/Test.sol";

contract GoatV1RouterTest is BaseTest {
    function testConstructor() public {
        assertEq(address(router.FACTORY()), address(factory));
        assertEq(address(router.WETH()), address(weth));
    }

    /* ------------------------------ ADD LIQUIDITY ----------------------------- */
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

    function testFirstAddLiquiditySuccess() public {
        // get the actual amount with view function
        BaseTest.AddLiqudityParams memory addLiqParams = addLiquidityParams(true, false);
        uint256 actualTokenAmountToSend = router.getActualAmountNeeded(
            addLiqParams.initParams.virtualEth,
            addLiqParams.initParams.bootstrapEth,
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

        // check how much liqudity is minted to the LP
        GoatV1Pair pair = GoatV1Pair(factory.getPool(addLiqParams.token));
        uint256 expectedLiquidity = Math.sqrt(10e18 * 750e18) - 1000;
        uint256 userLiquidity = pair.balanceOf(addLiqParams.to);
        assertEq(userLiquidity, expectedLiquidity);
        assertEq(pair.totalSupply(), expectedLiquidity + 1000);
        assertEq(token.balanceOf(address(pair)), 750e18);
        assertEq(weth.balanceOf(address(pair)), 0);
    }
}
