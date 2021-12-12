// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";


/// @title Rebalance reward calculation contract
/// @notice Settlement contract calls this contract to calculate the amount of rebalance reward a user deserve after a swap is settled
/// @dev This contract MUST be deployed on Settlement chain
/// Below are clarification of the namings in the contract
/// - "PCV" and "liquidity" refer to the same thing
/// - "fromChain" and "source chain" refer to the same thing
/// - "toChain" and "target chain" refer to the same thing
contract RebalanceRewardCalculation is Ownable {

    // BPS: Base Point, 1 Base Point = 0.01%
    uint256 constant private BPS = 10000;
    // Minimum reward rate that must be met in order to give out the reward
    uint256 public REBALANCE_REWARD_RATE_THRESHOLD;


    /* ========== CONSTRUCTOR ========== */

    constructor (uint256 _REBALANCE_REWARD_RATE_THRESHOLD) {
        REBALANCE_REWARD_RATE_THRESHOLD = _REBALANCE_REWARD_RATE_THRESHOLD;
    }

    /* ========== PRIVILEGED FUNCTION ========== */

    /// @param _REBALANCE_REWARD_RATE_THRESHOLD New `REBALANCE_REWARD_RATE_THRESHOLD`
    function setRewardRateThreshold(uint256 _REBALANCE_REWARD_RATE_THRESHOLD) external onlyOwner {
        require(_REBALANCE_REWARD_RATE_THRESHOLD <= BPS, "ERR_INVALID_THRESHOLD");
        REBALANCE_REWARD_RATE_THRESHOLD = _REBALANCE_REWARD_RATE_THRESHOLD;
    }

    /* ========== PURE FUNCTIONS ========== */

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice This function calculates rebalance reward amount the user can get if the swap is settled
    /// @dev This function emits `RebalanceRewardAdded` event including info like old and new source/target chain liquidity product and new reward rate
    /// `xyTokenUSDValue` MUST be greater than zero
    /// @param xyUSDValueDecimals Decimal of XY token value in USD
    /// @param swapFeeAmount Fee amount the user is paying for the swap
    /// @param xyTokenUSDValue XY token value in USD
    /// @param prevTotalPCV Total liquidity before the swap is settled
    /// @param prevFromChainPCV Source chain liquidity before the swap is settled
    /// @param amountIn Amount of YPool token sent to YPool vault on source chain
    /// @param prevToChainPCV Target chain liquidity before the swap is settled
    /// @param amountOut Amount of YPool token transfered away from YPool vault on target chain
    /// @return oldFromToPCVProduct Product of source chain liqudity and target chain liquidity before the swap is settled
    /// @return newFromToPCVProduct Product of source chain liqudity and target chain liquidity after the swap is settled
    /// @return rebalanceRewardRate Reward rate of the swap
    /// @return rebalanceReward Reward given to the user
    function calculate(
        uint256 xyUSDValueDecimals,
        uint256 swapFeeAmount,
        uint256 xyTokenUSDValue,
        uint256 prevTotalPCV,
        uint256 prevFromChainPCV,
        uint256 amountIn,
        uint256 prevToChainPCV,
        uint256 amountOut
    ) external view returns (uint256 oldFromToPCVProduct, uint256 newFromToPCVProduct, uint256 rebalanceRewardRate, uint256 rebalanceReward) {

        // Step 1. calculate the initial reward rate
        // Scale down reward rate base on the size of source chain liquidity, target chain liquidity and total liquidity
        // The smaller the sum of source chain liquidity and target chain liquidity, the smaller the reward rate
        rebalanceRewardRate = BPS * (prevFromChainPCV + prevToChainPCV) / prevTotalPCV;

        // Step 2. calculate the product of sourchain liquidity and target chain liquidity, both old and new
        // `prevFromChainPCV + amountIn` MUST be greater than zero
        newFromToPCVProduct = prevFromChainPCV + amountIn;
        if (prevToChainPCV > amountOut) {
            // If target chain has liquidity left, multiplies it
            newFromToPCVProduct *= (prevToChainPCV - amountOut);
        }
        // `prevToChainPCV` MUST be greater than zero
        oldFromToPCVProduct = prevToChainPCV;
        if (prevFromChainPCV != 0) {
            // If source chain had liquidity, multiplies it
            oldFromToPCVProduct *= prevFromChainPCV;
        }

        // Step 3-1. check if new liquidity product is greater than old liquidity product which implies the balance between each chain being improved
        // Reward only if liquidity product increases
        if (newFromToPCVProduct <= oldFromToPCVProduct) {
            rebalanceRewardRate = 0;
        } else {
            // Multiplied by the ratio of liquidity product increase relative to the old liquidity product
            rebalanceRewardRate = rebalanceRewardRate * (newFromToPCVProduct - oldFromToPCVProduct) / oldFromToPCVProduct;
        }
        // Step 3-2. bound the reward rate
        rebalanceRewardRate = min(BPS, rebalanceRewardRate);

        // Step 4. only give out reward if reward rate met the threshold
        if (rebalanceRewardRate >= REBALANCE_REWARD_RATE_THRESHOLD) {
            // Base reward is `swapFeeAmount`
            // On top of top, another percentage of `swapFeeAmount` is added depending on the reward rate
            // So the reward amount is between `swapFeeAmount` and `2 * swapFeeAmount`
            rebalanceReward = swapFeeAmount + swapFeeAmount * rebalanceRewardRate / BPS;
        }

        // Step 5. convert reward amount to XY Token amount because reward amount is denominated in the YPool token while reward given out should be XY token
        rebalanceReward = rebalanceReward * (10 ** xyUSDValueDecimals) / xyTokenUSDValue;

        return (oldFromToPCVProduct, newFromToPCVProduct, rebalanceRewardRate, rebalanceReward);
    }
}
