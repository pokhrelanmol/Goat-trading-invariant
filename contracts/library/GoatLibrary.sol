// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./GoatTypes.sol";

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
        require(pool.reserveWeth > 0 && pool.reserveToken > 0, "GoatLibrary: INSUFFICIENT_LIQUIDITY");
        // 1% fee on WETH
        uint256 actualAmountWETHIn = amountWETHIn * 9900;
        uint256 numerator;
        uint256 denominator;
        if (pool.vestingUntil != type(uint32).max) {
            numerator = actualAmountWETHIn * pool.reserveToken;
            denominator = pool.reserveWeth * 10000 + actualAmountWETHIn;
            amountTKNOut = numerator / denominator;
            // TODO: handle a situation when the current swap will be fraction trade on amm and remaining on presale
        } else {
            // If it's presale
            // TODO: Figure out if using KLast might cause problems
            numerator = actualAmountWETHIn * (pool.kLast / (pool.virtualEth + pool.reserveWETH));

            denominator = (pool.virtualEth + pool.reserveWETH) * 10000 + actualAmountWETHIn;
            tokenOut = numerator / denominator;
        }
    }

    ///@notice given amount of token in and pool reserves
    /// @return amountWETHOut an equivalent amount of the other asset
    function getWethAmountOut(uint256 amountTKNIn, GoatTypes.Pool memory pool)
        internal
        pure
        returns (uint256 amountWETHOut)
    {
        require(amountTKNIn > 0, "GoatLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(pool.reserveWeth > 0 && pool.reserveToken > 0, "GoatLibrary: INSUFFICIENT_LIQUIDITY");
        amountTKNIn = amountTKNIn * 10000;

        uint256 numerator;
        uint256 denominator;
        uint256 actualAmountWETHOut;
        if (pool.vestingUntil != type(uint32).max) {
            // amm logic
            numerator = amountTKNIn * pool.reserveWeth;
            denominator = pool.reserveToken * 10000 + amountTKNIn;
            actualAmountWETHOut = numerator / denominator;
        } else {
            // presale logic
            numerator = amountTKNIn * (pool.virtualEth + pool.reserveWETH);
            denominator = (pool.kLast / (pool.virtualEth + pool.reserveWETH)) * 10000 + amountTKNIn;
            actualAmountWETHOut = numerator / denominator;
        }
        // 1% fee on WETH
        amountWETHOut = (actualAmountWETHOut * 9900) / 10000;
    }

    function getTokenAmountIn() internal pure returns (uint256 amountTokenIn) {}

    function getWethAmountIn() internal pure returns (uint256 amountWethIn) {}
}
