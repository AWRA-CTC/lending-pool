// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface ICreditScore {
    /// @notice Called by tests / setup to give the credit contract the pool address
    function setLendingPool(address _pool) external;

    /// @notice Return the credit score of `user`. Higher = better.
    function getScore(address user) external view returns (int256);

    /// @notice Increase `user` score by `amount`. Callable by lending pool.
    function increaseScore(address user, int256 amount) external;

    /// @notice Decrease `user` score by `amount`. Callable by lending pool.
    function decreaseScore(address user, int256 amount) external;
}
