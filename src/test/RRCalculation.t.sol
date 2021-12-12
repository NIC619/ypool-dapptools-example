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
    struct Param {
        uint256 prevTotalPCV;
        uint256 prevFromChainPCV;
        uint256 amountIn;
        uint256 prevToChainPCV;
        uint256 amountOut;
        uint256 fromChainWeight;
        uint256 toChainWeight;
    }

    struct Ret {
        uint256 oldFromToPCVProduct;
        uint256 newFromToPCVProduct;
        uint256 rebalanceRewardRate;
        uint256 rebalanceReward;
    }

    function testNoReward() public {
        Param memory p;
        p.prevTotalPCV = 1000 * 10 ** 4 * 10 ** 18;
        p.prevFromChainPCV = 60 * 10 ** 4 * 10 ** 18;
        p.amountIn = 2000 * 10 ** 18;
        p.prevToChainPCV = 40 * 10 ** 4 * 10 ** 18;
        p.amountOut = 1500 * 10 ** 18;

        // Test calculate
        Ret memory r;
        (
            r.oldFromToPCVProduct,
            r.newFromToPCVProduct,
            r.rebalanceRewardRate,
            r.rebalanceReward
        ) = rrc.calculate(
                xyUSDValueDecimals,
                swapFeeAmount,
                xyTokenUSDValue,
                p.prevTotalPCV,
                p.prevFromChainPCV,
                p.amountIn,
                p.prevToChainPCV,
                p.amountOut
            );

        emit log_named_uint("oldFromToPCVProduct", r.oldFromToPCVProduct);
        emit log_named_uint("newFromToPCVProduct", r.newFromToPCVProduct);
        emit log_named_uint("rebalanceRewardRate", r.rebalanceRewardRate);
        emit log_named_uint("rebalanceReward", r.rebalanceReward);
        assertEq(r.oldFromToPCVProduct, p.prevFromChainPCV * p.prevToChainPCV);
        assertEq(r.newFromToPCVProduct, (p.prevFromChainPCV + p.amountIn) * (p.prevToChainPCV - p.amountOut));
        assertEq(r.rebalanceRewardRate, 0);
        assertEq(r.rebalanceReward, 0);
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

        Ret memory r;
        (
            r.oldFromToPCVProduct,
            r.newFromToPCVProduct,
            r.rebalanceRewardRate,
            r.rebalanceReward
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

        if (r.oldFromToPCVProduct < r.newFromToPCVProduct) {
            assertGt(r.rebalanceRewardRate, 0);
            assertLe(r.rebalanceRewardRate, BPS);
            assertGt(r.rebalanceReward, 0);
        } else {
            assertEq(r.rebalanceRewardRate, 0);
            assertEq(r.rebalanceReward, 0);
        }
    }
}
