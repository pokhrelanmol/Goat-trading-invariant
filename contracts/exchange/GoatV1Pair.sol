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
    address private _lastPoolTokenSender;

    uint112 private _virtualEth;
    uint112 private _initialTokenMatch;
    uint32 private _vestingUntil;

    // this is the real amount of eth in the pool
    uint112 private _reserveEth;
    // token reserve in the pool
    uint112 private _reserveToken;
    uint32 private _lastTrade;

    uint112 private _bootstrapEth;
    // total lp fees that are not withdrawn
    uint112 private _pendingLiquidityFees;

    // Scaled fees per token scaled by 1e18
    uint184 public feesPerTokenStored;
    // this variable can store >4500 ether
    uint72 private _pendingProtocolFees;

    mapping(address => uint256) private _presaleBalances;
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

    function _update(uint256 balanceEth, uint256 balanceToken, bool fromSwap) internal {
        // Update token reserves and other necessary data
        if (fromSwap) {
            _reserveEth = uint112(balanceEth);
            _reserveToken = uint112(balanceToken);
        } else {
            _reserveEth = uint112(balanceEth - (_pendingLiquidityFees + _pendingProtocolFees));
            _reserveToken = uint112(balanceToken);
        }
    }

    function _handleFees(uint256 amountWethIn, uint256 amountWethOut, bool isPresale)
        internal
        returns (uint256 feesCollected, uint256 feesLp)
    {
        // here either amountWethIn or amountWethOut will be zero

        // fees collected will be 100 bps of the weth amount
        if (amountWethIn != 0) {
            feesCollected = (amountWethIn * 99) / 10000;
        } else {
            feesCollected = (amountWethOut * 10000) / 9901 - amountWethOut;
        }
        // lp fess is fixed 40% of the fees collected of total 100 bps
        feesLp = (feesCollected * 40) / 100;

        uint256 pendingProtocolFees = _pendingProtocolFees;

        // lp fees only updated if it's not a presale
        if (!isPresale) {
            _pendingLiquidityFees += uint112(feesLp);
            // update fees per token stored
            feesPerTokenStored += uint184((feesLp * 1e18) / totalSupply());
        }

        pendingProtocolFees += feesCollected - feesLp;

        IGoatV1Factory _factory = IGoatV1Factory(factory);
        uint256 minCollectableFees = _factory.minimumCollectableFees();
        address treasury = _factory.treasury();

        if (pendingProtocolFees > minCollectableFees) {
            IERC20(_weth).safeTransfer(treasury, pendingProtocolFees);
            pendingProtocolFees = 0;
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
            if (balanceEth > mintVars.bootstrapEth) {
                revert GoatErrors.SupplyMoreThanBootstrapEth();
            }

            if (balanceEth < mintVars.bootstrapEth) {
                (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm) = _tokenAmountsForLiquidityBootstrap(
                    mintVars.virtualEth, mintVars.bootstrapEth, balanceEth, mintVars.initialTokenMatch
                );
                if (balanceToken != (tokenAmtForPresale + tokenAmtForAmm)) {
                    revert GoatErrors.InsufficientTokenAmount();
                }
                liquidity =
                    Math.sqrt(uint256(mintVars.virtualEth) * uint256(mintVars.initialTokenMatch)) - MINIMUM_LIQUIDITY;
            } else {
                // This means that user is willing to make this pool an amm pool in first liquidity mint
                liquidity = Math.sqrt(balanceEth * balanceToken) - MINIMUM_LIQUIDITY;
                uint32 timestamp = uint32(block.timestamp);
                _vestingUntil = timestamp + VESTING_PERIOD;
            }
            mintVars.isFirstMint = true;
        } else {
            // at this point in time we will get the actual reserves
            (uint256 reserveEth, uint256 reserveToken) = getReserves();
            amountWeth = balanceEth - reserveEth - _pendingLiquidityFees - _pendingProtocolFees;
            amountToken = balanceToken - reserveToken;
            liquidity = Math.min((amountWeth * totalSupply_) / reserveEth, (amountToken * totalSupply_) / reserveToken);
        }

        // @note can this be an attack area to grief initial lp?
        if (mintVars.isFirstMint || to == _initialLPInfo.liquidityProvider) {
            _updateInitialLpInfo(liquidity, balanceEth, to, false, false);
        }
        if (!mintVars.isFirstMint) _updateFeeRewards(to);

        if (totalSupply_ == 0) {
            _mint(address(0), MINIMUM_LIQUIDITY);
        }

        _locked[to] = uint32(block.timestamp + _MIN_LOCK_PERIOD);
        _mint(to, liquidity);

        _update(balanceEth, balanceToken, false);

        emit Mint(msg.sender, amountWeth, amountToken);
    }

    function _updateInitialLpInfo(uint256 liquidity, uint256 wethAmt, address lp, bool isBurn, bool internalBurn)
        internal
    {
        GoatTypes.InitialLPInfo memory info = _initialLPInfo;

        if (internalBurn) {
            // update from from swap when pool converts to an amm
            info.fractionalBalance = uint112(liquidity) / 4;
        } else if (isBurn) {
            if (lp == info.liquidityProvider) {
                info.lastWithdraw = uint32(block.timestamp);
                info.withdrawalLeft -= 1;
            }
        } else {
            info.fractionalBalance = uint112(((info.fractionalBalance * info.withdrawalLeft) + liquidity) / 4);
            info.withdrawalLeft = 4;
            info.liquidityProvider = lp;
            if (wethAmt != 0) {
                info.initialWethAdded = wethAmt;
            }
        }

        // Update initial liquidity provider info
        _initialLPInfo = info;
    }

    function burn(address to) external returns (uint256 amountWeth, uint256 amountToken) {
        uint256 liquidity = balanceOf(address(this));

        // initial lp can bypass this check by using different
        // to address so _lastPoolTokenSender is used
        if (_lastPoolTokenSender == _initialLPInfo.liquidityProvider) {
            if (_vestingUntil == _MAX_UINT32) revert GoatErrors.PresalePeriod();
            _updateInitialLpInfo(liquidity, 0, _initialLPInfo.liquidityProvider, true, false);
        }

        uint256 balanceEth = IERC20(_weth).balanceOf(address(this));
        uint256 balanceToken = IERC20(_token).balanceOf(address(this));

        uint256 totalSupply_ = totalSupply();
        amountWeth = (liquidity * balanceEth) / totalSupply_;
        amountToken = (liquidity * balanceToken) / totalSupply_;
        if (amountWeth == 0 || amountToken == 0) {
            revert GoatErrors.InsufficientLiquidityBurned();
        }

        _updateFeeRewards(to);
        _burn(address(this), liquidity);

        // Transfer liquidity tokens to the user
        IERC20(_weth).safeTransfer(to, amountWeth);
        IERC20(_token).safeTransfer(to, amountToken);
        balanceEth = IERC20(_weth).balanceOf(address(this));
        balanceToken = IERC20(_token).balanceOf(address(this));

        _update(balanceEth, balanceToken, false);

        emit Burn(msg.sender, amountWeth, amountToken, to);
    }

    // should be called from a contract with safety checks
    function swap(uint256 amountTokenOut, uint256 amountWethOut, address to) external nonReentrant {
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

        (swapVars.initialReserveEth, swapVars.initialReserveToken) = _getActualReserves();

        if (amountTokenOut > swapVars.initialReserveToken || amountWethOut > swapVars.initialReserveEth) {
            revert GoatErrors.InsufficientAmountOut();
        }

        if (swapVars.isBuy) {
            swapVars.amountWethIn = IERC20(_weth).balanceOf(address(this)) - swapVars.initialReserveEth
                - _pendingLiquidityFees - _pendingProtocolFees;
            // optimistically send tokens out
            IERC20(_token).safeTransfer(to, amountTokenOut);
        } else {
            swapVars.amountTokenIn = IERC20(_token).balanceOf(address(this)) - swapVars.initialReserveToken;
            // optimistically send weth out
            IERC20(_weth).safeTransfer(to, amountWethOut);
        }
        swapVars.vestingUntil = _vestingUntil;
        swapVars.isPresale = swapVars.vestingUntil == _MAX_UINT32;

        (swapVars.feesCollected, swapVars.lpFeesCollected) =
            _handleFees(swapVars.amountWethIn, amountWethOut, swapVars.isPresale);

        swapVars.tokenAmount = swapVars.isBuy ? amountTokenOut : swapVars.amountTokenIn;

        // We store details of participants so that we only allow users who have
        // swap back tokens who have bought in the vesting period.
        if (swapVars.vestingUntil > block.timestamp) {
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
            ? swapVars.initialReserveEth + swapVars.amountWethIn
            : swapVars.initialReserveEth - amountWethOut;
        swapVars.finalReserveToken = swapVars.isBuy
            ? swapVars.initialReserveToken - amountTokenOut
            : swapVars.initialReserveToken + swapVars.amountTokenIn;

        swapVars.bootstrapEth = _bootstrapEth;
        if (swapVars.isPresale && swapVars.finalReserveEth >= swapVars.bootstrapEth) {
            // at this point pool should be changed to an AMM
            _checkAndConvertPool(swapVars.finalReserveEth, swapVars.finalReserveToken);
        } else {
            // check for K
            swapVars.initialTokenMatch = _initialTokenMatch;
            swapVars.virtualEth = _virtualEth;

            (swapVars.virtualEthReserveBefore, swapVars.virtualTokenReserveBefore) =
                _getReserves(swapVars.vestingUntil, swapVars.initialReserveEth, swapVars.initialReserveToken);
            (swapVars.virtualEthReserveAfter, swapVars.virtualTokenReserveAfter) =
                _getReserves(swapVars.vestingUntil, swapVars.finalReserveEth, swapVars.finalReserveToken);
            if (
                swapVars.virtualEthReserveBefore * swapVars.virtualTokenReserveBefore
                    > swapVars.virtualEthReserveAfter * swapVars.virtualTokenReserveAfter
            ) {
                revert GoatErrors.KInvariant();
            }
        }
        // presale lp fees should go to reserve eth
        if (swapVars.isPresale) {
            swapVars.finalReserveEth += swapVars.lpFeesCollected;
        }
        _update(swapVars.finalReserveEth, swapVars.finalReserveToken, true);
    }

    function _getActualReserves() internal view returns (uint112 reserveEth, uint112 reserveToken) {
        reserveEth = _reserveEth;
        reserveToken = _reserveToken;
    }

    function _getReserves(uint32 vestingUntil_, uint256 ethReserve, uint256 tokenReserve)
        internal
        view
        returns (uint112 reserveEth, uint112 reserveToken)
    {
        // just pass eth reserve and token reserve here only use virtual eth and initial token match
        // if pool has not turned into an AMM
        if (vestingUntil_ != _MAX_UINT32) {
            // Actual reserves
            reserveEth = uint112(ethReserve);
            reserveToken = uint112(tokenReserve);
        } else {
            uint256 initialTokenMatch = _initialTokenMatch;
            uint256 virtualEth = _virtualEth;
            uint256 virtualToken = _getVirtualToken(virtualEth, _bootstrapEth, initialTokenMatch);
            // Virtual reserves
            reserveEth = uint112(virtualEth + ethReserve);
            reserveToken = uint112(virtualToken + tokenReserve);
        }
    }

    /// @notice returns actual reserves if pool has turned into an AMM else returns virtual reserves
    function getReserves() public view returns (uint112 reserveEth, uint112 reserveToken) {
        (reserveEth, reserveToken) = _getReserves(_vestingUntil, _reserveEth, _reserveToken);
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

        _update(reserveEth, tokenAmtForAmm, true);
    }

    // teams can use this function to take over the pool by adding
    // at least 10% more tokens and weth added by the initial LP.
    // This function can be used to bypass griefing by the malicious users
    function takeOverPool(uint256 tokenAmount, uint256 wethAmount, GoatTypes.InitParams memory initParams) external {
        if (_vestingUntil != _MAX_UINT32) {
            revert GoatErrors.ActionNotAllowed();
        }

        GoatTypes.InitialLPInfo memory initialLpInfo = _initialLPInfo;

        if (wethAmount < initialLpInfo.initialWethAdded) {
            revert GoatErrors.InsufficientWethAmount();
        }

        GoatTypes.LocalVariables_TakeOverPool memory localVars;
        address to = msg.sender;
        localVars.virtualEthOld = _virtualEth;
        localVars.bootstrapEthOld = _bootstrapEth;
        localVars.initialTokenMatchOld = _initialTokenMatch;
        // @note is there a need to check old init params and new init params?
        (localVars.tokenAmountForPresaleOld, localVars.tokenAmountForAmmOld) = _tokenAmountsForLiquidityBootstrap(
            localVars.virtualEthOld,
            localVars.bootstrapEthOld,
            initialLpInfo.initialWethAdded,
            localVars.initialTokenMatchOld
        );

        // team needs to add min 10% more tokens than the initial lp to take over
        localVars.minTokenNeeded =
            ((localVars.tokenAmountForPresaleOld + localVars.tokenAmountForAmmOld) * 11000) / 10000;
        if (tokenAmount < localVars.minTokenNeeded) {
            revert GoatErrors.InsufficientTakeoverTokenAmount();
        }

        // new token amount for presale if initParams are changed
        (localVars.tokenAmountForPresaleNew, localVars.tokenAmountForAmmNew) = _tokenAmountsForLiquidityBootstrap(
            initParams.virtualEth, initParams.bootstrapEth, wethAmount, initParams.initialTokenMatch
        );

        if (tokenAmount != (localVars.tokenAmountForPresaleNew + localVars.tokenAmountForAmmNew)) {
            revert GoatErrors.IncorrectTokenAmount();
        }

        //
        uint256 lpBalance = balanceOf(initialLpInfo.liquidityProvider);
        // @note even though future mints are calculated using totalSupply
        // is there a need to mint different amount of liquidity tokens
        // to the one who is taking over for homogenity? because init params
        // is gonna get updated here
        _burn(initialLpInfo.liquidityProvider, lpBalance);

        delete _initialLPInfo;
        // new lp balance
        lpBalance = Math.sqrt(initParams.virtualEth * initParams.initialTokenMatch) - MINIMUM_LIQUIDITY;
        _mint(to, lpBalance);
        _updateInitialLpInfo(lpBalance, wethAmount, to, false, false);

        // transfer excess token to the initial liquidity provider
        IERC20(_token).safeTransfer(
            initialLpInfo.liquidityProvider, (localVars.tokenAmountForAmmOld + localVars.tokenAmountForPresaleOld)
        );
        if (initialLpInfo.initialWethAdded != 0) {
            IERC20(_weth).safeTransfer(initialLpInfo.liquidityProvider, initialLpInfo.initialWethAdded);
        }
        // update init vars
        _virtualEth = uint112(initParams.virtualEth);
        _bootstrapEth = uint112(initParams.bootstrapEth);
        _initialTokenMatch = initParams.initialTokenMatch;

        // final balance check
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        // update reserves
        _update(_reserveEth, tokenBalance, false);
    }

    function _burnLiquidityAndConvertToAmm(uint256 actualEthReserve, uint256 actualTokenReserve) internal {
        address initialLiquidityProvider = _initialLPInfo.liquidityProvider;

        uint256 initialLPBalance = balanceOf(initialLiquidityProvider);

        uint256 liquidity = Math.sqrt(actualTokenReserve * actualEthReserve) - MINIMUM_LIQUIDITY;

        uint256 liquidityToBurn = initialLPBalance - liquidity;

        _updateInitialLpInfo(liquidity, 0, initialLiquidityProvider, false, true);
        _burn(initialLiquidityProvider, liquidityToBurn);
        _vestingUntil = uint32(block.timestamp + VESTING_PERIOD);
    }

    function _checkAndConvertPool(uint256 initialReserveEth, uint256 initialReserveToken) internal {
        uint256 tokenAmtForAmm;
        uint256 kForAmm;
        if (initialReserveEth >= _bootstrapEth) {
            (, tokenAmtForAmm) = _tokenAmountsForLiquidityBootstrap(_virtualEth, _bootstrapEth, 0, _initialTokenMatch);
            kForAmm = _bootstrapEth * tokenAmtForAmm;
        }

        uint256 actualK = initialReserveEth * initialReserveToken;
        if (actualK < kForAmm) {
            revert GoatErrors.KInvariant();
        }
        _burnLiquidityAndConvertToAmm(initialReserveEth, initialReserveToken);
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

    function _getVirtualToken(uint256 virtualEth, uint256 bootstrapEth, uint256 initialTokenMatch)
        internal
        pure
        returns (uint256 virtualToken)
    {
        (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm) =
            _tokenAmountsForLiquidityBootstrap(virtualEth, bootstrapEth, 0, initialTokenMatch);

        virtualToken = initialTokenMatch - (tokenAmtForPresale + tokenAmtForAmm);
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

    // handle initial liquidity provider checks and update locked if lp is transferred
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        GoatTypes.InitialLPInfo memory lpInfo = _initialLPInfo;
        if (to == lpInfo.liquidityProvider) revert GoatErrors.TransferToInitialLpRestricted();
        if (from == lpInfo.liquidityProvider) {
            // initial lp can't transfer funds to other addresses
            if (to != address(this)) revert GoatErrors.TransferFromInitialLpRestricted();

            uint256 timestamp = block.timestamp;

            // check for coldown period
            if ((timestamp - 1 weeks) < lpInfo.lastWithdraw) {
                revert GoatErrors.WithdrawalCooldownActive();
            }

            // we only check for fractional balance if withdrawalLeft is not 1
            // because last withdraw should be allowed to remove the dust amount
            // as well that's not in the fractional balance that's caused due
            // to division by 4
            if (lpInfo.withdrawalLeft != 1 && (amount > lpInfo.fractionalBalance)) {
                revert GoatErrors.BurnLimitExceeded();
            }
        }

        if (_locked[from] > block.timestamp) {
            revert GoatErrors.LiquidityLocked();
        }

        if (to == address(this)) {
            // We need to store from if lp is being sent to address(this) because
            // initial user can bypass the checks inside burn by passing different from argument
            _lastPoolTokenSender = from;
        }

        // Update fee rewards for both sender and receiver
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
        uint256 feesAccrued = (balanceOf(lp) * feesPerToken) / 1e18;
        return lpFees[lp] + feesAccrued;
    }

    function earned(address lp) external view returns (uint256) {
        return _earned(lp, feesPerTokenStored);
    }

    function vestingUntil() external view returns (uint32 vestingUntil_) {
        vestingUntil_ = _vestingUntil;
    }

    // read for test purposes only
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

    function getStateInfoForPresale()
        external
        view
        returns (
            uint112 reserveEth,
            uint112 reserveToken,
            uint112 virtualEth,
            uint112 initialTokenMatch,
            uint112 bootstrapEth,
            uint256 virtualToken
        )
    {
        reserveEth = _reserveEth;
        reserveToken = _reserveToken;
        virtualEth = _virtualEth;
        initialTokenMatch = _initialTokenMatch;
        bootstrapEth = _bootstrapEth;
        virtualToken = _getVirtualToken(virtualEth, bootstrapEth, initialTokenMatch);
    }

    function getStateInfoAmm() external view returns (uint112, uint112) {
        return (_reserveEth, _reserveToken);
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

    function getFeesPerTokenStored() external view returns (uint256) {
        return feesPerTokenStored;
    }

    function getPendingLiquidityFees() external view returns (uint112) {
        return _pendingLiquidityFees;
    }

    function getPendingProtocolFees() external view returns (uint72) {
        return _pendingProtocolFees;
    }
}
