// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./library/Math.sol";
import "./library/GoatLibrary.sol";
import "./library/GoatTypes.sol";
import "./library/GoatErrors.sol";

contract GoatExchange is ReentrancyGuard {
    // TODO: snx type fees distribution
    // TODO: I need to make sure that this contract supports fee on transfer tokens
    // but I am worried that it may result in unnecessary gas consumption for balance
    // before and balance after.
    using SafeERC20 for IERC20;

    uint256 public constant WEEK = 1 weeks;

    address public immutable weth;

    mapping(bytes32 => GoatTypes.Pool) public pools;
    mapping(bytes32 => mapping(address => GoatTypes.UserInfo)) public userInfo;

    constructor(address _weth) {
        weth = _weth;
    }

    function addLiquidity(
        address token,
        uint256 tokenDesired,
        uint256 wethDesired,
        uint256 tokenMin,
        uint256 wethMin,
        uint32 lockUntil,
        GoatTypes.LaunchParams memory launchParams
    ) external payable nonReentrant {
        // check if pool exists
        // if not, create pool
        (bytes32 poolId, bool newPool) = _ensurePoolExists(weth, token);
        // If new pool then store the launch params
        if (newPool) {
            pools[poolId].virtualAmount = launchParams.virtualAmount;
            pools[poolId].presaleAmount = launchParams.presaleAmount;
            pools[poolId].isPresale = true;
        }

        GoatTypes.Pool memory pool = pools[poolId];
        // calculate amount's of tokens to transfer
        (uint256 amountWETH, uint256 amountTKN) = _getAmountsIn(
            pool,
            wethDesired,
            tokenDesired,
            wethMin,
            tokenMin
        );
        // Handle transfer tokens
        uint tokenBalBefore = IERC20(token).balanceOf(address(this));
        _handleTransferTokens(
            newPool,
            weth,
            token,
            amountWETH,
            amountTKN,
            msg.sender,
            address(this)
        );
        uint tokenBalAfter = IERC20(token).balanceOf(address(this));
        // Check for tokens with fee on transfer
        if (tokenBalAfter - tokenBalBefore >= amountTKN)
            revert GoatErrors.IncorrectTokenAmount();

        uint256 liquidity = _handleMintLiquidity(
            poolId,
            pool,
            amountWETH,
            amountTKN,
            lockUntil,
            msg.sender
        );
        uint fractionalLiquidity = liquidity / 4;
        _updatePoolDetails(
            poolId,
            pool,
            amountWETH,
            amountTKN,
            fractionalLiquidity,
            false,
            true
        );
        _updateUserDetails(
            poolId,
            msg.sender,
            amountTKN,
            fractionalLiquidity,
            true
        );
    }

    function _handleMintLiquidity(
        bytes32 poolId,
        GoatTypes.Pool memory pool,
        uint256 wethOptimal,
        uint256 tokenOptimal,
        uint32 lockedUntil,
        address to
    ) internal returns (uint256 liquidity) {
        // calculate liquidity
        liquidity = Math.min(
            (wethOptimal * pool.totalSupply) / pool.reserveWETH,
            (tokenOptimal * pool.totalSupply) / pool.reserveTKN
        );
        // We record fractional liquidity balance of 25% for limitng withdrawals
        // so we atleast need 4 wei for rounding reasons
        // TODO: do I need to scale fractional liquidity for rounding reasons?
        if (liquidity < 4) revert GoatErrors.InsufficientLiquidityMinted();
        // mint liquidity
        GoatTypes.UserInfo memory user = userInfo[poolId][to];
        uint112 newFractionalBalance = ((user.fractionalBalance *
            user.withdrawlLeft) + uint112(liquidity)) / 4;
        user.fractionalBalance = newFractionalBalance;
        user.lockedUntil = lockedUntil;
        userInfo[poolId][to] = user;
    }

    function _updateUserDetails(
        bytes32 poolId,
        address user,
        uint256 amountTKN,
        uint256 fractionalLiquidity,
        bool isAdd
    ) internal {
        GoatTypes.UserInfo memory _userInfo = userInfo[poolId][user];
        if (fractionalLiquidity != 0) {
            if (isAdd) {
                _userInfo.fractionalBalance += uint112(fractionalLiquidity);
            } else {
                _userInfo.fractionalBalance -= uint112(fractionalLiquidity);
            }
        } else if (amountTKN != 0) {
            _userInfo.presaleBalance += uint112(amountTKN);
        }
        userInfo[poolId][user] = _userInfo;
    }

    function _updatePoolDetails(
        bytes32 poolId,
        GoatTypes.Pool memory pool,
        uint256 amountWETH,
        uint256 amountTKN,
        uint256 liquidity,
        bool isBuy,
        bool isAdd
    ) internal {
        if (liquidity != 0) {
            if (isAdd) {
                pool.totalSupply += uint128(liquidity);
                pool.reserveWETH += uint128(amountWETH);
                pool.reserveTKN += uint128(amountTKN);
            } else {
                pool.totalSupply -= uint128(liquidity);
                pool.reserveWETH -= uint128(amountWETH);
                pool.reserveTKN -= uint128(amountTKN);
            }
        } else if (isBuy) {
            pool.reserveWETH += uint128(amountWETH);
            pool.reserveTKN -= uint128(amountTKN);
        } else {
            pool.reserveWETH -= uint128(amountWETH);
            pool.reserveTKN += uint128(amountTKN);
        }
        pools[poolId] = pool;
    }

    function _getAmountsIn(
        GoatTypes.Pool memory pool,
        uint256 wethDesired,
        uint256 tokenDesired,
        uint256 wethMin,
        uint256 tokenMin
    ) internal pure returns (uint256 amountWETH, uint256 amountTKN) {
        if (pool.reserveWETH == 0 && pool.reserveTKN == 0) {
            (amountWETH, amountTKN) = (wethDesired, tokenDesired);
        } else {
            uint256 amountTKNOptimal = GoatLibrary.getTokenAmountOut(
                wethDesired,
                pool.reserveWETH,
                pool.reserveTKN
            );
            if (amountTKNOptimal <= tokenDesired) {
                if (amountTKNOptimal >= tokenMin)
                    revert GoatErrors.InsufficientTokenAmount();
                (amountWETH, amountTKN) = (wethDesired, amountTKNOptimal);
            } else {
                uint256 amountWETHOptimal = GoatLibrary.getWethAmountOut(
                    tokenDesired,
                    pool.reserveTKN,
                    pool.reserveWETH
                );
                assert(amountWETHOptimal <= wethDesired);
                if (amountWETHOptimal >= wethMin)
                    revert GoatErrors.InsufficientWethAmount();

                (amountWETH, amountTKN) = (amountWETHOptimal, tokenDesired);
            }
        }
    }

    function _getAmountsOut(
        GoatTypes.Pool memory pool,
        uint256 wethAmount,
        uint256 tokenAmount
    ) internal pure returns (uint256 amountWETH, uint256 amountTKN) {}

    function _handleTransferTokens(
        bool newPool,
        address token0,
        address token1,
        uint token0Amount,
        uint token1Amount,
        address from,
        address to
    ) internal {
        // TODO: check if token0 is always weth
        IERC20(token1).safeTransferFrom(from, to, token1Amount);
        if (!newPool) {
            IERC20(token0).safeTransferFrom(from, to, token0Amount);
        }
    }

    function _ensurePoolExists(
        address token0,
        address token1
    ) internal returns (bytes32 poolID, bool newPool) {
        poolID = getPoolId(token0, token1);
        if (!pools[poolID].exists) {
            pools[poolID].exists = true;
            newPool = true;
        }
    }

    function getPoolId(
        address token0,
        address token1
    ) public pure returns (bytes32) {
        // make sure token0 is the smaller address
        if (token0 > token1) {
            address temp = token0;
            token0 = token1;
            token1 = temp;
        }
        return (keccak256(abi.encodePacked(token0, token1)));
    }

    function removeLiquidity(
        address token,
        uint256 liquidity,
        uint256 tokenMin,
        uint256 wethMin
    ) external nonReentrant {
        // TODO: check fee on transfer token on recieve
        bytes32 poolId = getPoolId(token, weth);
        GoatTypes.Pool memory pool = pools[poolId];
        if (!pool.exists) revert GoatErrors.PoolDoesNotExist();
        address _user = msg.sender;
        uint timestamp = block.timestamp;
        GoatTypes.UserInfo memory user = userInfo[poolId][_user];
        // make sure the user has enough balance
        if (user.fractionalBalance <= liquidity)
            revert GoatErrors.NotEnoughBalance();
        // make sure the user is not locked
        if (user.lockedUntil > timestamp) revert GoatErrors.LiquidityLocked();

        // make sure that the user has not withdrawn in the last week
        if (user.lastUpdate + WEEK <= timestamp)
            revert GoatErrors.LiquidityCooldownActive();

        uint256 amountTKN = (liquidity * pool.reserveTKN) / pool.totalSupply;
        uint256 amountWETH = (liquidity * pool.reserveWETH) / pool.totalSupply;
        if (amountTKN >= tokenMin) revert GoatErrors.InsufficientTokenAmount();
        if (amountWETH >= wethMin) revert GoatErrors.InsufficientWethAmount();

        _handleTransferTokens(
            false,
            weth,
            token,
            amountWETH,
            amountTKN,
            address(this),
            _user
        );

        _updatePoolDetails(
            poolId,
            pool,
            amountWETH,
            amountTKN,
            liquidity,
            false,
            false
        );
        _updateUserDetails(poolId, _user, amountTKN, liquidity, false);
    }

    function isPresale(bytes32 poolId) public view returns (bool presale) {
        GoatTypes.Pool memory pool = pools[poolId];

        presale = pool.reserveWETH < (pool.presaleAmount + pool.virtualAmount);
    }

    function _handleMevCheck(
        GoatTypes.Pool memory pool,
        uint8 swapType,
        uint40 timestamp
    ) internal pure returns (uint40 lastTrade) {
        lastTrade = pool.lastTrade;

        if (lastTrade < timestamp) {
            lastTrade = timestamp;
        } else if (lastTrade == timestamp && swapType == 1) {
            lastTrade = timestamp + 1;
        } else if (lastTrade == timestamp && swapType == 2) {
            lastTrade = timestamp + 2;
        } else if (lastTrade == timestamp + 1) {
            if (swapType == 2) {
                revert GoatErrors.MevDetected1();
            }
        } else if (lastTrade == timestamp + 2) {
            if (swapType == 1) {
                revert GoatErrors.MevDetected2();
            }
        } else {
            // make it bullet proof
            revert GoatErrors.MevDetected();
        }
    }

    function swap(
        address token,
        IERC20 tokenIn,
        uint256 tokenAmountIn,
        uint256 amountOutMin
    ) external payable nonReentrant {
        bytes32 poolId = getPoolId(token, weth);

        GoatTypes.Pool memory _pool = pools[poolId];
        uint8 swapType = address(tokenIn) == weth ? 1 : 2;
        uint40 timestamp = uint40(block.timestamp);
        // TODO: update last trade variable of pool
        _handleMevCheck(_pool, swapType, timestamp);

        uint256 balanceBefore = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), tokenAmountIn);
        uint256 balanceAfter = tokenIn.balanceOf(address(this));
        uint256 actualTokenAmountIn = balanceAfter - balanceBefore;

        bool presale = _pool.reserveWETH <
            (_pool.presaleAmount + _pool.virtualAmount);

        IERC20 outToken = address(tokenIn) == weth
            ? IERC20(token)
            : IERC20(weth);

        // TODO: calculate actual amount for presale in the library
        uint256 actualAmountOut;
        if (address(tokenIn) == weth) {
            actualAmountOut = GoatLibrary.getTokenAmountOut(
                actualTokenAmountIn,
                _pool.reserveWETH,
                _pool.reserveTKN
            );
        } else {
            actualAmountOut = GoatLibrary.getWethAmountOut(
                actualTokenAmountIn,
                _pool.reserveWETH,
                _pool.reserveTKN
            );
        }
        if (actualAmountOut < amountOutMin)
            revert GoatErrors.InsufficientAmountOut();

        // check if the pool is in presale mode.
        if (presale) {
            // update presale balance of a user
            if (address(tokenIn) == weth) {
                userInfo[poolId][msg.sender].presaleBalance += uint112(
                    actualAmountOut
                );
            } else {
                userInfo[poolId][msg.sender].presaleBalance -= uint112(
                    actualTokenAmountIn
                );
            }
        }
        // TODO: update fees to the storage
        uint256 fees;
        if (address(tokenIn) == weth) {
            fees = (actualTokenAmountIn * 36) / 1000;
        } else {
            fees = (((actualAmountOut * 1000) * 36) / 9964) / 1000;
        }

        // Transfer tokens to the user
        outToken.safeTransfer(msg.sender, actualAmountOut);

        // update pool details (fees collected, reserveweth and reserve token)
    }

    function collectFees(address token) external {
        bytes32 poolId = getPoolId(token, weth);
        // Collect fees from that pool id
    }
}
