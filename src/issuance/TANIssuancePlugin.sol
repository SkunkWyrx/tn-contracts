// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Temporary TANIssuancePlugin, oversimplified to avoid handling funds for now
contract TANIssuancePlugin {
    using Checkpoints for Checkpoints.Trace224;
    using SafeERC20 for IERC20;

    error ArityMismatch();
    error ERC6372InconsistentClock();
    error FutureLookup(uint256 queriedBlock, uint48 clockBlock);

    IERC20 public immutable tel;

    mapping(address => Checkpoints.Trace224) private _cumulativeRewards;

    uint256 public lastSettlementBlock;
    address public increaser;

    /// @notice Emitted when users' (temporarily mocked) claimable rewards are increased
    event ClaimableIncreased(address indexed account, uint256 oldClaimable, uint256 newClaimable);

    /// @notice Emitted when increaser changes
    event IncreaserChanged(address indexed oldIncreaser, address indexed newIncreaser);

    constructor(IERC20 tel_, address increaser_) {
        tel = tel_;
        increaser = increaser_;
    }

    modifier onlyIncreaser() {
        require(msg.sender == increaser, "SimplePlugin: Caller is not onlyIncreaser");
        _;
    }

    /// @dev Returns the current cumulative rewards for an account
    function cumulativeRewards(address account) external view returns (uint256) {
        return _cumulativeRewards[account].latest();
    }

    /// @dev Returns the cumulative rewards for an account at the **end** of the supplied block
    function cumulativeRewardsAtBlock(address account, uint256 queryBlock) external view returns (uint256) {
        uint48 validatedBlock = _validateQueryBlock(queryBlock);
        return _cumulativeRewards[account].upperLookupRecent(validatedBlock);
    }

    /// @dev Returns the cumulative rewards for `accounts` at the **end** of the supplied block
    /// @notice To query for the current block, supply `queryBlock == 0`
    function cumulativeRewardsAtBlockBatched(
        address[] calldata accounts,
        uint256 queryBlock
    )
        external
        view
        returns (uint256[] memory)
    {
        uint48 validatedBlock;
        if (queryBlock == 0) {
            validatedBlock = block.number;
        } else {
            validatedBlock = _validateQueryBlock(queryBlock);
        }

        uint256 len = accounts.length;
        uint256[] memory rewards = new uint256[](accounts.length);
        for (uint256 i; i < len; ++i) {
            rewards[i] = _cumulativeRewardsAtBlock(accounts[i], validatedBlock);
        }

        return rewards;
    }

    function settle(address[] calldata accounts, uint256[] calldata amounts) public onlyIncreaser {
        uint256 len = accounts.length;
        if (amounts.length != len) revert ArityMismatch();

        for (uint256 i; i < len; ++i) {
            uint256 prevCumulativeReward = SafeCast.toUint256(_cumulativeRewards[accounts[i]].latest());
            uint256 newCumulativeReward = prevCumulativeReward + amounts[i];

            _cumulativeRewards[accounts[i]].push(newCumulativeReward);

            // omitted claimable state updates
            // omitted approval logic

            emit ClaimableIncreased(accounts[i], prevCumulativeReward, newCumulativeReward);
        }
    }

    /// @dev May be needed if batch settling exceeds gas limit
    /// @notice Temporarily omitted modifier: whenNotDeactivated
    // function increaseClaimableBy(address account, uint256 amount) external onlyIncreaser returns (bool) {
    //     // if amount is zero do nothing; this is for backend compatibility with earlier `IPlugins`
    //     if (amount == 0) return false;

    //     uint256 prevCumulativeReward = SafeCast.toUint256(cumulativeRewards[account].latest());
    //     uint256 newCumulativeReward = prevCumulativeReward + amount;

    //     cumulativeRewards[account].push(newCumulativeReward);

    //     // omitted claimable state updates
    //     // omitted transfer logic

    //     emit ClaimableIncreased(account, prevCumulativeReward, newCumulativeReward);
    //     return true;
    // }

    /**
     * IPlugin
     */

    /// @dev Omitted

    /**
     * ERC6372
     */
    function clock() public view returns (uint48) {
        return Time.blockNumber();
    }

    function CLOCK_MODE() public view returns (string memory) {
        if (clock() != Time.blockNumber()) {
            revert ERC6372InconsistentClock();
        }
        return "mode=blocknumber&from=default";
    }

    /**
     * Internals
     */

    /// @dev Validate that user-supplied block is in the past, and return it as a uint48.
    function _validateQueryBlock(uint256 queryBlock) internal view returns (uint48) {
        uint48 currentBlock = clock();
        if (queryBlock >= currentBlock) revert FutureLookup(queryBlock, currentBlock);
        return SafeCast.toUint48(queryBlock);
    }

    function _cumulativeRewardsAtBlock(address account, uint256 queryBlock) internal view returns (uint256) {
        return _cumulativeRewards[account].upperLookupRecent(queryBlock);
    }
}
