// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;

import "flywheel-v2/interfaces/IFlywheelBooster.sol";
import "../external/compound/ICToken.sol";
import "../external/balancer/BNum.sol";

/**
 * @title Flywheel3070Booster
 * @notice A booster that splits the rewards in a 30/70 ratio between supply and borrow
 *
 *                            user.supplied                     user.borrowed_principal
 *  user_rewards = 0.3 * ---------------------- + 0.7 * --------------------------------------
 *                       strategy.total_supplied            strategy.total_borrowed_principal
 *
 *                                   booster.boosted_balance_of()
 *  also, user_rewards = rewards * --------------------------------
 *                                  booster.boosted_total_supply()
 *
 * @author Veliko Minkov <veliko@midascapital.xyz>
 */
contract Flywheel3070Booster is IFlywheelBooster {
    uint256 public constant ONE = 1e18;

    function boostedTotalSupply(ERC20 strategy) external view returns (uint256) {
        // the 70% of the borrow should be incentivizing only the borrowed principal
        // without compounding more incentives for the accrued (owed) interest
        ICToken asCToken = ICToken(address(strategy));
        uint256 index = asCToken.borrowIndex();

        uint256 totalBorrowedPrincipal = asCToken.totalBorrows() * ONE / index;
        uint256 totalSupply = asCToken.totalSupply();

        // TODO use BNum multiplication
        return totalBorrowedPrincipal * totalSupply;
    }

    function boostedBalanceOf(ERC20 strategy, address user) external view returns (uint256 boostedBalance) {
        // TODO accrue interest first - use flywheelpresupplieraction
        ICToken asCToken = ICToken(address(strategy));
        uint256 index = asCToken.borrowIndex();
        uint256 balance = asCToken.balanceOf(user);
        uint256 totalSupply = asCToken.totalSupply();
        uint256 borrowPrincipal = asCToken.borrowBalanceStored(user) * ONE / index;
        uint256 totalBorrowedPrincipal = asCToken.totalBorrows() * ONE / index;

        // 30% of the rewards are for supplying
        // 70% of the rewards are for borrowing
        return (
                (7 * totalSupply * borrowPrincipal)
                + (3 * totalBorrowedPrincipal * balance)
            ) / 10;
    }
}
