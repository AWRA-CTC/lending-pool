// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract CreditScore {
    address public lendingPool;

    mapping(address => int256) private scores;

    int256 public constant MAX_SCORE = 100;
    int256 public constant MIN_SCORE = 0;

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "Not lending pool");
        _;
    }

    constructor() {
        lendingPool = msg.sender;
    }

    function setLendingPool(address _lendingPool) external {
        require(lendingPool == msg.sender || lendingPool == address(0), "Not authorized");
        lendingPool = _lendingPool;
    }

    function getScore(address user) external view returns (int256) {
        return scores[user];
    }

    function increaseScore(address user, int256 amount) external onlyLendingPool {
        scores[user] += amount;
        if (scores[user] > MAX_SCORE) {
            scores[user] = MAX_SCORE;
        }
    }

    function decreaseScore(address user, int256 amount) external onlyLendingPool {
        scores[user] -= amount;
        if (scores[user] < MIN_SCORE) {
            scores[user] = MIN_SCORE;
        }
    }
}
