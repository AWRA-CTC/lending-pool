// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ICreditScore.sol";
import "./interfaces/IPriceOracle.sol";
import "./LendToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LendingPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 10000;

    ICreditScore public creditScore;
    IPriceOracle public oracle;

    uint256 public loanCounter;

    // -----------------------------
    // STRUCTS
    // -----------------------------

    struct AssetConfig {
        bool isActive;
        uint256 collateralRatio;
        uint256 liquidationRatio;
        uint256 baseAPR;
        uint256 aprFloor;
        uint256 liquidationBonus;
        address lendToken;
        bool canBeCollateral;
        bool canBeBorrowed;
    }

    struct Loan {
        address borrower;
        address collateralAsset;
        address borrowAsset;
        uint256 principal;
        uint256 collateral;
        uint256 apr;
        uint256 startTime;
        bool active;
    }

    struct AssetBalance {
        uint256 totalBorrowed;
        uint256 totalInterestEarned;
    }

    mapping(address => AssetConfig) public assetConfigs;
    mapping(address => AssetBalance) public assetBalances;
    mapping(uint256 => Loan) public loans;
    mapping(address => uint256[]) public userLoans;

    address[] public supportedAssets;

    constructor(address _creditScore, address _oracle) Ownable(msg.sender) {
        creditScore = ICreditScore(_creditScore);
        oracle = IPriceOracle(_oracle);
    }

    // --------------------------------------------------
    // ---------------- LENDING -------------------------
    // --------------------------------------------------

    function deposit(
        address asset,
        uint256 amount
    ) external payable nonReentrant {
        AssetConfig memory config = assetConfigs[asset];
        require(config.isActive, "Asset not supported");

        uint256 depositAmount;

        if (asset == address(0)) {
            depositAmount = msg.value;
        } else {
            require(msg.value == 0, "No native token");
            depositAmount = amount;
            IERC20(asset).safeTransferFrom(
                msg.sender,
                address(this),
                depositAmount
            );
        }

        uint256 exchangeRate = _getExchangeRate(asset);
        uint256 mintAmount = (depositAmount * 1e18) / exchangeRate;

        LendToken(config.lendToken).mint(msg.sender, mintAmount);
    }

    function withdraw(
        address asset,
        uint256 aTokenAmount
    ) external nonReentrant {
        AssetConfig memory config = assetConfigs[asset];
        require(config.isActive, "Not supported");

        LendToken lendToken = LendToken(config.lendToken);

        uint256 exchangeRate = _getExchangeRate(asset);
        uint256 withdrawAmount = (aTokenAmount * exchangeRate) / 1e18;

        require(
            withdrawAmount <= _availableLiquidity(asset),
            "Insufficient liquidity"
        );

        lendToken.burn(msg.sender, aTokenAmount);

        if (asset == address(0)) {
            payable(msg.sender).transfer(withdrawAmount);
        } else {
            IERC20(asset).safeTransfer(msg.sender, withdrawAmount);
        }
    }

    // --------------------------------------------------
    // ---------------- BORROW --------------------------
    // --------------------------------------------------

    function borrow(
        address collateralAsset,
        address borrowAsset,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) external payable nonReentrant {
        AssetConfig memory colConfig = assetConfigs[collateralAsset];
        AssetConfig memory borConfig = assetConfigs[borrowAsset];

        require(
            colConfig.isActive && colConfig.canBeCollateral,
            "Invalid collateral"
        );
        require(
            borConfig.isActive && borConfig.canBeBorrowed,
            "Invalid borrow asset"
        );

        uint256 actualCollateral;

        if (collateralAsset == address(0)) {
            actualCollateral = msg.value;
        } else {
            require(msg.value == 0, "No native token");
            actualCollateral = collateralAmount;
            IERC20(collateralAsset).safeTransferFrom(
                msg.sender,
                address(this),
                actualCollateral
            );
        }

        uint256 collateralValue = _getAssetValue(
            collateralAsset,
            actualCollateral
        );

        uint256 maxBorrowValue = (collateralValue * BASIS_POINTS) /
            colConfig.collateralRatio;

        uint256 borrowValue = _getAssetValue(borrowAsset, borrowAmount);

        require(borrowValue <= maxBorrowValue, "Exceeds borrow limit");
        require(
            borrowAmount <= _availableLiquidity(borrowAsset),
            "Insufficient liquidity"
        );

        uint256 apr = _calculateAPR(msg.sender, borrowAsset);

        loans[++loanCounter] = Loan({
            borrower: msg.sender,
            collateralAsset: collateralAsset,
            borrowAsset: borrowAsset,
            principal: borrowAmount,
            collateral: actualCollateral,
            apr: apr,
            startTime: block.timestamp,
            active: true
        });

        userLoans[msg.sender].push(loanCounter);

        assetBalances[borrowAsset].totalBorrowed += borrowAmount;

        if (borrowAsset == address(0)) {
            payable(msg.sender).transfer(borrowAmount);
        } else {
            IERC20(borrowAsset).safeTransfer(msg.sender, borrowAmount);
        }
    }

    // --------------------------------------------------
    // ---------------- REPAY ---------------------------
    // --------------------------------------------------

    function repay(
        uint256 loanId,
        uint256 repayAmount
    ) external payable nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.active, "Inactive loan");
        require(msg.sender == loan.borrower, "Not borrower");

        uint256 interest = _interestOwed(loan);
        uint256 totalOwed = loan.principal + interest;

        uint256 payment;

        if (loan.borrowAsset == address(0)) {
            payment = msg.value;
        } else {
            payment = repayAmount;
            IERC20(loan.borrowAsset).safeTransferFrom(
                msg.sender,
                address(this),
                payment
            );
        }

        require(payment > 0, "No payment");

        if (payment >= totalOwed) {
            // full repayment
            loan.active = false;
            assetBalances[loan.borrowAsset].totalBorrowed -= loan.principal;
            assetBalances[loan.borrowAsset].totalInterestEarned += interest;

            _returnCollateral(loan);
            // attempt to update credit score; if creditScore is not set properly this may revert
            creditScore.increaseScore(msg.sender, 10);
        } else {
            // partial repayment
            loan.principal = totalOwed - payment;
            loan.startTime = block.timestamp;
        }
    }

    // --------------------------------------------------
    // ---------------- LIQUIDATION ---------------------
    // --------------------------------------------------

    function liquidate(uint256 loanId) external payable nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.active, "Inactive");

        uint256 interest = _interestOwed(loan);
        uint256 totalDebt = loan.principal + interest;

        uint256 collateralValue = _getAssetValue(
            loan.collateralAsset,
            loan.collateral
        );
        uint256 debtValue = _getAssetValue(loan.borrowAsset, totalDebt);

        AssetConfig memory config = assetConfigs[loan.collateralAsset];

        uint256 ratio = (collateralValue * BASIS_POINTS) / debtValue;

        require(ratio < config.liquidationRatio, "Healthy loan");

        // liquidator repays full debt
        if (loan.borrowAsset == address(0)) {
            require(msg.value >= totalDebt, "Insufficient repay");
        } else {
            IERC20(loan.borrowAsset).safeTransferFrom(
                msg.sender,
                address(this),
                totalDebt
            );
        }

        loan.active = false;

        assetBalances[loan.borrowAsset].totalBorrowed -= loan.principal;
        assetBalances[loan.borrowAsset].totalInterestEarned += interest;

        uint256 bonusCollateral = (loan.collateral *
            (BASIS_POINTS + config.liquidationBonus)) / BASIS_POINTS;

        uint256 seized = bonusCollateral > loan.collateral
            ? loan.collateral
            : bonusCollateral;

        if (loan.collateralAsset == address(0)) {
            payable(msg.sender).transfer(seized);
        } else {
            IERC20(loan.collateralAsset).safeTransfer(msg.sender, seized);
        }

        creditScore.decreaseScore(loan.borrower, 30);
    }

    // --------------------------------------------------
    // ---------------- INTERNALS -----------------------
    // --------------------------------------------------

    function _calculateAPR(
        address user,
        address asset
    ) internal view returns (uint256) {
        AssetConfig memory config = assetConfigs[asset];
        int256 score = creditScore.getScore(user);

        int256 discount = score * 50; // 0.5% per point
        int256 apr = int256(config.baseAPR) - discount;

        if (apr < int256(config.aprFloor)) {
            apr = int256(config.aprFloor);
        }

        return uint256(apr);
    }

    function _interestOwed(Loan memory loan) internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp - loan.startTime;
        return
            (loan.principal * loan.apr * timeElapsed) /
            (365 days * BASIS_POINTS);
    }

    function _getAssetValue(
        address asset,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 price = oracle.getPrice(asset);
        uint8 decimals = oracle.getDecimals(asset);
        return (amount * price) / (10 ** decimals);
    }

    function _getExchangeRate(address asset) internal view returns (uint256) {
        AssetConfig memory config = assetConfigs[asset];
        LendToken lendToken = LendToken(config.lendToken);

        uint256 cash = _availableLiquidity(asset);
        uint256 borrows = assetBalances[asset].totalBorrowed;

        if (lendToken.totalSupply() == 0) return 1e18;

        return ((cash + borrows) * 1e18) / lendToken.totalSupply();
    }

    function _availableLiquidity(
        address asset
    ) internal view returns (uint256) {
        if (asset == address(0)) {
            return address(this).balance;
        }
        return IERC20(asset).balanceOf(address(this));
    }

    function _returnCollateral(Loan memory loan) internal {
        if (loan.collateralAsset == address(0)) {
            payable(loan.borrower).transfer(loan.collateral);
        } else {
            IERC20(loan.collateralAsset).safeTransfer(
                loan.borrower,
                loan.collateral
            );
        }
    }

    receive() external payable {}

    // ---------------------------
    // Admin / helpers
    // ---------------------------

    function addAsset(
        address asset,
        uint256 collateralRatio,
        uint256 liquidationRatio,
        uint256 baseAPR,
        uint256 aprFloor,
        uint256 liquidationBonus,
        uint256 /* placeholder for legacy arg */,
        bool canBeCollateral,
        bool canBeBorrowed
    ) external onlyOwner {
        LendToken aToken = new LendToken();

        assetConfigs[asset] = AssetConfig({
            isActive: true,
            collateralRatio: collateralRatio,
            liquidationRatio: liquidationRatio,
            baseAPR: baseAPR,
            aprFloor: aprFloor,
            liquidationBonus: liquidationBonus,
            lendToken: address(aToken),
            canBeCollateral: canBeCollateral,
            canBeBorrowed: canBeBorrowed
        });

        supportedAssets.push(asset);
    }

    // Public wrappers to expose internals for testing
    function availableLiquidity(address asset) external view returns (uint256) {
        return _availableLiquidity(asset);
    }

    function getExchangeRate(address asset) external view returns (uint256) {
        return _getExchangeRate(asset);
    }

    function interestOwed(uint256 loanId) external view returns (uint256) {
        return _interestOwed(loans[loanId]);
    }

    function assetValue(
        address asset,
        uint256 amount
    ) external view returns (uint256) {
        return _getAssetValue(asset, amount);
    }
}
