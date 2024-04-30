// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;
import {Invariant} from "./Invariant.t.sol";

// contract InvariantRegressionTest is Invariant {
//     function setUp() public override {
//         super.setUp();
//     }
//     function testLiquidityLockIssue() public {
//         handler.swapWethToToken(1);
//         handler.withdrawExcessToken();
//         handler.mintLiquidity(1742624634);
//         handler.mintLiquidity(10658368462066338189);
//         handler.swapWethToToken(938623172715163864328);
//         handler.burnLiquidity(
//             1,
//             115792089237316195423570985008687907853269984665640564039457584007913129639934
//         );
//     }
//     function testPresaleBalanceIssue() public {
//         handler.swapWethToToken(21196256103);
//         handler.swapTokenToWeth(
//             115792089237316195423570985008687907853269984665640564039457584007913129639935,
//             11715371836708933610030926155028789514270123125156692843869278
//         );
//         handler.withdrawExcessToken();
//         handler.mintLiquidity(885456392072231700376);
//         handler.swapWethToToken(15185);
//         handler.burnLiquidity(
//             1168368305342564398467762380024951354389669116499,
//             168216883849406229099742845082348704563094176645193132038135213834707
//         );
//         handler.swapTokenToWeth(
//             115792089237316195423570985008687907853269984665640564039457584007913129639933,
//             2652825896444545849306229917523480
//         );
//         handler.mintLiquidity(211524089115895);
//         handler.swapWethToToken(
//             42512021203965164126638444508244537139077468118995743773963932654837026959053
//         );
//         handler.swapTokenToWeth(
//             22248484815069436283015301908729674972835508450894100449753965436301970767872,
//             80989896910423639971289209343890954616733530202671862104316970083842853587457
//         );
//     }
// }
