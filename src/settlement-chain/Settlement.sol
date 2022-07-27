// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { AccessControlUpgradeable } from "@openzeppelin-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { RebalanceRewardCalculation } from "./RebalanceRewardCalculation.sol";


/// @title Settlement contract for YPool token
/// @notice Each YPool token MUST share exactly one settlement contract, e.g., all USDT YPool Vaults share one USDT settlement contract
/// Settlement contract is solely managed by YPool owner(s) to keep track of liqudity on each periphery chain and calculate rebalance reward
/// Normal users MUST not be able or allowed to interact with this contract
/// User Id, i.e., `account` in settlement chain is represented as bytes32 type instead of address type
/// @dev This contract MUST be deployed on Settlement chain
/// This is an upgradeable contract following UUPS upgrade pattern and care should be taken when designing and doing the upgrade
/// User Id SHOULD be the hash of their corresponding id on each periphery chain, e.g., `keccak256(ethAddress)` or `sha256(solanaPubkey)`
/// Below are clarification of the namings in the contract
/// - "User" and "Account" refer to the same thing
/// - "PCV" and "liquidity" refer to the same thing
/// - "fromChain" and "source chain" refer to the same thing
/// - "toChain" and "target chain" refer to the same thing
contract YPoolVaultSettlement is AccessControlUpgradeable, UUPSUpgradeable {

    receive() external payable {}

    /* ========== STRUCTURE ========== */

    // Different type of transaction that updates PCV
    enum TxType { Force, Deposit, Withdraw, Swap }
    // Status of a YPool token deposit into YPool vault on a periphery chain
    enum DepositStatus { Nonexist, Completed }
    // Status of a YPool token withdraw from YPool vault on a periphery chain
    enum WithdrawStatus { Nonexist, Completed }
    // Status of a swap between periphery chains
    enum SwapStatus { Nonexist, Initiated, Completed }
    // Different type of how a swap is completed
    enum CompleteSwapType { Settled, Timeout, Invalidated }
    // Status of a claim of rebalance reward
    enum ClaimRRStatus { Nonexist, Completed }

    // Fees settings on Settlement chain
    // Note: this is the setting for withdraw fee, not swap fee
    // Fee is calculated as `inputAmount * FeeStructure.rate / (10 ** FeeStructure.decimals)`
    struct FeeStructure {
        bool isSet;
        uint256 min;
        uint256 max;
        uint256 rate;
        uint256 decimals;
    }

    // Swap info
    struct SwapInfo {
        // Id of the user initates the swap
        bytes32 account;
        // Amount of YPool token sent to YPool vault on source chain
        uint256 amountIn;
        // Amount of YPool token transfered away from YPool vault on target chain
        uint256 amountOut;
        // Gas fee paid by YPool worker
        uint256 gasFee;
        // Chain id of destination chain
        uint32 toChainId;
    }

    /* ========== STATE VARIABLES ========== */

    // Roles
    bytes32 public constant ROLE_OWNER = keccak256("ROLE_OWNER");
    // SETTLEMENT_WORKER is controled by YPool owner(s)
    bytes32 public constant ROLE_SETTLEMENT_WORKER = keccak256("ROLE_SETTLEMENT_WORKER");

    uint256 constant private YIELD_RATE_DECIMALS = 8;

    // Symbol of the YPool token
    string public ASSET_SYMBOL;
    // Decimal of XY token value in USD
    uint256 private XY_USD_VALUE_DECIMALS;
    // Sum of all YPool token Liquidity on each periphery chain
    uint256 private _totalPCV;
    // YPool token Liquidity on each periphery chain
    mapping (uint32 => uint256) _PCVs;
    // Sum of each user's share
    uint256 private _totalShares;
    mapping (uint32 => FeeStructure) public feeStructures;
    mapping(bytes32 => DepositStatus) private _depositStatus;
    mapping(bytes32 => WithdrawStatus) private _withdrawStatus;
    mapping(bytes32 => SwapStatus) private _swapStatus;
    mapping(bytes32 => SwapInfo) private _swapInfo;
    // Locked YPool token liquidity on each periphery chain
    // Part of liquidity is locked when a swap is initiated to prevent race condition
    mapping(uint32 => uint256) public chainLockedAmount;
    // Contract containing the logic for user's rebalance reward calculation
    // This contract is expected to be updated as rebalance reward formula is updated
    RebalanceRewardCalculation public rebalanceRewardCalculation;
    // Limit of max rebalance reward during a period of time
    // Start from start time and increase epoch
    uint256 public rebalanceRewardLimitPerEpoch;
    uint256 public rebalanceRewardPeriod;
    uint256 public rebalanceRewardCurrentEpochNumber;
    uint256 public rebalanceRewardCurrentEpochAmount;
    uint256 public rebalanceRewardEpochStartTime;

    // Each user's accumulated rebalance reward
    // Rebalance reward is denominated in XY token
    mapping(bytes32 => uint256) public rebalanceReward;
    mapping(bytes32 => ClaimRRStatus) private _claimRRStatus;

    // Weight of YPool token on each chain, indicating the preferred distribution of liquidity
    mapping (uint32 => uint8) _PCVWeights;

    /* ========== PURE FUNCTIONS ========== */

    function max(uint256 a, uint256 b) private pure returns (uint256) {
        return a >= b ? a : b;
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Compute the universal Id of request, e.g., deposit, swap or withdraw.
    /// An universal Id is the hash of chainId and a nonce
    function _getUniversalId(uint32 chainId, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(chainId, nonce));
    }

    /// @param chainId Chain Id of the periphery chain
    /// @param nonce Nonce of the request emitted on the periphery chain
    /// @return Universal Id of the request
    function getUniversalDepositId(uint32 chainId, uint256 nonce) external pure returns (bytes32) {
        return _getUniversalId(chainId, nonce);
    }

    function depositStatus(uint32 chainId, uint256 nonce) external view returns (DepositStatus) {
        bytes32 universalDepositId = _getUniversalId(chainId, nonce);
        return _depositStatus[universalDepositId];
    }

    function getUniversalWithdrawId(uint32 chainId, uint256 nonce) external pure returns (bytes32) {
        return _getUniversalId(chainId, nonce);
    }

    function withdrawStatus(uint32 chainId, uint256 nonce) external view returns (WithdrawStatus) {
        bytes32 universalWithdrawId = _getUniversalId(chainId, nonce);
        return _withdrawStatus[universalWithdrawId];
    }

    /// @notice Get the universal Id of a claim of rebalance reward
    function getUniversalClaimId(uint32 chainId, uint256 nonce) external pure returns (bytes32) {
        return _getUniversalId(chainId, nonce);
    }

    function claimRRStatus(uint32 chainId, uint256 nonce) external view returns (ClaimRRStatus) {
        bytes32 universalClaimRRId = _getUniversalId(chainId, nonce);
        return _claimRRStatus[universalClaimRRId];
    }

    /// @dev `swapId` is equivalent to `nonce`, not the universal Id of the swap
    function getUniversalSwapId(uint32 chainId, uint256 swapId) external pure returns (bytes32) {
        return _getUniversalId(chainId, swapId);
    }

    function swapStatus(uint32 chainId, uint256 swapId) external view returns (SwapStatus) {
        bytes32 universalSwapId = _getUniversalId(chainId, swapId);
        return _swapStatus[universalSwapId];
    }

    function swapInfo(uint32 chainId, uint256 swapId) external view returns (SwapInfo memory) {
        bytes32 universalSwapId = _getUniversalId(chainId, swapId);
        return _swapInfo[universalSwapId];
    }

    /// @notice Calculate the XY protocol fee
    /// @param chainId Chain Id of the periphery chain
    /// @param amount YPool token amount
    function calculateXYFee(uint32 chainId, uint256 amount) private view returns (uint256) {
        FeeStructure memory feeStructure = feeStructures[chainId];
        require(feeStructure.isSet, "ERR_FEE_NOT_SET");

        uint256 xyFee = amount * feeStructure.rate / (10 ** feeStructure.decimals);
        return min(max(xyFee, feeStructure.min), feeStructure.max);
    }

    function getFeeStructure(uint32 chainId) external view returns (FeeStructure memory) {
        return feeStructures[chainId];
    }

    function totalPCV() external view returns (uint256) {
        return _totalPCV;
    }

    function chainPCV(uint32 chainId) external view returns (uint256) {
        return _PCVs[chainId];
    }

    /// @notice Get the available liquidity on a periphery chain
    function remainLiquidity(uint32 chainId) external view returns (uint256) {
        return _PCVs[chainId] - chainLockedAmount[chainId];
    }

    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    /// @notice Get yield rate of the YPool token
    /// Every swap completed adds more liquidity to the pool and when a user withdraws he/she will get more YPool token
    function _getYieldRate() internal view returns (uint256) {
        if (_totalPCV == 0 || _totalShares == 0) {
            // Default yield rate
            return 10 ** YIELD_RATE_DECIMALS;
        } else {
            return (_totalPCV * 10 ** YIELD_RATE_DECIMALS / _totalShares);
        }
    }

    function getYieldRate() external view returns (uint256) {
        return _getYieldRate();
    }

    /* ========== INITIALIZER ========== */

    /// @dev `initialize` MUST be protected either by initializer or other condition check
    /// @param owner Owner of settlement contract who has the sole right to assign roles.
    /// @param workers List of workers who will be assigned SETTLEMENT_WORKER role
    /// @param assetSymbol Symbol of the YPool token
    /// @param decimal Decimal of XY token value in USD
    /// @param _rebalanceRewardCalculation The `RebalanceRewardCalculation` contract
    function initialize(
        address owner,
        address[] memory workers,
        string memory assetSymbol,
        uint256 decimal,
        RebalanceRewardCalculation _rebalanceRewardCalculation,
        uint256 _rebalanceRewardPeriod,
        uint256 _rebalanceRewardLimitPerEpoch
    ) initializer public {
        require(Address.isContract(address(_rebalanceRewardCalculation)), "ERR_XY_TOKEN_NOT_CONTRACT");
        _setRoleAdmin(ROLE_OWNER, ROLE_OWNER);
        _setRoleAdmin(ROLE_SETTLEMENT_WORKER, ROLE_OWNER);
        _setupRole(ROLE_OWNER, owner);
        for (uint i; i < workers.length; i++) {
            _setupRole(ROLE_SETTLEMENT_WORKER, workers[i]);
        }

        ASSET_SYMBOL = assetSymbol;
        XY_USD_VALUE_DECIMALS = decimal;
        rebalanceRewardCalculation = _rebalanceRewardCalculation;
        rebalanceRewardLimitPerEpoch = _rebalanceRewardLimitPerEpoch;
        rebalanceRewardPeriod = _rebalanceRewardPeriod;
        rebalanceRewardEpochStartTime = block.timestamp;
        rebalanceRewardCurrentEpochNumber = 0;

    }

    /* ========== WRITE FUNCTIONS ========== */

    function _authorizeUpgrade(address) internal override onlyRole(ROLE_OWNER) {}

    /// @notice This function updates the user's accumulated rebalance reward amount
    /// It calls to `rebalanceRewardCalculation` contract to calculate the rebalance reward for the user
    /// @dev This function emits `RebalanceRewardAdded` event including info like old and new source/target chain liquidity product and new reward rate
    /// `xyTokenUSDValue` MUST be greater than zero
    /// @param account User Id
    /// @param swapFeeAmount Fee amount the user is paying for the swap
    /// @param xyTokenUSDValue XY token value in USD
    /// @param prevTotalPCV Total liquidity before the swap is settled
    /// @param prevFromChainPCV Source chain liquidity before the swap is settled
    /// @param amountIn Amount of YPool token sent to YPool vault on source chain
    /// @param prevToChainPCV Target chain liquidity before the swap is settled
    /// @param amountOut Amount of YPool token transfered away from YPool vault on target chain
    function _updateRebalanceReward(
        bytes32 account,
        uint256 swapFeeAmount,
        uint256 xyTokenUSDValue,
        uint256 prevTotalPCV,
        uint256 prevFromChainPCV,
        uint256 amountIn,
        uint256 prevToChainPCV,
        uint256 amountOut
    ) internal {
        require(rebalanceRewardPeriod > 0, "ERR_PERIOD_NOT_SET");
        require(block.timestamp > rebalanceRewardEpochStartTime, "ERR_EPOCH_NOT_STARTED");
        uint256 newEpochNumber = (block.timestamp - rebalanceRewardEpochStartTime) / rebalanceRewardPeriod;
        if (newEpochNumber > rebalanceRewardCurrentEpochNumber) {
            rebalanceRewardCurrentEpochNumber = newEpochNumber;
            rebalanceRewardCurrentEpochAmount = 0;
        }

        (
            uint256 oldFromToPCVProduct,
            uint256 newFromToPCVProduct,
            uint256 rebalanceRewardRate,
            uint256 _rebalanceReward
        ) = rebalanceRewardCalculation.calculate(
            XY_USD_VALUE_DECIMALS,
            swapFeeAmount,
            xyTokenUSDValue,
            prevTotalPCV,
            prevFromChainPCV,
            amountIn,
            prevToChainPCV,
            amountOut
        );

        if (rebalanceRewardCurrentEpochAmount >= rebalanceRewardLimitPerEpoch) {
            emit RebalanceRewardAdded(account, oldFromToPCVProduct, newFromToPCVProduct, rebalanceRewardRate, 0);
            return;
        }

        if (rebalanceRewardCurrentEpochAmount + _rebalanceReward > rebalanceRewardLimitPerEpoch) {
            _rebalanceReward = rebalanceRewardLimitPerEpoch - rebalanceRewardCurrentEpochAmount;
        }
        rebalanceRewardCurrentEpochAmount += _rebalanceReward;

        // Update user's rebalance reward amount
        rebalanceReward[account] += _rebalanceReward;

        emit RebalanceRewardAdded(account, oldFromToPCVProduct, newFromToPCVProduct, rebalanceRewardRate, _rebalanceReward);
    }

    /// @param _newRebalanceRewardCalculation New `RebalanceRewardCalculation` contract
    function setRebalanceRewardCalculation(RebalanceRewardCalculation _newRebalanceRewardCalculation) external onlyRole(ROLE_SETTLEMENT_WORKER) {
        require(Address.isContract(address(_newRebalanceRewardCalculation)), "ERR_XY_TOKEN_NOT_CONTRACT");
        rebalanceRewardCalculation = _newRebalanceRewardCalculation;
    }

    /// @dev Fee structure can not be unset
    function setFeeStructure(uint32 chainId, uint256 _min, uint256 _max, uint256 rate, uint256 decimals) external onlyRole(ROLE_SETTLEMENT_WORKER) {
        FeeStructure memory feeStructure = FeeStructure(true, _min, _max, rate, decimals);
        feeStructures[chainId] = feeStructure;
        emit FeeStructureSet(chainId, _min, _max, rate, decimals);
    }

    function setRebalanceRewardLimitPerEpoch(uint256 limit) external onlyRole(ROLE_OWNER) {
        rebalanceRewardLimitPerEpoch = limit;
        emit RebalanceRewardLimitUpdated(limit);
    }

    function setRebalanceRewardPeriod(uint256 period) external onlyRole(ROLE_OWNER) {
        rebalanceRewardPeriod = period;
        rebalanceRewardEpochStartTime = block.timestamp;
        rebalanceRewardCurrentEpochNumber = 0;
        emit RebalanceRewardPeriodUpdated(period);
    }

    /// @notice This function is called whenever a user deposits YPool token to YPool vault on a periphery chain
    /// @notice Share given to the user is calculated based on total shares and total liquidity at the moment
    /// @dev If pool is empty before this deposit, share amount is equal to deposited amount
    /// @param chainId Chain Id of the periphery chain
    /// @param depositId Nonce of the deposit on the periphery chain
    /// @param account User Id
    /// @param amount Amount of YPool token deposited
    function deposit(uint32 chainId, uint256 depositId, bytes32 account, uint256 amount) public onlyRole(ROLE_SETTLEMENT_WORKER) {
        bytes32 universalDepositId = _getUniversalId(chainId, depositId);
        require(_depositStatus[universalDepositId] != DepositStatus.Completed, "ERR_ALREADY_DEPOSITED");
        _depositStatus[universalDepositId] = DepositStatus.Completed;
        require(amount > 0, "ERR_INVALID_DEPOSIT_AMOUNT");
        uint256 shareAmount = (_totalShares == 0) ? amount : _totalShares * amount / _totalPCV;
        _totalPCV += amount;
        _PCVs[chainId] += amount;
        _totalShares += shareAmount;
        emit Deposit(chainId, depositId, account, amount, shareAmount);
        emit PCVsUpdated(TxType.Deposit, depositId, chainId, 0, amount, 0);
    }

    /// @notice This function is called whenever a user requests a withdraw of YPool token from YPool vault on a periphery chain
    /// The amount of YPool token to be withdrawn is calculated based on yield rate, i.e., total shares and total liquidity at the moment
    /// A protocol fee `xyFee` will be charged
    /// If the available liquidity on the periphery chain is less than `shareAmount`, withdraw will fail
    /// @param chainId Chain Id of the periphery chain
    /// @param withdrawId Nonce of the withdraw request on the periphery chain
    /// @param account User Id
    /// @param shareAmount Amount of share to withdraw
    function withdraw(uint32 chainId, uint256 withdrawId, bytes32 account, uint256 shareAmount) public onlyRole(ROLE_SETTLEMENT_WORKER) {
        bytes32 universalWithdrawId = _getUniversalId(chainId, withdrawId);
        require(_withdrawStatus[universalWithdrawId] != WithdrawStatus.Completed, "ERR_ALREADY_WITHDREW");
        _withdrawStatus[universalWithdrawId] = WithdrawStatus.Completed;
        require(shareAmount > 0,"ERR_INVALID_SHARE_AMOUNT");
        // TODO: decimals for withdrawnAmount?
        uint256 withdrawnAmount = shareAmount * _getYieldRate() / 10 ** YIELD_RATE_DECIMALS;
        uint256 xyFee = calculateXYFee(chainId, withdrawnAmount);
        require(withdrawnAmount >= xyFee, "ERR_WITHDRAW_AMOUNT_TOO_LESS");
        withdrawnAmount -= xyFee;
        require((_PCVs[chainId] - withdrawnAmount) >= chainLockedAmount[chainId], "ERR_WITHDRAW_AMOUNT_TOO_LARGE");
        _totalPCV -= withdrawnAmount;
        _PCVs[chainId] -= withdrawnAmount;
        _totalShares -= shareAmount;
        emit Withdrawn(chainId, withdrawId, account, shareAmount, withdrawnAmount, xyFee, _getYieldRate());
        emit PCVsUpdated(TxType.Withdraw, withdrawId, 0, chainId, 0, withdrawnAmount);
    }

    /// @notice This function is called whenever a user initate a swap on a periphery chain
    /// If the available liquidity on the target chain is less than `amountOut`, swap will fail
    /// If the swap succeed, `amountOut` of liquidity on the target chain will be locked
    /// @param fromChainId Chain Id of the source chain
    /// @param toChainId Chain Id of the target chain
    /// @param fromChainSwapId Nonce of the swap on the source chain
    /// @param account User Id
    /// @param amountIn Amount of YPool token sent to YPool vault on source chain
    /// @param amountOut Amount of YPool token transfered away from YPool vault on target chain
    /// @param gasFee Amount of gas fee paid by YPool worker
    function initiateCrossChainSwap(
        uint32 fromChainId,
        uint32 toChainId,
        uint256 fromChainSwapId,
        bytes32 account,
        uint256 amountIn,
        uint256 amountOut,
        uint256 gasFee
    ) external onlyRole(ROLE_SETTLEMENT_WORKER) {
        require(_totalShares > 0, "ERR_INVALID_TOTAL_SHARES");
        bytes32 universalSwapId = _getUniversalId(fromChainId, fromChainSwapId);
        require(_swapStatus[universalSwapId] == SwapStatus.Nonexist, "ERR_INVALID_SWAP_STATUS");
        require(account != bytes32(0), "ERR_INVALID_ACCOUNT");
        require(_PCVs[toChainId] >= (chainLockedAmount[toChainId] + amountOut), "ERR_NOT_ENOUGH_LIQUIDITY");
        require(amountIn >= amountOut, "ERR_OUTPUT_TOKEN_LESS_THAN_INPUT");
        require(amountIn - amountOut >= gasFee, "ERR_REVENUE_LESS_THAN_GAS_FEE");

        chainLockedAmount[toChainId] += amountOut;
        _swapInfo[universalSwapId] = SwapInfo(account, amountIn, amountOut, gasFee, toChainId);
        _swapStatus[universalSwapId] = SwapStatus.Initiated;
        emit CrossChainSwapInitiated(fromChainId, toChainId, fromChainSwapId, amountIn, amountOut, gasFee);
    }

    /// @notice This function is called AFTER the YPool worker claimed the YPool token, i.e., `amountIn` of a swap on a periphery chain
    /// This is the happy case where YPool worker closes(read: settles) a swap and approved by validators
    /// If the settle succeed, `amountIn - gasFee` of liquidity will be added to the source chain
    /// If the settle succeed, `amountOut` of liquidity on the target chain will be unlocked and deducted
    /// If the settle succeed, `amountIn - gasFee + amountOut` of liquidity will be added to total liquidity
    /// @dev `xyTokenUSDValue` MUST be greater than zero
    /// @param fromChainId Chain Id of the source chain
    /// @param fromChainSwapId Nonce of the swap on the source chain
    /// @param xyTokenUSDValue XY token value in USD
    function settleCrossChainSwap(uint32 fromChainId, uint256 fromChainSwapId, uint256 xyTokenUSDValue) external onlyRole(ROLE_SETTLEMENT_WORKER) {
        require(_totalShares > 0, "ERR_INVALID_TOTAL_SHARES");
        bytes32 universalSwapId = _getUniversalId(fromChainId, fromChainSwapId);
        require(_swapStatus[universalSwapId] == SwapStatus.Initiated, "ERR_INVALID_SWAP_STATUS");
        uint32 toChainId = _swapInfo[universalSwapId].toChainId;

        uint256 prevFromChainPCV = _PCVs[fromChainId];
        uint256 prevToChainPCV = _PCVs[toChainId];
        uint256 prevTotalPCV = _totalPCV;

        uint256 amountIn = _swapInfo[universalSwapId].amountIn;
        uint256 amountOut = _swapInfo[universalSwapId].amountOut;
        uint256 gasFee = _swapInfo[universalSwapId].gasFee;
        uint256 revenue = amountIn - amountOut;
        _totalPCV += revenue - gasFee;
        _PCVs[fromChainId] += (amountIn - gasFee);
        _PCVs[toChainId] -= amountOut;
        emit Earned(fromChainId, toChainId, fromChainSwapId, revenue, gasFee);
        emit PCVsUpdated(TxType.Swap, fromChainSwapId, fromChainId, toChainId, amountIn - gasFee, amountOut);

        chainLockedAmount[toChainId] -= amountOut;
        _swapStatus[universalSwapId] = SwapStatus.Completed;

        _updateRebalanceReward(
            _swapInfo[universalSwapId].account,
            revenue,
            xyTokenUSDValue,
            prevTotalPCV,
            prevFromChainPCV,
            amountIn - gasFee,
            prevToChainPCV,
            amountOut
        );
        emit SwapCompleted(CompleteSwapType.Settled, fromChainId, fromChainSwapId, amountOut);
    }

    /// @notice This function is called AFTER the validators disapproved a swap on a periphery chain, source chain specificly
    /// This is the bad case where YPool worker messed up a swap and the swap is disapproved by validators
    /// `amountOut` of liquidity on the target chain will be unlocked
    /// `actualAmountOut` of liquidity on the target chain will be deducted
    /// `actualAmountOut` of liquidity of total liquidity will be deducted
    /// @param fromChainId Chain Id of the source chain
    /// @param fromChainSwapId Nonce of the swap on the source chain
    /// @param actualAmountOut Actual `amountOut` used to swap on the target chain
    function swapInvalidated(uint32 fromChainId, uint256 fromChainSwapId, uint256 actualAmountOut) external onlyRole(ROLE_SETTLEMENT_WORKER) {
        require(_totalShares > 0, "ERR_INVALID_TOTAL_SHARES");
        bytes32 universalSwapId = _getUniversalId(fromChainId, fromChainSwapId);
        require(_swapStatus[universalSwapId] == SwapStatus.Initiated, "ERR_INVALID_SWAP_STATUS");
        uint32 toChainId = _swapInfo[universalSwapId].toChainId;

        uint256 amountOut = _swapInfo[universalSwapId].amountOut;
        chainLockedAmount[toChainId] -= amountOut;
        _PCVs[toChainId] -= actualAmountOut;
        _totalPCV -= actualAmountOut;
        emit PCVsUpdated(TxType.Swap, fromChainSwapId, fromChainId, toChainId, 0, actualAmountOut);

        _swapStatus[universalSwapId] = SwapStatus.Completed;
        emit SwapCompleted(CompleteSwapType.Invalidated, fromChainId, fromChainSwapId, actualAmountOut);
    }

    /// @notice This function is called whenever the swap is not completed in time on a periphery chain
    /// This is the bad case where YPool worker did not close(read: settle) a swap in time, perhaps due to not enough liquidity
    /// `amountOut` of liquidity on the target chain will be unlocked
    /// @param fromChainId Chain Id of the source chain
    /// @param fromChainSwapId Nonce of the swap on the source chain
    function timeoutUnlockLiquidity(uint32 fromChainId, uint256 fromChainSwapId) external onlyRole(ROLE_SETTLEMENT_WORKER) {
        require(_totalShares > 0, "ERR_INVALID_TOTAL_SHARES");
        bytes32 universalSwapId = _getUniversalId(fromChainId, fromChainSwapId);
        require(_swapStatus[universalSwapId] == SwapStatus.Initiated, "ERR_INVALID_SWAP_STATUS");
        uint32 toChainId = _swapInfo[universalSwapId].toChainId;

        uint256 amountOut = _swapInfo[universalSwapId].amountOut;
        chainLockedAmount[toChainId] -= amountOut;
        _swapStatus[universalSwapId] = SwapStatus.Completed;
        emit SwapCompleted(CompleteSwapType.Timeout, fromChainId, fromChainSwapId, 0);
    }

    /// @notice This function is called whenever a user request to claim rebalance reward on a periphery chain
    /// @param chainId Chain Id of the periphery chain
    /// @param claimRewardId Nonce of the claim rebalance reward request on the periphery chain
    /// @param account User Id
    function claimRebalanceReward(uint32 chainId, uint256 claimRewardId, bytes32 account) external onlyRole(ROLE_SETTLEMENT_WORKER) {
        bytes32 universalClaimRRId = _getUniversalId(chainId, claimRewardId);
        require(_claimRRStatus[universalClaimRRId] != ClaimRRStatus.Completed, "ERR_CLAIM_REBALANCE_REWARD_COMPLETED");
        _claimRRStatus[universalClaimRRId] = ClaimRRStatus.Completed;
        require(account != bytes32(0), "ERR_INVALID_ACCOUNT");
        uint256 rebalanceRewardBalance = rebalanceReward[account];
        rebalanceReward[account] = 0;
        emit RebalanceRewardClaimed(chainId, claimRewardId, account, rebalanceRewardBalance);
    }

    /// @notice This function sets the current pcv and total shares
    /// @dev [WARNING] This function should only be called *only* when settlement contract is not
    /// consistent with the ypool vault on periphery chains. Other status on this contract might
    /// become stale as the consequence.
    /// @param chainId Chain Id of the periphery chain
    /// @param newPCV New value of PCV
    /// @param newTotalShares New total shares
    function updateChainPCVTotalShares(uint32 chainId, uint256 newPCV, uint256 newTotalShares) external onlyRole(ROLE_OWNER) {
        uint256 oldPCV = _PCVs[chainId];
        require(newPCV > chainLockedAmount[chainId], "ERR_INVALID_NEW_CHAIN_PCV");
        _PCVs[chainId] = newPCV;
        if (newPCV > oldPCV) {
            _totalPCV += newPCV - oldPCV;
            emit PCVsUpdated(TxType.Force, 0 , chainId, 0, newPCV - oldPCV, 0);
        } else if (newPCV < oldPCV){
            _totalPCV -= oldPCV - newPCV;
            emit PCVsUpdated(TxType.Force, 0, 0, chainId, 0, oldPCV - newPCV);
        }

        uint256 oldTotalShares = _totalShares;
        _totalShares = newTotalShares;
        if (newTotalShares > oldTotalShares) {
            emit TotalShareUpdated(newTotalShares - oldTotalShares, 0);
        } else if (newTotalShares < oldTotalShares) {
            emit TotalShareUpdated(0, oldTotalShares - newTotalShares);
        }
    }

    /* ========== EVENTS ========== */

    event FeeStructureSet(uint32 _toChainId, uint256 _min, uint256 _max, uint256 _rate, uint256 _decimals);
    event Deposit(uint32 _chainId, uint256 _depositId, bytes32 indexed _account, uint256 _amount, uint256 _shareAmount);
    event Withdrawn(uint32 _chainId, uint256 _withdrawId, bytes32 indexed _account, uint256 _shareAmount, uint256 _withdrawnAmount, uint256 _fee, uint256 _yieldRate);
    event CrossChainSwapInitiated(uint32 _fromChainId, uint32 _toChainId, uint256 _fromChainSwapId, uint256 _amountIn, uint256 _amountOut, uint256 _gasFee);
    event Earned(uint32 _fromChainId, uint32 _toChainId, uint256 _fromChainSwapId, uint256 _revenue, uint256 _gasFee);
    event PCVsUpdated(TxType _txType, uint256 _txId, uint32 _fromChainId, uint32 _toChainId, uint256 _amountIn, uint256 _amountOut);
    event TotalShareUpdated(uint256 _amountIn, uint256 _amountOut);
    event SwapCompleted(CompleteSwapType _completeType, uint32 _fromChainId, uint256 _fromChainSwapId, uint256 _amountOut);
    event RebalanceRewardAdded(bytes32 _account, uint256 _oldFromToPCVProduct, uint256 _newFromToPCVProduct, uint256 _rebalanceRewardRate, uint256 _rebalanceReward);
    event RebalanceRewardClaimed(uint32 _chainId, uint256 _nonce, bytes32 _account, uint256 _amount);
    event RebalanceRewardLimitUpdated(uint256 _limit);
    event RebalanceRewardPeriodUpdated(uint256 _period);
}
