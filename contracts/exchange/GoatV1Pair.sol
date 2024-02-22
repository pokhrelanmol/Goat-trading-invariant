// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// library imports
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// local imports
import "../library/GoatErrors.sol";
import "../library/GoatTypes.sol";
import "./GoatV1ERC20.sol";

// interfaces
import "../interfaces/IGoatV1Factory.sol";

// TODO: remove this later
import {console2} from "forge-std/Test.sol";

contract GoatV1Pair is GoatV1ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint32 private constant _MIN_LOCK_PERIOD = 2 days;
    uint32 public constant VESTING_PERIOD = 30 days;
    uint32 private constant _MAX_UINT32 = type(uint32).max;
    uint32 private constant _THIRTY_DAYS = 30 days;

    address public immutable factory;
    uint32 private immutable _genesis;
    // Figure out a way to use excess 12 bytes in here to store something
    address private _token;
    address private _weth;

    uint112 private _virtualEth;
    uint112 private _initialTokenMatch;
    uint32 private _vestingUntil;

    uint112 private _reserveEth;
    uint112 private _reserveToken;
    uint32 private _lastTrade;

    // No need to save it can be used first time to calculate k last
    // and reverse engineer to get actual token match

    uint112 private _bootstrapEth;
    // total lp fees that are not withdrwan
    uint112 private _pendingLiquidityFees;

    // Scaled fees per token stored by 1e18
    uint184 public feesPerTokenStored;
    // this variable can store >4500 ether
    uint72 private _pendingProtocolFees;

    mapping(address => uint256) private _presaleBalances;
    mapping(address => uint32) private _locked;
    mapping(address => uint256) public lpFees;
    mapping(address => uint256) public feesPerTokenPaid;

    GoatTypes.InitialLPInfo private _initialLPInfo;

    event Mint(address, uint256, uint256);
    event Burn(address, uint256, uint256, address);

    constructor() {
        factory = msg.sender;
        _genesis = uint32(block.timestamp);
    }

    function initialize(address token, address weth, string memory baseName, GoatTypes.InitParams memory params)
        external
    {
        if (msg.sender != factory) revert GoatErrors.GoatV1Forbidden();
        _token = token;
        _weth = weth;
        // setting non zero value so that swap will not incur new storage write on update
        _vestingUntil = _MAX_UINT32;
        // Is there a token without a name that may result in revert in this case?
        string memory tokenName = IERC20Metadata(_token).name();
        name = string(abi.encodePacked("GoatTradingV1: ", baseName, "/", tokenName));
        symbol = string(abi.encodePacked("GoatV1-", baseName, "-", tokenName));
        _initialTokenMatch = params.initialTokenMatch;
        _virtualEth = params.virtualEth;
        _bootstrapEth = params.bootstrapEth;
    }

    function _update(uint256 balanceEth, uint256 balanceToken) internal {
        // Update token reserves and other necessary data
        _reserveEth = uint112(balanceEth - (_pendingLiquidityFees + _pendingProtocolFees));
        _reserveToken = uint112(balanceToken);
    }

    function _handleFees(uint256 amountWethIn, uint256 amountWethOut) internal returns (uint256 feesCollected) {
        // here either amountWethIn or amountWethOut will be zero

        // fees collected will be 100 bps of the weth amount
        if (amountWethIn != 0) {
            feesCollected = (amountWethIn * 100) / 10000;
        } else {
            feesCollected = (amountWethOut * 10000) / 9900 - amountWethOut;
        }
        // lp fess is fixed 40% of the fees collected of total 100 bps
        uint256 feesLp = (feesCollected * 40) / 100;

        uint256 pendingProtocolFees = _pendingProtocolFees;

        unchecked {
            _pendingLiquidityFees += uint112(feesLp);
            pendingProtocolFees += uint184(feesCollected - feesLp);
            // update fees per token stored
            feesPerTokenStored += uint168((feesLp * 1e18) / totalSupply());
        }

        IGoatV1Factory _factory = IGoatV1Factory(factory);
        uint256 minCollectableFees = _factory.minimumCollectableFees();
        address treasury = _factory.treasury();

        if (pendingProtocolFees > minCollectableFees) {
            pendingProtocolFees = 0;
            IERC20(_weth).safeTransfer(treasury, pendingProtocolFees);
        }
        _pendingProtocolFees = uint72(pendingProtocolFees);
    }

    function _handleMevCheck(bool isBuy) internal returns (uint32 lastTrade) {
        uint8 swapType = isBuy ? 1 : 2;
        uint32 timestamp = uint32(block.timestamp);
        lastTrade = _lastTrade;
        if (lastTrade < timestamp) {
            lastTrade = timestamp;
        } else if (lastTrade == timestamp && swapType == 1) {
            lastTrade = timestamp + swapType;
        } else if (_lastTrade == timestamp && swapType == 2) {
            lastTrade = timestamp + swapType;
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
        // update last trade
        _lastTrade = lastTrade;
    }

    function _updatePresale(address user, uint256 amount, bool isBuy) internal {
        //
        if (isBuy) {
            unchecked {
                _presaleBalances[user] += amount;
            }
        } else {
            _presaleBalances[user] -= amount;
        }
    }

    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        uint256 totalSupply_ = totalSupply();
        uint256 amountWeth;
        uint256 amountToken;
        uint256 balanceEth = IERC20(_weth).balanceOf(address(this));
        uint256 balanceToken = IERC20(_token).balanceOf(address(this));

        GoatTypes.LocalVariables_MintLiquidity memory mintVars;

        mintVars.virtualEth = _virtualEth;
        mintVars.initialTokenMatch = _initialTokenMatch;
        mintVars.bootstrapEth = _bootstrapEth;

        if (_vestingUntil == _MAX_UINT32) {
            // Do not allow to add liquidity in presale period
            if (totalSupply_ > 0) revert GoatErrors.PresalePeriod();
            // don't allow to send more eth than bootstrap eth
            if (balanceEth > _bootstrapEth) {
                revert GoatErrors.SupplyMoreThanBootstrapEth();
            }

            // @note make sure balance token is equal to expected token amount
            (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm) = _tokenAmountsForLiquidityBootstrap(
                mintVars.virtualEth, mintVars.bootstrapEth, balanceEth, mintVars.initialTokenMatch
            );
            if (balanceToken < (tokenAmtForPresale + tokenAmtForAmm)) {
                revert GoatErrors.InsufficientTokenAmount();
            }

            if (balanceEth < mintVars.bootstrapEth) {
                liquidity =
                    Math.sqrt(uint256(mintVars.virtualEth) * uint256(mintVars.initialTokenMatch)) - MINIMUM_LIQUIDITY;
            } else {
                // This means that user is willing to make this pool an amm pool in first liquidity mint
                liquidity = Math.sqrt(balanceEth * tokenAmtForAmm) - MINIMUM_LIQUIDITY;
                uint32 timestamp = uint32(block.timestamp);
                _vestingUntil = timestamp;
            }
            mintVars.isFirstMint = true;
        } else {
            (uint256 reserveEth, uint256 reserveToken) = getReserves();
            amountWeth = balanceEth - reserveEth - _pendingLiquidityFees - _pendingProtocolFees;
            amountToken = balanceToken - reserveToken;
            liquidity = Math.min((amountWeth * totalSupply_) / reserveEth, (amountToken * totalSupply_) / reserveToken);
        }

        if (mintVars.isFirstMint || to == _initialLPInfo.liquidityProvider) {
            _updateInitialLpInfo(liquidity, to, false);
        }

        _updateFeeRewards(to);
        if (totalSupply_ == 0) {
            _mint(address(0), MINIMUM_LIQUIDITY);
        }

        _locked[to] = uint32(block.timestamp + _MIN_LOCK_PERIOD);
        _mint(to, liquidity);

        _update(balanceEth, balanceToken);

        emit Mint(msg.sender, amountWeth, amountToken);
    }

    function _handleInitialLiquidityProviderChecks(uint256 liquidity) internal view {
        // this check is only needed here because lp's won't be able to add
        // liquidity until the pool turns to an AMM
        if (_vestingUntil == _MAX_UINT32) revert GoatErrors.PresalePeriod();

        // check for actual lp constraints
        GoatTypes.InitialLPInfo memory info = _initialLPInfo;
        uint256 timestamp = block.timestamp;

        if ((timestamp - 1 weeks) < info.lastWithdraw) {
            revert GoatErrors.WithdrawalCooldownActive();
        }

        if (liquidity > info.fractionalBalance) {
            revert GoatErrors.BurnLimitExceeded();
        }
    }

    function _updateInitialLpInfo(uint256 liquidity, address lp, bool isBurn) internal {
        GoatTypes.InitialLPInfo memory info = _initialLPInfo;
        if (isBurn) {
            if (lp == info.liquidityProvider) {
                info.lastWithdraw = uint32(block.timestamp);
                info.withdrawlLeft -= 1;
            }
        } else {
            info.fractionalBalance = uint112(((info.fractionalBalance * info.withdrawlLeft) + liquidity) / 4);
            info.withdrawlLeft = 4;
            info.liquidityProvider = lp;
        }
        // Update initial liquidity provider info
        _initialLPInfo = info;
    }

    function burn(address from) external returns (uint256 amountWeth, uint256 amountToken) {
        // Burn liquidity tokens
        if (_locked[from] > block.timestamp) {
            revert GoatErrors.LiquidityLocked();
        }

        uint256 liquidity = balanceOf(address(this));
        if (from == _initialLPInfo.liquidityProvider) {
            _handleInitialLiquidityProviderChecks(liquidity);
            _updateInitialLpInfo(liquidity, from, true);
        }

        uint256 balanceEth = IERC20(_weth).balanceOf(address(this));
        uint256 balanceToken = IERC20(_token).balanceOf(address(this));

        uint256 totalSupply_ = totalSupply();
        amountWeth = (liquidity * balanceEth) / totalSupply_;
        amountToken = (liquidity * balanceToken) / totalSupply_;
        if (amountWeth == 0 || amountToken == 0) {
            revert GoatErrors.InsufficientLiquidityBurned();
        }

        _updateFeeRewards(from);
        _burn(address(this), liquidity);

        // Transfer liquidity tokens to the user
        IERC20(_weth).safeTransfer(from, amountWeth);
        IERC20(_token).safeTransfer(from, amountToken);
        balanceEth = IERC20(_weth).balanceOf(address(this));
        balanceToken = IERC20(_token).balanceOf(address(this));

        _update(balanceEth, balanceToken);

        emit Burn(msg.sender, amountWeth, amountToken, from);
    }

    // should be called from a contract with safety checks
    function swap(uint256 amountTokenOut, uint256 amountWethOut, address to) external {
        if (amountTokenOut == 0 && amountWethOut == 0) {
            revert GoatErrors.InsufficientOutputAmount();
        }
        if (amountTokenOut != 0 && amountWethOut != 0) {
            revert GoatErrors.MultipleOutputAmounts();
        }
        GoatTypes.LocalVariables_Swap memory swapVars;
        swapVars.isBuy = amountWethOut > 0 ? false : true;
        // check for mev
        _handleMevCheck(swapVars.isBuy);

        (swapVars.actualReserveEth, swapVars.actualReserveToken) = _getActualReserves();

        if (amountTokenOut > swapVars.actualReserveToken || amountWethOut > swapVars.actualReserveEth) {
            revert GoatErrors.InsufficientAmountOut();
        }

        if (swapVars.isBuy) {
            swapVars.amountWethIn = IERC20(_weth).balanceOf(address(this)) - swapVars.actualReserveEth
                - _pendingLiquidityFees - _pendingProtocolFees;
            // optimistically send tokens out
            IERC20(_token).safeTransfer(to, amountTokenOut);
        } else {
            swapVars.amountTokenIn = IERC20(_token).balanceOf(address(this)) - swapVars.actualReserveToken;
            // optimistically send weth out
            IERC20(_weth).safeTransfer(to, amountWethOut);
        }
        swapVars.feesCollected = _handleFees(swapVars.amountWethIn, amountWethOut);

        swapVars.tokenAmount = swapVars.isBuy ? amountTokenOut : swapVars.amountTokenIn;
        swapVars.vestingUntil = _vestingUntil;

        // We store details of participants so that we only allow users who have
        // swap back tokens who have bought in the vesting period.
        if (swapVars.vestingUntil > block.timestamp - _THIRTY_DAYS) {
            _updatePresale(to, swapVars.tokenAmount, swapVars.isBuy);
        }

        if (swapVars.isBuy) {
            swapVars.amountWethIn -= swapVars.feesCollected;
        } else {
            unchecked {
                amountWethOut += swapVars.feesCollected;
            }
        }
        swapVars.finalReserveEth = swapVars.isBuy
            ? swapVars.actualReserveEth + swapVars.amountWethIn
            : swapVars.actualReserveEth - amountWethOut;
        swapVars.finalReserveToken = swapVars.isBuy
            ? swapVars.actualReserveToken - amountTokenOut
            : swapVars.actualReserveToken + swapVars.amountTokenIn;

        swapVars.bootstrapEth = _bootstrapEth;
        if (swapVars.vestingUntil == _MAX_UINT32 && swapVars.finalReserveEth >= swapVars.bootstrapEth) {
            // at this point pool should be changed to an AMM
            _checkAndConvertPool(swapVars.finalReserveEth, swapVars.finalReserveEth);
        } else {
            // check for K
            swapVars.initialTokenMatch = _initialTokenMatch;
            swapVars.virtualEth = _virtualEth;

            (swapVars.virtualEthReserveBefore, swapVars.virtualTokenReserveBefore) = _getReserves(
                swapVars.vestingUntil,
                swapVars.actualReserveEth,
                swapVars.actualReserveToken,
                swapVars.virtualEth,
                swapVars.initialTokenMatch
            );
            (swapVars.virtualEthReserveAfter, swapVars.virtualTokenReserveAfter) = _getReserves(
                swapVars.vestingUntil,
                swapVars.finalReserveEth,
                swapVars.finalReserveToken,
                swapVars.virtualEth,
                swapVars.initialTokenMatch
            );
            if (
                swapVars.virtualEthReserveBefore * swapVars.virtualTokenReserveBefore
                    < swapVars.virtualEthReserveAfter * swapVars.virtualTokenReserveAfter
            ) {
                revert GoatErrors.KInvariant();
            }
        }
        _update(swapVars.actualReserveEth, swapVars.actualReserveToken);
    }

    function _getActualReserves() internal view returns (uint112 reserveEth, uint112 reserveToken) {
        reserveEth = _reserveEth;
        reserveToken = _reserveToken;
    }

    function _getReserves(
        uint32 vestingUntil_,
        uint256 ethReserve,
        uint256 tokenReserve,
        uint256 virtualEth,
        uint256 initialTokenMatch
    ) internal pure returns (uint112 reserveEth, uint112 reserveToken) {
        if (vestingUntil_ != _MAX_UINT32) {
            reserveEth = uint112(ethReserve);
            reserveToken = uint112(tokenReserve);
        } else {
            reserveEth = uint112(virtualEth + ethReserve);
            reserveToken = uint112((virtualEth * initialTokenMatch) / reserveEth);
        }
    }

    /// @notice returns actual reserves if pool has turned into an AMM else returns virtual reserves
    function getReserves() public view returns (uint112 reserveEth, uint112 reserveToken) {
        (reserveEth, reserveToken) =
            _getReserves(_vestingUntil, _reserveEth, _reserveToken, _virtualEth, _initialTokenMatch);
    }

    // this function converts the pool to an AMM with less liquidity and removes
    // the excess token from the pool
    function withdrawExcessToken() external {
        uint256 timestamp = block.timestamp;
        // initial liquidty provider can call this function after 30 days from genesis
        if (_genesis + _THIRTY_DAYS > timestamp) revert GoatErrors.PresaleDeadlineActive();
        if (_vestingUntil != _MAX_UINT32) {
            revert GoatErrors.ActionNotAllowed();
        }

        address initialLiquidityProvider = _initialLPInfo.liquidityProvider;
        if (msg.sender != initialLiquidityProvider) {
            revert GoatErrors.Unauthorized();
        }

        // as bootstrap eth is not met we consider reserve eth as bootstrap eth
        // and turn presale into an amm with less liquidity.
        uint256 reserveEth = _reserveEth;
        uint256 bootstrapEth = reserveEth;

        // if we know token amount for AMM we can remove excess tokens that are staying in this contract
        (, uint256 tokenAmtForAmm) =
            _tokenAmountsForLiquidityBootstrap(_virtualEth, bootstrapEth, reserveEth, _initialTokenMatch);

        IERC20 token = IERC20(_token);
        uint256 poolTokenBalance = token.balanceOf(address(this));

        uint256 amountToTransferBack = poolTokenBalance - tokenAmtForAmm;

        _burnLiquidityAndConvertToAmm(reserveEth, tokenAmtForAmm);

        // transfer excess token to the initial liquidity provider
        token.safeTransfer(initialLiquidityProvider, amountToTransferBack);

        // update bootstrap eth because original bootstrap eth was not met and
        // eth we raised until this point should be considered as bootstrap eth
        _bootstrapEth = uint112(bootstrapEth);

        _update(_reserveEth, tokenAmtForAmm);
    }

    function _burnLiquidityAndConvertToAmm(uint256 actualEthReserve, uint256 actualTokenReserve) internal {
        address initialLiquidityProvider = _initialLPInfo.liquidityProvider;

        uint256 initialLPBalance = balanceOf(initialLiquidityProvider);

        uint256 liquidity = Math.sqrt(actualTokenReserve * actualEthReserve);

        uint256 liquidityToBurn = initialLPBalance - liquidity;

        _updateInitialLpInfo(liquidityToBurn, initialLiquidityProvider, true);
        // @note can I read balanceOf just once? :thinking_face
        _updateFeeRewards(initialLiquidityProvider);
        _burn(initialLiquidityProvider, liquidityToBurn);
        _vestingUntil = uint32(block.timestamp);
    }

    function _checkAndConvertPool(uint256 actualReserveEth, uint256 actualReserveToken) internal {
        uint256 tokenAmtForAmm;
        uint256 kForAmm;
        if (actualReserveEth >= _bootstrapEth) {
            (, tokenAmtForAmm) = _tokenAmountsForLiquidityBootstrap(_virtualEth, _bootstrapEth, 0, _initialTokenMatch);
            kForAmm = _bootstrapEth * tokenAmtForAmm;
        }
        uint256 actualK = actualReserveEth * actualReserveToken;
        if (actualK < kForAmm) {
            revert GoatErrors.KInvariant();
        }
        _burnLiquidityAndConvertToAmm(actualReserveEth, actualReserveToken);
    }

    function withdrawFees(address to) external {
        uint256 feesCollected = lpFees[to];
        lpFees[to] = 0;
        uint256 feesPerToken = feesPerTokenStored - feesPerTokenPaid[to];

        feesPerTokenPaid[to] = feesPerTokenStored;

        uint256 feesAccured = (balanceOf(to) * feesPerToken) / 1e18;

        uint256 totalFees = feesCollected + feesAccured;

        if (totalFees != 0) {
            IERC20(_weth).safeTransfer(to, totalFees);
        }

        // update pending liquidity fees
        _pendingLiquidityFees -= uint112(totalFees);
        // is there a need to check if weth balance is in sync with reserve and fees?
    }

    function _tokenAmountsForLiquidityBootstrap(
        uint256 virtualEth,
        uint256 bootstrapEth,
        uint256 initialEth,
        uint256 initialTokenMatch
    ) internal pure returns (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm) {
        // @note I have not handled precision loss here. Make sure if I need to round it up by 1.
        uint256 k = virtualEth * initialTokenMatch;
        tokenAmtForPresale = initialTokenMatch - (k / (virtualEth + bootstrapEth));
        tokenAmtForAmm = ((k / (virtualEth + bootstrapEth)) / (virtualEth + bootstrapEth)) * bootstrapEth;

        if (initialEth != 0) {
            uint256 numerator = (initialEth * initialTokenMatch);
            uint256 denominator = virtualEth + initialEth;
            uint256 tokenAmountOut = numerator / denominator;
            if (tokenAmtForPresale > tokenAmountOut) {
                tokenAmtForPresale -= tokenAmountOut;
            } else {
                tokenAmtForPresale = 0;
            }
        }

        // @note use ceil for checking token amount in
        // if (tokenAmtForPresale != 0) {
        //     tokenAmtForPresale += 1;
        // }
        // tokenAmtForAmm += 1;
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal override {
        // handle initial liquidity provider checks
        GoatTypes.InitialLPInfo memory lpInfo = _initialLPInfo;
        // only allow address(this) to recieve lp tokens from initial liquidity
        if ((from == lpInfo.liquidityProvider && to != address(this)) || lpInfo.liquidityProvider == to) {
            revert GoatErrors.LPTransferRestricted();
        }
        if (to != address(this)) {
            _locked[to] = uint32(block.timestamp + _MIN_LOCK_PERIOD);
        }

        _updateFeeRewards(from);
        _updateFeeRewards(to);
    }

    function _updateFeeRewards(address lp) internal {
        // save for multiple reads
        uint256 _feesPerTokenStored = feesPerTokenStored;
        lpFees[lp] = _earned(lp, _feesPerTokenStored);
        feesPerTokenPaid[lp] = _feesPerTokenStored;
    }

    function _earned(address lp, uint256 _feesPerTokenStored) internal view returns (uint256) {
        uint256 feesPerToken = _feesPerTokenStored - feesPerTokenPaid[lp];
        uint256 feesAccured = (balanceOf(lp) * feesPerToken) / 1e18;
        return lpFees[lp] + feesAccured;
    }

    function earned(address lp) external view returns (uint256) {
        return _earned(lp, feesPerTokenStored);
    }

    function vestingUntil() external view returns (uint32 vestingUntil_) {
        vestingUntil_ = _vestingUntil;
        if (vestingUntil_ != _MAX_UINT32) {
            vestingUntil_ += VESTING_PERIOD;
        }
    }

    function getStateInfo()
        external
        view
        returns (
            uint112 reserveEth,
            uint112 reserveToken,
            uint112 virtualEth,
            uint112 initialTokenMatch,
            uint32 vestingUntil_,
            uint32 lastTrade,
            uint256 bootstrapEth,
            uint32 genesis
        )
    {
        reserveEth = _reserveEth;
        reserveToken = _reserveToken;
        virtualEth = _virtualEth;
        initialTokenMatch = _initialTokenMatch;
        vestingUntil_ = _vestingUntil;
        lastTrade = _lastTrade;
        bootstrapEth = _bootstrapEth;
        genesis = _genesis;
    }

    function getInitialLPInfo() external view returns (GoatTypes.InitialLPInfo memory) {
        return _initialLPInfo;
    }

    function getPresaleBalance(address user) external view returns (uint256) {
        return _presaleBalances[user];
    }

    function lockedUntil(address user) external view returns (uint32) {
        return _locked[user];
    }
}
