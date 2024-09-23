// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { AxelarGMPExecutable } from
    "@axelar-cgp-solidity/node_modules/@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarGMPExecutable.sol";
import { RecoverableWrapper } from "recoverable-wrapper/contracts/rwt/RecoverableWrapper.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RWTEL is RecoverableWrapper, AxelarGMPExecutable, UUPSUpgradeable, Ownable {
    /* RecoverableWrapper Storage Layout (Provided because RW is non-ERC7201 compliant)
     _______________________________________________________________________________________
    | Name              | Type                                                       | Slot |
    |-------------------|------------------------------------------------------------|------|
    | _balances         | mapping(address => uint256)                                | 0    |
    | _allowances       | mapping(address => mapping(address => uint256))            | 1    |
    | _totalSupply      | uint256                                                    | 2    |
    | _name             | string                                                     | 3    |
    | _symbol           | string                                                     | 4    |
    | _accountState     | mapping(address => struct RecoverableWrapper.AccountState) | 5    |
    | frozen            | mapping(address => uint256)                                | 6    |
    | _unsettledRecords | mapping(address => struct RecordsDeque)                    | 7    |
    | unwrapDisabled    | mapping(address => bool)                                   | 8    |
    | _totalSupply      | uint256                                                    | 9    |
    | governanceAddress | address                                                    | 10   |
    */

    /// @dev Overrides for `ERC20` storage since `RecoverableWrapper` dep restricts them
    string internal _name_;
    string internal _symbol_;

    /// @dev Designed for AxelarGMPExecutable's required implementation of `_execute()`
    struct ExtCall {
        address target;
        uint256 value;
        bytes data;
    }

    event ExecutionFailed(bytes32 commandId, address target);

    /// @notice For use when deployed as singleton
    /// @dev Required by `RecoverableWrapper` and `AxelarGMPExecutable` deps to write immutable vars to bytecode
    constructor(
        address gateway_,
        string memory name_,
        string memory symbol_,
        uint256 recoverableWindow_,
        address governanceAddress_,
        address baseERC20_,
        uint16 maxToClean
    )
        AxelarGMPExecutable(gateway_)
        RecoverableWrapper(name_, symbol_, recoverableWindow_, governanceAddress_, baseERC20_, maxToClean)
    { }

    /**
     *
     *   upgradeability
     *
     */

    /// @notice Replaces `constructor` for use when deployed as a proxy implementation
    /// @dev This function and all functions invoked within are only available on devnet and testnet
    /// @param '' The `baseERC20_` param is set as an immutable variable in bytecode by
    /// `RecoverableWrapper::constructor()`
    /// Since it will never change, no assembly workaround function such as `setMaxToClean()` is implemented
    function initialize(
        string memory name_,
        string memory symbol_,
        address governanceAddress_,
        IERC20Metadata, /* baseERC20_ */
        uint16 maxToClean_,
        address owner_
    )
        public
        initializer
    {
        _initializeOwner(owner_);
        setName(name_);
        setSymbol(symbol_);
        setGovernanceAddress(governanceAddress_);
        setMaxToClean(maxToClean_);
    }

    function setName(string memory newName) public onlyOwner {
        _name_ = newName;
    }

    function setSymbol(string memory newSymbol) public onlyOwner {
        _symbol_ = newSymbol;
    }

    function setGovernanceAddress(address newGovernanceAddress) public onlyOwner {
        governanceAddress = newGovernanceAddress;
    }

    /// @notice Workaround function to alter `RecoverableWrapper::MAX_TO_CLEAN` without forking audited code
    /// Provided because `MAX_TO_CLEAN` may require alteration in the future, as opposed to `baseERC20`,
    /// @dev `MAX_TO_CLEAN` is stored in slot 11
    function setMaxToClean(uint16 newMaxToClean) public onlyOwner {
        assembly {
            sstore(11, newMaxToClean)
        }
    }

    /// @notice Overrides `RecoverableWrapper::ERC20::name()` which accesses a private var
    function name() public view virtual override returns (string memory) {
        return _name_;
    }

    /// @notice Overrides `RecoverableWrapper::ERC20::symbol()` which accesses a private var
    function symbol() public view virtual override returns (string memory) {
        return _symbol_;
    }

    /**
     *
     *   internals
     *
     */

    /// @notice Only invoked after `commandId` is verified by Axelar gateway, ie in the context of an incoming message
    /// @notice Params `sourceChain` and `sourceAddress` are not currently used for vanilla bridging but may later on
    function _execute(
        bytes32 commandId,
        string calldata, /* sourceChain */
        string calldata, /* sourceAddress */
        bytes calldata payload
    )
        internal
        virtual
        override
    {
        ExtCall memory bridgeMsg = abi.decode(payload, (ExtCall));
        address target = bridgeMsg.target;
        (bool res,) = target.call{ value: bridgeMsg.value }(bridgeMsg.data);
        // to prevent stuck messages, emit failure event rather than revert
        if (!res) emit ExecutionFailed(commandId, target);
    }

    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner { }
}
