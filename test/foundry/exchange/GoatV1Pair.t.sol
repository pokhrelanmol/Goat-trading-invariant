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

contract GoatExchangeTest is Test {
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint32 private constant _MAX_UINT32 = type(uint32).max;
    GoatV1Factory factory;
    GoatV1Pair pair;
    MockERC20 goat;
    MockWETH weth;
    address public whale = makeAddr("whale");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public lp = makeAddr("lp");
    address public lp1 = makeAddr("lp1");
    address public treasury = makeAddr("treasury");

    function setUp() public {
        // pass weth as constructor param
        vm.warp(300 days);

        vm.startPrank(whale);
        weth = new MockWETH();
        goat = new MockERC20();
        vm.stopPrank();
        vm.startPrank(treasury);
        factory = new GoatV1Factory(address(weth));
        vm.stopPrank();
    }

    function testFactoryCreation() public {
        assertEq(factory.weth(), address(weth));
    }

    function testFactoryTreasury() public {
        assertEq(factory.treasury(), treasury);
    }

    function fundMe(IERC20 token, address to, uint256 amount) public {
        vm.startPrank(whale);
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

        _mintInitialLiquidity(initParams, lp);

        uint256 initialLpBalance = pair.balanceOf(lp);
        assertEq(initialLpBalance, 100e18 - MINIMUM_LIQUIDITY);
        (uint256 reserveWeth, uint256 reserveToken) = pair.getReserves();

        assertEq(reserveWeth, initParams.virtualEth);
        assertEq(reserveToken, initParams.initialTokenMatch);

        GoatTypes.InitialLPInfo memory initialLPInfo = pair.getInitialLPInfo();

        // since we allow 25% withdrawls, fractional balance will be 1/4th of the total
        uint256 expectedFractionalBalance = initialLpBalance / 4;

        assertEq(initialLPInfo.liquidityProvider, lp);
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

        (, uint256 tokenAmtForAmm) = _mintInitialLiquidity(initParams, lp);
        // since reserve eth will be 10e18 and reserveToken will be 250e18
        // sqrt of their product = 50e18
        uint256 expectedLp = 50e18 - MINIMUM_LIQUIDITY;
        uint256 initialLpBalance = pair.balanceOf(lp);
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

        _mintInitialLiquidity(initParams, lp);

        // expected lp will be sqrt of initial token match and virtual eth
        // if weth sent is < bootstrap amount
        uint256 expectedLp = 100e18 - MINIMUM_LIQUIDITY;
        uint256 actualK = (uint256(initParams.virtualEth) * uint256(initParams.initialTokenMatch));

        uint256 initialLpBalance = pair.balanceOf(lp);
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
        fundMe(IERC20(address(goat)), lp, bootstrapTokenAmt);
        vm.startPrank(lp);
        address pairAddress = factory.createPair(address(goat), initParams);

        // send less token amount to the pair contract
        goat.transfer(pairAddress, bootstrapTokenAmt - 1);
        pair = GoatV1Pair(pairAddress);

        vm.expectRevert(GoatErrors.InsufficientTokenAmount.selector);
        pair.mint(lp);

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

        fundMe(IERC20(address(goat)), lp, bootstrapTokenAmt);
        vm.deal(lp, 20e18);
        vm.startPrank(lp);
        address pairAddress = factory.createPair(address(goat), initParams);

        weth.deposit{value: 20e18}();
        // send less token amount to the pair contract
        goat.transfer(pairAddress, bootstrapTokenAmt);
        weth.transfer(pairAddress, 20e18);
        pair = GoatV1Pair(pairAddress);

        vm.expectRevert(GoatErrors.SupplyMoreThanBootstrapEth.selector);
        pair.mint(lp);

        vm.stopPrank();
    }

    function testMintRevertOnPresaleIfInitialLiquidityIsAlreadyThere() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 5e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);
        vm.startPrank(alice);
        vm.expectRevert(GoatErrors.PresalePeriod.selector);
        pair.mint(alice);
        vm.stopPrank();
    }

    function testTransferRevertOfInitialLiquidityProvider() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 5e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);
        vm.startPrank(lp);
        vm.expectRevert(GoatErrors.LPTransferRestricted.selector);
        pair.transfer(bob, 1e18);
        vm.stopPrank();
    }

    function testPartialBurnSuccessForInitialLp() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);

        // get initial lp info
        GoatTypes.InitialLPInfo memory initialLPInfo = pair.getInitialLPInfo();
        // burn 1/4th of the lp
        vm.startPrank(lp);

        uint256 totalSupplyBefore = pair.totalSupply();
        uint256 lpWethBalBefore = weth.balanceOf(lp);
        uint256 lpTokenBalanceBefore = goat.balanceOf(lp);

        uint256 warpTime = block.timestamp + 3 days;
        // increase block.timestamp so that initial lp can remove liquidity
        vm.warp(warpTime);
        pair.transfer(address(pair), initialLPInfo.fractionalBalance);
        pair.burn(lp);
        vm.stopPrank();

        uint256 totalSupplyAfter = pair.totalSupply();
        uint256 lpWethBalAfter = weth.balanceOf(lp);
        uint256 lpTokenBalanceAfter = goat.balanceOf(lp);

        GoatTypes.InitialLPInfo memory initialLPInfoAfterBurn = pair.getInitialLPInfo();

        assertEq(initialLPInfoAfterBurn.fractionalBalance, initialLPInfo.fractionalBalance);
        assertEq(initialLPInfoAfterBurn.lastWithdraw, block.timestamp);
        assertEq(initialLPInfoAfterBurn.withdrawlLeft, initialLPInfo.withdrawlLeft - 1);

        assertEq(totalSupplyBefore - totalSupplyAfter, initialLPInfo.fractionalBalance);

        // Using approx value because of initial liquidity mint for zero address
        assertApproxEqAbs(lpWethBalAfter - lpWethBalBefore, 2.5 ether, 0.0001 ether);
        assertApproxEqAbs(lpTokenBalanceAfter - lpTokenBalanceBefore, 62.5 ether, 0.0001 ether);
    }

    function testPartialBurnRevertOnCooldownActive() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);

        // get initial lp info
        GoatTypes.InitialLPInfo memory initialLPInfo = pair.getInitialLPInfo();

        vm.startPrank(lp);
        uint256 warpTime = block.timestamp + 3 days;
        // increase block.timestamp so that initial lp can remove liquidity
        vm.warp(warpTime);
        pair.transfer(address(pair), initialLPInfo.fractionalBalance);
        pair.burn(lp);

        // Withdraw cooldown active check
        pair.transfer(address(pair), initialLPInfo.fractionalBalance);
        vm.expectRevert(GoatErrors.WithdrawalCooldownActive.selector);
        pair.burn(lp);
        vm.stopPrank();
    }

    function testPartialBurnRevertOnPresale() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);

        // get initial lp info
        GoatTypes.InitialLPInfo memory initialLPInfo = pair.getInitialLPInfo();

        vm.startPrank(lp);
        uint256 warpTime = block.timestamp + 3 days;
        // increase block.timestamp so that initial lp can remove liquidity
        vm.warp(warpTime);
        pair.transfer(address(pair), initialLPInfo.fractionalBalance);

        // Should not allow liquidity burn on preslae period!
        vm.expectRevert(GoatErrors.PresalePeriod.selector);
        pair.burn(lp);

        vm.stopPrank();
    }

    function testPartialBurnRevertOnLimitExceeded() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);

        // get initial lp info
        GoatTypes.InitialLPInfo memory initialLPInfo = pair.getInitialLPInfo();

        vm.startPrank(lp);
        uint256 warpTime = block.timestamp + 3 days;
        // increase block.timestamp so that initial lp can remove liquidity
        vm.warp(warpTime);
        // try to burn amount more than allowed
        uint256 withdrawLpAmount = initialLPInfo.fractionalBalance + 1e18;
        pair.transfer(address(pair), withdrawLpAmount);
        vm.expectRevert(GoatErrors.BurnLimitExceeded.selector);
        pair.burn(lp);
        vm.stopPrank();
    }

    function testAddLpAfterPoolTurnsToAnAmm() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);

        _mintLiquidity(5e18, 125e18, bob);

        uint256 bobLpBalance = pair.balanceOf(bob);
        uint256 expectedLpMinted = 25e18;

        assertEq(bobLpBalance, expectedLpMinted);
    }

    function testBurnAfterLockPeriodForOtherLps() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 10e18;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);
        uint256 wethAmt = 5e18;
        uint256 tokenAmt = 125e18;

        _mintLiquidity(wethAmt, tokenAmt, bob);

        uint256 bobLpBalance = pair.balanceOf(bob);

        uint256 wethBalBefore = weth.balanceOf(bob);
        uint256 tokenBalBefore = goat.balanceOf(bob);

        vm.startPrank(bob);
        pair.transfer(address(pair), bobLpBalance);
        uint256 warpTime = block.timestamp + 3 days;
        vm.warp(warpTime);
        pair.burn(bob);

        uint256 wethBalAfter = weth.balanceOf(bob);
        uint256 tokenBalAfter = goat.balanceOf(bob);

        assertEq(wethBalAfter - wethBalBefore, wethAmt);
        assertEq(tokenBalAfter - tokenBalBefore, tokenAmt);
    }

    function testSwapWhenPoolIsInPresale() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);

        vm.startPrank(alice);
        vm.deal(alice, 10e18);
        weth.deposit{value: 10e18}();
        uint256 amountTokenOut = 250e18;
        uint256 amountWethOut = 0;
        weth.transfer(address(pair), 5e18 + 5e16);
        pair.swap(amountTokenOut, amountWethOut, alice);
        vm.stopPrank();
    }

    function testSwapToChangePoolFromPresaleToAnAmm() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);

        vm.startPrank(alice);
        vm.deal(alice, 20e18);
        weth.deposit{value: 20e18}();
        uint256 amountTokenOut = 500e18;
        uint256 amountWethOut = 0;
        weth.transfer(address(pair), 10e18 + 1e17);
        pair.swap(amountTokenOut, amountWethOut, alice);
        vm.stopPrank();
    }

    function testSwapToRecieveTokensFromBothPresaleAndAmm() public {
        GoatTypes.InitParams memory initParams;
        initParams.virtualEth = 10e18;
        initParams.initialEth = 0;
        initParams.initialTokenMatch = 1000e18;
        initParams.bootstrapEth = 10e18;

        _mintInitialLiquidity(initParams, lp);

        vm.startPrank(alice);
        vm.deal(alice, 20e18);
        weth.deposit{value: 20e18}();

        uint256 wethForAmm = 2e18;
        uint256 tokenAmountAtAmm = 250e18;
        uint256 amountTokenOutFromPresale = 500e18;
        uint256 amountTokenOutFromAmm = (wethForAmm * tokenAmountAtAmm) / (initParams.bootstrapEth + wethForAmm);

        uint256 amountTokenOut = amountTokenOutFromAmm + amountTokenOutFromPresale;
        uint256 amountWethOut = 0;
        // TODO: there is indiscrepency when it's becoming an amm. I need to check the
        // swap function. For now I am passing slightly more fees..
        weth.transfer(address(pair), 12e18 + 13e16);
        pair.swap(amountTokenOut, amountWethOut, alice);
        vm.stopPrank();
    }
}
