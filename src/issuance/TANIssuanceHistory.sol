// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity ^0.8.26;

import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ISimplePlugin } from "../interfaces/ISimplePlugin.sol";

/**
 * @title TANIssuanceHistory
 * @author Robriks 📯️📯️📯️.eth
 * @notice A Telcoin Contract
 *
 * @notice This contract persists historical information related to TAN Issuance onchain
 * The stored data is required for TAN Issuance rewards calculations, specifically rewards caps
 * It is designed to serve as the `increaser` for a Telcoin `SimplePlugin` module
 * which is attached to the canonical TEL `StakingModule` contract.
 */
contract TANIssuanceHistory is Ownable {
    using Checkpoints for Checkpoints.Trace224;
    using SafeERC20 for IERC20;

    error ERC6372InconsistentClock();
    error IncompatiblePlugin();
    error InvalidAddress(address invalidAddress);
    error InvalidBlock(uint256 endBlock);
    error FutureLookup(uint256 queriedBlock, uint48 clockBlock);
    error IncreaseClaimableByFailed(address account, uint256 amount);

    struct IssuanceReward {
        address account;
        uint256 amount;
    }

    ISimplePlugin public tanIssuancePlugin;
    IERC20 public immutable tel;

    mapping(address => Checkpoints.Trace224) private _cumulativeRewards;

    uint256 public lastSettlementBlock;

    /// @notice Emitted when users' (temporarily mocked) claimable rewards are increased
    event ClaimableIncreased(address indexed account, uint256 oldClaimable, uint256 newClaimable);

    constructor(ISimplePlugin tanIssuancePlugin_, address owner_) Ownable(owner_) {
        tanIssuancePlugin = tanIssuancePlugin_;
        tel = tanIssuancePlugin.tel();
    }

    /**
     * Views
     */

    /// @dev Returns the current cumulative rewards for an account
    function cumulativeRewards(address account) public view returns (uint256) {
        return _cumulativeRewards[account].latest();
    }

    /// @dev Returns the cumulative rewards for an account at the **end** of the supplied block
    function cumulativeRewardsAtBlock(address account, uint256 queryBlock) external view returns (uint256) {
        uint32 validatedBlock = _validateQueryBlock(queryBlock);
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
        returns (address[] memory, uint256[] memory)
    {
        uint32 validatedBlock;
        if (queryBlock == 0) {
            // no need for safecast when dealing with global block number variable
            validatedBlock = uint32(block.number);
        } else {
            validatedBlock = _validateQueryBlock(queryBlock);
        }

        uint256 len = accounts.length;
        uint256[] memory rewards = new uint256[](accounts.length);
        for (uint256 i; i < len; ++i) {
            rewards[i] = _cumulativeRewardsAtBlock(accounts[i], validatedBlock);
        }

        return (accounts, rewards);
    }

    /// @dev The active status of this contract is tethered to its designated plugin
    function deactivated() public view returns (bool) {
        return tanIssuancePlugin.deactivated();
    }

    /**
     * Writes
     */

    /// @dev Saves the settlement block, updates cumulative rewards history, and settles TEL rewards on the plugin
    function increaseClaimableByBatch(IssuanceReward[] calldata rewards, uint256 endBlock) external onlyOwner {
        // ensure temporal ordering of reward settlements
        if (endBlock < lastSettlementBlock || endBlock > block.number) revert InvalidBlock(endBlock);
        lastSettlementBlock = endBlock;

        uint256 totalAmount = 0;
        uint256 len = rewards.length;
        for (uint256 i; i < len; ++i) {
            totalAmount += rewards[i].amount;
            _incrementCumulativeRewards(rewards[i].account, rewards[i].amount, endBlock);
        }

        // cache plugin in memory, set approval as `SimplePlugin::increaseClaimableBy()` pulls TEL from this address
        ISimplePlugin plugin = tanIssuancePlugin;
        tel.approve(address(plugin), totalAmount);
        for (uint256 i; i < len; ++i) {
            // event emission on this contract is omitted since the plugin emits a `ClaimableIncreased` event
            bool success = plugin.increaseClaimableBy(rewards[i].account, rewards[i].amount);
            if (!success) revert IncreaseClaimableByFailed(rewards[i].account, rewards[i].amount);
        }
    }

    /// @dev Permissioned function to set a new issuance plugin
    function setTanIssuancePlugin(ISimplePlugin newPlugin) external onlyOwner {
        if (newPlugin.tel() != tel) {
            revert IncompatiblePlugin();
        }
        tanIssuancePlugin = newPlugin;
    }

    /// @notice Rescues any tokens stuck on this contract
    /// @dev Provide `address(0x0)` to recover native gas token
    function rescueTokens(IERC20 token, address recipient) external onlyOwner {
        if (address(token) == address(0x0)) {
            uint256 bal = address(this).balance;
            (bool r,) = recipient.call{ value: bal }("");
            if (!r) revert InvalidAddress(recipient);
        } else {
            // for other ERC20 tokens, any tokens owned by this address are accidental; send the full balance.
            token.safeTransfer(recipient, token.balanceOf(address(this)));
        }
    }

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
    function _incrementCumulativeRewards(address account, uint256 amount, uint256 endBlock) internal {
        uint256 prevCumulativeReward = cumulativeRewards(account);
        uint224 newCumulativeReward = SafeCast.toUint224(prevCumulativeReward + amount);

        _cumulativeRewards[account].push(SafeCast.toUint32(endBlock), newCumulativeReward);
    }

    /// @dev Validate that user-supplied block is in the past, and return it as a uint48.
    function _validateQueryBlock(uint256 queryBlock) internal view returns (uint32) {
        uint48 currentBlock = clock();
        if (queryBlock > currentBlock) revert FutureLookup(queryBlock, currentBlock);
        return SafeCast.toUint32(queryBlock);
    }

    function _cumulativeRewardsAtBlock(address account, uint32 queryBlock) internal view returns (uint256) {
        return _cumulativeRewards[account].upperLookupRecent(queryBlock);
    }
}
