pragma solidity 0.4.24;

import {DaoBoxVoting} from './DaoBoxVoting.sol';
import {VotesForwarder} from './VotesForwarder.sol';
import '@aragon/apps-agent/contracts/Agent.sol';
import '@aragon/apps-token-manager/contracts/TokenManager.sol';

import '@aragon/os/contracts/acl/ACL.sol';
import '@aragon/os/contracts/apm/Repo.sol';
import '@aragon/os/contracts/apm/APMNamehash.sol';
import '@aragon/os/contracts/kernel/Kernel.sol';
import '@aragon/os/contracts/lib/ens/ENS.sol';
import '@aragon/os/contracts/lib/ens/PublicResolver.sol';
import '@aragon/os/contracts/factory/DAOFactory.sol';
import '@aragon/os/contracts/common/IsContract.sol';
import '@aragon/id/contracts/IFIFSResolvingRegistrar.sol';

contract DaoBoxFactory is APMNamehash, IsContract {
    /* ====================================================================== //
                                        APP IDS
    // ====================================================================== */

    bytes32 internal VOTING_APP_ID = apmNamehash('daobox-voting');
    bytes32 internal VOTES_FORWARDER_APP_ID = apmNamehash('votes-forwarder');
    bytes32 internal AGENT_APP_ID = apmNamehash('agent');

    /* ====================================================================== //
                                        ERRORS
    // ====================================================================== */

    string private constant ERROR_ENS_NOT_CONTRACT = 'TEMPLATE_ENS_NOT_CONTRACT';
    string private constant ERROR_DAO_FACTORY_NOT_CONTRACT = 'TEMPLATE_DAO_FAC_NOT_CONTRACT';
    string private constant ERROR_ARAGON_ID_NOT_PROVIDED = 'TEMPLATE_ARAGON_ID_NOT_PROVIDED';
    string private constant ERROR_INVALID_ID = 'TEMPLATE_INVALID_ID';
    string private constant ERROR_VOTE_SETTINGS = 'COMPANY_VOTE_SETTINGS';

    /* ====================================================================== //
                                        STORAGE
    // ====================================================================== */

    ENS internal ens;
    DAOFactory internal daoFactory;
    MiniMeTokenFactory internal miniMeFactory;
    IFIFSResolvingRegistrar internal aragonID;
    DaoBoxVoting public daoBoxVoting;
    VotesForwarder public votesForwarder;

    /* ====================================================================== //
                                        EVENTS
    // ====================================================================== */

    event DeployDao(address dao);
    event SetupDao(address dao);
    event InstalledApp(address appProxy, bytes32 appId);
    event CompleteDAO(
        address dao,
        address acl,
        address agent,
        address voting,
        address votesForwarder
    );

    /* ====================================================================== //
                                    EXTERNAL FUNCTIONS
    // ====================================================================== */

    constructor(
        DaoBoxVoting _daoBoxVoting,
        VotesForwarder _votesForwarder,
        DAOFactory _daoFactory,
        ENS _ens,
        IFIFSResolvingRegistrar _aragonID
    ) public {
        daoBoxVoting = _daoBoxVoting;
        votesForwarder = _votesForwarder;
        ens = _ens;
        aragonID = _aragonID;
        daoFactory = _daoFactory;
    }

    /**
     * @dev Deploy a Company DAO using a previously cached MiniMe token
     * @param _token IVotes token that will be used as the company token
     * @param _id String with the name for org, will assign `[id].aragonid.eth`
     * @param _votingSettings Array of [supportRequired, minAcceptanceQuorum, voteDuration] to set up the voting app of the organization
     */
    function newInstance(
        address _token,
        string memory _id,
        uint64[3] memory _votingSettings
    ) public {
        // Validate ID
        require(bytes(_id).length > 0, ERROR_INVALID_ID);
        require(_votingSettings.length == 3, ERROR_VOTE_SETTINGS);

        // Create & Setup DAO
        Kernel dao = daoFactory.newDAO(this);
        emit DeployDao(address(dao));
        ACL acl = ACL(dao.acl());
        acl.createPermission(address(this), dao, dao.APP_MANAGER_ROLE(), address(this));

        // Create Agent
        bytes memory initializeAgentData = abi.encodeWithSelector(Agent(0).initialize.selector);
        Agent agent = Agent(_installApp(dao, AGENT_APP_ID, initializeAgentData, true));
        dao.setRecoveryVaultAppId(AGENT_APP_ID);

        // create Voting
        bytes memory initializeVotingData = abi.encodeWithSelector(
            DaoBoxVoting(0).initialize.selector,
            _token,
            _votingSettings[0],
            _votingSettings[1],
            _votingSettings[2]
        );
        DaoBoxVoting voting = DaoBoxVoting(_installVoting(dao, initializeVotingData));

        // create VotesForwarder
        bytes memory initializeVotesForwarderData = abi.encodeWithSelector(
            VotesForwarder(0).initialize.selector,
            address(_token)
        );
        VotesForwarder forwarder = VotesForwarder(
            _installVotesForwarder(dao, initializeVotesForwarderData)
        );

        // voting permissions
        acl.createPermission(voting, voting, voting.MODIFY_QUORUM_ROLE(), voting);
        acl.createPermission(voting, voting, voting.MODIFY_SUPPORT_ROLE(), voting);
        acl.createPermission(forwarder, voting, voting.CREATE_VOTES_ROLE(), voting);

        // agent permissions
        acl.createPermission(voting, agent, agent.EXECUTE_ROLE(), voting);
        acl.createPermission(voting, agent, agent.RUN_SCRIPT_ROLE(), voting);

        // votesForwarder permissions <-- HACK used to setup votesForwarder
        acl.createPermission(address(0), forwarder, forwarder.FANTOM_ROLE(), address(0));

        // finalise DAO
        _transferRootPermissionsFromTemplateAndFinalizeDAO(dao, voting, voting);
        _registerID(_id, dao);

        emit CompleteDAO(
            address(dao),
            address(acl),
            address(agent),
            address(voting),
            address(votesForwarder)
        );
    }

    /* ====================================================================== //
                                INTERNAL FUNCTIONS
    // ====================================================================== */
    function _installApp(
        Kernel _dao,
        bytes32 _appId,
        bytes memory _initializeData,
        bool _setDefault
    ) internal returns (address) {
        address latestBaseAppAddress = _latestVersionAppBase(_appId);
        address instance = address(
            _dao.newAppInstance(_appId, latestBaseAppAddress, _initializeData, _setDefault)
        );
        emit InstalledApp(instance, _appId);
        return instance;
    }

    function _installVoting(Kernel _dao, bytes memory _initializeData) internal returns (address) {
        address instance = address(
            _dao.newAppInstance(VOTING_APP_ID, daoBoxVoting, _initializeData, false)
        );
        emit InstalledApp(instance, VOTING_APP_ID);
        return instance;
    }

    function _installVotesForwarder(Kernel _dao, bytes memory _initializeData)
        internal
        returns (address)
    {
        address instance = address(
            _dao.newAppInstance(VOTES_FORWARDER_APP_ID, votesForwarder, _initializeData, false)
        );
        emit InstalledApp(instance, VOTES_FORWARDER_APP_ID);
        return instance;
    }

    function _latestVersionAppBase(bytes32 _appId) internal view returns (address base) {
        Repo repo = Repo(PublicResolver(ens.resolver(_appId)).addr(_appId));
        (, base, ) = repo.getLatest();
    }

    function _transferRootPermissionsFromTemplateAndFinalizeDAO(
        Kernel _dao,
        address _to,
        address _manager
    ) internal {
        ACL _acl = ACL(_dao.acl());
        _transferPermissionFromTemplate(_acl, _dao, _to, _dao.APP_MANAGER_ROLE(), _manager);
        _transferPermissionFromTemplate(_acl, _acl, _to, _acl.CREATE_PERMISSIONS_ROLE(), _manager);
        emit SetupDao(_dao);
    }

    function _transferPermissionFromTemplate(
        ACL _acl,
        address _app,
        address _to,
        bytes32 _permission,
        address _manager
    ) internal {
        _acl.grantPermission(_to, _app, _permission);
        _acl.revokePermission(address(this), _app, _permission);
        _acl.setPermissionManager(_manager, _app, _permission);
    }

    function _registerID(string memory _name, address _owner) internal {
        require(address(aragonID) != address(0), ERROR_ARAGON_ID_NOT_PROVIDED);
        aragonID.register(keccak256(abi.encodePacked(_name)), _owner);
    }
}

/*
 * SPDX-License-Identitifer:    GPL-3.0-or-later
 */

pragma solidity 0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/common/IForwarder.sol";

import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "@aragon/os/contracts/lib/math/SafeMath64.sol";

interface IVotes {
    /**
     * @dev Returns the current amount of votes that `account` has.
     */
    function getVotes(address account) external view returns (uint256);

    /**
     * @dev Returns the amount of votes that `account` had at the end of a past block (`blockNumber`).
     */
    function getPastVotes(address account, uint256 blockNumber)
        external
        view
        returns (uint256);

    /**
     * @dev Returns the total supply of votes available at the end of a past block (`blockNumber`).
     *
     * NOTE: This value is the sum of all available votes, which is not necessarily the sum of all delegated votes.
     * Votes that have not been delegated are still part of total supply, even though they would not participate in a
     * vote.
     */
    function getPastTotalSupply(uint256 blockNumber)
        external
        view
        returns (uint256);
}

contract DaoBoxVoting is IForwarder, AragonApp {
    using SafeMath for uint256;
    using SafeMath64 for uint64;

    bytes32 public constant CREATE_VOTES_ROLE = keccak256("CREATE_VOTES_ROLE");
    bytes32 public constant MODIFY_SUPPORT_ROLE =
        keccak256("MODIFY_SUPPORT_ROLE");
    bytes32 public constant MODIFY_QUORUM_ROLE =
        keccak256("MODIFY_QUORUM_ROLE");

    uint64 public constant PCT_BASE = 10**18; // 0% = 0; 1% = 10^16; 100% = 10^18

    string private constant ERROR_NO_VOTE = "VOTING_NO_VOTE";
    string private constant ERROR_INIT_PCTS = "VOTING_INIT_PCTS";
    string private constant ERROR_CHANGE_SUPPORT_PCTS =
        "VOTING_CHANGE_SUPPORT_PCTS";
    string private constant ERROR_CHANGE_QUORUM_PCTS =
        "VOTING_CHANGE_QUORUM_PCTS";
    string private constant ERROR_INIT_SUPPORT_TOO_BIG =
        "VOTING_INIT_SUPPORT_TOO_BIG";
    string private constant ERROR_CHANGE_SUPPORT_TOO_BIG =
        "VOTING_CHANGE_SUPP_TOO_BIG";
    string private constant ERROR_CAN_NOT_VOTE = "VOTING_CAN_NOT_VOTE";
    string private constant ERROR_CAN_NOT_EXECUTE = "VOTING_CAN_NOT_EXECUTE";
    string private constant ERROR_CAN_NOT_FORWARD = "VOTING_CAN_NOT_FORWARD";
    string private constant ERROR_NO_VOTING_POWER = "VOTING_NO_VOTING_POWER";

    enum VoterState {
        Absent,
        Yea,
        Nay
    }

    struct Vote {
        bool executed;
        uint64 startDate;
        uint64 snapshotBlock;
        uint64 supportRequiredPct;
        uint64 minAcceptQuorumPct;
        uint256 yea;
        uint256 nay;
        uint256 votingPower;
        bytes executionScript;
        mapping(address => VoterState) voters;
    }

    IVotes public token;
    uint64 public supportRequiredPct;
    uint64 public minAcceptQuorumPct;
    uint64 public voteTime;

    // We are mimicing an array, we use a mapping instead to make app upgrade more graceful
    mapping(uint256 => Vote) internal votes;
    uint256 public votesLength;

    event StartVote(
        uint256 indexed voteId,
        address indexed creator,
        string metadata
    );
    event CastVote(
        uint256 indexed voteId,
        address indexed voter,
        bool supports,
        uint256 stake
    );
    event ExecuteVote(uint256 indexed voteId);
    event ChangeSupportRequired(uint64 supportRequiredPct);
    event ChangeMinQuorum(uint64 minAcceptQuorumPct);

    modifier voteExists(uint256 _voteId) {
        require(_voteId < votesLength, ERROR_NO_VOTE);
        _;
    }

    /**
     * @notice Initialize Voting app with `_token.symbol(): string` for governance, minimum support of `@formatPct(_supportRequiredPct)`%, minimum acceptance quorum of `@formatPct(_minAcceptQuorumPct)`%, and a voting duration of `@transformTime(_voteTime)`
     * @param _token IVotes Address that will be used as governance token
     * @param _supportRequiredPct Percentage of yeas in casted votes for a vote to succeed (expressed as a percentage of 10^18; eg. 10^16 = 1%, 10^18 = 100%)
     * @param _minAcceptQuorumPct Percentage of yeas in total possible votes for a vote to succeed (expressed as a percentage of 10^18; eg. 10^16 = 1%, 10^18 = 100%)
     * @param _voteTime Seconds that a vote will be open for token holders to vote (unless enough yeas or nays have been cast to make an early decision)
     */
    function initialize(
        IVotes _token,
        uint64 _supportRequiredPct,
        uint64 _minAcceptQuorumPct,
        uint64 _voteTime
    ) external onlyInit {
        initialized();

        require(_minAcceptQuorumPct <= _supportRequiredPct, ERROR_INIT_PCTS);
        require(_supportRequiredPct < PCT_BASE, ERROR_INIT_SUPPORT_TOO_BIG);

        token = _token;
        supportRequiredPct = _supportRequiredPct;
        minAcceptQuorumPct = _minAcceptQuorumPct;
        voteTime = _voteTime;
    }

    /**
     * @notice Change required support to `@formatPct(_supportRequiredPct)`%
     * @param _supportRequiredPct New required support
     */
    function changeSupportRequiredPct(uint64 _supportRequiredPct)
        external
        authP(
            MODIFY_SUPPORT_ROLE,
            arr(uint256(_supportRequiredPct), uint256(supportRequiredPct))
        )
    {
        require(
            minAcceptQuorumPct <= _supportRequiredPct,
            ERROR_CHANGE_SUPPORT_PCTS
        );
        require(_supportRequiredPct < PCT_BASE, ERROR_CHANGE_SUPPORT_TOO_BIG);
        supportRequiredPct = _supportRequiredPct;

        emit ChangeSupportRequired(_supportRequiredPct);
    }

    /**
     * @notice Change minimum acceptance quorum to `@formatPct(_minAcceptQuorumPct)`%
     * @param _minAcceptQuorumPct New acceptance quorum
     */
    function changeMinAcceptQuorumPct(uint64 _minAcceptQuorumPct)
        external
        authP(
            MODIFY_QUORUM_ROLE,
            arr(uint256(_minAcceptQuorumPct), uint256(minAcceptQuorumPct))
        )
    {
        require(
            _minAcceptQuorumPct <= supportRequiredPct,
            ERROR_CHANGE_QUORUM_PCTS
        );
        minAcceptQuorumPct = _minAcceptQuorumPct;

        emit ChangeMinQuorum(_minAcceptQuorumPct);
    }

    /**
     * @notice Create a new vote about "`_metadata`"
     * @param _executionScript EVM script to be executed on approval
     * @param _metadata Vote metadata
     * @return voteId Id for newly created vote
     */
    function newVote(bytes _executionScript, string _metadata)
        external
        auth(CREATE_VOTES_ROLE)
        returns (uint256 voteId)
    {
        return _newVote(_executionScript, _metadata, true, true);
    }

    /**
     * @notice Create a new vote about "`_metadata`"
     * @param _executionScript EVM script to be executed on approval
     * @param _metadata Vote metadata
     * @param _castVote Whether to also cast newly created vote
     * @param _executesIfDecided Whether to also immediately execute newly created vote if decided
     * @return voteId id for newly created vote
     */
    function newVote(
        bytes _executionScript,
        string _metadata,
        bool _castVote,
        bool _executesIfDecided
    ) external auth(CREATE_VOTES_ROLE) returns (uint256 voteId) {
        return
            _newVote(
                _executionScript,
                _metadata,
                _castVote,
                _executesIfDecided
            );
    }

    /**
     * @notice Vote `_supports ? 'yes' : 'no'` in vote #`_voteId`
     * @dev Initialization check is implicitly provided by `voteExists()` as new votes can only be
     *      created via `newVote(),` which requires initialization
     * @param _voteId Id for vote
     * @param _supports Whether voter supports the vote
     * @param _executesIfDecided Whether the vote should execute its action if it becomes decided
     */
    function vote(
        uint256 _voteId,
        bool _supports,
        bool _executesIfDecided
    ) external voteExists(_voteId) {
        require(_canVote(_voteId, msg.sender), ERROR_CAN_NOT_VOTE);
        _vote(_voteId, _supports, msg.sender, _executesIfDecided);
    }

    /**
     * @notice Execute vote #`_voteId`
     * @dev Initialization check is implicitly provided by `voteExists()` as new votes can only be
     *      created via `newVote(),` which requires initialization
     * @param _voteId Id for vote
     */
    function executeVote(uint256 _voteId) external voteExists(_voteId) {
        _executeVote(_voteId);
    }

    // Forwarding fns

    /**
     * @notice Tells whether the Voting app is a forwarder or not
     * @dev IForwarder interface conformance
     * @return Always true
     */
    function isForwarder() external pure returns (bool) {
        return true;
    }

    /**
     * @notice Creates a vote to execute the desired action, and casts a support vote if possible
     * @dev IForwarder interface conformance
     * @param _evmScript Start vote with script
     */
    function forward(bytes _evmScript) public {
        require(canForward(msg.sender, _evmScript), ERROR_CAN_NOT_FORWARD);
        _newVote(_evmScript, "", true, true);
    }

    /**
     * @notice Tells whether `_sender` can forward actions or not
     * @dev IForwarder interface conformance
     * @param _sender Address of the account intending to forward an action
     * @return True if the given address can create votes, false otherwise
     */
    function canForward(address _sender, bytes) public view returns (bool) {
        // Note that `canPerform()` implicitly does an initialization check itself
        return canPerform(_sender, CREATE_VOTES_ROLE, arr());
    }

    // Getter fns

    /**
     * @notice Tells whether a vote #`_voteId` can be executed or not
     * @dev Initialization check is implicitly provided by `voteExists()` as new votes can only be
     *      created via `newVote(),` which requires initialization
     * @return True if the given vote can be executed, false otherwise
     */
    function canExecute(uint256 _voteId)
        public
        view
        voteExists(_voteId)
        returns (bool)
    {
        return _canExecute(_voteId);
    }

    /**
     * @notice Tells whether `_sender` can participate in the vote #`_voteId` or not
     * @dev Initialization check is implicitly provided by `voteExists()` as new votes can only be
     *      created via `newVote(),` which requires initialization
     * @return True if the given voter can participate a certain vote, false otherwise
     */
    function canVote(uint256 _voteId, address _voter)
        public
        view
        voteExists(_voteId)
        returns (bool)
    {
        return _canVote(_voteId, _voter);
    }

    /**
     * @dev Return all information for a vote by its ID
     * @param _voteId Vote identifier
     * @return Vote open status
     * @return Vote executed status
     * @return Vote start date
     * @return Vote snapshot block
     * @return Vote support required
     * @return Vote minimum acceptance quorum
     * @return Vote yeas amount
     * @return Vote nays amount
     * @return Vote power
     * @return Vote script
     */
    function getVote(uint256 _voteId)
        public
        view
        voteExists(_voteId)
        returns (
            bool open,
            bool executed,
            uint64 startDate,
            uint64 snapshotBlock,
            uint64 supportRequired,
            uint64 minAcceptQuorum,
            uint256 yea,
            uint256 nay,
            uint256 votingPower,
            bytes script
        )
    {
        Vote storage vote_ = votes[_voteId];

        open = _isVoteOpen(vote_);
        executed = vote_.executed;
        startDate = vote_.startDate;
        snapshotBlock = vote_.snapshotBlock;
        supportRequired = vote_.supportRequiredPct;
        minAcceptQuorum = vote_.minAcceptQuorumPct;
        yea = vote_.yea;
        nay = vote_.nay;
        votingPower = vote_.votingPower;
        script = vote_.executionScript;
    }

    /**
     * @dev Return the state of a voter for a given vote by its ID
     * @param _voteId Vote identifier
     * @return VoterState of the requested voter for a certain vote
     */
    function getVoterState(uint256 _voteId, address _voter)
        public
        view
        voteExists(_voteId)
        returns (VoterState)
    {
        return votes[_voteId].voters[_voter];
    }

    // Internal fns

    /**
     * @dev Internal function to create a new vote
     * @return voteId id for newly created vote
     */
    function _newVote(
        bytes _executionScript,
        string _metadata,
        bool _castVote,
        bool _executesIfDecided
    ) internal returns (uint256 voteId) {
        uint64 snapshotBlock = getBlockNumber64() - 1; // avoid double voting in this very block
        uint256 votingPower = token.getPastTotalSupply(snapshotBlock);
        require(votingPower > 0, ERROR_NO_VOTING_POWER);

        voteId = votesLength++;

        Vote storage vote_ = votes[voteId];
        vote_.startDate = getTimestamp64();
        vote_.snapshotBlock = snapshotBlock;
        vote_.supportRequiredPct = supportRequiredPct;
        vote_.minAcceptQuorumPct = minAcceptQuorumPct;
        vote_.votingPower = votingPower;
        vote_.executionScript = _executionScript;

        emit StartVote(voteId, msg.sender, _metadata);

        if (_castVote && _canVote(voteId, msg.sender)) {
            _vote(voteId, true, msg.sender, _executesIfDecided);
        }
    }

    /**
     * @dev Internal function to cast a vote. It assumes the queried vote exists.
     */
    function _vote(
        uint256 _voteId,
        bool _supports,
        address _voter,
        bool _executesIfDecided
    ) internal {
        Vote storage vote_ = votes[_voteId];

        // This could re-enter, though we can assume the governance token is not malicious
        uint256 voterStake = token.getPastVotes(_voter, vote_.snapshotBlock);
        VoterState state = vote_.voters[_voter];

        // If voter had previously voted, decrease count
        if (state == VoterState.Yea) {
            vote_.yea = vote_.yea.sub(voterStake);
        } else if (state == VoterState.Nay) {
            vote_.nay = vote_.nay.sub(voterStake);
        }

        if (_supports) {
            vote_.yea = vote_.yea.add(voterStake);
        } else {
            vote_.nay = vote_.nay.add(voterStake);
        }

        vote_.voters[_voter] = _supports ? VoterState.Yea : VoterState.Nay;

        emit CastVote(_voteId, _voter, _supports, voterStake);

        if (_executesIfDecided && _canExecute(_voteId)) {
            // We've already checked if the vote can be executed with `_canExecute()`
            _unsafeExecuteVote(_voteId);
        }
    }

    /**
     * @dev Internal function to execute a vote. It assumes the queried vote exists.
     */
    function _executeVote(uint256 _voteId) internal {
        require(_canExecute(_voteId), ERROR_CAN_NOT_EXECUTE);
        _unsafeExecuteVote(_voteId);
    }

    /**
     * @dev Unsafe version of _executeVote that assumes you have already checked if the vote can be executed and exists
     */
    function _unsafeExecuteVote(uint256 _voteId) internal {
        Vote storage vote_ = votes[_voteId];

        vote_.executed = true;

        bytes memory input = new bytes(0); // TODO: Consider input for voting scripts
        runScript(vote_.executionScript, input, new address[](0));

        emit ExecuteVote(_voteId);
    }

    /**
     * @dev Internal function to check if a vote can be executed. It assumes the queried vote exists.
     * @return True if the given vote can be executed, false otherwise
     */
    function _canExecute(uint256 _voteId) internal view returns (bool) {
        Vote storage vote_ = votes[_voteId];

        if (vote_.executed) {
            return false;
        }

        // Voting is already decided
        if (
            _isValuePct(vote_.yea, vote_.votingPower, vote_.supportRequiredPct)
        ) {
            return true;
        }

        // Vote ended?
        if (_isVoteOpen(vote_)) {
            return false;
        }
        // Has enough support?
        uint256 totalVotes = vote_.yea.add(vote_.nay);
        if (!_isValuePct(vote_.yea, totalVotes, vote_.supportRequiredPct)) {
            return false;
        }
        // Has min quorum?
        if (
            !_isValuePct(vote_.yea, vote_.votingPower, vote_.minAcceptQuorumPct)
        ) {
            return false;
        }

        return true;
    }

    /**
     * @dev Internal function to check if a voter can participate on a vote. It assumes the queried vote exists.
     * @return True if the given voter can participate a certain vote, false otherwise
     */
    function _canVote(uint256 _voteId, address _voter)
        internal
        view
        returns (bool)
    {
        Vote storage vote_ = votes[_voteId];
        return
            _isVoteOpen(vote_) &&
            token.getPastVotes(_voter, vote_.snapshotBlock) > 0;
    }

    /**
     * @dev Internal function to check if a vote is still open
     * @return True if the given vote is open, false otherwise
     */
    function _isVoteOpen(Vote storage vote_) internal view returns (bool) {
        return
            getTimestamp64() < vote_.startDate.add(voteTime) && !vote_.executed;
    }

    /**
     * @dev Calculates whether `_value` is more than a percentage `_pct` of `_total`
     */
    function _isValuePct(
        uint256 _value,
        uint256 _total,
        uint256 _pct
    ) internal pure returns (bool) {
        if (_total == 0) {
            return false;
        }

        uint256 computedPct = _value.mul(PCT_BASE) / _total;
        return computedPct > _pct;
    }
}

/*
 * SPDX-License-Identitifer:    GPL-3.0-or-later
 */
pragma solidity 0.4.24;

import '@aragon/os/contracts/apps/AragonApp.sol';
import '@aragon/os/contracts/common/IForwarder.sol';
import '@aragon/os/contracts/lib/math/SafeMath.sol';

interface IVotes {
    /**
     * @dev Returns the current amount of votes that `account` has.
     */
    function getVotes(address account) external view returns (uint256);

    /**
     * @dev Returns the amount of votes that `account` had at the end of a past block (`blockNumber`).
     */
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);

    /**
     * @dev Returns the total supply of votes available at the end of a past block (`blockNumber`).
     *
     * NOTE: This value is the sum of all available votes, which is not necessarily the sum of all delegated votes.
     * Votes that have not been delegated are still part of total supply, even though they would not participate in a
     * vote.
     */
    function getPastTotalSupply(uint256 blockNumber) external view returns (uint256);
}

contract VotesForwarder is IForwarder, AragonApp {
    using SafeMath for uint256;

    bytes32 public constant FANTOM_ROLE = keccak256('FANTOM_ROLE');

    string private constant ERROR_CALLER_NOT_TOKEN = 'VF_CALLER_NOT_TOKEN';
    string private constant ERROR_CAN_NOT_FORWARD = 'VF_CAN_NOT_FORWARD';

    IVotes public token;

    modifier onlyToken() {
        require(msg.sender == address(token), ERROR_CALLER_NOT_TOKEN);
        _;
    }

    /**
     * @notice Initialize VotesForwarder for `_token.symbol(): string`
     * @param _token IVotes address for the managed token
     */
    function initialize(IVotes _token) external onlyInit {
        initialized();
        token = _token;
    }

    function isForwarder() external pure returns (bool) {
        return true;
    }

    /**
     * @notice Execute desired action as a token holder
     * @dev IForwarder interface conformance. Forwards any token holder action.
     * @param _evmScript Script being executed
     */
    function forward(bytes _evmScript) public {
        require(canForward(msg.sender, _evmScript), ERROR_CAN_NOT_FORWARD);
        bytes memory input = new bytes(0); // TODO: Consider input for this

        // Add the managed token to the blacklist to disallow a token holder from executing actions
        // on the token controller's (this contract) behalf
        address[] memory blacklist = new address[](1);
        blacklist[0] = address(token);

        runScript(_evmScript, input, blacklist);
    }

    function canForward(address _sender, bytes) public view returns (bool) {
        return hasInitialized() && token.getVotes(_sender) > 0;
    }
}

/*
 * SPDX-License-Identitifer:    GPL-3.0-or-later
 */

/* solium-disable function-order */

pragma solidity 0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/common/IForwarder.sol";

import "@aragon/os/contracts/lib/math/SafeMath.sol";

import "@aragon/apps-shared-minime/contracts/ITokenController.sol";
import "@aragon/apps-shared-minime/contracts/MiniMeToken.sol";


contract TokenManager is ITokenController, IForwarder, AragonApp {
    using SafeMath for uint256;

    bytes32 public constant MINT_ROLE = keccak256("MINT_ROLE");
    bytes32 public constant ISSUE_ROLE = keccak256("ISSUE_ROLE");
    bytes32 public constant ASSIGN_ROLE = keccak256("ASSIGN_ROLE");
    bytes32 public constant REVOKE_VESTINGS_ROLE = keccak256("REVOKE_VESTINGS_ROLE");
    bytes32 public constant BURN_ROLE = keccak256("BURN_ROLE");

    uint256 public constant MAX_VESTINGS_PER_ADDRESS = 50;

    string private constant ERROR_CALLER_NOT_TOKEN = "TM_CALLER_NOT_TOKEN";
    string private constant ERROR_NO_VESTING = "TM_NO_VESTING";
    string private constant ERROR_TOKEN_CONTROLLER = "TM_TOKEN_CONTROLLER";
    string private constant ERROR_MINT_RECEIVER_IS_TM = "TM_MINT_RECEIVER_IS_TM";
    string private constant ERROR_VESTING_TO_TM = "TM_VESTING_TO_TM";
    string private constant ERROR_TOO_MANY_VESTINGS = "TM_TOO_MANY_VESTINGS";
    string private constant ERROR_WRONG_CLIFF_DATE = "TM_WRONG_CLIFF_DATE";
    string private constant ERROR_VESTING_NOT_REVOKABLE = "TM_VESTING_NOT_REVOKABLE";
    string private constant ERROR_REVOKE_TRANSFER_FROM_REVERTED = "TM_REVOKE_TRANSFER_FROM_REVERTED";
    string private constant ERROR_CAN_NOT_FORWARD = "TM_CAN_NOT_FORWARD";
    string private constant ERROR_BALANCE_INCREASE_NOT_ALLOWED = "TM_BALANCE_INC_NOT_ALLOWED";
    string private constant ERROR_ASSIGN_TRANSFER_FROM_REVERTED = "TM_ASSIGN_TRANSFER_FROM_REVERTED";

    struct TokenVesting {
        uint256 amount;
        uint64 start;
        uint64 cliff;
        uint64 vesting;
        bool revokable;
    }

    // Note that we COMPLETELY trust this MiniMeToken to not be malicious for proper operation of this contract
    MiniMeToken public token;
    uint256 public maxAccountTokens;

    // We are mimicing an array in the inner mapping, we use a mapping instead to make app upgrade more graceful
    mapping (address => mapping (uint256 => TokenVesting)) internal vestings;
    mapping (address => uint256) public vestingsLengths;

    // Other token specific events can be watched on the token address directly (avoids duplication)
    event NewVesting(address indexed receiver, uint256 vestingId, uint256 amount);
    event RevokeVesting(address indexed receiver, uint256 vestingId, uint256 nonVestedAmount);

    modifier onlyToken() {
        require(msg.sender == address(token), ERROR_CALLER_NOT_TOKEN);
        _;
    }

    modifier vestingExists(address _holder, uint256 _vestingId) {
        // TODO: it's not checking for gaps that may appear because of deletes in revokeVesting function
        require(_vestingId < vestingsLengths[_holder], ERROR_NO_VESTING);
        _;
    }

    /**
    * @notice Initialize Token Manager for `_token.symbol(): string`, whose tokens are `transferable ? 'not' : ''` transferable`_maxAccountTokens > 0 ? ' and limited to a maximum of ' + @tokenAmount(_token, _maxAccountTokens, false) + ' per account' : ''`
    * @param _token MiniMeToken address for the managed token (Token Manager instance must be already set as the token controller)
    * @param _transferable whether the token can be transferred by holders
    * @param _maxAccountTokens Maximum amount of tokens an account can have (0 for infinite tokens)
    */
    function initialize(
        MiniMeToken _token,
        bool _transferable,
        uint256 _maxAccountTokens
    )
        external
        onlyInit
    {
        initialized();

        require(_token.controller() == address(this), ERROR_TOKEN_CONTROLLER);

        token = _token;
        maxAccountTokens = _maxAccountTokens == 0 ? uint256(-1) : _maxAccountTokens;

        if (token.transfersEnabled() != _transferable) {
            token.enableTransfers(_transferable);
        }
    }

    /**
    * @notice Mint `@tokenAmount(self.token(): address, _amount, false)` tokens for `_receiver`
    * @param _receiver The address receiving the tokens, cannot be the Token Manager itself (use `issue()` instead)
    * @param _amount Number of tokens minted
    */
    function mint(address _receiver, uint256 _amount) external authP(MINT_ROLE, arr(_receiver, _amount)) {
        require(_receiver != address(this), ERROR_MINT_RECEIVER_IS_TM);
        _mint(_receiver, _amount);
    }

    /**
    * @notice Mint `@tokenAmount(self.token(): address, _amount, false)` tokens for the Token Manager
    * @param _amount Number of tokens minted
    */
    function issue(uint256 _amount) external authP(ISSUE_ROLE, arr(_amount)) {
        _mint(address(this), _amount);
    }

    /**
    * @notice Assign `@tokenAmount(self.token(): address, _amount, false)` tokens to `_receiver` from the Token Manager's holdings
    * @param _receiver The address receiving the tokens
    * @param _amount Number of tokens transferred
    */
    function assign(address _receiver, uint256 _amount) external authP(ASSIGN_ROLE, arr(_receiver, _amount)) {
        _assign(_receiver, _amount);
    }

    /**
    * @notice Burn `@tokenAmount(self.token(): address, _amount, false)` tokens from `_holder`
    * @param _holder Holder of tokens being burned
    * @param _amount Number of tokens being burned
    */
    function burn(address _holder, uint256 _amount) external authP(BURN_ROLE, arr(_holder, _amount)) {
        // minime.destroyTokens() never returns false, only reverts on failure
        token.destroyTokens(_holder, _amount);
    }

    /**
    * @notice Assign `@tokenAmount(self.token(): address, _amount, false)` tokens to `_receiver` from the Token Manager's holdings with a `_revokable : 'revokable' : ''` vesting starting at `@formatDate(_start)`, cliff at `@formatDate(_cliff)` (first portion of tokens transferable), and completed vesting at `@formatDate(_vested)` (all tokens transferable)
    * @param _receiver The address receiving the tokens, cannot be Token Manager itself
    * @param _amount Number of tokens vested
    * @param _start Date the vesting calculations start
    * @param _cliff Date when the initial portion of tokens are transferable
    * @param _vested Date when all tokens are transferable
    * @param _revokable Whether the vesting can be revoked by the Token Manager
    */
    function assignVested(
        address _receiver,
        uint256 _amount,
        uint64 _start,
        uint64 _cliff,
        uint64 _vested,
        bool _revokable
    )
        external
        authP(ASSIGN_ROLE, arr(_receiver, _amount))
        returns (uint256)
    {
        require(_receiver != address(this), ERROR_VESTING_TO_TM);
        require(vestingsLengths[_receiver] < MAX_VESTINGS_PER_ADDRESS, ERROR_TOO_MANY_VESTINGS);
        require(_start <= _cliff && _cliff <= _vested, ERROR_WRONG_CLIFF_DATE);

        uint256 vestingId = vestingsLengths[_receiver]++;
        vestings[_receiver][vestingId] = TokenVesting(
            _amount,
            _start,
            _cliff,
            _vested,
            _revokable
        );

        _assign(_receiver, _amount);

        emit NewVesting(_receiver, vestingId, _amount);

        return vestingId;
    }

    /**
    * @notice Revoke vesting #`_vestingId` from `_holder`, returning unvested tokens to the Token Manager
    * @param _holder Address whose vesting to revoke
    * @param _vestingId Numeric id of the vesting
    */
    function revokeVesting(address _holder, uint256 _vestingId)
        external
        authP(REVOKE_VESTINGS_ROLE, arr(_holder))
        vestingExists(_holder, _vestingId)
    {
        TokenVesting storage v = vestings[_holder][_vestingId];
        require(v.revokable, ERROR_VESTING_NOT_REVOKABLE);

        uint256 nonVested = _calculateNonVestedTokens(
            v.amount,
            getTimestamp(),
            v.start,
            v.cliff,
            v.vesting
        );

        // To make vestingIds immutable over time, we just zero out the revoked vesting
        // Clearing this out also allows the token transfer back to the Token Manager to succeed
        delete vestings[_holder][_vestingId];

        // transferFrom always works as controller
        // onTransfer hook always allows if transfering to token controller
        require(token.transferFrom(_holder, address(this), nonVested), ERROR_REVOKE_TRANSFER_FROM_REVERTED);

        emit RevokeVesting(_holder, _vestingId, nonVested);
    }

    // ITokenController fns
    // `onTransfer()`, `onApprove()`, and `proxyPayment()` are callbacks from the MiniMe token
    // contract and are only meant to be called through the managed MiniMe token that gets assigned
    // during initialization.

    /*
    * @dev Notifies the controller about a token transfer allowing the controller to decide whether
    *      to allow it or react if desired (only callable from the token).
    *      Initialization check is implicitly provided by `onlyToken()`.
    * @param _from The origin of the transfer
    * @param _to The destination of the transfer
    * @param _amount The amount of the transfer
    * @return False if the controller does not authorize the transfer
    */
    function onTransfer(address _from, address _to, uint256 _amount) external onlyToken returns (bool) {
        return _isBalanceIncreaseAllowed(_to, _amount) && _transferableBalance(_from, getTimestamp()) >= _amount;
    }

    /**
    * @dev Notifies the controller about an approval allowing the controller to react if desired
    *      Initialization check is implicitly provided by `onlyToken()`.
    * @return False if the controller does not authorize the approval
    */
    function onApprove(address, address, uint) external onlyToken returns (bool) {
        return true;
    }

    /**
    * @dev Called when ether is sent to the MiniMe Token contract
    *      Initialization check is implicitly provided by `onlyToken()`.
    * @return True if the ether is accepted, false for it to throw
    */
    function proxyPayment(address) external payable onlyToken returns (bool) {
        return false;
    }

    // Forwarding fns

    function isForwarder() external pure returns (bool) {
        return true;
    }

    /**
    * @notice Execute desired action as a token holder
    * @dev IForwarder interface conformance. Forwards any token holder action.
    * @param _evmScript Script being executed
    */
    function forward(bytes _evmScript) public {
        require(canForward(msg.sender, _evmScript), ERROR_CAN_NOT_FORWARD);
        bytes memory input = new bytes(0); // TODO: Consider input for this

        // Add the managed token to the blacklist to disallow a token holder from executing actions
        // on the token controller's (this contract) behalf
        address[] memory blacklist = new address[](1);
        blacklist[0] = address(token);

        runScript(_evmScript, input, blacklist);
    }

    function canForward(address _sender, bytes) public view returns (bool) {
        return hasInitialized() && token.balanceOf(_sender) > 0;
    }

    // Getter fns

    function getVesting(
        address _recipient,
        uint256 _vestingId
    )
        public
        view
        vestingExists(_recipient, _vestingId)
        returns (
            uint256 amount,
            uint64 start,
            uint64 cliff,
            uint64 vesting,
            bool revokable
        )
    {
        TokenVesting storage tokenVesting = vestings[_recipient][_vestingId];
        amount = tokenVesting.amount;
        start = tokenVesting.start;
        cliff = tokenVesting.cliff;
        vesting = tokenVesting.vesting;
        revokable = tokenVesting.revokable;
    }

    function spendableBalanceOf(address _holder) public view isInitialized returns (uint256) {
        return _transferableBalance(_holder, getTimestamp());
    }

    function transferableBalance(address _holder, uint256 _time) public view isInitialized returns (uint256) {
        return _transferableBalance(_holder, _time);
    }

    /**
    * @dev Disable recovery escape hatch for own token,
    *      as the it has the concept of issuing tokens without assigning them
    */
    function allowRecoverability(address _token) public view returns (bool) {
        return _token != address(token);
    }

    // Internal fns

    function _assign(address _receiver, uint256 _amount) internal {
        require(_isBalanceIncreaseAllowed(_receiver, _amount), ERROR_BALANCE_INCREASE_NOT_ALLOWED);
        // Must use transferFrom() as transfer() does not give the token controller full control
        require(token.transferFrom(address(this), _receiver, _amount), ERROR_ASSIGN_TRANSFER_FROM_REVERTED);
    }

    function _mint(address _receiver, uint256 _amount) internal {
        require(_isBalanceIncreaseAllowed(_receiver, _amount), ERROR_BALANCE_INCREASE_NOT_ALLOWED);
        token.generateTokens(_receiver, _amount); // minime.generateTokens() never returns false
    }

    function _isBalanceIncreaseAllowed(address _receiver, uint256 _inc) internal view returns (bool) {
        // Max balance doesn't apply to the token manager itself
        if (_receiver == address(this)) {
            return true;
        }
        return token.balanceOf(_receiver).add(_inc) <= maxAccountTokens;
    }

    /**
    * @dev Calculate amount of non-vested tokens at a specifc time
    * @param tokens The total amount of tokens vested
    * @param time The time at which to check
    * @param start The date vesting started
    * @param cliff The cliff period
    * @param vested The fully vested date
    * @return The amount of non-vested tokens of a specific grant
    *  transferableTokens
    *   |                         _/--------   vestedTokens rect
    *   |                       _/
    *   |                     _/
    *   |                   _/
    *   |                 _/
    *   |                /
    *   |              .|
    *   |            .  |
    *   |          .    |
    *   |        .      |
    *   |      .        |
    *   |    .          |
    *   +===+===========+---------+----------> time
    *      Start       Cliff    Vested
    */
    function _calculateNonVestedTokens(
        uint256 tokens,
        uint256 time,
        uint256 start,
        uint256 cliff,
        uint256 vested
    )
        private
        pure
        returns (uint256)
    {
        // Shortcuts for before cliff and after vested cases.
        if (time >= vested) {
            return 0;
        }
        if (time < cliff) {
            return tokens;
        }

        // Interpolate all vested tokens.
        // As before cliff the shortcut returns 0, we can just calculate a value
        // in the vesting rect (as shown in above's figure)

        // vestedTokens = tokens * (time - start) / (vested - start)
        // In assignVesting we enforce start <= cliff <= vested
        // Here we shortcut time >= vested and time < cliff,
        // so no division by 0 is possible
        uint256 vestedTokens = tokens.mul(time.sub(start)) / vested.sub(start);

        // tokens - vestedTokens
        return tokens.sub(vestedTokens);
    }

    function _transferableBalance(address _holder, uint256 _time) internal view returns (uint256) {
        uint256 transferable = token.balanceOf(_holder);

        // This check is not strictly necessary for the current version of this contract, as
        // Token Managers now cannot assign vestings to themselves.
        // However, this was a possibility in the past, so in case there were vestings assigned to
        // themselves, this will still return the correct value (entire balance, as the Token
        // Manager does not have a spending limit on its own balance).
        if (_holder != address(this)) {
            uint256 vestingsCount = vestingsLengths[_holder];
            for (uint256 i = 0; i < vestingsCount; i++) {
                TokenVesting storage v = vestings[_holder][i];
                uint256 nonTransferable = _calculateNonVestedTokens(
                    v.amount,
                    _time,
                    v.start,
                    v.cliff,
                    v.vesting
                );
                transferable = transferable.sub(nonTransferable);
            }
        }

        return transferable;
    }
}

/*
 * SPDX-License-Identitifer:    GPL-3.0-or-later
 */

pragma solidity 0.4.24;

import "./SignatureValidator.sol";
import "./standards/IERC165.sol";
import "./standards/ERC1271.sol";
import "./standards/IERC721Receiver.sol";

import "@aragon/apps-vault/contracts/Vault.sol";

import "@aragon/os/contracts/common/IForwarder.sol";


contract Agent is IERC165, IERC721Receiver, ERC1271Bytes, IForwarder, IsContract, Vault {
    /* Hardcoded constants to save gas
    bytes32 public constant EXECUTE_ROLE = keccak256("EXECUTE_ROLE");
    bytes32 public constant SAFE_EXECUTE_ROLE = keccak256("SAFE_EXECUTE_ROLE");
    bytes32 public constant ADD_PROTECTED_TOKEN_ROLE = keccak256("ADD_PROTECTED_TOKEN_ROLE");
    bytes32 public constant REMOVE_PROTECTED_TOKEN_ROLE = keccak256("REMOVE_PROTECTED_TOKEN_ROLE");
    bytes32 public constant ADD_PRESIGNED_HASH_ROLE = keccak256("ADD_PRESIGNED_HASH_ROLE");
    bytes32 public constant DESIGNATE_SIGNER_ROLE = keccak256("DESIGNATE_SIGNER_ROLE");
    bytes32 public constant RUN_SCRIPT_ROLE = keccak256("RUN_SCRIPT_ROLE");
    */

    bytes32 public constant EXECUTE_ROLE = 0xcebf517aa4440d1d125e0355aae64401211d0848a23c02cc5d29a14822580ba4;
    bytes32 public constant SAFE_EXECUTE_ROLE = 0x0a1ad7b87f5846153c6d5a1f761d71c7d0cfd122384f56066cd33239b7933694;
    bytes32 public constant ADD_PROTECTED_TOKEN_ROLE = 0x6eb2a499556bfa2872f5aa15812b956cc4a71b4d64eb3553f7073c7e41415aaa;
    bytes32 public constant REMOVE_PROTECTED_TOKEN_ROLE = 0x71eee93d500f6f065e38b27d242a756466a00a52a1dbcd6b4260f01a8640402a;
    bytes32 public constant ADD_PRESIGNED_HASH_ROLE = 0x0b29780bb523a130b3b01f231ef49ed2fa2781645591a0b0a44ca98f15a5994c;
    bytes32 public constant DESIGNATE_SIGNER_ROLE = 0x23ce341656c3f14df6692eebd4757791e33662b7dcf9970c8308303da5472b7c;
    bytes32 public constant RUN_SCRIPT_ROLE = 0xb421f7ad7646747f3051c50c0b8e2377839296cd4973e27f63821d73e390338f;

    uint256 public constant PROTECTED_TOKENS_CAP = 10;

    bytes4 private constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 private constant ERC721_RECEIVED_INTERFACE_ID = 0x150b7a02; // bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))

    string private constant ERROR_TARGET_PROTECTED = "AGENT_TARGET_PROTECTED";
    string private constant ERROR_PROTECTED_TOKENS_MODIFIED = "AGENT_PROTECTED_TOKENS_MODIFIED";
    string private constant ERROR_PROTECTED_BALANCE_LOWERED = "AGENT_PROTECTED_BALANCE_LOWERED";
    string private constant ERROR_TOKENS_CAP_REACHED = "AGENT_TOKENS_CAP_REACHED";
    string private constant ERROR_TOKEN_NOT_ERC20 = "AGENT_TOKEN_NOT_ERC20";
    string private constant ERROR_TOKEN_ALREADY_PROTECTED = "AGENT_TOKEN_ALREADY_PROTECTED";
    string private constant ERROR_TOKEN_NOT_PROTECTED = "AGENT_TOKEN_NOT_PROTECTED";
    string private constant ERROR_DESIGNATED_TO_SELF = "AGENT_DESIGNATED_TO_SELF";
    string private constant ERROR_CAN_NOT_FORWARD = "AGENT_CAN_NOT_FORWARD";

    mapping (bytes32 => bool) public isPresigned;
    address public designatedSigner;
    address[] public protectedTokens;

    event SafeExecute(address indexed sender, address indexed target, bytes data);
    event Execute(address indexed sender, address indexed target, uint256 ethValue, bytes data);
    event AddProtectedToken(address indexed token);
    event RemoveProtectedToken(address indexed token);
    event PresignHash(address indexed sender, bytes32 indexed hash);
    event SetDesignatedSigner(address indexed sender, address indexed oldSigner, address indexed newSigner);
    event ReceiveERC721(address indexed token, address indexed operator, address indexed from, uint256 tokenId, bytes data);

    /**
    * @notice Execute '`@radspec(_target, _data)`' on `_target``_ethValue == 0 ? '' : ' (Sending ' + @tokenAmount(0x0000000000000000000000000000000000000000, _ethValue) + ')'`
    * @param _target Address where the action is being executed
    * @param _ethValue Amount of ETH from the contract that is sent with the action
    * @param _data Calldata for the action
    * @return Exits call frame forwarding the return data of the executed call (either error or success data)
    */
    function execute(address _target, uint256 _ethValue, bytes _data)
        external // This function MUST always be external as the function performs a low level return, exiting the Agent app execution context
        authP(EXECUTE_ROLE, arr(_target, _ethValue, uint256(_getSig(_data)))) // bytes4 casted as uint256 sets the bytes as the LSBs
    {
        bool result = _target.call.value(_ethValue)(_data);

        if (result) {
            emit Execute(msg.sender, _target, _ethValue, _data);
        }

        assembly {
            let ptr := mload(0x40)
            returndatacopy(ptr, 0, returndatasize)

            // revert instead of invalid() bc if the underlying call failed with invalid() it already wasted gas.
            // if the call returned error data, forward it
            switch result case 0 { revert(ptr, returndatasize) }
            default { return(ptr, returndatasize) }
        }
    }

    /**
    * @notice Execute '`@radspec(_target, _data)`' on `_target`, ensuring that protected tokens can't be spent
    * @param _target Address where the action is being executed
    * @param _data Calldata for the action
    * @return Exits call frame forwarding the return data of the executed call (either error or success data)
    */
    function safeExecute(address _target, bytes _data)
        external // This function MUST always be external as the function performs a low level return, exiting the Agent app execution context
        authP(SAFE_EXECUTE_ROLE, arr(_target, uint256(_getSig(_data)))) // bytes4 casted as uint256 sets the bytes as the LSBs
    {
        uint256 protectedTokensLength = protectedTokens.length;
        address[] memory protectedTokens_ = new address[](protectedTokensLength);
        uint256[] memory balances = new uint256[](protectedTokensLength);

        for (uint256 i = 0; i < protectedTokensLength; i++) {
            address token = protectedTokens[i];
            require(_target != token, ERROR_TARGET_PROTECTED);
            // we copy the protected tokens array to check whether the storage array has been modified during the underlying call
            protectedTokens_[i] = token;
            // we copy the balances to check whether they have been modified during the underlying call
            balances[i] = balance(token);
        }

        bool result = _target.call(_data);

        bytes32 ptr;
        uint256 size;
        assembly {
            size := returndatasize
            ptr := mload(0x40)
            mstore(0x40, add(ptr, returndatasize))
            returndatacopy(ptr, 0, returndatasize)
        }

        if (result) {
            // if the underlying call has succeeded, we check that the protected tokens
            // and their balances have not been modified and return the call's return data
            require(protectedTokens.length == protectedTokensLength, ERROR_PROTECTED_TOKENS_MODIFIED);
            for (uint256 j = 0; j < protectedTokensLength; j++) {
                require(protectedTokens[j] == protectedTokens_[j], ERROR_PROTECTED_TOKENS_MODIFIED);
                require(balance(protectedTokens[j]) >= balances[j], ERROR_PROTECTED_BALANCE_LOWERED);
            }

            emit SafeExecute(msg.sender, _target, _data);

            assembly {
                return(ptr, size)
            }
        } else {
            // if the underlying call has failed, we revert and forward returned error data
            assembly {
                revert(ptr, size)
            }
        }
    }

    /**
    * @notice Add `_token.symbol(): string` to the list of protected tokens
    * @param _token Address of the token to be protected
    */
    function addProtectedToken(address _token) external authP(ADD_PROTECTED_TOKEN_ROLE, arr(_token)) {
        require(protectedTokens.length < PROTECTED_TOKENS_CAP, ERROR_TOKENS_CAP_REACHED);
        require(_isERC20(_token), ERROR_TOKEN_NOT_ERC20);
        require(!_tokenIsProtected(_token), ERROR_TOKEN_ALREADY_PROTECTED);

        _addProtectedToken(_token);
    }

    /**
    * @notice Remove `_token.symbol(): string` from the list of protected tokens
    * @param _token Address of the token to be unprotected
    */
    function removeProtectedToken(address _token) external authP(REMOVE_PROTECTED_TOKEN_ROLE, arr(_token)) {
        require(_tokenIsProtected(_token), ERROR_TOKEN_NOT_PROTECTED);

        _removeProtectedToken(_token);
    }

    /**
    * @notice Pre-sign hash `_hash`
    * @param _hash Hash that will be considered signed regardless of the signature checked with 'isValidSignature()'
    */
    function presignHash(bytes32 _hash)
        external
        authP(ADD_PRESIGNED_HASH_ROLE, arr(_hash))
    {
        isPresigned[_hash] = true;

        emit PresignHash(msg.sender, _hash);
    }

    /**
    * @notice Set `_designatedSigner` as the designated signer of the app, which will be able to sign messages on behalf of the app
    * @param _designatedSigner Address that will be able to sign messages on behalf of the app
    */
    function setDesignatedSigner(address _designatedSigner)
        external
        authP(DESIGNATE_SIGNER_ROLE, arr(_designatedSigner))
    {
        // Prevent an infinite loop by setting the app itself as its designated signer.
        // An undetectable loop can be created by setting a different contract as the
        // designated signer which calls back into `isValidSignature`.
        // Given that `isValidSignature` is always called with just 50k gas, the max
        // damage of the loop is wasting 50k gas.
        require(_designatedSigner != address(this), ERROR_DESIGNATED_TO_SELF);

        address oldDesignatedSigner = designatedSigner;
        designatedSigner = _designatedSigner;

        emit SetDesignatedSigner(msg.sender, oldDesignatedSigner, _designatedSigner);
    }

    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes _data) external returns (bytes4) {
        emit ReceiveERC721(msg.sender, _operator, _from, _tokenId, _data);

        return ERC721_RECEIVED_INTERFACE_ID;
    }

    // Forwarding fns

    /**
    * @notice Tells whether the Agent app is a forwarder or not
    * @dev IForwarder interface conformance
    * @return Always true
    */
    function isForwarder() external pure returns (bool) {
        return true;
    }

    /**
     * @notice Tells whether this contract supports a given ERC-165 interface
     * @dev Implements conformance to ERC-165
     * @param _interfaceId Interface bytes to check
     * @return True if this contract supports the interface
     */
    function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
        return
            _interfaceId == ERC1271_INTERFACE_ID ||
            _interfaceId == ERC721_RECEIVED_INTERFACE_ID ||
            _interfaceId == ERC165_INTERFACE_ID;
    }

    /**
    * @notice Execute the script as the Agent app
    * @dev IForwarder interface conformance. Forwards any token holder action.
    * @param _evmScript Script being executed
    */
    function forward(bytes _evmScript) public {
        require(canForward(msg.sender, _evmScript), ERROR_CAN_NOT_FORWARD);

        bytes memory input = ""; // no input
        address[] memory blacklist = new address[](0); // no addr blacklist, can interact with anything
        runScript(_evmScript, input, blacklist);
        // We don't need to emit an event here as EVMScriptRunner will emit ScriptResult if successful
    }

    /**
    * @notice Tells whether `_sender` can forward actions or not
    * @dev IForwarder interface conformance
    * @param _sender Address of the account intending to forward an action
    * @return True if the given address can run scripts, false otherwise
    */
    function canForward(address _sender, bytes _evmScript) public view returns (bool) {
        // Note that `canPerform()` implicitly does an initialization check itself
        return canPerform(_sender, RUN_SCRIPT_ROLE, arr(_getScriptACLParam(_evmScript)));
    }

    // ERC-1271 conformance

    /**
     * @notice Tells whether a signature is seen as valid by this contract through ERC-1271
     * @param _hash Arbitrary length data signed on the behalf of address (this)
     * @param _signature Signature byte array associated with _data
     * @return The ERC-1271 magic value if the signature is valid
     */
    function isValidSignature(bytes32 _hash, bytes _signature) public view returns (bytes4) {
        // Short-circuit in case the hash was presigned. Optimization as performing calls
        // and ecrecover is more expensive than an SLOAD.
        if (isPresigned[_hash]) {
            return returnIsValidSignatureMagicNumber(true);
        }

        bool isValid;
        if (designatedSigner == address(0)) {
            isValid = false;
        } else {
            isValid = SignatureValidator.isValidSignature(_hash, designatedSigner, _signature);
        }

        return returnIsValidSignatureMagicNumber(isValid);
    }

    // Getters

    function getProtectedTokensLength() public view isInitialized returns (uint256) {
        return protectedTokens.length;
    }

    // Internal fns

    function _addProtectedToken(address _token) internal {
        protectedTokens.push(_token);

        emit AddProtectedToken(_token);
    }

    function _removeProtectedToken(address _token) internal {
        protectedTokens[_protectedTokenIndex(_token)] = protectedTokens[protectedTokens.length - 1];
        protectedTokens.length--;

        emit RemoveProtectedToken(_token);
    }

    function _isERC20(address _token) internal view returns (bool) {
        if (!isContract(_token)) {
            return false;
        }

        // Throwaway sanity check to make sure the token's `balanceOf()` does not error (for now)
        balance(_token);

        return true;
    }

    function _protectedTokenIndex(address _token) internal view returns (uint256) {
        for (uint i = 0; i < protectedTokens.length; i++) {
            if (protectedTokens[i] == _token) {
              return i;
            }
        }

        revert(ERROR_TOKEN_NOT_PROTECTED);
    }

    function _tokenIsProtected(address _token) internal view returns (bool) {
        for (uint256 i = 0; i < protectedTokens.length; i++) {
            if (protectedTokens[i] == _token) {
                return true;
            }
        }

        return false;
    }

    function _getScriptACLParam(bytes _evmScript) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_evmScript)));
    }

    function _getSig(bytes _data) internal pure returns (bytes4 sig) {
        if (_data.length < 4) {
            return;
        }

        assembly { sig := mload(add(_data, 0x20)) }
    }
}

pragma solidity 0.4.24;

import "./ens/IPublicResolver.sol";


interface IFIFSResolvingRegistrar {
    function register(bytes32 _subnode, address _owner) external;
    function registerWithResolver(bytes32 _subnode, address _owner, IPublicResolver _resolver) public;
}

pragma solidity 0.4.24;

import "../apps/AragonApp.sol";
import "../common/ConversionHelpers.sol";
import "../common/TimeHelpers.sol";
import "./ACLSyntaxSugar.sol";
import "./IACL.sol";
import "./IACLOracle.sol";


/* solium-disable function-order */
// Allow public initialize() to be first
contract ACL is IACL, TimeHelpers, AragonApp, ACLHelpers {
    /* Hardcoded constants to save gas
    bytes32 public constant CREATE_PERMISSIONS_ROLE = keccak256("CREATE_PERMISSIONS_ROLE");
    */
    bytes32 public constant CREATE_PERMISSIONS_ROLE = 0x0b719b33c83b8e5d300c521cb8b54ae9bd933996a14bef8c2f4e0285d2d2400a;

    enum Op { NONE, EQ, NEQ, GT, LT, GTE, LTE, RET, NOT, AND, OR, XOR, IF_ELSE } // op types

    struct Param {
        uint8 id;
        uint8 op;
        uint240 value; // even though value is an uint240 it can store addresses
        // in the case of 32 byte hashes losing 2 bytes precision isn't a huge deal
        // op and id take less than 1 byte each so it can be kept in 1 sstore
    }

    uint8 internal constant BLOCK_NUMBER_PARAM_ID = 200;
    uint8 internal constant TIMESTAMP_PARAM_ID    = 201;
    // 202 is unused
    uint8 internal constant ORACLE_PARAM_ID       = 203;
    uint8 internal constant LOGIC_OP_PARAM_ID     = 204;
    uint8 internal constant PARAM_VALUE_PARAM_ID  = 205;
    // TODO: Add execution times param type?

    /* Hardcoded constant to save gas
    bytes32 public constant EMPTY_PARAM_HASH = keccak256(uint256(0));
    */
    bytes32 public constant EMPTY_PARAM_HASH = 0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563;
    bytes32 public constant NO_PERMISSION = bytes32(0);
    address public constant ANY_ENTITY = address(-1);
    address public constant BURN_ENTITY = address(1); // address(0) is already used as "no permission manager"

    string private constant ERROR_AUTH_INIT_KERNEL = "ACL_AUTH_INIT_KERNEL";
    string private constant ERROR_AUTH_NO_MANAGER = "ACL_AUTH_NO_MANAGER";
    string private constant ERROR_EXISTENT_MANAGER = "ACL_EXISTENT_MANAGER";

    // Whether someone has a permission
    mapping (bytes32 => bytes32) internal permissions; // permissions hash => params hash
    mapping (bytes32 => Param[]) internal permissionParams; // params hash => params

    // Who is the manager of a permission
    mapping (bytes32 => address) internal permissionManager;

    event SetPermission(address indexed entity, address indexed app, bytes32 indexed role, bool allowed);
    event SetPermissionParams(address indexed entity, address indexed app, bytes32 indexed role, bytes32 paramsHash);
    event ChangePermissionManager(address indexed app, bytes32 indexed role, address indexed manager);

    modifier onlyPermissionManager(address _app, bytes32 _role) {
        require(msg.sender == getPermissionManager(_app, _role), ERROR_AUTH_NO_MANAGER);
        _;
    }

    modifier noPermissionManager(address _app, bytes32 _role) {
        // only allow permission creation (or re-creation) when there is no manager
        require(getPermissionManager(_app, _role) == address(0), ERROR_EXISTENT_MANAGER);
        _;
    }

    /**
    * @dev Initialize can only be called once. It saves the block number in which it was initialized.
    * @notice Initialize an ACL instance and set `_permissionsCreator` as the entity that can create other permissions
    * @param _permissionsCreator Entity that will be given permission over createPermission
    */
    function initialize(address _permissionsCreator) public onlyInit {
        initialized();
        require(msg.sender == address(kernel()), ERROR_AUTH_INIT_KERNEL);

        _createPermission(_permissionsCreator, this, CREATE_PERMISSIONS_ROLE, _permissionsCreator);
    }

    /**
    * @dev Creates a permission that wasn't previously set and managed.
    *      If a created permission is removed it is possible to reset it with createPermission.
    *      This is the **ONLY** way to create permissions and set managers to permissions that don't
    *      have a manager.
    *      In terms of the ACL being initialized, this function implicitly protects all the other
    *      state-changing external functions, as they all require the sender to be a manager.
    * @notice Create a new permission granting `_entity` the ability to perform actions requiring `_role` on `_app`, setting `_manager` as the permission's manager
    * @param _entity Address of the whitelisted entity that will be able to perform the role
    * @param _app Address of the app in which the role will be allowed (requires app to depend on kernel for ACL)
    * @param _role Identifier for the group of actions in app given access to perform
    * @param _manager Address of the entity that will be able to grant and revoke the permission further.
    */
    function createPermission(address _entity, address _app, bytes32 _role, address _manager)
        external
        auth(CREATE_PERMISSIONS_ROLE)
        noPermissionManager(_app, _role)
    {
        _createPermission(_entity, _app, _role, _manager);
    }

    /**
    * @dev Grants permission if allowed. This requires `msg.sender` to be the permission manager
    * @notice Grant `_entity` the ability to perform actions requiring `_role` on `_app`
    * @param _entity Address of the whitelisted entity that will be able to perform the role
    * @param _app Address of the app in which the role will be allowed (requires app to depend on kernel for ACL)
    * @param _role Identifier for the group of actions in app given access to perform
    */
    function grantPermission(address _entity, address _app, bytes32 _role)
        external
    {
        grantPermissionP(_entity, _app, _role, new uint256[](0));
    }

    /**
    * @dev Grants a permission with parameters if allowed. This requires `msg.sender` to be the permission manager
    * @notice Grant `_entity` the ability to perform actions requiring `_role` on `_app`
    * @param _entity Address of the whitelisted entity that will be able to perform the role
    * @param _app Address of the app in which the role will be allowed (requires app to depend on kernel for ACL)
    * @param _role Identifier for the group of actions in app given access to perform
    * @param _params Permission parameters
    */
    function grantPermissionP(address _entity, address _app, bytes32 _role, uint256[] _params)
        public
        onlyPermissionManager(_app, _role)
    {
        bytes32 paramsHash = _params.length > 0 ? _saveParams(_params) : EMPTY_PARAM_HASH;
        _setPermission(_entity, _app, _role, paramsHash);
    }

    /**
    * @dev Revokes permission if allowed. This requires `msg.sender` to be the the permission manager
    * @notice Revoke from `_entity` the ability to perform actions requiring `_role` on `_app`
    * @param _entity Address of the whitelisted entity to revoke access from
    * @param _app Address of the app in which the role will be revoked
    * @param _role Identifier for the group of actions in app being revoked
    */
    function revokePermission(address _entity, address _app, bytes32 _role)
        external
        onlyPermissionManager(_app, _role)
    {
        _setPermission(_entity, _app, _role, NO_PERMISSION);
    }

    /**
    * @notice Set `_newManager` as the manager of `_role` in `_app`
    * @param _newManager Address for the new manager
    * @param _app Address of the app in which the permission management is being transferred
    * @param _role Identifier for the group of actions being transferred
    */
    function setPermissionManager(address _newManager, address _app, bytes32 _role)
        external
        onlyPermissionManager(_app, _role)
    {
        _setPermissionManager(_newManager, _app, _role);
    }

    /**
    * @notice Remove the manager of `_role` in `_app`
    * @param _app Address of the app in which the permission is being unmanaged
    * @param _role Identifier for the group of actions being unmanaged
    */
    function removePermissionManager(address _app, bytes32 _role)
        external
        onlyPermissionManager(_app, _role)
    {
        _setPermissionManager(address(0), _app, _role);
    }

    /**
    * @notice Burn non-existent `_role` in `_app`, so no modification can be made to it (grant, revoke, permission manager)
    * @param _app Address of the app in which the permission is being burned
    * @param _role Identifier for the group of actions being burned
    */
    function createBurnedPermission(address _app, bytes32 _role)
        external
        auth(CREATE_PERMISSIONS_ROLE)
        noPermissionManager(_app, _role)
    {
        _setPermissionManager(BURN_ENTITY, _app, _role);
    }

    /**
    * @notice Burn `_role` in `_app`, so no modification can be made to it (grant, revoke, permission manager)
    * @param _app Address of the app in which the permission is being burned
    * @param _role Identifier for the group of actions being burned
    */
    function burnPermissionManager(address _app, bytes32 _role)
        external
        onlyPermissionManager(_app, _role)
    {
        _setPermissionManager(BURN_ENTITY, _app, _role);
    }

    /**
     * @notice Get parameters for permission array length
     * @param _entity Address of the whitelisted entity that will be able to perform the role
     * @param _app Address of the app
     * @param _role Identifier for a group of actions in app
     * @return Length of the array
     */
    function getPermissionParamsLength(address _entity, address _app, bytes32 _role) external view returns (uint) {
        return permissionParams[permissions[permissionHash(_entity, _app, _role)]].length;
    }

    /**
    * @notice Get parameter for permission
    * @param _entity Address of the whitelisted entity that will be able to perform the role
    * @param _app Address of the app
    * @param _role Identifier for a group of actions in app
    * @param _index Index of parameter in the array
    * @return Parameter (id, op, value)
    */
    function getPermissionParam(address _entity, address _app, bytes32 _role, uint _index)
        external
        view
        returns (uint8, uint8, uint240)
    {
        Param storage param = permissionParams[permissions[permissionHash(_entity, _app, _role)]][_index];
        return (param.id, param.op, param.value);
    }

    /**
    * @dev Get manager for permission
    * @param _app Address of the app
    * @param _role Identifier for a group of actions in app
    * @return address of the manager for the permission
    */
    function getPermissionManager(address _app, bytes32 _role) public view returns (address) {
        return permissionManager[roleHash(_app, _role)];
    }

    /**
    * @dev Function called by apps to check ACL on kernel or to check permission statu
    * @param _who Sender of the original call
    * @param _where Address of the app
    * @param _where Identifier for a group of actions in app
    * @param _how Permission parameters
    * @return boolean indicating whether the ACL allows the role or not
    */
    function hasPermission(address _who, address _where, bytes32 _what, bytes memory _how) public view returns (bool) {
        return hasPermission(_who, _where, _what, ConversionHelpers.dangerouslyCastBytesToUintArray(_how));
    }

    function hasPermission(address _who, address _where, bytes32 _what, uint256[] memory _how) public view returns (bool) {
        bytes32 whoParams = permissions[permissionHash(_who, _where, _what)];
        if (whoParams != NO_PERMISSION && evalParams(whoParams, _who, _where, _what, _how)) {
            return true;
        }

        bytes32 anyParams = permissions[permissionHash(ANY_ENTITY, _where, _what)];
        if (anyParams != NO_PERMISSION && evalParams(anyParams, ANY_ENTITY, _where, _what, _how)) {
            return true;
        }

        return false;
    }

    function hasPermission(address _who, address _where, bytes32 _what) public view returns (bool) {
        uint256[] memory empty = new uint256[](0);
        return hasPermission(_who, _where, _what, empty);
    }

    function evalParams(
        bytes32 _paramsHash,
        address _who,
        address _where,
        bytes32 _what,
        uint256[] _how
    ) public view returns (bool)
    {
        if (_paramsHash == EMPTY_PARAM_HASH) {
            return true;
        }

        return _evalParam(_paramsHash, 0, _who, _where, _what, _how);
    }

    /**
    * @dev Internal createPermission for access inside the kernel (on instantiation)
    */
    function _createPermission(address _entity, address _app, bytes32 _role, address _manager) internal {
        _setPermission(_entity, _app, _role, EMPTY_PARAM_HASH);
        _setPermissionManager(_manager, _app, _role);
    }

    /**
    * @dev Internal function called to actually save the permission
    */
    function _setPermission(address _entity, address _app, bytes32 _role, bytes32 _paramsHash) internal {
        permissions[permissionHash(_entity, _app, _role)] = _paramsHash;
        bool entityHasPermission = _paramsHash != NO_PERMISSION;
        bool permissionHasParams = entityHasPermission && _paramsHash != EMPTY_PARAM_HASH;

        emit SetPermission(_entity, _app, _role, entityHasPermission);
        if (permissionHasParams) {
            emit SetPermissionParams(_entity, _app, _role, _paramsHash);
        }
    }

    function _saveParams(uint256[] _encodedParams) internal returns (bytes32) {
        bytes32 paramHash = keccak256(abi.encodePacked(_encodedParams));
        Param[] storage params = permissionParams[paramHash];

        if (params.length == 0) { // params not saved before
            for (uint256 i = 0; i < _encodedParams.length; i++) {
                uint256 encodedParam = _encodedParams[i];
                Param memory param = Param(decodeParamId(encodedParam), decodeParamOp(encodedParam), uint240(encodedParam));
                params.push(param);
            }
        }

        return paramHash;
    }

    function _evalParam(
        bytes32 _paramsHash,
        uint32 _paramId,
        address _who,
        address _where,
        bytes32 _what,
        uint256[] _how
    ) internal view returns (bool)
    {
        if (_paramId >= permissionParams[_paramsHash].length) {
            return false; // out of bounds
        }

        Param memory param = permissionParams[_paramsHash][_paramId];

        if (param.id == LOGIC_OP_PARAM_ID) {
            return _evalLogic(param, _paramsHash, _who, _where, _what, _how);
        }

        uint256 value;
        uint256 comparedTo = uint256(param.value);

        // get value
        if (param.id == ORACLE_PARAM_ID) {
            value = checkOracle(IACLOracle(param.value), _who, _where, _what, _how) ? 1 : 0;
            comparedTo = 1;
        } else if (param.id == BLOCK_NUMBER_PARAM_ID) {
            value = getBlockNumber();
        } else if (param.id == TIMESTAMP_PARAM_ID) {
            value = getTimestamp();
        } else if (param.id == PARAM_VALUE_PARAM_ID) {
            value = uint256(param.value);
        } else {
            if (param.id >= _how.length) {
                return false;
            }
            value = uint256(uint240(_how[param.id])); // force lost precision
        }

        if (Op(param.op) == Op.RET) {
            return uint256(value) > 0;
        }

        return compare(value, Op(param.op), comparedTo);
    }

    function _evalLogic(Param _param, bytes32 _paramsHash, address _who, address _where, bytes32 _what, uint256[] _how)
        internal
        view
        returns (bool)
    {
        if (Op(_param.op) == Op.IF_ELSE) {
            uint32 conditionParam;
            uint32 successParam;
            uint32 failureParam;

            (conditionParam, successParam, failureParam) = decodeParamsList(uint256(_param.value));
            bool result = _evalParam(_paramsHash, conditionParam, _who, _where, _what, _how);

            return _evalParam(_paramsHash, result ? successParam : failureParam, _who, _where, _what, _how);
        }

        uint32 param1;
        uint32 param2;

        (param1, param2,) = decodeParamsList(uint256(_param.value));
        bool r1 = _evalParam(_paramsHash, param1, _who, _where, _what, _how);

        if (Op(_param.op) == Op.NOT) {
            return !r1;
        }

        if (r1 && Op(_param.op) == Op.OR) {
            return true;
        }

        if (!r1 && Op(_param.op) == Op.AND) {
            return false;
        }

        bool r2 = _evalParam(_paramsHash, param2, _who, _where, _what, _how);

        if (Op(_param.op) == Op.XOR) {
            return r1 != r2;
        }

        return r2; // both or and and depend on result of r2 after checks
    }

    function compare(uint256 _a, Op _op, uint256 _b) internal pure returns (bool) {
        if (_op == Op.EQ)  return _a == _b;                              // solium-disable-line lbrace
        if (_op == Op.NEQ) return _a != _b;                              // solium-disable-line lbrace
        if (_op == Op.GT)  return _a > _b;                               // solium-disable-line lbrace
        if (_op == Op.LT)  return _a < _b;                               // solium-disable-line lbrace
        if (_op == Op.GTE) return _a >= _b;                              // solium-disable-line lbrace
        if (_op == Op.LTE) return _a <= _b;                              // solium-disable-line lbrace
        return false;
    }

    function checkOracle(IACLOracle _oracleAddr, address _who, address _where, bytes32 _what, uint256[] _how) internal view returns (bool) {
        bytes4 sig = _oracleAddr.canPerform.selector;

        // a raw call is required so we can return false if the call reverts, rather than reverting
        bytes memory checkCalldata = abi.encodeWithSelector(sig, _who, _where, _what, _how);

        bool ok;
        assembly {
            // send all available gas; if the oracle eats up all the gas, we will eventually revert
            // note that we are currently guaranteed to still have some gas after the call from
            // EIP-150's 63/64 gas forward rule
            ok := staticcall(gas, _oracleAddr, add(checkCalldata, 0x20), mload(checkCalldata), 0, 0)
        }

        if (!ok) {
            return false;
        }

        uint256 size;
        assembly { size := returndatasize }
        if (size != 32) {
            return false;
        }

        bool result;
        assembly {
            let ptr := mload(0x40)       // get next free memory ptr
            returndatacopy(ptr, 0, size) // copy return from above `staticcall`
            result := mload(ptr)         // read data at ptr and set it to result
            mstore(ptr, 0)               // set pointer memory to 0 so it still is the next free ptr
        }

        return result;
    }

    /**
    * @dev Internal function that sets management
    */
    function _setPermissionManager(address _newManager, address _app, bytes32 _role) internal {
        permissionManager[roleHash(_app, _role)] = _newManager;
        emit ChangePermissionManager(_app, _role, _newManager);
    }

    function roleHash(address _where, bytes32 _what) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROLE", _where, _what));
    }

    function permissionHash(address _who, address _where, bytes32 _what) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("PERMISSION", _who, _where, _what));
    }
}

pragma solidity 0.4.24;

import "../apps/AragonApp.sol";


/* solium-disable function-order */
// Allow public initialize() to be first
contract Repo is AragonApp {
    /* Hardcoded constants to save gas
    bytes32 public constant CREATE_VERSION_ROLE = keccak256("CREATE_VERSION_ROLE");
    */
    bytes32 public constant CREATE_VERSION_ROLE = 0x1f56cfecd3595a2e6cc1a7e6cb0b20df84cdbd92eff2fee554e70e4e45a9a7d8;

    string private constant ERROR_INVALID_BUMP = "REPO_INVALID_BUMP";
    string private constant ERROR_INVALID_VERSION = "REPO_INVALID_VERSION";
    string private constant ERROR_INEXISTENT_VERSION = "REPO_INEXISTENT_VERSION";

    struct Version {
        uint16[3] semanticVersion;
        address contractAddress;
        bytes contentURI;
    }

    uint256 internal versionsNextIndex;
    mapping (uint256 => Version) internal versions;
    mapping (bytes32 => uint256) internal versionIdForSemantic;
    mapping (address => uint256) internal latestVersionIdForContract;

    event NewVersion(uint256 versionId, uint16[3] semanticVersion);

    /**
    * @dev Initialize can only be called once. It saves the block number in which it was initialized.
    * @notice Initialize this Repo
    */
    function initialize() public onlyInit {
        initialized();
        versionsNextIndex = 1;
    }

    /**
    * @notice Create new version with contract `_contractAddress` and content `@fromHex(_contentURI)`
    * @param _newSemanticVersion Semantic version for new repo version
    * @param _contractAddress address for smart contract logic for version (if set to 0, it uses last versions' contractAddress)
    * @param _contentURI External URI for fetching new version's content
    */
    function newVersion(
        uint16[3] _newSemanticVersion,
        address _contractAddress,
        bytes _contentURI
    ) public auth(CREATE_VERSION_ROLE)
    {
        address contractAddress = _contractAddress;
        uint256 lastVersionIndex = versionsNextIndex - 1;

        uint16[3] memory lastSematicVersion;

        if (lastVersionIndex > 0) {
            Version storage lastVersion = versions[lastVersionIndex];
            lastSematicVersion = lastVersion.semanticVersion;

            if (contractAddress == address(0)) {
                contractAddress = lastVersion.contractAddress;
            }
            // Only allows smart contract change on major version bumps
            require(
                lastVersion.contractAddress == contractAddress || _newSemanticVersion[0] > lastVersion.semanticVersion[0],
                ERROR_INVALID_VERSION
            );
        }

        require(isValidBump(lastSematicVersion, _newSemanticVersion), ERROR_INVALID_BUMP);

        uint256 versionId = versionsNextIndex++;
        versions[versionId] = Version(_newSemanticVersion, contractAddress, _contentURI);
        versionIdForSemantic[semanticVersionHash(_newSemanticVersion)] = versionId;
        latestVersionIdForContract[contractAddress] = versionId;

        emit NewVersion(versionId, _newSemanticVersion);
    }

    function getLatest() public view returns (uint16[3] semanticVersion, address contractAddress, bytes contentURI) {
        return getByVersionId(versionsNextIndex - 1);
    }

    function getLatestForContractAddress(address _contractAddress)
        public
        view
        returns (uint16[3] semanticVersion, address contractAddress, bytes contentURI)
    {
        return getByVersionId(latestVersionIdForContract[_contractAddress]);
    }

    function getBySemanticVersion(uint16[3] _semanticVersion)
        public
        view
        returns (uint16[3] semanticVersion, address contractAddress, bytes contentURI)
    {
        return getByVersionId(versionIdForSemantic[semanticVersionHash(_semanticVersion)]);
    }

    function getByVersionId(uint _versionId) public view returns (uint16[3] semanticVersion, address contractAddress, bytes contentURI) {
        require(_versionId > 0 && _versionId < versionsNextIndex, ERROR_INEXISTENT_VERSION);
        Version storage version = versions[_versionId];
        return (version.semanticVersion, version.contractAddress, version.contentURI);
    }

    function getVersionsCount() public view returns (uint256) {
        return versionsNextIndex - 1;
    }

    function isValidBump(uint16[3] _oldVersion, uint16[3] _newVersion) public pure returns (bool) {
        bool hasBumped;
        uint i = 0;
        while (i < 3) {
            if (hasBumped) {
                if (_newVersion[i] != 0) {
                    return false;
                }
            } else if (_newVersion[i] != _oldVersion[i]) {
                if (_oldVersion[i] > _newVersion[i] || _newVersion[i] - _oldVersion[i] != 1) {
                    return false;
                }
                hasBumped = true;
            }
            i++;
        }
        return hasBumped;
    }

    function semanticVersionHash(uint16[3] version) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(version[0], version[1], version[2]));
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


contract APMNamehash {
    /* Hardcoded constants to save gas
    bytes32 internal constant APM_NODE = keccak256(abi.encodePacked(ETH_TLD_NODE, keccak256(abi.encodePacked("aragonpm"))));
    */
    bytes32 internal constant APM_NODE = 0x9065c3e7f7b7ef1ef4e53d2d0b8e0cef02874ab020c1ece79d5f0d3d0111c0ba;

    function apmNamehash(string name) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(APM_NODE, keccak256(bytes(name))));
    }
}

pragma solidity 0.4.24;

import "./IKernel.sol";
import "./KernelConstants.sol";
import "./KernelStorage.sol";
import "../acl/IACL.sol";
import "../acl/ACLSyntaxSugar.sol";
import "../common/ConversionHelpers.sol";
import "../common/IsContract.sol";
import "../common/Petrifiable.sol";
import "../common/VaultRecoverable.sol";
import "../factory/AppProxyFactory.sol";
import "../lib/misc/ERCProxy.sol";


// solium-disable-next-line max-len
contract Kernel is IKernel, KernelStorage, KernelAppIds, KernelNamespaceConstants, Petrifiable, IsContract, VaultRecoverable, AppProxyFactory, ACLSyntaxSugar {
    /* Hardcoded constants to save gas
    bytes32 public constant APP_MANAGER_ROLE = keccak256("APP_MANAGER_ROLE");
    */
    bytes32 public constant APP_MANAGER_ROLE = 0xb6d92708f3d4817afc106147d969e229ced5c46e65e0a5002a0d391287762bd0;

    string private constant ERROR_APP_NOT_CONTRACT = "KERNEL_APP_NOT_CONTRACT";
    string private constant ERROR_INVALID_APP_CHANGE = "KERNEL_INVALID_APP_CHANGE";
    string private constant ERROR_AUTH_FAILED = "KERNEL_AUTH_FAILED";

    /**
    * @dev Constructor that allows the deployer to choose if the base instance should be petrified immediately.
    * @param _shouldPetrify Immediately petrify this instance so that it can never be initialized
    */
    constructor(bool _shouldPetrify) public {
        if (_shouldPetrify) {
            petrify();
        }
    }

    /**
    * @dev Initialize can only be called once. It saves the block number in which it was initialized.
    * @notice Initialize this kernel instance along with its ACL and set `_permissionsCreator` as the entity that can create other permissions
    * @param _baseAcl Address of base ACL app
    * @param _permissionsCreator Entity that will be given permission over createPermission
    */
    function initialize(IACL _baseAcl, address _permissionsCreator) public onlyInit {
        initialized();

        // Set ACL base
        _setApp(KERNEL_APP_BASES_NAMESPACE, KERNEL_DEFAULT_ACL_APP_ID, _baseAcl);

        // Create ACL instance and attach it as the default ACL app
        IACL acl = IACL(newAppProxy(this, KERNEL_DEFAULT_ACL_APP_ID));
        acl.initialize(_permissionsCreator);
        _setApp(KERNEL_APP_ADDR_NAMESPACE, KERNEL_DEFAULT_ACL_APP_ID, acl);

        recoveryVaultAppId = KERNEL_DEFAULT_VAULT_APP_ID;
    }

    /**
    * @dev Create a new instance of an app linked to this kernel
    * @notice Create a new upgradeable instance of `_appId` app linked to the Kernel, setting its code to `_appBase`
    * @param _appId Identifier for app
    * @param _appBase Address of the app's base implementation
    * @return AppProxy instance
    */
    function newAppInstance(bytes32 _appId, address _appBase)
        public
        auth(APP_MANAGER_ROLE, arr(KERNEL_APP_BASES_NAMESPACE, _appId))
        returns (ERCProxy appProxy)
    {
        return newAppInstance(_appId, _appBase, new bytes(0), false);
    }

    /**
    * @dev Create a new instance of an app linked to this kernel and set its base
    *      implementation if it was not already set
    * @notice Create a new upgradeable instance of `_appId` app linked to the Kernel, setting its code to `_appBase`. `_setDefault ? 'Also sets it as the default app instance.':''`
    * @param _appId Identifier for app
    * @param _appBase Address of the app's base implementation
    * @param _initializePayload Payload for call made by the proxy during its construction to initialize
    * @param _setDefault Whether the app proxy app is the default one.
    *        Useful when the Kernel needs to know of an instance of a particular app,
    *        like Vault for escape hatch mechanism.
    * @return AppProxy instance
    */
    function newAppInstance(bytes32 _appId, address _appBase, bytes _initializePayload, bool _setDefault)
        public
        auth(APP_MANAGER_ROLE, arr(KERNEL_APP_BASES_NAMESPACE, _appId))
        returns (ERCProxy appProxy)
    {
        _setAppIfNew(KERNEL_APP_BASES_NAMESPACE, _appId, _appBase);
        appProxy = newAppProxy(this, _appId, _initializePayload);
        // By calling setApp directly and not the internal functions, we make sure the params are checked
        // and it will only succeed if sender has permissions to set something to the namespace.
        if (_setDefault) {
            setApp(KERNEL_APP_ADDR_NAMESPACE, _appId, appProxy);
        }
    }

    /**
    * @dev Create a new pinned instance of an app linked to this kernel
    * @notice Create a new non-upgradeable instance of `_appId` app linked to the Kernel, setting its code to `_appBase`.
    * @param _appId Identifier for app
    * @param _appBase Address of the app's base implementation
    * @return AppProxy instance
    */
    function newPinnedAppInstance(bytes32 _appId, address _appBase)
        public
        auth(APP_MANAGER_ROLE, arr(KERNEL_APP_BASES_NAMESPACE, _appId))
        returns (ERCProxy appProxy)
    {
        return newPinnedAppInstance(_appId, _appBase, new bytes(0), false);
    }

    /**
    * @dev Create a new pinned instance of an app linked to this kernel and set
    *      its base implementation if it was not already set
    * @notice Create a new non-upgradeable instance of `_appId` app linked to the Kernel, setting its code to `_appBase`. `_setDefault ? 'Also sets it as the default app instance.':''`
    * @param _appId Identifier for app
    * @param _appBase Address of the app's base implementation
    * @param _initializePayload Payload for call made by the proxy during its construction to initialize
    * @param _setDefault Whether the app proxy app is the default one.
    *        Useful when the Kernel needs to know of an instance of a particular app,
    *        like Vault for escape hatch mechanism.
    * @return AppProxy instance
    */
    function newPinnedAppInstance(bytes32 _appId, address _appBase, bytes _initializePayload, bool _setDefault)
        public
        auth(APP_MANAGER_ROLE, arr(KERNEL_APP_BASES_NAMESPACE, _appId))
        returns (ERCProxy appProxy)
    {
        _setAppIfNew(KERNEL_APP_BASES_NAMESPACE, _appId, _appBase);
        appProxy = newAppProxyPinned(this, _appId, _initializePayload);
        // By calling setApp directly and not the internal functions, we make sure the params are checked
        // and it will only succeed if sender has permissions to set something to the namespace.
        if (_setDefault) {
            setApp(KERNEL_APP_ADDR_NAMESPACE, _appId, appProxy);
        }
    }

    /**
    * @dev Set the resolving address of an app instance or base implementation
    * @notice Set the resolving address of `_appId` in namespace `_namespace` to `_app`
    * @param _namespace App namespace to use
    * @param _appId Identifier for app
    * @param _app Address of the app instance or base implementation
    * @return ID of app
    */
    function setApp(bytes32 _namespace, bytes32 _appId, address _app)
        public
        auth(APP_MANAGER_ROLE, arr(_namespace, _appId))
    {
        _setApp(_namespace, _appId, _app);
    }

    /**
    * @dev Set the default vault id for the escape hatch mechanism
    * @param _recoveryVaultAppId Identifier of the recovery vault app
    */
    function setRecoveryVaultAppId(bytes32 _recoveryVaultAppId)
        public
        auth(APP_MANAGER_ROLE, arr(KERNEL_APP_ADDR_NAMESPACE, _recoveryVaultAppId))
    {
        recoveryVaultAppId = _recoveryVaultAppId;
    }

    // External access to default app id and namespace constants to mimic default getters for constants
    /* solium-disable function-order, mixedcase */
    function CORE_NAMESPACE() external pure returns (bytes32) { return KERNEL_CORE_NAMESPACE; }
    function APP_BASES_NAMESPACE() external pure returns (bytes32) { return KERNEL_APP_BASES_NAMESPACE; }
    function APP_ADDR_NAMESPACE() external pure returns (bytes32) { return KERNEL_APP_ADDR_NAMESPACE; }
    function KERNEL_APP_ID() external pure returns (bytes32) { return KERNEL_CORE_APP_ID; }
    function DEFAULT_ACL_APP_ID() external pure returns (bytes32) { return KERNEL_DEFAULT_ACL_APP_ID; }
    /* solium-enable function-order, mixedcase */

    /**
    * @dev Get the address of an app instance or base implementation
    * @param _namespace App namespace to use
    * @param _appId Identifier for app
    * @return Address of the app
    */
    function getApp(bytes32 _namespace, bytes32 _appId) public view returns (address) {
        return apps[_namespace][_appId];
    }

    /**
    * @dev Get the address of the recovery Vault instance (to recover funds)
    * @return Address of the Vault
    */
    function getRecoveryVault() public view returns (address) {
        return apps[KERNEL_APP_ADDR_NAMESPACE][recoveryVaultAppId];
    }

    /**
    * @dev Get the installed ACL app
    * @return ACL app
    */
    function acl() public view returns (IACL) {
        return IACL(getApp(KERNEL_APP_ADDR_NAMESPACE, KERNEL_DEFAULT_ACL_APP_ID));
    }

    /**
    * @dev Function called by apps to check ACL on kernel or to check permission status
    * @param _who Sender of the original call
    * @param _where Address of the app
    * @param _what Identifier for a group of actions in app
    * @param _how Extra data for ACL auth
    * @return Boolean indicating whether the ACL allows the role or not.
    *         Always returns false if the kernel hasn't been initialized yet.
    */
    function hasPermission(address _who, address _where, bytes32 _what, bytes _how) public view returns (bool) {
        IACL defaultAcl = acl();
        return address(defaultAcl) != address(0) && // Poor man's initialization check (saves gas)
            defaultAcl.hasPermission(_who, _where, _what, _how);
    }

    function _setApp(bytes32 _namespace, bytes32 _appId, address _app) internal {
        require(isContract(_app), ERROR_APP_NOT_CONTRACT);
        apps[_namespace][_appId] = _app;
        emit SetApp(_namespace, _appId, _app);
    }

    function _setAppIfNew(bytes32 _namespace, bytes32 _appId, address _app) internal {
        address app = getApp(_namespace, _appId);
        if (app != address(0)) {
            // The only way to set an app is if it passes the isContract check, so no need to check it again
            require(app == _app, ERROR_INVALID_APP_CHANGE);
        } else {
            _setApp(_namespace, _appId, _app);
        }
    }

    modifier auth(bytes32 _role, uint256[] memory _params) {
        require(
            hasPermission(msg.sender, address(this), _role, ConversionHelpers.dangerouslyCastUintArrayToBytes(_params)),
            ERROR_AUTH_FAILED
        );
        _;
    }
}

pragma solidity 0.4.24;

import "../kernel/IKernel.sol";
import "../kernel/Kernel.sol";
import "../kernel/KernelProxy.sol";

import "../acl/IACL.sol";
import "../acl/ACL.sol";

import "./EVMScriptRegistryFactory.sol";


contract DAOFactory {
    IKernel public baseKernel;
    IACL public baseACL;
    EVMScriptRegistryFactory public regFactory;

    event DeployDAO(address dao);
    event DeployEVMScriptRegistry(address reg);

    /**
    * @notice Create a new DAOFactory, creating DAOs with Kernels proxied to `_baseKernel`, ACLs proxied to `_baseACL`, and new EVMScriptRegistries created from `_regFactory`.
    * @param _baseKernel Base Kernel
    * @param _baseACL Base ACL
    * @param _regFactory EVMScriptRegistry factory
    */
    constructor(IKernel _baseKernel, IACL _baseACL, EVMScriptRegistryFactory _regFactory) public {
        // No need to init as it cannot be killed by devops199
        if (address(_regFactory) != address(0)) {
            regFactory = _regFactory;
        }

        baseKernel = _baseKernel;
        baseACL = _baseACL;
    }

    /**
    * @notice Create a new DAO with `_root` set as the initial admin
    * @param _root Address that will be granted control to setup DAO permissions
    * @return Newly created DAO
    */
    function newDAO(address _root) public returns (Kernel) {
        Kernel dao = Kernel(new KernelProxy(baseKernel));

        if (address(regFactory) == address(0)) {
            dao.initialize(baseACL, _root);
        } else {
            dao.initialize(baseACL, this);

            ACL acl = ACL(dao.acl());
            bytes32 permRole = acl.CREATE_PERMISSIONS_ROLE();
            bytes32 appManagerRole = dao.APP_MANAGER_ROLE();

            acl.grantPermission(regFactory, acl, permRole);

            acl.createPermission(regFactory, dao, appManagerRole, this);

            EVMScriptRegistry reg = regFactory.newEVMScriptRegistry(dao);
            emit DeployEVMScriptRegistry(address(reg));

            // Clean up permissions
            // First, completely reset the APP_MANAGER_ROLE
            acl.revokePermission(regFactory, dao, appManagerRole);
            acl.removePermissionManager(dao, appManagerRole);

            // Then, make root the only holder and manager of CREATE_PERMISSIONS_ROLE
            acl.revokePermission(regFactory, acl, permRole);
            acl.revokePermission(this, acl, permRole);
            acl.grantPermission(_root, acl, permRole);
            acl.setPermissionManager(_root, acl, permRole);
        }

        emit DeployDAO(address(dao));

        return dao;
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

// See https://github.com/ensdomains/ens/blob/7e377df83f/contracts/PublicResolver.sol

pragma solidity ^0.4.0;

import "./AbstractENS.sol";

/**
 * A simple resolver anyone can use; only allows the owner of a node to set its
 * address.
 */
contract PublicResolver {
    bytes4 constant INTERFACE_META_ID = 0x01ffc9a7;
    bytes4 constant ADDR_INTERFACE_ID = 0x3b3b57de;
    bytes4 constant CONTENT_INTERFACE_ID = 0xd8389dc5;
    bytes4 constant NAME_INTERFACE_ID = 0x691f3431;
    bytes4 constant ABI_INTERFACE_ID = 0x2203ab56;
    bytes4 constant PUBKEY_INTERFACE_ID = 0xc8690233;
    bytes4 constant TEXT_INTERFACE_ID = 0x59d1d43c;

    event AddrChanged(bytes32 indexed node, address a);
    event ContentChanged(bytes32 indexed node, bytes32 hash);
    event NameChanged(bytes32 indexed node, string name);
    event ABIChanged(bytes32 indexed node, uint256 indexed contentType);
    event PubkeyChanged(bytes32 indexed node, bytes32 x, bytes32 y);
    event TextChanged(bytes32 indexed node, string indexed indexedKey, string key);

    struct PublicKey {
        bytes32 x;
        bytes32 y;
    }

    struct Record {
        address addr;
        bytes32 content;
        string name;
        PublicKey pubkey;
        mapping(string=>string) text;
        mapping(uint256=>bytes) abis;
    }

    AbstractENS ens;
    mapping(bytes32=>Record) records;

    modifier only_owner(bytes32 node) {
        if (ens.owner(node) != msg.sender) throw;
        _;
    }

    /**
     * Constructor.
     * @param ensAddr The ENS registrar contract.
     */
    function PublicResolver(AbstractENS ensAddr) public {
        ens = ensAddr;
    }

    /**
     * Returns true if the resolver implements the interface specified by the provided hash.
     * @param interfaceID The ID of the interface to check for.
     * @return True if the contract implements the requested interface.
     */
    function supportsInterface(bytes4 interfaceID) public pure returns (bool) {
        return interfaceID == ADDR_INTERFACE_ID ||
               interfaceID == CONTENT_INTERFACE_ID ||
               interfaceID == NAME_INTERFACE_ID ||
               interfaceID == ABI_INTERFACE_ID ||
               interfaceID == PUBKEY_INTERFACE_ID ||
               interfaceID == TEXT_INTERFACE_ID ||
               interfaceID == INTERFACE_META_ID;
    }

    /**
     * Returns the address associated with an ENS node.
     * @param node The ENS node to query.
     * @return The associated address.
     */
    function addr(bytes32 node) public constant returns (address ret) {
        ret = records[node].addr;
    }

    /**
     * Sets the address associated with an ENS node.
     * May only be called by the owner of that node in the ENS registry.
     * @param node The node to update.
     * @param addr The address to set.
     */
    function setAddr(bytes32 node, address addr) only_owner(node) public {
        records[node].addr = addr;
        AddrChanged(node, addr);
    }

    /**
     * Returns the content hash associated with an ENS node.
     * Note that this resource type is not standardized, and will likely change
     * in future to a resource type based on multihash.
     * @param node The ENS node to query.
     * @return The associated content hash.
     */
    function content(bytes32 node) public constant returns (bytes32 ret) {
        ret = records[node].content;
    }

    /**
     * Sets the content hash associated with an ENS node.
     * May only be called by the owner of that node in the ENS registry.
     * Note that this resource type is not standardized, and will likely change
     * in future to a resource type based on multihash.
     * @param node The node to update.
     * @param hash The content hash to set
     */
    function setContent(bytes32 node, bytes32 hash) only_owner(node) public {
        records[node].content = hash;
        ContentChanged(node, hash);
    }

    /**
     * Returns the name associated with an ENS node, for reverse records.
     * Defined in EIP181.
     * @param node The ENS node to query.
     * @return The associated name.
     */
    function name(bytes32 node) public constant returns (string ret) {
        ret = records[node].name;
    }

    /**
     * Sets the name associated with an ENS node, for reverse records.
     * May only be called by the owner of that node in the ENS registry.
     * @param node The node to update.
     * @param name The name to set.
     */
    function setName(bytes32 node, string name) only_owner(node) public {
        records[node].name = name;
        NameChanged(node, name);
    }

    /**
     * Returns the ABI associated with an ENS node.
     * Defined in EIP205.
     * @param node The ENS node to query
     * @param contentTypes A bitwise OR of the ABI formats accepted by the caller.
     * @return contentType The content type of the return value
     * @return data The ABI data
     */
    function ABI(bytes32 node, uint256 contentTypes) public constant returns (uint256 contentType, bytes data) {
        var record = records[node];
        for(contentType = 1; contentType <= contentTypes; contentType <<= 1) {
            if ((contentType & contentTypes) != 0 && record.abis[contentType].length > 0) {
                data = record.abis[contentType];
                return;
            }
        }
        contentType = 0;
    }

    /**
     * Sets the ABI associated with an ENS node.
     * Nodes may have one ABI of each content type. To remove an ABI, set it to
     * the empty string.
     * @param node The node to update.
     * @param contentType The content type of the ABI
     * @param data The ABI data.
     */
    function setABI(bytes32 node, uint256 contentType, bytes data) only_owner(node) public {
        // Content types must be powers of 2
        if (((contentType - 1) & contentType) != 0) throw;

        records[node].abis[contentType] = data;
        ABIChanged(node, contentType);
    }

    /**
     * Returns the SECP256k1 public key associated with an ENS node.
     * Defined in EIP 619.
     * @param node The ENS node to query
     * @return x, y the X and Y coordinates of the curve point for the public key.
     */
    function pubkey(bytes32 node) public constant returns (bytes32 x, bytes32 y) {
        return (records[node].pubkey.x, records[node].pubkey.y);
    }

    /**
     * Sets the SECP256k1 public key associated with an ENS node.
     * @param node The ENS node to query
     * @param x the X coordinate of the curve point for the public key.
     * @param y the Y coordinate of the curve point for the public key.
     */
    function setPubkey(bytes32 node, bytes32 x, bytes32 y) only_owner(node) public {
        records[node].pubkey = PublicKey(x, y);
        PubkeyChanged(node, x, y);
    }

    /**
     * Returns the text data associated with an ENS node and key.
     * @param node The ENS node to query.
     * @param key The text data key to query.
     * @return The associated text data.
     */
    function text(bytes32 node, string key) public constant returns (string ret) {
        ret = records[node].text[key];
    }

    /**
     * Sets the text data associated with an ENS node and key.
     * May only be called by the owner of that node in the ENS registry.
     * @param node The node to update.
     * @param key The key to set.
     * @param value The text data value to set.
     */
    function setText(bytes32 node, string key, string value) only_owner(node) public {
        records[node].text[key] = value;
        TextChanged(node, key, key);
    }
}

// See https://github.com/ensdomains/ens/blob/7e377df83f/contracts/ENS.sol

pragma solidity ^0.4.0;


import "./AbstractENS.sol";

/**
 * The ENS registry contract.
 */
contract ENS is AbstractENS {
    struct Record {
        address owner;
        address resolver;
        uint64 ttl;
    }

    mapping(bytes32=>Record) records;

    // Permits modifications only by the owner of the specified node.
    modifier only_owner(bytes32 node) {
        if (records[node].owner != msg.sender) throw;
        _;
    }

    /**
     * Constructs a new ENS registrar.
     */
    function ENS() public {
        records[0].owner = msg.sender;
    }

    /**
     * Returns the address that owns the specified node.
     */
    function owner(bytes32 node) public constant returns (address) {
        return records[node].owner;
    }

    /**
     * Returns the address of the resolver for the specified node.
     */
    function resolver(bytes32 node) public constant returns (address) {
        return records[node].resolver;
    }

    /**
     * Returns the TTL of a node, and any records associated with it.
     */
    function ttl(bytes32 node) public constant returns (uint64) {
        return records[node].ttl;
    }

    /**
     * Transfers ownership of a node to a new address. May only be called by the current
     * owner of the node.
     * @param node The node to transfer ownership of.
     * @param owner The address of the new owner.
     */
    function setOwner(bytes32 node, address owner) only_owner(node) public {
        Transfer(node, owner);
        records[node].owner = owner;
    }

    /**
     * Transfers ownership of a subnode keccak256(node, label) to a new address. May only be
     * called by the owner of the parent node.
     * @param node The parent node.
     * @param label The hash of the label specifying the subnode.
     * @param owner The address of the new owner.
     */
    function setSubnodeOwner(bytes32 node, bytes32 label, address owner) only_owner(node) public {
        var subnode = keccak256(node, label);
        NewOwner(node, label, owner);
        records[subnode].owner = owner;
    }

    /**
     * Sets the resolver address for the specified node.
     * @param node The node to update.
     * @param resolver The address of the resolver.
     */
    function setResolver(bytes32 node, address resolver) only_owner(node) public {
        NewResolver(node, resolver);
        records[node].resolver = resolver;
    }

    /**
     * Sets the TTL for the specified node.
     * @param node The node to update.
     * @param ttl The TTL in seconds.
     */
    function setTTL(bytes32 node, uint64 ttl) only_owner(node) public {
        NewTTL(node, ttl);
        records[node].ttl = ttl;
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;

import "./AppStorage.sol";
import "../acl/ACLSyntaxSugar.sol";
import "../common/Autopetrified.sol";
import "../common/ConversionHelpers.sol";
import "../common/ReentrancyGuard.sol";
import "../common/VaultRecoverable.sol";
import "../evmscript/EVMScriptRunner.sol";


// Contracts inheriting from AragonApp are, by default, immediately petrified upon deployment so
// that they can never be initialized.
// Unless overriden, this behaviour enforces those contracts to be usable only behind an AppProxy.
// ReentrancyGuard, EVMScriptRunner, and ACLSyntaxSugar are not directly used by this contract, but
// are included so that they are automatically usable by subclassing contracts
contract AragonApp is AppStorage, Autopetrified, VaultRecoverable, ReentrancyGuard, EVMScriptRunner, ACLSyntaxSugar {
    string private constant ERROR_AUTH_FAILED = "APP_AUTH_FAILED";

    modifier auth(bytes32 _role) {
        require(canPerform(msg.sender, _role, new uint256[](0)), ERROR_AUTH_FAILED);
        _;
    }

    modifier authP(bytes32 _role, uint256[] _params) {
        require(canPerform(msg.sender, _role, _params), ERROR_AUTH_FAILED);
        _;
    }

    /**
    * @dev Check whether an action can be performed by a sender for a particular role on this app
    * @param _sender Sender of the call
    * @param _role Role on this app
    * @param _params Permission params for the role
    * @return Boolean indicating whether the sender has the permissions to perform the action.
    *         Always returns false if the app hasn't been initialized yet.
    */
    function canPerform(address _sender, bytes32 _role, uint256[] _params) public view returns (bool) {
        if (!hasInitialized()) {
            return false;
        }

        IKernel linkedKernel = kernel();
        if (address(linkedKernel) == address(0)) {
            return false;
        }

        return linkedKernel.hasPermission(
            _sender,
            address(this),
            _role,
            ConversionHelpers.dangerouslyCastUintArrayToBytes(_params)
        );
    }

    /**
    * @dev Get the recovery vault for the app
    * @return Recovery vault address for the app
    */
    function getRecoveryVault() public view returns (address) {
        // Funds recovery via a vault is only available when used with a kernel
        return kernel().getRecoveryVault(); // if kernel is not set, it will revert
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


interface IForwarder {
    function isForwarder() external pure returns (bool);

    // TODO: this should be external
    // See https://github.com/ethereum/solidity/issues/4832
    function canForward(address sender, bytes evmCallScript) public view returns (bool);

    // TODO: this should be external
    // See https://github.com/ethereum/solidity/issues/4832
    function forward(bytes evmCallScript) public;
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

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;

import "../common/UnstructuredStorage.sol";
import "../kernel/IKernel.sol";


contract AppStorage {
    using UnstructuredStorage for bytes32;

    /* Hardcoded constants to save gas
    bytes32 internal constant KERNEL_POSITION = keccak256("aragonOS.appStorage.kernel");
    bytes32 internal constant APP_ID_POSITION = keccak256("aragonOS.appStorage.appId");
    */
    bytes32 internal constant KERNEL_POSITION = 0x4172f0f7d2289153072b0a6ca36959e0cbe2efc3afe50fc81636caa96338137b;
    bytes32 internal constant APP_ID_POSITION = 0xd625496217aa6a3453eecb9c3489dc5a53e6c67b444329ea2b2cbc9ff547639b;

    function kernel() public view returns (IKernel) {
        return IKernel(KERNEL_POSITION.getStorageAddress());
    }

    function appId() public view returns (bytes32) {
        return APP_ID_POSITION.getStorageBytes32();
    }

    function setKernel(IKernel _kernel) internal {
        KERNEL_POSITION.setStorageAddress(address(_kernel));
    }

    function setAppId(bytes32 _appId) internal {
        APP_ID_POSITION.setStorageBytes32(_appId);
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

import "../common/UnstructuredStorage.sol";


contract ReentrancyGuard {
    using UnstructuredStorage for bytes32;

    /* Hardcoded constants to save gas
    bytes32 internal constant REENTRANCY_MUTEX_POSITION = keccak256("aragonOS.reentrancyGuard.mutex");
    */
    bytes32 private constant REENTRANCY_MUTEX_POSITION = 0xe855346402235fdd185c890e68d2c4ecad599b88587635ee285bce2fda58dacb;

    string private constant ERROR_REENTRANT = "REENTRANCY_REENTRANT_CALL";

    modifier nonReentrant() {
        // Ensure mutex is unlocked
        require(!REENTRANCY_MUTEX_POSITION.getStorageBool(), ERROR_REENTRANT);

        // Lock mutex before function call
        REENTRANCY_MUTEX_POSITION.setStorageBool(true);

        // Perform function call
        _;

        // Unlock mutex after function call
        REENTRANCY_MUTEX_POSITION.setStorageBool(false);
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;

import "./Petrifiable.sol";


contract Autopetrified is Petrifiable {
    constructor() public {
        // Immediately petrify base (non-proxy) instances of inherited contracts on deploy.
        // This renders them uninitializable (and unusable without a proxy).
        petrify();
    }
}

pragma solidity ^0.4.24;


library ConversionHelpers {
    string private constant ERROR_IMPROPER_LENGTH = "CONVERSION_IMPROPER_LENGTH";

    function dangerouslyCastUintArrayToBytes(uint256[] memory _input) internal pure returns (bytes memory output) {
        // Force cast the uint256[] into a bytes array, by overwriting its length
        // Note that the bytes array doesn't need to be initialized as we immediately overwrite it
        // with the input and a new length. The input becomes invalid from this point forward.
        uint256 byteLength = _input.length * 32;
        assembly {
            output := _input
            mstore(output, byteLength)
        }
    }

    function dangerouslyCastBytesToUintArray(bytes memory _input) internal pure returns (uint256[] memory output) {
        // Force cast the bytes array into a uint256[], by overwriting its length
        // Note that the uint256[] doesn't need to be initialized as we immediately overwrite it
        // with the input and a new length. The input becomes invalid from this point forward.
        uint256 intsLength = _input.length / 32;
        require(_input.length == intsLength * 32, ERROR_IMPROPER_LENGTH);

        assembly {
            output := _input
            mstore(output, intsLength)
        }
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

import "./IEVMScriptExecutor.sol";
import "./IEVMScriptRegistry.sol";

import "../apps/AppStorage.sol";
import "../kernel/KernelConstants.sol";
import "../common/Initializable.sol";


contract EVMScriptRunner is AppStorage, Initializable, EVMScriptRegistryConstants, KernelNamespaceConstants {
    string private constant ERROR_EXECUTOR_UNAVAILABLE = "EVMRUN_EXECUTOR_UNAVAILABLE";
    string private constant ERROR_PROTECTED_STATE_MODIFIED = "EVMRUN_PROTECTED_STATE_MODIFIED";

    /* This is manually crafted in assembly
    string private constant ERROR_EXECUTOR_INVALID_RETURN = "EVMRUN_EXECUTOR_INVALID_RETURN";
    */

    event ScriptResult(address indexed executor, bytes script, bytes input, bytes returnData);

    function getEVMScriptExecutor(bytes _script) public view returns (IEVMScriptExecutor) {
        return IEVMScriptExecutor(getEVMScriptRegistry().getScriptExecutor(_script));
    }

    function getEVMScriptRegistry() public view returns (IEVMScriptRegistry) {
        address registryAddr = kernel().getApp(KERNEL_APP_ADDR_NAMESPACE, EVMSCRIPT_REGISTRY_APP_ID);
        return IEVMScriptRegistry(registryAddr);
    }

    function runScript(bytes _script, bytes _input, address[] _blacklist)
        internal
        isInitialized
        protectState
        returns (bytes)
    {
        IEVMScriptExecutor executor = getEVMScriptExecutor(_script);
        require(address(executor) != address(0), ERROR_EXECUTOR_UNAVAILABLE);

        bytes4 sig = executor.execScript.selector;
        bytes memory data = abi.encodeWithSelector(sig, _script, _input, _blacklist);

        bytes memory output;
        assembly {
            let success := delegatecall(
                gas,                // forward all gas
                executor,           // address
                add(data, 0x20),    // calldata start
                mload(data),        // calldata length
                0,                  // don't write output (we'll handle this ourselves)
                0                   // don't write output
            )

            output := mload(0x40) // free mem ptr get

            switch success
            case 0 {
                // If the call errored, forward its full error data
                returndatacopy(output, 0, returndatasize)
                revert(output, returndatasize)
            }
            default {
                switch gt(returndatasize, 0x3f)
                case 0 {
                    // Need at least 0x40 bytes returned for properly ABI-encoded bytes values,
                    // revert with "EVMRUN_EXECUTOR_INVALID_RETURN"
                    // See remix: doing a `revert("EVMRUN_EXECUTOR_INVALID_RETURN")` always results in
                    // this memory layout
                    mstore(output, 0x08c379a000000000000000000000000000000000000000000000000000000000)         // error identifier
                    mstore(add(output, 0x04), 0x0000000000000000000000000000000000000000000000000000000000000020) // starting offset
                    mstore(add(output, 0x24), 0x000000000000000000000000000000000000000000000000000000000000001e) // reason length
                    mstore(add(output, 0x44), 0x45564d52554e5f4558454355544f525f494e56414c49445f52455455524e0000) // reason

                    revert(output, 100) // 100 = 4 + 3 * 32 (error identifier + 3 words for the ABI encoded error)
                }
                default {
                    // Copy result
                    //
                    // Needs to perform an ABI decode for the expected `bytes` return type of
                    // `executor.execScript()` as solidity will automatically ABI encode the returned bytes as:
                    //    [ position of the first dynamic length return value = 0x20 (32 bytes) ]
                    //    [ output length (32 bytes) ]
                    //    [ output content (N bytes) ]
                    //
                    // Perform the ABI decode by ignoring the first 32 bytes of the return data
                    let copysize := sub(returndatasize, 0x20)
                    returndatacopy(output, 0x20, copysize)

                    mstore(0x40, add(output, copysize)) // free mem ptr set
                }
            }
        }

        emit ScriptResult(address(executor), _script, _input, output);

        return output;
    }

    modifier protectState {
        address preKernel = address(kernel());
        bytes32 preAppId = appId();
        _; // exec
        require(address(kernel()) == preKernel, ERROR_PROTECTED_STATE_MODIFIED);
        require(appId() == preAppId, ERROR_PROTECTED_STATE_MODIFIED);
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;

import "../acl/IACL.sol";
import "../common/IVaultRecoverable.sol";


interface IKernelEvents {
    event SetApp(bytes32 indexed namespace, bytes32 indexed appId, address app);
}


// This should be an interface, but interfaces can't inherit yet :(
contract IKernel is IKernelEvents, IVaultRecoverable {
    function acl() public view returns (IACL);
    function hasPermission(address who, address where, bytes32 what, bytes how) public view returns (bool);

    function setApp(bytes32 namespace, bytes32 appId, address app) public;
    function getApp(bytes32 namespace, bytes32 appId) public view returns (address);
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

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


interface IACL {
    function initialize(address permissionsCreator) external;

    // TODO: this should be external
    // See https://github.com/ethereum/solidity/issues/4832
    function hasPermission(address who, address where, bytes32 what, bytes how) public view returns (bool);
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

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;

import "./Initializable.sol";


contract Petrifiable is Initializable {
    // Use block UINT256_MAX (which should be never) as the initializable date
    uint256 internal constant PETRIFIED_BLOCK = uint256(-1);

    function isPetrified() public view returns (bool) {
        return getInitializationBlock() == PETRIFIED_BLOCK;
    }

    /**
    * @dev Function to be called by top level contract to prevent being initialized.
    *      Useful for freezing base contracts when they're used behind proxies.
    */
    function petrify() internal onlyInit {
        initializedAt(PETRIFIED_BLOCK);
    }
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

pragma solidity ^0.4.24;


library Uint256Helpers {
    uint256 private constant MAX_UINT64 = uint64(-1);

    string private constant ERROR_NUMBER_TOO_BIG = "UINT64_NUMBER_TOO_BIG";

    function toUint64(uint256 a) internal pure returns (uint64) {
        require(a <= MAX_UINT64, ERROR_NUMBER_TOO_BIG);
        return uint64(a);
    }
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


contract KernelAppIds {
    /* Hardcoded constants to save gas
    bytes32 internal constant KERNEL_CORE_APP_ID = apmNamehash("kernel");
    bytes32 internal constant KERNEL_DEFAULT_ACL_APP_ID = apmNamehash("acl");
    bytes32 internal constant KERNEL_DEFAULT_VAULT_APP_ID = apmNamehash("vault");
    */
    bytes32 internal constant KERNEL_CORE_APP_ID = 0x3b4bf6bf3ad5000ecf0f989d5befde585c6860fea3e574a4fab4c49d1c177d9c;
    bytes32 internal constant KERNEL_DEFAULT_ACL_APP_ID = 0xe3262375f45a6e2026b7e7b18c2b807434f2508fe1a2a3dfb493c7df8f4aad6a;
    bytes32 internal constant KERNEL_DEFAULT_VAULT_APP_ID = 0x7e852e0fcfce6551c13800f1e7476f982525c2b5277ba14b24339c68416336d1;
}


contract KernelNamespaceConstants {
    /* Hardcoded constants to save gas
    bytes32 internal constant KERNEL_CORE_NAMESPACE = keccak256("core");
    bytes32 internal constant KERNEL_APP_BASES_NAMESPACE = keccak256("base");
    bytes32 internal constant KERNEL_APP_ADDR_NAMESPACE = keccak256("app");
    */
    bytes32 internal constant KERNEL_CORE_NAMESPACE = 0xc681a85306374a5ab27f0bbc385296a54bcd314a1948b6cf61c4ea1bc44bb9f8;
    bytes32 internal constant KERNEL_APP_BASES_NAMESPACE = 0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f;
    bytes32 internal constant KERNEL_APP_ADDR_NAMESPACE = 0xd6f028ca0e8edb4a8c9757ca4fdccab25fa1e0317da1188108f7d2dee14902fb;
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


interface IEVMScriptExecutor {
    function execScript(bytes script, bytes input, address[] blacklist) external returns (bytes);
    function executorType() external pure returns (bytes32);
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;

import "./IEVMScriptExecutor.sol";


contract EVMScriptRegistryConstants {
    /* Hardcoded constants to save gas
    bytes32 internal constant EVMSCRIPT_REGISTRY_APP_ID = apmNamehash("evmreg");
    */
    bytes32 internal constant EVMSCRIPT_REGISTRY_APP_ID = 0xddbcfd564f642ab5627cf68b9b7d374fb4f8a36e941a75d89c87998cef03bd61;
}


interface IEVMScriptRegistry {
    function addScriptExecutor(IEVMScriptExecutor executor) external returns (uint id);
    function disableScriptExecutor(uint256 executorId) external;

    // TODO: this should be external
    // See https://github.com/ethereum/solidity/issues/4832
    function getScriptExecutor(bytes script) public view returns (IEVMScriptExecutor);
}

pragma solidity ^0.4.24;

/*
    Copyright 2016, Jordi Baylina
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/// @title MiniMeToken Contract
/// @author Jordi Baylina
/// @dev This token contract's goal is to make it easy for anyone to clone this
///  token using the token distribution at a given block, this will allow DAO's
///  and DApps to upgrade their features in a decentralized manner without
///  affecting the original token
/// @dev It is ERC20 compliant, but still needs to under go further testing.

import "./ITokenController.sol";

contract Controlled {
    /// @notice The address of the controller is the only address that can call
    ///  a function with this modifier
    modifier onlyController {
        require(msg.sender == controller);
        _;
    }

    address public controller;

    function Controlled()  public { controller = msg.sender;}

    /// @notice Changes the controller of the contract
    /// @param _newController The new controller of the contract
    function changeController(address _newController) onlyController  public {
        controller = _newController;
    }
}

contract ApproveAndCallFallBack {
    function receiveApproval(
        address from,
        uint256 _amount,
        address _token,
        bytes _data
    ) public;
}

/// @dev The actual token contract, the default controller is the msg.sender
///  that deploys the contract, so usually this token will be deployed by a
///  token controller contract, which Giveth will call a "Campaign"
contract MiniMeToken is Controlled {

    string public name;                //The Token's name: e.g. DigixDAO Tokens
    uint8 public decimals;             //Number of decimals of the smallest unit
    string public symbol;              //An identifier: e.g. REP
    string public version = "MMT_0.1"; //An arbitrary versioning scheme


    /// @dev `Checkpoint` is the structure that attaches a block number to a
    ///  given value, the block number attached is the one that last changed the
    ///  value
    struct Checkpoint {

        // `fromBlock` is the block number that the value was generated from
        uint128 fromBlock;

        // `value` is the amount of tokens at a specific block number
        uint128 value;
    }

    // `parentToken` is the Token address that was cloned to produce this token;
    //  it will be 0x0 for a token that was not cloned
    MiniMeToken public parentToken;

    // `parentSnapShotBlock` is the block number from the Parent Token that was
    //  used to determine the initial distribution of the Clone Token
    uint public parentSnapShotBlock;

    // `creationBlock` is the block number that the Clone Token was created
    uint public creationBlock;

    // `balances` is the map that tracks the balance of each address, in this
    //  contract when the balance changes the block number that the change
    //  occurred is also included in the map
    mapping (address => Checkpoint[]) balances;

    // `allowed` tracks any extra transfer rights as in all ERC20 tokens
    mapping (address => mapping (address => uint256)) allowed;

    // Tracks the history of the `totalSupply` of the token
    Checkpoint[] totalSupplyHistory;

    // Flag that determines if the token is transferable or not.
    bool public transfersEnabled;

    // The factory used to create new clone tokens
    MiniMeTokenFactory public tokenFactory;

////////////////
// Constructor
////////////////

    /// @notice Constructor to create a MiniMeToken
    /// @param _tokenFactory The address of the MiniMeTokenFactory contract that
    ///  will create the Clone token contracts, the token factory needs to be
    ///  deployed first
    /// @param _parentToken Address of the parent token, set to 0x0 if it is a
    ///  new token
    /// @param _parentSnapShotBlock Block of the parent token that will
    ///  determine the initial distribution of the clone token, set to 0 if it
    ///  is a new token
    /// @param _tokenName Name of the new token
    /// @param _decimalUnits Number of decimals of the new token
    /// @param _tokenSymbol Token Symbol for the new token
    /// @param _transfersEnabled If true, tokens will be able to be transferred
    function MiniMeToken(
        MiniMeTokenFactory _tokenFactory,
        MiniMeToken _parentToken,
        uint _parentSnapShotBlock,
        string _tokenName,
        uint8 _decimalUnits,
        string _tokenSymbol,
        bool _transfersEnabled
    )  public
    {
        tokenFactory = _tokenFactory;
        name = _tokenName;                                 // Set the name
        decimals = _decimalUnits;                          // Set the decimals
        symbol = _tokenSymbol;                             // Set the symbol
        parentToken = _parentToken;
        parentSnapShotBlock = _parentSnapShotBlock;
        transfersEnabled = _transfersEnabled;
        creationBlock = block.number;
    }


///////////////////
// ERC20 Methods
///////////////////

    /// @notice Send `_amount` tokens to `_to` from `msg.sender`
    /// @param _to The address of the recipient
    /// @param _amount The amount of tokens to be transferred
    /// @return Whether the transfer was successful or not
    function transfer(address _to, uint256 _amount) public returns (bool success) {
        require(transfersEnabled);
        return doTransfer(msg.sender, _to, _amount);
    }

    /// @notice Send `_amount` tokens to `_to` from `_from` on the condition it
    ///  is approved by `_from`
    /// @param _from The address holding the tokens being transferred
    /// @param _to The address of the recipient
    /// @param _amount The amount of tokens to be transferred
    /// @return True if the transfer was successful
    function transferFrom(address _from, address _to, uint256 _amount) public returns (bool success) {

        // The controller of this contract can move tokens around at will,
        //  this is important to recognize! Confirm that you trust the
        //  controller of this contract, which in most situations should be
        //  another open source smart contract or 0x0
        if (msg.sender != controller) {
            require(transfersEnabled);

            // The standard ERC 20 transferFrom functionality
            if (allowed[_from][msg.sender] < _amount)
                return false;
            allowed[_from][msg.sender] -= _amount;
        }
        return doTransfer(_from, _to, _amount);
    }

    /// @dev This is the actual transfer function in the token contract, it can
    ///  only be called by other functions in this contract.
    /// @param _from The address holding the tokens being transferred
    /// @param _to The address of the recipient
    /// @param _amount The amount of tokens to be transferred
    /// @return True if the transfer was successful
    function doTransfer(address _from, address _to, uint _amount) internal returns(bool) {
        if (_amount == 0) {
            return true;
        }
        require(parentSnapShotBlock < block.number);
        // Do not allow transfer to 0x0 or the token contract itself
        require((_to != 0) && (_to != address(this)));
        // If the amount being transfered is more than the balance of the
        //  account the transfer returns false
        var previousBalanceFrom = balanceOfAt(_from, block.number);
        if (previousBalanceFrom < _amount) {
            return false;
        }
        // Alerts the token controller of the transfer
        if (isContract(controller)) {
            // Adding the ` == true` makes the linter shut up so...
            require(ITokenController(controller).onTransfer(_from, _to, _amount) == true);
        }
        // First update the balance array with the new value for the address
        //  sending the tokens
        updateValueAtNow(balances[_from], previousBalanceFrom - _amount);
        // Then update the balance array with the new value for the address
        //  receiving the tokens
        var previousBalanceTo = balanceOfAt(_to, block.number);
        require(previousBalanceTo + _amount >= previousBalanceTo); // Check for overflow
        updateValueAtNow(balances[_to], previousBalanceTo + _amount);
        // An event to make the transfer easy to find on the blockchain
        Transfer(_from, _to, _amount);
        return true;
    }

    /// @param _owner The address that's balance is being requested
    /// @return The balance of `_owner` at the current block
    function balanceOf(address _owner) public constant returns (uint256 balance) {
        return balanceOfAt(_owner, block.number);
    }

    /// @notice `msg.sender` approves `_spender` to spend `_amount` tokens on
    ///  its behalf. This is a modified version of the ERC20 approve function
    ///  to be a little bit safer
    /// @param _spender The address of the account able to transfer the tokens
    /// @param _amount The amount of tokens to be approved for transfer
    /// @return True if the approval was successful
    function approve(address _spender, uint256 _amount) public returns (bool success) {
        require(transfersEnabled);

        // To change the approve amount you first have to reduce the addresses`
        //  allowance to zero by calling `approve(_spender,0)` if it is not
        //  already 0 to mitigate the race condition described here:
        //  https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
        require((_amount == 0) || (allowed[msg.sender][_spender] == 0));

        // Alerts the token controller of the approve function call
        if (isContract(controller)) {
            // Adding the ` == true` makes the linter shut up so...
            require(ITokenController(controller).onApprove(msg.sender, _spender, _amount) == true);
        }

        allowed[msg.sender][_spender] = _amount;
        Approval(msg.sender, _spender, _amount);
        return true;
    }

    /// @dev This function makes it easy to read the `allowed[]` map
    /// @param _owner The address of the account that owns the token
    /// @param _spender The address of the account able to transfer the tokens
    /// @return Amount of remaining tokens of _owner that _spender is allowed
    ///  to spend
    function allowance(address _owner, address _spender) public constant returns (uint256 remaining) {
        return allowed[_owner][_spender];
    }

    /// @notice `msg.sender` approves `_spender` to send `_amount` tokens on
    ///  its behalf, and then a function is triggered in the contract that is
    ///  being approved, `_spender`. This allows users to use their tokens to
    ///  interact with contracts in one function call instead of two
    /// @param _spender The address of the contract able to transfer the tokens
    /// @param _amount The amount of tokens to be approved for transfer
    /// @return True if the function call was successful
    function approveAndCall(ApproveAndCallFallBack _spender, uint256 _amount, bytes _extraData) public returns (bool success) {
        require(approve(_spender, _amount));

        _spender.receiveApproval(
            msg.sender,
            _amount,
            this,
            _extraData
        );

        return true;
    }

    /// @dev This function makes it easy to get the total number of tokens
    /// @return The total number of tokens
    function totalSupply() public constant returns (uint) {
        return totalSupplyAt(block.number);
    }


////////////////
// Query balance and totalSupply in History
////////////////

    /// @dev Queries the balance of `_owner` at a specific `_blockNumber`
    /// @param _owner The address from which the balance will be retrieved
    /// @param _blockNumber The block number when the balance is queried
    /// @return The balance at `_blockNumber`
    function balanceOfAt(address _owner, uint _blockNumber) public constant returns (uint) {

        // These next few lines are used when the balance of the token is
        //  requested before a check point was ever created for this token, it
        //  requires that the `parentToken.balanceOfAt` be queried at the
        //  genesis block for that token as this contains initial balance of
        //  this token
        if ((balances[_owner].length == 0) || (balances[_owner][0].fromBlock > _blockNumber)) {
            if (address(parentToken) != 0) {
                return parentToken.balanceOfAt(_owner, min(_blockNumber, parentSnapShotBlock));
            } else {
                // Has no parent
                return 0;
            }

        // This will return the expected balance during normal situations
        } else {
            return getValueAt(balances[_owner], _blockNumber);
        }
    }

    /// @notice Total amount of tokens at a specific `_blockNumber`.
    /// @param _blockNumber The block number when the totalSupply is queried
    /// @return The total amount of tokens at `_blockNumber`
    function totalSupplyAt(uint _blockNumber) public constant returns(uint) {

        // These next few lines are used when the totalSupply of the token is
        //  requested before a check point was ever created for this token, it
        //  requires that the `parentToken.totalSupplyAt` be queried at the
        //  genesis block for this token as that contains totalSupply of this
        //  token at this block number.
        if ((totalSupplyHistory.length == 0) || (totalSupplyHistory[0].fromBlock > _blockNumber)) {
            if (address(parentToken) != 0) {
                return parentToken.totalSupplyAt(min(_blockNumber, parentSnapShotBlock));
            } else {
                return 0;
            }

        // This will return the expected totalSupply during normal situations
        } else {
            return getValueAt(totalSupplyHistory, _blockNumber);
        }
    }

////////////////
// Clone Token Method
////////////////

    /// @notice Creates a new clone token with the initial distribution being
    ///  this token at `_snapshotBlock`
    /// @param _cloneTokenName Name of the clone token
    /// @param _cloneDecimalUnits Number of decimals of the smallest unit
    /// @param _cloneTokenSymbol Symbol of the clone token
    /// @param _snapshotBlock Block when the distribution of the parent token is
    ///  copied to set the initial distribution of the new clone token;
    ///  if the block is zero than the actual block, the current block is used
    /// @param _transfersEnabled True if transfers are allowed in the clone
    /// @return The address of the new MiniMeToken Contract
    function createCloneToken(
        string _cloneTokenName,
        uint8 _cloneDecimalUnits,
        string _cloneTokenSymbol,
        uint _snapshotBlock,
        bool _transfersEnabled
    ) public returns(MiniMeToken)
    {
        uint256 snapshot = _snapshotBlock == 0 ? block.number - 1 : _snapshotBlock;

        MiniMeToken cloneToken = tokenFactory.createCloneToken(
            this,
            snapshot,
            _cloneTokenName,
            _cloneDecimalUnits,
            _cloneTokenSymbol,
            _transfersEnabled
        );

        cloneToken.changeController(msg.sender);

        // An event to make the token easy to find on the blockchain
        NewCloneToken(address(cloneToken), snapshot);
        return cloneToken;
    }

////////////////
// Generate and destroy tokens
////////////////

    /// @notice Generates `_amount` tokens that are assigned to `_owner`
    /// @param _owner The address that will be assigned the new tokens
    /// @param _amount The quantity of tokens generated
    /// @return True if the tokens are generated correctly
    function generateTokens(address _owner, uint _amount) onlyController public returns (bool) {
        uint curTotalSupply = totalSupply();
        require(curTotalSupply + _amount >= curTotalSupply); // Check for overflow
        uint previousBalanceTo = balanceOf(_owner);
        require(previousBalanceTo + _amount >= previousBalanceTo); // Check for overflow
        updateValueAtNow(totalSupplyHistory, curTotalSupply + _amount);
        updateValueAtNow(balances[_owner], previousBalanceTo + _amount);
        Transfer(0, _owner, _amount);
        return true;
    }


    /// @notice Burns `_amount` tokens from `_owner`
    /// @param _owner The address that will lose the tokens
    /// @param _amount The quantity of tokens to burn
    /// @return True if the tokens are burned correctly
    function destroyTokens(address _owner, uint _amount) onlyController public returns (bool) {
        uint curTotalSupply = totalSupply();
        require(curTotalSupply >= _amount);
        uint previousBalanceFrom = balanceOf(_owner);
        require(previousBalanceFrom >= _amount);
        updateValueAtNow(totalSupplyHistory, curTotalSupply - _amount);
        updateValueAtNow(balances[_owner], previousBalanceFrom - _amount);
        Transfer(_owner, 0, _amount);
        return true;
    }

////////////////
// Enable tokens transfers
////////////////


    /// @notice Enables token holders to transfer their tokens freely if true
    /// @param _transfersEnabled True if transfers are allowed in the clone
    function enableTransfers(bool _transfersEnabled) onlyController public {
        transfersEnabled = _transfersEnabled;
    }

////////////////
// Internal helper functions to query and set a value in a snapshot array
////////////////

    /// @dev `getValueAt` retrieves the number of tokens at a given block number
    /// @param checkpoints The history of values being queried
    /// @param _block The block number to retrieve the value at
    /// @return The number of tokens being queried
    function getValueAt(Checkpoint[] storage checkpoints, uint _block) constant internal returns (uint) {
        if (checkpoints.length == 0)
            return 0;

        // Shortcut for the actual value
        if (_block >= checkpoints[checkpoints.length-1].fromBlock)
            return checkpoints[checkpoints.length-1].value;
        if (_block < checkpoints[0].fromBlock)
            return 0;

        // Binary search of the value in the array
        uint min = 0;
        uint max = checkpoints.length-1;
        while (max > min) {
            uint mid = (max + min + 1) / 2;
            if (checkpoints[mid].fromBlock<=_block) {
                min = mid;
            } else {
                max = mid-1;
            }
        }
        return checkpoints[min].value;
    }

    /// @dev `updateValueAtNow` used to update the `balances` map and the
    ///  `totalSupplyHistory`
    /// @param checkpoints The history of data being updated
    /// @param _value The new number of tokens
    function updateValueAtNow(Checkpoint[] storage checkpoints, uint _value) internal {
        if ((checkpoints.length == 0) || (checkpoints[checkpoints.length - 1].fromBlock < block.number)) {
            Checkpoint storage newCheckPoint = checkpoints[checkpoints.length++];
            newCheckPoint.fromBlock = uint128(block.number);
            newCheckPoint.value = uint128(_value);
        } else {
            Checkpoint storage oldCheckPoint = checkpoints[checkpoints.length - 1];
            oldCheckPoint.value = uint128(_value);
        }
    }

    /// @dev Internal function to determine if an address is a contract
    /// @param _addr The address being queried
    /// @return True if `_addr` is a contract
    function isContract(address _addr) constant internal returns(bool) {
        uint size;
        if (_addr == 0)
            return false;

        assembly {
            size := extcodesize(_addr)
        }

        return size>0;
    }

    /// @dev Helper function to return a min betwen the two uints
    function min(uint a, uint b) pure internal returns (uint) {
        return a < b ? a : b;
    }

    /// @notice The fallback function: If the contract's controller has not been
    ///  set to 0, then the `proxyPayment` method is called which relays the
    ///  ether and creates tokens as described in the token controller contract
    function () external payable {
        require(isContract(controller));
        // Adding the ` == true` makes the linter shut up so...
        require(ITokenController(controller).proxyPayment.value(msg.value)(msg.sender) == true);
    }

//////////
// Safety Methods
//////////

    /// @notice This method can be used by the controller to extract mistakenly
    ///  sent tokens to this contract.
    /// @param _token The address of the token contract that you want to recover
    ///  set to 0 in case you want to extract ether.
    function claimTokens(address _token) onlyController public {
        if (_token == 0x0) {
            controller.transfer(this.balance);
            return;
        }

        MiniMeToken token = MiniMeToken(_token);
        uint balance = token.balanceOf(this);
        token.transfer(controller, balance);
        ClaimedTokens(_token, controller, balance);
    }

////////////////
// Events
////////////////
    event ClaimedTokens(address indexed _token, address indexed _controller, uint _amount);
    event Transfer(address indexed _from, address indexed _to, uint256 _amount);
    event NewCloneToken(address indexed _cloneToken, uint _snapshotBlock);
    event Approval(
        address indexed _owner,
        address indexed _spender,
        uint256 _amount
        );

}


////////////////
// MiniMeTokenFactory
////////////////

/// @dev This contract is used to generate clone contracts from a contract.
///  In solidity this is the way to create a contract from a contract of the
///  same class
contract MiniMeTokenFactory {

    /// @notice Update the DApp by creating a new token with new functionalities
    ///  the msg.sender becomes the controller of this clone token
    /// @param _parentToken Address of the token being cloned
    /// @param _snapshotBlock Block of the parent token that will
    ///  determine the initial distribution of the clone token
    /// @param _tokenName Name of the new token
    /// @param _decimalUnits Number of decimals of the new token
    /// @param _tokenSymbol Token Symbol for the new token
    /// @param _transfersEnabled If true, tokens will be able to be transferred
    /// @return The address of the new token contract
    function createCloneToken(
        MiniMeToken _parentToken,
        uint _snapshotBlock,
        string _tokenName,
        uint8 _decimalUnits,
        string _tokenSymbol,
        bool _transfersEnabled
    ) public returns (MiniMeToken)
    {
        MiniMeToken newToken = new MiniMeToken(
            this,
            _parentToken,
            _snapshotBlock,
            _tokenName,
            _decimalUnits,
            _tokenSymbol,
            _transfersEnabled
        );

        newToken.changeController(msg.sender);
        return newToken;
    }
}

pragma solidity ^0.4.24;

/// @dev The token controller contract must implement these functions


interface ITokenController {
    /// @notice Called when `_owner` sends ether to the MiniMe Token contract
    /// @param _owner The address that sent the ether to create tokens
    /// @return True if the ether is accepted, false if it throws
    function proxyPayment(address _owner) external payable returns(bool);

    /// @notice Notifies the controller about a token transfer allowing the
    ///  controller to react if desired
    /// @param _from The origin of the transfer
    /// @param _to The destination of the transfer
    /// @param _amount The amount of the transfer
    /// @return False if the controller does not authorize the transfer
    function onTransfer(address _from, address _to, uint _amount) external returns(bool);

    /// @notice Notifies the controller about an approval allowing the
    ///  controller to react if desired
    /// @param _owner The address that calls `approve()`
    /// @param _spender The spender in the `approve()` call
    /// @param _amount The amount in the `approve()` call
    /// @return False if the controller does not authorize the approval
    function onApprove(address _owner, address _spender, uint _amount) external returns(bool);
}

pragma solidity 0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/common/DepositableStorage.sol";
import "@aragon/os/contracts/common/EtherTokenConstant.sol";
import "@aragon/os/contracts/common/SafeERC20.sol";
import "@aragon/os/contracts/lib/token/ERC20.sol";


contract Vault is EtherTokenConstant, AragonApp, DepositableStorage {
    using SafeERC20 for ERC20;

    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    string private constant ERROR_DATA_NON_ZERO = "VAULT_DATA_NON_ZERO";
    string private constant ERROR_NOT_DEPOSITABLE = "VAULT_NOT_DEPOSITABLE";
    string private constant ERROR_DEPOSIT_VALUE_ZERO = "VAULT_DEPOSIT_VALUE_ZERO";
    string private constant ERROR_TRANSFER_VALUE_ZERO = "VAULT_TRANSFER_VALUE_ZERO";
    string private constant ERROR_SEND_REVERTED = "VAULT_SEND_REVERTED";
    string private constant ERROR_VALUE_MISMATCH = "VAULT_VALUE_MISMATCH";
    string private constant ERROR_TOKEN_TRANSFER_FROM_REVERTED = "VAULT_TOKEN_TRANSFER_FROM_REVERT";
    string private constant ERROR_TOKEN_TRANSFER_REVERTED = "VAULT_TOKEN_TRANSFER_REVERTED";

    event VaultTransfer(address indexed token, address indexed to, uint256 amount);
    event VaultDeposit(address indexed token, address indexed sender, uint256 amount);

    /**
    * @dev On a normal send() or transfer() this fallback is never executed as it will be
    *      intercepted by the Proxy (see aragonOS#281)
    */
    function () external payable isInitialized {
        require(msg.data.length == 0, ERROR_DATA_NON_ZERO);
        _deposit(ETH, msg.value);
    }

    /**
    * @notice Initialize Vault app
    * @dev As an AragonApp it needs to be initialized in order for roles (`auth` and `authP`) to work
    */
    function initialize() external onlyInit {
        initialized();
        setDepositable(true);
    }

    /**
    * @notice Deposit `_value` `_token` to the vault
    * @param _token Address of the token being transferred
    * @param _value Amount of tokens being transferred
    */
    function deposit(address _token, uint256 _value) external payable isInitialized {
        _deposit(_token, _value);
    }

    /**
    * @notice Transfer `_value` `_token` from the Vault to `_to`
    * @param _token Address of the token being transferred
    * @param _to Address of the recipient of tokens
    * @param _value Amount of tokens being transferred
    */
    /* solium-disable-next-line function-order */
    function transfer(address _token, address _to, uint256 _value)
        external
        authP(TRANSFER_ROLE, arr(_token, _to, _value))
    {
        require(_value > 0, ERROR_TRANSFER_VALUE_ZERO);

        if (_token == ETH) {
            require(_to.send(_value), ERROR_SEND_REVERTED);
        } else {
            require(ERC20(_token).safeTransfer(_to, _value), ERROR_TOKEN_TRANSFER_REVERTED);
        }

        emit VaultTransfer(_token, _to, _value);
    }

    function balance(address _token) public view returns (uint256) {
        if (_token == ETH) {
            return address(this).balance;
        } else {
            return ERC20(_token).staticBalanceOf(address(this));
        }
    }

    /**
    * @dev Disable recovery escape hatch, as it could be used
    *      maliciously to transfer funds away from the vault
    */
    function allowRecoverability(address) public view returns (bool) {
        return false;
    }

    function _deposit(address _token, uint256 _value) internal {
        require(isDepositable(), ERROR_NOT_DEPOSITABLE);
        require(_value > 0, ERROR_DEPOSIT_VALUE_ZERO);

        if (_token == ETH) {
            // Deposit is implicit in this case
            require(msg.value == _value, ERROR_VALUE_MISMATCH);
        } else {
            require(
                ERC20(_token).safeTransferFrom(msg.sender, address(this), _value),
                ERROR_TOKEN_TRANSFER_FROM_REVERTED
            );
        }

        emit VaultDeposit(_token, msg.sender, _value);
    }
}

pragma solidity 0.4.24;

// Inspired by https://github.com/horizon-games/multi-token-standard/blob/319740cf2a78b8816269ae49a09c537b3fd7303b/contracts/utils/SignatureValidator.sol
// This should probably be moved into aOS: https://github.com/aragon/aragonOS/pull/442

import "./standards/ERC1271.sol";


library SignatureValidator {
    enum SignatureMode {
        Invalid, // 0x00
        EIP712,  // 0x01
        EthSign, // 0x02
        ERC1271, // 0x03
        NMode    // 0x04, to check if mode is specified, leave at the end
    }

    // bytes4(keccak256("isValidSignature(bytes,bytes)")
    bytes4 public constant ERC1271_RETURN_VALID_SIGNATURE = 0x20c13b0b;
    uint256 internal constant ERC1271_ISVALIDSIG_MAX_GAS = 250000;

    string private constant ERROR_INVALID_LENGTH_POP_BYTE = "SIGVAL_INVALID_LENGTH_POP_BYTE";

    /// @dev Validates that a hash was signed by a specified signer.
    /// @param hash Hash which was signed.
    /// @param signer Address of the signer.
    /// @param signature ECDSA signature along with the mode (0 = Invalid, 1 = EIP712, 2 = EthSign, 3 = ERC1271) {mode}{r}{s}{v}.
    /// @return Returns whether signature is from a specified user.
    function isValidSignature(bytes32 hash, address signer, bytes signature) internal view returns (bool) {
        if (signature.length == 0) {
            return false;
        }

        uint8 modeByte = uint8(signature[0]);
        if (modeByte >= uint8(SignatureMode.NMode)) {
            return false;
        }
        SignatureMode mode = SignatureMode(modeByte);

        if (mode == SignatureMode.EIP712) {
            return ecVerify(hash, signer, signature);
        } else if (mode == SignatureMode.EthSign) {
            return ecVerify(
                keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)),
                signer,
                signature
            );
        } else if (mode == SignatureMode.ERC1271) {
            // Pop the mode byte before sending it down the validation chain
            return safeIsValidSignature(signer, hash, popFirstByte(signature));
        } else {
            return false;
        }
    }

    function ecVerify(bytes32 hash, address signer, bytes memory signature) private pure returns (bool) {
        (bool badSig, bytes32 r, bytes32 s, uint8 v) = unpackEcSig(signature);

        if (badSig) {
            return false;
        }

        return signer == ecrecover(hash, v, r, s);
    }

    function unpackEcSig(bytes memory signature) private pure returns (bool badSig, bytes32 r, bytes32 s, uint8 v) {
        if (signature.length != 66) {
            badSig = true;
            return;
        }

        v = uint8(signature[65]);
        assembly {
            r := mload(add(signature, 33))
            s := mload(add(signature, 65))
        }

        // Allow signature version to be 0 or 1
        if (v < 27) {
            v += 27;
        }

        if (v != 27 && v != 28) {
            badSig = true;
        }
    }

    function popFirstByte(bytes memory input) private pure returns (bytes memory output) {
        uint256 inputLength = input.length;
        require(inputLength > 0, ERROR_INVALID_LENGTH_POP_BYTE);

        output = new bytes(inputLength - 1);

        if (output.length == 0) {
            return output;
        }

        uint256 inputPointer;
        uint256 outputPointer;
        assembly {
            inputPointer := add(input, 0x21)
            outputPointer := add(output, 0x20)
        }
        memcpy(outputPointer, inputPointer, output.length);
    }

    function safeIsValidSignature(address validator, bytes32 hash, bytes memory signature) private view returns (bool) {
        bytes memory data = abi.encodeWithSelector(ERC1271(validator).isValidSignature.selector, hash, signature);
        bytes4 erc1271Return = safeBytes4StaticCall(validator, data, ERC1271_ISVALIDSIG_MAX_GAS);
        return erc1271Return == ERC1271_RETURN_VALID_SIGNATURE;
    }

    function safeBytes4StaticCall(address target, bytes data, uint256 maxGas) private view returns (bytes4 ret) {
        uint256 gasLeft = gasleft();

        uint256 callGas = gasLeft > maxGas ? maxGas : gasLeft;
        bool ok;
        assembly {
            ok := staticcall(callGas, target, add(data, 0x20), mload(data), 0, 0)
        }

        if (!ok) {
            return;
        }

        uint256 size;
        assembly { size := returndatasize }
        if (size != 32) {
            return;
        }

        assembly {
            let ptr := mload(0x40)       // get next free memory ptr
            returndatacopy(ptr, 0, size) // copy return from above `staticcall`
            ret := mload(ptr)            // read data at ptr and set it to be returned
        }

        return ret;
    }

    // From: https://github.com/Arachnid/solidity-stringutils/blob/01e955c1d6/src/strings.sol
    function memcpy(uint256 dest, uint256 src, uint256 len) private pure {
        // Copy word-length chunks while possible
        for (; len >= 32; len -= 32) {
            assembly {
                mstore(dest, mload(src))
            }
            dest += 32;
            src += 32;
        }

        // Copy remaining bytes
        uint mask = 256 ** (32 - len) - 1;
        assembly {
            let srcpart := and(mload(src), not(mask))
            let destpart := and(mload(dest), mask)
            mstore(dest, or(destpart, srcpart))
        }
    }
}

pragma solidity 0.4.24;


interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}

pragma solidity 0.4.24;

// ERC1271 on Feb 12th, 2019: https://github.com/ethereum/EIPs/blob/a97dc434930d0ccc4461c97d8c7a920dc585adf2/EIPS/eip-1271.md
// Using `isValidSignature(bytes32,bytes)` even though the standard still hasn't been modified
// Rationale: https://github.com/ethereum/EIPs/issues/1271#issuecomment-462719728


contract ERC1271 {
    bytes4 constant public ERC1271_INTERFACE_ID = 0xfb855dc9; // this.isValidSignature.selector

    bytes4 constant public ERC1271_RETURN_VALID_SIGNATURE =   0x20c13b0b; // TODO: Likely needs to be updated
    bytes4 constant public ERC1271_RETURN_INVALID_SIGNATURE = 0x00000000;

    /**
    * @dev Function must be implemented by deriving contract
    * @param _hash Arbitrary length data signed on the behalf of address(this)
    * @param _signature Signature byte array associated with _data
    * @return A bytes4 magic value 0x20c13b0b if the signature check passes, 0x00000000 if not
    *
    * MUST NOT modify state (using STATICCALL for solc < 0.5, view modifier for solc > 0.5)
    * MUST allow external calls
    */
    function isValidSignature(bytes32 _hash, bytes memory _signature) public view returns (bytes4);

    function returnIsValidSignatureMagicNumber(bool isValid) internal pure returns (bytes4) {
        return isValid ? ERC1271_RETURN_VALID_SIGNATURE : ERC1271_RETURN_INVALID_SIGNATURE;
    }
}


contract ERC1271Bytes is ERC1271 {
    /**
    * @dev Default behavior of `isValidSignature(bytes,bytes)`, can be overloaded for custom validation
    * @param _data Arbitrary length data signed on the behalf of address(this)
    * @param _signature Signature byte array associated with _data
    * @return A bytes4 magic value 0x20c13b0b if the signature check passes, 0x00000000 if not
    *
    * MUST NOT modify state (using STATICCALL for solc < 0.5, view modifier for solc > 0.5)
    * MUST allow external calls
    */
    function isValidSignature(bytes _data, bytes _signature) public view returns (bytes4) {
        return isValidSignature(keccak256(_data), _signature);
    }
}

pragma solidity 0.4.24;


interface IERC721Receiver {
    /**
     * @notice Handle the receipt of an NFT
     * @dev The ERC721 smart contract calls this function on the recipient
     * after a {IERC721-safeTransferFrom}. This function MUST return the function selector,
     * otherwise the caller will revert the transaction. The selector to be
     * returned can be obtained as `this.onERC721Received.selector`. This
     * function MAY throw to revert and reject the transfer.
     * Note: the ERC721 contract address is always the message sender.
     * @param operator The address which called `safeTransferFrom` function
     * @param from The address which previously owned the token
     * @param tokenId The NFT identifier which is being transferred
     * @param data Additional data with no specified format
     * @return bytes4 `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
     */
    function onERC721Received(address operator, address from, uint256 tokenId, bytes data) external returns (bytes4);
}

pragma solidity 0.4.24;

import "./UnstructuredStorage.sol";


contract DepositableStorage {
    using UnstructuredStorage for bytes32;

    // keccak256("aragonOS.depositableStorage.depositable")
    bytes32 internal constant DEPOSITABLE_POSITION = 0x665fd576fbbe6f247aff98f5c94a561e3f71ec2d3c988d56f12d342396c50cea;

    function isDepositable() public view returns (bool) {
        return DEPOSITABLE_POSITION.getStorageBool();
    }

    function setDepositable(bool _depositable) internal {
        DEPOSITABLE_POSITION.setStorageBool(_depositable);
    }
}

pragma solidity ^0.4.0;


interface IPublicResolver {
    function supportsInterface(bytes4 interfaceID) constant returns (bool);
    function addr(bytes32 node) constant returns (address ret);
    function setAddr(bytes32 node, address addr);
    function hash(bytes32 node) constant returns (bytes32 ret);
    function setHash(bytes32 node, bytes32 hash);
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


interface IACLOracle {
    function canPerform(address who, address where, bytes32 what, uint256[] how) external view returns (bool);
}

pragma solidity 0.4.24;


contract KernelStorage {
    // namespace => app id => address
    mapping (bytes32 => mapping (bytes32 => address)) public apps;
    bytes32 public recoveryVaultAppId;
}

pragma solidity 0.4.24;

import "../apps/AppProxyUpgradeable.sol";
import "../apps/AppProxyPinned.sol";


contract AppProxyFactory {
    event NewAppProxy(address proxy, bool isUpgradeable, bytes32 appId);

    /**
    * @notice Create a new upgradeable app instance on `_kernel` with identifier `_appId`
    * @param _kernel App's Kernel reference
    * @param _appId Identifier for app
    * @return AppProxyUpgradeable
    */
    function newAppProxy(IKernel _kernel, bytes32 _appId) public returns (AppProxyUpgradeable) {
        return newAppProxy(_kernel, _appId, new bytes(0));
    }

    /**
    * @notice Create a new upgradeable app instance on `_kernel` with identifier `_appId` and initialization payload `_initializePayload`
    * @param _kernel App's Kernel reference
    * @param _appId Identifier for app
    * @return AppProxyUpgradeable
    */
    function newAppProxy(IKernel _kernel, bytes32 _appId, bytes _initializePayload) public returns (AppProxyUpgradeable) {
        AppProxyUpgradeable proxy = new AppProxyUpgradeable(_kernel, _appId, _initializePayload);
        emit NewAppProxy(address(proxy), true, _appId);
        return proxy;
    }

    /**
    * @notice Create a new pinned app instance on `_kernel` with identifier `_appId`
    * @param _kernel App's Kernel reference
    * @param _appId Identifier for app
    * @return AppProxyPinned
    */
    function newAppProxyPinned(IKernel _kernel, bytes32 _appId) public returns (AppProxyPinned) {
        return newAppProxyPinned(_kernel, _appId, new bytes(0));
    }

    /**
    * @notice Create a new pinned app instance on `_kernel` with identifier `_appId` and initialization payload `_initializePayload`
    * @param _kernel App's Kernel reference
    * @param _appId Identifier for app
    * @param _initializePayload Proxy initialization payload
    * @return AppProxyPinned
    */
    function newAppProxyPinned(IKernel _kernel, bytes32 _appId, bytes _initializePayload) public returns (AppProxyPinned) {
        AppProxyPinned proxy = new AppProxyPinned(_kernel, _appId, _initializePayload);
        emit NewAppProxy(address(proxy), false, _appId);
        return proxy;
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


contract ERCProxy {
    uint256 internal constant FORWARDING = 1;
    uint256 internal constant UPGRADEABLE = 2;

    function proxyType() public pure returns (uint256 proxyTypeId);
    function implementation() public view returns (address codeAddr);
}

pragma solidity 0.4.24;

import "../common/UnstructuredStorage.sol";
import "../common/IsContract.sol";
import "./AppProxyBase.sol";


contract AppProxyPinned is IsContract, AppProxyBase {
    using UnstructuredStorage for bytes32;

    // keccak256("aragonOS.appStorage.pinnedCode")
    bytes32 internal constant PINNED_CODE_POSITION = 0xdee64df20d65e53d7f51cb6ab6d921a0a6a638a91e942e1d8d02df28e31c038e;

    /**
    * @dev Initialize AppProxyPinned (makes it an un-upgradeable Aragon app)
    * @param _kernel Reference to organization kernel for the app
    * @param _appId Identifier for app
    * @param _initializePayload Payload for call to be made after setup to initialize
    */
    constructor(IKernel _kernel, bytes32 _appId, bytes _initializePayload)
        AppProxyBase(_kernel, _appId, _initializePayload)
        public // solium-disable-line visibility-first
    {
        setPinnedCode(getAppBase(_appId));
        require(isContract(pinnedCode()));
    }

    /**
     * @dev ERC897, the address the proxy would delegate calls to
     */
    function implementation() public view returns (address) {
        return pinnedCode();
    }

    /**
     * @dev ERC897, whether it is a forwarding (1) or an upgradeable (2) proxy
     */
    function proxyType() public pure returns (uint256 proxyTypeId) {
        return FORWARDING;
    }

    function setPinnedCode(address _pinnedCode) internal {
        PINNED_CODE_POSITION.setStorageAddress(_pinnedCode);
    }

    function pinnedCode() internal view returns (address) {
        return PINNED_CODE_POSITION.getStorageAddress();
    }
}

pragma solidity 0.4.24;

import "./AppProxyBase.sol";


contract AppProxyUpgradeable is AppProxyBase {
    /**
    * @dev Initialize AppProxyUpgradeable (makes it an upgradeable Aragon app)
    * @param _kernel Reference to organization kernel for the app
    * @param _appId Identifier for app
    * @param _initializePayload Payload for call to be made after setup to initialize
    */
    constructor(IKernel _kernel, bytes32 _appId, bytes _initializePayload)
        AppProxyBase(_kernel, _appId, _initializePayload)
        public // solium-disable-line visibility-first
    {
        // solium-disable-previous-line no-empty-blocks
    }

    /**
     * @dev ERC897, the address the proxy would delegate calls to
     */
    function implementation() public view returns (address) {
        return getAppBase(appId());
    }

    /**
     * @dev ERC897, whether it is a forwarding (1) or an upgradeable (2) proxy
     */
    function proxyType() public pure returns (uint256 proxyTypeId) {
        return UPGRADEABLE;
    }
}

pragma solidity 0.4.24;

import "./AppStorage.sol";
import "../common/DepositableDelegateProxy.sol";
import "../kernel/KernelConstants.sol";
import "../kernel/IKernel.sol";


contract AppProxyBase is AppStorage, DepositableDelegateProxy, KernelNamespaceConstants {
    /**
    * @dev Initialize AppProxy
    * @param _kernel Reference to organization kernel for the app
    * @param _appId Identifier for app
    * @param _initializePayload Payload for call to be made after setup to initialize
    */
    constructor(IKernel _kernel, bytes32 _appId, bytes _initializePayload) public {
        setKernel(_kernel);
        setAppId(_appId);

        // Implicit check that kernel is actually a Kernel
        // The EVM doesn't actually provide a way for us to make sure, but we can force a revert to
        // occur if the kernel is set to 0x0 or a non-code address when we try to call a method on
        // it.
        address appCode = getAppBase(_appId);

        // If initialize payload is provided, it will be executed
        if (_initializePayload.length > 0) {
            require(isContract(appCode));
            // Cannot make delegatecall as a delegateproxy.delegatedFwd as it
            // returns ending execution context and halts contract deployment
            require(appCode.delegatecall(_initializePayload));
        }
    }

    function getAppBase(bytes32 _appId) internal view returns (address) {
        return kernel().getApp(KERNEL_APP_BASES_NAMESPACE, _appId);
    }
}

pragma solidity 0.4.24;

import "./DelegateProxy.sol";
import "./DepositableStorage.sol";


contract DepositableDelegateProxy is DepositableStorage, DelegateProxy {
    event ProxyDeposit(address sender, uint256 value);

    function () external payable {
        uint256 forwardGasThreshold = FWD_GAS_LIMIT;
        bytes32 isDepositablePosition = DEPOSITABLE_POSITION;

        // Optimized assembly implementation to prevent EIP-1884 from breaking deposits, reference code in Solidity:
        // https://github.com/aragon/aragonOS/blob/v4.2.1/contracts/common/DepositableDelegateProxy.sol#L10-L20
        assembly {
            // Continue only if the gas left is lower than the threshold for forwarding to the implementation code,
            // otherwise continue outside of the assembly block.
            if lt(gas, forwardGasThreshold) {
                // Only accept the deposit and emit an event if all of the following are true:
                // the proxy accepts deposits (isDepositable), msg.data.length == 0, and msg.value > 0
                if and(and(sload(isDepositablePosition), iszero(calldatasize)), gt(callvalue, 0)) {
                    // Equivalent Solidity code for emitting the event:
                    // emit ProxyDeposit(msg.sender, msg.value);

                    let logData := mload(0x40) // free memory pointer
                    mstore(logData, caller) // add 'msg.sender' to the log data (first event param)
                    mstore(add(logData, 0x20), callvalue) // add 'msg.value' to the log data (second event param)

                    // Emit an event with one topic to identify the event: keccak256('ProxyDeposit(address,uint256)') = 0x15ee...dee1
                    log1(logData, 0x40, 0x15eeaa57c7bd188c1388020bcadc2c436ec60d647d36ef5b9eb3c742217ddee1)

                    stop() // Stop. Exits execution context
                }

                // If any of above checks failed, revert the execution (if ETH was sent, it is returned to the sender)
                revert(0, 0)
            }
        }

        address target = implementation();
        delegatedFwd(target, msg.data);
    }
}

pragma solidity 0.4.24;

import "../common/IsContract.sol";
import "../lib/misc/ERCProxy.sol";


contract DelegateProxy is ERCProxy, IsContract {
    uint256 internal constant FWD_GAS_LIMIT = 10000;

    /**
    * @dev Performs a delegatecall and returns whatever the delegatecall returned (entire context execution will return!)
    * @param _dst Destination address to perform the delegatecall
    * @param _calldata Calldata for the delegatecall
    */
    function delegatedFwd(address _dst, bytes _calldata) internal {
        require(isContract(_dst));
        uint256 fwdGasLimit = FWD_GAS_LIMIT;

        assembly {
            let result := delegatecall(sub(gas, fwdGasLimit), _dst, add(_calldata, 0x20), mload(_calldata), 0, 0)
            let size := returndatasize
            let ptr := mload(0x40)
            returndatacopy(ptr, 0, size)

            // revert instead of invalid() bc if the underlying call failed with invalid() it already wasted gas.
            // if the call returned error data, forward it
            switch result case 0 { revert(ptr, size) }
            default { return(ptr, size) }
        }
    }
}

pragma solidity 0.4.24;

import "../evmscript/IEVMScriptExecutor.sol";
import "../evmscript/EVMScriptRegistry.sol";

import "../evmscript/executors/CallsScript.sol";

import "../kernel/Kernel.sol";
import "../acl/ACL.sol";


contract EVMScriptRegistryFactory is EVMScriptRegistryConstants {
    EVMScriptRegistry public baseReg;
    IEVMScriptExecutor public baseCallScript;

    /**
    * @notice Create a new EVMScriptRegistryFactory.
    */
    constructor() public {
        baseReg = new EVMScriptRegistry();
        baseCallScript = IEVMScriptExecutor(new CallsScript());
    }

    /**
    * @notice Install a new pinned instance of EVMScriptRegistry on `_dao`.
    * @param _dao Kernel
    * @return Installed EVMScriptRegistry
    */
    function newEVMScriptRegistry(Kernel _dao) public returns (EVMScriptRegistry reg) {
        bytes memory initPayload = abi.encodeWithSelector(reg.initialize.selector);
        reg = EVMScriptRegistry(_dao.newPinnedAppInstance(EVMSCRIPT_REGISTRY_APP_ID, baseReg, initPayload, true));

        ACL acl = ACL(_dao.acl());

        acl.createPermission(this, reg, reg.REGISTRY_ADD_EXECUTOR_ROLE(), this);

        reg.addScriptExecutor(baseCallScript);     // spec 1 = CallsScript

        // Clean up the permissions
        acl.revokePermission(this, reg, reg.REGISTRY_ADD_EXECUTOR_ROLE());
        acl.removePermissionManager(reg, reg.REGISTRY_ADD_EXECUTOR_ROLE());

        return reg;
    }
}

pragma solidity 0.4.24;

import "./IKernel.sol";
import "./KernelConstants.sol";
import "./KernelStorage.sol";
import "../common/DepositableDelegateProxy.sol";
import "../common/IsContract.sol";


contract KernelProxy is IKernelEvents, KernelStorage, KernelAppIds, KernelNamespaceConstants, IsContract, DepositableDelegateProxy {
    /**
    * @dev KernelProxy is a proxy contract to a kernel implementation. The implementation
    *      can update the reference, which effectively upgrades the contract
    * @param _kernelImpl Address of the contract used as implementation for kernel
    */
    constructor(IKernel _kernelImpl) public {
        require(isContract(address(_kernelImpl)));
        apps[KERNEL_CORE_NAMESPACE][KERNEL_CORE_APP_ID] = _kernelImpl;

        // Note that emitting this event is important for verifying that a KernelProxy instance
        // was never upgraded to a malicious Kernel logic contract over its lifespan.
        // This starts the "chain of trust", that can be followed through later SetApp() events
        // emitted during kernel upgrades.
        emit SetApp(KERNEL_CORE_NAMESPACE, KERNEL_CORE_APP_ID, _kernelImpl);
    }

    /**
     * @dev ERC897, whether it is a forwarding (1) or an upgradeable (2) proxy
     */
    function proxyType() public pure returns (uint256 proxyTypeId) {
        return UPGRADEABLE;
    }

    /**
    * @dev ERC897, the address the proxy would delegate calls to
    */
    function implementation() public view returns (address) {
        return apps[KERNEL_CORE_NAMESPACE][KERNEL_CORE_APP_ID];
    }
}

pragma solidity 0.4.24;

import "../apps/AragonApp.sol";
import "./ScriptHelpers.sol";
import "./IEVMScriptExecutor.sol";
import "./IEVMScriptRegistry.sol";


/* solium-disable function-order */
// Allow public initialize() to be first
contract EVMScriptRegistry is IEVMScriptRegistry, EVMScriptRegistryConstants, AragonApp {
    using ScriptHelpers for bytes;

    /* Hardcoded constants to save gas
    bytes32 public constant REGISTRY_ADD_EXECUTOR_ROLE = keccak256("REGISTRY_ADD_EXECUTOR_ROLE");
    bytes32 public constant REGISTRY_MANAGER_ROLE = keccak256("REGISTRY_MANAGER_ROLE");
    */
    bytes32 public constant REGISTRY_ADD_EXECUTOR_ROLE = 0xc4e90f38eea8c4212a009ca7b8947943ba4d4a58d19b683417f65291d1cd9ed2;
    // WARN: Manager can censor all votes and the like happening in an org
    bytes32 public constant REGISTRY_MANAGER_ROLE = 0xf7a450ef335e1892cb42c8ca72e7242359d7711924b75db5717410da3f614aa3;

    uint256 internal constant SCRIPT_START_LOCATION = 4;

    string private constant ERROR_INEXISTENT_EXECUTOR = "EVMREG_INEXISTENT_EXECUTOR";
    string private constant ERROR_EXECUTOR_ENABLED = "EVMREG_EXECUTOR_ENABLED";
    string private constant ERROR_EXECUTOR_DISABLED = "EVMREG_EXECUTOR_DISABLED";
    string private constant ERROR_SCRIPT_LENGTH_TOO_SHORT = "EVMREG_SCRIPT_LENGTH_TOO_SHORT";

    struct ExecutorEntry {
        IEVMScriptExecutor executor;
        bool enabled;
    }

    uint256 private executorsNextIndex;
    mapping (uint256 => ExecutorEntry) public executors;

    event EnableExecutor(uint256 indexed executorId, address indexed executorAddress);
    event DisableExecutor(uint256 indexed executorId, address indexed executorAddress);

    modifier executorExists(uint256 _executorId) {
        require(_executorId > 0 && _executorId < executorsNextIndex, ERROR_INEXISTENT_EXECUTOR);
        _;
    }

    /**
    * @notice Initialize the registry
    */
    function initialize() public onlyInit {
        initialized();
        // Create empty record to begin executor IDs at 1
        executorsNextIndex = 1;
    }

    /**
    * @notice Add a new script executor with address `_executor` to the registry
    * @param _executor Address of the IEVMScriptExecutor that will be added to the registry
    * @return id Identifier of the executor in the registry
    */
    function addScriptExecutor(IEVMScriptExecutor _executor) external auth(REGISTRY_ADD_EXECUTOR_ROLE) returns (uint256 id) {
        uint256 executorId = executorsNextIndex++;
        executors[executorId] = ExecutorEntry(_executor, true);
        emit EnableExecutor(executorId, _executor);
        return executorId;
    }

    /**
    * @notice Disable script executor with ID `_executorId`
    * @param _executorId Identifier of the executor in the registry
    */
    function disableScriptExecutor(uint256 _executorId)
        external
        authP(REGISTRY_MANAGER_ROLE, arr(_executorId))
    {
        // Note that we don't need to check for an executor's existence in this case, as only
        // existing executors can be enabled
        ExecutorEntry storage executorEntry = executors[_executorId];
        require(executorEntry.enabled, ERROR_EXECUTOR_DISABLED);
        executorEntry.enabled = false;
        emit DisableExecutor(_executorId, executorEntry.executor);
    }

    /**
    * @notice Enable script executor with ID `_executorId`
    * @param _executorId Identifier of the executor in the registry
    */
    function enableScriptExecutor(uint256 _executorId)
        external
        authP(REGISTRY_MANAGER_ROLE, arr(_executorId))
        executorExists(_executorId)
    {
        ExecutorEntry storage executorEntry = executors[_executorId];
        require(!executorEntry.enabled, ERROR_EXECUTOR_ENABLED);
        executorEntry.enabled = true;
        emit EnableExecutor(_executorId, executorEntry.executor);
    }

    /**
    * @dev Get the script executor that can execute a particular script based on its first 4 bytes
    * @param _script EVMScript being inspected
    */
    function getScriptExecutor(bytes _script) public view returns (IEVMScriptExecutor) {
        require(_script.length >= SCRIPT_START_LOCATION, ERROR_SCRIPT_LENGTH_TOO_SHORT);
        uint256 id = _script.getSpecId();

        // Note that we don't need to check for an executor's existence in this case, as only
        // existing executors can be enabled
        ExecutorEntry storage entry = executors[id];
        return entry.enabled ? entry.executor : IEVMScriptExecutor(0);
    }
}

pragma solidity 0.4.24;

// Inspired by https://github.com/reverendus/tx-manager

import "../ScriptHelpers.sol";
import "./BaseEVMScriptExecutor.sol";


contract CallsScript is BaseEVMScriptExecutor {
    using ScriptHelpers for bytes;

    /* Hardcoded constants to save gas
    bytes32 internal constant EXECUTOR_TYPE = keccak256("CALLS_SCRIPT");
    */
    bytes32 internal constant EXECUTOR_TYPE = 0x2dc858a00f3e417be1394b87c07158e989ec681ce8cc68a9093680ac1a870302;

    string private constant ERROR_BLACKLISTED_CALL = "EVMCALLS_BLACKLISTED_CALL";
    string private constant ERROR_INVALID_LENGTH = "EVMCALLS_INVALID_LENGTH";

    /* This is manually crafted in assembly
    string private constant ERROR_CALL_REVERTED = "EVMCALLS_CALL_REVERTED";
    */

    event LogScriptCall(address indexed sender, address indexed src, address indexed dst);

    /**
    * @notice Executes a number of call scripts
    * @param _script [ specId (uint32) ] many calls with this structure ->
    *    [ to (address: 20 bytes) ] [ calldataLength (uint32: 4 bytes) ] [ calldata (calldataLength bytes) ]
    * @param _blacklist Addresses the script cannot call to, or will revert.
    * @return Always returns empty byte array
    */
    function execScript(bytes _script, bytes, address[] _blacklist) external isInitialized returns (bytes) {
        uint256 location = SCRIPT_START_LOCATION; // first 32 bits are spec id
        while (location < _script.length) {
            // Check there's at least address + calldataLength available
            require(_script.length - location >= 0x18, ERROR_INVALID_LENGTH);

            address contractAddress = _script.addressAt(location);
            // Check address being called is not blacklist
            for (uint256 i = 0; i < _blacklist.length; i++) {
                require(contractAddress != _blacklist[i], ERROR_BLACKLISTED_CALL);
            }

            // logged before execution to ensure event ordering in receipt
            // if failed entire execution is reverted regardless
            emit LogScriptCall(msg.sender, address(this), contractAddress);

            uint256 calldataLength = uint256(_script.uint32At(location + 0x14));
            uint256 startOffset = location + 0x14 + 0x04;
            uint256 calldataStart = _script.locationOf(startOffset);

            // compute end of script / next location
            location = startOffset + calldataLength;
            require(location <= _script.length, ERROR_INVALID_LENGTH);

            bool success;
            assembly {
                success := call(
                    sub(gas, 5000),       // forward gas left - 5000
                    contractAddress,      // address
                    0,                    // no value
                    calldataStart,        // calldata start
                    calldataLength,       // calldata length
                    0,                    // don't write output
                    0                     // don't write output
                )

                switch success
                case 0 {
                    let ptr := mload(0x40)

                    switch returndatasize
                    case 0 {
                        // No error data was returned, revert with "EVMCALLS_CALL_REVERTED"
                        // See remix: doing a `revert("EVMCALLS_CALL_REVERTED")` always results in
                        // this memory layout
                        mstore(ptr, 0x08c379a000000000000000000000000000000000000000000000000000000000)         // error identifier
                        mstore(add(ptr, 0x04), 0x0000000000000000000000000000000000000000000000000000000000000020) // starting offset
                        mstore(add(ptr, 0x24), 0x0000000000000000000000000000000000000000000000000000000000000016) // reason length
                        mstore(add(ptr, 0x44), 0x45564d43414c4c535f43414c4c5f524556455254454400000000000000000000) // reason

                        revert(ptr, 100) // 100 = 4 + 3 * 32 (error identifier + 3 words for the ABI encoded error)
                    }
                    default {
                        // Forward the full error data
                        returndatacopy(ptr, 0, returndatasize)
                        revert(ptr, returndatasize)
                    }
                }
                default { }
            }
        }
        // No need to allocate empty bytes for the return as this can only be called via an delegatecall
        // (due to the isInitialized modifier)
    }

    function executorType() external pure returns (bytes32) {
        return EXECUTOR_TYPE;
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;


library ScriptHelpers {
    function getSpecId(bytes _script) internal pure returns (uint32) {
        return uint32At(_script, 0);
    }

    function uint256At(bytes _data, uint256 _location) internal pure returns (uint256 result) {
        assembly {
            result := mload(add(_data, add(0x20, _location)))
        }
    }

    function addressAt(bytes _data, uint256 _location) internal pure returns (address result) {
        uint256 word = uint256At(_data, _location);

        assembly {
            result := div(and(word, 0xffffffffffffffffffffffffffffffffffffffff000000000000000000000000),
            0x1000000000000000000000000)
        }
    }

    function uint32At(bytes _data, uint256 _location) internal pure returns (uint32 result) {
        uint256 word = uint256At(_data, _location);

        assembly {
            result := div(and(word, 0xffffffff00000000000000000000000000000000000000000000000000000000),
            0x100000000000000000000000000000000000000000000000000000000)
        }
    }

    function locationOf(bytes _data, uint256 _location) internal pure returns (uint256 result) {
        assembly {
            result := add(_data, add(0x20, _location))
        }
    }

    function toBytes(bytes4 _sig) internal pure returns (bytes) {
        bytes memory payload = new bytes(4);
        assembly { mstore(add(payload, 0x20), _sig) }
        return payload;
    }
}

/*
 * SPDX-License-Identifier:    MIT
 */

pragma solidity ^0.4.24;

import "../../common/Autopetrified.sol";
import "../IEVMScriptExecutor.sol";


contract BaseEVMScriptExecutor is IEVMScriptExecutor, Autopetrified {
    uint256 internal constant SCRIPT_START_LOCATION = 4;
}

// See https://github.com/ensdomains/ens/blob/7e377df83f/contracts/AbstractENS.sol

pragma solidity ^0.4.15;


interface AbstractENS {
    function owner(bytes32 _node) public constant returns (address);
    function resolver(bytes32 _node) public constant returns (address);
    function ttl(bytes32 _node) public constant returns (uint64);
    function setOwner(bytes32 _node, address _owner) public;
    function setSubnodeOwner(bytes32 _node, bytes32 label, address _owner) public;
    function setResolver(bytes32 _node, address _resolver) public;
    function setTTL(bytes32 _node, uint64 _ttl) public;

    // Logged when the owner of a node assigns a new owner to a subnode.
    event NewOwner(bytes32 indexed _node, bytes32 indexed _label, address _owner);

    // Logged when the owner of a node transfers ownership to a new account.
    event Transfer(bytes32 indexed _node, address _owner);

    // Logged when the resolver for a node changes.
    event NewResolver(bytes32 indexed _node, address _resolver);

    // Logged when the TTL of a node changes
    event NewTTL(bytes32 indexed _node, uint64 _ttl);
}