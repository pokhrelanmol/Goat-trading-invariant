// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../../../contracts/exchange/GoatV1Pair.sol";
import "../../../contracts/exchange/GoatV1Factory.sol";
import "../../../contracts/mock/MockERC20.sol";
import "../../../contracts/mock/MockWETH.sol";
import "../../../contracts/library/GoatTypes.sol";

contract GoatExchangeTest is Test {
    GoatV1Factory factory;
    GoatV1Pair pair;
    MockToken goat;
    MockWETH weth;

    function setUp() public {
        // pass weth as constructor param
        weth = new MockWETH();
        goat = new MockToken();
        factory = new GoatV1Factory(address(weth));
    }

    function testPairCreation() public {
        GoatTypes.InitParams memory initParams = GoatTypes.InitParams(address(0), 0, 0, 0, 0, 0);
        address pairAddress = factory.createPair(address(goat), initParams);
        pair = GoatV1Pair(pairAddress);
        address token0 = address(weth) > address(goat) ? address(goat) : address(weth);
        address token1 = token0 == address(goat) ? address(weth) : address(goat);
        assertEq(pair.token0(), token0);
        assertEq(pair.token1(), token1);
        assertEq(pair.factory(), address(factory));
    }
}
