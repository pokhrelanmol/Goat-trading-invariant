// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {GoatV1Pair} from "../../contracts/exchange/GoatV1Pair.sol";
import {GoatV1Factory} from "../../contracts/exchange/GoatV1Factory.sol";
import {GoatV1Router} from "../../contracts/periphery/GoatRouterV1.sol";
import {GoatV1ERC20} from "../../contracts/exchange/GoatV1ERC20.sol";
import {MockWETH} from "../../contracts/mock/MockWETH.sol";
import {MockERC20} from "../../contracts/mock/MockERC20.sol";
import {GoatTypes} from "../../contracts/library/GoatTypes.sol";

abstract contract BaseTest is Test {
    GoatV1Pair public pair;
    GoatV1Factory public factory;
    GoatV1Router public router;
    GoatV1ERC20 public goatToken;
    MockWETH public weth;
    MockERC20 public token;
    //     Mint weth

    struct AddLiqudityParams {
        address token;
        uint256 tokenDesired;
        uint256 wethDesired;
        uint256 tokenMin;
        uint256 wethMin;
        address to;
        uint256 deadline;
        GoatTypes.InitParams initParams;
    }

    AddLiqudityParams public addLiqParams;

    function setUp() public {
        weth = new MockWETH();
        token = new MockERC20();
        factory = new GoatV1Factory(address(weth));
        router = new GoatV1Router(address(factory), address(weth));
    }

    function addLiquidityParams(bool initial, bool sendInitWeth) public returns (AddLiqudityParams memory) {
        weth.deposit{value: 10e18}();
        if (initial) {
            /* ------------------------------- SET PARAMS ------------------------------- */
            addLiqParams.token = address(token);
            addLiqParams.tokenDesired = 0;
            addLiqParams.wethDesired = 0;
            addLiqParams.tokenMin = 0;
            addLiqParams.wethMin = 0;
            addLiqParams.to = address(this);
            addLiqParams.deadline = block.timestamp + 1000;

            addLiqParams.initParams = GoatTypes.InitParams(10e18, 10e18, sendInitWeth ? 10e18 : 0, 1000e18);
        } else {
            addLiqParams.token = address(token);
            addLiqParams.tokenDesired = 1000e18;
            addLiqParams.wethDesired = 10e18;
            addLiqParams.tokenMin = 0;
            addLiqParams.wethMin = 0;
            addLiqParams.to = address(this);
            addLiqParams.deadline = block.timestamp + 1000;

            addLiqParams.initParams = GoatTypes.InitParams(0, 0, 0, 0);
        }
        return addLiqParams;
    }
}
