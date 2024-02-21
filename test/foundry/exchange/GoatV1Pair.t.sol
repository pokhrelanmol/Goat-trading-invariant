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
        GoatTypes.InitParams memory initParams = GoatTypes.InitParams(0, 0, 0, 0);
        address pairAddress = factory.createPair(address(goat), initParams);
        pair = GoatV1Pair(pairAddress);
        assertEq(pair.factory(), address(factory));
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

    function testMintWithoutInitialEth() public {
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
    }

    function testMintWithFullBootstrapEth() public {
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
    }

    function testMintWithPartialBootstrapEth() public {
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
    }
}
