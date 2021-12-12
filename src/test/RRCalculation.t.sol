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
}
