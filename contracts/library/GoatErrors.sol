// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract GoatErrors {
    error ZeroAddress();
    error PoolDoesNotExist();
    error LiquidityLocked();
    error NotEnoughBalance();
    error LiquidityCooldownActive();
    error IncorrectTokenAmount();
    error InsufficientWethAmount();
    error InsufficientTokenAmount();
    error InsufficientAmountOut();
    error InsufficientVirtualAmount();
    error InsufficientLiquidityMinted();
    error MevDetected();
    error MevDetected1();
    error MevDetected2();
    error OnlyGov();
    error Receive();
}
