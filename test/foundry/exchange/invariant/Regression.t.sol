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
        handler.swapWethToToken(0);
        handler.burnLiquidity(
            6391808189260493041100077813901956187182535464214128060269978952650598639917,
            115792089237316195423570985008687907853269984665640564039457584007913129639934
        );

        handler.swapTokenToWeth(
            115792089237316195423570985008687907853269984665640564039457584007913129639934,
            115792089237316195423570985008687907853269984665640564039457584007913129639933
        );
        handler.mintLiquidity(10658368462066338189);
        handler.withdrawFees();
        handler.withdrawFees();
        handler.mintLiquidity(1);
        handler.swapWethToToken(2);
        handler.swapWethToToken(938623172715163864328);
        handler.burnLiquidity(
            1,
            115792089237316195423570985008687907853269984665640564039457584007913129639934
        );
        handler.swapTokenToWeth(13825818857680196998666325676, 2);
        handler.burnLiquidity(
            9189024996434438089442221745668442254752153861651822065451990693594638,
            499581851495766296
        );
        handler.swapWethToToken(
            998609402861428212055830076784731327639826834590453984
        );
        handler.withdrawFees();
        handler.swapTokenToWeth(
            2921480871008119254893,
            155257435522370752848117
        );
        handler.withdrawFees();
        handler.burnLiquidity(1299637730301016802, 25939510);
        handler.swapWethToToken(27447439150212882628671);
        handler.swapTokenToWeth(
            530704305916781345087874365146860539670443275837689967,
            167698042299
        );
        handler.withdrawFees();
        handler.withdrawFees();
        handler.withdrawFees();
        handler.mintLiquidity(
            115792089237316195423570985008687907853269984665640564039457584007913129639935
        );
        handler.swapWethToToken(1870480497675447879963);
        handler.mintLiquidity(0);
        handler.withdrawFees();
        handler.swapWethToToken(2624067);
        handler.swapWethToToken(
            115792089237316195423570985008687907853269984665640564039457584007913129639934
        );
        handler.swapWethToToken(
            80879840001451949419856209198402125585030460509155827353987437305017
        );
        handler.swapTokenToWeth(
            115792089237316195423570985008687907853269984665640564039457584007913129639932,
            115792089237316195423570985008687907853269984665640564039457584007913129639934
        );
    }
}
