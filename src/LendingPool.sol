// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CreditScore.sol";
import "./IPriceOracle.sol";
import "./LendToken.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract LendingPool is ReentrancyGuard {
    struct Loan {
        address borrower;
        uint256 principal;
        uint256 collateral;
        uint256 apr; // basis points (e.g. 1000 = 10%)
        uint256 startTime;
        bool active;
    }

    CreditScore public creditScore;
    IPriceOracle public oracle;
    LendToken public lendToken;

    uint256 public constant COLLATERAL_RATIO = 150; // 150%
    uint256 public constant LIQUIDATION_RATIO = 140; // 140%
    uint256 public constant BASE_APR = 1500; // 15%
    uint256 public constant APR_FLOOR = 500; // 5%
    uint256 public constant MIN_DEPOSIT = 5 * 10**18; // Minimum deposit: 5 CTC
    uint256 public constant LIQUIDATION_BONUS = 500; // 5% (in basis points)

    uint256 public loanCounter;
    mapping(uint256 => Loan) public loans;

    // Liquidity tracking
    uint256 public totalDeposited; // Total CTC deposited by lenders
    uint256 public totalBorrowed; // Total CTC currently borrowed
    uint256 public totalInterestEarned; // Accumulated interest from borrowers

    // ----------------------------
    // EVENTS
    // ----------------------------

    event Deposit(
        address indexed user,
        uint256 amount,
        uint256 tokensReceived,
        uint256 timestamp
    );

    event Withdraw(
        address indexed user,
        uint256 tokensReturned,
        uint256 ctcReceived,
        uint256 timestamp
    );

    event Borrow(
        address indexed borrower,
        uint256 indexed loanId,
        uint256 principal,
        uint256 collateral,
        uint256 apr,
        uint256 timestamp
    );

    event Repay(
        address indexed borrower,
        uint256 indexed loanId,
        uint256 principal,
        uint256 interest,
        uint256 timestamp
    );

    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 indexed loanId,
        uint256 collateralSeized,
        uint256 reward,
        uint256 timestamp
    );

    constructor(address _creditScore, address _oracle) {
        creditScore = CreditScore(_creditScore);
        oracle = IPriceOracle(_oracle);
        lendToken = new LendToken();
    }

    // ----------------------------
    // LENDER LOGIC
    // ----------------------------

    /**
     * @notice Deposit CTC and receive aAWRA tokens
     * @dev Mints tokens based on current exchange rate
     */
    function deposit() external payable nonReentrant {
        require(msg.value >= MIN_DEPOSIT, "Below minimum deposit");

        uint256 tokensToMint;
        
        if (lendToken.totalSupply() == 0) {
            // First deposit: 1:1 ratio
            tokensToMint = msg.value;
        } else {
            // Calculate based on exchange rate
            tokensToMint = (msg.value * lendToken.totalSupply()) / _poolValue();
        }

        totalDeposited += msg.value;
        lendToken.mint(msg.sender, tokensToMint);

        emit Deposit(msg.sender, msg.value, tokensToMint, block.timestamp);
    }

    /**
     * @notice Withdraw CTC by burning aAWRA tokens
     * @param tokenAmount Amount of aAWRA tokens to burn
     */
    function withdraw(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "Amount must be > 0");
        require(lendToken.balanceOf(msg.sender) >= tokenAmount, "Insufficient balance");

        uint256 ctcToReturn = (tokenAmount * _poolValue()) / lendToken.totalSupply();
        uint256 availableLiquidity = _availableLiquidity();
        
        require(ctcToReturn <= availableLiquidity, "Insufficient liquidity");

        totalDeposited -= ctcToReturn;
        lendToken.burn(msg.sender, tokenAmount);
        
        payable(msg.sender).transfer(ctcToReturn);

        emit Withdraw(msg.sender, tokenAmount, ctcToReturn, block.timestamp);
    }

    /**
     * @notice Get current exchange rate (CTC per aAWRA token)
     * @return Exchange rate in wei (1e18 = 1:1)
     */
    function getExchangeRate() external view returns (uint256) {
        if (lendToken.totalSupply() == 0) {
            return 1e18; // 1:1 initial rate
        }
        return (_poolValue() * 1e18) / lendToken.totalSupply();
    }

    // ----------------------------
    // BORROW
    // ----------------------------

    function borrow() external payable nonReentrant {
        uint256 collateralValue = _collateralValue(msg.value);
        uint256 maxBorrow = (collateralValue * 100) / COLLATERAL_RATIO;

        require(maxBorrow > 0, "Insufficient collateral");
        
        uint256 availableLiquidity = _availableLiquidity();
        require(availableLiquidity >= maxBorrow, "Insufficient liquidity in pool");

        uint256 apr = _calculateAPR(msg.sender);

        loans[++loanCounter] = Loan({
            borrower: msg.sender,
            principal: maxBorrow,
            collateral: msg.value,
            apr: apr,
            startTime: block.timestamp,
            active: true
        });

        totalBorrowed += maxBorrow;

        payable(msg.sender).transfer(maxBorrow);

        emit Borrow(
            msg.sender,
            loanCounter,
            maxBorrow,
            msg.value,
            apr,
            block.timestamp
        );
    }

    // ----------------------------
    // REPAY
    // ----------------------------

    function repay(uint256 loanId) external payable nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.active, "Loan not active");
        require(msg.sender == loan.borrower, "Not the borrower");

        uint256 interest = _interestOwed(loan);
        uint256 totalOwed = loan.principal + interest;

        require(msg.value >= totalOwed, "Insufficient repayment");

        loan.active = false;

        // Add interest to pool earnings (lenders profit!)
        totalInterestEarned += interest;
        totalBorrowed -= loan.principal;

        // Reward good behavior
        creditScore.increaseScore(msg.sender, 10);

        // Return collateral
        payable(msg.sender).transfer(loan.collateral);

        // Refund excess payment
        if (msg.value > totalOwed) {
            payable(msg.sender).transfer(msg.value - totalOwed);
        }

        emit Repay(
            msg.sender,
            loanId,
            loan.principal,
            interest,
            block.timestamp
        );
    }

    // ----------------------------
    // LIQUIDATION
    // ----------------------------

    function liquidate(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.active, "Loan not active");

        uint256 collateralValue = _collateralValue(loan.collateral);
        uint256 interest = _interestOwed(loan);
        uint256 loanValue = loan.principal + interest;

        uint256 ratio = (collateralValue * 100) / loanValue;
        require(ratio < LIQUIDATION_RATIO, "Loan not liquidatable");

        loan.active = false;
        totalBorrowed -= loan.principal;

        // Punish bad behavior
        creditScore.decreaseScore(loan.borrower, 30);

        // Calculate liquidator reward (5% of collateral)
        uint256 liquidatorReward = (loan.collateral * LIQUIDATION_BONUS) / 10000;
        uint256 protocolShare = loan.collateral - liquidatorReward;

        // Liquidator gets bonus
        payable(msg.sender).transfer(liquidatorReward);

        // Rest stays in pool as profit for lenders
        totalInterestEarned += protocolShare;

        emit Liquidate(
            msg.sender,
            loan.borrower,
            loanId,
            loan.collateral,
            liquidatorReward,
            block.timestamp
        );
    }

    // ----------------------------
    // INTERNAL LOGIC
    // ----------------------------

    function _calculateAPR(address user) internal view returns (uint256) {
        int256 score = creditScore.getScore(user);
        int256 discount = score * 50; // 0.5% per credit point

        int256 apr = int256(BASE_APR) - discount;

        if (apr < int256(APR_FLOOR)) {
            apr = int256(APR_FLOOR);
        }

        return uint256(apr);
    }

    function _interestOwed(Loan memory loan) internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp - loan.startTime;
        return (loan.principal * loan.apr * timeElapsed) / (365 days * 10000);
    }

    function _collateralValue(uint256 amount) internal view returns (uint256) {
        uint256 price = oracle.getPrice(address(0)); // native token
        return (amount * price) / 1e8;
    }

    /**
     * @notice Total value of pool (deposits + interest earned)
     */
    function _poolValue() internal view returns (uint256) {
        return totalDeposited + totalInterestEarned;
    }

    /**
     * @notice Available liquidity for borrowing
     */
    function _availableLiquidity() internal view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Calculate pool utilization rate (0-10000 basis points)
     */
    function getUtilizationRate() external view returns (uint256) {
        uint256 totalLiquidity = totalBorrowed + _availableLiquidity();
        if (totalLiquidity == 0) return 0;
        return (totalBorrowed * 10000) / totalLiquidity;
    }
}
