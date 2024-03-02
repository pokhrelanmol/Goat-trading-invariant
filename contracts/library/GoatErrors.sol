// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

contract GoatErrors {
    error ActionNotAllowed();
    error BurnLimitExceeded();
    error EthTransferFailed();
    error Expired();
    error FailedToSendEther();
    error Forbidden();
    error GoatPoolDoesNotExist();
    error GoatV1Forbidden();
    error IncorrectTokenAmount();
    error InsufficientAmountOut();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InsufficientLiquidityBurned();
    error InsufficientLiquidityMinted();
    error InsufficientOutputAmount();
    error InsufficientTakeoverTokenAmount();
    error InsufficientTokenAmount();
    error InsufficientVirtualEth();
    error InsufficientWethAmount();
    error InvalidEthAmount();
    error InvalidParams();
    error KInvariant();
    error LiquidityCooldownActive();
    error LiquidityLocked();
    error LPTransferRestricted();
    error MevDetected();
    error MevDetected1();
    error MevDetected2();
    error MultipleOutputAmounts();
    error NotEnoughBalance();
    error OnlyGov();
    error PoolDoesNotExist();
    error PresaleDeadlineActive();
    error PresalePeriod();
    error Receive();
    error ShouldWithdrawAllBalance();
    error SupplyMoreThanBootstrapEth();
    error Unauthorized();
    error WithdrawalCooldownActive();
    error WrongToken();
    error ZeroAddress();
}
