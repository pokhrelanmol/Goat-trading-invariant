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
    event Swap(
        address indexed sender,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 timestamp
    );
    event AddLiquidity(address indexed sender, address token, uint256 amountTKN, uint256 amountWETH, uint256 timestamp);
    event RemoveLiquidity(
        address indexed sender, address token, uint256 amountTKN, uint256 amountWETH, uint256 timestamp
    );

    using SafeERC20 for IERC20;

    uint256 public constant WEEK = 1 weeks;

    address public immutable weth;
    address public gov;
    uint256 public pendingProtocolFees;

    mapping(bytes32 => GoatTypes.Pool) public pools;
    mapping(bytes32 => mapping(address => GoatTypes.UserInfo)) public userInfo;
    // poolId => liquidity provider => reward to be paid
    mapping(bytes32 => mapping(address => uint256)) public rewards;

    constructor(address _weth, address _gov) {
        weth = _weth;
        gov = _gov;
    }

    /**
     * @dev Adds liquidity to a pool in the exchange.
     * @param token The address of the token for which liquidity is being added.
     * @param tokenDesired The amount of the token the user wishes to add.
     * @param wethDesired The amount of WETH the user wishes to add.
     * @param tokenMin The minimum amount of the token to add for liquidity.
     * @param wethMin The minimum amount of WETH to add for liquidity.
     * @param lockUntil The timestamp until which the liquidity will be locked.
     * @param launchParams The initial launch parameters for the pool.
     * @notice Handles the addition of liquidity to a pool, including token transfers, liquidity minting, updating pool, and user details.
     * @notice Emits an {AddLiquidity} event on successful liquidity addition.
     */
    // TODO: do we need to add to argument?
    function addLiquidity(
        address token,
        uint256 tokenDesired,
        uint256 wethDesired,
        uint256 tokenMin,
        uint256 wethMin,
        uint32 lockUntil,
        GoatTypes.LaunchParams memory launchParams
    ) external payable nonReentrant {
        // TODO: Do I need to check launch params for initial weth and virtual amount?
        // What problems would be caused if initial weth is > virtual amount?
        // Todo: is this check necessary?
        if (token == address(0)) revert GoatErrors.ZeroAddress();

        (bytes32 poolId, bool newPool) = _ensurePoolExists(weth, token);

        GoatTypes.Pool memory pool = pools[poolId];

        if (newPool) {
            pool.virtualAmount = launchParams.virtualAmount;
            pool.presaleAmount = launchParams.presaleAmount;

            if (launchParams.virtualAmount + launchParams.presaleAmount < launchParams.initialWETH) {
                pool.isPresale = true;
            }
        }

        // calculate amount's of tokens to transfer
        (uint256 amountWETH, uint256 amountTKN) = _getAmountsIn(pool, wethDesired, tokenDesired, wethMin, tokenMin);
        // Handle transfer tokens
        {
            uint256 tokenBalBefore = IERC20(token).balanceOf(address(this));
            _handleTransferTokens(
                token, newPool ? launchParams.initialWETH : amountWETH, amountTKN, msg.sender, address(this)
            );
            uint256 tokenBalAfter = IERC20(token).balanceOf(address(this));
            // Check for tokens with fee on transfer
            if (tokenBalAfter - tokenBalBefore >= amountTKN) {
                revert GoatErrors.IncorrectTokenAmount();
            }

            uint256 liquidity = _handleMintLiquidity(poolId, pool, amountWETH, amountTKN, lockUntil, msg.sender);
            uint256 fractionalLiquidity = liquidity / 4;
            _updatePoolDetails(poolId, pool, amountWETH, amountTKN, fractionalLiquidity, false, true);
            _updateUserDetails(poolId, msg.sender, amountTKN, fractionalLiquidity, pool.feesPerTokenStored, true);
        }

        emit AddLiquidity(msg.sender, token, amountTKN, amountWETH, block.timestamp);
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
            (wethOptimal * pool.totalSupply) / pool.reserveWETH, (tokenOptimal * pool.totalSupply) / pool.reserveTKN
        );
        // We record fractional liquidity balance of 25% for limitng withdrawals
        // so we atleast need 4 wei for rounding reasons
        // TODO: do I need to scale fractional liquidity for rounding reasons?
        if (liquidity < 4) revert GoatErrors.InsufficientLiquidityMinted();
        // mint liquidity
        GoatTypes.UserInfo memory user = userInfo[poolId][to];
        // TODO: check if new fractional balance calculation is correct
        uint112 newFractionalBalance = ((user.fractionalBalance * user.withdrawlLeft) + uint112(liquidity)) / 4;
        user.fractionalBalance = newFractionalBalance;
        user.lockedUntil = lockedUntil;
        userInfo[poolId][to] = user;
    }

    function _updateUserDetails(
        bytes32 poolId,
        address user,
        uint256 amountTKN,
        uint256 fractionalLiquidity,
        uint256 feesPerTokenPaid,
        bool isAdd
    ) internal {
        GoatTypes.UserInfo memory _userInfo = userInfo[poolId][user];
        // TODO: check if fees per token paid is scaled
        _userInfo.pendingFees += uint112(
            (feesPerTokenPaid - _userInfo.feesPerTokenPaid) * _userInfo.fractionalBalance * _userInfo.withdrawlLeft
        );

        _userInfo.feesPerTokenPaid = uint96(feesPerTokenPaid);

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
        // TODO: change presale to false conditional
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
            uint256 amountTKNOptimal = GoatLibrary.getTokenAmountOut(wethDesired, pool.reserveWETH, pool.reserveTKN);
            if (amountTKNOptimal <= tokenDesired) {
                if (amountTKNOptimal >= tokenMin) {
                    revert GoatErrors.InsufficientTokenAmount();
                }
                (amountWETH, amountTKN) = (wethDesired, amountTKNOptimal);
            } else {
                uint256 amountWETHOptimal =
                    GoatLibrary.getWethAmountOut(tokenDesired, pool.reserveTKN, pool.reserveWETH);
                assert(amountWETHOptimal <= wethDesired);
                if (amountWETHOptimal >= wethMin) {
                    revert GoatErrors.InsufficientWethAmount();
                }

                (amountWETH, amountTKN) = (amountWETHOptimal, tokenDesired);
            }
        }
    }

    function _getAmountsOut(GoatTypes.Pool memory pool, uint256 wethAmount, uint256 tokenAmount)
        internal
        pure
        returns (uint256 amountWETH, uint256 amountTKN)
    {}

    /**
     * @notice Transfers specified amounts of token and WETH from one address to another.
     * @param token The address of the token to transfer.
     * @param wethAmount The amount of WETH to transfer.
     * @param tokenAmount The amount of the specified token to transfer.
     * @param from The address from which the tokens are transferred.
     * @param to The address to which the tokens are transferred.
     * @dev Performs a safe transfer of the specified amounts of token and WETH using the OpenZeppelin SafeERC20 library.
     *      If the wethAmount is zero, only the specified token is transferred.
     */
    function _handleTransferTokens(address token, uint256 wethAmount, uint256 tokenAmount, address from, address to)
        internal
    {
        IERC20(token).safeTransferFrom(from, to, tokenAmount);
        if (wethAmount != 0) {
            IERC20(weth).safeTransferFrom(from, to, wethAmount);
        }
    }

    /**
     * @notice Ensures that a liquidity pool for a given pair of tokens exists in the contract.
     * @param token0 The address of the first token in the pair.
     * @param token1 The address of the second token in the pair.
     * @dev Checks if the pool for the given token pair exists. If it doesn't, the function initializes the pool and marks it as a new pool.
     * @return poolID The unique identifier of the pool.
     * @return newPool A boolean indicating whether a new pool was created (true) or if the pool already existed (false).
     */
    function _ensurePoolExists(address token0, address token1) internal returns (bytes32 poolID, bool newPool) {
        poolID = getPoolId(token0, token1);
        if (!pools[poolID].exists) {
            pools[poolID].exists = true;
            newPool = true;
        }
    }

    /**
     * @notice Calculates and returns the unique identifier for a pool based on two token addresses.
     * @param token0 The address of the first token in the pair.
     * @param token1 The address of the second token in the pair.
     * @dev Ensures token0 is the smaller address to maintain a consistent ordering, then returns a keccak256 hash of the ordered pair.
     * @return poolId The unique pool identifier derived from the two token addresses.
     */
    function getPoolId(address token0, address token1) public pure returns (bytes32 poolId) {
        // make sure token0 is the smaller address
        if (token0 > token1) {
            address temp = token0;
            token0 = token1;
            token1 = temp;
        }
        poolId = (keccak256(abi.encodePacked(token0, token1)));
    }

    /**
     * @dev Removes liquidity from a pool in the exchange.
     * @param token The address of the token for which liquidity is being removed.
     * @param liquidity The amount of liquidity to remove.
     * @param tokenMin The minimum amount of the token that must be received.
     * @param wethMin The minimum amount of WETH that must be received.
     * @notice Handles the removal of liquidity from a pool, including token transfers and updating pool and user details.
     * @notice Emits a {RemoveLiquidity} event on successful liquidity removal.
     */
    function removeLiquidity(address token, uint256 liquidity, uint256 tokenMin, uint256 wethMin)
        external
        nonReentrant
    {
        bytes32 poolId = getPoolId(token, weth);
        GoatTypes.Pool memory pool = pools[poolId];
        if (!pool.exists) revert GoatErrors.PoolDoesNotExist();
        address _user = msg.sender;
        uint256 timestamp = block.timestamp;
        GoatTypes.UserInfo memory user = userInfo[poolId][_user];
        // make sure the user has enough balance
        if (user.fractionalBalance <= liquidity) {
            revert GoatErrors.NotEnoughBalance();
        }
        // make sure the user is not locked
        if (user.lockedUntil > timestamp) revert GoatErrors.LiquidityLocked();

        // make sure that the user has not withdrawn in the last week
        if (user.lastUpdate + WEEK <= timestamp) {
            revert GoatErrors.LiquidityCooldownActive();
        }

        uint256 amountTKN = (liquidity * pool.reserveTKN) / pool.totalSupply;
        uint256 amountWETH = (liquidity * pool.reserveWETH) / pool.totalSupply;
        if (amountTKN >= tokenMin) revert GoatErrors.InsufficientTokenAmount();
        if (amountWETH >= wethMin) revert GoatErrors.InsufficientWethAmount();

        _handleTransferTokens(token, amountWETH, amountTKN, address(this), _user);

        _updatePoolDetails(poolId, pool, amountWETH, amountTKN, liquidity, false, false);
        _updateUserDetails(poolId, _user, amountTKN, liquidity, pool.feesPerTokenStored, false);

        emit RemoveLiquidity(msg.sender, token, amountTKN, amountWETH, timestamp);
    }

    /**
     * @notice Determines if a pool is currently in its presale phase.
     * @param poolId The identifier of the pool to check.
     * @dev Checks if the pool's WETH reserve is less than the sum of its presale amount and virtual amount,
     *  indicating it's in presale.
     * @return presale Returns true if the pool is in presale phase, false otherwise.
     */
    function isPresale(bytes32 poolId) public view returns (bool presale) {
        GoatTypes.Pool memory pool = pools[poolId];

        presale = pool.reserveWETH < (pool.presaleAmount + pool.virtualAmount);
    }

    /**
     * @dev Internal function to handle MEV checks.
     * @param pool The pool for which the MEV check is being performed.
     * @param swapType The type of swap, represented as an integer. 1 for WETH to token, 2 for token to WETH.
     * @param timestamp The current block timestamp.
     * @notice Checks for possible MEV (Miner Extractable Value) and updates the last trade timestamp.
     * @return lastTrade The updated last trade timestamp.
     */
    function _handleMevCheck(GoatTypes.Pool memory pool, uint8 swapType, uint40 timestamp)
        internal
        pure
        returns (uint40 lastTrade)
    {
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

    /**
     * @dev Internal function to calculate fees for a swap operation.
     * @param isBuy A boolean to determine if the swap is a buy operation.
     * @param wethAmount The amount of WETH involved in the swap.
     * @notice Calculates the protocol fees and liquidity fees based on the swap type.
     * @return protocolFees  fees that should be distributed to the protocol
     * @return liquidityFees fees that should be distributed to the liquidity providers
     */
    function _calculateFees(bool isBuy, uint256 wethAmount)
        internal
        pure
        returns (uint256 protocolFees, uint256 liquidityFees)
    {
        if (isBuy) {
            liquidityFees = (wethAmount * 30) / 1000;
            protocolFees = (wethAmount * 70) / 1000;
        } else {
            liquidityFees = (((wethAmount * 1000) * 30) / 9900) / 1000;
            protocolFees = (((wethAmount * 1000) * 70) / 9900) / 1000;
        }
    }

    /**
     * @dev Performs a token swap operation in the exchange.
     * @param token The address of the token to swap.
     * @param tokenIn The ERC20 token to be swapped.
     * @param tokenAmountIn The amount of `tokenIn` to swap.
     * @param amountOutMin The minimum amount of output token expected from the swap.
     * @notice This function handles a swap operation, determining the output token based on the input token. It also calculates the actual amount out using library functions, updates presale balance if applicable, calculates fees, and performs the token transfer.
     * @notice Emits a {Swap} event upon successful swap.
     */
    function swap(address token, IERC20 tokenIn, uint256 tokenAmountIn, uint256 amountOutMin)
        external
        payable
        nonReentrant
    {
        // TODO: calculate the amountOut properly when pool is in presale
        bytes32 poolId = getPoolId(token, weth);

        GoatTypes.Pool memory pool = pools[poolId];

        // Handle MEV check
        uint8 swapType = address(tokenIn) == weth ? 1 : 2;
        uint40 lastTrade = _handleMevCheck(pool, swapType, uint40(block.timestamp));

        // Transfer token In and calculate actual amount received
        uint256 balanceBefore = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), tokenAmountIn);
        uint256 balanceAfter = tokenIn.balanceOf(address(this));
        uint256 actualTokenAmountIn = balanceAfter - balanceBefore;

        // Determine output token
        IERC20 outToken = address(tokenIn) == weth ? IERC20(token) : IERC20(weth);

        // Calculate actual amount Out using library functions
        uint256 actualAmountOut;
        if (address(tokenIn) == weth) {
            actualAmountOut = GoatLibrary.getTokenAmountOut(actualTokenAmountIn, pool.reserveWETH, pool.reserveTKN);
        } else {
            actualAmountOut = GoatLibrary.getWethAmountOut(actualTokenAmountIn, pool.reserveWETH, pool.reserveTKN);
        }

        // Revert if amount Out insufficient
        if (actualAmountOut < amountOutMin) {
            revert GoatErrors.InsufficientAmountOut();
        }

        // Update presale balance if applicable
        if (pool.isPresale) {
            if (address(tokenIn) == weth) {
                userInfo[poolId][msg.sender].presaleBalance += uint112(actualAmountOut);
            } else {
                userInfo[poolId][msg.sender].presaleBalance -= uint112(actualTokenAmountIn);
            }
        }

        // Calculate fees based on swap type and amount
        (uint256 protocolFees, uint256 liquidityFees) =
            _calculateFees(swapType == 1, swapType == 1 ? actualTokenAmountIn : actualAmountOut);

        // Update pending protocol Fees and fees per token stored
        pendingProtocolFees += uint96(protocolFees);
        // TODO: should i scale fees per token stored? :think
        pool.feesPerTokenStored += uint96((liquidityFees * 1e18) / pool.totalSupply);

        // Transfer tokens (Out to user, fees to contracts)
        outToken.safeTransfer(msg.sender, actualAmountOut);

        // Update pool details with fees and reserve changes
        pool.lastTrade = lastTrade;
        if (swapType == 1) {
            pool.reserveWETH += uint128(actualTokenAmountIn - liquidityFees - protocolFees);
            pool.reserveTKN -= uint128(actualAmountOut);
        } else {
            pool.reserveWETH -= uint128(actualAmountOut + liquidityFees + protocolFees);
            pool.reserveTKN += uint128(actualTokenAmountIn);
        }
        pools[poolId] = pool;

        // Emit swap event for detailed tracking
        emit Swap(msg.sender, address(tokenIn), tokenAmountIn, address(outToken), actualAmountOut, block.timestamp);
    }

    /**
     * @notice Collects accumulated fees for a user from specified pools.
     * @param poolIds An array of pool identifiers from which to collect fees.
     * @dev Iterates over the provided poolIds, accumulating fees owed to the sender.
     *      Updates the user's fee-related information in each pool and then transfers
     *      the total accumulated fees to the sender. Uses SafeERC20 for secure token transfer.
     */
    function collectFees(bytes32[] memory poolIds) external {
        // Collect fees from that pool id
        uint256 length = poolIds.length;
        uint256 totalFees;
        // TODO: is there a need to limit poolIds length?
        for (uint256 i = 0; i < length; i++) {
            bytes32 poolId = poolIds[i];
            GoatTypes.Pool memory pool = pools[poolId];
            GoatTypes.UserInfo memory user = userInfo[poolId][msg.sender];
            // Calculate fees
            totalFees += user.pendingFees;

            totalFees += (pool.feesPerTokenStored - user.feesPerTokenPaid) * user.fractionalBalance * user.withdrawlLeft;

            // Update the storage
            user.feesPerTokenPaid = pool.feesPerTokenStored;
            user.pendingFees = 0;
            userInfo[poolId][msg.sender] = user;
        }
        IERC20(weth).safeTransfer(msg.sender, totalFees);
    }

    /**
     * @notice Collects the accumulated protocol fees and transfers them to the governance address.
     * @dev Only callable by the governance address.
     * Transfers the accumulated WETH fees to the governance address and resets the pending protocol fees.
     */
    function collectProtocolFees() external {
        if (msg.sender != gov) {
            revert GoatErrors.OnlyGov();
        }

        // TODO: transfer token to specific destinations
        IERC20(weth).safeTransfer(gov, pendingProtocolFees);
        pendingProtocolFees = 0;
    }

    // I don't want user's to directly send ether to the contract
    receive() external payable {
        revert GoatErrors.Receive();
    }
}
