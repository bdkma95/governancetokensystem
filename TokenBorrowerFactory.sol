// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./MoneyMarketInterface.sol";
import "./CDP.sol";
import "./EIP20Interface.sol";

contract TokenBorrowerFactory {
    address public wethAddress;
    MoneyMarketInterface public compoundMoneyMarket;
    EIP20Interface public token;

    mapping(address => CDP) public borrowers;

    /**
     * @dev Constructor to initialize the factory.
     * @param weth The address of the Wrapped ETH contract.
     * @param _token The address of the ERC20 token to be borrowed.
     * @param moneyMarket The address of the money market (Compound).
     */
    constructor(address weth, address _token, address moneyMarket) {
        require(weth != address(0), "Invalid WETH address");
        require(_token != address(0), "Invalid token address");
        require(moneyMarket != address(0), "Invalid money market address");

        wethAddress = weth;
        token = EIP20Interface(_token);
        compoundMoneyMarket = MoneyMarketInterface(moneyMarket);
    }

    /**
     * @notice Deploys a new CDP or adds funds to an existing one.
     * @dev The caller will receive borrowed tokens if their collateral ratio permits.
     */
    receive() external payable {
        require(msg.value > 0, "Must send ETH to fund");

        CDP cdp;
        if (address(borrowers[msg.sender]) == address(0)) {
            // Create a new CDP for the sender
            cdp = new CDP(msg.sender, address(token), wethAddress, address(compoundMoneyMarket));
            borrowers[msg.sender] = cdp;
        } else {
            // Use the existing CDP
            cdp = borrowers[msg.sender];
        }

        // Fund the CDP with the sent ETH
        cdp.fund{value: msg.value}();
    }

    /**
     * @notice Repays the user's borrow.
     * @dev The user must approve this contract to transfer the borrowed tokens.
     */
    function repay() external {
        CDP cdp = borrowers[msg.sender];
        require(address(cdp) != address(0), "No CDP exists for user");

        uint256 allowance = token.allowance(msg.sender, address(this));
        uint256 borrowBalance = compoundMoneyMarket.getBorrowBalance(address(cdp), address(token));
        uint256 userTokenBalance = token.balanceOf(msg.sender);

        uint256 transferAmount = _min(_min(allowance, borrowBalance), userTokenBalance);
        require(transferAmount > 0, "No tokens to repay");

        // Transfer tokens from user to CDP
        bool success = token.transferFrom(msg.sender, address(cdp), transferAmount);
        require(success, "Token transfer failed");

        // Repay the borrow
        cdp.repay();
    }

    /**
     * @dev Returns the borrow balance of a user.
     * @param user The address of the user.
     */
    function getBorrowBalance(address user) external view returns (uint256) {
        CDP cdp = borrowers[user];
        require(address(cdp) != address(0), "No CDP exists for user");

        return compoundMoneyMarket.getBorrowBalance(address(cdp), address(token));
    }

    /**
     * @dev Returns the supply balance of a user.
     * @param user The address of the user.
     */
    function getSupplyBalance(address user) external view returns (uint256) {
        CDP cdp = borrowers[user];
        require(address(cdp) != address(0), "No CDP exists for user");

        return compoundMoneyMarket.getSupplyBalance(address(cdp), wethAddress);
    }

    /**
     * @dev Internal function to find the minimum of two values.
     * @param a First value.
     * @param b Second value.
     */
    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
