// SPDX-License-Identifier: MIT

pragma solidity 0.4.24;

// import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "@aragon/os/contracts/lib/math/SafeMath64.sol";
import "@aragon/os/contracts/common/IsContract.sol";

    /**added code without aragonApp */
import "./role/RoleManager.sol";
import "./interfaces/IKiKiStakingHelper.sol";
    /**added code without aragonApp */

import "solidity-bytes-utils/contracts/BytesLib.sol";

import "./interfaces/IKiKiStaking.sol";
import "./interfaces/INodeOperatorsRegistry.sol";
import "./interfaces/IDepositContract.sol";
import "./KiKiStakingToken.sol";
import "../farm/IMasterChef.sol";

/**
* @title Liquid staking pool implementation
*
* KiKiStaking is an Ethereum 2.0 liquid staking protocol solving the problem of frozen staked Ethers
* until transfers become available in Ethereum 2.0.
* Whitepaper: TODO
*
* NOTE: the code below assumes moderate amount of node operators, e.g. up to 50.
*
* Since balances of all token holders change when the amount of total pooled Ether
* changes, this token cannot fully implement ERC20 standard: it only emits `Transfer`
* events upon explicit transfer between holders. In contrast, when KiKiStaking oracle reports
* rewards, no Transfer events are generated: doing so would require emitting an event
* for each token holder and thus running an unbounded loop.
*/
contract KiKiStaking is IKiKiStaking, IsContract, KiKiStakingToken
, RoleManager
// , AragonApp 
{
    using SafeMath for uint256;
    using SafeMath64 for uint64;
    using UnstructuredStorage for bytes32;

    /// ACL
    bytes32 constant public PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 constant public MANAGE_FEE = keccak256("MANAGE_FEE");
    bytes32 constant public MANAGE_WITHDRAWAL_KEY = keccak256("MANAGE_WITHDRAWAL_KEY");
    bytes32 constant public SET_ORACLE = keccak256("SET_ORACLE");
    bytes32 constant public BURN_ROLE = keccak256("BURN_ROLE");
    bytes32 constant public SET_TREASURY = keccak256("SET_TREASURY");
    bytes32 constant public SET_INSURANCE_FUND = keccak256("SET_INSURANCE_FUND");
    bytes32 constant public DEPOSIT_ROLE = keccak256("DEPOSIT_ROLE");
    bytes32 constant public VAULT_ROLE = keccak256("VAULT_ROLE");

    uint256 constant public PUBKEY_LENGTH = 48;
    uint256 constant public WITHDRAWAL_CREDENTIALS_LENGTH = 32;
    uint256 constant public SIGNATURE_LENGTH = 96;

    uint256 constant public DEPOSIT_SIZE = 32 ether;

    uint256 internal constant DEPOSIT_AMOUNT_UNIT = 1000000000 wei;

    /// @dev default value for maximum number of Ethereum 2.0 validators registered in a single depositBufferedEther call
    uint256 internal constant DEFAULT_MAX_DEPOSITS_PER_CALL = 150;

    bytes32 internal constant FEE_POSITION = keccak256("KKS.KKS.fee");

    bytes32 internal constant DEPOSIT_CONTRACT_POSITION = keccak256("KKS.KKS.depositContract");
    bytes32 internal constant ORACLE_POSITION = keccak256("KKS.KKS.oracle");
    bytes32 internal constant NODE_OPERATORS_REGISTRY_POSITION = keccak256("KKS.KKS.nodeOperatorsRegistry");
    bytes32 internal constant HELPER_POSITION = keccak256("KKS.KKS.helper");
    bytes32 internal constant MASTERCHEF_POSITION = keccak256("KKS.KKS.masterChef");
    bytes32 internal constant FEETO_POSITION = keccak256("KKS.KKS.feeTo");
    bytes32 internal constant RECOVERY_VAULT_POSITION = keccak256("KKS.KKS.recoveryVault");

    /// @dev amount of Ether (on the current Ethereum side) buffered on this smart contract balance
    bytes32 internal constant BUFFERED_ETHER_POSITION = keccak256("KKS.KKS.bufferedEther");
    /// @dev amount of Ether (on the current Ethereum side) in liquidity pool pool on this smart contract balance
    bytes32 internal constant LiQUIDITY_POSITION = keccak256("KKS.KKS.swapPoolEther");
    /// @dev number of deposited validators (incrementing counter of deposit operations).
    bytes32 internal constant DEPOSITED_VALIDATORS_POSITION = keccak256("KKS.KKS.depositedValidators");
    /// @dev total amount of Beacon-side Ether (sum of all the balances of KiKiStaking validators)
    bytes32 internal constant BEACON_BALANCE_POSITION = keccak256("KKS.KKS.beaconBalance");
    /// @dev number of KiKiStaking's validators available in the Beacon state
    bytes32 internal constant BEACON_VALIDATORS_POSITION = keccak256("KKS.KKS.beaconValidators");
    /// @dev Credentials which allows the DAO to withdraw Ether on the 2.0 side
    bytes32 internal constant WITHDRAWAL_CREDENTIALS_POSITION = keccak256("KKS.KKS.withdrawalCredentials");
    /// @dev Total swap fee
    bytes32 internal constant TOTAL_SWAP_FEE_POSITION = keccak256("KKS.KKS.totalSwapFee");

    /**added code without aragonApp */
    bytes32 public constant TEMPORARY_WITHDRAW_ROLE = keccak256("TEMPORARY_WITHDRAW_ROLE");
    /**added code without aragonApp */

    /**
    * @dev As AragonApp, KiKiStaking contract must be initialized with following variables:
    * @param depositContract official ETH2 Deposit contract
    * @param _oracle oracle contract
    * @param _operators instance of Node Operators Registry
    */
    function initialize(
        IDepositContract depositContract,
        address _oracle,
        INodeOperatorsRegistry _operators,
        address _feeTo,
        IKiKiStakingHelper _helper,
        IMasterChef _masterChef,
        uint16 defaultAPR
    )
        public 
        onlyInit
        onlyMainManager
    {
        _setDepositContract(depositContract);
        _setOracle(_oracle);
        _setOperators(_operators);
        _setFeeTo(_feeTo);
        _setHelper(_helper);
        _setMasterChef(_masterChef);
        _setAPR(defaultAPR);

        initialized();
    }

    /**
    * @notice Send funds to the pool
    * @dev Users are able to submit their funds by transacting to the fallback function.
    * Unlike vanilla Eth2.0 Deposit contract, accepting only 32-Ether transactions, KiKiStaking
    * accepts payments of any size. Submitted Ethers are stored in Buffer until someone calls
    * depositBufferedEther() and pushes them to the ETH2 Deposit contract.
    */
    function() external payable {
        // protection against accidental submissions by calling non-existent function
        require(msg.data.length == 0, "NON_EMPTY_DATA");
        _submit(0);
    }

    /**
    * @notice Send funds to the pool with optional _referral parameter
    * @dev This function is alternative way to submit funds. Supports optional referral address.
    * @return Amount of StETH shares generated
    */
    function submit(address _referral) external payable returns (uint256) {
        return _submit(_referral);
    }

    /**
    * @notice Deposits buffered ethers to the official DepositContract.
    * @dev This function is separated from submit() to reduce the cost of sending funds.
    */
    function depositBufferedEther() external auth(DEPOSIT_ROLE) {
        return _depositBufferedEther(DEFAULT_MAX_DEPOSITS_PER_CALL);
    }

    /**
      * @notice Deposits buffered ethers to the official DepositContract, making no more than `_maxDeposits` deposit calls.
      * @dev This function is separated from submit() to reduce the cost of sending funds.
      */
    function depositBufferedEther(uint256 _maxDeposits) external auth(DEPOSIT_ROLE) {
        return _depositBufferedEther(_maxDeposits);
    }

    function burnShares(address _account, uint256 _sharesAmount)
        external
        authP(BURN_ROLE, arr(_account, _sharesAmount))
        returns (uint256 newTotalShares)
    {
        return _burnShares(_account, _sharesAmount);
    }

    /**
      * @notice Stop pool routine operations
      */
    function stop() external auth(PAUSE_ROLE) {
        _stop();
    }

    /**
      * @notice Resume pool routine operations
      */
    function resume() external auth(PAUSE_ROLE) {
        _resume();
    }

    /**
      * @notice Set fee rate to `_feeBasisPoints` basis points. The fees are accrued when oracles report staking results
      * @param _feeBasisPoints Fee rate, in basis points
      */
    function setFee(uint16 _feeBasisPoints) external auth(MANAGE_FEE) {
        _setBPValue(FEE_POSITION, _feeBasisPoints);
        emit FeeSet(_feeBasisPoints);
    }

    /**
      * @notice Set authorized oracle contract address to `_oracle`
      * @dev Contract specified here is allowed to make periodical updates of beacon states
      * by calling pushBeacon.
      * @param _oracle oracle contract
      */
    function setOracle(address _oracle) external auth(SET_ORACLE) {
        _setOracle(_oracle);
    }

    /**
      * @notice Set fee to address to `_feeTo`
      * @dev address specified here is used to accumulate the fee.
      * @param _feeTo address which accumulates fee.
      */
    function setFeeTo(address _feeTo) external auth(SET_TREASURY) {
        _setFeeTo(_feeTo);
    }

    /**
      * @notice Set credentials to withdraw ETH on ETH 2.0 side after the phase 2 is launched to `_withdrawalCredentials`
      * @dev Note that setWithdrawalCredentials discards all unused signing keys as the signatures are invalidated.
      * @param _withdrawalCredentials hash of withdrawal multisignature key as accepted by
      *        the deposit_contract.deposit function
      */
    function setWithdrawalCredentials(bytes32 _withdrawalCredentials) external auth(MANAGE_WITHDRAWAL_KEY) {
        WITHDRAWAL_CREDENTIALS_POSITION.setStorageBytes32(_withdrawalCredentials);
        getOperators().trimUnusedKeys();

        emit WithdrawalCredentialsSet(_withdrawalCredentials);
    }

    /**
      * @notice Issues withdrawal request. Not implemented.
      * @param _amount Amount of StETH to withdraw
      * @param _pubkeyHash Receiving address
      */
    function withdraw(uint256 _amount, bytes32 _pubkeyHash) external whenNotStopped { /* solhint-disable-line no-unused-vars */
        //will be upgraded to an actual implementation when withdrawals are enabled (Phase 1.5 or 2 of Eth2 launch, likely late 2021 or 2022).
        //at the moment withdrawals are not possible in the beacon chain and there's no workaround
        revert("NOT_IMPLEMENTED_YET");
    }

    /**
    * @notice Updates the number of KiKiStaking-controlled keys in the beacon validators set and their total balance.
    * @dev periodically called by the Oracle contract
    * @param _beaconValidators number of KiKiStaking's keys in the beacon state
    * @param _beaconBalance simmarized balance of KiKiStaking-controlled keys in wei
    */
    function pushBeacon(uint256 _beaconValidators, uint256 _beaconBalance) external whenNotStopped {
        require(msg.sender == getOracle(), "APP_AUTH_FAILED");

        uint256 depositedValidators = DEPOSITED_VALIDATORS_POSITION.getStorageUint256();
        require(_beaconValidators <= depositedValidators, "REPORTED_MORE_DEPOSITED");

        uint256 beaconValidators = BEACON_VALIDATORS_POSITION.getStorageUint256();
        // Since the calculation of funds in the ingress queue is based on the number of validators
        // that are in a transient state (deposited but not seen on beacon yet), we can't decrease the previously
        // reported number (we'll be unable to figure out who is in the queue and count them).
        require(_beaconValidators >= beaconValidators, "REPORTED_LESS_VALIDATORS");
        uint256 appearedValidators = _beaconValidators.sub(beaconValidators);

        // RewardBase is the amount of money that is not included in the reward calculation
        // Just appeared validators * 32 added to the previously reported beacon balance
        uint256 rewardBase = (appearedValidators.mul(DEPOSIT_SIZE)).add(BEACON_BALANCE_POSITION.getStorageUint256());

        // Save the current beacon balance and validators to
        // calcuate rewards on the next push
        BEACON_BALANCE_POSITION.setStorageUint256(_beaconBalance);
        BEACON_VALIDATORS_POSITION.setStorageUint256(_beaconValidators);

        if (_beaconBalance > rewardBase) {
            uint256 rewards = _beaconBalance.sub(rewardBase);
            distributeRewards(rewards);
            getHelper().updateAPR();
        }
    }

    // /**
    //   * @notice Send funds to recovery Vault. Overrides default AragonApp behaviour.
    //   * @param _token Token to be sent to recovery vault.
    //   */
    // function transferToVault(address _token) external {
    //     require(allowRecoverability(_token), "RECOVER_DISALLOWED");
    //     address vault = getRecoveryVault();
    //     require(isContract(vault), "RECOVER_VAULT_NOT_CONTRACT");

    //     uint256 balance;
    //     if (_token == ETH) {
    //         balance = _getUnaccountedEther();
    //         // Transfer replaced by call to prevent transfer gas amount issue    
    //         require(vault.call.value(balance)(), "RECOVER_TRANSFER_FAILED");
    //     } else {
    //         ERC20 token = ERC20(_token);
    //         balance = token.staticBalanceOf(this);
    //         // safeTransfer comes from overriden default implementation
    //         require(token.safeTransfer(vault, balance), "RECOVER_TOKEN_TRANSFER_FAILED");
    //     }

    //     emit RecoverToVault(vault, _token, balance);
    // }

    /**added code without aragonApp */
    function setRecoveryVault(address vault) public auth(VAULT_ROLE) {
        RECOVERY_VAULT_POSITION.setStorageAddress(vault);
    }

    function getRecoveryVault() public view returns (address) {
        return RECOVERY_VAULT_POSITION.getStorageAddress();
    }
    /**added code without aragonApp */

    /**
      * @notice Returns staking rewards fee rate
      */
    function getFee() external view returns (uint16 feeBasisPoints) {
        return _getFee();
    }

    /**
      * @notice Returns current credentials to withdraw ETH on ETH 2.0 side after the phase 2 is launched
      */
    function getWithdrawalCredentials() public view returns (bytes32) {
        return WITHDRAWAL_CREDENTIALS_POSITION.getStorageBytes32();
    }

    /**
    * @notice Get the amount of Ether temporary buffered on this contract balance
    * @dev Buffered balance is kept on the contract from the moment the funds are received from user
    * until the moment they are actually sent to the official Deposit contract.
    * @return uint256 of buffered funds in wei
    */
    function getBufferedEther() external view returns (uint256) {
        return _getBufferedEther();
    }

    /**added code without aragonApp */

    /**
      * @notice Grant `role` entity to `entity`, need manager role
      * @param role Which role to grant
      * @param entity Role grant to who
      */
    function grantRole(bytes32 role, address entity) external {
        transferRole(role, entity);
    }

    /**
      * @notice Transfer `role` manager to `newManager`, need manager role
      * @param role Which role to transfer
      * @param role Role manager transfer to who
      */
    function transferManager(bytes32 role, address newManager) external {
        transferManagerRole(role, newManager);
    }

    /**added code without aragonApp */

    /**
      * @notice Issues swap `_amount` kETH to ETH from liquidity pool, transfer to `to`.
      * @param _amount Amount of kETH to burn
      * @param to Recipient
      * @return ETH swaped
      */
    function swap(uint256 _amount, address to) external returns (uint256) {
        require(_amount <= _sharesOf(msg.sender), "Not enough balance");
        require(address(0) != to, "Transfer to zero address");
        uint256 ethAmount = getPooledEthByShares(_amount);
        uint256 bufferPoolLiquidity = _getLiquidityPoolEther();
        uint256 outEth = bufferPoolLiquidity > ethAmount ? ethAmount : bufferPoolLiquidity;
        uint256 outEthWithFee = _swap(msg.sender, to, outEth, getSharesByPooledEth(outEth));
        safeTransferETH(to, outEthWithFee);
        return outEth;
    }

    /**
      * @notice Gets total swap fee
      */
    function getTotalSwapFee() external view returns (uint256) {
        return TOTAL_SWAP_FEE_POSITION.getStorageUint256();
    }

    function updateSwapPool(uint256 _value) external whenNotStopped {
        require(msg.sender == address(getHelper()));
        _updateSwapPool(_value);
    }

    /**added business functions */

    /**
      * @notice Gets deposit contract handle
      */
    function getDepositContract() public view returns (IDepositContract) {
        return IDepositContract(DEPOSIT_CONTRACT_POSITION.getStorageAddress());
    }

    /**
    * @notice Gets authorized oracle address
    * @return address of oracle contract
    */
    function getOracle() public view returns (address) {
        return ORACLE_POSITION.getStorageAddress();
    }

    /**
      * @notice Gets node operators registry interface handle
      */
    function getOperators() public view returns (INodeOperatorsRegistry) {
        return INodeOperatorsRegistry(NODE_OPERATORS_REGISTRY_POSITION.getStorageAddress());
    }

    /**
      * @notice Gets KiKiStaking helper interface handle
      */
    function getHelper() public view returns (IKiKiStakingHelper) {
        return IKiKiStakingHelper(HELPER_POSITION.getStorageAddress());
    }

    /**
      * @notice Gets masterChef interface handle
      */
    function getMasterChef() public view returns (IMasterChef) {
        return IMasterChef(MASTERCHEF_POSITION.getStorageAddress());
    }

    /**
      * @notice Returns the fee to address
      */
    function getFeeTo() public view returns (address) {
        return FEETO_POSITION.getStorageAddress();
    }

    /**
    * @notice Returns the key values related to Beacon-side
    * @return depositedValidators - number of deposited validators
    * @return beaconValidators - number of KiKiStaking's validators visible in the Beacon state, reported by oracles
    * @return beaconBalance - total amount of Beacon-side Ether (sum of all the balances of KiKiStaking validators)
    */
    function getBeaconStat() public view returns (uint256 depositedValidators, uint256 beaconValidators, uint256 beaconBalance) {
        depositedValidators = DEPOSITED_VALIDATORS_POSITION.getStorageUint256();
        beaconValidators = BEACON_VALIDATORS_POSITION.getStorageUint256();
        beaconBalance = BEACON_BALANCE_POSITION.getStorageUint256();
    }

    /**added business functions */

    function getLiquidity() public view returns (uint256) {
        return _getLiquidityPoolEther();
    }

    /**
      * @notice Gets the swap pool size
      */
    function getLiquidityPoolSize() public view returns (uint256) {
        return _getLiquidityPoolSize();
    }

    /**
      * @notice Gets the deposited and buffered ethers
      */
    function getDepositedAndBufferedEthers() public view returns (uint256) {
        return _getDepositedAndBufferedEthers();
    }
    /**added business functions */

    /**
    * @dev Sets the address of Deposit contract
    * @param _contract the address of Deposit contract
    */
    function _setDepositContract(IDepositContract _contract) internal {
        require(isContract(address(_contract)), "D_NOT_A_CONTRACT");
        DEPOSIT_CONTRACT_POSITION.setStorageAddress(address(_contract));
    }

    /**
    * @dev Internal function to set authorized oracle address
    * @param _oracle oracle contract
    */
    function _setOracle(address _oracle) internal {
        // require(isContract(_oracle), "NOT_A_CONTRACT");
        require(_oracle != address(0), "SET_ORACLE_ZERO_ADDRESS");
        ORACLE_POSITION.setStorageAddress(_oracle);
    }

    /**
    * @dev Internal function to set node operator registry address
    * @param _r registry of node operators
    */
    function _setOperators(INodeOperatorsRegistry _r) internal {
        require(isContract(_r), "NOT_A_CONTRACT");
        NODE_OPERATORS_REGISTRY_POSITION.setStorageAddress(_r);
    }

    /**
    * @dev Internal function to set KiKiStakingHelper address
    * @param _helper helper of KiKiStaking
    */
    function _setHelper(IKiKiStakingHelper _helper) internal {
        require(isContract(_helper), "NOT_A_CONTRACT");
        HELPER_POSITION.setStorageAddress(_helper);
    }

    /**
    * @dev Internal function to set MasterChef address
    * @param _masterChef masterChef
    */
    function _setMasterChef(IMasterChef _masterChef) internal {
        require(isContract(_masterChef), "NOT_A_CONTRACT");
        MASTERCHEF_POSITION.setStorageAddress(_masterChef);
    }

    function _setFeeTo(address _feeTo) internal {
        require(_feeTo != address(0), "SET_FEETO_ZERO_ADDRESS");
        FEETO_POSITION.setStorageAddress(_feeTo);
    }

    function _setAPR(uint16 _APR) internal {
        getHelper().setAPR(_APR);
    }

    /**
    * @dev Process user deposit, mints liquid tokens and increase the pool buffer
    * @param _referral address of referral.
    * @return amount of StETH shares generated
    */
    function _submit(address _referral) internal whenNotStopped returns (uint256) {
        address sender = msg.sender;
        uint256 deposit = msg.value;
        require(deposit != 0, "ZERO_DEPOSIT");

        uint256 sharesAmount = getSharesByPooledEth(deposit);
        if (sharesAmount == 0) {
            // totalControlledEther is 0: either the first-ever deposit or complete slashing
            // assume that shares correspond to Ether 1-to-1
            sharesAmount = deposit;
        }

        _mintShares(sender, sharesAmount);
        _submitted(sender, deposit, _referral);
        _emitTransferAfterMintingShares(sender, sharesAmount);
        return sharesAmount;
    }

    /**
     * @dev Emits an {Transfer} event where from is 0 address. Indicates mint events.
     */
    function _emitTransferAfterMintingShares(address _to, uint256 _sharesAmount) internal {
        emit Transfer(address(0), _to, getPooledEthByShares(_sharesAmount));
    }

    /**
    * @dev Deposits buffered eth to the DepositContract and assigns chunked deposits to node operators
    */
    function _depositBufferedEther(uint256 _maxDeposits) internal whenNotStopped {
        uint256 buffered = _getBufferedEther();
        if (buffered >= DEPOSIT_SIZE) {
            uint256 unaccounted = _getUnaccountedEther();
            uint256 numDeposits = buffered.div(DEPOSIT_SIZE);
            _markAsUnbuffered(_ETH2Deposit(numDeposits < _maxDeposits ? numDeposits : _maxDeposits));
            assert(_getUnaccountedEther() == unaccounted);
        }
    }

    /**
    * @dev Performs deposits to the ETH 2.0 side
    * @param _numDeposits Number of deposits to perform
    * @return actually deposited Ether amount
    */
    function _ETH2Deposit(uint256 _numDeposits) internal returns (uint256) {
        (bytes memory pubkeys, bytes memory signatures) = getOperators().assignNextSigningKeys(_numDeposits);
        if (pubkeys.length == 0) {
            return 0;
        }

        require(pubkeys.length.mod(PUBKEY_LENGTH) == 0, "REGISTRY_INCONSISTENT_PUBKEYS_LEN");
        require(signatures.length.mod(SIGNATURE_LENGTH) == 0, "REGISTRY_INCONSISTENT_SIG_LEN");

        uint256 numKeys = pubkeys.length.div(PUBKEY_LENGTH);
        require(numKeys == signatures.length.div(SIGNATURE_LENGTH), "REGISTRY_INCONSISTENT_SIG_COUNT");

        for (uint256 i = 0; i < numKeys; ++i) {
            bytes memory pubkey = BytesLib.slice(pubkeys, i * PUBKEY_LENGTH, PUBKEY_LENGTH);
            bytes memory signature = BytesLib.slice(signatures, i * SIGNATURE_LENGTH, SIGNATURE_LENGTH);
            _stake(pubkey, signature);
        }

        DEPOSITED_VALIDATORS_POSITION.setStorageUint256(
            DEPOSITED_VALIDATORS_POSITION.getStorageUint256().add(numKeys)
        );

        return numKeys.mul(DEPOSIT_SIZE);
    }

    /**
    * @dev Invokes a deposit call to the official Deposit contract
    * @param _pubkey Validator to stake for
    * @param _signature Signature of the deposit call
    */
    function _stake(bytes memory _pubkey, bytes memory _signature) internal {
        bytes32 withdrawalCredentials = getWithdrawalCredentials();
        require(withdrawalCredentials != 0, "EMPTY_WITHDRAWAL_CREDENTIALS");

        uint256 value = DEPOSIT_SIZE;

        // The following computations and Merkle tree-ization will make official Deposit contract happy
        uint256 depositAmount = value.div(DEPOSIT_AMOUNT_UNIT);
        assert(depositAmount.mul(DEPOSIT_AMOUNT_UNIT) == value);    // properly rounded

        // Compute deposit data root (`DepositData` hash tree root) according to deposit_contract.sol
        bytes32 pubkeyRoot = sha256(_pad64(_pubkey));
        bytes32 signatureRoot = sha256(
            abi.encodePacked(
                sha256(BytesLib.slice(_signature, 0, 64)),
                sha256(_pad64(BytesLib.slice(_signature, 64, SIGNATURE_LENGTH.sub(64))))
            )
        );

        bytes32 depositDataRoot = sha256(
            abi.encodePacked(
                sha256(abi.encodePacked(pubkeyRoot, withdrawalCredentials)),
                sha256(abi.encodePacked(_toLittleEndian64(depositAmount), signatureRoot))
            )
        );

        uint256 targetBalance = address(this).balance.sub(value);

        getDepositContract().deposit.value(value)(
            _pubkey, abi.encodePacked(withdrawalCredentials), _signature, depositDataRoot);
        require(address(this).balance == targetBalance, "EXPECTING_DEPOSIT_TO_HAPPEN");
    }

    /**
    * @dev Distributes rewards by minting and distributing corresponding amount of liquid tokens.
    * @param _totalRewards Total rewards accrued on the Ethereum 2.0 side in wei
    */
    function distributeRewards(uint256 _totalRewards) internal {
        // We need to take a defined percentage of the reported reward as a fee, and we do
        // this by minting new token shares and assigning them to the fee recipients (see
        // StETH docs for the explanation of the shares mechanics). The staking rewards fee
        // is defined in basis points (1 basis point is equal to 0.01%, 10000 is 100%).
        //
        // Since we've increased totalPooledEther by _totalRewards (which is already
        // performed by the time this function is called), the combined cost of all holders'
        // shares has became _totalRewards StETH tokens more, effectively splitting the reward
        // between each token holder proportionally to their token share.
        //
        // Now we want to mint new shares to the fee recipient, so that the total cost of the
        // newly-minted shares exactly corresponds to the fee taken:
        //
        // shares2mint * newShareCost = (_totalRewards * feeBasis) / 10000
        // newShareCost = newTotalPooledEther / (prevTotalShares + shares2mint)
        //
        // which follows to:
        //
        //                        _totalRewards * feeBasis * prevTotalShares
        // shares2mint = --------------------------------------------------------------
        //                 (newTotalPooledEther * 10000) - (feeBasis * _totalRewards)
        //
        // The effect is that the given percentage of the reward goes to the fee recipient, and
        // the rest of the reward is distributed between token holders proportionally to their
        // token shares.
        uint256 feeBasis = _getFee();
        uint256 totalPooledEther = _getTotalPooledEther();
        uint256 shares2mint = (
            _totalRewards.mul(feeBasis).mul(_getTotalShares())
            .div(
                totalPooledEther.mul(10000)
                .sub(feeBasis.mul(_totalRewards))
            )
        );

        // Mint the calculated amount of shares to fee address
        _mintShares(getFeeTo(), shares2mint);
    }

    /**
    * @dev Records a deposit made by a user with optional referral
    * @param _sender sender's address
    * @param _value Deposit value in wei
    * @param _referral address of the referral
    */
    function _submitted(address _sender, uint256 _value, address _referral) internal {
        _updateSwapPool(_value);
        stakingEthers[_sender] = stakingEthers[_sender].add(_value);
        getMasterChef().processDeposit(_sender, _value);
        TOTAL_STAKING_POSITION.setStorageUint256(_getTotalStaking().add(_value));
        emit Submitted(_sender, _value, _referral);
    }

    /**
      * @dev Records a deposit to the deposit_contract.deposit function.
      * @param _amount Total amount deposited to the ETH 2.0 side
      */
    function _markAsUnbuffered(uint256 _amount) internal {
        BUFFERED_ETHER_POSITION.setStorageUint256(
            BUFFERED_ETHER_POSITION.getStorageUint256().sub(_amount));

        emit Unbuffered(_amount);
    }

    /**
      * @dev Write a value nominated in basis points
      */
    function _setBPValue(bytes32 _slot, uint16 _value) internal {
        require(_value <= 10000, "VALUE_OVER_100_PERCENT");
        _slot.setStorageUint256(uint256(_value));
    }

    /**
      * @dev Returns staking rewards fee rate
      */
    function _getFee() internal view returns (uint16) {
        return _readBPValue(FEE_POSITION);
    }

    /**
      * @dev Read a value nominated in basis points
      */
    function _readBPValue(bytes32 _slot) internal view returns (uint16) {
        uint256 v = _slot.getStorageUint256();
        assert(v <= 10000);
        return uint16(v);
    }

    /**
      * @dev Gets the amount of Ether temporary buffered on this contract balance
      */
    function _getBufferedEther() internal view returns (uint256) {
        uint256 buffered = BUFFERED_ETHER_POSITION.getStorageUint256();
        require(address(this).balance >= buffered, "Buffered ether error");

        return buffered;
    }

    /**
      * @dev Gets the amount of Ether temporary in swap pool on this contract balance
      */
    function _getLiquidityPoolEther() internal view returns (uint256) {
        uint256 buffered = LiQUIDITY_POSITION.getStorageUint256();
        require(address(this).balance >= buffered, "KiKiStaking::_getLiquidityPoolEther: swap pool ether error");
        return buffered;
    }

    /**
      * @dev Gets the amount of Ether temporary in swap pool and buffered on this contract balance
      */
    function _getAllBufferingEther() internal view returns (uint256) {
        uint256 buffered = BUFFERED_ETHER_POSITION.getStorageUint256();
        buffered = buffered.add(LiQUIDITY_POSITION.getStorageUint256());
        assert(address(this).balance >= buffered);
        return buffered;
    }

    /**
      * @dev Gets unaccounted (excess) Ether on this contract balance
      */
    function _getUnaccountedEther() internal view returns (uint256) {
        return address(this).balance.sub(_getAllBufferingEther());
    }

    /**
    * @dev Calculates and returns the total base balance (multiple of 32) of validators in transient state,
    *      i.e. submitted to the official Deposit contract but not yet visible in the beacon state.
    * @return transient balance in wei (1e-18 Ether)
    */
    function _getTransientBalance() internal view returns (uint256) {
        uint256 depositedValidators = DEPOSITED_VALIDATORS_POSITION.getStorageUint256();
        uint256 beaconValidators = BEACON_VALIDATORS_POSITION.getStorageUint256();
        // beaconValidators can never be less than deposited ones.
        assert(depositedValidators >= beaconValidators);
        uint256 transientValidators = depositedValidators.sub(beaconValidators);
        return transientValidators.mul(DEPOSIT_SIZE);
    }

    /**
    * @dev Gets the total amount of Ether controlled by the system
    * @return total balance in wei
    */
    function _getTotalPooledEther() internal view returns (uint256) {
        uint256 bufferedBalance = _getAllBufferingEther();
        uint256 beaconBalance = BEACON_BALANCE_POSITION.getStorageUint256();
        uint256 transientBalance = _getTransientBalance();
        return bufferedBalance.add(beaconBalance).add(transientBalance);
    }

    function _getDepositedAndBufferedEthers() internal view returns (uint256) {
        return _getBufferedEther().add(DEPOSITED_VALIDATORS_POSITION.getStorageUint256().mul(DEPOSIT_SIZE));
    }

    function _getLiquidityPoolSize() internal view returns (uint256) {
        uint16 swapPoolPercentPoints = getHelper().getLiquidityPoolPercent();
        uint256 depositedAndBufferedEthers = _getDepositedAndBufferedEthers();
        return depositedAndBufferedEthers.mul(10000).div(uint256(10000).sub(swapPoolPercentPoints)).sub(depositedAndBufferedEthers);
    }

    function _updateSwapPool(uint256 _value) internal {
        (uint256 swapPoolLiquidity, uint256 bufferedEther) = getHelper().getLiquidityPoolNewStatus(_value);
        if (_getBufferedEther() != bufferedEther) {
            BUFFERED_ETHER_POSITION.setStorageUint256(bufferedEther);
        }
        LiQUIDITY_POSITION.setStorageUint256(swapPoolLiquidity);
    }

    /**
      * @dev Padding memory array with zeroes up to 64 bytes on the right
      * @param _b Memory array of size 32 .. 64
      */
    function _pad64(bytes memory _b) internal pure returns (bytes memory) {
        assert(_b.length >= 32 && _b.length <= 64);
        if (64 == _b.length)
            return _b;

        bytes memory zero32 = new bytes(32);
        assembly { mstore(add(zero32, 0x20), 0) }

        if (32 == _b.length)
            return BytesLib.concat(_b, zero32);
        else
            return BytesLib.concat(_b, BytesLib.slice(zero32, 0, uint256(64).sub(_b.length)));
    }

    /**
      * @dev Converting value to little endian bytes and padding up to 32 bytes on the right
      * @param _value Number less than `2**64` for compatibility reasons
      */
    function _toLittleEndian64(uint256 _value) internal pure returns (uint256 result) {
        result = 0;
        uint256 temp_value = _value;
        for (uint256 i = 0; i < 8; ++i) {
            result = (result << 8) | (temp_value & 0xFF);
            temp_value >>= 8;
        }

        assert(0 == temp_value);    // fully converted
        result <<= (24 * 8);
    }

    function to64(uint256 v) internal pure returns (uint64) {
        assert(v <= uint256(uint64(-1)));
        return uint64(v);
    }
    
    /**added code without aragonApp */

    function destroyContract(address recipient) external auth(TEMPORARY_WITHDRAW_ROLE) returns (uint256) {
        require(recipient != address(0), "Transfer to zero address");
        selfdestruct(recipient);
    }
    /**added code without aragonApp */

    /**added business functions */
    function _swap(address from, address recipient, uint256 ethAmount, uint256 kETHAmount) internal whenNotStopped returns (uint256) {
        uint256 ethFeeAmount = getHelper().getSwapFeeByETH(ethAmount);
        LiQUIDITY_POSITION.setStorageUint256(_getLiquidityPoolEther().sub(ethAmount).add(ethFeeAmount));
        uint256 _accountStaking = stakingEthers[from];
        _burnShares(from, kETHAmount);
        getMasterChef().processWithdraw(from, _accountStaking.sub(stakingEthers[from]));
        distributeRewards(ethFeeAmount);
        saveSwapFee(ethFeeAmount);
        emit Swap(from, recipient, ethAmount, kETHAmount);
        return ethAmount.sub(ethFeeAmount);
    }

    function safeTransferETH(address to, uint256 value) internal {
        bool success = to.call.value(value)(new bytes(0));
        require(
            success,
            "KiKiStaking::safeTransferETH: ETH transfer failed"
        );
    }

    function saveSwapFee(uint256 feeETH) internal {
        TOTAL_SWAP_FEE_POSITION.setStorageUint256(TOTAL_SWAP_FEE_POSITION.getStorageUint256().add(feeETH));
    }
    /**added business functions */
}

// See https://github.com/OpenZeppelin/openzeppelin-solidity/blob/d51e38758e1d985661534534d5c61e27bece5042/contracts/math/SafeMath.sol
// Adapted to use pragma ^0.4.24 and satisfy our linter rules

pragma solidity ^0.4.24;


/**
 * @title SafeMath
 * @dev Math operations with safety checks that revert on error
 */
library SafeMath {
    string private constant ERROR_ADD_OVERFLOW = "MATH_ADD_OVERFLOW";
    string private constant ERROR_SUB_UNDERFLOW = "MATH_SUB_UNDERFLOW";
    string private constant ERROR_MUL_OVERFLOW = "MATH_MUL_OVERFLOW";
    string private constant ERROR_DIV_ZERO = "MATH_DIV_ZERO";

    /**
    * @dev Multiplies two numbers, reverts on overflow.
    */
    function mul(uint256 _a, uint256 _b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522
        if (_a == 0) {
            return 0;
        }

        uint256 c = _a * _b;
        require(c / _a == _b, ERROR_MUL_OVERFLOW);

        return c;
    }

    /**
    * @dev Integer division of two numbers truncating the quotient, reverts on division by zero.
    */
    function div(uint256 _a, uint256 _b) internal pure returns (uint256) {
        require(_b > 0, ERROR_DIV_ZERO); // Solidity only automatically asserts when dividing by 0
        uint256 c = _a / _b;
        // assert(_a == _b * c + _a % _b); // There is no case in which this doesn't hold

        return c;
    }

    /**
    * @dev Subtracts two numbers, reverts on overflow (i.e. if subtrahend is greater than minuend).
    */
    function sub(uint256 _a, uint256 _b) internal pure returns (uint256) {
        require(_b <= _a, ERROR_SUB_UNDERFLOW);
        uint256 c = _a - _b;

        return c;
    }

    /**
    * @dev Adds two numbers, reverts on overflow.
    */
    function add(uint256 _a, uint256 _b) internal pure returns (uint256) {
        uint256 c = _a + _b;
        require(c >= _a, ERROR_ADD_OVERFLOW);

        return c;
    }

    /**
    * @dev Divides two numbers and returns the remainder (unsigned integer modulo),
    * reverts when dividing by zero.
    */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, ERROR_DIV_ZERO);
        return a % b;
    }
}

// See https://github.com/OpenZeppelin/openzeppelin-solidity/blob/d51e38758e1d985661534534d5c61e27bece5042/contracts/math/SafeMath.sol
// Adapted for uint64, pragma ^0.4.24, and satisfying our linter rules
// Also optimized the mul() implementation, see https://github.com/aragon/aragonOS/pull/417

pragma solidity ^0.4.24;


/**
 * @title SafeMath64
 * @dev Math operations for uint64 with safety checks that revert on error
 */
library SafeMath64 {
    string private constant ERROR_ADD_OVERFLOW = "MATH64_ADD_OVERFLOW";
    string private constant ERROR_SUB_UNDERFLOW = "MATH64_SUB_UNDERFLOW";
    string private constant ERROR_MUL_OVERFLOW = "MATH64_MUL_OVERFLOW";
    string private constant ERROR_DIV_ZERO = "MATH64_DIV_ZERO";

    /**
    * @dev Multiplies two numbers, reverts on overflow.
    */
    function mul(uint64 _a, uint64 _b) internal pure returns (uint64) {
        uint256 c = uint256(_a) * uint256(_b);
        require(c < 0x010000000000000000, ERROR_MUL_OVERFLOW); // 2**64 (less gas this way)

        return uint64(c);
    }

    /**
    * @dev Integer division of two numbers truncating the quotient, reverts on division by zero.
    */
    function div(uint64 _a, uint64 _b) internal pure returns (uint64) {
        require(_b > 0, ERROR_DIV_ZERO); // Solidity only automatically asserts when dividing by 0
        uint64 c = _a / _b;
        // assert(_a == _b * c + _a % _b); // There is no case in which this doesn't hold

        return c;
    }

    /**
    * @dev Subtracts two numbers, reverts on overflow (i.e. if subtrahend is greater than minuend).
    */
    function sub(uint64 _a, uint64 _b) internal pure returns (uint64) {
        require(_b <= _a, ERROR_SUB_UNDERFLOW);
        uint64 c = _a - _b;

        return c;
    }

    /**
    * @dev Adds two numbers, reverts on overflow.
    */
    function add(uint64 _a, uint64 _b) internal pure returns (uint64) {
        uint64 c = _a + _b;
        require(c >= _a, ERROR_ADD_OVERFLOW);

        return c;
    }

    /**
    * @dev Divides two numbers and returns the remainder (unsigned integer modulo),
    * reverts when dividing by zero.
    */
    function mod(uint64 a, uint64 b) internal pure returns (uint64) {
        require(b != 0, ERROR_DIV_ZERO);
        return a % b;
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


contract IsContract {
    /*
    * NOTE: this should NEVER be used for authentication
    * (see pitfalls: https://github.com/fergarrui/ethereum-security/tree/master/contracts/extcodesize).
    *
    * This is only intended to be used as a sanity check that an address is actually a contract,
    * RATHER THAN an address not being a contract.
    */
    function isContract(address _target) internal view returns (bool) {
        if (_target == address(0)) {
            return false;
        }

        uint256 size;
        assembly { size := extcodesize(_target) }
        return size > 0;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.4.24;

import "@aragon/os/contracts/common/Initializable.sol";
import "@aragon/os/contracts/acl/ACLSyntaxSugar.sol";
import "@aragon/os/contracts/common/VaultRecoverable.sol";

contract RoleManager is Initializable
, ACLSyntaxSugar
, VaultRecoverable {
    mapping(bytes32 => address) managers;
    bytes32 constant public MANAGE_MAIN = keccak256("MANAGE_MAIN");
    address internal constant ROLE_ANYONE = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    string private constant ERROR_AUTH_FAILED = "APP_AUTH_FAILED";
    string private constant ERROR_AUTH_MANAGER_FAILED = "ERROR_AUTH_MANAGER_FAILED";

    event TranseferRole(bytes32 role, address from, address to);
    event TranseferManager(bytes32 role, address from, address to);

    modifier authManager(bytes32 _role) {
        require(managers[_role] == msg.sender, ERROR_AUTH_MANAGER_FAILED);
        _;
    }

    modifier onlyMainManager() {
        require(MANAGE_MAIN.getStorageAddress() == msg.sender, ERROR_AUTH_FAILED);
        _;
    }

    modifier auth(bytes32 _role) {
        require(canPerform(msg.sender, _role), ERROR_AUTH_FAILED);
        _;
    }

    modifier authP(bytes32 _role, uint256[] _params) {
        require(canPerform(msg.sender, _role), ERROR_AUTH_FAILED);
        _;
    }

    constructor() public {
        managers[MANAGE_MAIN] = msg.sender;
        MANAGE_MAIN.setStorageAddress(msg.sender);
        emit TranseferManager(MANAGE_MAIN, address(0), msg.sender);
        emit TranseferRole(MANAGE_MAIN, address(0), msg.sender);
    }

    function getManager(bytes32 _role) public view returns (address) {
        require(managers[_role] != address(0), "RoleManager::getManager: invalid role");
        return managers[_role];
    }

    function canPerform(address _sender, bytes32 _role) public view returns (bool) {
        if (!hasInitialized()) {
            return false;
        }
        address entity = _role.getStorageAddress();
        if (entity == ROLE_ANYONE) {
            return true;
        }
        else {
            return _sender == entity;
        }
    }

    function registerRole(bytes32 role, address manager, address entity) public auth(MANAGE_MAIN) {
        require(managers[role] == address(0), "RoleManager::registerRole: role aready have");
        managers[role] = manager;
        role.setStorageAddress(entity);
        emit TranseferManager(role, address(0), manager);
        emit TranseferRole(role, address(0), entity);
    }

    function registerRoleGrantAnyone(bytes32 role, address manager) public {
        registerRole(role, manager, ROLE_ANYONE);
    }

    function transferRole(bytes32 role, address newEntity) internal authManager(role) {
        address oldEntity = role.getStorageAddress();
        role.setStorageAddress(newEntity);
        emit TranseferRole(role, oldEntity, newEntity);
    }

    function transferManagerRole(bytes32 role, address newManager) internal authManager(role) {
        managers[role] = newManager;
        emit TranseferManager(role, msg.sender, newManager);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.4.24;

interface IKiKiStakingHelper {
    function setLiquidityPoolPercent(uint16 points) external;
    function setSwapFeePercent(uint16 minPoints, uint16 maxPoints) external;
    function setAPR(uint16 _APR) external;
    function updateAPR() external;
    function getLiquidityPoolPercent() external view returns (uint16);
    function getSwapFeePercent() external view returns (uint16, uint16);
    function getSwapFeeByETH(uint256 etherAmount) external view returns (uint256);
    function getSwapFeePointsByETH(uint256 etherAmount) external view returns (uint16);
    function getLiquidityPoolNewStatus(uint256 _value) external view returns (uint256 swapPoolLiquidity, uint256 bufferedEther);
}

/*
 * @title Solidity Bytes Arrays Utils
 * @author Gonçalo Sá <[email protected]>
 *
 * @dev Bytes tightly packed arrays utility library for ethereum contracts written in Solidity.
 *      The library lets you concatenate, slice and type cast bytes arrays both in memory and storage.
 */

pragma solidity ^0.4.19;


library BytesLib {
    function concat(bytes memory _preBytes, bytes memory _postBytes) internal pure returns (bytes) {
        bytes memory tempBytes;

        assembly {
            // Get a location of some free memory and store it in tempBytes as
            // Solidity does for memory variables.
            tempBytes := mload(0x40)

            // Store the length of the first bytes array at the beginning of
            // the memory for tempBytes.
            let length := mload(_preBytes)
            mstore(tempBytes, length)

            // Maintain a memory counter for the current write location in the
            // temp bytes array by adding the 32 bytes for the array length to
            // the starting location.
            let mc := add(tempBytes, 0x20)
            // Stop copying when the memory counter reaches the length of the
            // first bytes array.
            let end := add(mc, length)

            for {
                // Initialize a copy counter to the start of the _preBytes data,
                // 32 bytes into its memory.
                let cc := add(_preBytes, 0x20)
            } lt(mc, end) {
                // Increase both counters by 32 bytes each iteration.
                mc := add(mc, 0x20)
                cc := add(cc, 0x20)
            } {
                // Write the _preBytes data into the tempBytes memory 32 bytes
                // at a time.
                mstore(mc, mload(cc))
            }

            // Add the length of _postBytes to the current length of tempBytes
            // and store it as the new length in the first 32 bytes of the
            // tempBytes memory.
            length := mload(_postBytes)
            mstore(tempBytes, add(length, mload(tempBytes)))

            // Move the memory counter back from a multiple of 0x20 to the
            // actual end of the _preBytes data.
            mc := end
            // Stop copying when the memory counter reaches the new combined
            // length of the arrays.
            end := add(mc, length)

            for {
                let cc := add(_postBytes, 0x20)
            } lt(mc, end) {
                mc := add(mc, 0x20)
                cc := add(cc, 0x20)
            } {
                mstore(mc, mload(cc))
            }

            // Update the free-memory pointer by padding our last write location
            // to 32 bytes: add 31 bytes to the end of tempBytes to move to the
            // next 32 byte block, then round down to the nearest multiple of
            // 32. If the sum of the length of the two arrays is zero then add 
            // one before rounding down to leave a blank 32 bytes (the length block with 0).
            mstore(0x40, and(
              add(add(end, iszero(add(length, mload(_preBytes)))), 31),
              not(31) // Round down to the nearest 32 bytes.
            ))
        }

        return tempBytes;
    }

    function concatStorage(bytes storage _preBytes, bytes memory _postBytes) internal {
        assembly {
            // Read the first 32 bytes of _preBytes storage, which is the length
            // of the array. (We don't need to use the offset into the slot
            // because arrays use the entire slot.)
            let fslot := sload(_preBytes_slot)
            // Arrays of 31 bytes or less have an even value in their slot,
            // while longer arrays have an odd value. The actual length is
            // the slot divided by two for odd values, and the lowest order
            // byte divided by two for even values.
            // If the slot is even, bitwise and the slot with 255 and divide by
            // two to get the length. If the slot is odd, bitwise and the slot
            // with -1 and divide by two.
            let slength := div(and(fslot, sub(mul(0x100, iszero(and(fslot, 1))), 1)), 2)
            let mlength := mload(_postBytes)
            let newlength := add(slength, mlength)
            // slength can contain both the length and contents of the array
            // if length < 32 bytes so let's prepare for that
            // v. http://solidity.readthedocs.io/en/latest/miscellaneous.html#layout-of-state-variables-in-storage
            switch add(lt(slength, 32), lt(newlength, 32))
            case 2 {
                // Since the new array still fits in the slot, we just need to
                // update the contents of the slot.
                // uint256(bytes_storage) = uint256(bytes_storage) + uint256(bytes_memory) + new_length
                sstore(
                    _preBytes_slot,
                    // all the modifications to the slot are inside this
                    // next block
                    add(
                        // we can just add to the slot contents because the
                        // bytes we want to change are the LSBs
                        fslot,
                        add(
                            mul(
                                div(
                                    // load the bytes from memory
                                    mload(add(_postBytes, 0x20)),
                                    // zero all bytes to the right
                                    exp(0x100, sub(32, mlength))
                                ),
                                // and now shift left the number of bytes to
                                // leave space for the length in the slot
                                exp(0x100, sub(32, newlength))
                            ),
                            // increase length by the double of the memory
                            // bytes length
                            mul(mlength, 2)
                        )
                    )
                )
            }
            case 1 {
                // The stored value fits in the slot, but the combined value
                // will exceed it.
                // get the keccak hash to get the contents of the array
                mstore(0x0, _preBytes_slot)
                let sc := add(keccak256(0x0, 0x20), div(slength, 32))

                // save new length
                sstore(_preBytes_slot, add(mul(newlength, 2), 1))

                // The contents of the _postBytes array start 32 bytes into
                // the structure. Our first read should obtain the `submod`
                // bytes that can fit into the unused space in the last word
                // of the stored array. To get this, we read 32 bytes starting
                // from `submod`, so the data we read overlaps with the array
                // contents by `submod` bytes. Masking the lowest-order
                // `submod` bytes allows us to add that value directly to the
                // stored value.

                let submod := sub(32, slength)
                let mc := add(_postBytes, submod)
                let end := add(_postBytes, mlength)
                let mask := sub(exp(0x100, submod), 1)

                sstore(
                    sc,
                    add(
                        and(
                            fslot,
                            0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00
                        ),
                        and(mload(mc), mask)
                    )
                )

                for {
                    mc := add(mc, 0x20)
                    sc := add(sc, 1)
                } lt(mc, end) {
                    sc := add(sc, 1)
                    mc := add(mc, 0x20)
                } {
                    sstore(sc, mload(mc))
                }

                mask := exp(0x100, sub(mc, end))

                sstore(sc, mul(div(mload(mc), mask), mask))
            }
            default {
                // get the keccak hash to get the contents of the array
                mstore(0x0, _preBytes_slot)
                // Start copying to the last used word of the stored array.
                let sc := add(keccak256(0x0, 0x20), div(slength, 32))

                // save new length
                sstore(_preBytes_slot, add(mul(newlength, 2), 1))

                // Copy over the first `submod` bytes of the new data as in
                // case 1 above.
                let slengthmod := mod(slength, 32)
                let mlengthmod := mod(mlength, 32)
                let submod := sub(32, slengthmod)
                let mc := add(_postBytes, submod)
                let end := add(_postBytes, mlength)
                let mask := sub(exp(0x100, submod), 1)

                sstore(sc, add(sload(sc), and(mload(mc), mask)))
                
                for { 
                    sc := add(sc, 1)
                    mc := add(mc, 0x20)
                } lt(mc, end) {
                    sc := add(sc, 1)
                    mc := add(mc, 0x20)
                } {
                    sstore(sc, mload(mc))
                }

                mask := exp(0x100, sub(mc, end))

                sstore(sc, mul(div(mload(mc), mask), mask))
            }
        }
    }

    function slice(bytes _bytes, uint _start, uint _length) internal  pure returns (bytes) {
        require(_bytes.length >= (_start + _length));

        bytes memory tempBytes;

        assembly {
            switch iszero(_length)
            case 0 {
                // Get a location of some free memory and store it in tempBytes as
                // Solidity does for memory variables.
                tempBytes := mload(0x40)

                // The first word of the slice result is potentially a partial
                // word read from the original array. To read it, we calculate
                // the length of that partial word and start copying that many
                // bytes into the array. The first word we copy will start with
                // data we don't care about, but the last `lengthmod` bytes will
                // land at the beginning of the contents of the new array. When
                // we're done copying, we overwrite the full first word with
                // the actual length of the slice.
                let lengthmod := and(_length, 31)

                // The multiplication in the next line is necessary
                // because when slicing multiples of 32 bytes (lengthmod == 0)
                // the following copy loop was copying the origin's length
                // and then ending prematurely not copying everything it should.
                let mc := add(add(tempBytes, lengthmod), mul(0x20, iszero(lengthmod)))
                let end := add(mc, _length)

                for {
                    // The multiplication in the next line has the same exact purpose
                    // as the one above.
                    let cc := add(add(add(_bytes, lengthmod), mul(0x20, iszero(lengthmod))), _start)
                } lt(mc, end) {
                    mc := add(mc, 0x20)
                    cc := add(cc, 0x20)
                } {
                    mstore(mc, mload(cc))
                }

                mstore(tempBytes, _length)

                //update free-memory pointer
                //allocating the array padded to 32 bytes like the compiler does now
                mstore(0x40, and(add(mc, 31), not(31)))
            }
            //if we want a zero-length slice let's just return a zero-length array
            default {
                tempBytes := mload(0x40)

                mstore(0x40, add(tempBytes, 0x20))
            }
        }

        return tempBytes;
    }

    function toAddress(bytes _bytes, uint _start) internal  pure returns (address) {
        require(_bytes.length >= (_start + 20));
        address tempAddress;

        assembly {
            tempAddress := div(mload(add(add(_bytes, 0x20), _start)), 0x1000000000000000000000000)
        }

        return tempAddress;
    }

    function toUint8(bytes _bytes, uint _start) internal  pure returns (uint8) {
        require(_bytes.length >= (_start + 1));
        uint8 tempUint;

        assembly {
            tempUint := mload(add(add(_bytes, 0x1), _start))
        }

        return tempUint;
    }

    function toUint16(bytes _bytes, uint _start) internal  pure returns (uint16) {
        require(_bytes.length >= (_start + 2));
        uint16 tempUint;

        assembly {
            tempUint := mload(add(add(_bytes, 0x2), _start))
        }

        return tempUint;
    }

    function toUint32(bytes _bytes, uint _start) internal  pure returns (uint32) {
        require(_bytes.length >= (_start + 4));
        uint32 tempUint;

        assembly {
            tempUint := mload(add(add(_bytes, 0x4), _start))
        }

        return tempUint;
    }

    function toUint(bytes _bytes, uint _start) internal  pure returns (uint256) {
        require(_bytes.length >= (_start + 32));
        uint256 tempUint;

        assembly {
            tempUint := mload(add(add(_bytes, 0x20), _start))
        }

        return tempUint;
    }

    function toBytes32(bytes _bytes, uint _start) internal  pure returns (bytes32) {
        require(_bytes.length >= (_start + 32));
        bytes32 tempBytes32;

        assembly {
            tempBytes32 := mload(add(add(_bytes, 0x20), _start))
        }

        return tempBytes32;
    }

    function equal(bytes memory _preBytes, bytes memory _postBytes) internal pure returns (bool) {
        bool success = true;

        assembly {
            let length := mload(_preBytes)

            // if lengths don't match the arrays are not equal
            switch eq(length, mload(_postBytes))
            case 1 {
                // cb is a circuit breaker in the for loop since there's
                //  no said feature for inline assembly loops
                // cb = 1 - don't breaker
                // cb = 0 - break
                let cb := 1

                let mc := add(_preBytes, 0x20)
                let end := add(mc, length)

                for {
                    let cc := add(_postBytes, 0x20)
                // the next line is the loop condition:
                // while(uint(mc < end) + cb == 2)
                } eq(add(lt(mc, end), cb), 2) {
                    mc := add(mc, 0x20)
                    cc := add(cc, 0x20)
                } {
                    // if any of these checks fails then arrays are not equal
                    if iszero(eq(mload(mc), mload(cc))) {
                        // unsuccess:
                        success := 0
                        cb := 0
                    }
                }
            }
            default {
                // unsuccess:
                success := 0
            }
        }

        return success;
    }

    function equalStorage(bytes storage _preBytes, bytes memory _postBytes) internal view returns (bool) {
        bool success = true;

        assembly {
            // we know _preBytes_offset is 0
            let fslot := sload(_preBytes_slot)
            // Decode the length of the stored array like in concatStorage().
            let slength := div(and(fslot, sub(mul(0x100, iszero(and(fslot, 1))), 1)), 2)
            let mlength := mload(_postBytes)

            // if lengths don't match the arrays are not equal
            switch eq(slength, mlength)
            case 1 {
                // slength can contain both the length and contents of the array
                // if length < 32 bytes so let's prepare for that
                // v. http://solidity.readthedocs.io/en/latest/miscellaneous.html#layout-of-state-variables-in-storage
                if iszero(iszero(slength)) {
                    switch lt(slength, 32)
                    case 1 {
                        // blank the last byte which is the length
                        fslot := mul(div(fslot, 0x100), 0x100)

                        if iszero(eq(fslot, mload(add(_postBytes, 0x20)))) {
                            // unsuccess:
                            success := 0
                        }
                    }
                    default {
                        // cb is a circuit breaker in the for loop since there's
                        //  no said feature for inline assembly loops
                        // cb = 1 - don't breaker
                        // cb = 0 - break
                        let cb := 1

                        // get the keccak hash to get the contents of the array
                        mstore(0x0, _preBytes_slot)
                        let sc := keccak256(0x0, 0x20)

                        let mc := add(_postBytes, 0x20)
                        let end := add(mc, mlength)

                        // the next line is the loop condition:
                        // while(uint(mc < end) + cb == 2)
                        for {} eq(add(lt(mc, end), cb), 2) {
                            sc := add(sc, 1)
                            mc := add(mc, 0x20)
                        } {
                            if iszero(eq(sload(sc), mload(mc))) {
                                // unsuccess:
                                success := 0
                                cb := 0
                            }
                        }
                    }
                }
            }
            default {
                // unsuccess:
                success := 0
            }
        }

        return success;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.4.24;

/**
  * @title Liquid staking pool
  *
  * For the high-level description of the pool operation please refer to the paper.
  * Pool manages withdrawal keys and fees. It receives ether submitted by users on the ETH 1 side
  * and stakes it via the deposit_contract.sol contract. It doesn't hold ether on it's balance,
  * only a small portion (buffer) of it.
  * It also mints new tokens for rewards generated at the ETH 2.0 side.
  */
interface IKiKiStaking {
    /**
     * @dev From IKiKiStaking interface, because "Interfaces cannot inherit".
     */
    function totalSupply() external view returns (uint256);
    function getTotalShares() external view returns (uint256);

    /**
      * @notice Stop pool routine operations
      */
    function stop() external;

    /**
      * @notice Resume pool routine operations
      */
    function resume() external;

    event Stopped();
    event Resumed();


    /**
      * @notice Set fee rate to `_feeBasisPoints` basis points. The fees are accrued when oracles report staking results
      * @param _feeBasisPoints Fee rate, in basis points
      */
    function setFee(uint16 _feeBasisPoints) external;

    /**
      * @notice Returns staking rewards fee rate
      */
    function getFee() external view returns (uint16 feeBasisPoints);

    event FeeSet(uint16 feeBasisPoints);

    /**
      * @notice Set credentials to withdraw ETH on ETH 2.0 side after the phase 2 is launched to `_withdrawalCredentials`
      * @dev Note that setWithdrawalCredentials discards all unused signing keys as the signatures are invalidated.
      * @param _withdrawalCredentials hash of withdrawal multisignature key as accepted by
      *        the deposit_contract.deposit function
      */
    function setWithdrawalCredentials(bytes32 _withdrawalCredentials) external;

    /**
      * @notice Returns current credentials to withdraw ETH on ETH 2.0 side after the phase 2 is launched
      */
    function getWithdrawalCredentials() external view returns (bytes);


    event WithdrawalCredentialsSet(bytes32 withdrawalCredentials);


    /**
      * @notice Ether on the ETH 2.0 side reported by the oracle
      * @param _epoch Epoch id
      * @param _eth2balance Balance in wei on the ETH 2.0 side
      */
    function pushBeacon(uint256 _epoch, uint256 _eth2balance) external;


    // User functions

    /**
      * @notice Adds eth to the pool
      * @return kETH Amount of kETH generated
      */
    function submit(address _referral) external payable returns (uint256 kETH);

    // Records a deposit made by a user
    event Submitted(address indexed sender, uint256 amount, address referral);

    // The `_amount` of ether was sent to the deposit_contract.deposit function.
    event Unbuffered(uint256 amount);

    /**
      * @notice Issues withdrawal request. Large withdrawals will be processed only after the phase 2 launch.
      * @param _amount Amount of kETH to burn
      * @param _pubkeyHash Receiving address
      */
    function withdraw(uint256 _amount, bytes32 _pubkeyHash) external;

    // Requested withdrawal of `etherAmount` to `pubkeyHash` on the ETH 2.0 side, `tokenAmount` burned by `sender`,
    // `sentFromBuffer` was sent on the current Ethereum side.
    event Withdrawal(address indexed sender, uint256 tokenAmount, uint256 sentFromBuffer,
                     bytes32 indexed pubkeyHash, uint256 etherAmount);

    /**
      * @notice Issues swap `_amount` kETH to ETH from liquidity pool, transfer to `to`.
      * @param _amount Amount of kETH to burn
      * @param to Recipient
      * @return ETH swaped
      */
    function swap(uint256 _amount, address to) external returns (uint256);

    // Requested swap of `ethAmount`, `kETHAmount` burned by `sender`
    event Swap(address sender, address recipient, uint256 ethAmount, uint256 kETHAmount);

    // Info functions

    /**
      * @notice Gets the amount of Ether controlled by the system
      */
    function getTotalPooledEther() external view returns (uint256);

    /**
      * @notice Gets the amount of Ether temporary buffered on this contract balance
      */
    function getBufferedEther() external view returns (uint256);

    /**
      * @notice Gets the amount of swap pool liquidity
      */
    function getLiquidity() external view returns (uint256);

    /**
      * @notice Gets the swap pool size
      */
    function getLiquidityPoolSize() external view returns (uint256);

    /**
      * @notice Gets the deposited and buffered ethers
      */
    function getDepositedAndBufferedEthers() external view returns (uint256);

    /**
      * @notice Gets total swap fee
      */
    function getTotalSwapFee() external view returns (uint256);

    /**
      * @notice Update liquidity pool status, when decrease liquidity pool size, may call this function.
      */
    function updateSwapPool(uint256 _value) external;

    /**
      * @notice Returns the key values related to Beacon-side
      * @return depositedValidators - number of deposited validators
      * @return beaconValidators - number of KiKiStaking's validators visible in the Beacon state, reported by oracles
      * @return beaconBalance - total amount of Beacon-side Ether (sum of all the balances of KiKiStaking validators)
      */
    function getBeaconStat() external view returns (uint256 depositedValidators, uint256 beaconValidators, uint256 beaconBalance);

    // /**
    //   * @notice Get current APR based on 10000 points
    //   */
    // function getAPR() external view returns (uint16);
}

// SPDX-License-Identifier: MIT

pragma solidity 0.4.24;

/**
  * @title Node Operator registry
  *
  * Node Operator registry manages signing keys and other node operator data.
  * It's also responsible for distributing rewards to node operators.
  */
interface INodeOperatorsRegistry {
    /**
      * @notice Add node operator named `name` with reward address `rewardAddress` and staking limit = 0 validators
      * @param _name Human-readable name
      * @param _rewardAddress Ethereum 1 address which receives kETH rewards for this operator
      * @return a unique key of the added operator
      */
    function addNodeOperator(string _name, address _rewardAddress) external returns (uint256 id);

    /**
      * @notice `_active ? 'Enable' : 'Disable'` the node operator #`_id`
      */
    function setNodeOperatorActive(uint256 _id, bool _active) external;

    /**
      * @notice Change human-readable name of the node operator #`_id` to `_name`
      */
    function setNodeOperatorName(uint256 _id, string _name) external;

    /**
      * @notice Change reward address of the node operator #`_id` to `_rewardAddress`
      */
    function setNodeOperatorRewardAddress(uint256 _id, address _rewardAddress) external;

    /**
      * @notice Set the maximum number of validators to stake for the node operator #`_id` to `_stakingLimit`
      */
    function setNodeOperatorStakingLimit(uint256 _id, uint64 _stakingLimit) external;

    /**
      * @notice Report `_stoppedIncrement` more stopped validators of the node operator #`_id`
      */
    function reportStoppedValidators(uint256 _id, uint64 _stoppedIncrement) external;

    /**
      * @notice Remove unused signing keys
      * @dev Function is used by the pool
      */
    function trimUnusedKeys() external;

    /**
      * @notice Returns total number of node operators
      */
    function getNodeOperatorsCount() external view returns (uint256);

    /**
      * @notice Returns number of active node operators
      */
    function getActiveNodeOperatorsCount() external view returns (uint256);

    /**
      * @notice Returns the n-th node operator
      * @param _id Node Operator id
      * @param _fullInfo If true, name will be returned as well
      */
    function getNodeOperator(uint256 _id, bool _fullInfo) external view returns (
        bool active,
        string name,
        address rewardAddress,
        uint64 stakingLimit,
        uint64 stoppedValidators,
        uint64 totalSigningKeys,
        uint64 usedSigningKeys);

    /**
      * @notice Returns the rewards distribution proportional to the effective stake for each node operator.
      * @param _totalRewardShares Total amount of reward shares to distribute.
      */
    function getRewardsDistribution(uint256 _totalRewardShares) external view returns (
        address[] memory recipients,
        uint256[] memory shares
    );

    event NodeOperatorAdded(uint256 id, string name, address rewardAddress, uint64 stakingLimit);
    event NodeOperatorActiveSet(uint256 indexed id, bool active);
    event NodeOperatorNameSet(uint256 indexed id, string name);
    event NodeOperatorRewardAddressSet(uint256 indexed id, address rewardAddress);
    event NodeOperatorStakingLimitSet(uint256 indexed id, uint64 stakingLimit);
    event NodeOperatorTotalStoppedValidatorsReported(uint256 indexed id, uint64 totalStopped);
    event NodeOperatorTotalKeysTrimmed(uint256 indexed id, uint64 totalKeysTrimmed);

    /**
     * @notice Selects and returns at most `_numKeys` signing keys (as well as the corresponding
     *         signatures) from the set of active keys and marks the selected keys as used.
     *         May only be called by the pool contract.
     *
     * @param _numKeys The number of keys to select. The actual number of selected keys may be less
     *        due to the lack of active keys.
     */
    function assignNextSigningKeys(uint256 _numKeys) external returns (bytes memory pubkeys, bytes memory signatures);

    /**
      * @notice Add `_quantity` validator signing keys to the keys of the node operator #`_operator_id`. Concatenated keys are: `_pubkeys`
      * @dev Along with each key the DAO has to provide a signatures for the
      *      (pubkey, withdrawal_credentials, 32000000000) message.
      *      Given that information, the contract'll be able to call
      *      deposit_contract.deposit on-chain.
      * @param _operator_id Node Operator id
      * @param _quantity Number of signing keys provided
      * @param _pubkeys Several concatenated validator signing keys
      * @param _signatures Several concatenated signatures for (pubkey, withdrawal_credentials, 32000000000) messages
      */
    function addSigningKeys(uint256 _operator_id, uint256 _quantity, bytes _pubkeys, bytes _signatures) external;

    /**
      * @notice Add `_quantity` validator signing keys of operator #`_id` to the set of usable keys. Concatenated keys are: `_pubkeys`. Can be done by node operator in question by using the designated rewards address.
      * @dev Along with each key the DAO has to provide a signatures for the
      *      (pubkey, withdrawal_credentials, 32000000000) message.
      *      Given that information, the contract'll be able to call
      *      deposit_contract.deposit on-chain.
      * @param _operator_id Node Operator id
      * @param _quantity Number of signing keys provided
      * @param _pubkeys Several concatenated validator signing keys
      * @param _signatures Several concatenated signatures for (pubkey, withdrawal_credentials, 32000000000) messages
      */
    function addSigningKeysOperatorBH(uint256 _operator_id, uint256 _quantity, bytes _pubkeys, bytes _signatures) external;

    /**
      * @notice Removes a validator signing key #`_index` from the keys of the node operator #`_operator_id`
      * @param _operator_id Node Operator id
      * @param _index Index of the key, starting with 0
      */
    function removeSigningKey(uint256 _operator_id, uint256 _index) external;

    /**
      * @notice Removes a validator signing key #`_index` of operator #`_id` from the set of usable keys. Executed on behalf of Node Operator.
      * @param _operator_id Node Operator id
      * @param _index Index of the key, starting with 0
      */
    function removeSigningKeyOperatorBH(uint256 _operator_id, uint256 _index) external;

    /**
      * @notice Removes an #`_amount` of validator signing keys starting from #`_index` of operator #`_id` usable keys. Executed on behalf of DAO.
      * @param _operator_id Node Operator id
      * @param _index Index of the key, starting with 0
      * @param _amount Number of keys to remove
      */
    function removeSigningKeys(uint256 _operator_id, uint256 _index, uint256 _amount) external;

    /**
      * @notice Removes an #`_amount` of validator signing keys starting from #`_index` of operator #`_id` usable keys. Executed on behalf of Node Operator.
      * @param _operator_id Node Operator id
      * @param _index Index of the key, starting with 0
      * @param _amount Number of keys to remove
      */
    function removeSigningKeysOperatorBH(uint256 _operator_id, uint256 _index, uint256 _amount) external;

    /**
      * @notice Returns total number of signing keys of the node operator #`_operator_id`
      */
    function getTotalSigningKeyCount(uint256 _operator_id) external view returns (uint256);

    /**
      * @notice Returns number of usable signing keys of the node operator #`_operator_id`
      */
    function getUnusedSigningKeyCount(uint256 _operator_id) external view returns (uint256);

    /**
      * @notice Returns n-th signing key of the node operator #`_operator_id`
      * @param _operator_id Node Operator id
      * @param _index Index of the key, starting with 0
      * @return key Key
      * @return depositSignature Signature needed for a deposit_contract.deposit call
      * @return used Flag indication if the key was used in the staking
      */
    function getSigningKey(uint256 _operator_id, uint256 _index) external view returns
            (bytes key, bytes depositSignature, bool used);


    /**
     * @notice Returns a monotonically increasing counter that gets incremented when any of the following happens:
     *   1. a node operator's key(s) is added;
     *   2. a node operator's key(s) is removed;
     *   3. a node operator's approved keys limit is changed.
     *   4. a node operator was activated/deactivated. Activation or deactivation of node operator
     *      might lead to usage of unvalidated keys in the assignNextSigningKeys method.
     */
    function getKeysOpIndex() external view returns (uint256);

    event SigningKeyAdded(uint256 indexed operatorId, bytes pubkey);
    event SigningKeyRemoved(uint256 indexed operatorId, bytes pubkey);
    event KeysOpIndexSet(uint256 keysOpIndex);
}

// SPDX-License-Identifier: MIT

pragma solidity 0.4.24;

/**
  * @title Deposit contract interface
  */
interface IDepositContract {
    /**
      * @notice Top-ups deposit of a validator on the ETH 2.0 side
      * @param pubkey Validator signing key
      * @param withdrawal_credentials Credentials that allows to withdraw funds
      * @param signature Signature of the request
      * @param deposit_data_root The deposits Merkle tree node, used as a checksum
      */
    function deposit(
        bytes /* 48 */ pubkey,
        bytes /* 32 */ withdrawal_credentials,
        bytes /* 96 */ signature,
        bytes32 deposit_data_root
    )
        external payable;
}

// SPDX-License-Identifier: MIT



pragma solidity 0.4.24;

import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "@aragon/os/contracts/common/UnstructuredStorage.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "./lib/Pausable.sol";

/**
 * @title Interest-bearing ERC20-like token for KiKiStaking Liquid Stacking protocol.
 *
 * This contract is abstract. To make the contract deployable override the
 * `_getTotalPooledEther` function. `KiKiStaking.sol` contract inherits kETH and defines
 * the `_getTotalPooledEther` function.
 *
 * kETH balances are dynamic and represent the holder's share in the total amount
 * of Ether controlled by the protocol. Account shares aren't normalized, so the
 * contract also stores the sum of all shares to calculate each account's token balance
 * which equals to:
 *
 *   shares[account] * _getTotalPooledEther() / _getTotalShares()
 *
 * For example, assume that we have:
 *
 *   _getTotalPooledEther() -> 10 ETH
 *   sharesOf(user1) -> 100
 *   sharesOf(user2) -> 400
 *
 * Therefore:
 *
 *   balanceOf(user1) -> 2 tokens which corresponds 2 ETH
 *   balanceOf(user2) -> 8 tokens which corresponds 8 ETH
 *
 * Since balances of all token holders change when the amount of total pooled Ether
 * changes, this token cannot fully implement ERC20 standard: it only emits `Transfer`
 * events upon explicit transfer between holders. In contrast, when total amount of
 * pooled Ether increases, no `Transfer` events are generated: doing so would require
 * emitting an event for each token holder and thus running an unbounded loop.
 *
 * The token inherits from `Pausable` and uses `whenNotStopped` modifier for methods
 * which change `shares` or `allowances`. `_stop` and `_resume` functions are overriden
 * in `KiKiStaking.sol` and might be called by an account with the `PAUSE_ROLE` assigned by the
 * DAO. This is useful for emergency scenarios, e.g. a protocol bug, where one might want
 * to freeze all token transfers and approvals until the emergency is resolved.
 */
contract KiKiStakingToken is IERC20, Pausable {
    using SafeMath for uint256;
    using UnstructuredStorage for bytes32;

    /**
     * @dev KiKiStakingToken balances are dynamic and are calculated based on the accounts' shares
     * and the total amount of Ether controlled by the protocol. Account shares aren't
     * normalized, so the contract also stores the sum of all shares to calculate
     * each account's token balance which equals to:
     *
     *   shares[account] * _getTotalPooledEther() / _getTotalShares()
    */
    mapping (address => uint256) private shares;

    /**
     * @dev Staking ethers from current side
     */
    mapping (address => uint256) internal stakingEthers;

    /**
     * @dev Allowances are nominated in tokens, not token shares.
     */
    mapping (address => mapping (address => uint256)) private allowances;

    /**
     * @dev Storage position used for holding the total amount of shares in existence.
     *
     * The KiKiStaking protocol is built on top of Aragon and uses the Unstructured Storage pattern
     * for value types:
     *
     * https://blog.openzeppelin.com/upgradeability-using-unstructured-storage
     * https://blog.8bitzen.com/posts/20-02-2020-understanding-how-solidity-upgradeable-unstructured-proxies-work
     *
     * For reference types, conventional storage variables are used since it's non-trivial
     * and error-prone to implement reference-type unstructured storage using Solidity v0.4;
     */
    bytes32 internal constant TOTAL_SHARES_POSITION = keccak256("KKS.kETH.totalShares");

    bytes32 internal constant TOTAL_STAKING_POSITION = keccak256("KKS.kETH.totalStaking");

    /**
     * @return the name of the token.
     */
    function name() public pure returns (string) {
        return "KiKi staking eth";
    }

    /**
     * @return the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public pure returns (string) {
        return "kETH";
    }

    /**
     * @return the number of decimals for getting user representation of a token amount.
     */
    function decimals() public pure returns (uint8) {
        return 18;
    }

    /**
     * @return the amount of tokens in existence.
     *
     * @dev Always equals to `_getTotalPooledEther()` since token amount
     * is pegged to the total amount of Ether controlled by the protocol.
     */
    function totalSupply() public view returns (uint256) {
        return _getTotalShares();
    }

    /**
     * @return the entire amount of Ether controlled by the protocol.
     *
     * @dev The sum of all ETH balances in the protocol.
     */
    function getTotalPooledEther() public view returns (uint256) {
        return _getTotalPooledEther();
    }

    /**
     * @return the amount of tokens owned by the `_account`.
     *
     * @dev Balances are dynamic and equal the `_account`'s share in the amount of the
     * total Ether controlled by the protocol. See `sharesOf`.
     */
    function ethOf(address _account) public view returns (uint256) {
        return getPooledEthByShares(_sharesOf(_account));
    }

    /**
     * @return the amount of shares owned by `_account`.
     */
    function balanceOf(address _account) public view returns (uint256) {
        return _sharesOf(_account);
    }

    /**
     * @notice Moves `_amount` tokens from the caller's account to the `_recipient` account.
     *
     * @return a boolean value indicating whether the operation succeeded.
     * Emits a `Transfer` event.
     *
     * Requirements:
     *
     * - `_recipient` cannot be the zero address.
     * - the caller must have a balance of at least `_amount`.
     * - the contract must not be paused.
     *
     * @dev The `_amount` argument is the amount of tokens, not shares.
     */
    function transfer(address _recipient, uint256 _amount) public returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    /**
     * @return the remaining number of tokens that `_spender` is allowed to spend
     * on behalf of `_owner` through `transferFrom`. This is zero by default.
     *
     * @dev This value changes when `approve` or `transferFrom` is called.
     */
    function allowance(address _owner, address _spender) public view returns (uint256) {
        return allowances[_owner][_spender];
    }

    /**
     * @notice Sets `_amount` as the allowance of `_spender` over the caller's tokens.
     *
     * @return a boolean value indicating whether the operation succeeded.
     * Emits an `Approval` event.
     *
     * Requirements:
     *
     * - `_spender` cannot be the zero address.
     * - the contract must not be paused.
     *
     * @dev The `_amount` argument is the amount of tokens, not shares.
     */
    function approve(address _spender, uint256 _amount) public returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    /**
     * @notice Moves `_amount` tokens from `_sender` to `_recipient` using the
     * allowance mechanism. `_amount` is then deducted from the caller's
     * allowance.
     *
     * @return a boolean value indicating whether the operation succeeded.
     *
     * Emits a `Transfer` event.
     * Emits an `Approval` event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `_sender` and `_recipient` cannot be the zero addresses.
     * - `_sender` must have a balance of at least `_amount`.
     * - the caller must have allowance for `_sender`'s tokens of at least `_amount`.
     * - the contract must not be paused.
     *
     * @dev The `_amount` argument is the amount of tokens, not shares.
     */
    function transferFrom(address _sender, address _recipient, uint256 _amount) public returns (bool) {
        uint256 currentAllowance = allowances[_sender][msg.sender];
        require(currentAllowance >= _amount, "TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE");

        _transfer(_sender, _recipient, _amount);
        _approve(_sender, msg.sender, currentAllowance.sub(_amount));
        return true;
    }

    /**
     * @notice Atomically increases the allowance granted to `_spender` by the caller by `_addedValue`.
     *
     * This is an alternative to `approve` that can be used as a mitigation for
     * problems described in:
     * https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol#L42
     * Emits an `Approval` event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `_spender` cannot be the the zero address.
     * - the contract must not be paused.
     */
    function increaseAllowance(address _spender, uint256 _addedValue) public returns (bool) {
        _approve(msg.sender, _spender, allowances[msg.sender][_spender].add(_addedValue));
        return true;
    }

    /**
     * @notice Atomically decreases the allowance granted to `_spender` by the caller by `_subtractedValue`.
     *
     * This is an alternative to `approve` that can be used as a mitigation for
     * problems described in:
     * https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol#L42
     * Emits an `Approval` event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `_spender` cannot be the zero address.
     * - `_spender` must have allowance for the caller of at least `_subtractedValue`.
     * - the contract must not be paused.
     */
    function decreaseAllowance(address _spender, uint256 _subtractedValue) public returns (bool) {
        uint256 currentAllowance = allowances[msg.sender][_spender];
        require(currentAllowance >= _subtractedValue, "DECREASED_ALLOWANCE_BELOW_ZERO");
        _approve(msg.sender, _spender, currentAllowance.sub(_subtractedValue));
        return true;
    }

    /**
     * @return the total amount of shares in existence.
     *
     * @dev The sum of all accounts' shares can be an arbitrary number, therefore
     * it is necessary to store it in order to calculate each account's relative share.
     */
    function getTotalShares() public view returns (uint256) {
        return _getTotalShares();
    }

    /**
      * @dev Gets total staking Ether on this side
      */
    function getTotalStaking() public view returns (uint256) {
        return _getTotalStaking();
    }

    /**
     * @return the amount of shares owned by `_account`.
     */
    function sharesOf(address _account) public view returns (uint256) {
        return _sharesOf(_account);
    }

    /**
     * @return the amount of staking ethers owned by `_account`.
     */
    function stakingOf(address _account) public view returns (uint256) {
        return stakingEthers[_account];
    }

    /**
     * @return the amount of shares that corresponds to `_ethAmount` protocol-controlled Ether.
     */
    function getSharesByPooledEth(uint256 _ethAmount) public view returns (uint256) {
        uint256 totalPooledEther = _getTotalPooledEther();
        if (totalPooledEther == 0) {
            return 0;
        } else {
            return _ethAmount
                .mul(_getTotalShares())
                .div(totalPooledEther);
        }
    }

    /**
     * @return the amount of Ether that corresponds to `_sharesAmount` token shares.
     */
    function getPooledEthByShares(uint256 _sharesAmount) public view returns (uint256) {
        uint256 totalShares = _getTotalShares();
        if (totalShares == 0) {
            return 0;
        } else {
            return _sharesAmount
                .mul(_getTotalPooledEther())
                .div(totalShares);
        }
    }

    /**
     * @return the total amount (in wei) of Ether controlled by the protocol.
     * @dev This is used for calaulating tokens from shares and vice versa.
     * @dev This function is required to be implemented in a derived contract.
     */
    function _getTotalPooledEther() internal view returns (uint256);

    /**
     * @notice Moves `_amount` tokens from `_sender` to `_recipient`.
     * Emits a `Transfer` event.
     */
    function _transfer(address _sender, address _recipient, uint256 _amount) internal {
        uint256 _sharesToTransfer = getSharesByPooledEth(_amount);
        _transferShares(_sender, _recipient, _sharesToTransfer);
        emit Transfer(_sender, _recipient, _amount);
    }

    /**
     * @notice Sets `_amount` as the allowance of `_spender` over the `_owner` s tokens.
     *
     * Emits an `Approval` event.
     *
     * Requirements:
     *
     * - `_owner` cannot be the zero address.
     * - `_spender` cannot be the zero address.
     * - the contract must not be paused.
     */
    function _approve(address _owner, address _spender, uint256 _amount) internal whenNotStopped {
        require(_owner != address(0), "APPROVE_FROM_ZERO_ADDRESS");
        require(_spender != address(0), "APPROVE_TO_ZERO_ADDRESS");

        allowances[_owner][_spender] = _amount;
        emit Approval(_owner, _spender, _amount);
    }

    /**
     * @return the total amount of shares in existence.
     */
    function _getTotalShares() internal view returns (uint256) {
        return TOTAL_SHARES_POSITION.getStorageUint256();
    }

    /**
      * @dev Gets total staking Ether on this side
      */
    function _getTotalStaking() internal view returns (uint256) {
        uint256 totalStaking = TOTAL_STAKING_POSITION.getStorageUint256();
        return totalStaking;
    }

    /**
     * @return the amount of shares owned by `_account`.
     */
    function _sharesOf(address _account) internal view returns (uint256) {
        return shares[_account];
    }

    /**
     * @notice Moves `_sharesAmount` shares from `_sender` to `_recipient`.
     *
     * Requirements:
     *
     * - `_sender` cannot be the zero address.
     * - `_recipient` cannot be the zero address.
     * - `_sender` must hold at least `_sharesAmount` shares.
     * - the contract must not be paused.
     */
    function _transferShares(address _sender, address _recipient, uint256 _sharesAmount) internal whenNotStopped {
        require(_sender != address(0), "TRANSFER_FROM_THE_ZERO_ADDRESS");
        require(_recipient != address(0), "TRANSFER_TO_THE_ZERO_ADDRESS");

        uint256 currentSenderShares = shares[_sender];
        require(_sharesAmount <= currentSenderShares, "TRANSFER_AMOUNT_EXCEEDS_BALANCE");

        shares[_sender] = currentSenderShares.sub(_sharesAmount);
        shares[_recipient] = shares[_recipient].add(_sharesAmount);
    }

    /**
     * @notice Creates `_sharesAmount` shares and assigns them to `_recipient`, increasing the total amount of shares.
     * @dev This doesn't increase the token total supply.
     *
     * Requirements:
     *
     * - `_recipient` cannot be the zero address.
     * - the contract must not be paused.
     */
    function _mintShares(address _recipient, uint256 _sharesAmount) internal whenNotStopped returns (uint256 newTotalShares) {
        require(_recipient != address(0), "MINT_TO_THE_ZERO_ADDRESS");

        newTotalShares = _getTotalShares().add(_sharesAmount);
        TOTAL_SHARES_POSITION.setStorageUint256(newTotalShares);

        shares[_recipient] = shares[_recipient].add(_sharesAmount);

        // Notice: we're not emitting a Transfer event from the zero address here since shares mint
        // works by taking the amount of tokens corresponding to the minted shares from all other
        // token holders, proportionally to their share. The total supply of the token doesn't change
        // as the result. This is equivalent to performing a send from each other token holder's
        // address to `address`, but we cannot reflect this as it would require sending an unbounded
        // number of events.
    }

    /**
     * @notice Destroys `_sharesAmount` shares from `_account`'s holdings, decreasing the total amount of shares.
     * @dev This doesn't decrease the token total supply.
     *
     * Requirements:
     *
     * - `_account` cannot be the zero address.
     * - `_account` must hold at least `_sharesAmount` shares.
     * - the contract must not be paused.
     */
    function _burnShares(address _account, uint256 _sharesAmount) internal whenNotStopped returns (uint256 newTotalShares) {
        require(_account != address(0), "BURN_FROM_THE_ZERO_ADDRESS");
        uint256 accountShares = shares[_account];
        require(_sharesAmount <= accountShares, "BURN_AMOUNT_EXCEEDS_BALANCE");
        newTotalShares = _getTotalShares().sub(_sharesAmount);
        TOTAL_SHARES_POSITION.setStorageUint256(newTotalShares);
        shares[_account] = accountShares.sub(_sharesAmount);

        uint256 _accountStaking = stakingEthers[_account];
        uint256 _stakingAmounts = _accountStaking.mul(_sharesAmount).div(accountShares);
        stakingEthers[_account] = _accountStaking.sub(_stakingAmounts);
        TOTAL_STAKING_POSITION.setStorageUint256(_getTotalStaking().sub(_stakingAmounts));

        // Notice: we're not emitting a Transfer event to the zero address here since shares burn
        // works by redistributing the amount of tokens corresponding to the burned shares between
        // all other token holders. The total supply of the token doesn't change as the result.
        // This is equivalent to performing a send from `address` to each other token holder address,
        // but we cannot reflect this as it would require sending an unbounded number of events.
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.4.24;

interface IMasterChef{
    
  function processDeposit(address account, uint _amount) external;

  function processWithdraw(address account, uint _amount) external;
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;

import "./TimeHelpers.sol";
import "./UnstructuredStorage.sol";


contract Initializable is TimeHelpers {
    using UnstructuredStorage for bytes32;

    // keccak256("aragonOS.initializable.initializationBlock")
    bytes32 internal constant INITIALIZATION_BLOCK_POSITION = 0xebb05b386a8d34882b8711d156f463690983dc47815980fb82aeeff1aa43579e;

    string private constant ERROR_ALREADY_INITIALIZED = "INIT_ALREADY_INITIALIZED";
    string private constant ERROR_NOT_INITIALIZED = "INIT_NOT_INITIALIZED";

    modifier onlyInit {
        require(getInitializationBlock() == 0, ERROR_ALREADY_INITIALIZED);
        _;
    }

    modifier isInitialized {
        require(hasInitialized(), ERROR_NOT_INITIALIZED);
        _;
    }

    /**
    * @return Block number in which the contract was initialized
    */
    function getInitializationBlock() public view returns (uint256) {
        return INITIALIZATION_BLOCK_POSITION.getStorageUint256();
    }

    /**
    * @return Whether the contract has been initialized by the time of the current block
    */
    function hasInitialized() public view returns (bool) {
        uint256 initializationBlock = getInitializationBlock();
        return initializationBlock != 0 && getBlockNumber() >= initializationBlock;
    }

    /**
    * @dev Function to be called by top level contract after initialization has finished.
    */
    function initialized() internal onlyInit {
        INITIALIZATION_BLOCK_POSITION.setStorageUint256(getBlockNumber());
    }

    /**
    * @dev Function to be called by top level contract after initialization to enable the contract
    *      at a future block number rather than immediately.
    */
    function initializedAt(uint256 _blockNumber) internal onlyInit {
        INITIALIZATION_BLOCK_POSITION.setStorageUint256(_blockNumber);
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


contract ACLSyntaxSugar {
    function arr() internal pure returns (uint256[]) {
        return new uint256[](0);
    }

    function arr(bytes32 _a) internal pure returns (uint256[] r) {
        return arr(uint256(_a));
    }

    function arr(bytes32 _a, bytes32 _b) internal pure returns (uint256[] r) {
        return arr(uint256(_a), uint256(_b));
    }

    function arr(address _a) internal pure returns (uint256[] r) {
        return arr(uint256(_a));
    }

    function arr(address _a, address _b) internal pure returns (uint256[] r) {
        return arr(uint256(_a), uint256(_b));
    }

    function arr(address _a, uint256 _b, uint256 _c) internal pure returns (uint256[] r) {
        return arr(uint256(_a), _b, _c);
    }

    function arr(address _a, uint256 _b, uint256 _c, uint256 _d) internal pure returns (uint256[] r) {
        return arr(uint256(_a), _b, _c, _d);
    }

    function arr(address _a, uint256 _b) internal pure returns (uint256[] r) {
        return arr(uint256(_a), uint256(_b));
    }

    function arr(address _a, address _b, uint256 _c, uint256 _d, uint256 _e) internal pure returns (uint256[] r) {
        return arr(uint256(_a), uint256(_b), _c, _d, _e);
    }

    function arr(address _a, address _b, address _c) internal pure returns (uint256[] r) {
        return arr(uint256(_a), uint256(_b), uint256(_c));
    }

    function arr(address _a, address _b, uint256 _c) internal pure returns (uint256[] r) {
        return arr(uint256(_a), uint256(_b), uint256(_c));
    }

    function arr(uint256 _a) internal pure returns (uint256[] r) {
        r = new uint256[](1);
        r[0] = _a;
    }

    function arr(uint256 _a, uint256 _b) internal pure returns (uint256[] r) {
        r = new uint256[](2);
        r[0] = _a;
        r[1] = _b;
    }

    function arr(uint256 _a, uint256 _b, uint256 _c) internal pure returns (uint256[] r) {
        r = new uint256[](3);
        r[0] = _a;
        r[1] = _b;
        r[2] = _c;
    }

    function arr(uint256 _a, uint256 _b, uint256 _c, uint256 _d) internal pure returns (uint256[] r) {
        r = new uint256[](4);
        r[0] = _a;
        r[1] = _b;
        r[2] = _c;
        r[3] = _d;
    }

    function arr(uint256 _a, uint256 _b, uint256 _c, uint256 _d, uint256 _e) internal pure returns (uint256[] r) {
        r = new uint256[](5);
        r[0] = _a;
        r[1] = _b;
        r[2] = _c;
        r[3] = _d;
        r[4] = _e;
    }
}


contract ACLHelpers {
    function decodeParamOp(uint256 _x) internal pure returns (uint8 b) {
        return uint8(_x >> (8 * 30));
    }

    function decodeParamId(uint256 _x) internal pure returns (uint8 b) {
        return uint8(_x >> (8 * 31));
    }

    function decodeParamsList(uint256 _x) internal pure returns (uint32 a, uint32 b, uint32 c) {
        a = uint32(_x);
        b = uint32(_x >> (8 * 4));
        c = uint32(_x >> (8 * 8));
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;

import "../lib/token/ERC20.sol";
import "./EtherTokenConstant.sol";
import "./IsContract.sol";
import "./IVaultRecoverable.sol";
import "./SafeERC20.sol";


contract VaultRecoverable is IVaultRecoverable, EtherTokenConstant, IsContract {
    using SafeERC20 for ERC20;

    string private constant ERROR_DISALLOWED = "RECOVER_DISALLOWED";
    string private constant ERROR_VAULT_NOT_CONTRACT = "RECOVER_VAULT_NOT_CONTRACT";
    string private constant ERROR_TOKEN_TRANSFER_FAILED = "RECOVER_TOKEN_TRANSFER_FAILED";

    /**
     * @notice Send funds to recovery Vault. This contract should never receive funds,
     *         but in case it does, this function allows one to recover them.
     * @param _token Token balance to be sent to recovery vault.
     */
    function transferToVault(address _token) external {
        require(allowRecoverability(_token), ERROR_DISALLOWED);
        address vault = getRecoveryVault();
        require(isContract(vault), ERROR_VAULT_NOT_CONTRACT);

        uint256 balance;
        if (_token == ETH) {
            balance = address(this).balance;
            vault.transfer(balance);
        } else {
            ERC20 token = ERC20(_token);
            balance = token.staticBalanceOf(this);
            require(token.safeTransfer(vault, balance), ERROR_TOKEN_TRANSFER_FAILED);
        }

        emit RecoverToVault(vault, _token, balance);
    }

    /**
    * @dev By default deriving from AragonApp makes it recoverable
    * @param token Token address that would be recovered
    * @return bool whether the app allows the recovery
    */
    function allowRecoverability(address token) public view returns (bool) {
        return true;
    }

    // Cast non-implemented interface to be public so we can use it internally
    function getRecoveryVault() public view returns (address);
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;

import "./Uint256Helpers.sol";


contract TimeHelpers {
    using Uint256Helpers for uint256;

    /**
    * @dev Returns the current block number.
    *      Using a function rather than `block.number` allows us to easily mock the block number in
    *      tests.
    */
    function getBlockNumber() internal view returns (uint256) {
        return block.number;
    }

    /**
    * @dev Returns the current block number, converted to uint64.
    *      Using a function rather than `block.number` allows us to easily mock the block number in
    *      tests.
    */
    function getBlockNumber64() internal view returns (uint64) {
        return getBlockNumber().toUint64();
    }

    /**
    * @dev Returns the current timestamp.
    *      Using a function rather than `block.timestamp` allows us to easily mock it in
    *      tests.
    */
    function getTimestamp() internal view returns (uint256) {
        return block.timestamp; // solium-disable-line security/no-block-members
    }

    /**
    * @dev Returns the current timestamp, converted to uint64.
    *      Using a function rather than `block.timestamp` allows us to easily mock it in
    *      tests.
    */
    function getTimestamp64() internal view returns (uint64) {
        return getTimestamp().toUint64();
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


library UnstructuredStorage {
    function getStorageBool(bytes32 position) internal view returns (bool data) {
        assembly { data := sload(position) }
    }

    function getStorageAddress(bytes32 position) internal view returns (address data) {
        assembly { data := sload(position) }
    }

    function getStorageBytes32(bytes32 position) internal view returns (bytes32 data) {
        assembly { data := sload(position) }
    }

    function getStorageUint256(bytes32 position) internal view returns (uint256 data) {
        assembly { data := sload(position) }
    }

    function setStorageBool(bytes32 position, bool data) internal {
        assembly { sstore(position, data) }
    }

    function setStorageAddress(bytes32 position, address data) internal {
        assembly { sstore(position, data) }
    }

    function setStorageBytes32(bytes32 position, bytes32 data) internal {
        assembly { sstore(position, data) }
    }

    function setStorageUint256(bytes32 position, uint256 data) internal {
        assembly { sstore(position, data) }
    }
}

pragma solidity ^0.4.24;


library Uint256Helpers {
    uint256 private constant MAX_UINT64 = uint64(-1);

    string private constant ERROR_NUMBER_TOO_BIG = "UINT64_NUMBER_TOO_BIG";

    function toUint64(uint256 a) internal pure returns (uint64) {
        require(a <= MAX_UINT64, ERROR_NUMBER_TOO_BIG);
        return uint64(a);
    }
}

// See https://github.com/OpenZeppelin/openzeppelin-solidity/blob/a9f910d34f0ab33a1ae5e714f69f9596a02b4d91/contracts/token/ERC20/ERC20.sol

pragma solidity ^0.4.24;


/**
 * @title ERC20 interface
 * @dev see https://github.com/ethereum/EIPs/issues/20
 */
contract ERC20 {
    function totalSupply() public view returns (uint256);

    function balanceOf(address _who) public view returns (uint256);

    function allowance(address _owner, address _spender)
        public view returns (uint256);

    function transfer(address _to, uint256 _value) public returns (bool);

    function approve(address _spender, uint256 _value)
        public returns (bool);

    function transferFrom(address _from, address _to, uint256 _value)
        public returns (bool);

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 value
    );

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


// aragonOS and aragon-apps rely on address(0) to denote native ETH, in
// contracts where both tokens and ETH are accepted
contract EtherTokenConstant {
    address internal constant ETH = address(0);
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


interface IVaultRecoverable {
    event RecoverToVault(address indexed vault, address indexed token, uint256 amount);

    function transferToVault(address token) external;

    function allowRecoverability(address token) external view returns (bool);
    function getRecoveryVault() external view returns (address);
}

// Inspired by AdEx (https://github.com/AdExNetwork/adex-protocol-eth/blob/b9df617829661a7518ee10f4cb6c4108659dd6d5/contracts/libs/SafeERC20.sol)
// and 0x (https://github.com/0xProject/0x-monorepo/blob/737d1dc54d72872e24abce5a1dbe1b66d35fa21a/contracts/protocol/contracts/protocol/AssetProxy/ERC20Proxy.sol#L143)

pragma solidity ^0.4.24;

import "../lib/token/ERC20.sol";


library SafeERC20 {
    // Before 0.5, solidity has a mismatch between `address.transfer()` and `token.transfer()`:
    // https://github.com/ethereum/solidity/issues/3544
    bytes4 private constant TRANSFER_SELECTOR = 0xa9059cbb;

    string private constant ERROR_TOKEN_BALANCE_REVERTED = "SAFE_ERC_20_BALANCE_REVERTED";
    string private constant ERROR_TOKEN_ALLOWANCE_REVERTED = "SAFE_ERC_20_ALLOWANCE_REVERTED";

    function invokeAndCheckSuccess(address _addr, bytes memory _calldata)
        private
        returns (bool)
    {
        bool ret;
        assembly {
            let ptr := mload(0x40)    // free memory pointer

            let success := call(
                gas,                  // forward all gas
                _addr,                // address
                0,                    // no value
                add(_calldata, 0x20), // calldata start
                mload(_calldata),     // calldata length
                ptr,                  // write output over free memory
                0x20                  // uint256 return
            )

            if gt(success, 0) {
                // Check number of bytes returned from last function call
                switch returndatasize

                // No bytes returned: assume success
                case 0 {
                    ret := 1
                }

                // 32 bytes returned: check if non-zero
                case 0x20 {
                    // Only return success if returned data was true
                    // Already have output in ptr
                    ret := eq(mload(ptr), 1)
                }

                // Not sure what was returned: don't mark as success
                default { }
            }
        }
        return ret;
    }

    function staticInvoke(address _addr, bytes memory _calldata)
        private
        view
        returns (bool, uint256)
    {
        bool success;
        uint256 ret;
        assembly {
            let ptr := mload(0x40)    // free memory pointer

            success := staticcall(
                gas,                  // forward all gas
                _addr,                // address
                add(_calldata, 0x20), // calldata start
                mload(_calldata),     // calldata length
                ptr,                  // write output over free memory
                0x20                  // uint256 return
            )

            if gt(success, 0) {
                ret := mload(ptr)
            }
        }
        return (success, ret);
    }

    /**
    * @dev Same as a standards-compliant ERC20.transfer() that never reverts (returns false).
    *      Note that this makes an external call to the token.
    */
    function safeTransfer(ERC20 _token, address _to, uint256 _amount) internal returns (bool) {
        bytes memory transferCallData = abi.encodeWithSelector(
            TRANSFER_SELECTOR,
            _to,
            _amount
        );
        return invokeAndCheckSuccess(_token, transferCallData);
    }

    /**
    * @dev Same as a standards-compliant ERC20.transferFrom() that never reverts (returns false).
    *      Note that this makes an external call to the token.
    */
    function safeTransferFrom(ERC20 _token, address _from, address _to, uint256 _amount) internal returns (bool) {
        bytes memory transferFromCallData = abi.encodeWithSelector(
            _token.transferFrom.selector,
            _from,
            _to,
            _amount
        );
        return invokeAndCheckSuccess(_token, transferFromCallData);
    }

    /**
    * @dev Same as a standards-compliant ERC20.approve() that never reverts (returns false).
    *      Note that this makes an external call to the token.
    */
    function safeApprove(ERC20 _token, address _spender, uint256 _amount) internal returns (bool) {
        bytes memory approveCallData = abi.encodeWithSelector(
            _token.approve.selector,
            _spender,
            _amount
        );
        return invokeAndCheckSuccess(_token, approveCallData);
    }

    /**
    * @dev Static call into ERC20.balanceOf().
    * Reverts if the call fails for some reason (should never fail).
    */
    function staticBalanceOf(ERC20 _token, address _owner) internal view returns (uint256) {
        bytes memory balanceOfCallData = abi.encodeWithSelector(
            _token.balanceOf.selector,
            _owner
        );

        (bool success, uint256 tokenBalance) = staticInvoke(_token, balanceOfCallData);
        require(success, ERROR_TOKEN_BALANCE_REVERTED);

        return tokenBalance;
    }

    /**
    * @dev Static call into ERC20.allowance().
    * Reverts if the call fails for some reason (should never fail).
    */
    function staticAllowance(ERC20 _token, address _owner, address _spender) internal view returns (uint256) {
        bytes memory allowanceCallData = abi.encodeWithSelector(
            _token.allowance.selector,
            _owner,
            _spender
        );

        (bool success, uint256 allowance) = staticInvoke(_token, allowanceCallData);
        require(success, ERROR_TOKEN_ALLOWANCE_REVERTED);

        return allowance;
    }

    /**
    * @dev Static call into ERC20.totalSupply().
    * Reverts if the call fails for some reason (should never fail).
    */
    function staticTotalSupply(ERC20 _token) internal view returns (uint256) {
        bytes memory totalSupplyCallData = abi.encodeWithSelector(_token.totalSupply.selector);

        (bool success, uint256 totalSupply) = staticInvoke(_token, totalSupplyCallData);
        require(success, ERROR_TOKEN_ALLOWANCE_REVERTED);

        return totalSupply;
    }
}

pragma solidity ^0.4.24;

/**
 * @title ERC20 interface
 * @dev see https://github.com/ethereum/EIPs/issues/20
 */
interface IERC20 {
  function totalSupply() external view returns (uint256);

  function balanceOf(address who) external view returns (uint256);

  function allowance(address owner, address spender)
    external view returns (uint256);

  function transfer(address to, uint256 value) external returns (bool);

  function approve(address spender, uint256 value)
    external returns (bool);

  function transferFrom(address from, address to, uint256 value)
    external returns (bool);

  event Transfer(
    address indexed from,
    address indexed to,
    uint256 value
  );

  event Approval(
    address indexed owner,
    address indexed spender,
    uint256 value
  );
}

// SPDX-License-Identifier: MIT



pragma solidity 0.4.24;

import "@aragon/os/contracts/common/UnstructuredStorage.sol";


contract Pausable {
    using UnstructuredStorage for bytes32;

    event Stopped();
    event Resumed();

    bytes32 internal constant ACTIVE_FLAG_POSITION = keccak256("KiKiStaking.Pausable.activeFlag");

    modifier whenNotStopped() {
        require(ACTIVE_FLAG_POSITION.getStorageBool(), "CONTRACT_IS_STOPPED");
        _;
    }

    modifier whenStopped() {
        require(!ACTIVE_FLAG_POSITION.getStorageBool(), "CONTRACT_IS_ACTIVE");
        _;
    }

    function isStopped() external view returns (bool) {
        return !ACTIVE_FLAG_POSITION.getStorageBool();
    }

    function _stop() internal whenNotStopped {
        ACTIVE_FLAG_POSITION.setStorageBool(false);
        emit Stopped();
    }

    function _resume() internal whenStopped {
        ACTIVE_FLAG_POSITION.setStorageBool(true);
        emit Resumed();
    }
}