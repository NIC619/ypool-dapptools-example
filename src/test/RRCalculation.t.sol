// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "ds-test/test.sol";

import "../RebalanceRewardCalculation.sol";
import "./utils/Hevm.sol";

abstract contract RRCTest is DSTest {
    Hevm internal constant hevm = Hevm(HEVM_ADDRESS);

    uint256 constant internal BPS = 10000;
    uint256 constant internal REBALANCE_REWARD_RATE_THRESHOLD = 1000;
    uint256 constant internal xyUSDValueDecimals = 18;
    uint256 constant internal xyTokenUSDValue = 2 * 10 ** 18;
    uint256 constant internal swapFeeAmount = 10 * 10 ** 18;

    RebalanceRewardCalculation rrc;

    function setUp() public virtual {
        rrc = new RebalanceRewardCalculation(REBALANCE_REWARD_RATE_THRESHOLD);
    }
}

contract RRC is RRCTest {
    struct localVar {
        uint256 oldFromToPCVProduct;
        uint256 newFromToPCVProduct;
        uint256 rebalanceRewardRate;
        uint256 rebalanceReward;
    }

    function testNoReward() public {
        uint256 prevTotalPCV = 1000 * 10 ** 4 * 10 ** 18;
        uint256 prevFromChainPCV = 60 * 10 ** 4 * 10 ** 18;
        uint256 amountIn = 2000 * 10 ** 18;
        uint256 prevToChainPCV = 40 * 10 ** 4 * 10 ** 18;
        uint256 amountOut = 1500 * 10 ** 18;

        (
            uint256 oldFromToPCVProduct,
            uint256 newFromToPCVProduct,
            uint256 rebalanceRewardRate,
            uint256 rebalanceReward
        ) = rrc.calculate(
                xyUSDValueDecimals,
                swapFeeAmount,
                xyTokenUSDValue,
                prevTotalPCV,
                prevFromChainPCV,
                amountIn,
                prevToChainPCV,
                amountOut
            );

        emit log_uint(oldFromToPCVProduct);
        emit log_uint(newFromToPCVProduct);
        emit log_uint(rebalanceRewardRate);
        emit log_uint(rebalanceReward);
        assertEq(oldFromToPCVProduct, prevFromChainPCV * prevToChainPCV);
        assertEq(newFromToPCVProduct, (prevFromChainPCV + amountIn) * (prevToChainPCV - amountOut));
        assertEq(rebalanceRewardRate, 0);
        assertEq(rebalanceReward, 0);
    }

    function testReward(uint256 prevFromChainPCV, uint256 amountIn, uint256 prevToChainPCV, uint256 amountOut) public {
        uint256 prevTotalPCV = 1000 * 10 ** 4 * 10 ** 18;
        // If from chain PCV > total PCV, skip
        if(prevFromChainPCV > prevTotalPCV) return;
        // If to chain PCV > total PCV, skip
        if(prevToChainPCV > prevTotalPCV) return;
        // If from chain PCV + to chain PCV > total PCV, skip
        if(prevFromChainPCV + prevToChainPCV > prevTotalPCV) return;
        // If from chain PCV + to chain PCV < 1% of total PCV, skip
        if(prevFromChainPCV + prevToChainPCV < prevTotalPCV / BPS) return;
        // If amount in > from chain PCV, skip
        if(amountIn > prevFromChainPCV) return;
        // If amount out > to chain PCV, skip
        if(amountOut > prevToChainPCV) return;

        localVar memory v;
        (
            v.oldFromToPCVProduct,
            v.newFromToPCVProduct,
            v.rebalanceRewardRate,
            v.rebalanceReward
        ) = rrc.calculate(
                xyUSDValueDecimals,
                swapFeeAmount,
                xyTokenUSDValue,
                prevTotalPCV,
                prevFromChainPCV,
                amountIn,
                prevToChainPCV,
                amountOut
            );

        assertEq(v.oldFromToPCVProduct, prevFromChainPCV * prevToChainPCV);
        assertEq(v.newFromToPCVProduct, (prevFromChainPCV + amountIn) * (prevToChainPCV - amountOut));
        if (v.oldFromToPCVProduct < v.newFromToPCVProduct) {
            assertGt(v.rebalanceRewardRate, 0);
            assertLe(v.rebalanceRewardRate, BPS);
            assertGt(v.rebalanceReward, 0);
        } else {
            assertEq(v.rebalanceRewardRate, 0);
            assertEq(v.rebalanceReward, 0);
        }
    }
}
