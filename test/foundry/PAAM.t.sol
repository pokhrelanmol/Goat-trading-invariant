// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../../contracts/GoatExchange.sol";

contract GoatExchangeTest is Test {
    GoatExchange exchange;

    function setUp() public {
        // pass weth as constructor param
        exchange = new GoatExchange(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    }

    function testPoolId() public {
        address token0 = address(10000);
        address token1 = address(11111);
        bytes32 poolId = exchange.getPoolId(token0, token1);
        bytes32 expectedPID = (keccak256(abi.encodePacked(token0, token1)));
        assertEq(poolId, expectedPID);
    }
}
