// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;
import {Invariant} from "./Invariant.t.sol";

contract InvariantRegressionTest is Invariant {
    function setUp() public override {
        super.setUp();
    }

    function testLiquidityLockIssue() public {
        handler.swapWethToToken(1);
        handler.withdrawExcessToken();
        handler.mintLiquidity(1742624634);

        handler.mintLiquidity(10658368462066338189);
        handler.swapWethToToken(938623172715163864328);
        handler.burnLiquidity(
            1,
            115792089237316195423570985008687907853269984665640564039457584007913129639934
        );
    }
}
