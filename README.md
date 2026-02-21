# AWRA — Lending Pool

A lending pool built with credit score based APR system. Main contracts:

- [`LendingPool`](src/LendingPool.sol)
- [`CreditScore`](src/CreditScore.sol)
- [`LendToken`](src/LendToken.sol)

## Overview

- The pool accepts deposits, mints interest-bearing tokens (`LendToken`) to lenders, and allows borrowers to lock collateral and borrow supported assets.
- A separate credit score contract (`CreditScore`) is used to adjust borrower APRs based on their score.
- Tests live in [test/LendingPool.t.sol](test/LendingPool.t.sol). Deployment scripts live in [script/LendingPool.s.sol](script/LendingPool.s.sol) and [script/CreditScore.s.sol](script/CreditScore.s.sol).

## Key concepts

- Liquidity: lenders deposit assets into the pool; available liquidity is exposed via [`LendingPool.availableLiquidity`](src/LendingPool.sol).
- Exchange rate: lenders hold `LendToken` which represents a share of the pool. The exchange rate is computed as:

$$
\text{exchangeRate} = \frac{(\text{cash} + \text{borrows}) \cdot 10^{18}}{\text{totalSupply}}
$$

(See [`LendingPool._getExchangeRate`](src/LendingPool.sol).)

- APR calculation: borrower APR is derived from the asset's `baseAPR` and the borrower's credit score. Conceptually:

$$
\text{apr} = \max(\text{aprFloor},\ \text{baseAPR} - 0.5\%\cdot\text{score})
$$

(Implementation: [`LendingPool._calculateAPR`](src/LendingPool.sol), and score management in [`CreditScore`](src/CreditScore.sol).)

## How borrowing / repayment works (high level)

1. Borrower deposits collateral and requests a borrow. The pool checks collateral value via the oracle ([`IPriceOracle`](src/interfaces/IPriceOracle.sol)) and enforces collateral limits.
2. On successful borrow, a `Loan` entry is created and the pool transfers the borrowed asset to the borrower.
3. Interest accrues over time using the loan APR. Lenders earn interest reflected in the `LendToken` exchange rate.
4. On full repayment the loan is closed, collateral returned, interest recorded, and the borrower's credit score is increased via [`CreditScore.increaseScore`](src/CreditScore.sol).
5. On liquidation (undercollateralized loans) collateral is seized and the borrower's credit score is decreased via [`CreditScore.decreaseScore`](src/CreditScore.sol).

See loan lifecycle code in [`LendingPool.repay`](src/LendingPool.sol) and [`LendingPool.liquidate`](src/LendingPool.sol).

## Tests & local development

- Build and run tests with Foundry:

```sh
forge test
```

- Deploy locally via scripts:

```sh
forge script script/LendingPool.s.sol:DeployLendingPool --rpc-url <RPC> --broadcast
forge script script/CreditScore.s.sol:DeployCreditScore --rpc-url <RPC> --broadcast
```

```

```
