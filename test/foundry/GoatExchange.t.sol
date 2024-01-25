// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../../contracts/GoatExchange.sol";
import "../../contracts/mock/MockERC20.sol";
import "../../contracts/mock/FeeOnTransferToken.sol";
import "../../contracts/mock/MockWETH.sol";

contract GoatExchangeTest is Test {
    GoatExchange exchange;
    address public devTreasury = address(1232435);
    address public funder = address(985984388538387329883875982387329885983298);
    FeeOnTransferToken feeToken;
    MockToken token0;
    MockToken token1;
    MockToken goat;
    MockWETH weth;

    function setUp() public {
        // pass weth as constructor param
        vm.startPrank(funder);
        token0 = new MockToken();
        token1 = new MockToken();
        feeToken = new FeeOnTransferToken();
        weth = new MockWETH();
        goat = new MockToken();
        exchange = new GoatExchange(
            address(weth),
            devTreasury,
            address(goat)
        );
        vm.stopPrank();
    }

    function testPoolId() public {
        address t0 = address(10000);
        address t1 = address(11111);
        bytes32 poolId = exchange.getPoolId(t0, t1);
        bytes32 expectedPID = (keccak256(abi.encodePacked(t0, t1)));
        assertEq(poolId, expectedPID);
    }

    // function testAddLiquidity() {}

    function testInitialization() public {}

    function testPresaleSwapValidity() public {}

    function testPresaleToCPMMTransition() public {}

    function testInvalidPresaleSwap() public {}
}
