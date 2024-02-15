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

contract GoatV1Pair is GoatV1ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint32 public constant LOCK_PERIOD = 30 days;
    uint32 public constant VESTING_PERIOD = 30 days;
    uint32 private constant _MAX_UINT32 = type(uint32).max;

    address public immutable factory;
    uint32 private immutable _genesis;
    // Figure out a way to use excess 12 bytes in here to store something
    address private _token;
    address private _weth;

    uint112 private _virtualEth;
    uint112 private _bootstrapEth;
    uint32 private _vestingUntil;

    uint112 private _reserveEth;
    uint112 private _reserveToken;
    uint32 private _lastTrade;

    // No need to save it can be used first time to calculate k last
    // and reverse engineer to get actual token match
    uint256 private initialTokenMatch;

    // updates on liquidity changes
    uint256 private kLast;

    mapping(address => uint256) private presaleBalances;
    mapping(address => uint32) private locked;

    GoatTypes.InitialLPInfo private initialLPInfo;

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
        initialTokenMatch = params.initialTokenMatch;
        _virtualEth = params.virtualEth;
        _bootstrapEth = params.bootstrapEth;
        initialLPInfo.liquidityProvider = params.liquidityProvider;
    }

    function _update(uint256 balanceEth, uint256 balanceToken) internal {
        // Update token reserves and other necessary data
        _reserveEth = uint112(balanceEth);
        _reserveToken = uint112(balanceToken);
        // TODO: update k last by using presale and amm logic
        kLast = balanceEth * balanceToken;
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
            presaleBalances[user] += amount;
        } else {
            presaleBalances[user] -= amount;
        }
    }

    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        // required bootstrap eth.
        uint256 totalSupply_ = totalSupply();
        uint256 amountBase;
        uint256 amountToken;
        // TODO: make sure to lock liquidity for a certain period of time
        // so that people can't sandwich fees on large swaps.

        uint256 balanceEth = IERC20(_weth).balanceOf(address(this));
        uint256 balanceToken = IERC20(_token).balanceOf(address(this));

        if (_vestingUntil == _MAX_UINT32) {
            // Do not allow to add liquidity in presale period
            if (totalSupply_ > 0) revert GoatErrors.PresalePeriod();

            initialLPInfo.liquidityProvider = to;

            locked[to] = uint32(block.timestamp + LOCK_PERIOD);

            // @note make sure balance token is equal to expected token amount
            (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm) =
                _tokenAmountsForLiquidityBootstrap(_virtualEth, _bootstrapEth, initialTokenMatch);
            liquidity = Math.sqrt(_virtualEth * balanceToken) - MINIMUM_LIQUIDITY;
            if (balanceEth != 0) {
                if (balanceEth >= _bootstrapEth) {
                    _vestingUntil = uint32(block.timestamp);
                    // @note I am not sure if I need != here
                    if (balanceToken < tokenAmtForAmm) {
                        revert GoatErrors.InsufficientTokenAmount();
                    }
                } else {
                    // I am considering additional real eth added at the time of first liquidity
                    // as swap event on presale but without fees
                    uint256 quoteTokenAmount = (balanceEth * tokenAmtForPresale) / _bootstrapEth;
                    // quote token amount will cancle out the weth added at the time of initial liquidity
                    if (balanceToken < (tokenAmtForPresale + tokenAmtForAmm - quoteTokenAmount)) {
                        revert GoatErrors.InsufficientTokenAmount();
                    }
                }
            } else {
                // @note I am not sure if I need != here
                if (balanceToken < tokenAmtForPresale + tokenAmtForAmm) {
                    revert GoatErrors.InsufficientTokenAmount();
                }
            }
        } else {
            (uint256 reserveEth, uint256 reserveToken) = getReserves();
            amountBase = balanceEth - reserveEth;
            amountToken = balanceToken - reserveToken;
            liquidity = Math.min((amountBase * totalSupply_) / reserveEth, (amountToken * totalSupply_) / reserveToken);
        }

        if (totalSupply_ == 0) {
            _mint(address(0), MINIMUM_LIQUIDITY);
        }
        _mint(to, liquidity);

        // @note check if this is the right place to update initial lp info
        _updateInitialLpInfo(liquidity, false);

        _update(balanceEth, balanceToken);
        emit Mint(msg.sender, amountBase, amountToken);
    }

    function _handleInitialLiquidityProviderChecks(uint256 liquidity) internal {
        GoatTypes.InitialLPInfo memory info = initialLPInfo;
        uint256 timestamp = block.timestamp;
        if (liquidity > info.fractionalBalance) {
            revert GoatErrors.BurnLimitExceeded();
        }
        if ((timestamp - 1 weeks) < info.lastWithdraw) {
            revert GoatErrors.WithdrawalCooldownActive();
        }
    }

    function _updateInitialLpInfo(uint256 liquidity, bool isBurn) internal {
        // Update initial liquidity provider info
        GoatTypes.InitialLPInfo memory info = initialLPInfo;
        if (isBurn) {
            info.fractionalBalance = uint112(info.fractionalBalance - (liquidity / 4));
            info.withdrawlLeft -= 1;
        } else {
            info.fractionalBalance = uint112(((info.fractionalBalance * info.withdrawlLeft) + liquidity) / 4);
            info.withdrawlLeft = 4;
        }
        initialLPInfo = info;
    }

    function burn(address from) external returns (uint256 amountWeth, uint256 amountToken) {
        // Burn liquidity tokens
        if (locked[from] > block.timestamp) {
            revert GoatErrors.LiquidityLocked();
        }
        uint256 liquidity = balanceOf(address(this));
        if (from == initialLPInfo.liquidityProvider) {
            _handleInitialLiquidityProviderChecks(liquidity);
        }

        // @note check if this is the right place to update
        _updateInitialLpInfo(liquidity, true);

        (uint256 reserveEth, uint256 reserveToken) = getReserves();
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
            reserveEth = _virtualEth + _reserveEth;
            reserveToken = uint112(kLast / _reserveEth);
        }
    }

    function withdrawExcessToken() external {
        if (msg.sender != initialLPInfo.liquidityProvider) {
            revert GoatErrors.Unauthorized();
        }
        // Burn similar amount of liquidity
    }

    function _tokenAmountsForLiquidityBootstrap(uint256 virtualEth, uint256 bootstrapEth, uint256 _initialTokenMatch)
        internal
        pure
        returns (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm)
    {
        // TODO: figure out for a situation when initial liquidity provider is trying to add some weth
        // some amount of weth along with it.
        // @note I have not handled precision loss here. Make sure if I need to round it up by 1.
        uint256 k = virtualEth * _initialTokenMatch;
        tokenAmtForPresale = _initialTokenMatch - (k / (virtualEth + bootstrapEth));
        tokenAmtForAmm = ((k / (virtualEth + bootstrapEth)) / (virtualEth + bootstrapEth)) * bootstrapEth;
    }

    // Implement after token transfers for liqudity rewards

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
}
