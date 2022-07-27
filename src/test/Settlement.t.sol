// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "ds-test/test.sol";

import "../settlement-chain/Settlement.sol";
import "../settlement-chain/RebalanceRewardCalculation.sol";
import "./utils/Hevm.sol";

abstract contract BaseSettlementTest is DSTest {
    Hevm internal constant hevm = Hevm(HEVM_ADDRESS);

    uint256 constant internal BPS = 10000;
    uint256 constant internal REBALANCE_REWARD_RATE_THRESHOLD = 1000;
    uint256 constant internal xyUSDValueDecimals = 18;
    uint256 constant internal xyTokenUSDValue = 2 * 10 ** 18;
    uint256 constant internal swapFeeAmount = 10 * 10 ** 18;

    uint256 constant internal rebalanceRewardPeriod = 10;
    uint256 constant internal rebalanceRewardLimitPerEpoch = swapFeeAmount * 10000;

    RebalanceRewardCalculation rrc;
    Settlement settlement;

    function setUp() public virtual {
        rrc = new RebalanceRewardCalculation(REBALANCE_REWARD_RATE_THRESHOLD);
        settlement = new Settlement();
        settlement.initialize(
            address(this),
            [address(this)],
            "Test",
            18,
            rrc,
            rebalanceRewardPeriod,
            rebalanceRewardLimitPerEpoch
        );
    }
}

contract SettlementTest is BaseSettlementTest {
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

    function testFailReinitialize() public {
        settlement.initialize(
            address(this),
            [address(this)],
            "Test",
            18,
            rrc,
            rebalanceRewardPeriod,
            rebalanceRewardLimitPerEpoch
        );
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
        ) = settlement.calculate(
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
        assertEq(r.rebalanceRewardRate, 0);
        assertEq(r.rebalanceReward, 0);

        p.fromChainWeight = 1;
        p.toChainWeight = 1;
        // Test weightedCalculate
        (
            r.oldFromToPCVProduct,
            r.newFromToPCVProduct,
            r.rebalanceRewardRate,
            r.rebalanceReward
        ) = settlement.weightedCalculate(
                xyUSDValueDecimals,
                swapFeeAmount,
                xyTokenUSDValue,
                p.prevTotalPCV,
                p.prevFromChainPCV,
                p.fromChainWeight,
                p.amountIn,
                p.prevToChainPCV,
                p.toChainWeight,
                p.amountOut
            );

        emit log_named_uint("oldFromToPCVProduct", r.oldFromToPCVProduct);
        emit log_named_uint("newFromToPCVProduct", r.newFromToPCVProduct);
        emit log_named_uint("rebalanceRewardRate", r.rebalanceRewardRate);
        emit log_named_uint("rebalanceReward", r.rebalanceReward);
        assertEq(r.rebalanceRewardRate, 0);
        assertEq(r.rebalanceReward, 0);
    }

    function testGetReward() public {
        Param memory p;
        p.prevTotalPCV = 100 * 10 ** 4 * 10 ** 18;
        p.prevFromChainPCV = 40 * 10 ** 4 * 10 ** 18;
        p.amountIn = 3 * 10 ** 4 * 10 ** 18;
        p.prevToChainPCV = 60 * 10 ** 4 * 10 ** 18;
        p.amountOut = 2 * 10 ** 4 * 10 ** 18;

        p.fromChainWeight = 4;
        p.toChainWeight = 1;
        Ret memory r;
        (
            r.oldFromToPCVProduct,
            r.newFromToPCVProduct,
            r.rebalanceRewardRate,
            r.rebalanceReward
        ) = settlement.weightedCalculate(
                xyUSDValueDecimals,
                swapFeeAmount,
                xyTokenUSDValue,
                p.prevTotalPCV,
                p.prevFromChainPCV,
                p.fromChainWeight,
                p.amountIn,
                p.prevToChainPCV,
                p.toChainWeight,
                p.amountOut
            );

        emit log_named_uint("oldFromToPCVProduct", r.oldFromToPCVProduct);
        emit log_named_uint("newFromToPCVProduct", r.newFromToPCVProduct);
        emit log_named_uint("rebalanceRewardRate", r.rebalanceRewardRate);
        emit log_named_uint("rebalanceReward", r.rebalanceReward);
        assertGt(r.rebalanceRewardRate, 0);
        assertGt(r.rebalanceReward, 0);
    }

    function _checkReward(Ret memory r) internal {
        if ((r.oldFromToPCVProduct < r.newFromToPCVProduct) && ((r.newFromToPCVProduct - r.oldFromToPCVProduct) >= r.oldFromToPCVProduct / REBALANCE_REWARD_RATE_THRESHOLD)) {
            assertGt(r.rebalanceRewardRate, 0);
            assertLe(r.rebalanceRewardRate, BPS);
            if (r.rebalanceRewardRate >= REBALANCE_REWARD_RATE_THRESHOLD) {
                assertGt(r.rebalanceReward, 0);
            } else {
                assertEq(r.rebalanceReward, 0);
            }
        } else {
            assertEq(r.rebalanceRewardRate, 0);
            assertEq(r.rebalanceReward, 0);
        }
    }

    function testChainWeight(uint8 fromChainWeight, uint8 toChainWeight, uint32 prevFromChainPCV, uint32 amountIn, uint32 prevToChainPCV, uint32 amountOut) public {
        if (fromChainWeight == 0) return;
        if (toChainWeight == 0) return;
        if (fromChainWeight > settlement.MAX_CHAIN_WEIGHT()) return;
        if (toChainWeight > settlement.MAX_CHAIN_WEIGHT()) return;
        // If to chain PCV == 0, skip
        if(prevToChainPCV == 0) return;
        // If amount out > to chain PCV, skip
        if (amountOut > prevToChainPCV) return;
        Param memory p;
        // Set total PCV to 10 times the sum of from chain PCV and to chain PCV
        p.prevTotalPCV = (uint256(prevFromChainPCV) + uint256(prevToChainPCV)) * 10 * 10**18;
        p.prevFromChainPCV = uint256(prevFromChainPCV) * 10 ** 18;
        p.amountIn = uint256(amountIn) * 10 ** 18;
        p.prevToChainPCV = uint256(prevToChainPCV) * 10 ** 18;
        p.amountOut = uint256(amountOut) * 10 ** 18;
        p.fromChainWeight = fromChainWeight;
        p.toChainWeight = toChainWeight;

        // Test calculate
        Ret memory r;
        (
            r.oldFromToPCVProduct,
            r.newFromToPCVProduct,
            r.rebalanceRewardRate,
            r.rebalanceReward
        ) = settlement.weightedCalculate(
                xyUSDValueDecimals,
                swapFeeAmount,
                xyTokenUSDValue,
                p.prevTotalPCV,
                p.prevFromChainPCV,
                p.fromChainWeight,
                p.amountIn,
                p.prevToChainPCV,
                p.toChainWeight,
                p.amountOut
            );

        _checkReward(r);
    }

    // Fuzz reward calculation with input values with their decimals being 0 and multiply them by 10**18 before passing them in
    function testRewardNoDecimal(uint32 prevFromChainPCV, uint32 amountIn, uint32 prevToChainPCV, uint32 amountOut) public {
        // If to chain PCV == 0, skip
        if(prevToChainPCV == 0) return;
        // If amount out > to chain PCV, skip
        if (amountOut > prevToChainPCV) return;
        Param memory p;
        // Set total PCV to 10 times the sum of from chain PCV and to chain PCV
        p.prevTotalPCV = (uint256(prevFromChainPCV) + uint256(prevToChainPCV)) * 10 * 10**18;
        p.prevFromChainPCV = uint256(prevFromChainPCV) * 10 ** 18;
        p.amountIn = uint256(amountIn) * 10 ** 18;
        p.prevToChainPCV = uint256(prevToChainPCV) * 10 ** 18;
        p.amountOut = uint256(amountOut) * 10 ** 18;

        Ret memory r;
        (
            r.oldFromToPCVProduct,
            r.newFromToPCVProduct,
            r.rebalanceRewardRate,
            r.rebalanceReward
        ) = settlement.calculate(
                xyUSDValueDecimals,
                swapFeeAmount,
                xyTokenUSDValue,
                p.prevTotalPCV,
                p.prevFromChainPCV,
                p.amountIn,
                p.prevToChainPCV,
                p.amountOut
            );

        _checkReward(r);
    }

    function testReward(uint88 prevFromChainPCV, uint88 amountIn, uint88 prevToChainPCV, uint88 amountOut) public {
        // If to chain PCV == 0, skip
        if(prevToChainPCV == 0) return;
        // If amount out > to chain PCV, skip
        if(amountOut > prevToChainPCV) return;
        Param memory p;
        // Set total PCV to 10 times the sum of from chain PCV and to chain PCV
        p.prevTotalPCV = (uint256(prevFromChainPCV) + uint256(prevToChainPCV)) * 10;
        p.prevFromChainPCV = uint256(prevFromChainPCV);
        p.amountIn = uint256(amountIn);
        p.prevToChainPCV = uint256(prevToChainPCV);
        p.amountOut = uint256(amountOut);

        Ret memory r;
        (
            r.oldFromToPCVProduct,
            r.newFromToPCVProduct,
            r.rebalanceRewardRate,
            r.rebalanceReward
        ) = settlement.calculate(
                xyUSDValueDecimals,
                swapFeeAmount,
                xyTokenUSDValue,
                p.prevTotalPCV,
                p.prevFromChainPCV,
                p.amountIn,
                p.prevToChainPCV,
                p.amountOut
            );

        _checkReward(r);
    }
}
