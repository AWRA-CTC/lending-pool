// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LendingPool.sol";
import "../src/CreditScore.sol";
import "../src/LendToken.sol";
import "../src/interfaces/IPriceOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {console} from "forge-std/console.sol";

/// @notice Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply
    ) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock Price Oracle
contract MockOracle is IPriceOracle {
    mapping(address => uint256) public prices;

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getDecimals(address asset) external view override returns (uint8) {
        return 18;
    }

    function getPrice(address asset) external view override returns (uint256) {
        return prices[asset];
    }

    function getLastUpdated(
        address asset
    ) external view override returns (uint256) {
        return block.timestamp;
    }
}

/// @notice Test suite for LendingPool
contract LendingPoolTest is Test {
    LendingPool pool;
    CreditScore credit;
    MockOracle oracle;

    MockERC20 tokenA;
    MockERC20 tokenB;

    address user = address(1);
    address borrower = address(2);

    function setUp() public {
        // Deploy mocks
        credit = new CreditScore();
        oracle = new MockOracle();
        pool = new LendingPool(address(credit), address(oracle));

        // set lending pool in credit contract so pool can call score updates
        credit.setLendingPool(address(pool));

        // Deploy ERC20 tokens
        tokenA = new MockERC20("TokenA", "TKA", 1_000_000e18);
        tokenB = new MockERC20("TokenB", "TKB", 1_000_000e18);

        // Fund users
        tokenA.mint(user, 10_000e18);
        tokenB.mint(borrower, 10_000e18);

        // Setup oracle prices
        oracle.setPrice(address(tokenA), 1e18); // $1
        oracle.setPrice(address(tokenB), 2e18); // $2

        // Add assets to lending pool
        pool.addAsset(
            address(tokenA),
            15000,
            14000,
            1500,
            500,
            1e18,
            500,
            true,
            true
        );
        pool.addAsset(
            address(tokenB),
            15000,
            14000,
            1500,
            500,
            1e18,
            500,
            true,
            true
        );

        // Approve pool for ERC20 transfers from users
        vm.prank(user);
        tokenA.approve(address(pool), type(uint256).max);

        vm.prank(borrower);
        tokenB.approve(address(pool), type(uint256).max);

        // Provide initial tokenB liquidity from the test contract (deployer has initial supply)
        tokenB.approve(address(pool), type(uint256).max);
        pool.deposit(address(tokenB), 1000e18);
    }

    // -------------------------
    // Internal function tests
    // -------------------------
    function testAvailableLiquidity() public {
        // Initially zero for tokenA
        assertEq(pool.availableLiquidity(address(tokenA)), 0);

        // Deposit some tokens
        vm.prank(user);
        pool.deposit(address(tokenA), 100e18);

        uint256 liquidity = pool.availableLiquidity(address(tokenA));
        assertEq(liquidity, 100e18);
    }

    function testGetExchangeRate() public {
        // Initially, exchange rate = 1e18
        uint256 rate = pool.getExchangeRate(address(tokenA));
        assertEq(rate, 1e18);

        // Deposit 100 tokens
        vm.prank(user);
        pool.deposit(address(tokenA), 100e18);

        rate = pool.getExchangeRate(address(tokenA));
        assertEq(rate, 1e18);
    }

    // -------------------------
    // Lender logic tests
    // -------------------------
    function testDepositAndWithdraw() public {
        vm.startPrank(user);

        // Deposit tokenA
        pool.deposit(address(tokenA), 100e18);

        // Check aToken balance
        (, , , , , , address aTokenAddr, , ) = pool.assetConfigs(
            address(tokenA)
        );
        LendToken aToken = LendToken(aTokenAddr);
        assertEq(aToken.balanceOf(user), 100e18);

        // Withdraw 50 aTokens
        pool.withdraw(address(tokenA), 50e18);

        // aToken balance should be 50
        assertEq(aToken.balanceOf(user), 50e18);

        vm.stopPrank();
    }

    // -------------------------
    // Borrow and repay tests
    // -------------------------
    function testBorrowAndRepay() public {
        // Deposit collateral
        vm.startPrank(user);
        pool.deposit(address(tokenA), 100e18);
        vm.stopPrank();

        // Borrow
        vm.startPrank(borrower);
        tokenB.approve(address(pool), type(uint256).max);
        pool.borrow(address(tokenB), address(tokenA), 50e18, 20e18);
        vm.stopPrank();

        // Check loan data
        (, , , uint256 principal, uint256 collateral, , , bool active) = pool
            .loans(1);
        assertEq(principal, 20e18);
        assertEq(collateral, 50e18);

        // Repay loan
        vm.startPrank(borrower);
        tokenB.mint(borrower, 10_000e18); // Ensure enough funds
        tokenB.approve(address(pool), 100e18);

        uint256 interest = pool.interestOwed(1);
        tokenA.approve(address(pool), type(uint256).max);
        pool.repay(1, 20e18 + interest);
        vm.stopPrank();

        (, , , , , , , active) = pool.loans(1);
        assertEq(active, false);
    }

    function testBorrowZeroAmountReverts() public {
        vm.prank(user);
        pool.deposit(address(tokenA), 100e18);

        vm.startPrank(borrower);
        vm.expectRevert(LendingPool.BorrowAmountZero.selector);
        pool.borrow(address(tokenB), address(tokenA), 50e18, 0);
        vm.stopPrank();
    }

    function testPartialRepayUpdatesTotalBorrowed() public {
        vm.prank(user);
        pool.deposit(address(tokenA), 100e18);

        vm.prank(borrower);
        pool.borrow(address(tokenB), address(tokenA), 50e18, 20e18);

        vm.warp(block.timestamp + 365 days);

        uint256 interest = pool.interestOwed(1);
        uint256 totalOwed = 20e18 + interest;
        uint256 partialPayment = 10e18;
        assertLt(partialPayment, totalOwed);

        vm.startPrank(borrower);
        tokenA.mint(borrower, 10_000e18);
        tokenA.approve(address(pool), type(uint256).max);
        pool.repay(1, partialPayment);
        vm.stopPrank();

        (, , , uint256 newPrincipal, , , , bool activeAfterPartial) = pool
            .loans(1);
        uint256 expectedPrincipal = totalOwed - partialPayment;
        assertEq(newPrincipal, expectedPrincipal);
        assertTrue(activeAfterPartial);

        (uint256 borrowedAfterPartial, ) = pool.assetBalances(address(tokenA));
        assertEq(borrowedAfterPartial, expectedPrincipal);

        vm.prank(borrower);
        pool.repay(1, expectedPrincipal);

        (uint256 borrowedAfterFull, ) = pool.assetBalances(address(tokenA));
        assertEq(borrowedAfterFull, 0);
    }

    function testRepayOverpaymentIsRefundedForERC20() public {
        vm.prank(user);
        pool.deposit(address(tokenA), 100e18);

        vm.prank(borrower);
        pool.borrow(address(tokenB), address(tokenA), 50e18, 20e18);

        vm.startPrank(borrower);
        tokenA.mint(borrower, 10_000e18);
        tokenA.approve(address(pool), type(uint256).max);

        uint256 totalOwed = 20e18 + pool.interestOwed(1);
        uint256 overpayment = totalOwed + 5e18;
        uint256 balanceBefore = tokenA.balanceOf(borrower);

        pool.repay(1, overpayment);

        uint256 balanceAfter = tokenA.balanceOf(borrower);
        assertEq(balanceBefore - balanceAfter, totalOwed);
        vm.stopPrank();
    }

    // -------------------------
    // Liquidation test
    // -------------------------
    function testLiquidation() public {
        vm.startPrank(user);
        pool.deposit(address(tokenA), 100e18);
        vm.stopPrank();

        // Borrower borrows fully
        vm.startPrank(borrower);
        pool.borrow(address(tokenB), address(tokenA), 100e18, 50e18);
        vm.stopPrank();

        // Simulate price drop to make loan undercollateralized
        oracle.setPrice(address(tokenB), 1e8 / 2); // Collateral halves

        // Liquidate (liquidator must pay tokenB debt)
        vm.startPrank(user);
        // ensure user has tokenB to repay as liquidator
        tokenA.mint(user, 1000e18);
        tokenA.approve(address(pool), type(uint256).max);
        pool.liquidate(1);
        vm.stopPrank();

        (, , , , , , , bool active) = pool.loans(1);
        assertEq(active, false);
    }

    // -------------------------
    // Large integration test
    // -------------------------
    function testMultipleUsersDepositBorrow() public {
        address user2 = address(3);
        tokenA.mint(user2, 10_000e18);
        vm.prank(user2);
        tokenA.approve(address(pool), type(uint256).max);

        // Two deposits
        vm.prank(user);
        pool.deposit(address(tokenA), 100e18);

        vm.prank(user2);
        pool.deposit(address(tokenA), 200e18);

        uint256 totalLiquidity = pool.availableLiquidity(address(tokenA));
        assertEq(totalLiquidity, 300e18);

        // Borrower borrows 150 tokenB worth
        vm.prank(borrower);
        pool.borrow(address(tokenB), address(tokenA), 150e18, 75e18);

        (uint256 borrowTotal, ) = pool.assetBalances(address(tokenA));
        assertEq(borrowTotal, 75e18);
    }

    function test_Withdraw_WithInterest() public {
        // Step 0: record user's underlying balance
        uint256 balanceBefore = tokenA.balanceOf(user);

        // Step 1: user deposits 100 tokenA
        vm.prank(user);
        pool.deposit(address(tokenA), 100e18);

        // Step 2: borrower borrows (will generate interest)
        vm.startPrank(borrower);
        tokenB.approve(address(pool), type(uint256).max);
        pool.borrow(address(tokenB), address(tokenA), 50e18, 20e18);
        vm.stopPrank();

        // Step 3: fast forward 365 days
        vm.warp(block.timestamp + 365 days);

        // Step 4: borrower repays with interest
        vm.startPrank(borrower);
        tokenA.mint(borrower, 10_000e18); // Ensure enough funds to repay
        tokenA.approve(address(pool), type(uint256).max);
        uint256 interest = pool.interestOwed(1);
        console.log("Interest owed after 1 year:", interest / 1e18);
        pool.repay(1, 20e18 + interest);
        vm.stopPrank();

        // Step 5: exchange rate should have increased
        uint256 exchangeRate = pool.getExchangeRate(address(tokenA));
        console.log(
            "Exchange rate after interest accrual:",
            exchangeRate / 1e18
        );
        assertGt(exchangeRate, 1e18, "Exchange rate should be > 1:1");

        // Step 6: user withdraws aTokens and should end up with more tokenA than before
        (, , , , , , address aTokenAddr, , ) = pool.assetConfigs(
            address(tokenA)
        );
        LendToken aToken = LendToken(aTokenAddr);

        vm.startPrank(user);
        pool.withdraw(address(tokenA), 100e18);
        vm.stopPrank();

        uint256 balanceAfter = tokenA.balanceOf(user);
        console.log("User balance before:", balanceBefore / 1e18);
        console.log("User balance after:", balanceAfter / 1e18);

        assertGt(
            balanceAfter,
            balanceBefore,
            "User should have more underlying tokenA after interest"
        );

        assertEq(
            aToken.balanceOf(user),
            0,
            "User's aToken balance should be zero after full withdrawal"
        );
    }
}
