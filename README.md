# LoanCreator
## Overview
A simple loan protocol for Ether with collateral submitted by a third-party "guarantor". It is deployed to the Sepolia Testnet here: [0x90Ebfccef2AB1f8418e12455dB60a22E8C90281f](https://sepolia.etherscan.io/address/0x90ebfccef2ab1f8418e12455db60a22e8c90281f).

## How to Use
### dApp Front End on daniel.kashepava.com
You can access the LoanCreator with a convenient UI at [daniel.kashepava.com](http://daniel.kashepava.com/loancreator.html)! Usage instructions can be found on that page.

### Direct smart contract interaction
1. A prospective borrower must submit a loan request with the loanRequest() function. This will include specifying their desired interest rate, loan duration, and value to borrow.
1. A guarantor can now decide to submit collateral for the borrower's loan request, using the payable function guaranteeLoan().
1. The borrower must now repay their outstanding debts with the repay() function before the term of the loan is up. This can be done in one go or in several payments. You can use getLoanInterestRate() to find out how much you need to pay at the current time. The interest on the loan is sent to the guarantor as a reward.
1. Once the term of the loan is up, a third-party known as the "liquidator" can call the liquidate() function to remove the loan from memory. The liquitaor is rewarded with the guarantor's interest deposit.