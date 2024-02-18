// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./GoatV1Pair.sol";
import "../library/GoatTypes.sol";

contract GoatV1Factory {
    address public immutable weth;
    string private baseName;
    address public treasury;
    address public pendingTreasury;
    mapping(address => address) public pools;
    uint256 public minimumCollectableFees = 0.1 ether;

    event PairCreated(address indexed token, address pair, uint256);

    constructor(address _weth) {
        weth = _weth;
        baseName = IERC20Metadata(_weth).name();
    }

    function createPair(address token, GoatTypes.InitParams memory params) external returns (address) {
        bytes32 _salt = keccak256(abi.encodePacked(token, weth));
        GoatV1Pair pair = new GoatV1Pair{ salt: _salt }();
        pair.initialize(token, weth, baseName, params);
        pools[token] = address(pair);
        return address(pair);
    }

    function getPool(address token) external view returns (address) {
        return pools[token];
    }

    function setTreasury(address _pendingTreasury) external {
        require(msg.sender == treasury, "GoatV1Factory: FORBIDDEN");
        pendingTreasury = _pendingTreasury;
    }

    function acceptTreasury() external {
        require(msg.sender == pendingTreasury, "GoatV1Factory: FORBIDDEN");
        pendingTreasury = address(0);
        treasury = msg.sender;
    }

    function setFeeToTreasury(uint256 _minimumCollectibleFees) external {
        require(msg.sender == treasury, "GoatV1Factory: FORBIDDEN");
        minimumCollectableFees = _minimumCollectibleFees;
    }
}
