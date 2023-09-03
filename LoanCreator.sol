// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "https://github.com/abdk-consulting/abdk-libraries-solidity/blob/master/ABDKMath64x64.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";


/// @title A simple loan platform
/// @author Daniel Kashepava
/// @notice Submit loan requests or provide funds for someone else's!
/// @dev Not actually audited, use only on testnet
contract LoanCreator {

    // Length of a base-10 Ethereum address, for key generation
    uint256 constant addressLength = 10**49;

    event BorrowEvent(uint256 creationTime, uint256 expirationTime, uint256 interest, uint256 value, address borrower, address guarantor);
    event RepayEvent(uint256 time, uint256 value, uint256 newValue, address borrower);
    event LoanRequestEvent(uint256 creationTime, uint8 interest, uint256 term, uint256 value, address borrower);
    event LiquidationEvent(uint256 time, uint256 value, address borrower);

    struct Loan {
        uint8 interest;
        uint256 value;
        uint256 time;
        address guarantor;
    }

    /// @notice Mapping of loans
    /// @dev Key is creation address + timestamp 
    mapping (uint256 => Loan) public loans;

    /// @notice Mapping of loan requests
    mapping (address => Loan) public loanRequests;

    /// @notice Borrower's credit score
    mapping (address => int256) public credit;

    /// @notice Gets value after interest of a loan for a given term
    /// @param _interest Annual interest rate as a percent
    /// @param _term Duration of loan, in seconds
    /// @param _value Initial value of loan
    /// @return uint256 Loan value at the end of the term
    function getFinalValue(uint8 _interest, uint256 _term, uint256 _value) public pure returns(uint256) {
        return ABDKMath64x64.mulu(ABDKMath64x64.exp(ABDKMath64x64.mul(ABDKMath64x64.divu(_interest, 100), ABDKMath64x64.divu(_term, 365 days))), _value);
    }

    /// @notice Gets value of loan at current time
    /// @param  _loanKey Mapping key for loan
    /// @return uint256 Loan value at current time
    function getLoanInterestValue(uint256 _loanKey) public view returns(uint256) {
        Loan storage loan = loans[_loanKey];
        require(loan.value > 0, "Loan does not exist!");
        uint256 term = block.timestamp - (_loanKey / addressLength);
        return getFinalValue(loan.interest, term, loan.value);
    }

    /// Returns reduction in principal when a certain fraction of a loan is repaid. Used for partial loan repayment
    function _getLoanPartPrincipal(uint256 _partPaid, uint256 _interestValue, uint256 _originalValue) private pure returns(uint256) {
        return ABDKMath64x64.toUInt(ABDKMath64x64.div(ABDKMath64x64.fromUInt(_partPaid), ABDKMath64x64.divu(_interestValue, _originalValue)));
    }

    /// @notice Returns if given loan is expired
    /// @param _loanKey Mapping key of loan
    /// @return bool Whether loan is expired
    function isLoanExpired(uint256 _loanKey) public view returns(bool) {
        require(loans[_loanKey].guarantor != address(0), "Loan does not exist or is not active!");
        return (loans[_loanKey].time < block.timestamp);
    }

    /// @notice Deletes sender's loan request
    function loanRequestDelete() external {
        require(loanRequests[msg.sender].value != 0, "You have no loan request to remove.");

        delete loanRequests[msg.sender];
    }

    /// @notice Creates a loan request
    /// @param _interest Annual interest rate as a percent
    /// @param _term Duration of loan, in seconds
    /// @param _value Initial value of loan
    function loanRequest(uint8 _interest, uint256 _term, uint256 _value) external {
        require(_value > 0, "Request must be a non-zero value");
        require(loanRequests[msg.sender].value == 0, "Please remove this loan request before requesting another.");

        loanRequests[msg.sender] = Loan(_interest, _value, _term, address(0));

        emit LoanRequestEvent(block.timestamp, _interest, _term, _value, msg.sender);
    }

    /// @notice Sender guarantees _borrower's loan request by depositing the maximum repayment amount
    /// @param  _borrower Address of user who made a loan request
    /// @return uint256 Mapping key of new loan
    function guaranteeLoan(address _borrower) external payable returns(uint256) {
        require(msg.value > 0, "Please submit a guarantee for the loan");
        require(loanRequests[_borrower].value != 0, "Borrower must have a loan request!");
        require(loanRequests[_borrower].guarantor == address(0), "Loan should not be active!");
        require(msg.value == getFinalValue(loanRequests[_borrower].interest, loanRequests[_borrower].time, loanRequests[_borrower].value), "Guarantee deposit must be final amount with interest!");

        uint256 key = (block.timestamp * addressLength) + uint256(uint160(_borrower));
        loans[key] = loanRequests[_borrower];
        delete loanRequests[_borrower];
        loans[key].time += block.timestamp;
        loans[key].guarantor = msg.sender;

        (bool success, ) = _borrower.call{value:loans[key].value}("");
        require(success, "Borrow failed!");

        emit BorrowEvent(block.timestamp, loans[key].time, loans[key].interest, loans[key].value, _borrower, msg.sender);

        return key;
    }

    /// @notice Handles loan repayment
    /// @param _loanKey Mapping key of loan
    function repay(uint256 _loanKey) external payable {
        require(msg.value > 0, "Please submit a payment.");
        require(!isLoanExpired(_loanKey), "Loan expired! Please use liquidate()");

        uint256 loanValue = loans[_loanKey].value;
        address guarantor = loans[_loanKey].guarantor;
        uint256 interestValue = getLoanInterestValue(_loanKey);
        uint256 loanPartPrincipal;
        if (msg.value >= interestValue) {
            loanPartPrincipal = loans[_loanKey].value;
            uint256 finalValue = getFinalValue(loans[_loanKey].interest, loans[_loanKey].time - (_loanKey / addressLength), loanValue);
            delete loans[_loanKey];

            (bool success, ) = guarantor.call{value:(finalValue + interestValue - loanPartPrincipal)}("");
            require(success, "Transfer to guarantor failed!");
        } else {
            loanPartPrincipal = _getLoanPartPrincipal(msg.value, interestValue, loanValue);
            loans[_loanKey].value -= loanPartPrincipal;

            (bool success, ) = guarantor.call{value:(msg.value * 2 - loanPartPrincipal)}("");
            require(success, "Transfer to guarantor failed!");
        }
        credit[msg.sender] += int256(msg.value);

        emit RepayEvent(block.timestamp, msg.value, loanValue -= loanPartPrincipal, msg.sender);
    }

    /// @notice Liquidates value of loan and gives reward to liquidator
    /// @param _loanKey Mapping key of loan
    function liquidate(uint256 _loanKey) external {
        require(isLoanExpired(_loanKey), "This loan has not yet expired.");
        address debtorAddress = address(uint160(_loanKey % addressLength));

        uint256 loanValue = loans[_loanKey].value;
        credit[debtorAddress] -= int256(loanValue);
        uint256 finalInterest = getFinalValue(loans[_loanKey].interest, loans[_loanKey].time - (_loanKey / addressLength), loanValue) - loanValue;
        delete loans[_loanKey];

        (bool success, ) = msg.sender.call{value:finalInterest}("");
        require(success, "Compensation failed!");

        emit LiquidationEvent(block.timestamp, loanValue, debtorAddress);
    }
}