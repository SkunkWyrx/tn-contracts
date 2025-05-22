// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity 0.8.26;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { StakeInfo, IStakeManager } from "../interfaces/IStakeManager.sol";
import { Issuance } from "./Issuance.sol";

/**
 * @title StakeManager
 * @author Telcoin Association
 * @notice A Telcoin Contract
 *
 * @notice This abstract contract provides modular management of consensus validator stake
 * @dev Designed for inheritance by the ConsensusRegistry
 */
abstract contract StakeManager is ERC721, EIP712, IStakeManager {
    address payable public issuance;
    uint24 public totalSupply;
    uint8 public stakeVersion;
    mapping(uint8 => StakeConfig) internal versions;
    mapping(address => StakeInfo) internal stakeInfo;
    mapping(address => Delegation) internal delegations;

    /// @dev Validators that unstake are permanently ejected by setting their index to `UNSTAKED`
    /// @notice Rejoining requires re-onboarding with new validator address, tokenId, stake, & index
    uint24 internal constant UNSTAKED = type(uint24).max;

    /// @dev EIP-712 typed struct hash used to enable delegated proof of stake
    bytes32 DELEGATION_TYPEHASH = keccak256(
        "Delegation(bytes32 blsPubkeyHash,address delegator,uint24 tokenId,uint8 validatorVersion,uint64 nonce)"
    );

    constructor(string memory name, string memory symbol) ERC721(name, symbol) { }

    /// @inheritdoc IStakeManager
    function stake(bytes calldata blsPubkey) external payable virtual;

    /// @inheritdoc IStakeManager
    function delegateStake(
        bytes calldata blsPubkey,
        address validatorAddress,
        bytes calldata validatorSig
    )
        external
        payable
        virtual;

    /// @inheritdoc IStakeManager
    function claimStakeRewards(address ecsdaPubkey) external virtual;

    /// @inheritdoc IStakeManager
    function unstake(address validatorAddress) external virtual;

    /// @inheritdoc IStakeManager
    function getRewards(address validatorAddress) public view virtual returns (uint232);

    /// @inheritdoc IStakeManager
    function getStakeInfo(address validatorAddress) public view virtual returns (StakeInfo memory) {
        return stakeInfo[validatorAddress];
    }

    /// @inheritdoc IStakeManager
    function stakeConfig(uint8 version) public view virtual returns (StakeConfig memory) {
        return versions[version];
    }

    /// @inheritdoc IStakeManager
    function getCurrentStakeConfig() public view returns (StakeConfig memory) {
        return versions[stakeVersion];
    }

    /// @inheritdoc IStakeManager
    function upgradeStakeVersion(StakeConfig calldata config) external virtual returns (uint8);

    /// @inheritdoc IStakeManager
    function allocateIssuance() external payable virtual override;

    /// @inheritdoc IStakeManager
    function delegationDigest(
        bytes memory blsPubkey,
        address validatorAddress,
        address delegator
    )
        external
        view
        override
        returns (bytes32)
    {
        uint24 tokenId = _checkConsensusNFTOwner(validatorAddress);
        uint64 nonce = delegations[validatorAddress].nonce;
        bytes32 blsPubkeyHash = keccak256(blsPubkey);
        bytes32 structHash =
            keccak256(abi.encode(DELEGATION_TYPEHASH, blsPubkeyHash, delegator, tokenId, stakeVersion, nonce));

        return _hashTypedData(structHash);
    }

    /**
     *
     *   ERC721
     *
     */

    /// @dev The StakeManager's ERC721 ledger serves a permissioning role over validators, requiring
    /// Telcoin governance to approve each node operator and manually issue them a `ConsensusNFT`
    /// @param to Refers to the struct member `ValidatorInfo.validatorAddress` in `IConsensusRegistry`
    /// @param tokenId Refers to the `ERC721::tokenId` which must be less than `UNSTAKED` and nonzero
    /// tokenIds must be minted in order unless overwriting a retired validator for storage efficiency
    /// @notice Access-gated in ConsensusRegistry to its owner, which is a Telcoin governance address
    function mint(address to, uint256 tokenId) external virtual;

    /// @dev In the case of malicious or erroneous node operator behavior, governance can use this function
    /// to burn a validator's `ConsensusNFT` and immediately eject from consensus committees if applicable
    /// @param from Refers to the struct member `ValidatorInfo.validatorAddress` in `IConsensusRegistry`
    /// @notice `from` will be marked `UNSTAKED` so the validator address cannot be reused
    /// @dev Intended for sparing use; only reverts if burning results in empty committee
    function burn(address from) external virtual;

    /// @notice Consensus NFTs are soulbound to validators and cannot be transferred unless burned
    function transferFrom(
        address,
        /* from */
        address,
        /* to */
        uint256 /* tokenId */
    )
        public
        virtual
        override
    {
        revert NotTransferable();
    }

    /// @notice Wouldn't do anything because transfers are disabled but explicitly disallow anyway
    function approve(address, /*to*/ uint256 /*tokenId*/ ) public virtual override {
        revert NotTransferable();
    }

    /// @notice Read-only mechanism, not yet live
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireOwned(tokenId);

        return _baseURI();
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return ""; // TEL svg
    }

    /**
     *
     *   internals
     *
     */
    function _claimStakeRewards(
        address validatorAddress,
        address recipient,
        uint8 validatorVersion
    )
        internal
        virtual
        returns (uint232)
    {
        // check rewards are claimable and send via the InterchainTEL contract
        uint232 rewards = _checkRewards(validatorAddress, validatorVersion);
        stakeInfo[validatorAddress].balance -= rewards;
        Issuance(issuance).distributeStakeReward(recipient, rewards);

        return rewards;
    }

    function _unstake(
        address validatorAddress,
        address recipient,
        uint256 tokenId,
        uint8 validatorVersion
    )
        internal
        virtual
        returns (uint256)
    {
        uint232 stakeAmt = versions[validatorVersion].stakeAmount;
        uint256 rewards = _getRewards(validatorAddress, stakeAmt);

        // wipe existing stakeInfo and burn the token
        StakeInfo storage info = stakeInfo[validatorAddress];
        uint232 bal = info.balance;
        info.balance = 0;
        if (--totalSupply == 0) revert InvalidSupply();
        _burn(tokenId);

        // forward outstanding stake balance to recipient through Issuance
        uint256 unstakeAmt;
        if (bal >= stakeAmt) {
            // recipient is entitled to full initial stake amount and any outstanding rewards
            unstakeAmt = stakeAmt;
        } else {
            // recipient has been slashed below initial stake; only outstanding bal will be sent
            unstakeAmt = bal;
            // consolidate remainder on the Issuance contract
            (bool r,) = issuance.call{ value: stakeAmt - bal }("");
            r;
        }

        // send `bal` if `rewards == 0`, or `stakeAmt` with nonzero `rewards` added from Issuance's balance
        Issuance(issuance).distributeStakeReward{ value: unstakeAmt }(recipient, rewards);

        return unstakeAmt + rewards;
    }

    function _checkRewards(address validatorAddress, uint8 validatorVersion) internal virtual returns (uint232) {
        uint232 initialStake = versions[validatorVersion].stakeAmount;
        uint232 rewards = _getRewards(validatorAddress, initialStake);

        if (rewards == 0 || rewards < versions[validatorVersion].minWithdrawAmount) {
            revert InsufficientRewards(rewards);
        }

        return rewards;
    }

    function _checkStakeValue(uint256 value, uint8 version) internal virtual returns (uint232) {
        if (value != versions[version].stakeAmount) revert InvalidStakeAmount(value);

        return uint232(value);
    }

    function _getRewards(address validatorAddress, uint232 initialStake) internal view virtual returns (uint232) {
        uint232 balance = stakeInfo[validatorAddress].balance;
        uint232 rewards = balance > initialStake ? balance - initialStake : 0;

        return rewards;
    }

    /// @dev Identifies the validator's rewards recipient, ie the stake originator
    /// @return _ Returns the validator's delegator if one exists, else the validator itself
    function _getRecipient(address validatorAddress) internal view returns (address) {
        Delegation storage delegation = delegations[validatorAddress];
        address recipient = delegation.delegator;
        if (recipient == address(0x0)) recipient = validatorAddress;

        return recipient;
    }

    /// @dev Reverts if the provided address doesn't correspond to an existing `tokenId` owned by `validatorAddress`
    function _checkConsensusNFTOwner(address validatorAddress) internal view returns (uint24) {
        uint24 tokenId = _getTokenId(validatorAddress);
        if (!_exists(tokenId)) revert InvalidTokenId(tokenId);
        if (ownerOf(tokenId) != validatorAddress) revert RequiresConsensusNFT();

        return tokenId;
    }

    function _getTokenId(address validatorAddress) internal view returns (uint24) {
        return stakeInfo[validatorAddress].tokenId;
    }

    function _exists(uint256 tokenId) internal view virtual returns (bool) {
        if (tokenId == 0 || tokenId >= UNSTAKED) revert InvalidTokenId(tokenId);
        return _ownerOf(tokenId) != address(0);
    }

    function _domainNameAndVersion() internal view virtual override returns (string memory, string memory) {
        return ("Telcoin StakeManager", "1");
    }
}
