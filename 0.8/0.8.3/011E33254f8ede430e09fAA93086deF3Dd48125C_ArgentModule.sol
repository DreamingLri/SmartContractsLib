// Copyright (C) 2021  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

import "./common/Utils.sol";
import "./common/BaseModule.sol";
import "./RelayerManager.sol";
import "./SecurityManager.sol";
import "./TransactionManager.sol";

/**
 * @title ArgentModule
 * @notice Single module for the Argent wallet.
 * @author Julien Niset - <[email protected]>
 */
contract ArgentModule is BaseModule, RelayerManager, SecurityManager, TransactionManager {

    bytes32 constant public NAME = "ArgentModule";

    constructor (
        IModuleRegistry _registry,
        IGuardianStorage _guardianStorage,
        ITransferStorage _userWhitelist,
        IAuthoriser _authoriser,
        address _uniswapRouter,
        uint256 _securityPeriod,
        uint256 _securityWindow,
        uint256 _recoveryPeriod,
        uint256 _lockPeriod
    )
        BaseModule(_registry, _guardianStorage, _userWhitelist, _authoriser, NAME)
        SecurityManager(_recoveryPeriod, _securityPeriod, _securityWindow, _lockPeriod)
        TransactionManager(_securityPeriod)
        RelayerManager(_uniswapRouter)
    {
        
    }

    /**
     * @inheritdoc IModule
     */
    function init(address _wallet) external override onlyWallet(_wallet) {
        enableDefaultStaticCalls(_wallet);
    }

    /**
    * @inheritdoc IModule
    */
    function addModule(address _wallet, address _module) external override onlyWalletOwnerOrSelf(_wallet) onlyWhenUnlocked(_wallet) {
        require(registry.isRegisteredModule(_module), "AM: module is not registered");
        IWallet(_wallet).authoriseModule(_module, true);
    }
    
    /**
     * @inheritdoc RelayerManager
     */
    function getRequiredSignatures(address _wallet, bytes calldata _data) public view override returns (uint256, OwnerSignature) {
        bytes4 methodId = Utils.functionPrefix(_data);

        if (methodId == TransactionManager.multiCall.selector ||
            methodId == TransactionManager.addToWhitelist.selector ||
            methodId == TransactionManager.removeFromWhitelist.selector ||
            methodId == TransactionManager.enableERC1155TokenReceiver.selector ||
            methodId == TransactionManager.clearSession.selector ||
            methodId == ArgentModule.addModule.selector ||
            methodId == SecurityManager.addGuardian.selector ||
            methodId == SecurityManager.revokeGuardian.selector ||
            methodId == SecurityManager.cancelGuardianAddition.selector ||
            methodId == SecurityManager.cancelGuardianRevokation.selector)
        {
            // owner
            return (1, OwnerSignature.Required);
        }
        if (methodId == TransactionManager.multiCallWithSession.selector) {
            return (1, OwnerSignature.Session);
        }
        if (methodId == SecurityManager.executeRecovery.selector) {
            // majority of guardians
            uint numberOfSignaturesRequired = _majorityOfGuardians(_wallet);
            require(numberOfSignaturesRequired > 0, "AM: no guardians set on wallet");
            return (numberOfSignaturesRequired, OwnerSignature.Disallowed);
        }
        if (methodId == SecurityManager.cancelRecovery.selector) {
            // majority of (owner + guardians)
            uint numberOfSignaturesRequired = Utils.ceil(recoveryConfigs[_wallet].guardianCount + 1, 2);
            return (numberOfSignaturesRequired, OwnerSignature.Optional);
        }
        if (methodId == TransactionManager.multiCallWithGuardians.selector ||
            methodId == TransactionManager.multiCallWithGuardiansAndStartSession.selector ||
            methodId == SecurityManager.transferOwnership.selector)
        {
            // owner + majority of guardians
            uint majorityGuardians = _majorityOfGuardians(_wallet);
            uint numberOfSignaturesRequired = majorityGuardians + 1;
            return (numberOfSignaturesRequired, OwnerSignature.Required);
        }
        if (methodId == SecurityManager.finalizeRecovery.selector ||
            methodId == SecurityManager.confirmGuardianAddition.selector ||
            methodId == SecurityManager.confirmGuardianRevokation.selector)
        {
            // anyone
            return (0, OwnerSignature.Anyone);
        }
        if (methodId == SecurityManager.lock.selector || methodId == SecurityManager.unlock.selector) {
            // any guardian
            return (1, OwnerSignature.Disallowed);
        }
        revert("SM: unknown method");
    }

    function _majorityOfGuardians(address _wallet) internal view returns (uint) {
        return Utils.ceil(guardianStorage.guardianCount(_wallet), 2);
    }
}

// Copyright (C) 2020  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

/**
 * @title Utils
 * @notice Common utility methods used by modules.
 */
library Utils {

    // ERC20, ERC721 & ERC1155 transfers & approvals
    bytes4 private constant ERC20_TRANSFER = bytes4(keccak256("transfer(address,uint256)"));
    bytes4 private constant ERC20_APPROVE = bytes4(keccak256("approve(address,uint256)"));
    bytes4 private constant ERC721_SET_APPROVAL_FOR_ALL = bytes4(keccak256("setApprovalForAll(address,bool)"));
    bytes4 private constant ERC721_TRANSFER_FROM = bytes4(keccak256("transferFrom(address,address,uint256)"));
    bytes4 private constant ERC721_SAFE_TRANSFER_FROM = bytes4(keccak256("safeTransferFrom(address,address,uint256)"));
    bytes4 private constant ERC721_SAFE_TRANSFER_FROM_BYTES = bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)"));
    bytes4 private constant ERC1155_SAFE_TRANSFER_FROM = bytes4(keccak256("safeTransferFrom(address,address,uint256,uint256,bytes)"));

    bytes4 private constant OWNER_SIG = 0x8da5cb5b;
    /**
    * @notice Helper method to recover the signer at a given position from a list of concatenated signatures.
    * @param _signedHash The signed hash
    * @param _signatures The concatenated signatures.
    * @param _index The index of the signature to recover.
    */
    function recoverSigner(bytes32 _signedHash, bytes memory _signatures, uint _index) internal pure returns (address) {
        uint8 v;
        bytes32 r;
        bytes32 s;
        // we jump 32 (0x20) as the first slot of bytes contains the length
        // we jump 65 (0x41) per signature
        // for v we load 32 bytes ending with v (the first 31 come from s) then apply a mask
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(_signatures, add(0x20,mul(0x41,_index))))
            s := mload(add(_signatures, add(0x40,mul(0x41,_index))))
            v := and(mload(add(_signatures, add(0x41,mul(0x41,_index)))), 0xff)
        }
        require(v == 27 || v == 28, "Utils: bad v value in signature");

        address recoveredAddress = ecrecover(_signedHash, v, r, s);
        require(recoveredAddress != address(0), "Utils: ecrecover returned 0");
        return recoveredAddress;
    }

    /**
    * @notice Helper method to recover the spender from a contract call. 
    * The method returns the contract unless the call is to a standard method of a ERC20/ERC721/ERC1155 token
    * in which case the spender is recovered from the data.
    * @param _to The target contract.
    * @param _data The data payload.
    */
    function recoverSpender(address _to, bytes memory _data) internal pure returns (address spender) {
        if(_data.length >= 68) {
            bytes4 methodId;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                methodId := mload(add(_data, 0x20))
            }
            if(
                methodId == ERC20_TRANSFER ||
                methodId == ERC20_APPROVE ||
                methodId == ERC721_SET_APPROVAL_FOR_ALL) 
            {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    spender := mload(add(_data, 0x24))
                }
                return spender;
            }
            if(
                methodId == ERC721_TRANSFER_FROM ||
                methodId == ERC721_SAFE_TRANSFER_FROM ||
                methodId == ERC721_SAFE_TRANSFER_FROM_BYTES ||
                methodId == ERC1155_SAFE_TRANSFER_FROM)
            {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    spender := mload(add(_data, 0x44))
                }
                return spender;
            }
        }

        spender = _to;
    }

    /**
    * @notice Helper method to parse data and extract the method signature.
    */
    function functionPrefix(bytes memory _data) internal pure returns (bytes4 prefix) {
        require(_data.length >= 4, "Utils: Invalid functionPrefix");
        // solhint-disable-next-line no-inline-assembly
        assembly {
            prefix := mload(add(_data, 0x20))
        }
    }

    /**
    * @notice Checks if an address is a contract.
    * @param _addr The address.
    */
    function isContract(address _addr) internal view returns (bool) {
        uint32 size;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }

    /**
    * @notice Checks if an address is a guardian or an account authorised to sign on behalf of a smart-contract guardian
    * given a list of guardians.
    * @param _guardians the list of guardians
    * @param _guardian the address to test
    * @return true and the list of guardians minus the found guardian upon success, false and the original list of guardians if not found.
    */
    function isGuardianOrGuardianSigner(address[] memory _guardians, address _guardian) internal view returns (bool, address[] memory) {
        if (_guardians.length == 0 || _guardian == address(0)) {
            return (false, _guardians);
        }
        bool isFound = false;
        address[] memory updatedGuardians = new address[](_guardians.length - 1);
        uint256 index = 0;
        for (uint256 i = 0; i < _guardians.length; i++) {
            if (!isFound) {
                // check if _guardian is an account guardian
                if (_guardian == _guardians[i]) {
                    isFound = true;
                    continue;
                }
                // check if _guardian is the owner of a smart contract guardian
                if (isContract(_guardians[i]) && isGuardianOwner(_guardians[i], _guardian)) {
                    isFound = true;
                    continue;
                }
            }
            if (index < updatedGuardians.length) {
                updatedGuardians[index] = _guardians[i];
                index++;
            }
        }
        return isFound ? (true, updatedGuardians) : (false, _guardians);
    }

    /**
    * @notice Checks if an address is the owner of a guardian contract.
    * The method does not revert if the call to the owner() method consumes more then 25000 gas.
    * @param _guardian The guardian contract
    * @param _owner The owner to verify.
    */
    function isGuardianOwner(address _guardian, address _owner) internal view returns (bool) {
        address owner = address(0);

        // solhint-disable-next-line no-inline-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,OWNER_SIG)
            let result := staticcall(25000, _guardian, ptr, 0x20, ptr, 0x20)
            if eq(result, 1) {
                owner := mload(ptr)
            }
        }
        return owner == _owner;
    }

    /**
    * @notice Returns ceil(a / b).
    */
    function ceil(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a / b;
        if (a % b == 0) {
            return c;
        } else {
            return c + 1;
        }
    }
}

// Copyright (C) 2018  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

import "../../interfaces/IAuthoriser.sol";
import "../../wallet/IWallet.sol";
import "../../infrastructure/IModuleRegistry.sol";
import "../../infrastructure/storage/IGuardianStorage.sol";
import "../../infrastructure/storage/ITransferStorage.sol";
import "./IModule.sol";
import "../../interfaces/IERC20.sol";

/**
 * @title BaseModule
 * @notice Base Module contract that contains methods common to all Modules.
 * @author Julien Niset - <[email protected]>, Olivier VDB - <[email protected]>
 */
abstract contract BaseModule is IModule {

    // Empty calldata
    bytes constant internal EMPTY_BYTES = "";
    // Mock token address for ETH
    address constant internal ETH_TOKEN = address(0);

    // The module registry
    IModuleRegistry internal immutable registry;
    // The guardians storage
    IGuardianStorage internal immutable guardianStorage;
    // The trusted contacts storage
    ITransferStorage internal immutable userWhitelist;
    // The authoriser
    IAuthoriser internal immutable authoriser;

    event ModuleCreated(bytes32 name);

    enum OwnerSignature {
        Anyone,             // Anyone
        Required,           // Owner required
        Optional,           // Owner and/or guardians
        Disallowed,         // Guardians only
        Session             // Session only
    }

    struct Session {
        address key;
        uint64 expires;
    }

    // Maps wallet to session
    mapping (address => Session) internal sessions;

    struct Lock {
        // the lock's release timestamp
        uint64 release;
        // the signature of the method that set the last lock
        bytes4 locker;
    }
    
    // Wallet specific lock storage
    mapping (address => Lock) internal locks;

    /**
     * @notice Throws if the wallet is not locked.
     */
    modifier onlyWhenLocked(address _wallet) {
        require(_isLocked(_wallet), "BM: wallet must be locked");
        _;
    }

    /**
     * @notice Throws if the wallet is locked.
     */
    modifier onlyWhenUnlocked(address _wallet) {
        require(!_isLocked(_wallet), "BM: wallet locked");
        _;
    }

    /**
     * @notice Throws if the sender is not the module itself.
     */
    modifier onlySelf() {
        require(_isSelf(msg.sender), "BM: must be module");
        _;
    }

    /**
     * @notice Throws if the sender is not the module itself or the owner of the target wallet.
     */
    modifier onlyWalletOwnerOrSelf(address _wallet) {
        require(_isSelf(msg.sender) || _isOwner(_wallet, msg.sender), "BM: must be wallet owner/self");
        _;
    }

    /**
     * @dev Throws if the sender is not the target wallet of the call.
     */
    modifier onlyWallet(address _wallet) {
        require(msg.sender == _wallet, "BM: caller must be wallet");
        _;
    }

    constructor(
        IModuleRegistry _registry,
        IGuardianStorage _guardianStorage,
        ITransferStorage _userWhitelist,
        IAuthoriser _authoriser,
        bytes32 _name
    ) {
        registry = _registry;
        guardianStorage = _guardianStorage;
        userWhitelist = _userWhitelist;
        authoriser = _authoriser;
        emit ModuleCreated(_name);
    }

    /**
     * @notice Moves tokens that have been sent to the module by mistake.
     * @param _token The target token.
     */
    function recoverToken(address _token) external {
        uint total = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transfer(address(registry), total);
    }

    function _clearSession(address _wallet) internal {
        delete sessions[_wallet];
    }
    
    /**
     * @notice Helper method to check if an address is the owner of a target wallet.
     * @param _wallet The target wallet.
     * @param _addr The address.
     */
    function _isOwner(address _wallet, address _addr) internal view returns (bool) {
        return IWallet(_wallet).owner() == _addr;
    }

    /**
     * @notice Helper method to check if a wallet is locked.
     * @param _wallet The target wallet.
     */
    function _isLocked(address _wallet) internal view returns (bool) {
        return locks[_wallet].release > uint64(block.timestamp);
    }

    /**
     * @notice Helper method to check if an address is the module itself.
     * @param _addr The target address.
     */
    function _isSelf(address _addr) internal view returns (bool) {
        return _addr == address(this);
    }

    /**
     * @notice Helper method to invoke a wallet.
     * @param _wallet The target wallet.
     * @param _to The target address for the transaction.
     * @param _value The value of the transaction.
     * @param _data The data of the transaction.
     */
    function invokeWallet(address _wallet, address _to, uint256 _value, bytes memory _data) internal returns (bytes memory _res) {
        bool success;
        (success, _res) = _wallet.call(abi.encodeWithSignature("invoke(address,uint256,bytes)", _to, _value, _data));
        if (success && _res.length > 0) { //_res is empty if _wallet is an "old" BaseWallet that can't return output values
            (_res) = abi.decode(_res, (bytes));
        } else if (_res.length > 0) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        } else if (!success) {
            revert("BM: wallet invoke reverted");
        }
    }
}

// Copyright (C) 2018  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./common/Utils.sol";
import "./common/BaseModule.sol";
import "./common/SimpleOracle.sol";
import "../infrastructure/storage/IGuardianStorage.sol";

/**
 * @title RelayerManager
 * @notice Abstract Module to execute transactions signed by ETH-less accounts and sent by a relayer.
 * @author Julien Niset <[email protected]>, Olivier VDB <[email protected]>
 */
abstract contract RelayerManager is BaseModule, SimpleOracle {

    uint256 constant internal BLOCKBOUND = 10000;

    mapping (address => RelayerConfig) internal relayer;

    struct RelayerConfig {
        uint256 nonce;
        mapping (bytes32 => bool) executedTx;
    }

    // Used to avoid stack too deep error
    struct StackExtension {
        uint256 requiredSignatures;
        OwnerSignature ownerSignatureRequirement;
        bytes32 signHash;
        bool success;
        bytes returnData;
    }

    event TransactionExecuted(address indexed wallet, bool indexed success, bytes returnData, bytes32 signedHash);
    event Refund(address indexed wallet, address indexed refundAddress, address refundToken, uint256 refundAmount);

    // *************** Constructor ************************ //

    constructor(address _uniswapRouter) SimpleOracle(_uniswapRouter) {

    }

    /* ***************** External methods ************************* */

    /**
    * @notice Gets the number of valid signatures that must be provided to execute a
    * specific relayed transaction.
    * @param _wallet The target wallet.
    * @param _data The data of the relayed transaction.
    * @return The number of required signatures and the wallet owner signature requirement.
    */
    function getRequiredSignatures(address _wallet, bytes calldata _data) public view virtual returns (uint256, OwnerSignature);

    /**
    * @notice Executes a relayed transaction.
    * @param _wallet The target wallet.
    * @param _data The data for the relayed transaction
    * @param _nonce The nonce used to prevent replay attacks.
    * @param _signatures The signatures as a concatenated byte array.
    * @param _gasPrice The max gas price (in token) to use for the gas refund.
    * @param _gasLimit The max gas limit to use for the gas refund.
    * @param _refundToken The token to use for the gas refund.
    * @param _refundAddress The address refunded to prevent front-running.
    */
    function execute(
        address _wallet,
        bytes calldata _data,
        uint256 _nonce,
        bytes calldata _signatures,
        uint256 _gasPrice,
        uint256 _gasLimit,
        address _refundToken,
        address _refundAddress
    )
        external
        returns (bool)
    {
        // initial gas = 21k + non_zero_bytes * 16 + zero_bytes * 4
        //            ~= 21k + calldata.length * [1/3 * 16 + 2/3 * 4]
        uint256 startGas = gasleft() + 21000 + msg.data.length * 8;
        require(startGas >= _gasLimit, "RM: not enough gas provided");
        require(verifyData(_wallet, _data), "RM: Target of _data != _wallet");

        require(!_isLocked(_wallet) || _gasPrice == 0, "RM: Locked wallet refund");

        StackExtension memory stack;
        (stack.requiredSignatures, stack.ownerSignatureRequirement) = getRequiredSignatures(_wallet, _data);

        require(stack.requiredSignatures > 0 || stack.ownerSignatureRequirement == OwnerSignature.Anyone, "RM: Wrong signature requirement");
        require(stack.requiredSignatures * 65 == _signatures.length, "RM: Wrong number of signatures");
        stack.signHash = getSignHash(
            address(this),
            0,
            _data,
            _nonce,
            _gasPrice,
            _gasLimit,
            _refundToken,
            _refundAddress);
        require(checkAndUpdateUniqueness(
            _wallet,
            _nonce,
            stack.signHash,
            stack.requiredSignatures,
            stack.ownerSignatureRequirement), "RM: Duplicate request");

        if (stack.ownerSignatureRequirement == OwnerSignature.Session) {
            require(validateSession(_wallet, stack.signHash, _signatures), "RM: Invalid session");
        } else {
            require(validateSignatures(_wallet, stack.signHash, _signatures, stack.ownerSignatureRequirement), "RM: Invalid signatures");
        }
        (stack.success, stack.returnData) = address(this).call(_data);
        refund(
            _wallet,
            startGas,
            _gasPrice,
            _gasLimit,
            _refundToken,
            _refundAddress,
            stack.requiredSignatures,
            stack.ownerSignatureRequirement);
        emit TransactionExecuted(_wallet, stack.success, stack.returnData, stack.signHash);
        return stack.success;
    }

    /**
    * @notice Gets the current nonce for a wallet.
    * @param _wallet The target wallet.
    */
    function getNonce(address _wallet) external view returns (uint256 nonce) {
        return relayer[_wallet].nonce;
    }

    /**
    * @notice Checks if a transaction identified by its sign hash has already been executed.
    * @param _wallet The target wallet.
    * @param _signHash The sign hash of the transaction.
    */
    function isExecutedTx(address _wallet, bytes32 _signHash) external view returns (bool executed) {
        return relayer[_wallet].executedTx[_signHash];
    }

    /**
    * @notice Gets the last stored session for a wallet.
    * @param _wallet The target wallet.
    */
    function getSession(address _wallet) external view returns (address key, uint64 expires) {
        return (sessions[_wallet].key, sessions[_wallet].expires);
    }

    /* ***************** Internal & Private methods ************************* */

    /**
    * @notice Generates the signed hash of a relayed transaction according to ERC 1077.
    * @param _from The starting address for the relayed transaction (should be the relayer module)
    * @param _value The value for the relayed transaction.
    * @param _data The data for the relayed transaction which includes the wallet address.
    * @param _nonce The nonce used to prevent replay attacks.
    * @param _gasPrice The max gas price (in token) to use for the gas refund.
    * @param _gasLimit The max gas limit to use for the gas refund.
    * @param _refundToken The token to use for the gas refund.
    * @param _refundAddress The address refunded to prevent front-running.
    */
    function getSignHash(
        address _from,
        uint256 _value,
        bytes memory _data,
        uint256 _nonce,
        uint256 _gasPrice,
        uint256 _gasLimit,
        address _refundToken,
        address _refundAddress
    )
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encodePacked(
                    bytes1(0x19),
                    bytes1(0),
                    _from,
                    _value,
                    _data,
                    block.chainid,
                    _nonce,
                    _gasPrice,
                    _gasLimit,
                    _refundToken,
                    _refundAddress))
        ));
    }

    /**
    * @notice Checks if the relayed transaction is unique. If yes the state is updated.
    * For actions requiring 1 signature by the owner or a session key we use the incremental nonce.
    * For all other actions we check/store the signHash in a mapping.
    * @param _wallet The target wallet.
    * @param _nonce The nonce.
    * @param _signHash The signed hash of the transaction.
    * @param requiredSignatures The number of signatures required.
    * @param ownerSignatureRequirement The wallet owner signature requirement.
    * @return true if the transaction is unique.
    */
    function checkAndUpdateUniqueness(
        address _wallet,
        uint256 _nonce,
        bytes32 _signHash,
        uint256 requiredSignatures,
        OwnerSignature ownerSignatureRequirement
    )
        internal
        returns (bool)
    {
        if (requiredSignatures == 1 &&
            (ownerSignatureRequirement == OwnerSignature.Required || ownerSignatureRequirement == OwnerSignature.Session)) {
            // use the incremental nonce
            if (_nonce <= relayer[_wallet].nonce) {
                return false;
            }
            uint256 nonceBlock = (_nonce & 0xffffffffffffffffffffffffffffffff00000000000000000000000000000000) >> 128;
            if (nonceBlock > block.number + BLOCKBOUND) {
                return false;
            }
            relayer[_wallet].nonce = _nonce;
            return true;
        } else {
            // use the txHash map
            if (relayer[_wallet].executedTx[_signHash] == true) {
                return false;
            }
            relayer[_wallet].executedTx[_signHash] = true;
            return true;
        }
    }

    /**
    * @notice Validates the signatures provided with a relayed transaction.
    * @param _wallet The target wallet.
    * @param _signHash The signed hash representing the relayed transaction.
    * @param _signatures The signatures as a concatenated bytes array.
    * @param _option An OwnerSignature enum indicating whether the owner is required, optional or disallowed.
    * @return A boolean indicating whether the signatures are valid.
    */
    function validateSignatures(address _wallet, bytes32 _signHash, bytes memory _signatures, OwnerSignature _option) internal view returns (bool)
    {
        if (_signatures.length == 0) {
            return true;
        }
        address lastSigner = address(0);
        address[] memory guardians;
        if (_option != OwnerSignature.Required || _signatures.length > 65) {
            guardians = guardianStorage.getGuardians(_wallet); // guardians are only read if they may be needed
        }
        bool isGuardian;

        for (uint256 i = 0; i < _signatures.length / 65; i++) {
            address signer = Utils.recoverSigner(_signHash, _signatures, i);

            if (i == 0) {
                if (_option == OwnerSignature.Required) {
                    // First signer must be owner
                    if (_isOwner(_wallet, signer)) {
                        continue;
                    }
                    return false;
                } else if (_option == OwnerSignature.Optional) {
                    // First signer can be owner
                    if (_isOwner(_wallet, signer)) {
                        continue;
                    }
                }
            }
            if (signer <= lastSigner) {
                return false; // Signers must be different
            }
            lastSigner = signer;
            (isGuardian, guardians) = Utils.isGuardianOrGuardianSigner(guardians, signer);
            if (!isGuardian) {
                return false;
            }
        }
        return true;
    }

    /**
    * @notice Validates the signature provided when a session key was used.
    * @param _wallet The target wallet.
    * @param _signHash The signed hash representing the relayed transaction.
    * @param _signatures The signatures as a concatenated bytes array.
    * @return A boolean indicating whether the signature is valid.
    */
    function validateSession(address _wallet, bytes32 _signHash, bytes calldata _signatures) internal view returns (bool) { 
        Session memory session = sessions[_wallet];
        address signer = Utils.recoverSigner(_signHash, _signatures, 0);
        return (signer == session.key && session.expires >= block.timestamp);
    }

    /**
    * @notice Refunds the gas used to the Relayer.
    * @param _wallet The target wallet.
    * @param _startGas The gas provided at the start of the execution.
    * @param _gasPrice The max gas price (in token) for the refund.
    * @param _gasLimit The max gas limit for the refund.
    * @param _refundToken The token to use for the gas refund.
    * @param _refundAddress The address refunded to prevent front-running.
    * @param _requiredSignatures The number of signatures required.
    * @param _option An OwnerSignature enum indicating the signature requirement.
    */
    function refund(
        address _wallet,
        uint _startGas,
        uint _gasPrice,
        uint _gasLimit,
        address _refundToken,
        address _refundAddress,
        uint256 _requiredSignatures,
        OwnerSignature _option
    )
        internal
    {
        // Only refund when the owner is one of the signers or a session key was used
        if (_gasPrice > 0 && (_option == OwnerSignature.Required || _option == OwnerSignature.Session)) {
            address refundAddress = _refundAddress == address(0) ? msg.sender : _refundAddress;
            if (_requiredSignatures == 1 && _option == OwnerSignature.Required) {
                    // refundAddress must be whitelisted/authorised
                    if (!authoriser.isAuthorised(_wallet, refundAddress, address(0), EMPTY_BYTES)) {
                        uint whitelistAfter = userWhitelist.getWhitelist(_wallet, refundAddress);
                        require(whitelistAfter > 0 && whitelistAfter < block.timestamp, "RM: refund not authorised");
                    }
            }
            uint256 refundAmount;
            if (_refundToken == ETH_TOKEN) {
                // 23k as an upper bound to cover the rest of refund logic
                uint256 gasConsumed = _startGas - gasleft() + 23000;
                refundAmount = Math.min(gasConsumed, _gasLimit) * (Math.min(_gasPrice, tx.gasprice));
                invokeWallet(_wallet, refundAddress, refundAmount, EMPTY_BYTES);
            } else {
                // 37.5k as an upper bound to cover the rest of refund logic
                uint256 gasConsumed = _startGas - gasleft() + 37500;
                uint256 tokenGasPrice = inToken(_refundToken, tx.gasprice);
                refundAmount = Math.min(gasConsumed, _gasLimit) * (Math.min(_gasPrice, tokenGasPrice));
                bytes memory methodData = abi.encodeWithSelector(IERC20.transfer.selector, refundAddress, refundAmount);
                bytes memory transferSuccessBytes = invokeWallet(_wallet, _refundToken, 0, methodData);
                // Check token refund is successful, when `transfer` returns a success bool result
                if (transferSuccessBytes.length > 0) {
                    require(abi.decode(transferSuccessBytes, (bool)), "RM: Refund transfer failed");
                }
            }
            emit Refund(_wallet, refundAddress, _refundToken, refundAmount);    
        }
    }

    /**
    * @notice Checks that the wallet address provided as the first parameter of _data matches _wallet
    * @return false if the addresses are different.
    */
    function verifyData(address _wallet, bytes calldata _data) internal pure returns (bool) {
        require(_data.length >= 36, "RM: Invalid dataWallet");
        address dataWallet = abi.decode(_data[4:], (address));
        return dataWallet == _wallet;
    }
}

// Copyright (C) 2018  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./common/Utils.sol";
import "./common/BaseModule.sol";
import "../wallet/IWallet.sol";

/**
 * @title SecurityManager
 * @notice Abstract module implementing the key security features of the wallet: guardians, lock and recovery.
 * @author Julien Niset - <[email protected]>
 * @author Olivier Van Den Biggelaar - <[email protected]>
 */
abstract contract SecurityManager is BaseModule {

    struct RecoveryConfig {
        address recovery;
        uint64 executeAfter;
        uint32 guardianCount;
    }

    struct GuardianManagerConfig {
        // The time at which a guardian addition or revokation will be confirmable by the owner
        mapping (bytes32 => uint256) pending;
    }

    // Wallet specific storage for recovery
    mapping (address => RecoveryConfig) internal recoveryConfigs;
    // Wallet specific storage for pending guardian addition/revokation
    mapping (address => GuardianManagerConfig) internal guardianConfigs;


    // Recovery period
    uint256 internal immutable recoveryPeriod;
    // Lock period
    uint256 internal immutable lockPeriod;
    // The security period to add/remove guardians
    uint256 internal immutable securityPeriod;
    // The security window
    uint256 internal immutable securityWindow;

    // *************** Events *************************** //

    event RecoveryExecuted(address indexed wallet, address indexed _recovery, uint64 executeAfter);
    event RecoveryFinalized(address indexed wallet, address indexed _recovery);
    event RecoveryCanceled(address indexed wallet, address indexed _recovery);
    event OwnershipTransfered(address indexed wallet, address indexed _newOwner);
    event Locked(address indexed wallet, uint64 releaseAfter);
    event Unlocked(address indexed wallet);
    event GuardianAdditionRequested(address indexed wallet, address indexed guardian, uint256 executeAfter);
    event GuardianRevokationRequested(address indexed wallet, address indexed guardian, uint256 executeAfter);
    event GuardianAdditionCancelled(address indexed wallet, address indexed guardian);
    event GuardianRevokationCancelled(address indexed wallet, address indexed guardian);
    event GuardianAdded(address indexed wallet, address indexed guardian);
    event GuardianRevoked(address indexed wallet, address indexed guardian);
    // *************** Modifiers ************************ //

    /**
     * @notice Throws if there is no ongoing recovery procedure.
     */
    modifier onlyWhenRecovery(address _wallet) {
        require(recoveryConfigs[_wallet].executeAfter > 0, "SM: no ongoing recovery");
        _;
    }

    /**
     * @notice Throws if there is an ongoing recovery procedure.
     */
    modifier notWhenRecovery(address _wallet) {
        require(recoveryConfigs[_wallet].executeAfter == 0, "SM: ongoing recovery");
        _;
    }

    /**
     * @notice Throws if the caller is not a guardian for the wallet or the module itself.
     */
    modifier onlyGuardianOrSelf(address _wallet) {
        require(_isSelf(msg.sender) || isGuardian(_wallet, msg.sender), "SM: must be guardian/self");
        _;
    }

    // *************** Constructor ************************ //

    constructor(
        uint256 _recoveryPeriod,
        uint256 _securityPeriod,
        uint256 _securityWindow,
        uint256 _lockPeriod
    ) {
        // For the wallet to be secure we must have recoveryPeriod >= securityPeriod + securityWindow
        // where securityPeriod and securityWindow are the security parameters of adding/removing guardians.
        require(_lockPeriod >= _recoveryPeriod, "SM: insecure lock period");
        require(_recoveryPeriod >= _securityPeriod + _securityWindow, "SM: insecure security periods");
        recoveryPeriod = _recoveryPeriod;
        lockPeriod = _lockPeriod;
        securityWindow = _securityWindow;
        securityPeriod = _securityPeriod;
    }

    // *************** External functions ************************ //

    // *************** Recovery functions ************************ //

    /**
     * @notice Lets the guardians start the execution of the recovery procedure.
     * Once triggered the recovery is pending for the security period before it can be finalised.
     * Must be confirmed by N guardians, where N = ceil(Nb Guardians / 2).
     * @param _wallet The target wallet.
     * @param _recovery The address to which ownership should be transferred.
     */
    function executeRecovery(address _wallet, address _recovery) external onlySelf() notWhenRecovery(_wallet) {
        validateNewOwner(_wallet, _recovery);
        uint64 executeAfter = uint64(block.timestamp + recoveryPeriod);
        recoveryConfigs[_wallet] = RecoveryConfig(_recovery, executeAfter, uint32(guardianStorage.guardianCount(_wallet)));
        _setLock(_wallet, block.timestamp + lockPeriod, SecurityManager.executeRecovery.selector);
        emit RecoveryExecuted(_wallet, _recovery, executeAfter);
    }

    /**
     * @notice Finalizes an ongoing recovery procedure if the security period is over.
     * The method is public and callable by anyone to enable orchestration.
     * @param _wallet The target wallet.
     */
    function finalizeRecovery(address _wallet) external onlyWhenRecovery(_wallet) {
        RecoveryConfig storage config = recoveryConfigs[_wallet];
        require(uint64(block.timestamp) > config.executeAfter, "SM: ongoing recovery period");
        address recoveryOwner = config.recovery;
        delete recoveryConfigs[_wallet];

        _clearSession(_wallet);

        IWallet(_wallet).setOwner(recoveryOwner);
        _setLock(_wallet, 0, bytes4(0));

        emit RecoveryFinalized(_wallet, recoveryOwner);
    }

    /**
     * @notice Lets the owner cancel an ongoing recovery procedure.
     * Must be confirmed by N guardians, where N = ceil(Nb Guardian at executeRecovery + 1) / 2) - 1.
     * @param _wallet The target wallet.
     */
    function cancelRecovery(address _wallet) external onlySelf() onlyWhenRecovery(_wallet) {
        address recoveryOwner = recoveryConfigs[_wallet].recovery;
        delete recoveryConfigs[_wallet];
        _setLock(_wallet, 0, bytes4(0));

        emit RecoveryCanceled(_wallet, recoveryOwner);
    }

    /**
     * @notice Lets the owner transfer the wallet ownership. This is executed immediately.
     * @param _wallet The target wallet.
     * @param _newOwner The address to which ownership should be transferred.
     */
    function transferOwnership(address _wallet, address _newOwner) external onlySelf() onlyWhenUnlocked(_wallet) {
        validateNewOwner(_wallet, _newOwner);
        IWallet(_wallet).setOwner(_newOwner);

        emit OwnershipTransfered(_wallet, _newOwner);
    }

    /**
    * @notice Gets the details of the ongoing recovery procedure if any.
    * @param _wallet The target wallet.
    */
    function getRecovery(address _wallet) external view returns(address _address, uint64 _executeAfter, uint32 _guardianCount) {
        RecoveryConfig storage config = recoveryConfigs[_wallet];
        return (config.recovery, config.executeAfter, config.guardianCount);
    }

    // *************** Lock functions ************************ //

    /**
     * @notice Lets a guardian lock a wallet.
     * @param _wallet The target wallet.
     */
    function lock(address _wallet) external onlyGuardianOrSelf(_wallet) onlyWhenUnlocked(_wallet) {
        _setLock(_wallet, block.timestamp + lockPeriod, SecurityManager.lock.selector);
        emit Locked(_wallet, uint64(block.timestamp + lockPeriod));
    }

    /**
     * @notice Lets a guardian unlock a locked wallet.
     * @param _wallet The target wallet.
     */
    function unlock(address _wallet) external onlyGuardianOrSelf(_wallet) onlyWhenLocked(_wallet) {
        require(locks[_wallet].locker == SecurityManager.lock.selector, "SM: cannot unlock");
        _setLock(_wallet, 0, bytes4(0));
        emit Unlocked(_wallet);
    }

    /**
     * @notice Returns the release time of a wallet lock or 0 if the wallet is unlocked.
     * @param _wallet The target wallet.
     * @return _releaseAfter The epoch time at which the lock will release (in seconds).
     */
    function getLock(address _wallet) external view returns(uint64 _releaseAfter) {
        return _isLocked(_wallet) ? locks[_wallet].release : 0;
    }

    /**
     * @notice Checks if a wallet is locked.
     * @param _wallet The target wallet.
     * @return _isLocked `true` if the wallet is locked otherwise `false`.
     */
    function isLocked(address _wallet) external view returns (bool) {
        return _isLocked(_wallet);
    }

    // *************** Guardian functions ************************ //

    /**
     * @notice Lets the owner add a guardian to its wallet.
     * The first guardian is added immediately. All following additions must be confirmed
     * by calling the confirmGuardianAddition() method.
     * @param _wallet The target wallet.
     * @param _guardian The guardian to add.
     */
    function addGuardian(address _wallet, address _guardian) external onlyWalletOwnerOrSelf(_wallet) onlyWhenUnlocked(_wallet) {
        require(!_isOwner(_wallet, _guardian), "SM: guardian cannot be owner");
        require(!isGuardian(_wallet, _guardian), "SM: duplicate guardian");
        // Guardians must either be an EOA or a contract with an owner()
        // method that returns an address with a 25000 gas stipend.
        // Note that this test is not meant to be strict and can be bypassed by custom malicious contracts.
        (bool success,) = _guardian.call{gas: 25000}(abi.encodeWithSignature("owner()"));
        require(success, "SM: must be EOA/Argent wallet");

        bytes32 id = keccak256(abi.encodePacked(_wallet, _guardian, "addition"));
        GuardianManagerConfig storage config = guardianConfigs[_wallet];
        require(
            config.pending[id] == 0 || block.timestamp > config.pending[id] + securityWindow,
            "SM: duplicate pending addition");
        config.pending[id] = block.timestamp + securityPeriod;
        emit GuardianAdditionRequested(_wallet, _guardian, block.timestamp + securityPeriod);
    }

    /**
     * @notice Confirms the pending addition of a guardian to a wallet.
     * The method must be called during the confirmation window and can be called by anyone to enable orchestration.
     * @param _wallet The target wallet.
     * @param _guardian The guardian.
     */
    function confirmGuardianAddition(address _wallet, address _guardian) external onlyWhenUnlocked(_wallet) {
        bytes32 id = keccak256(abi.encodePacked(_wallet, _guardian, "addition"));
        GuardianManagerConfig storage config = guardianConfigs[_wallet];
        require(config.pending[id] > 0, "SM: unknown pending addition");
        require(config.pending[id] < block.timestamp, "SM: pending addition not over");
        require(block.timestamp < config.pending[id] + securityWindow, "SM: pending addition expired");
        guardianStorage.addGuardian(_wallet, _guardian);
        emit GuardianAdded(_wallet, _guardian);
        delete config.pending[id];
    }

    /**
     * @notice Lets the owner cancel a pending guardian addition.
     * @param _wallet The target wallet.
     * @param _guardian The guardian.
     */
    function cancelGuardianAddition(address _wallet, address _guardian) external onlyWalletOwnerOrSelf(_wallet) onlyWhenUnlocked(_wallet) {
        bytes32 id = keccak256(abi.encodePacked(_wallet, _guardian, "addition"));
        GuardianManagerConfig storage config = guardianConfigs[_wallet];
        require(config.pending[id] > 0, "SM: unknown pending addition");
        delete config.pending[id];
        emit GuardianAdditionCancelled(_wallet, _guardian);
    }

    /**
     * @notice Lets the owner revoke a guardian from its wallet.
     * @dev Revokation must be confirmed by calling the confirmGuardianRevokation() method.
     * @param _wallet The target wallet.
     * @param _guardian The guardian to revoke.
     */
    function revokeGuardian(address _wallet, address _guardian) external onlyWalletOwnerOrSelf(_wallet) {
        require(isGuardian(_wallet, _guardian), "SM: must be existing guardian");
        bytes32 id = keccak256(abi.encodePacked(_wallet, _guardian, "revokation"));
        GuardianManagerConfig storage config = guardianConfigs[_wallet];
        require(
            config.pending[id] == 0 || block.timestamp > config.pending[id] + securityWindow,
            "SM: duplicate pending revoke"); // TODO need to allow if confirmation window passed
        config.pending[id] = block.timestamp + securityPeriod;
        emit GuardianRevokationRequested(_wallet, _guardian, block.timestamp + securityPeriod);
    }

    /**
     * @notice Confirms the pending revokation of a guardian to a wallet.
     * The method must be called during the confirmation window and can be called by anyone to enable orchestration.
     * @param _wallet The target wallet.
     * @param _guardian The guardian.
     */
    function confirmGuardianRevokation(address _wallet, address _guardian) external {
        bytes32 id = keccak256(abi.encodePacked(_wallet, _guardian, "revokation"));
        GuardianManagerConfig storage config = guardianConfigs[_wallet];
        require(config.pending[id] > 0, "SM: unknown pending revoke");
        require(config.pending[id] < block.timestamp, "SM: pending revoke not over");
        require(block.timestamp < config.pending[id] + securityWindow, "SM: pending revoke expired");
        guardianStorage.revokeGuardian(_wallet, _guardian);
        emit GuardianRevoked(_wallet, _guardian);
        delete config.pending[id];
    }

    /**
     * @notice Lets the owner cancel a pending guardian revokation.
     * @param _wallet The target wallet.
     * @param _guardian The guardian.
     */
    function cancelGuardianRevokation(address _wallet, address _guardian) external onlyWalletOwnerOrSelf(_wallet) onlyWhenUnlocked(_wallet) {
        bytes32 id = keccak256(abi.encodePacked(_wallet, _guardian, "revokation"));
        GuardianManagerConfig storage config = guardianConfigs[_wallet];
        require(config.pending[id] > 0, "SM: unknown pending revoke");
        delete config.pending[id];
        emit GuardianRevokationCancelled(_wallet, _guardian);
    }

    /**
     * @notice Checks if an address is a guardian for a wallet.
     * @param _wallet The target wallet.
     * @param _guardian The address to check.
     * @return _isGuardian `true` if the address is a guardian for the wallet otherwise `false`.
     */
    function isGuardian(address _wallet, address _guardian) public view returns (bool _isGuardian) {
        return guardianStorage.isGuardian(_wallet, _guardian);
    }

    /**
    * @notice Checks if an address is a guardian or an account authorised to sign on behalf of a smart-contract guardian.
    * @param _wallet The target wallet.
    * @param _guardian the address to test
    * @return _isGuardian `true` if the address is a guardian for the wallet otherwise `false`.
    */
    function isGuardianOrGuardianSigner(address _wallet, address _guardian) external view returns (bool _isGuardian) {
        (_isGuardian, ) = Utils.isGuardianOrGuardianSigner(guardianStorage.getGuardians(_wallet), _guardian);
    }

    /**
     * @notice Counts the number of active guardians for a wallet.
     * @param _wallet The target wallet.
     * @return _count The number of active guardians for a wallet.
     */
    function guardianCount(address _wallet) external view returns (uint256 _count) {
        return guardianStorage.guardianCount(_wallet);
    }

    /**
     * @notice Get the active guardians for a wallet.
     * @param _wallet The target wallet.
     * @return _guardians the active guardians for a wallet.
     */
    function getGuardians(address _wallet) external view returns (address[] memory _guardians) {
        return guardianStorage.getGuardians(_wallet);
    }

    // *************** Internal Functions ********************* //

    function validateNewOwner(address _wallet, address _newOwner) internal view {
        require(_newOwner != address(0), "SM: new owner cannot be null");
        require(!isGuardian(_wallet, _newOwner), "SM: new owner cannot be guardian");
    }

    function _setLock(address _wallet, uint256 _releaseAfter, bytes4 _locker) internal {
        locks[_wallet] = Lock(SafeCast.toUint64(_releaseAfter), _locker);
    }
}

// Copyright (C) 2018  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./common/Utils.sol";
import "./common/BaseModule.sol";
import "../interfaces/IERC20.sol";

/**
 * @title TransactionManager
 * @notice Module to execute transactions in sequence to e.g. transfer tokens (ETH, ERC20, ERC721, ERC1155) or call third-party contracts.
 * @author Julien Niset - <[email protected]>
 */
abstract contract TransactionManager is BaseModule {

    // Static calls
    bytes4 private constant ERC1271_IS_VALID_SIGNATURE = bytes4(keccak256("isValidSignature(bytes32,bytes)"));
    bytes4 private constant ERC721_RECEIVED = bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    bytes4 private constant ERC1155_RECEIVED = bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    bytes4 private constant ERC1155_BATCH_RECEIVED = bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"));
    bytes4 private constant ERC165_INTERFACE = bytes4(keccak256("supportsInterface(bytes4)"));

    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    // The time delay for adding a trusted contact
    uint256 internal immutable whitelistPeriod;

    // *************** Events *************************** //

    event AddedToWhitelist(address indexed wallet, address indexed target, uint64 whitelistAfter);
    event RemovedFromWhitelist(address indexed wallet, address indexed target);
    event SessionCreated(address indexed wallet, address sessionKey, uint64 expires);
    event SessionCleared(address indexed wallet, address sessionKey);
    // *************** Constructor ************************ //

    constructor(uint256 _whitelistPeriod) {
        whitelistPeriod = _whitelistPeriod;
    }

    // *************** External functions ************************ //

    /**
     * @notice Makes the target wallet execute a sequence of transactions authorised by the wallet owner.
     * The method reverts if any of the inner transactions reverts.
     * The method reverts if any of the inner transaction is not to a trusted contact or an authorised dapp.
     * @param _wallet The target wallet.
     * @param _transactions The sequence of transactions.
     */
    function multiCall(
        address _wallet,
        Call[] calldata _transactions
    )
        external
        onlySelf()
        onlyWhenUnlocked(_wallet)
        returns (bytes[] memory)
    {
        bytes[] memory results = new bytes[](_transactions.length);
        for(uint i = 0; i < _transactions.length; i++) {
            address spender = Utils.recoverSpender(_transactions[i].to, _transactions[i].data);
            require(
                (_transactions[i].value == 0 || spender == _transactions[i].to) &&
                (isWhitelisted(_wallet, spender) || authoriser.isAuthorised(_wallet, spender, _transactions[i].to, _transactions[i].data)),
                "TM: call not authorised");
            results[i] = invokeWallet(_wallet, _transactions[i].to, _transactions[i].value, _transactions[i].data);
        }
        return results;
    }

    /**
     * @notice Makes the target wallet execute a sequence of transactions authorised by a session key.
     * The method reverts if any of the inner transactions reverts.
     * @param _wallet The target wallet.
     * @param _transactions The sequence of transactions.
     */
    function multiCallWithSession(
        address _wallet,
        Call[] calldata _transactions
    )
        external
        onlySelf()
        onlyWhenUnlocked(_wallet)
        returns (bytes[] memory)
    {
        return multiCallWithApproval(_wallet, _transactions);
    }

    /**
     * @notice Makes the target wallet execute a sequence of transactions approved by a majority of guardians.
     * The method reverts if any of the inner transactions reverts.
     * @param _wallet The target wallet.
     * @param _transactions The sequence of transactions.
     */
    function multiCallWithGuardians(
        address _wallet,
        Call[] calldata _transactions
    )
        external 
        onlySelf()
        onlyWhenUnlocked(_wallet)
        returns (bytes[] memory)
    {
        return multiCallWithApproval(_wallet, _transactions);
    }

    /**
     * @notice Makes the target wallet execute a sequence of transactions approved by a majority of guardians.
     * The method reverts if any of the inner transactions reverts.
     * Upon success a new session is started.
     * @param _wallet The target wallet.
     * @param _transactions The sequence of transactions.
     */
    function multiCallWithGuardiansAndStartSession(
        address _wallet,
        Call[] calldata _transactions,
        address _sessionUser,
        uint64 _duration
    )
        external 
        onlySelf()
        onlyWhenUnlocked(_wallet)
        returns (bytes[] memory)
    {
        startSession(_wallet, _sessionUser, _duration);
        return multiCallWithApproval(_wallet, _transactions);
    }

    /**
    * @notice Clears the active session of a wallet if any.
    * @param _wallet The target wallet.
    */
    function clearSession(address _wallet) external onlyWalletOwnerOrSelf(_wallet) onlyWhenUnlocked(_wallet) {
        emit SessionCleared(_wallet, sessions[_wallet].key);
        _clearSession(_wallet);
    }

    /**
     * @notice Adds an address to the list of trusted contacts.
     * @param _wallet The target wallet.
     * @param _target The address to add.
     */
    function addToWhitelist(address _wallet, address _target) external onlyWalletOwnerOrSelf(_wallet) onlyWhenUnlocked(_wallet) {
        require(_target != _wallet, "TM: Cannot whitelist wallet");
        require(!registry.isRegisteredModule(_target), "TM: Cannot whitelist module");
        require(!isWhitelisted(_wallet, _target), "TM: target already whitelisted");

        uint256 whitelistAfter = block.timestamp + whitelistPeriod;
        setWhitelist(_wallet, _target, whitelistAfter);
        emit AddedToWhitelist(_wallet, _target, uint64(whitelistAfter));
    }

    /**
     * @notice Removes an address from the list of trusted contacts.
     * @param _wallet The target wallet.
     * @param _target The address to remove.
     */
    function removeFromWhitelist(address _wallet, address _target) external onlyWalletOwnerOrSelf(_wallet) onlyWhenUnlocked(_wallet) {
        setWhitelist(_wallet, _target, 0);
        emit RemovedFromWhitelist(_wallet, _target);
    }

    /**
    * @notice Checks if an address is a trusted contact for a wallet.
    * @param _wallet The target wallet.
    * @param _target The address.
    * @return _isWhitelisted true if the address is a trusted contact.
    */
    function isWhitelisted(address _wallet, address _target) public view returns (bool _isWhitelisted) {
        uint whitelistAfter = userWhitelist.getWhitelist(_wallet, _target);
        return whitelistAfter > 0 && whitelistAfter < block.timestamp;
    }
    
    /*
    * @notice Enable the static calls required to make the wallet compatible with the ERC1155TokenReceiver 
    * interface (see https://eips.ethereum.org/EIPS/eip-1155#erc-1155-token-receiver). This method only 
    * needs to be called for wallets deployed in version lower or equal to 2.4.0 as the ERC1155 static calls
    * are not available by default for these versions of BaseWallet
    * @param _wallet The target wallet.
    */
    function enableERC1155TokenReceiver(address _wallet) external onlyWalletOwnerOrSelf(_wallet) onlyWhenUnlocked(_wallet) {
        IWallet(_wallet).enableStaticCall(address(this), ERC165_INTERFACE);
        IWallet(_wallet).enableStaticCall(address(this), ERC1155_RECEIVED);
        IWallet(_wallet).enableStaticCall(address(this), ERC1155_BATCH_RECEIVED);
    }

    /**
     * @inheritdoc IModule
     */
    function supportsStaticCall(bytes4 _methodId) external pure override returns (bool _isSupported) {
        return _methodId == ERC1271_IS_VALID_SIGNATURE ||
               _methodId == ERC721_RECEIVED ||
               _methodId == ERC165_INTERFACE ||
               _methodId == ERC1155_RECEIVED ||
               _methodId == ERC1155_BATCH_RECEIVED;
    }

    /** ******************* Callbacks ************************** */

    /**
     * @notice Returns true if this contract implements the interface defined by
     * `interfaceId` (see https://eips.ethereum.org/EIPS/eip-165).
     */
    function supportsInterface(bytes4 _interfaceID) external pure returns (bool) {
        return  _interfaceID == ERC165_INTERFACE || _interfaceID == (ERC1155_RECEIVED ^ ERC1155_BATCH_RECEIVED);          
    }

    /**
    * @notice Implementation of EIP 1271.
    * Should return whether the signature provided is valid for the provided data.
    * @param _msgHash Hash of a message signed on the behalf of address(this)
    * @param _signature Signature byte array associated with _msgHash
    */
    function isValidSignature(bytes32 _msgHash, bytes memory _signature) external view returns (bytes4) {
        require(_signature.length == 65, "TM: invalid signature length");
        address signer = Utils.recoverSigner(_msgHash, _signature, 0);
        require(_isOwner(msg.sender, signer), "TM: Invalid signer");
        return ERC1271_IS_VALID_SIGNATURE;
    }


    fallback() external {
        bytes4 methodId = Utils.functionPrefix(msg.data);
        if(methodId == ERC721_RECEIVED || methodId == ERC1155_RECEIVED || methodId == ERC1155_BATCH_RECEIVED) {
            // solhint-disable-next-line no-inline-assembly
            assembly {                
                calldatacopy(0, 0, 0x04)
                return (0, 0x20)
            }
        }
    }

    // *************** Internal Functions ********************* //

    function enableDefaultStaticCalls(address _wallet) internal {
        // setup the static calls that are available for free for all wallets
        IWallet(_wallet).enableStaticCall(address(this), ERC1271_IS_VALID_SIGNATURE);
        IWallet(_wallet).enableStaticCall(address(this), ERC721_RECEIVED);
    }

    function multiCallWithApproval(address _wallet, Call[] calldata _transactions) internal returns (bytes[] memory) {
        bytes[] memory results = new bytes[](_transactions.length);
        for(uint i = 0; i < _transactions.length; i++) {
            results[i] = invokeWallet(_wallet, _transactions[i].to, _transactions[i].value, _transactions[i].data);
        }
        return results;
    }

    function startSession(address _wallet, address _sessionUser, uint64 _duration) internal {
        require(_sessionUser != address(0), "TM: Invalid session user");
        require(_duration > 0, "TM: Invalid session duration");

        uint64 expiry = SafeCast.toUint64(block.timestamp + _duration);
        sessions[_wallet] = Session(_sessionUser, expiry);
        emit SessionCreated(_wallet, _sessionUser, expiry);
    }

    function setWhitelist(address _wallet, address _target, uint256 _whitelistAfter) internal {
        userWhitelist.setWhitelist(_wallet, _target, _whitelistAfter);
    }
}

// Copyright (C) 2021  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

interface IAuthoriser {
    function isAuthorised(address _wallet, address _spender, address _to, bytes calldata _data) external view returns (bool);
    function areAuthorised(
        address _wallet,
        address[] calldata _spenders,
        address[] calldata _to,
        bytes[] calldata _data
    )
        external
        view
        returns (bool);
}

// Copyright (C) 2018  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.5.4 <0.9.0;

/**
 * @title IWallet
 * @notice Interface for the BaseWallet
 */
interface IWallet {
    /**
     * @notice Returns the wallet owner.
     * @return The wallet owner address.
     */
    function owner() external view returns (address);

    /**
     * @notice Returns the number of authorised modules.
     * @return The number of authorised modules.
     */
    function modules() external view returns (uint);

    /**
     * @notice Sets a new owner for the wallet.
     * @param _newOwner The new owner.
     */
    function setOwner(address _newOwner) external;

    /**
     * @notice Checks if a module is authorised on the wallet.
     * @param _module The module address to check.
     * @return `true` if the module is authorised, otherwise `false`.
     */
    function authorised(address _module) external view returns (bool);

    /**
     * @notice Returns the module responsible for a static call redirection.
     * @param _sig The signature of the static call.
     * @return the module doing the redirection
     */
    function enabled(bytes4 _sig) external view returns (address);

    /**
     * @notice Enables/Disables a module.
     * @param _module The target module.
     * @param _value Set to `true` to authorise the module.
     */
    function authoriseModule(address _module, bool _value) external;

    /**
    * @notice Enables a static method by specifying the target module to which the call must be delegated.
    * @param _module The target module.
    * @param _method The static method signature.
    */
    function enableStaticCall(address _module, bytes4 _method) external;
}

// Copyright (C) 2020  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.5.4 <0.9.0;

/**
 * @title IModuleRegistry
 * @notice Interface for the registry of authorised modules.
 */
interface IModuleRegistry {
    function registerModule(address _module, bytes32 _name) external;

    function deregisterModule(address _module) external;

    function registerUpgrader(address _upgrader, bytes32 _name) external;

    function deregisterUpgrader(address _upgrader) external;

    function recoverToken(address _token) external;

    function moduleInfo(address _module) external view returns (bytes32);

    function upgraderInfo(address _upgrader) external view returns (bytes32);

    function isRegisteredModule(address _module) external view returns (bool);

    function isRegisteredModule(address[] calldata _modules) external view returns (bool);

    function isRegisteredUpgrader(address _upgrader) external view returns (bool);
}

// Copyright (C) 2018  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.5.4 <0.9.0;

interface IGuardianStorage {

    /**
     * @notice Lets an authorised module add a guardian to a wallet.
     * @param _wallet The target wallet.
     * @param _guardian The guardian to add.
     */
    function addGuardian(address _wallet, address _guardian) external;

    /**
     * @notice Lets an authorised module revoke a guardian from a wallet.
     * @param _wallet The target wallet.
     * @param _guardian The guardian to revoke.
     */
    function revokeGuardian(address _wallet, address _guardian) external;

    /**
     * @notice Checks if an account is a guardian for a wallet.
     * @param _wallet The target wallet.
     * @param _guardian The account.
     * @return true if the account is a guardian for a wallet.
     */
    function isGuardian(address _wallet, address _guardian) external view returns (bool);

    function isLocked(address _wallet) external view returns (bool);

    function getLock(address _wallet) external view returns (uint256);

    function getLocker(address _wallet) external view returns (address);

    function setLock(address _wallet, uint256 _releaseAfter) external;

    function getGuardians(address _wallet) external view returns (address[] memory);

    function guardianCount(address _wallet) external view returns (uint256);
}

// Copyright (C) 2020  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.5.4 <0.9.0;

/**
 * @title ITransferStorage
 * @notice TransferStorage interface
 */
interface ITransferStorage {
    function setWhitelist(address _wallet, address _target, uint256 _value) external;

    function getWhitelist(address _wallet, address _target) external view returns (uint256);
}

// Copyright (C) 2018  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

/**
 * @title IModule
 * @notice Interface for a Module.
 * @author Julien Niset - <[email protected]>, Olivier VDB - <[email protected]>
 */
interface IModule {

    /**	
     * @notice Adds a module to a wallet. Cannot execute when wallet is locked (or under recovery)	
     * @param _wallet The target wallet.	
     * @param _module The modules to authorise.	
     */	
    function addModule(address _wallet, address _module) external;

    /**
     * @notice Inits a Module for a wallet by e.g. setting some wallet specific parameters in storage.
     * @param _wallet The wallet.
     */
    function init(address _wallet) external;


    /**
     * @notice Returns whether the module implements a callback for a given static call method.
     * @param _methodId The method id.
     */
    function supportsStaticCall(bytes4 _methodId) external view returns (bool _isSupported);
}

pragma solidity >=0.5.4 <0.9.0;

/**
 * ERC20 contract interface.
 */
interface IERC20 {
    function totalSupply() external view returns (uint);
    function decimals() external view returns (uint);
    function balanceOf(address tokenOwner) external view returns (uint balance);
    function allowance(address tokenOwner, address spender) external view returns (uint remaining);
    function transfer(address to, uint tokens) external returns (bool success);
    function approve(address spender, uint tokens) external returns (bool success);
    function transferFrom(address from, address to, uint tokens) external returns (bool success);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (utils/math/Math.sol)

pragma solidity ^0.8.0;

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    enum Rounding {
        Down, // Toward negative infinity
        Up, // Toward infinity
        Zero // Toward zero
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds up instead
     * of rounding down.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv)
     * with further edits by Uniswap Labs also under MIT license.
     */
    function mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            require(denominator > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator. Always >= 1.
            // See https://cs.stackexchange.com/q/138556/92363.

            // Does not overflow because the denominator cannot be zero at this stage in the function.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256 such
            // that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also works
            // in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2^256. Since the preconditions guarantee that the outcome is
            // less than 2^256, this is the final result. We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator,
        Rounding rounding
    ) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (rounding == Rounding.Up && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. It the number is not a perfect square, the value is rounded down.
     *
     * Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        // For our first guess, we get the biggest power of 2 which is smaller than the square root of the target.
        // We know that the "msb" (most significant bit) of our target number `a` is a power of 2 such that we have
        // `msb(a) <= a < 2*msb(a)`.
        // We also know that `k`, the position of the most significant bit, is such that `msb(a) = 2**k`.
        // This gives `2**k < a <= 2**(k+1)` → `2**(k/2) <= sqrt(a) < 2 ** (k/2+1)`.
        // Using an algorithm similar to the msb conmputation, we are able to compute `result = 2**(k/2)` which is a
        // good first aproximation of `sqrt(a)` with at least 1 correct bit.
        uint256 result = 1;
        uint256 x = a;
        if (x >> 128 > 0) {
            x >>= 128;
            result <<= 64;
        }
        if (x >> 64 > 0) {
            x >>= 64;
            result <<= 32;
        }
        if (x >> 32 > 0) {
            x >>= 32;
            result <<= 16;
        }
        if (x >> 16 > 0) {
            x >>= 16;
            result <<= 8;
        }
        if (x >> 8 > 0) {
            x >>= 8;
            result <<= 4;
        }
        if (x >> 4 > 0) {
            x >>= 4;
            result <<= 2;
        }
        if (x >> 2 > 0) {
            result <<= 1;
        }

        // At this point `result` is an estimation with one bit of precision. We know the true value is a uint128,
        // since it is the square root of a uint256. Newton's method converges quadratically (precision doubles at
        // every iteration). We thus need at most 7 iteration to turn our partial result with one bit of precision
        // into the expected uint128 result.
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return min(result, a / result);
        }
    }

    /**
     * @notice Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        uint256 result = sqrt(a);
        if (rounding == Rounding.Up && result * result < a) {
            result += 1;
        }
        return result;
    }
}

// Copyright (C) 2021  Argent Labs Ltd. <https://argent.xyz>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

contract SimpleOracle {

    address internal immutable weth;
    address internal immutable uniswapV2Factory;

    constructor(address _uniswapRouter) {
        weth = IUniswapV2Router01(_uniswapRouter).WETH();
        uniswapV2Factory = IUniswapV2Router01(_uniswapRouter).factory();
    }

    function inToken(address _token, uint256 _ethAmount) internal view returns (uint256) {
        (uint256 wethReserve, uint256 tokenReserve) = getReservesForTokenPool(_token);
        return _ethAmount * tokenReserve / wethReserve;
    }

    function getReservesForTokenPool(address _token) internal view returns (uint256 wethReserve, uint256 tokenReserve) {
        if (weth < _token) {
            address pair = getPairForSorted(weth, _token);
            (wethReserve, tokenReserve,) = IUniswapV2Pair(pair).getReserves();
        } else {
            address pair = getPairForSorted(_token, weth);
            (tokenReserve, wethReserve,) = IUniswapV2Pair(pair).getReserves();
        }
        require(wethReserve != 0 && tokenReserve != 0, "SO: no liquidity");
    }

    function getPairForSorted(address tokenA, address tokenB) internal virtual view returns (address pair) {    
        pair = address(uint160(uint256(keccak256(abi.encodePacked(
                hex'ff',
                uniswapV2Factory,
                keccak256(abi.encodePacked(tokenA, tokenB)),
                hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f'
            )))));
    }
}

pragma solidity >=0.6.2;

interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

pragma solidity >=0.5.0;

interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (utils/math/SafeCast.sol)

pragma solidity ^0.8.0;

/**
 * @dev Wrappers over Solidity's uintXX/intXX casting operators with added overflow
 * checks.
 *
 * Downcasting from uint256/int256 in Solidity does not revert on overflow. This can
 * easily result in undesired exploitation or bugs, since developers usually
 * assume that overflows raise errors. `SafeCast` restores this intuition by
 * reverting the transaction when such an operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 *
 * Can be combined with {SafeMath} and {SignedSafeMath} to extend it to smaller types, by performing
 * all math on `uint256` and `int256` and then downcasting.
 */
library SafeCast {
    /**
     * @dev Returns the downcasted uint248 from uint256, reverting on
     * overflow (when the input is greater than largest uint248).
     *
     * Counterpart to Solidity's `uint248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     *
     * _Available since v4.7._
     */
    function toUint248(uint256 value) internal pure returns (uint248) {
        require(value <= type(uint248).max, "SafeCast: value doesn't fit in 248 bits");
        return uint248(value);
    }

    /**
     * @dev Returns the downcasted uint240 from uint256, reverting on
     * overflow (when the input is greater than largest uint240).
     *
     * Counterpart to Solidity's `uint240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     *
     * _Available since v4.7._
     */
    function toUint240(uint256 value) internal pure returns (uint240) {
        require(value <= type(uint240).max, "SafeCast: value doesn't fit in 240 bits");
        return uint240(value);
    }

    /**
     * @dev Returns the downcasted uint232 from uint256, reverting on
     * overflow (when the input is greater than largest uint232).
     *
     * Counterpart to Solidity's `uint232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     *
     * _Available since v4.7._
     */
    function toUint232(uint256 value) internal pure returns (uint232) {
        require(value <= type(uint232).max, "SafeCast: value doesn't fit in 232 bits");
        return uint232(value);
    }

    /**
     * @dev Returns the downcasted uint224 from uint256, reverting on
     * overflow (when the input is greater than largest uint224).
     *
     * Counterpart to Solidity's `uint224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     *
     * _Available since v4.2._
     */
    function toUint224(uint256 value) internal pure returns (uint224) {
        require(value <= type(uint224).max, "SafeCast: value doesn't fit in 224 bits");
        return uint224(value);
    }

    /**
     * @dev Returns the downcasted uint216 from uint256, reverting on
     * overflow (when the input is greater than largest uint216).
     *
     * Counterpart to Solidity's `uint216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     *
     * _Available since v4.7._
     */
    function toUint216(uint256 value) internal pure returns (uint216) {
        require(value <= type(uint216).max, "SafeCast: value doesn't fit in 216 bits");
        return uint216(value);
    }

    /**
     * @dev Returns the downcasted uint208 from uint256, reverting on
     * overflow (when the input is greater than largest uint208).
     *
     * Counterpart to Solidity's `uint208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     *
     * _Available since v4.7._
     */
    function toUint208(uint256 value) internal pure returns (uint208) {
        require(value <= type(uint208).max, "SafeCast: value doesn't fit in 208 bits");
        return uint208(value);
    }

    /**
     * @dev Returns the downcasted uint200 from uint256, reverting on
     * overflow (when the input is greater than largest uint200).
     *
     * Counterpart to Solidity's `uint200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     *
     * _Available since v4.7._
     */
    function toUint200(uint256 value) internal pure returns (uint200) {
        require(value <= type(uint200).max, "SafeCast: value doesn't fit in 200 bits");
        return uint200(value);
    }

    /**
     * @dev Returns the downcasted uint192 from uint256, reverting on
     * overflow (when the input is greater than largest uint192).
     *
     * Counterpart to Solidity's `uint192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     *
     * _Available since v4.7._
     */
    function toUint192(uint256 value) internal pure returns (uint192) {
        require(value <= type(uint192).max, "SafeCast: value doesn't fit in 192 bits");
        return uint192(value);
    }

    /**
     * @dev Returns the downcasted uint184 from uint256, reverting on
     * overflow (when the input is greater than largest uint184).
     *
     * Counterpart to Solidity's `uint184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     *
     * _Available since v4.7._
     */
    function toUint184(uint256 value) internal pure returns (uint184) {
        require(value <= type(uint184).max, "SafeCast: value doesn't fit in 184 bits");
        return uint184(value);
    }

    /**
     * @dev Returns the downcasted uint176 from uint256, reverting on
     * overflow (when the input is greater than largest uint176).
     *
     * Counterpart to Solidity's `uint176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     *
     * _Available since v4.7._
     */
    function toUint176(uint256 value) internal pure returns (uint176) {
        require(value <= type(uint176).max, "SafeCast: value doesn't fit in 176 bits");
        return uint176(value);
    }

    /**
     * @dev Returns the downcasted uint168 from uint256, reverting on
     * overflow (when the input is greater than largest uint168).
     *
     * Counterpart to Solidity's `uint168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     *
     * _Available since v4.7._
     */
    function toUint168(uint256 value) internal pure returns (uint168) {
        require(value <= type(uint168).max, "SafeCast: value doesn't fit in 168 bits");
        return uint168(value);
    }

    /**
     * @dev Returns the downcasted uint160 from uint256, reverting on
     * overflow (when the input is greater than largest uint160).
     *
     * Counterpart to Solidity's `uint160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     *
     * _Available since v4.7._
     */
    function toUint160(uint256 value) internal pure returns (uint160) {
        require(value <= type(uint160).max, "SafeCast: value doesn't fit in 160 bits");
        return uint160(value);
    }

    /**
     * @dev Returns the downcasted uint152 from uint256, reverting on
     * overflow (when the input is greater than largest uint152).
     *
     * Counterpart to Solidity's `uint152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     *
     * _Available since v4.7._
     */
    function toUint152(uint256 value) internal pure returns (uint152) {
        require(value <= type(uint152).max, "SafeCast: value doesn't fit in 152 bits");
        return uint152(value);
    }

    /**
     * @dev Returns the downcasted uint144 from uint256, reverting on
     * overflow (when the input is greater than largest uint144).
     *
     * Counterpart to Solidity's `uint144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     *
     * _Available since v4.7._
     */
    function toUint144(uint256 value) internal pure returns (uint144) {
        require(value <= type(uint144).max, "SafeCast: value doesn't fit in 144 bits");
        return uint144(value);
    }

    /**
     * @dev Returns the downcasted uint136 from uint256, reverting on
     * overflow (when the input is greater than largest uint136).
     *
     * Counterpart to Solidity's `uint136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     *
     * _Available since v4.7._
     */
    function toUint136(uint256 value) internal pure returns (uint136) {
        require(value <= type(uint136).max, "SafeCast: value doesn't fit in 136 bits");
        return uint136(value);
    }

    /**
     * @dev Returns the downcasted uint128 from uint256, reverting on
     * overflow (when the input is greater than largest uint128).
     *
     * Counterpart to Solidity's `uint128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     *
     * _Available since v2.5._
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "SafeCast: value doesn't fit in 128 bits");
        return uint128(value);
    }

    /**
     * @dev Returns the downcasted uint120 from uint256, reverting on
     * overflow (when the input is greater than largest uint120).
     *
     * Counterpart to Solidity's `uint120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     *
     * _Available since v4.7._
     */
    function toUint120(uint256 value) internal pure returns (uint120) {
        require(value <= type(uint120).max, "SafeCast: value doesn't fit in 120 bits");
        return uint120(value);
    }

    /**
     * @dev Returns the downcasted uint112 from uint256, reverting on
     * overflow (when the input is greater than largest uint112).
     *
     * Counterpart to Solidity's `uint112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     *
     * _Available since v4.7._
     */
    function toUint112(uint256 value) internal pure returns (uint112) {
        require(value <= type(uint112).max, "SafeCast: value doesn't fit in 112 bits");
        return uint112(value);
    }

    /**
     * @dev Returns the downcasted uint104 from uint256, reverting on
     * overflow (when the input is greater than largest uint104).
     *
     * Counterpart to Solidity's `uint104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     *
     * _Available since v4.7._
     */
    function toUint104(uint256 value) internal pure returns (uint104) {
        require(value <= type(uint104).max, "SafeCast: value doesn't fit in 104 bits");
        return uint104(value);
    }

    /**
     * @dev Returns the downcasted uint96 from uint256, reverting on
     * overflow (when the input is greater than largest uint96).
     *
     * Counterpart to Solidity's `uint96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     *
     * _Available since v4.2._
     */
    function toUint96(uint256 value) internal pure returns (uint96) {
        require(value <= type(uint96).max, "SafeCast: value doesn't fit in 96 bits");
        return uint96(value);
    }

    /**
     * @dev Returns the downcasted uint88 from uint256, reverting on
     * overflow (when the input is greater than largest uint88).
     *
     * Counterpart to Solidity's `uint88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     *
     * _Available since v4.7._
     */
    function toUint88(uint256 value) internal pure returns (uint88) {
        require(value <= type(uint88).max, "SafeCast: value doesn't fit in 88 bits");
        return uint88(value);
    }

    /**
     * @dev Returns the downcasted uint80 from uint256, reverting on
     * overflow (when the input is greater than largest uint80).
     *
     * Counterpart to Solidity's `uint80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     *
     * _Available since v4.7._
     */
    function toUint80(uint256 value) internal pure returns (uint80) {
        require(value <= type(uint80).max, "SafeCast: value doesn't fit in 80 bits");
        return uint80(value);
    }

    /**
     * @dev Returns the downcasted uint72 from uint256, reverting on
     * overflow (when the input is greater than largest uint72).
     *
     * Counterpart to Solidity's `uint72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     *
     * _Available since v4.7._
     */
    function toUint72(uint256 value) internal pure returns (uint72) {
        require(value <= type(uint72).max, "SafeCast: value doesn't fit in 72 bits");
        return uint72(value);
    }

    /**
     * @dev Returns the downcasted uint64 from uint256, reverting on
     * overflow (when the input is greater than largest uint64).
     *
     * Counterpart to Solidity's `uint64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     *
     * _Available since v2.5._
     */
    function toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "SafeCast: value doesn't fit in 64 bits");
        return uint64(value);
    }

    /**
     * @dev Returns the downcasted uint56 from uint256, reverting on
     * overflow (when the input is greater than largest uint56).
     *
     * Counterpart to Solidity's `uint56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     *
     * _Available since v4.7._
     */
    function toUint56(uint256 value) internal pure returns (uint56) {
        require(value <= type(uint56).max, "SafeCast: value doesn't fit in 56 bits");
        return uint56(value);
    }

    /**
     * @dev Returns the downcasted uint48 from uint256, reverting on
     * overflow (when the input is greater than largest uint48).
     *
     * Counterpart to Solidity's `uint48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     *
     * _Available since v4.7._
     */
    function toUint48(uint256 value) internal pure returns (uint48) {
        require(value <= type(uint48).max, "SafeCast: value doesn't fit in 48 bits");
        return uint48(value);
    }

    /**
     * @dev Returns the downcasted uint40 from uint256, reverting on
     * overflow (when the input is greater than largest uint40).
     *
     * Counterpart to Solidity's `uint40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     *
     * _Available since v4.7._
     */
    function toUint40(uint256 value) internal pure returns (uint40) {
        require(value <= type(uint40).max, "SafeCast: value doesn't fit in 40 bits");
        return uint40(value);
    }

    /**
     * @dev Returns the downcasted uint32 from uint256, reverting on
     * overflow (when the input is greater than largest uint32).
     *
     * Counterpart to Solidity's `uint32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     *
     * _Available since v2.5._
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        require(value <= type(uint32).max, "SafeCast: value doesn't fit in 32 bits");
        return uint32(value);
    }

    /**
     * @dev Returns the downcasted uint24 from uint256, reverting on
     * overflow (when the input is greater than largest uint24).
     *
     * Counterpart to Solidity's `uint24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     *
     * _Available since v4.7._
     */
    function toUint24(uint256 value) internal pure returns (uint24) {
        require(value <= type(uint24).max, "SafeCast: value doesn't fit in 24 bits");
        return uint24(value);
    }

    /**
     * @dev Returns the downcasted uint16 from uint256, reverting on
     * overflow (when the input is greater than largest uint16).
     *
     * Counterpart to Solidity's `uint16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     *
     * _Available since v2.5._
     */
    function toUint16(uint256 value) internal pure returns (uint16) {
        require(value <= type(uint16).max, "SafeCast: value doesn't fit in 16 bits");
        return uint16(value);
    }

    /**
     * @dev Returns the downcasted uint8 from uint256, reverting on
     * overflow (when the input is greater than largest uint8).
     *
     * Counterpart to Solidity's `uint8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     *
     * _Available since v2.5._
     */
    function toUint8(uint256 value) internal pure returns (uint8) {
        require(value <= type(uint8).max, "SafeCast: value doesn't fit in 8 bits");
        return uint8(value);
    }

    /**
     * @dev Converts a signed int256 into an unsigned uint256.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     *
     * _Available since v3.0._
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "SafeCast: value must be positive");
        return uint256(value);
    }

    /**
     * @dev Returns the downcasted int248 from int256, reverting on
     * overflow (when the input is less than smallest int248 or
     * greater than largest int248).
     *
     * Counterpart to Solidity's `int248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     *
     * _Available since v4.7._
     */
    function toInt248(int256 value) internal pure returns (int248) {
        require(value >= type(int248).min && value <= type(int248).max, "SafeCast: value doesn't fit in 248 bits");
        return int248(value);
    }

    /**
     * @dev Returns the downcasted int240 from int256, reverting on
     * overflow (when the input is less than smallest int240 or
     * greater than largest int240).
     *
     * Counterpart to Solidity's `int240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     *
     * _Available since v4.7._
     */
    function toInt240(int256 value) internal pure returns (int240) {
        require(value >= type(int240).min && value <= type(int240).max, "SafeCast: value doesn't fit in 240 bits");
        return int240(value);
    }

    /**
     * @dev Returns the downcasted int232 from int256, reverting on
     * overflow (when the input is less than smallest int232 or
     * greater than largest int232).
     *
     * Counterpart to Solidity's `int232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     *
     * _Available since v4.7._
     */
    function toInt232(int256 value) internal pure returns (int232) {
        require(value >= type(int232).min && value <= type(int232).max, "SafeCast: value doesn't fit in 232 bits");
        return int232(value);
    }

    /**
     * @dev Returns the downcasted int224 from int256, reverting on
     * overflow (when the input is less than smallest int224 or
     * greater than largest int224).
     *
     * Counterpart to Solidity's `int224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     *
     * _Available since v4.7._
     */
    function toInt224(int256 value) internal pure returns (int224) {
        require(value >= type(int224).min && value <= type(int224).max, "SafeCast: value doesn't fit in 224 bits");
        return int224(value);
    }

    /**
     * @dev Returns the downcasted int216 from int256, reverting on
     * overflow (when the input is less than smallest int216 or
     * greater than largest int216).
     *
     * Counterpart to Solidity's `int216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     *
     * _Available since v4.7._
     */
    function toInt216(int256 value) internal pure returns (int216) {
        require(value >= type(int216).min && value <= type(int216).max, "SafeCast: value doesn't fit in 216 bits");
        return int216(value);
    }

    /**
     * @dev Returns the downcasted int208 from int256, reverting on
     * overflow (when the input is less than smallest int208 or
     * greater than largest int208).
     *
     * Counterpart to Solidity's `int208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     *
     * _Available since v4.7._
     */
    function toInt208(int256 value) internal pure returns (int208) {
        require(value >= type(int208).min && value <= type(int208).max, "SafeCast: value doesn't fit in 208 bits");
        return int208(value);
    }

    /**
     * @dev Returns the downcasted int200 from int256, reverting on
     * overflow (when the input is less than smallest int200 or
     * greater than largest int200).
     *
     * Counterpart to Solidity's `int200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     *
     * _Available since v4.7._
     */
    function toInt200(int256 value) internal pure returns (int200) {
        require(value >= type(int200).min && value <= type(int200).max, "SafeCast: value doesn't fit in 200 bits");
        return int200(value);
    }

    /**
     * @dev Returns the downcasted int192 from int256, reverting on
     * overflow (when the input is less than smallest int192 or
     * greater than largest int192).
     *
     * Counterpart to Solidity's `int192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     *
     * _Available since v4.7._
     */
    function toInt192(int256 value) internal pure returns (int192) {
        require(value >= type(int192).min && value <= type(int192).max, "SafeCast: value doesn't fit in 192 bits");
        return int192(value);
    }

    /**
     * @dev Returns the downcasted int184 from int256, reverting on
     * overflow (when the input is less than smallest int184 or
     * greater than largest int184).
     *
     * Counterpart to Solidity's `int184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     *
     * _Available since v4.7._
     */
    function toInt184(int256 value) internal pure returns (int184) {
        require(value >= type(int184).min && value <= type(int184).max, "SafeCast: value doesn't fit in 184 bits");
        return int184(value);
    }

    /**
     * @dev Returns the downcasted int176 from int256, reverting on
     * overflow (when the input is less than smallest int176 or
     * greater than largest int176).
     *
     * Counterpart to Solidity's `int176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     *
     * _Available since v4.7._
     */
    function toInt176(int256 value) internal pure returns (int176) {
        require(value >= type(int176).min && value <= type(int176).max, "SafeCast: value doesn't fit in 176 bits");
        return int176(value);
    }

    /**
     * @dev Returns the downcasted int168 from int256, reverting on
     * overflow (when the input is less than smallest int168 or
     * greater than largest int168).
     *
     * Counterpart to Solidity's `int168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     *
     * _Available since v4.7._
     */
    function toInt168(int256 value) internal pure returns (int168) {
        require(value >= type(int168).min && value <= type(int168).max, "SafeCast: value doesn't fit in 168 bits");
        return int168(value);
    }

    /**
     * @dev Returns the downcasted int160 from int256, reverting on
     * overflow (when the input is less than smallest int160 or
     * greater than largest int160).
     *
     * Counterpart to Solidity's `int160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     *
     * _Available since v4.7._
     */
    function toInt160(int256 value) internal pure returns (int160) {
        require(value >= type(int160).min && value <= type(int160).max, "SafeCast: value doesn't fit in 160 bits");
        return int160(value);
    }

    /**
     * @dev Returns the downcasted int152 from int256, reverting on
     * overflow (when the input is less than smallest int152 or
     * greater than largest int152).
     *
     * Counterpart to Solidity's `int152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     *
     * _Available since v4.7._
     */
    function toInt152(int256 value) internal pure returns (int152) {
        require(value >= type(int152).min && value <= type(int152).max, "SafeCast: value doesn't fit in 152 bits");
        return int152(value);
    }

    /**
     * @dev Returns the downcasted int144 from int256, reverting on
     * overflow (when the input is less than smallest int144 or
     * greater than largest int144).
     *
     * Counterpart to Solidity's `int144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     *
     * _Available since v4.7._
     */
    function toInt144(int256 value) internal pure returns (int144) {
        require(value >= type(int144).min && value <= type(int144).max, "SafeCast: value doesn't fit in 144 bits");
        return int144(value);
    }

    /**
     * @dev Returns the downcasted int136 from int256, reverting on
     * overflow (when the input is less than smallest int136 or
     * greater than largest int136).
     *
     * Counterpart to Solidity's `int136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     *
     * _Available since v4.7._
     */
    function toInt136(int256 value) internal pure returns (int136) {
        require(value >= type(int136).min && value <= type(int136).max, "SafeCast: value doesn't fit in 136 bits");
        return int136(value);
    }

    /**
     * @dev Returns the downcasted int128 from int256, reverting on
     * overflow (when the input is less than smallest int128 or
     * greater than largest int128).
     *
     * Counterpart to Solidity's `int128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     *
     * _Available since v3.1._
     */
    function toInt128(int256 value) internal pure returns (int128) {
        require(value >= type(int128).min && value <= type(int128).max, "SafeCast: value doesn't fit in 128 bits");
        return int128(value);
    }

    /**
     * @dev Returns the downcasted int120 from int256, reverting on
     * overflow (when the input is less than smallest int120 or
     * greater than largest int120).
     *
     * Counterpart to Solidity's `int120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     *
     * _Available since v4.7._
     */
    function toInt120(int256 value) internal pure returns (int120) {
        require(value >= type(int120).min && value <= type(int120).max, "SafeCast: value doesn't fit in 120 bits");
        return int120(value);
    }

    /**
     * @dev Returns the downcasted int112 from int256, reverting on
     * overflow (when the input is less than smallest int112 or
     * greater than largest int112).
     *
     * Counterpart to Solidity's `int112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     *
     * _Available since v4.7._
     */
    function toInt112(int256 value) internal pure returns (int112) {
        require(value >= type(int112).min && value <= type(int112).max, "SafeCast: value doesn't fit in 112 bits");
        return int112(value);
    }

    /**
     * @dev Returns the downcasted int104 from int256, reverting on
     * overflow (when the input is less than smallest int104 or
     * greater than largest int104).
     *
     * Counterpart to Solidity's `int104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     *
     * _Available since v4.7._
     */
    function toInt104(int256 value) internal pure returns (int104) {
        require(value >= type(int104).min && value <= type(int104).max, "SafeCast: value doesn't fit in 104 bits");
        return int104(value);
    }

    /**
     * @dev Returns the downcasted int96 from int256, reverting on
     * overflow (when the input is less than smallest int96 or
     * greater than largest int96).
     *
     * Counterpart to Solidity's `int96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     *
     * _Available since v4.7._
     */
    function toInt96(int256 value) internal pure returns (int96) {
        require(value >= type(int96).min && value <= type(int96).max, "SafeCast: value doesn't fit in 96 bits");
        return int96(value);
    }

    /**
     * @dev Returns the downcasted int88 from int256, reverting on
     * overflow (when the input is less than smallest int88 or
     * greater than largest int88).
     *
     * Counterpart to Solidity's `int88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     *
     * _Available since v4.7._
     */
    function toInt88(int256 value) internal pure returns (int88) {
        require(value >= type(int88).min && value <= type(int88).max, "SafeCast: value doesn't fit in 88 bits");
        return int88(value);
    }

    /**
     * @dev Returns the downcasted int80 from int256, reverting on
     * overflow (when the input is less than smallest int80 or
     * greater than largest int80).
     *
     * Counterpart to Solidity's `int80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     *
     * _Available since v4.7._
     */
    function toInt80(int256 value) internal pure returns (int80) {
        require(value >= type(int80).min && value <= type(int80).max, "SafeCast: value doesn't fit in 80 bits");
        return int80(value);
    }

    /**
     * @dev Returns the downcasted int72 from int256, reverting on
     * overflow (when the input is less than smallest int72 or
     * greater than largest int72).
     *
     * Counterpart to Solidity's `int72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     *
     * _Available since v4.7._
     */
    function toInt72(int256 value) internal pure returns (int72) {
        require(value >= type(int72).min && value <= type(int72).max, "SafeCast: value doesn't fit in 72 bits");
        return int72(value);
    }

    /**
     * @dev Returns the downcasted int64 from int256, reverting on
     * overflow (when the input is less than smallest int64 or
     * greater than largest int64).
     *
     * Counterpart to Solidity's `int64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     *
     * _Available since v3.1._
     */
    function toInt64(int256 value) internal pure returns (int64) {
        require(value >= type(int64).min && value <= type(int64).max, "SafeCast: value doesn't fit in 64 bits");
        return int64(value);
    }

    /**
     * @dev Returns the downcasted int56 from int256, reverting on
     * overflow (when the input is less than smallest int56 or
     * greater than largest int56).
     *
     * Counterpart to Solidity's `int56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     *
     * _Available since v4.7._
     */
    function toInt56(int256 value) internal pure returns (int56) {
        require(value >= type(int56).min && value <= type(int56).max, "SafeCast: value doesn't fit in 56 bits");
        return int56(value);
    }

    /**
     * @dev Returns the downcasted int48 from int256, reverting on
     * overflow (when the input is less than smallest int48 or
     * greater than largest int48).
     *
     * Counterpart to Solidity's `int48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     *
     * _Available since v4.7._
     */
    function toInt48(int256 value) internal pure returns (int48) {
        require(value >= type(int48).min && value <= type(int48).max, "SafeCast: value doesn't fit in 48 bits");
        return int48(value);
    }

    /**
     * @dev Returns the downcasted int40 from int256, reverting on
     * overflow (when the input is less than smallest int40 or
     * greater than largest int40).
     *
     * Counterpart to Solidity's `int40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     *
     * _Available since v4.7._
     */
    function toInt40(int256 value) internal pure returns (int40) {
        require(value >= type(int40).min && value <= type(int40).max, "SafeCast: value doesn't fit in 40 bits");
        return int40(value);
    }

    /**
     * @dev Returns the downcasted int32 from int256, reverting on
     * overflow (when the input is less than smallest int32 or
     * greater than largest int32).
     *
     * Counterpart to Solidity's `int32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     *
     * _Available since v3.1._
     */
    function toInt32(int256 value) internal pure returns (int32) {
        require(value >= type(int32).min && value <= type(int32).max, "SafeCast: value doesn't fit in 32 bits");
        return int32(value);
    }

    /**
     * @dev Returns the downcasted int24 from int256, reverting on
     * overflow (when the input is less than smallest int24 or
     * greater than largest int24).
     *
     * Counterpart to Solidity's `int24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     *
     * _Available since v4.7._
     */
    function toInt24(int256 value) internal pure returns (int24) {
        require(value >= type(int24).min && value <= type(int24).max, "SafeCast: value doesn't fit in 24 bits");
        return int24(value);
    }

    /**
     * @dev Returns the downcasted int16 from int256, reverting on
     * overflow (when the input is less than smallest int16 or
     * greater than largest int16).
     *
     * Counterpart to Solidity's `int16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     *
     * _Available since v3.1._
     */
    function toInt16(int256 value) internal pure returns (int16) {
        require(value >= type(int16).min && value <= type(int16).max, "SafeCast: value doesn't fit in 16 bits");
        return int16(value);
    }

    /**
     * @dev Returns the downcasted int8 from int256, reverting on
     * overflow (when the input is less than smallest int8 or
     * greater than largest int8).
     *
     * Counterpart to Solidity's `int8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     *
     * _Available since v3.1._
     */
    function toInt8(int256 value) internal pure returns (int8) {
        require(value >= type(int8).min && value <= type(int8).max, "SafeCast: value doesn't fit in 8 bits");
        return int8(value);
    }

    /**
     * @dev Converts an unsigned uint256 into a signed int256.
     *
     * Requirements:
     *
     * - input must be less than or equal to maxInt256.
     *
     * _Available since v3.0._
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        // Note: Unsafe cast below is okay because `type(int256).max` is guaranteed to be positive
        require(value <= uint256(type(int256).max), "SafeCast: value doesn't fit in an int256");
        return int256(value);
    }
}