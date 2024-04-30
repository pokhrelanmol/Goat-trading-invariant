// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {InvariantTest} from "forge-std/InvariantTest.sol";
import {Test, console2} from "forge-std/Test.sol";
import {GoatV1Pair} from "../../../../contracts/exchange/GoatV1Pair.sol";
import {GoatV1Factory} from "../../../../contracts/exchange/GoatV1Factory.sol";
import {GoatTypes} from "../../../../contracts/library/GoatTypes.sol";
import {GoatLibrary} from "../../../../contracts/library/GoatLibrary.sol";
import {MockERC20} from "../../../../contracts/mock/MockERC20.sol";
import {MockWETH} from "../../../../contracts/mock/MockWETH.sol";
import {Handler} from "./Handler.t.sol";

contract Invariant is InvariantTest, Test {
    //How should i write these?
    GoatTypes.InitParams initParams =
        GoatTypes.InitParams({
            virtualEth: uint112(1000e18),
            bootstrapEth: uint112(10e18),
            initialEth: uint112(0),
            initialTokenMatch: uint112(100000000e18)
        });
    MockERC20 token;
    MockWETH weth;
    GoatV1Factory factory;
    GoatV1Pair pair;
    Handler handler;

    address initialLp = makeAddr("initialLp");

    function setUp() public virtual {
        token = new MockERC20();
        weth = new MockWETH();
        factory = new GoatV1Factory(address(weth));
        //initialize
        _createPair();
        handler = new Handler(factory, token, weth, pair);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.swapWethToToken.selector;
        selectors[1] = handler.mintLiquidity.selector;
        selectors[2] = handler.burnLiquidity.selector;
        selectors[3] = handler.withdrawExcessToken.selector;
        selectors[4] = handler.withdrawFees.selector;
        selectors[5] = handler.swapTokenToWeth.selector;
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
        vm.warp(300 days);
    }

    // function _randInitialInput()
    //     internal
    //     returns (GoatTypes.InitParams memory initialParams)
    // {
    //     uint256 randomNum;
    //     randomNum = bound(randomNum, 1, 1000);

    //     if (randomNum < 10) {
    //         // All input is equal
    //         initParams = GoatTypes.InitParams({
    //             virtualEth: uint112(100e18),
    //             bootstrapEth: uint112(100e18),
    //             initialEth: uint112(100e18),
    //             initialTokenMatch: uint112(100e18)
    //         });
    //     } else if (randomNum > 10 && randomNum < 100) {
    //         //  bootstrap == virtualEth
    //         initParams = GoatTypes.InitParams({
    //             virtualEth: uint112(100e18),
    //             bootstrapEth: uint112(100e18),
    //             initialEth: uint112(10e18),
    //             initialTokenMatch: uint112(10000e18)
    //         });
    //     } else {
    //         // intialEth ==0,vitualEth > boostrap
    //         initParams = GoatTypes.InitParams({
    //             virtualEth: uint112(1000e18),
    //             bootstrapEth: uint112(10e18),
    //             initialEth: uint112(0),
    //             initialTokenMatch: uint112(100000000e18)
    //         });
    //     }
    // }
    function _createPair() internal {
        uint256 tokenAmtToSend = GoatLibrary.getActualBootstrapTokenAmount(
            initParams.virtualEth,
            initParams.bootstrapEth,
            initParams.initialEth,
            initParams.initialTokenMatch
        );
        deal(address(token), initialLp, tokenAmtToSend);
        deal(address(weth), initialLp, initParams.initialEth);
        vm.startPrank(initialLp);
        pair = GoatV1Pair(factory.createPair(address(token), initParams));
        weth.transfer(address(pair), initParams.initialEth);
        token.transfer(address(pair), tokenAmtToSend);
        pair.mint(initialLp);
        vm.stopPrank();
    }

    function invariantReserves() public {
        int256 actual = handler.actualDeltaWethReserve();
        int256 expected = handler.expectedDeltaWethReserve();
        assertApproxEqAbs(actual, expected, 1);
        assertEq(
            handler.expectedDeltaTokenReserve(),
            handler.expectedDeltaTokenReserve()
        );
    }

    function invariantFees() public {
        assertApproxEqAbs(
            handler.expectedTotalFees(),
            handler.actualTotalFees(),
            1
        );
        uint256 totalFees = pair.getPendingLiquidityFees() +
            pair.getPendingProtocolFees();
        assertApproxEqAbs(handler.expectedTotalFees(), totalFees, 1);
    }

    function invariantBootstrapWethShouldBeGreaterThanRealWethReserveInPresale()
        public
    {
        if (pair.vestingUntil() == type(uint32).max) {
            uint256 wethBalance = weth.balanceOf(address(pair));
            uint256 protocolFees = pair.getPendingProtocolFees();
            uint256 actualRealWethReserve = wethBalance - protocolFees;
            (, uint112 bootstrapEth, ) = pair.getInitParams();
            assertGt(bootstrapEth, actualRealWethReserve);
        }
    }
    function invariant_SumOfUsersPresaleBalancesShouldNotBeMoreThanInitialTokenProvided()
        public
    {}
}
