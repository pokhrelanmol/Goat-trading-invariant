// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../library/GoatErrors.sol";
import "../library/GoatTypes.sol";
import "./GoatV1ERC20.sol";

// TODO: restrict intitial liquidity provider from transferring
// liquidity tokens

contract GoatV1Pair is GoatV1ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint32 public constant LOCK_PERIOD = 30 days;
    uint32 public constant VESTING_PERIOD = 30 days;
    uint32 private constant _MAX_UINT32 = type(uint32).max;
    uint32 private constant THIRTY_DAYS = 30 days;

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

    uint256 private _bootstrapEth;
    // updates on liquidity changes
    uint256 private _kLast;

    mapping(address => uint256) private _presaleBalances;
    mapping(address => uint32) private _locked;

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
        _reserveEth = uint112(balanceEth);
        _reserveToken = uint112(balanceToken);
    }

    function _handleFirstLiquidityMint(uint256 tokenDepositAmount) internal {
        // Handle first liquidity mint
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
            _presaleBalances[user] += amount;
        } else {
            _presaleBalances[user] -= amount;
        }
    }

    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        uint256 totalSupply_ = totalSupply();
        uint256 amountBase;
        uint256 amountToken;
        uint256 balanceEth = IERC20(_weth).balanceOf(address(this));
        uint256 balanceToken = IERC20(_token).balanceOf(address(this));

        GoatTypes.LocalVariables_MintLiquidity memory mintVars;

        mintVars.virtualEth = _virtualEth;
        mintVars.initialTokenMatch = _initialTokenMatch;
        mintVars.vestingUntil = _vestingUntil;
        mintVars.bootstrapEth = _bootstrapEth;

        if (_vestingUntil == _MAX_UINT32) {
            // Do not allow to add liquidity in presale period
            if (totalSupply_ > 0) revert GoatErrors.PresalePeriod();
            // don't allow to send more eth than bootstrap eth
            if (balanceEth > _bootstrapEth) {
                revert GoatErrors.BalanceMoreThanBootstrapEth();
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
                mintVars.vestingUntil = timestamp;
            }
            _updateInitialLpInfo(liquidity, to, false);
        } else {
            (uint256 reserveEth, uint256 reserveToken) = getReserves();
            amountBase = balanceEth - reserveEth;
            amountToken = balanceToken - reserveToken;
            liquidity = Math.min((amountBase * totalSupply_) / reserveEth, (amountToken * totalSupply_) / reserveToken);
        }

        if (totalSupply_ == 0) {
            _mint(address(0), MINIMUM_LIQUIDITY);
        }

        _locked[to] = uint32(block.timestamp + LOCK_PERIOD);
        _mint(to, liquidity);

        _update(balanceEth, balanceToken);
        emit Mint(msg.sender, amountBase, amountToken);
    }

    function _handleInitialLiquidityProviderChecks(uint256 liquidity) internal view {
        GoatTypes.InitialLPInfo memory info = _initialLPInfo;
        uint256 timestamp = block.timestamp;
        if (liquidity > info.fractionalBalance) {
            revert GoatErrors.BurnLimitExceeded();
        }
        if ((timestamp - 1 weeks) < info.lastWithdraw) {
            revert GoatErrors.WithdrawalCooldownActive();
        }
    }

    function _updateInitialLpInfo(uint256 liquidity, address lp, bool isBurn) internal {
        // TODO: refactor this function
        // Update initial liquidity provider info
        GoatTypes.InitialLPInfo memory info = _initialLPInfo;
        if (isBurn) {
            if (lp == info.liquidityProvider) {
                info.fractionalBalance = uint112(info.fractionalBalance - (liquidity / 4));
                info.withdrawlLeft -= 1;
            }
        } else {
            info.fractionalBalance = uint112(((info.fractionalBalance * info.withdrawlLeft) + liquidity) / 4);
            info.withdrawlLeft = 4;
            info.liquidityProvider = lp;
        }
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
        _burn(address(this), liquidity);
        // Transfer liquidity tokens to the user
        IERC20(_weth).safeTransfer(from, amountWeth);
        IERC20(_token).safeTransfer(from, amountToken);
        balanceEth = IERC20(_weth).balanceOf(address(this));
        balanceToken = IERC20(_token).balanceOf(address(this));

        _update(balanceEth, balanceToken);

        emit Burn(msg.sender, amountWeth, amountToken, from);
    }

    // Call from a safe contract ensuring critical validations are performed.
    function swap(uint256 amountTokenOut, uint256 amountBaseOut, address to) external {
        // General swap like univ2
        // check for mev
        // calculate amount out for presale
        // calculate amount out for amm
        // burn liquidity portion form initial user if bootstrapEth == balanceETH
        // update fees
        // transfer fees to external contract for buybacks and all if fees collected > 0.1 ether
        if (amountTokenOut == 0 && amountBaseOut == 0) {
            revert GoatErrors.InsufficientOutputAmount();
        }
        if (amountTokenOut != 0 || amountBaseOut != 0) {
            revert GoatErrors.MultipleOutputAmounts();
        }

        bool isBuy = amountBaseOut > 0 ? false : true;
        _handleMevCheck(isBuy);

        (uint112 reserveEth, uint112 reserveToken) = getReserves();

        if (amountTokenOut > reserveToken || amountBaseOut > reserveEth) {
            revert GoatErrors.InsufficientAmountOut();
        }
        // What should happen here?
        // 1. Check if the user has presale balance because only presale participants
        // can swap back during the presale period
        // 2. make sure the fees are always stored in the contract and its always in weth
        // so if the swap is buy or sale fees will be taken always in weth amount

        // TODO: I need to transfer fees to the treasury if it reaches a certain amount.
        uint256 balanceEth;
        uint256 balanceToken;
        {
            address token = _token;
            address weth = _weth;

            // Optimistically send tokens out
            if (amountTokenOut > 0) {
                IERC20(token).safeTransfer(to, amountTokenOut);
            }
            if (amountBaseOut > 0) {
                IERC20(weth).safeTransfer(to, amountBaseOut);
            }

            balanceEth = IERC20(weth).balanceOf(address(this));
            balanceToken = IERC20(token).balanceOf(address(this));
        }
        // Think about fees in here
        uint256 amountBaseIn =
            (balanceEth > (_reserveEth - amountBaseOut)) ? balanceEth - (_reserveEth - amountBaseOut) : 0;

        uint256 amountTokenIn =
            (balanceToken > (_reserveToken - amountTokenOut)) ? balanceToken - (_reserveToken - amountTokenOut) : 0;

        // if presale update the presale balance of the buyer
        {
            uint256 amount = isBuy ? amountTokenOut : amountTokenIn;
            if (_vestingUntil == _MAX_UINT32) _updatePresale(to, amount, isBuy);
        }
    }

    function getReserves() public view returns (uint112 reserveEth, uint112 reserveToken) {
        // Calculate reserves and return
        if (_vestingUntil != _MAX_UINT32) {
            reserveEth = _reserveEth;
            reserveToken = _reserveToken;
        } else {
            reserveEth = _virtualEth + _reserveEth; // this is all good
            reserveToken = uint112((uint256(_virtualEth) * uint256(_initialTokenMatch)) / uint256(reserveEth));
            // 10e18 * 1000e18 / 15e18 = 666.666666666666666666
        }
    }

    function withdrawExcessToken() external {
        if (msg.sender != _initialLPInfo.liquidityProvider) {
            revert GoatErrors.Unauthorized();
        }
        uint256 timestamp = block.timestamp;
        address initialLiquidityProvider = _initialLPInfo.liquidityProvider;
        // initial liquidty provider can call this function after
        if (_genesis + THIRTY_DAYS > timestamp) revert GoatErrors.PresaleDeadlineActive();

        // as bootstrap eth is not met we consider reserve eth as bootstrap eth
        // and turn presale into an amm will less liquidity.
        uint256 reserveEth = _reserveEth;
        uint256 bootstrapEth = reserveEth;

        (, uint256 tokenAmtForAmm) =
            _tokenAmountsForLiquidityBootstrap(_virtualEth, bootstrapEth, reserveEth, _initialTokenMatch);
        IERC20 token = IERC20(_token);
        uint256 poolTokenBalance = token.balanceOf(address(this));

        uint256 amountToTransferBack = poolTokenBalance - tokenAmtForAmm;

        _vestingUntil = uint32(block.timestamp);
        uint256 initialLPBalance = balanceOf(initialLiquidityProvider);

        uint256 liquidity = Math.sqrt(tokenAmtForAmm * reserveEth);

        uint256 liquidityToBurn = initialLPBalance - liquidity;

        _burn(initialLiquidityProvider, liquidityToBurn);
        _updateInitialLpInfo(liquidityToBurn, initialLiquidityProvider, true);

        token.safeTransfer(initialLiquidityProvider, amountToTransferBack);
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

    // Implement after token transfers for liqudity rewards
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        // handle fees update
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        // handle initial liquidity provider checks
        GoatTypes.InitialLPInfo memory lpInfo = _initialLPInfo;
        if (lpInfo.liquidityProvider == from || lpInfo.liquidityProvider == to) {
            revert GoatErrors.LPTransferRestricted();
        }
    }

    function token0() external view returns (address) {
        return _token < _weth ? _token : _weth;
    }

    function vestingUntil() external view returns (uint32 vestingUntil_) {
        vestingUntil_ = _vestingUntil;
        if (vestingUntil_ != _MAX_UINT32) {
            vestingUntil_ += VESTING_PERIOD;
        }
    }

    function token1() external view returns (address) {
        return _token < _weth ? _weth : _token;
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
            uint256 kLast,
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
        kLast = kLast;
        genesis = _genesis;
    }

    function getPresaleBalance(address user) external view returns (uint256) {
        return _presaleBalances[user];
    }

    function getInitialLPInfo() external view returns (GoatTypes.InitialLPInfo memory) {
        return _initialLPInfo;
    }

    function getLocked(address user) external view returns (uint32) {
        return _locked[user];
    }
}
