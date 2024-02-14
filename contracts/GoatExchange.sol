// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
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
    uint32 internal constant MAX_UINT32 = type(uint32).max;

    address public immutable weth;
    address public immutable goat;
    address public devTreasury;
    uint256 public pendingProtocolFees;

    mapping(bytes32 => GoatTypes.Pool) public pools;
    mapping(bytes32 => mapping(address => GoatTypes.UserInfo)) public userInfo;
    // poolId => liquidity provider => reward to be paid
    mapping(bytes32 => mapping(address => uint256)) public rewards;

    constructor(address _weth, address _goat, address _devTreasury) {
        weth = _weth;
        goat = _goat;
        devTreasury = _devTreasury;
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
    // TODO: should we care about to argument?
    function addLiquidity(
        address token,
        uint256 tokenDesired,
        uint256 wethDesired,
        uint256 tokenMin,
        uint256 wethMin,
        uint32 lockUntil,
        GoatTypes.LaunchParams memory launchParams
    ) external nonReentrant {
        // TODO: Do I need to check launch params for initial weth and virtual amount?

        if (token == address(0)) revert GoatErrors.ZeroAddress();

        (bytes32 poolId, bool newPool) = _ensurePoolExists(weth, token);

        GoatTypes.Pool memory pool = pools[poolId];

        if (pool.vestingUntil == MAX_UINT32) revert GoatErrors.PresalePeriod();

        if (newPool) {
            // TODO: Make sure reserveBase is updated if launch team wants to add
            // Some amount of eth
            pool.virtualEth = launchParams.virtualBase;
            pool.bootstrapEth = launchParams.bootstrapBase;
            pool.vestingUntil = MAX_UINT32;

            if (launchParams.bootstrapBase <= launchParams.initialBase) {
                pool.vestingUntil = uint32(block.timestamp);
            }
        }

        // calculate amount's of tokens to transfer
        (uint256 amountWETH, uint256 amountTKN) = _getAmountsIn(pool, wethDesired, tokenDesired, wethMin, tokenMin);
        // Handle transfer tokens
        {
            uint256 tokenBalBefore = IERC20(token).balanceOf(address(this));
            _handleTransferTokens(
                token, newPool ? launchParams.initialBase : amountWETH, amountTKN, msg.sender, address(this)
            );
            uint256 tokenBalAfter = IERC20(token).balanceOf(address(this));
            // Check for tokens with fee on transfer
            if (tokenBalAfter - tokenBalBefore >= amountTKN) {
                revert GoatErrors.IncorrectTokenAmount();
            }

            // TODO: check if amount weth is handled properly if this is the first liquidity
            uint256 liquidity = _handleMintLiquidity(poolId, pool, amountWETH, amountTKN, lockUntil, msg.sender);
            uint256 fractionalLiquidity = liquidity / 4;
            _updatePoolDetails(
                poolId,
                pool,
                newPool ? launchParams.initialBase : amountWETH,
                amountTKN,
                fractionalLiquidity,
                false,
                true
            );
            _updateUserDetails(poolId, msg.sender, 0, fractionalLiquidity, pool.feesPerTokenStored, true);
        }

        // TODO: is there a need to emit liquidity amount too?
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
            (wethOptimal * pool.totalSupply) / pool.reserveBase, (tokenOptimal * pool.totalSupply) / pool.reserveToken
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
        // TODO: don't update here? :think return user and update using _updateUser
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
        _userInfo.pendingFees += uint104(
            (feesPerTokenPaid - _userInfo.feesPerTokenPaid) * _userInfo.fractionalBalance * _userInfo.withdrawlLeft
        );

        _userInfo.feesPerTokenPaid = uint112(feesPerTokenPaid);

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
        // TODO: update fees collected?
        if (liquidity != 0) {
            if (isAdd) {
                pool.totalSupply += uint112(liquidity);
                pool.reserveBase += uint112(amountWETH);
                pool.reserveToken += uint112(amountTKN);
            } else {
                pool.totalSupply -= uint112(liquidity);
                pool.reserveBase -= uint112(amountWETH);
                pool.reserveToken -= uint112(amountTKN);
            }
        } else if (isBuy) {
            pool.reserveBase += uint112(amountWETH);
            pool.reserveToken -= uint112(amountTKN);
        } else {
            pool.reserveBase -= uint112(amountWETH);
            pool.reserveToken += uint112(amountTKN);
        }
        // TODO: update kLast here

        pools[poolId] = pool;
    }

    function _getAmountsIn(
        GoatTypes.Pool memory pool,
        uint256 wethDesired,
        uint256 tokenDesired,
        uint256 wethMin,
        uint256 tokenMin
    ) internal pure returns (uint256 amountWETH, uint256 amountTKN) {
        if (pool.reserveBase == 0 && pool.reserveToken == 0) {
            (amountWETH, amountTKN) = (wethDesired, tokenDesired);
        } else {
            uint256 amountTKNOptimal = GoatLibrary.quote(wethDesired, pool.reserveBase, pool.reserveToken);
            if (amountTKNOptimal <= tokenDesired) {
                if (amountTKNOptimal >= tokenMin) {
                    revert GoatErrors.InsufficientTokenAmount();
                }
                (amountWETH, amountTKN) = (wethDesired, amountTKNOptimal);
            } else {
                uint256 amountWETHOptimal = GoatLibrary.quote(tokenDesired, pool.reserveToken, pool.reserveBase);
                assert(amountWETHOptimal <= wethDesired);
                if (amountWETHOptimal >= wethMin) {
                    revert GoatErrors.InsufficientWethAmount();
                }

                (amountWETH, amountTKN) = (amountWETHOptimal, tokenDesired);
            }
        }
    }

    function _getAmountsOut(GoatTypes.Pool memory pool, uint256 liquidity, uint256 tokenMin, uint256 wethMin)
        internal
        pure
        returns (uint256 amountWETH, uint256 amountTKN)
    {
        // TODO: handle a scenario where team wants to remove tokens
        // when there is not enough trades to turn presale to an AMM

        amountWETH = (pool.reserveBase * liquidity) / pool.totalSupply;
        amountTKN = (pool.reserveToken * liquidity) / pool.totalSupply;

        if (amountTKN < tokenMin) revert GoatErrors.InsufficientTokenAmount();
        if (amountWETH < wethMin) revert GoatErrors.InsufficientWethAmount();
    }

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

        (uint256 amountWETH, uint256 amountTKN) = _getAmountsOut(pool, liquidity, tokenMin, wethMin);

        _handleTransferTokens(token, amountWETH, amountTKN, address(this), _user);

        _updatePoolDetails(poolId, pool, amountWETH, amountTKN, liquidity, false, false);
        _updateUserDetails(poolId, _user, amountTKN, liquidity, pool.feesPerTokenStored, false);

        // TODO: is there a need to emit liquidity amount too?
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

        presale = pool.reserveBase < (pool.bootstrapEth);
    }

    /**
     * @dev Internal function to handle MEV checks.
     * @param pool The pool for which the MEV check is being performed.
     * @param swapType The type of swap, represented as an integer. 1 for WETH to token, 2 for token to WETH.
     * @param timestamp The current block timestamp.
     * @notice Checks for possible MEV (Miner Extractable Value) and updates the last trade timestamp.
     * @return lastTrade The updated last trade timestamp.
     */
    function _handleMevCheck(GoatTypes.Pool memory pool, uint8 swapType, uint32 timestamp)
        internal
        pure
        returns (uint32 lastTrade)
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
    function swap(address token, IERC20 tokenIn, uint256 tokenAmountIn, uint256 amountOutMin) external nonReentrant {
        // TODO: calculate the amountOut properly when pool is in presale
        // TODO: update the total fees earned and may be total fees distributed

        bytes32 poolId = getPoolId(token, weth);

        GoatTypes.Pool memory pool = pools[poolId];

        // Handle MEV check
        uint8 swapType = address(tokenIn) == weth ? 1 : 2;
        uint32 lastTrade = _handleMevCheck(pool, swapType, uint32(block.timestamp));

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
            actualAmountOut = GoatLibrary.getTokenAmountOut(actualTokenAmountIn, pool);
        } else {
            actualAmountOut = GoatLibrary.getWethAmountOut(actualTokenAmountIn, pool);
        }

        // Revert if amount Out insufficient
        if (actualAmountOut < amountOutMin) {
            revert GoatErrors.InsufficientAmountOut();
        }

        // Update presale balance if applicable vesting is applicable even if pool turns to an AMM
        if (pool.vestingUntil == MAX_UINT32 || (pool.vestingUntil + WEEK > block.timestamp)) {
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
        pendingProtocolFees += protocolFees;
        // TODO: should i scale fees per token stored? :think
        pool.feesPerTokenStored += uint112((liquidityFees * 1e18) / pool.totalSupply);

        // Transfer tokens (Out to user, fees to contracts)
        outToken.safeTransfer(msg.sender, actualAmountOut);

        // Update pool details with fees and reserve changes
        pool.lastTrade = lastTrade;
        if (swapType == 1) {
            pool.reserveBase += uint112(actualTokenAmountIn - liquidityFees - protocolFees);
            pool.reserveToken -= uint112(actualAmountOut);
        } else {
            pool.reserveBase -= uint112(actualAmountOut + liquidityFees + protocolFees);
            pool.reserveToken += uint112(actualTokenAmountIn);
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

    function buybackGoat() external {
        uint256 _pendingProtocolFees = pendingProtocolFees;
        // buyback share is 40 bps of total 60 bps protocol fees
        uint256 buyBackShare = _pendingProtocolFees * 40 / 60;
        // dev fees is 20 bps of total 60 bps protocol fees
        uint256 devFees = _pendingProtocolFees - buyBackShare;

        (bool sent,) = devTreasury.call{value: devFees}("");
        if (!sent) revert GoatErrors.FailedToSendEther();
        bytes32 poolId = getPoolId(goat, weth);
        GoatTypes.Pool memory pool = pools[poolId];
        if (!pool.exists) revert GoatErrors.GoatPoolDoesNotExist();

        uint256 amountExpected = GoatLibrary.getTokenAmountOut(buyBackShare, pool);
        (uint256 protocolFees, uint256 liquidityFees) = _calculateFees(true, amountExpected);

        // pending fees at this point should be fees this trade has produced
        pendingProtocolFees = protocolFees;
        pool.feesPerTokenStored += uint112((liquidityFees * 1e18) / pool.totalSupply);

        pool.reserveBase += uint112(buyBackShare - (protocolFees + liquidityFees));
        pool.reserveToken -= uint112(amountExpected);

        // Burn goat token
        IERC20(goat).safeTransfer(address(0), amountExpected);

        // Update the pool detais
        pools[poolId] = pool;
    }

    /**
     * @dev Sets a new developer treasury address.
     * Requirements:
     * - The caller must be the current `devTreasury`.
     * - `newDevTreasury` cannot be the zero address.
     *
     * @param newDevTreasury The address to be set as the new developer treasury.
     */
    function setDevTreasury(address newDevTreasury) external {
        if (msg.sender != devTreasury) revert GoatErrors.Unauthorized();
        if (newDevTreasury == address(0)) revert GoatErrors.ZeroAddress();

        devTreasury = newDevTreasury;
    }
    // VIEW FUNCTIONS

    function getActualTokenForLiquidityBootstrap(uint256 virtualEth, uint256 bootstrapEth, uint256 initialTokenMatch)
        public
        view
        returns (uint256 tokenAmt)
    {
        // @note I have not handled precision loss here. We need to test this function so that
        // the pool is never under funded by actual Y amount
        uint256 k = virtualEth * initialTokenMatch;
        uint256 tokenAmountForPresale = initialTokenMatch - (k / (virtualEth + bootstrapEth));
        uint256 tokenAmountForAmm = ((k / (virtualEth + bootstrapEth)) / (virtualEth + bootstrapEth)) * bootstrapEth;
        tokenAmt = tokenAmountForPresale + tokenAmountForAmm;
    }

    // I don't want user's to directly send ether to the contract
    receive() external payable {
        revert GoatErrors.Receive();
    }
}
