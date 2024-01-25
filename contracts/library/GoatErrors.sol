// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract GoatErrors {
    error Unauthorized();
    error FailedToSendEther();
    error ZeroAddress();
    error PoolDoesNotExist();
    error GoatPoolDoesNotExist();
    error LiquidityLocked();
    error NotEnoughBalance();
    error LiquidityCooldownActive();
    error IncorrectTokenAmount();
    error InsufficientWethAmount();
    error InsufficientTokenAmount();
    error InsufficientAmountOut();
    error InsufficientVirtualEth();
    error InsufficientLiquidityMinted();
    error MevDetected();
    error MevDetected1();
    error MevDetected2();
    error OnlyGov();
    error Receive();
    error PresalePeriod();
}
