// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library GoatLibrary {
    ///@notice given some amount of asset and pair reserves,
    /// @return amountB an equivalent amount of the other asset
    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) internal pure returns (uint amountB) {
        require(amountA > 0, "GoatLibrary: INSUFFICIENT AMOUNT");
        require(
            reserveA > 0 && reserveB > 0,
            "GoatLibrary: INSUFFICIENT_LIQUIDITY"
        );
        amountB = (amountA * reserveB) / reserveA;
    }

    ///@notice given amount of weth in and pool reserves
    /// @return amountTKNOut an equivalent amount of the other asset
    function getTokenAmountOut(
        uint amountWETHIn,
        uint reserveWETH,
        uint reserveTKN
    ) internal pure returns (uint amountTKNOut) {
        require(amountWETHIn > 0, "GoatLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveWETH > 0 && reserveTKN > 0,
            "GoatLibrary: INSUFFICIENT_LIQUIDITY"
        );
        // .36% fee on WETH
        uint actualAmountWETHIn = amountWETHIn * 9964;
        uint numerator = actualAmountWETHIn * reserveTKN;
        uint denominator = reserveWETH * 10000 + actualAmountWETHIn;
        amountTKNOut = numerator / denominator;
    }

    ///@notice given amount of token in and pool reserves
    /// @return amountWETHOut an equivalent amount of the other asset
    function getWethAmountOut(
        uint amountTKNIn,
        uint reserveWETH,
        uint reserveTKN
    ) internal pure returns (uint amountWETHOut) {
        require(amountTKNIn > 0, "GoatLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveWETH > 0 && reserveTKN > 0,
            "GoatLibrary: INSUFFICIENT_LIQUIDITY"
        );
        amountTKNIn = amountTKNIn * 10000;
        uint numerator = amountTKNIn * reserveWETH;
        uint denominator = reserveTKN * 10000 + amountTKNIn;
        uint actualAmountWETHOut = numerator / denominator;
        // .36% fee on WETH
        amountWETHOut = (actualAmountWETHOut * 9964) / 10000;
    }

    function getTokenAmountIn() internal pure returns (uint amountTokenIn) {}

    function getWethAmountIn() internal pure returns (uint amountWethIn) {}
}
