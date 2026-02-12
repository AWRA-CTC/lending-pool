// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CreditScore.sol";
import "./IPriceOracle.sol";

contract LendingPool {
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

    uint256 public constant COLLATERAL_RATIO = 150; // 150%
    uint256 public constant LIQUIDATION_RATIO = 140; // 140%
    uint256 public constant BASE_APR = 1500; // 15%
    uint256 public constant APR_FLOOR = 500; // 5%

    uint256 public loanCounter;
    mapping(uint256 => Loan) public loans;

    constructor(address _creditScore, address _oracle) {
        creditScore = CreditScore(_creditScore);
        oracle = IPriceOracle(_oracle);
    }

    // ----------------------------
    // LENDER LOGIC (minimal)
    // ----------------------------

    receive() external payable {}

    // ----------------------------
    // BORROW
    // ----------------------------

    function borrow() external payable {
        uint256 collateralValue = _collateralValue(msg.value);
        uint256 maxBorrow = (collateralValue * 100) / COLLATERAL_RATIO;

        require(maxBorrow > 0, "Insufficient collateral");
        require(address(this).balance >= maxBorrow, "No liquidity");

        uint256 apr = _calculateAPR(msg.sender);

        loans[++loanCounter] = Loan({
            borrower: msg.sender,
            principal: maxBorrow,
            collateral: msg.value,
            apr: apr,
            startTime: block.timestamp,
            active: true
        });

        payable(msg.sender).transfer(maxBorrow);
    }

    // ----------------------------
    // REPAY
    // ----------------------------

    function repay(uint256 loanId) external payable {
        Loan storage loan = loans[loanId];
        require(loan.active, "Loan inactive");
        require(msg.sender == loan.borrower, "Not borrower");

        uint256 interest = _interestOwed(loan);
        uint256 totalOwed = loan.principal + interest;

        require(msg.value >= totalOwed, "Insufficient repayment");

        loan.active = false;

        // reward good behavior
        creditScore.increaseScore(msg.sender, 10);

        // return collateral
        payable(msg.sender).transfer(loan.collateral);
    }

    // ----------------------------
    // LIQUIDATION
    // ----------------------------

    function liquidate(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(loan.active, "Loan inactive");

        uint256 collateralValue = _collateralValue(loan.collateral);
        uint256 loanValue = loan.principal;

        uint256 ratio = (collateralValue * 100) / loanValue;
        require(ratio < LIQUIDATION_RATIO, "Not liquidatable");

        loan.active = false;

        // punish bad behavior
        creditScore.decreaseScore(loan.borrower, 30);

        // collateral stays in pool (simplified)
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
}
