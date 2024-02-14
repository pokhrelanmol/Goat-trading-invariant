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
    address private _baseToken;
    address private _initialLiquidityProvider;

    uint112 private _virtualBase;
    uint112 private _bootstrapBase;
    uint32 private _vestingUntil;

    uint112 private _reserveBase;
    uint112 private _reserveToken;
    uint32 private _lastTrade;

    // No need to save it can be used first time to calculate k last
    // and reverse engineer to get actual token match
    uint256 private initialTokenMatch;

    // updates on liquidity changes
    uint256 private kLast;

    mapping(address => uint256) private presaleBalances;
    mapping(address => uint32) private locked;

    event Mint(address, uint256, uint256);

    constructor() {
        factory = msg.sender;
        _genesis = uint32(block.timestamp);
    }

    function initialize(address token, address baseToken, string memory baseName, GoatTypes.InitParams memory params)
        external
    {
        if (msg.sender != factory) revert GoatErrors.GoatV1Forbidden();
        _token = token;
        _baseToken = baseToken;
        // setting non zero value so that swap will not incur new storage write on update
        _vestingUntil = _MAX_UINT32;
        // Is there a token without a name that may result in revert in this case?
        string memory tokenName = IERC20Metadata(_token).name();
        name = string(abi.encodePacked("GoatTradingV1: ", baseName, "/", tokenName));
        symbol = string(abi.encodePacked("GoatV1-", baseName, "-", tokenName));
        initialTokenMatch = params.initialTokenMatch;
        _virtualBase = params.virtualBase;
        _bootstrapBase = params.bootstrapBase;
        _initialLiquidityProvider = params.liquidiyProvider;
    }

    function _update() internal {
        // Update token reserves and other necessary data
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
        // TODO: make sure that presale is flase if initial weth provided is >
        // required bootstrap eth.
        uint256 totalSupply_ = totalSupply();
        uint256 amountBase;
        uint256 amountToken;

        uint256 balanceBase = IERC20(_baseToken).balanceOf(address(this));
        uint256 balanceToken = IERC20(_token).balanceOf(address(this));

        if (_vestingUntil == _MAX_UINT32) {
            if (totalSupply_ > 0) revert GoatErrors.PresalePeriod();

            // check for frontrun and DOS (What if msg.sender is router? and user is not calling)
            // TODO: figure this out.
            if (msg.sender != _initialLiquidityProvider) revert GoatErrors.Unauthorized();

            _initialLiquidityProvider = to;

            locked[to] = uint32(block.timestamp + 30 days);

            if (balanceBase >= _bootstrapBase) {
                _vestingUntil = uint32(block.timestamp);
            }

            // TODO: handle initial liquidity calculation
            // make sure balance token is equal to expected token amount
            (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm) =
                _tokenAmountsForLiquidityBootstrap(_virtualBase, _bootstrapBase, initialTokenMatch);
            // is there a need to use < instead of !=?
            if (balanceToken != tokenAmtForPresale + tokenAmtForAmm) {
                revert GoatErrors.InsufficientTokenAmount();
            }
            liquidity = Math.sqrt((_virtualBase + balanceBase) * amountToken) - MINIMUM_LIQUIDITY;
        } else {
            (uint256 reserveBase, uint256 reserveToken) = getReserves();
            amountBase = balanceBase - reserveBase;
            amountToken = balanceToken - reserveToken;
            liquidity = Math.min((amountBase * totalSupply_) / reserveBase, (amountToken * totalSupply_) / reserveToken);
        }

        if (totalSupply_ == 0) {
            _mint(address(0), MINIMUM_LIQUIDITY);
        }
        _mint(to, liquidity);

        emit Mint(msg.sender, amountBase, amountToken);
    }

    function burn(address from) external returns (uint256, uint256) {
        // Burn liquidity tokens
        if (locked[from] > block.timestamp) {
            revert GoatErrors.LiquidityLocked();
        }
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

        (uint112 reserveBase, uint112 reserveToken) = getReserves();

        if (amountTokenOut > reserveToken || amountBaseOut > reserveBase) {
            revert GoatErrors.InsufficientAmountOut();
        }
        // What should happen here?
        // 1. Check if the user has presale balance because only presale participants
        // can swap back during the presale period
        // 2. make sure the fees are always stored in the contract and its always in weth
        // so if the swap is buy or sale fees will be taken always in weth amount

        // TODO: I need to transfer fees to the treasury if it reaches a certain amount.
        uint256 balanceBase;
        uint256 balanceToken;
        {
            address token = _token;
            address baseToken = _baseToken;

            // Optimistically send tokens out
            if (amountTokenOut > 0) {
                IERC20(token).safeTransfer(to, amountTokenOut);
            }
            if (amountBaseOut > 0) {
                IERC20(baseToken).safeTransfer(to, amountBaseOut);
            }

            balanceBase = IERC20(baseToken).balanceOf(address(this));
            balanceToken = IERC20(token).balanceOf(address(this));
        }
        // Think about fees in here
        uint256 amountBaseIn =
            (balanceBase > (_reserveBase - amountBaseOut)) ? balanceBase - (_reserveBase - amountBaseOut) : 0;

        uint256 amountTokenIn =
            (balanceToken > (_reserveToken - amountTokenOut)) ? balanceToken - (_reserveToken - amountTokenOut) : 0;

        // if presale update the presale balance of the buyer
        {
            uint256 amount = isBuy ? amountTokenOut : amountTokenIn;
            if (_vestingUntil == _MAX_UINT32) _updatePresale(to, amount, isBuy);
        }
    }

    function getReserves() public view returns (uint112 reserveBase, uint112 reserveToken) {
        // Calculate reserves and return
        if (_vestingUntil != _MAX_UINT32) {
            reserveBase = _reserveBase;
            reserveToken = _reserveToken;
        } else {
            reserveBase = _virtualBase + _reserveBase;
            reserveToken = uint112(kLast / _reserveBase);
        }
    }

    function withdrawExcessToken() external {
        if (msg.sender != _initialLiquidityProvider) {
            revert GoatErrors.Unauthorized();
        }
        // Burn similar amount of liquidity
    }

    function _tokenAmountsForLiquidityBootstrap(uint256 virtualEth, uint256 bootstrapEth, uint256 _initialTokenMatch)
        internal
        pure
        returns (uint256 tokenAmtForPresale, uint256 tokenAmtForAmm)
    {
        // TODO: figure out for a situation when initial liquidity provider is trying to add
        // some amount of baseToken along with it.
        // @note I have not handled precision loss here. Make sure if I need to round it up by 1.
        uint256 k = virtualEth * _initialTokenMatch;
        tokenAmtForPresale = _initialTokenMatch - (k / (virtualEth + bootstrapEth));
        tokenAmtForAmm = ((k / (virtualEth + bootstrapEth)) / (virtualEth + bootstrapEth)) * bootstrapEth;
    }

    // Implement after token transfers for liqudity rewards

    function token0() external view returns (address) {
        return _token < _baseToken ? _token : _baseToken;
    }

    function vestingUntil() external view returns (uint32 vestingUntil_) {
        vestingUntil_ = _vestingUntil;
        if (vestingUntil_ != type(uint32).max) {
            vestingUntil_ += 4 weeks;
        }
        return vestingUntil_;
    }

    function token1() external view returns (address) {
        return _token < _baseToken ? _baseToken : _token;
    }
}
