// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./GoatTypes.sol";
import "./GoatErrors.sol";

import {console2} from "forge-std/console2.sol";

library GoatLibrary {
    ///@notice given some amount of asset and pair reserves,
    /// @return amountB an equivalent amount of the other asset
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "GoatLibrary: INSUFFICIENT AMOUNT");
        require(reserveA > 0 && reserveB > 0, "GoatLibrary: INSUFFICIENT_LIQUIDITY");

        amountB = (amountA * reserveB) / reserveA;
    }

    ///@notice given amount of weth in and pool reserves
    /// @return amountTKNOut an equivalent amount of the other asset
    function getTokenAmountOut(uint256 amountWETHIn, GoatTypes.Pool memory pool)
        internal
        pure
        returns (uint256 amountTKNOut)
    {
        require(amountWETHIn > 0, "GoatLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(pool.reserveEth > 0 && pool.reserveToken > 0, "GoatLibrary: INSUFFICIENT_LIQUIDITY");
        // 1% fee on WETH
        uint256 actualAmountWETHIn = amountWETHIn * 9900;
        uint256 numerator;
        uint256 denominator;
        if (pool.vestingUntil != type(uint32).max) {
            numerator = actualAmountWETHIn * pool.reserveToken;
            denominator = pool.reserveEth * 10000 + actualAmountWETHIn;
            amountTKNOut = numerator / denominator;
            // TODO: handle a situation when the current swap will be fraction trade on amm and remaining on presale
        } else {
            // If it's presale
            // TODO: Figure out if using KLast might cause problems
            numerator = actualAmountWETHIn * (pool.kLast / (pool.virtualEth + pool.reserveEth));
            denominator = (pool.virtualEth + pool.reserveEth) * 10000 + actualAmountWETHIn;
            amountTKNOut = numerator / denominator;
        }
    }

    function getTokenAmountOutAmm(uint256 amountWethIn, uint256 reserveEth, uint256 reserveToken)
        internal
        pure
        returns (uint256 amountTokenOut)
    {
        uint256 actualWethIn = amountWethIn * 9901;

        uint256 numerator = actualWethIn * reserveToken;
        uint256 denominator = reserveEth * 10000 + actualWethIn;

        amountTokenOut = numerator / denominator;
    }

    function _getTokenAmountForAmm(uint256 virtualEth, uint256 bootstrapEth, uint256 initialTokenMatch)
        internal
        pure
        returns (uint256 tokenAmtForAmm)
    {
        uint256 k = virtualEth * initialTokenMatch;
        tokenAmtForAmm = ((k / (virtualEth + bootstrapEth)) / (virtualEth + bootstrapEth)) * bootstrapEth;
    }

    function getTokenAmountOutPresale(
        uint256 amountWethIn,
        uint256 virtualEth,
        uint256 reserveEth,
        uint256 bootStrapEth,
        uint256 reserveToken,
        uint256 virtualToken,
        uint256 reserveTokenForAmm
    ) internal pure returns (uint256 amountTokenOut) {
        uint256 actualWethIn = (amountWethIn * 9901) / 10000;

        uint256 wethForAmm;
        uint256 wethForPresale;
        uint256 amountTokenOutPresale;
        uint256 amountTokenOutAmm;

        if (reserveEth + actualWethIn > bootStrapEth) {
            wethForAmm = (reserveEth + actualWethIn) - bootStrapEth;
        }
        wethForPresale = (actualWethIn - wethForAmm) * 10000;
        uint256 numerator = wethForPresale * (virtualToken + reserveToken);
        uint256 denominator = (reserveEth + virtualEth) * 10000 + wethForPresale;
        amountTokenOutPresale = numerator / denominator;

        if (wethForAmm > 0) {
            wethForAmm = wethForAmm * 10000;
            numerator = wethForAmm * reserveTokenForAmm;
            denominator = bootStrapEth * 10000 + wethForAmm;
            amountTokenOutAmm = numerator / denominator;
        }
        amountTokenOut = amountTokenOutPresale + amountTokenOutAmm;
    }

    function _getTokenAmountOut(
        uint256 amountWethIn,
        uint256 virtualEth,
        uint256 reserveEth,
        uint32 vestingUntil,
        uint256 bootStrapEth,
        uint256 reserveToken,
        uint256 virtualToken,
        uint256 reserveTokenForAmm
    ) internal pure returns (uint256 amountTokenOut) {
        if (amountWethIn == 0) revert GoatErrors.InsufficientInputAmount();

        // 100 bps is considered as fees
        uint256 actualWethIn = amountWethIn * 9901;

        uint256 numerator;
        uint256 denominator;

        uint256 amountTokenOutPresale;
        uint256 amountTokenOutAmm;
        if (vestingUntil != type(uint32).max) {
            // amm logic
            numerator = actualWethIn * reserveToken;
            denominator = reserveEth * 10000 + actualWethIn;
            amountTokenOutAmm = numerator / denominator;
        } else {
            // Scale actual weth down
            actualWethIn = actualWethIn / 10000;

            uint256 wethForAmm;
            uint256 wethForPresale;

            if (reserveEth + actualWethIn > bootStrapEth) {
                wethForAmm = (reserveEth + actualWethIn) - bootStrapEth;
            }
            wethForPresale = (actualWethIn - wethForAmm) * 10000;
            numerator = wethForPresale * (virtualToken + reserveToken);
            denominator = (reserveEth + virtualEth) * 10000 + wethForPresale;
            amountTokenOutPresale = numerator / denominator;

            if (wethForAmm > 0) {
                wethForAmm = wethForAmm * 10000;
                numerator = wethForAmm * reserveTokenForAmm;
                denominator = bootStrapEth * 10000 + wethForAmm;
                amountTokenOutAmm = numerator / denominator;
            }
        }
        amountTokenOut = amountTokenOutPresale + amountTokenOutAmm;
    }

    function getWethAmountOutAmm(uint256 amountTokenIn, uint256 reserveEth, uint256 reserveToken)
        internal
        pure
        returns (uint256 amountWethOut)
    {
        if (amountTokenIn == 0) revert GoatErrors.InsufficientInputAmount();
        if (reserveEth == 0 || reserveToken == 0) revert GoatErrors.InsufficientLiquidity();
        amountTokenIn = amountTokenIn * 10000;
        uint256 numerator;
        uint256 denominator;
        uint256 actualAmountWETHOut;
        // amm logic
        numerator = amountTokenIn * reserveEth;
        denominator = reserveToken * 10000 + amountTokenIn;
        actualAmountWETHOut = numerator / denominator;
        // 1% fee on WETH
        amountWethOut = (actualAmountWETHOut * 9901) / 10000;
    }

    function getWethAmountOutPresale(
        uint256 amountTokenIn,
        uint256 reserveEth,
        uint256 reserveToken,
        uint256 virtualEth,
        uint256 virtualToken,
        uint32 vestingUntil
    ) internal pure returns (uint256 amountWethOut) {
        if (amountTokenIn == 0) revert GoatErrors.InsufficientInputAmount();
        if (reserveEth == 0 || reserveToken == 0) revert GoatErrors.InsufficientLiquidity();
        amountTokenIn = amountTokenIn * 10000;
        uint256 numerator;
        uint256 denominator;
        uint256 actualAmountWETHOut;
        numerator = amountTokenIn * (virtualEth + reserveEth);
        denominator = (virtualToken + reserveToken) * 10000 + amountTokenIn;
        actualAmountWETHOut = numerator / denominator;
        // 1% fee on WETH
        amountWethOut = (actualAmountWETHOut * 9901) / 10000;
    }

    ///@notice given amount of token in and pool reserves
    /// @return amountWethOut an equivalent amount of the other asset
    function _getWethAmountOut(
        uint256 amountTokenIn,
        uint256 reserveEth,
        uint256 reserveToken,
        uint256 virtualEth,
        uint256 virtualToken,
        uint32 vestingUntil
    ) internal pure returns (uint256 amountWethOut) {
        if (amountTokenIn == 0) revert GoatErrors.InsufficientInputAmount();
        if (reserveEth == 0 || reserveToken == 0) revert GoatErrors.InsufficientLiquidity();
        amountTokenIn = amountTokenIn * 10000;
        uint256 numerator;
        uint256 denominator;
        uint256 actualAmountWETHOut;
        if (vestingUntil != type(uint32).max) {
            // amm logic
            numerator = amountTokenIn * reserveEth;
            denominator = reserveToken * 10000 + amountTokenIn;
            actualAmountWETHOut = numerator / denominator;
        } else {
            numerator = amountTokenIn * (virtualEth + reserveEth);
            denominator = (virtualToken + reserveToken) * 10000 + amountTokenIn;
            actualAmountWETHOut = numerator / denominator;
        }
        // 1% fee on WETH
        amountWethOut = (actualAmountWETHOut * 9901) / 10000;
    }

    ///@notice given amount of token in and pool reserves
    /// @return amountWETHOut an equivalent amount of the other asset
    function getWethAmountOut(uint256 amountTKNIn, GoatTypes.Pool memory pool)
        internal
        pure
        returns (uint256 amountWETHOut)
    {
        require(amountTKNIn > 0, "GoatLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(pool.reserveEth > 0 && pool.reserveToken > 0, "GoatLibrary: INSUFFICIENT_LIQUIDITY");
        amountTKNIn = amountTKNIn * 10000;

        uint256 numerator;
        uint256 denominator;
        uint256 actualAmountWETHOut;
        if (pool.vestingUntil != type(uint32).max) {
            // amm logic
            numerator = amountTKNIn * pool.reserveEth;
            denominator = pool.reserveToken * 10000 + amountTKNIn;
        } else {
            numerator = amountTKNIn * (pool.virtualEth + pool.reserveEth);
            denominator = (pool.kLast / (pool.virtualEth + pool.reserveEth)) * 10000 + amountTKNIn;
        }
        actualAmountWETHOut = numerator / denominator;
        // 1% fee on WETH
        amountWETHOut = (actualAmountWETHOut * 9901) / 10000;
    }

    function getActualBootstrapTokenAmount(
        uint256 virtualEth,
        uint256 bootstrapEth,
        uint256 initialEth,
        uint256 initialTokenMatch
    ) internal pure returns (uint256 actualTokenAmount) {
        (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm) =
            _getTokenAmountsForPresaleAndAmm(virtualEth, bootstrapEth, initialEth, initialTokenMatch);
        actualTokenAmount = tokenAmtForPresale + tokenAmtForAmm;
    }

    function getTokenAmountsForPresaleAndAmm(
        uint256 virtualEth,
        uint256 bootstrapEth,
        uint256 initialEth,
        uint256 initialTokenMatch
    ) internal pure returns (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm) {
        (tokenAmtForPresale, tokenAmtForAmm) =
            _getTokenAmountsForPresaleAndAmm(virtualEth, bootstrapEth, initialEth, initialTokenMatch);
    }

    function _getTokenAmountsForPresaleAndAmm(
        uint256 virtualEth,
        uint256 bootstrapEth,
        uint256 initialEth,
        uint256 initialTokenMatch
    ) private pure returns (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm) {
        uint256 k = virtualEth * initialTokenMatch;
        tokenAmtForPresale = initialTokenMatch - (k / (virtualEth + bootstrapEth));
        tokenAmtForAmm = ((k / (virtualEth + bootstrapEth)) / (virtualEth + bootstrapEth)) * bootstrapEth;

        if (initialEth != 0) {
            uint256 numerator = (initialEth * initialTokenMatch);
            uint256 denominator = virtualEth + initialEth;
            uint256 tokenAmountOut = numerator / denominator;
            tokenAmtForPresale -= tokenAmountOut;
        }
    }

    function getTokenAmountIn() internal pure returns (uint256 amountTokenIn) {}

    function getWethAmountIn() internal pure returns (uint256 amountWethIn) {}
}
