// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./EIP20Interface.sol";
import "./WrappedEtherInterface.sol";
import "./MoneyMarketInterface.sol";

contract CDP {
    uint256 constant expScale = 10**18;
    uint256 constant collateralRatioBuffer = 25 * 10**16;

    address public creator;
    address public owner;
    WrappedEtherInterface public weth;
    MoneyMarketInterface public compoundMoneyMarket;
    EIP20Interface public borrowedToken;

    event Log(uint256 value, string message);
    event LogInt(int256 value, string message);
    event Funded(address indexed funder, uint256 amount);
    event Repaid(address indexed repayer, uint256 amount);
    event TokensTransferred(address indexed to, uint256 amount);

    modifier onlyCreator() {
        require(msg.sender == creator, "CDP: Caller is not the creator");
        _;
    }

    constructor(
        address _owner,
        address tokenAddress,
        address wethAddress,
        address moneyMarketAddress
    ) {
        creator = msg.sender;
        owner = _owner;
        borrowedToken = EIP20Interface(tokenAddress);
        compoundMoneyMarket = MoneyMarketInterface(moneyMarketAddress);
        weth = WrappedEtherInterface(wethAddress);

        // Approve maximum spending for WETH and borrowed tokens
        weth.approve(moneyMarketAddress, type(uint256).max);
        borrowedToken.approve(moneyMarketAddress, type(uint256).max);
    }

    /**
     * @dev Wraps ETH, supplies WETH, and borrows tokens.
     */
    function fund() external payable onlyCreator {
        require(msg.value > 0, "CDP: Must send ETH to fund");

        // Deposit ETH and convert to WETH
        weth.deposit{value: msg.value}();

        // Supply WETH to the money market
        uint256 supplyStatus = compoundMoneyMarket.supply(address(weth), msg.value);
        require(supplyStatus == 0, "CDP: Supply to money market failed");

        // Calculate available borrow
        uint256 collateralRatio = compoundMoneyMarket.collateralRatio();
        (uint256 status, uint256 totalSupply, uint256 totalBorrow) = compoundMoneyMarket.calculateAccountValues(address(this));
        require(status == 0, "CDP: Failed to calculate account values");

        uint256 availableBorrow = findAvailableBorrow(totalSupply, totalBorrow, collateralRatio);
        uint256 assetPrice = compoundMoneyMarket.assetPrices(address(borrowedToken));
        uint256 tokenAmount = availableBorrow * expScale / assetPrice;

        // Borrow tokens
        uint256 borrowStatus = compoundMoneyMarket.borrow(address(borrowedToken), tokenAmount);
        require(borrowStatus == 0, "CDP: Borrow failed");

        // Transfer borrowed tokens to the owner
        uint256 borrowedTokenBalance = borrowedToken.balanceOf(address(this));
        borrowedToken.transfer(owner, borrowedTokenBalance);

        emit Funded(msg.sender, msg.value);
        emit TokensTransferred(owner, borrowedTokenBalance);
    }

    /**
     * @dev Repays the borrowed tokens and withdraws excess collateral.
     */
    function repay() external onlyCreator {
        // Repay the borrowed tokens
        uint256 repayStatus = compoundMoneyMarket.repayBorrow(address(borrowedToken), type(uint256).max);
        require(repayStatus == 0, "CDP: Repay failed");

        // Calculate excess collateral and withdraw
        uint256 collateralRatio = compoundMoneyMarket.collateralRatio();
        (uint256 status, uint256 totalSupply, uint256 totalBorrow) = compoundMoneyMarket.calculateAccountValues(address(this));
        require(status == 0, "CDP: Failed to calculate account values");

        uint256 amountToWithdraw = totalBorrow == 0
            ? type(uint256).max
            : findAvailableWithdrawal(totalSupply, totalBorrow, collateralRatio);

        uint256 withdrawStatus = compoundMoneyMarket.withdraw(address(weth), amountToWithdraw);
        require(withdrawStatus == 0, "CDP: Withdraw failed");

        // Convert WETH back to ETH and transfer to the owner
        uint256 wethBalance = weth.balanceOf(address(this));
        weth.withdraw(wethBalance);
        payable(owner).transfer(address(this).balance);

        emit Repaid(msg.sender, amountToWithdraw);
    }

    /**
     * @dev Calculates the available borrow value in ETH (scaled to 10**18).
     */
    function findAvailableBorrow(
        uint256 currentSupplyValue,
        uint256 currentBorrowValue,
        uint256 collateralRatio
    ) public pure returns (uint256) {
        uint256 totalPossibleBorrow = currentSupplyValue * expScale / (collateralRatio + collateralRatioBuffer);
        return totalPossibleBorrow > currentBorrowValue
            ? (totalPossibleBorrow - currentBorrowValue) / expScale
            : 0;
    }

    /**
     * @dev Calculates the available withdrawal value in ETH (scaled to 10**18).
     */
    function findAvailableWithdrawal(
        uint256 currentSupplyValue,
        uint256 currentBorrowValue,
        uint256 collateralRatio
    ) public pure returns (uint256) {
        uint256 requiredCollateralValue = currentBorrowValue * (collateralRatio + collateralRatioBuffer) / expScale;
        return currentSupplyValue > requiredCollateralValue
            ? (currentSupplyValue - requiredCollateralValue) / expScale
            : 0;
    }

    /**
     * @dev Required to accept ETH for unwrapping WETH.
     */
    receive() external payable {}

    fallback() external payable {}
}
