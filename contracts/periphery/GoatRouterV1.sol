// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GoatTypes} from "../library/GoatTypes.sol";
import {GoatV1Factory} from "../exchange/GoatV1Factory.sol";
import {GoatV1Pair} from "../exchange/GoatV1Pair.sol";
import {GoatErrors} from "../library/GoatErrors.sol";
import {GoatLibrary} from "../library/GoatLibrary.sol";
import {IWETH} from "../interfaces/IWETH.sol";

contract GoatV1Router is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable FACTORY;
    address public immutable WETH;
    uint32 private constant MAX_UINT32 = type(uint32).max;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "GoatV1Router: EXPIRED");
        _;
    }

    constructor(address factory, address weth) {
        FACTORY = factory;
        WETH = weth;
    }

    //TODO: Have a fresh look at the code and check if this is what we want to do,
    //TODO: add checks
    function addLiqudity(
        address token,
        uint256 tokenDesired,
        uint256 wethDesired,
        uint256 tokenMin,
        uint256 wethMin,
        address to,
        uint256 deadline,
        GoatTypes.InitParams memory initParams
    ) external nonReentrant ensure(deadline) returns (uint256, uint256, uint256) {
        //    Follow CEI
        // checks
        // 3. tokenMin and wethMin will be same as desired because there is not ratio to adjust at first
        // 4. lockUntil - if any minimum  for this is required?
        // 5. if there is any data in lauch params after launch then we should rever
        // 6. check if the token is not WETH
        GoatTypes.LocalVariables_AddLiquidity memory vars;
        {
            (vars.tokenAmount, vars.wethAmount, vars.isNewPair) =
                _addLiquidity(token, tokenDesired, wethDesired, tokenMin, wethMin, initParams);
            if (vars.isNewPair) {
                // only for the first time
                vars.actualTokenAmount = GoatLibrary.getActualTokenAmount(
                    initParams.virtualEth, initParams.bootstrapEth, initParams.initialTokenMatch
                );
            }
            vars.wethAmountInitial = vars.isNewPair ? initParams.initialEth : vars.wethAmount;
        }
        {
            vars.pair = GoatV1Factory(FACTORY).getPool(token);
            IERC20(token).safeTransferFrom(msg.sender, vars.pair, vars.actualTokenAmount);
            if (vars.wethAmountInitial != 0) {
                IERC20(WETH).safeTransferFrom(msg.sender, vars.pair, vars.wethAmountInitial);
            }
            vars.liquidity = GoatV1Pair(vars.pair).mint(to);
        }
        return (vars.tokenAmount, vars.wethAmount, vars.liquidity);
    }

    function addLiqudityETH(
        address token,
        uint256 tokenDesired,
        uint256 tokenMin,
        uint256 ethMin,
        address to,
        uint256 deadline,
        GoatTypes.InitParams memory initParams
    ) external payable ensure(deadline) returns (uint256 tokenAmount, uint256 ethAmount, uint256 liquidity) {
        GoatTypes.LocalVariables_AddLiquidity memory vars;
        vars.pair = GoatV1Factory(FACTORY).getPool(token);
        if (vars.pair == address(0)) {
            // only for the first time
            vars.actualTokenAmount = GoatLibrary.getActualTokenAmount(
                initParams.virtualEth, initParams.bootstrapEth, initParams.initialTokenMatch
            );
        }

        (tokenAmount, ethAmount, vars.isNewPair) =
            _addLiquidity(token, tokenDesired, msg.value, tokenMin, ethMin, initParams);
        IERC20(token).safeTransferFrom(msg.sender, vars.pair, vars.actualTokenAmount);
        IWETH(WETH).deposit{value: ethAmount}();
        IERC20(WETH).safeTransfer(vars.pair, ethAmount);
        uint256 _wethAmountInitial = vars.isNewPair ? initParams.initialEth : ethAmount;

        if (_wethAmountInitial != 0) {
            IERC20(WETH).safeTransferFrom(msg.sender, vars.pair, _wethAmountInitial);
        }

        liquidity = GoatV1Pair(vars.pair).mint(to);
        // refund dust eth, if any
        if (msg.value > ethAmount) {
            payable(msg.sender).transfer(msg.value - ethAmount);
        }
    }

    function _addLiquidity(
        address token,
        uint256 tokenDesired,
        uint256 wethDesired,
        uint256 tokenMin,
        uint256 wethMin,
        GoatTypes.InitParams memory initParams
    ) internal returns (uint256 tokenAmount, uint256 wethAmount, bool isNewPair) {
        address pool = GoatV1Factory(FACTORY).getPool(token); // @audit we need to sort the tokens to avoid duplicate pool
        GoatV1Pair pair;
        if (pool == address(0)) {
            pair = GoatV1Pair(GoatV1Factory(FACTORY).createPair(token, initParams));
            isNewPair = true;
        } else {
            // @note Is this necessary to check both in pair and here?
            pair = GoatV1Pair(pool);
            if (pair.vestingUntil() == MAX_UINT32) {
                revert GoatErrors.PresalePeriod();
            }
        }

        // @note should we mint liqudity for first liqudity provider?
        if (isNewPair) {
            (tokenAmount, wethAmount) = (initParams.initialTokenMatch, initParams.virtualEth); // ratio is initialTokenMatch: virtualWethAmount
        } else {
            //@note this is the block that will be accesed only after the presale period
            (uint256 tokenReserve, uint256 wethReserve) = pair.getReserves();

            uint256 tokenAmountOptimal = GoatLibrary.quote(wethDesired, wethReserve, tokenReserve);
            if (tokenAmountOptimal <= tokenDesired) {
                if (tokenAmountOptimal < tokenMin) {
                    revert GoatErrors.InsufficientTokenAmount();
                }
                (tokenAmount, wethAmount) = (tokenAmountOptimal, wethDesired);
            } else {
                uint256 wethAmountOptimal = GoatLibrary.quote(tokenDesired, tokenReserve, wethReserve);

                if (wethAmountOptimal <= wethDesired) {
                    // wethAmountOptimal is a adjuted weth amount for tokenDesired
                    if (wethAmountOptimal < wethMin) {
                        revert GoatErrors.InsufficientWethAmount();
                    }
                    (tokenAmount, wethAmount) = (tokenDesired, wethAmountOptimal);
                } else {
                    revert GoatErrors.InsufficientLiquidityMinted();
                }
            }
        }
    }

    function removeLiquidity(
        address token,
        uint256 liquidity,
        uint256 tokenMin,
        uint256 wethMin,
        address to,
        uint256 deadline
    ) public nonReentrant ensure(deadline) returns (uint256 tokenAmount, uint256 wethAmount) {
        // This function is fairly simple, we just need to transfer the liquidity to the pair and call burn
        address pair = GoatV1Factory(FACTORY).getPool(token);

        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity); // send liquidity directly to pair
        (uint256 tokenAmount0, uint256 wethAmount0) = GoatV1Pair(pair).burn(to);

        (tokenAmount, wethAmount) = (tokenAmount0, wethAmount0); // we know we are always going to create a pair with token:WETH so token0 is always token and token1 is always WETH

        if (tokenAmount < tokenMin) {
            revert GoatErrors.InsufficientTokenAmount();
        }
        if (wethAmount < wethMin) {
            revert GoatErrors.InsufficientWethAmount();
        }
    }
}
