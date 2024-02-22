// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.t.sol";
import {GoatTypes} from "../../../contracts/library/GoatTypes.sol";
import {GoatV1Pair} from "../../../contracts/exchange/GoatV1Pair.sol";
import {GoatErrors} from "../../../contracts/library/GoatErrors.sol";

contract GoatV1FactoryTest is BaseTest {
    function testConstructorFactory() public {
        assertEq(factory.weth(), address(weth));
        assertEq(factory.treasury(), address(this));
    }

    function testCreatePairWithValidParams() public {
        GoatTypes.InitParams memory initParams = GoatTypes.InitParams(10e18, 10e18, 0, 1000e18);
        GoatV1Pair pair = GoatV1Pair(factory.createPair(address(token), initParams));
        assert(address(pair) != address(0));
        assertEq(pair.factory(), address(factory));

        address pool = factory.getPool(address(token));
        assertEq(pool, address(pair));
    }

    function testCreatePairWithInvalidParams() public {
        GoatTypes.InitParams memory initParams = GoatTypes.InitParams(0, 0, 0, 0);
        vm.expectRevert(GoatErrors.InvalidParams.selector);
        GoatV1Pair(factory.createPair(address(token), initParams));
    }

    function testSetTreasuryAndAccept() public {
        factory.setTreasury(lp_1);
        assertEq(factory.pendingTreasury(), lp_1);
        vm.prank(lp_1);
        factory.acceptTreasury();
        assertEq(factory.treasury(), lp_1);
    }

    function testSetTreasuryRevertIfNotCalledByTreasury() public {
        vm.prank(lp_1);
        vm.expectRevert(GoatErrors.Forbidden.selector);
        factory.setTreasury(lp_1);
    }

    function testAcceptTreasuryRevertIfNotCalledByPendingTreasury() public {
        factory.setTreasury(lp_1);
        vm.expectRevert(GoatErrors.Forbidden.selector);
        factory.acceptTreasury();
    }

    function testSetFeeToTreasury() public {
        factory.setFeeToTreasury(100e18);
        assertEq(factory.minimumCollectableFees(), 100e18);
    }

    function testSetFeeToTreasuryRevertIfNotCalledByTreasury() public {
        vm.prank(lp_1);
        vm.expectRevert(GoatErrors.Forbidden.selector);
        factory.setFeeToTreasury(100e18);
    }
}
