// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import "../../../contracts/exchange/GoatV1Pair.sol";
import "../../../contracts/exchange/GoatV1Factory.sol";
import "../../../contracts/mock/MockWETH.sol";
import "../../../contracts/mock/MockERC20.sol";
import "../../../contracts/library/GoatTypes.sol";
import "../../../contracts/library/GoatLibrary.sol";
import "../../../contracts/library/GoatErrors.sol";

struct Users {
    address whale;
    address alice;
    address bob;
    address lp;
    address lp1;
    address treasury;
}

contract GoatExchangeTest is Test {
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint32 private constant _MAX_UINT32 = type(uint32).max;
    GoatV1Factory factory;
    GoatV1Pair pair;
    MockERC20 goat;
    MockWETH weth;
    Users users;

    function setUp() public {
        users = Users({
            whale: makeAddr("whale"),
            alice: makeAddr("alice"),
            bob: makeAddr("bob"),
            lp: makeAddr("lp"),
            lp1: makeAddr("lp1"),
            treasury: makeAddr("treasury")
        });
        vm.warp(300 days);

        vm.startPrank(users.whale);
        weth = new MockWETH();
        goat = new MockERC20();
        vm.stopPrank();
        vm.startPrank(users.treasury);
        factory = new GoatV1Factory(address(weth));
        vm.stopPrank();
    }

    function testFactoryCreation() public {
        assertEq(factory.weth(), address(weth));
    }

    function testFactoryTreasury() public {
        assertEq(factory.treasury(), users.treasury);
    }

    function fundMe(IERC20 token, address to, uint256 amount) public {
        vm.startPrank(users.whale);
        token.transfer(to, amount);
        vm.stopPrank();
    }

    function testPairCreation() public {
        GoatTypes.InitParams memory initParams = GoatTypes.InitParams(10, 10, 10, 10);
        address pairAddress = factory.createPair(address(goat), initParams);
        pair = GoatV1Pair(pairAddress);
        assertEq(pair.factory(), address(factory));
    }

    function _mintLiquidity(uint256 ethAmt, uint256 tokenAmt, address to) private {
        vm.deal(to, ethAmt);
        fundMe(IERC20(goat), to, tokenAmt);
        vm.startPrank(to);
        weth.deposit{value: ethAmt}();
        weth.transfer(address(pair), ethAmt);
        goat.transfer(address(pair), tokenAmt);
        pair.mint(to);
        vm.stopPrank();
    }

    function _mintInitialLiquidity(GoatTypes.InitParams memory initParams, address to)
        private
        returns (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm)
    {
        (tokenAmtForPresale, tokenAmtForAmm) = GoatLibrary.getTokenAmountsForPresaleAndAmm(
            initParams.virtualEth, initParams.bootstrapEth, initParams.initialEth, initParams.initialTokenMatch
        );
        uint256 bootstrapTokenAmt = tokenAmtForPresale + tokenAmtForAmm;
        fundMe(IERC20(address(goat)), to, bootstrapTokenAmt);
        vm.startPrank(to);
        address pairAddress = factory.createPair(address(goat), initParams);
        if (bootstrapTokenAmt != 0) {
            goat.transfer(pairAddress, bootstrapTokenAmt);
        }
        if (initParams.initialEth != 0) {
            vm.deal(to, initParams.initialEth);
            weth.deposit{value: initParams.initialEth}();
            weth.transfer(pairAddress, initParams.initialEth);
        }
        pair = GoatV1Pair(pairAddress);
        pair.mint(to);

        vm.stopPrank();
    }

    function testMintSuccessWithoutInitialEth() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        uint256 initialLpBalance = pair.balanceOf(users.lp);
        assertEq(initialLpBalance, 100e18 - MINIMUM_LIQUIDITY);
        (uint256 reserveWeth, uint256 reserveToken) = pair.getReserves();

        assertEq(reserveWeth, initParams.virtualEth);
        assertEq(reserveToken, initParams.initialTokenMatch);

        GoatTypes.InitialLPInfo memory initialLPInfo = pair.getInitialLPInfo();

        // since we allow 25% withdrawls, fractional balance will be 1/4th of the total
        uint256 expectedFractionalBalance = initialLpBalance / 4;

        assertEq(initialLPInfo.liquidityProvider, users.lp);
        assertEq(initialLPInfo.fractionalBalance, expectedFractionalBalance);
        assertEq(initialLPInfo.lastWithdraw, 0);
        assertEq(initialLPInfo.withdrawlLeft, 4);
    }

    function testMintSuccessWithFullBootstrapEth() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        (, uint256 tokenAmtForAmm) = _mintInitialLiquidity(initParams, users.lp);
        // since reserve eth will be 10e18 and reserveToken will be 250e18
        // sqrt of their product = 50e18
        uint256 expectedLp = 50e18 - MINIMUM_LIQUIDITY;
        uint256 initialLpBalance = pair.balanceOf(users.lp);
        assertEq(initialLpBalance, expectedLp);
        (uint256 reserveEth, uint256 reserveToken) = pair.getReserves();

        assertEq(reserveEth, initParams.bootstrapEth);
        assertEq(reserveToken, tokenAmtForAmm);

        uint256 vestingUntil = pair.vestingUntil();
        assertEq(vestingUntil, block.timestamp + 30 days);
    }

    function testMintSuccessWithPartialBootstrapEth() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 5e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        // expected lp will be sqrt of initial token match and virtual eth
        // if weth sent is < bootstrap amount
        uint256 expectedLp = 100e18 - MINIMUM_LIQUIDITY;
        uint256 actualK = (uint256(initParams.virtualEth) * uint256(initParams.initialTokenMatch));

        uint256 initialLpBalance = pair.balanceOf(users.lp);
        assertEq(initialLpBalance, expectedLp);
        (uint256 virtualReserveEth, uint256 virtualReserveToken) = pair.getReserves();

        assertEq(virtualReserveEth, initParams.virtualEth + initParams.initialEth);
        uint256 expectedVirtualReserveToken = actualK / (initParams.virtualEth + initParams.initialEth);

        assertEq(virtualReserveToken, expectedVirtualReserveToken);

        uint256 vestingUntil = pair.vestingUntil();
        assertEq(vestingUntil, _MAX_UINT32);
    }

    function testMintRevertWithoutEnoughBootstrapTokenAmt() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;
        uint256 bootstrapTokenAmt = GoatLibrary.getActualBootstrapTokenAmount(
            initParams.virtualEth, initParams.bootstrapEth, initParams.initialEth, initParams.initialTokenMatch
        );
        fundMe(IERC20(address(goat)), users.lp, bootstrapTokenAmt);
        vm.startPrank(users.lp);
        address pairAddress = factory.createPair(address(goat), initParams);

        // send less token amount to the pair contract
        goat.transfer(pairAddress, bootstrapTokenAmt - 1);
        pair = GoatV1Pair(pairAddress);

        vm.expectRevert(GoatErrors.InsufficientTokenAmount.selector);
        pair.mint(users.lp);

        vm.stopPrank();
    }

    function testMintRevertWithExcessInitialWeth() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        uint256 bootstrapTokenAmt = GoatLibrary.getActualBootstrapTokenAmount(
            initParams.virtualEth, initParams.bootstrapEth, initParams.initialEth, initParams.initialTokenMatch
        );

        fundMe(IERC20(address(goat)), users.lp, bootstrapTokenAmt);
        vm.deal(users.lp, 20e18);
        vm.startPrank(users.lp);
        address pairAddress = factory.createPair(address(goat), initParams);

        weth.deposit{value: 20e18}();
        // send less token amount to the pair contract
        goat.transfer(pairAddress, bootstrapTokenAmt);
        weth.transfer(pairAddress, 20e18);
        pair = GoatV1Pair(pairAddress);

        vm.expectRevert(GoatErrors.SupplyMoreThanBootstrapEth.selector);
        pair.mint(users.lp);

        vm.stopPrank();
    }

    function testMintRevertOnPresaleIfInitialLiquidityIsAlreadyThere() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 5e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);
        vm.startPrank(users.alice);
        vm.expectRevert(GoatErrors.PresalePeriod.selector);
        pair.mint(users.alice);
        vm.stopPrank();
    }

    function testTransferRevertOfInitialLiquidityProvider() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 5e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);
        vm.startPrank(users.lp);
        vm.expectRevert(GoatErrors.LPTransferRestricted.selector);
        pair.transfer(users.bob, 1e18);
        vm.stopPrank();
    }

    function testPartialBurnSuccessForInitialLp() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        // get initial lp info
        GoatTypes.InitialLPInfo memory initialLPInfo = pair.getInitialLPInfo();
        // burn 1/4th of the lp
        vm.startPrank(users.lp);

        uint256 totalSupplyBefore = pair.totalSupply();
        uint256 lpWethBalBefore = weth.balanceOf(users.lp);
        uint256 lpTokenBalanceBefore = goat.balanceOf(users.lp);

        uint256 warpTime = block.timestamp + 3 days;
        // increase block.timestamp so that initial lp can remove liquidity
        vm.warp(warpTime);
        pair.transfer(address(pair), initialLPInfo.fractionalBalance);
        pair.burn(users.lp);
        vm.stopPrank();

        uint256 totalSupplyAfter = pair.totalSupply();
        uint256 lpWethBalAfter = weth.balanceOf(users.lp);
        uint256 lpTokenBalanceAfter = goat.balanceOf(users.lp);

        GoatTypes.InitialLPInfo memory initialLPInfoAfterBurn = pair.getInitialLPInfo();

        assertEq(initialLPInfoAfterBurn.fractionalBalance, initialLPInfo.fractionalBalance);
        assertEq(initialLPInfoAfterBurn.lastWithdraw, block.timestamp);
        assertEq(initialLPInfoAfterBurn.withdrawlLeft, initialLPInfo.withdrawlLeft - 1);

        assertEq(totalSupplyBefore - totalSupplyAfter, initialLPInfo.fractionalBalance);

        // Using approx value because of initial liquidity mint for zero address
        assertApproxEqAbs(lpWethBalAfter - lpWethBalBefore, 2.5 ether, 0.0001 ether);
        assertApproxEqAbs(lpTokenBalanceAfter - lpTokenBalanceBefore, 62.5 ether, 0.0001 ether);
    }

    function testPartialBypassRevertFromInitialLp() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        // burn 1/4th of the lp
        vm.startPrank(users.lp);

        uint256 warpTime = block.timestamp + 3 days;
        // increase block.timestamp so that initial lp can remove liquidity
        vm.warp(warpTime);
        uint256 totalBalance = pair.balanceOf(users.lp);
        pair.transfer(address(pair), totalBalance);
        vm.expectRevert(GoatErrors.BurnLimitExceeded.selector);
        // So even if burn is called for alice and actual tokens was
        // transferred by initial lp this call should fail because
        // from of last token recieved by the contract is saved and checked
        // when burn is called.
        pair.burn(users.alice);
        vm.stopPrank();
    }

    function testPartialBurnRevertOnCooldownActive() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        // get initial lp info
        GoatTypes.InitialLPInfo memory initialLPInfo = pair.getInitialLPInfo();

        vm.startPrank(users.lp);
        uint256 warpTime = block.timestamp + 3 days;
        // increase block.timestamp so that initial lp can remove liquidity
        vm.warp(warpTime);
        pair.transfer(address(pair), initialLPInfo.fractionalBalance);
        pair.burn(users.lp);

        // Withdraw cooldown active check
        pair.transfer(address(pair), initialLPInfo.fractionalBalance);
        vm.expectRevert(GoatErrors.WithdrawalCooldownActive.selector);
        pair.burn(users.lp);
        vm.stopPrank();
    }

    function testPartialBurnRevertOnPresale() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        // get initial lp info
        GoatTypes.InitialLPInfo memory initialLPInfo = pair.getInitialLPInfo();

        vm.startPrank(users.lp);
        uint256 warpTime = block.timestamp + 3 days;
        // increase block.timestamp so that initial lp can remove liquidity
        vm.warp(warpTime);
        pair.transfer(address(pair), initialLPInfo.fractionalBalance);

        // Should not allow liquidity burn on preslae period!
        vm.expectRevert(GoatErrors.PresalePeriod.selector);
        pair.burn(users.lp);

        vm.stopPrank();
    }

    function testPartialBurnRevertOnLimitExceeded() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        // get initial lp info
        GoatTypes.InitialLPInfo memory initialLPInfo = pair.getInitialLPInfo();

        vm.startPrank(users.lp);
        uint256 warpTime = block.timestamp + 3 days;
        // increase block.timestamp so that initial lp can remove liquidity
        vm.warp(warpTime);
        // try to burn amount more than allowed
        uint256 withdrawLpAmount = initialLPInfo.fractionalBalance + 1e18;
        pair.transfer(address(pair), withdrawLpAmount);
        vm.expectRevert(GoatErrors.BurnLimitExceeded.selector);
        pair.burn(users.lp);
        vm.stopPrank();
    }

    function testAddLpAfterPoolTurnsToAnAmm() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        _mintLiquidity(5e18, 125e18, users.bob);

        uint256 bobLpBalance = pair.balanceOf(users.bob);
        uint256 expectedLpMinted = 25e18;

        assertEq(bobLpBalance, expectedLpMinted);
    }

    function testBurnAfterLockPeriodForOtherLps() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);
        uint256 wethAmt = 5e18;
        uint256 tokenAmt = 125e18;

        _mintLiquidity(wethAmt, tokenAmt, users.bob);

        uint256 bobLpBalance = pair.balanceOf(users.bob);

        uint256 wethBalBefore = weth.balanceOf(users.bob);
        uint256 tokenBalBefore = goat.balanceOf(users.bob);

        vm.startPrank(users.bob);
        pair.transfer(address(pair), bobLpBalance);
        uint256 warpTime = block.timestamp + 3 days;
        vm.warp(warpTime);
        pair.burn(users.bob);

        uint256 wethBalAfter = weth.balanceOf(users.bob);
        uint256 tokenBalAfter = goat.balanceOf(users.bob);

        assertEq(wethBalAfter - wethBalBefore, wethAmt);
        assertEq(tokenBalAfter - tokenBalBefore, tokenAmt);
    }

    function testSwapWhenPoolIsInPresale() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        vm.startPrank(users.alice);
        vm.deal(users.alice, 10e18);
        weth.deposit{value: 10e18}();
        uint256 amountTokenOut = 250e18;
        uint256 amountWethOut = 0;
        weth.transfer(address(pair), 5e18 + 5e16);
        pair.swap(amountTokenOut, amountWethOut, users.alice);
        vm.stopPrank();
    }

    function testSwapToChangePoolFromPresaleToAnAmm() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        vm.startPrank(users.alice);
        vm.deal(users.alice, 20e18);
        weth.deposit{value: 20e18}();
        uint256 amountTokenOut = 500e18;
        uint256 amountWethOut = 0;
        uint256 amountWeth = 10e18;
        uint256 wethAmtWithFees = (amountWeth * 10000) / 9901;
        weth.transfer(address(pair), wethAmtWithFees);
        pair.swap(amountTokenOut, amountWethOut, users.alice);
        vm.stopPrank();
    }

    function testSwapToRecieveTokensFromBothPresaleAndAmm() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        vm.startPrank(users.alice);
        vm.deal(users.alice, 20e18);
        weth.deposit{value: 20e18}();

        uint256 wethForAmm = 2e18;
        uint256 tokenAmountAtAmm = 250e18;
        uint256 amountTokenOutFromPresale = 500e18;
        uint256 amountTokenOutFromAmm = (wethForAmm * tokenAmountAtAmm) / (initParams.bootstrapEth + wethForAmm);

        (uint256 virtualEthReserve, uint256 virtualTokenReserve) = pair.getReserves();
        uint256 actualK = virtualEthReserve * virtualTokenReserve;
        uint256 desiredK = uint256(initParams.virtualEth) * (initParams.initialTokenMatch);

        assertGe(actualK, desiredK);

        uint256 amountTokenOut = amountTokenOutFromAmm + amountTokenOutFromPresale;
        uint256 amountWethOut = 0;
        uint256 actualWeth = 12e18;
        uint256 actualWethWithFees = (actualWeth * 10000) / 9901;

        weth.transfer(address(pair), actualWethWithFees);
        pair.swap(amountTokenOut, amountWethOut, users.alice);
        vm.stopPrank();

        // Since the pool has turned to an Amm now, the reserves are real.
        (uint256 realEthReserve, uint256 realTokenReserve) = pair.getReserves();

        desiredK = tokenAmountAtAmm * initParams.bootstrapEth;
        actualK = realEthReserve * realTokenReserve;

        assertGe(actualK, desiredK);
    }

    function testWithdrawAccessTokenSuccess() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, users.lp);

        uint256 wethAmount = 5e18;
        uint256 expectedTokenOut = (wethAmount * initParams.initialTokenMatch) / (initParams.virtualEth + wethAmount);
        uint256 wethAmountWithFees = (wethAmount * 10000) / 9901;

        vm.startPrank(users.alice);
        vm.deal(users.alice, wethAmountWithFees);
        weth.deposit{value: wethAmountWithFees}();
        weth.transfer(address(pair), wethAmountWithFees);
        pair.swap(expectedTokenOut, 0, users.alice);
        vm.stopPrank();

        uint256 warpTime = block.timestamp + 32 days;
        vm.warp(warpTime);
        vm.startPrank(users.lp);
        pair.withdrawExcessToken();
        vm.stopPrank();

        uint256 actualWethReserveInPool = wethAmount;

        // at this point the pool has turned to an Amm
        // I need to check if the tokens in the pool match
        // up with what's needed in the pool

        (, uint256 tokenAmountForAmm) = GoatLibrary.getTokenAmountsForPresaleAndAmm(
            initParams.virtualEth, actualWethReserveInPool, 0, initParams.initialTokenMatch
        );

        (uint256 realEthReserve, uint256 realTokenReserve) = pair.getReserves();
        assertEq(tokenAmountForAmm, realTokenReserve);
        assertEq(wethAmount, realEthReserve);
    }
}
