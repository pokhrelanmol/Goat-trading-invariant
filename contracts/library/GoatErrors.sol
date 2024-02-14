// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

contract GoatErrors {
    error Unauthorized();
    error FailedToSendEther();
    error ZeroAddress();
    error PoolDoesNotExist();
    error GoatPoolDoesNotExist();
    error GoatV1Forbidden();
    error LiquidityLocked();
    error NotEnoughBalance();
    error LiquidityCooldownActive();
    error IncorrectTokenAmount();
    error InsufficientWethAmount();
    error InsufficientTokenAmount();
    error InsufficientOutputAmount();
    error InsufficientAmountOut();
    error InsufficientVirtualEth();
    error InsufficientLiquidityMinted();
    error MevDetected();
    error MevDetected1();
    error MevDetected2();
    error MultipleOutputAmounts();
    error OnlyGov();
    error Receive();
    error PresalePeriod();
}
