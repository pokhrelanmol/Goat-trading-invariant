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
import {console2} from "forge-std/Test.sol";

// TODO: NOT HANDLED FEE ON TRANSFER TOKENS
contract GoatV1Router is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable FACTORY;
    address public immutable WETH;
    uint32 private constant MAX_UINT32 = type(uint32).max;

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) {
            revert GoatErrors.Expired();
        }
        _;
    }

    constructor(address factory, address weth) {
        FACTORY = factory;
        WETH = weth;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address token,
        uint256 tokenDesired,
        uint256 wethDesired,
        uint256 tokenMin,
        uint256 wethMin,
        GoatTypes.InitParams memory initParams
    ) internal returns (uint256, uint256, bool) {
        GoatTypes.LocalVariables_AddLiquidity memory vars;
        vars.pair = GoatV1Factory(FACTORY).getPool(token);
        GoatV1Pair pool;
        if (vars.pair == address(0)) {
            // First time liqudity provider
            pool = GoatV1Pair(GoatV1Factory(FACTORY).createPair(token, initParams));
            vars.isNewPair = true;
        } else {
            pool = GoatV1Pair(vars.pair);
        }

        if (vars.isNewPair) {
            if (initParams.initialEth < initParams.bootstrapEth) {
                (vars.tokenAmount, vars.wethAmount) = (initParams.initialTokenMatch, initParams.virtualEth);
            } else {
                vars.actualTokenAmount = GoatLibrary.getActualBootstrapTokenAmount(
                    initParams.virtualEth, initParams.bootstrapEth, initParams.initialEth, initParams.initialTokenMatch
                );
                (vars.tokenAmount, vars.wethAmount) = (
                    vars.actualTokenAmount,
                    initParams.initialEth // we could also have used initParams.bootstrapEth here
                );
            }
        } else {
            //@note this is the block that will be accesed only after the presale period
            (uint256 wethReserve, uint256 tokenReserve) = pool.getReserves();
            uint256 tokenAmountOptimal = GoatLibrary.quote(wethDesired, wethReserve, tokenReserve);
            if (tokenAmountOptimal <= tokenDesired) {
                if (tokenAmountOptimal < tokenMin) {
                    revert GoatErrors.InsufficientTokenAmount();
                }
                (vars.tokenAmount, vars.wethAmount) = (tokenAmountOptimal, wethDesired);
            } else {
                uint256 wethAmountOptimal = GoatLibrary.quote(tokenDesired, tokenReserve, wethReserve);

                if (wethAmountOptimal <= wethDesired) {
                    // wethAmountOptimal is a adjuted weth amount for tokenDesired
                    if (wethAmountOptimal < wethMin) {
                        revert GoatErrors.InsufficientWethAmount();
                    }
                    (vars.tokenAmount, vars.wethAmount) = (tokenDesired, wethAmountOptimal);
                } else {
                    revert GoatErrors.InsufficientLiquidityMinted();
                }
            }
        }
        return (vars.tokenAmount, vars.wethAmount, vars.isNewPair);
    }

    function addLiquidity(
        address token,
        uint256 tokenDesired,
        uint256 wethDesired,
        uint256 tokenMin,
        uint256 wethMin,
        address to,
        uint256 deadline,
        GoatTypes.InitParams memory initParams
    ) external nonReentrant ensure(deadline) returns (uint256, uint256, uint256) {
        if (token == WETH || token == address(0)) {
            revert GoatErrors.WrongToken();
        }
        GoatTypes.LocalVariables_AddLiquidity memory vars;
        vars.token = token; // prevent stack too deep error
        (vars.tokenAmount, vars.wethAmount, vars.isNewPair) =
            _addLiquidity(token, tokenDesired, wethDesired, tokenMin, wethMin, initParams);

        vars.wethAmountInitial = vars.isNewPair ? initParams.initialEth : vars.wethAmount;
        if (vars.isNewPair) {
            // only for the first time
            vars.actualTokenAmount = GoatLibrary.getActualBootstrapTokenAmount(
                initParams.virtualEth, initParams.bootstrapEth, vars.wethAmountInitial, initParams.initialTokenMatch
            );
        } else {
            vars.actualTokenAmount = vars.tokenAmount;
        }

        vars.pair = GoatV1Factory(FACTORY).getPool(vars.token);

        IERC20(vars.token).safeTransferFrom(msg.sender, vars.pair, vars.actualTokenAmount);
        if (vars.wethAmountInitial != 0) {
            IERC20(WETH).safeTransferFrom(msg.sender, vars.pair, vars.wethAmountInitial);
        }
        vars.liquidity = GoatV1Pair(vars.pair).mint(to);
        return (vars.tokenAmount, vars.wethAmount, vars.liquidity);
    }

    function addLiquidityETH(
        address token,
        uint256 tokenDesired,
        uint256 tokenMin,
        uint256 ethMin,
        address to,
        uint256 deadline,
        GoatTypes.InitParams memory initParams
    ) external payable ensure(deadline) returns (uint256, uint256, uint256) {
        if (token == WETH || token == address(0)) {
            revert GoatErrors.WrongToken();
        }
        GoatTypes.LocalVariables_AddLiquidity memory vars;
        vars.token = token; // prevent stack too deep error
        (vars.tokenAmount, vars.wethAmount, vars.isNewPair) =
            _addLiquidity(token, tokenDesired, msg.value, tokenMin, ethMin, initParams);
        vars.wethAmountInitial = vars.isNewPair ? initParams.initialEth : vars.wethAmount;

        if (vars.isNewPair) {
            // only for the first time
            vars.actualTokenAmount = GoatLibrary.getActualBootstrapTokenAmount(
                initParams.virtualEth, initParams.bootstrapEth, vars.wethAmountInitial, initParams.initialTokenMatch
            );
        } else {
            vars.actualTokenAmount = vars.tokenAmount;
        }
        if (msg.value != vars.wethAmountInitial) {
            revert GoatErrors.InvalidEthAmount();
        }
        vars.pair = GoatV1Factory(FACTORY).getPool(vars.token);
        IERC20(token).safeTransferFrom(msg.sender, vars.pair, vars.actualTokenAmount);
        if (vars.wethAmountInitial != 0) {
            IWETH(WETH).deposit{value: vars.wethAmountInitial}();
            IERC20(WETH).safeTransfer(vars.pair, vars.wethAmountInitial);
        }

        vars.liquidity = GoatV1Pair(vars.pair).mint(to);
        // refund dust eth, if any
        //TODO: check for any revert from external call
        if (msg.value > vars.wethAmount) {
            (bool success,) = payable(msg.sender).call{value: msg.value - vars.wethAmount}("");
            if (!success) {
                revert GoatErrors.EthTransferFailed();
            }
        }
        return (vars.tokenAmount, vars.wethAmount, vars.liquidity);
    }

    function removeLiquidity(
        address token,
        uint256 liquidity,
        uint256 tokenMin,
        uint256 wethMin,
        address to,
        uint256 deadline
    ) public nonReentrant ensure(deadline) returns (uint256 amountWeth, uint256 amountToken) {
        // This function is fairly simple, we just need to transfer the liquidity to the pair and call burn
        address pair = GoatV1Factory(FACTORY).getPool(token);

        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity); // send liquidity directly to pair
        (uint256 tokenAmount0, uint256 wethAmount0) = GoatV1Pair(pair).burn(to);

        (amountWeth, amountToken) = (tokenAmount0, wethAmount0); // we know we are always going to create a pair with token:WETH so token0 is always token and token1 is always WETH
        if (amountWeth < wethMin) {
            revert GoatErrors.InsufficientWethAmount();
        }
        if (amountToken < tokenMin) {
            revert GoatErrors.InsufficientTokenAmount();
        }
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 tokenMin,
        uint256 ethMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountWeth, uint256 amountToken) {
        (amountWeth, amountToken) = removeLiquidity(token, liquidity, tokenMin, ethMin, address(this), deadline);
        IERC20(token).safeTransfer(to, amountToken);
        IWETH(WETH).withdraw(amountWeth);
        (bool success,) = to.call{value: amountWeth}("");
        if (!success) {
            revert GoatErrors.EthTransferFailed();
        }
    }

    /* ----------------------------- SWAP FUNCTIONS ----------------------------- */
    function swapWethForExactTokens(uint256 amountIn, uint256 amountOutMin, address token, address to, uint256 deadline)
        external
        ensure(deadline)
        returns (uint256 amountTokenOut)
    {
        if (amountIn == 0) {
            revert GoatErrors.InsufficientInputAmount();
        }
        GoatTypes.LocalVariables_PairStateInfo memory vars;
        GoatV1Pair pair = GoatV1Pair(GoatV1Factory(FACTORY).getPool(token));

        if (pair == GoatV1Pair(address(0))) {
            revert GoatErrors.GoatPoolDoesNotExist();
        }

        if (pair.vestingUntil() != type(uint32).max) {
            (uint112 reserveEth, uint112 reserveToken) = pair.getStateInfoAmm();
            amountTokenOut = GoatLibrary.getTokenAmountOutAmm(amountIn, reserveEth, reserveToken);
        } else {
            (
                vars.reserveEth,
                vars.reserveToken,
                vars.virtualEth,
                vars.initialTokenMatch,
                vars.bootstrapEth,
                vars.virtualToken
            ) = pair.getStateInfoForPresale();

            uint256 tokenAmountForAmm =
                GoatLibrary._getTokenAmountForAmm(vars.virtualEth, vars.bootstrapEth, vars.initialTokenMatch);
            amountTokenOut = GoatLibrary.getTokenAmountOutPresale(
                amountIn,
                vars.virtualEth,
                vars.reserveEth,
                vars.bootstrapEth,
                vars.reserveToken,
                vars.virtualToken,
                tokenAmountForAmm
            );
        }
        if (amountTokenOut < amountOutMin) {
            revert GoatErrors.InsufficientAmountOut();
        }
        IERC20(WETH).safeTransferFrom(msg.sender, address(pair), amountIn);
        pair.swap(amountTokenOut, 0, to);
    }

    function swapExactETHForTokens(uint256 amountOutMin, address token, address to, uint256 deadline)
        external
        payable
        ensure(deadline)
        nonReentrant
        returns (uint256 amountTokenOut)
    {
        if (msg.value == 0) {
            revert GoatErrors.InsufficientInputAmount();
        }
        GoatTypes.LocalVariables_PairStateInfo memory vars;
        GoatV1Pair pair = GoatV1Pair(GoatV1Factory(FACTORY).getPool(token));
        if (pair == GoatV1Pair(address(0))) {
            revert GoatErrors.GoatPoolDoesNotExist();
        }
        if (pair.vestingUntil() != type(uint32).max) {
            (uint112 reserveEth, uint112 reserveToken) = pair.getStateInfoAmm();
            amountTokenOut = GoatLibrary.getTokenAmountOutAmm(msg.value, reserveEth, reserveToken);
        } else {
            (
                vars.reserveEth,
                vars.reserveToken,
                vars.virtualEth,
                vars.initialTokenMatch,
                vars.bootstrapEth,
                vars.virtualToken
            ) = pair.getStateInfoForPresale();

            uint256 tokenAmountForAmm =
                GoatLibrary._getTokenAmountForAmm(vars.virtualEth, vars.bootstrapEth, vars.initialTokenMatch);
            amountTokenOut = GoatLibrary.getTokenAmountOutPresale(
                msg.value,
                vars.virtualEth,
                vars.reserveEth,
                vars.bootstrapEth,
                vars.reserveToken,
                vars.virtualToken,
                tokenAmountForAmm
            );
        }

        if (amountTokenOut < amountOutMin) {
            revert GoatErrors.InsufficientAmountOut();
        }
        IWETH(WETH).deposit{value: msg.value}();
        IERC20(WETH).safeTransfer(address(pair), msg.value);
        pair.swap(amountTokenOut, 0, to);
    }

    function swapExactTokensForWeth(uint256 amountIn, uint256 amountOutMin, address token, address to, uint256 deadline)
        public
        ensure(deadline)
        nonReentrant
        returns (uint256 amountWethOut)
    {
        if (amountIn == 0) {
            revert GoatErrors.InsufficientInputAmount();
        }

        GoatTypes.LocalVariables_PairStateInfo memory vars;
        GoatV1Pair pair = GoatV1Pair(GoatV1Factory(FACTORY).getPool(token));
        if (pair == GoatV1Pair(address(0))) {
            revert GoatErrors.GoatPoolDoesNotExist();
        }
        if (pair.vestingUntil() != type(uint32).max) {
            (uint112 reserveEth, uint112 reserveToken) = pair.getStateInfoAmm();
            amountWethOut = GoatLibrary.getWethAmountOutAmm(amountIn, reserveEth, reserveToken);
        } else {
            (vars.reserveEth, vars.reserveToken, vars.virtualEth,,, vars.virtualToken) = pair.getStateInfoForPresale();

            amountWethOut = GoatLibrary.getWethAmountOutPresale(
                amountIn, vars.reserveEth, vars.reserveToken, vars.virtualEth, vars.virtualToken
            );
        }

        if (amountWethOut < amountOutMin) {
            revert GoatErrors.InsufficientAmountOut();
        }
        IERC20(token).safeTransferFrom(msg.sender, address(pair), amountIn);
        pair.swap(0, amountWethOut, to);
    }

    function withdrawFees(address token, address to) external nonReentrant {
        if (to == address(0)) {
            revert GoatErrors.ZeroAddress();
        }

        GoatV1Pair pair = GoatV1Pair(GoatV1Factory(FACTORY).getPool(token));

        if (pair == GoatV1Pair(address(0))) {
            revert GoatErrors.GoatPoolDoesNotExist();
        }
        pair.withdrawFees(to);
    }

    /* ----------------------------- view FUNCTIONS ----------------------------- */

    function getActualAmountNeeded(
        uint256 virtualEth,
        uint256 bootstrapEth,
        uint256 initialEth,
        uint256 initialTokenMatch
    ) public view returns (uint256 actualTokenAmount) {
        return GoatLibrary.getActualBootstrapTokenAmount(virtualEth, bootstrapEth, initialEth, initialTokenMatch);
    }
}
