// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "./PartyInitializable.sol";
import "./PartyStorage.sol";

// Interfaces
import "./interfaces/IParty.sol";

// Libraries
import "./libraries/Announcements.sol";
import "./libraries/JoinRequests.sol";
import "./libraries/AddressArrayLib.sol";
import "./libraries/SharedStructs.sol";
import "./libraries/SignatureHelpers.sol";

// @openzeppelin/contracts
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

error NotMember(); // "User is not a member"
error AlreadyMember(); // "User is already a member"
error DepositNotEnough(); // "Deposit is not enough"
error DepositExceeded(); // "Deposit exceeds maximum required"
error PartyClosed(); // "Party is closed"
error UserBalanceNotEnough(); // "User balance is not enough"
error OwnerNotKickable(); // "Cannot kick yourself"
error FailedAproveReset(); // "Failed approve reset"
error FailedAprove(); // "Failed approving sellToken"
error ZeroXFail(); // "SWAP_CALL_FAILED"
error InvalidSignature(); // "Invalid approval signature"
error InvalidSwap(); // "Only one swap at a time"
error AlreadyRequested(); // "User has already requested to join"
error AlreadyHandled(); // "Request already handled"
error NeedsInvitation(); // "User needs invitation to join private party"
error IsZeroAddress(); // "Address cannot be zero address"
error OneInchCallFailed(); // "Call to method failed"
error Invalid1nchSource(); // "Invalid 1nch source"
error InvalidLimitOrderFill(); // "Invalid 1nch limit order filled maker"

address constant LIMIT_ORDER_PROTOCOL_1NCH = 0x94Bc2a1C732BcAd7343B25af48385Fe76E08734f; // 1nch Polygon LimitOrderProtocol

contract Party is PartyInitializable, PartyStorage, IParty {
    /***************
    EVENTS
    ***************/
    /// @dev inherited from IPartyEvents

    /***************
    MODIFIERS
    ***************/
    function _onlyMember() internal view {
        if (!members[msg.sender]) revert NotMember();
    }

    modifier onlyMember() {
        _onlyMember();
        _;
    }

    function _notMember() internal view {
        if (members[msg.sender]) revert AlreadyMember();
    }

    modifier notMember() {
        _notMember();
        _;
    }

    function _isAlive() internal view {
        if (closed) revert PartyClosed();
    }

    modifier isAlive() {
        _isAlive();
        _;
    }

    /***************
    INITIALIZATION
    ***************/
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /**
     * @notice Creates a party
     * @dev Called by the PartyFactory after minimal cloning the new party
     * @param _creator The address of the party creator
     * @param _partyInfo Struct that contains the party information
     * @param _tokenSymbol The Party Token symbol
     * @param _initialDeposit The initial deposit of the creator
     * @param _denominationAsset The address of the denomination asset
     * @param _collector The address of the platform fee collector
     * @param _sentinel The address of the platform sentinel
     */
    function initialize(
        address _creator,
        SharedStructs.PartyInfo memory _partyInfo,
        string memory _tokenSymbol,
        uint256 _initialDeposit,
        address _denominationAsset,
        address _collector,
        address _sentinel
    ) external payable initializer {
        if (_denominationAsset == address(0)) revert IsZeroAddress();
        // Init functions
        __ERC20_init(_partyInfo.name, _tokenSymbol);
        __ERC20Burnable_init();
        __ReentrancyGuard_init();
        __Ownable_init();

        // Party ownership
        transferOwnership(_creator);

        // Platform
        PLATFORM_ADDRESS = _collector;
        PLATFORM_SENTINEL = _sentinel;
        PLATFORM_FACTORY = msg.sender;

        // Party info
        partyInfo = _partyInfo;

        // Set DA token
        denominationAsset = _denominationAsset;
        tokens.push(denominationAsset);

        // Add member
        members[_creator] = true;

        // Mint Party tokens
        uint256 mintedPT = _initialDeposit *
            10**(decimals() - IERC20Metadata(_denominationAsset).decimals());
        _mint(_creator, mintedPT);

        // Emit PartyCreated event
        emit PartyCreated(
            _creator,
            partyInfo.name,
            partyInfo.isPublic,
            denominationAsset,
            partyInfo.minDeposit,
            partyInfo.maxDeposit,
            mintedPT,
            partyInfo.bio,
            partyInfo.img,
            partyInfo.model,
            partyInfo.purpose
        );
    }

    /***************
    OVERRIDES
    ***************/
    function transfer(address, uint256) public pure override returns (bool) {
        revert("GT: transfer is prohibited");
    }

    function transferFrom(
        address,
        address,
        uint256
    ) public pure override returns (bool) {
        revert("GT: transferFrom is prohibited");
    }

    /***************
    PARTY FUNCTIONS
    ***************/
    /// @inheritdoc IPartyActions
    function joinParty(
        uint256 amount,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval
    ) external payable override notMember nonReentrant isAlive {
        // Handle request for private parties
        if (!partyInfo.isPublic) {
            if (!joinRequests.accepted[msg.sender]) {
                revert NeedsInvitation();
            }
            delete joinRequests.accepted[msg.sender];
        }
        // Add user as member
        members[msg.sender] = true;

        // Deposit, collect fees and mint party tokens
        (uint256 fee, uint256 mintedPT) = mintPartyTokens(
            amount,
            allocation,
            approval
        );

        // Emit Join event
        emit Join(msg.sender, denominationAsset, amount, fee, mintedPT);
    }

    /// @inheritdoc IPartyMemberActions
    function deposit(
        uint256 amount,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval
    ) external payable override onlyMember nonReentrant isAlive {
        // Deposit, collect fees and mint party tokens
        (uint256 fee, uint256 mintedPT) = mintPartyTokens(
            amount,
            allocation,
            approval
        );

        // Emit Deposit event
        emit Deposit(msg.sender, denominationAsset, amount, fee, mintedPT);
    }

    /// @inheritdoc IPartyMemberActions
    function withdraw(
        uint256 amountPT,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval,
        bool liquidate
    ) external payable override onlyMember nonReentrant {
        // Withdraw, collect fees and burn party tokens
        redeemPartyTokens(
            amountPT,
            msg.sender,
            allocation,
            approval,
            liquidate
        );

        // Emit Withdraw event
        emit Withdraw(msg.sender, amountPT);
    }

    /// @inheritdoc IPartyOwnerActions
    function swapToken(
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval
    ) external payable override onlyOwner nonReentrant {
        if (allocation.sellTokens.length != 1) revert InvalidSwap();

        // -> Validate authenticity of assets allocation
        if (
            !SignatureHelpers.isValidAllocation(
                PLATFORM_SENTINEL,
                allocation,
                approval
            )
        ) {
            revert InvalidSignature();
        }

        // Fill 0x Quote
        SharedStructs.FilledQuote memory filledQuote = fillQuote(
            allocation.sellTokens[0],
            allocation.sellAmounts[0],
            allocation.buyTokens[0],
            allocation.spenders[0],
            allocation.swapsTargets[0],
            allocation.swapsCallData[0]
        );

        // Collect fees
        uint256 fee = collectPlatformFee(
            filledQuote.boughtAmount,
            allocation.buyTokens[0]
        );

        // Check if bought asset is new
        if (!AddressArrayLib.contains(tokens, allocation.buyTokens[0])) {
            // Adding new asset to list
            tokens.push(allocation.buyTokens[0]);
        }

        // Emit SwapToken event
        emit SwapToken(
            msg.sender,
            address(allocation.sellTokens[0]),
            address(allocation.buyTokens[0]),
            filledQuote.soldAmount,
            filledQuote.boughtAmount,
            fee
        );
    }

    /// @inheritdoc IPartyOwnerActions
    function kickMember(
        address kickingMember,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval,
        bool liquidate
    ) external payable override onlyOwner nonReentrant {
        if (kickingMember == msg.sender) revert OwnerNotKickable();

        // Get total PT from kicking member
        uint256 kickingMemberPT = balanceOf(kickingMember);
        redeemPartyTokens(
            kickingMemberPT,
            kickingMember,
            allocation,
            approval,
            liquidate
        );

        // Remove user as a member
        delete members[kickingMember];

        // Emit Kick event
        emit Kick(msg.sender, kickingMember, kickingMemberPT);
    }

    /// @inheritdoc IPartyMemberActions
    function leaveParty(
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval,
        bool liquidate
    ) external payable override onlyMember nonReentrant {
        // Get total PT from member
        uint256 leavingMemberPT = balanceOf(msg.sender);
        redeemPartyTokens(
            leavingMemberPT,
            msg.sender,
            allocation,
            approval,
            liquidate
        );

        // Remove user as a member
        delete members[msg.sender];

        // Emit Leave event
        emit Leave(msg.sender, leavingMemberPT);
    }

    /// @inheritdoc IPartyOwnerActions
    function closeParty() external payable override onlyOwner isAlive {
        closed = true;
        // Emit Close event
        emit Close(msg.sender, totalSupply());
    }

    /// @inheritdoc IPartyOwnerActions
    function approveLimitOrder(address sellToken, uint256 sellAmount)
        external
        override
    {
        // Execute 1nch cancelOrder method
        IERC20Metadata(sellToken).approve(
            LIMIT_ORDER_PROTOCOL_1NCH,
            sellAmount
        );
    }

    /// @inheritdoc IPartyOwnerActions
    function cancelLimitOrder(SharedStructs.LimitOrder memory order)
        external
        override
    {
        // Execute 1nch cancelOrder method
        (bool success, ) = LIMIT_ORDER_PROTOCOL_1NCH.call(
            abi.encodeWithSignature(
                "cancelOrder((uint256,address,address,address,address,address,uint256,uint256,bytes,bytes,bytes,bytes,bytes,bytes,bytes))",
                order
            )
        );
        if (!success) revert OneInchCallFailed();
    }

    /// @inheritdoc IPartyActions
    function notifyFillOrder(
        address taker,
        address makerAsset,
        address takerAsset,
        uint256 makingAmount,
        uint256 takingAmount,
        bytes calldata interactiveData
    ) external override {
        if (msg.sender != LIMIT_ORDER_PROTOCOL_1NCH) revert Invalid1nchSource();
        address makerAddress;
        assembly {
            makerAddress := shr(96, calldataload(interactiveData.offset))
        }
        if (makerAddress != address(this)) revert InvalidLimitOrderFill();
        emit LimitOrderFilled(
            taker,
            makerAsset,
            takerAsset,
            makingAmount,
            takingAmount
        );
    }

    /// @inheritdoc IPartyActions
    function isValidSignature(bytes32 _hash, bytes calldata _signature)
        external
        view
        override
        returns (bytes4)
    {
        return SignatureHelpers.isValidSignature(owner(), _hash, _signature);
    }

    /***************
    PARTY TOKEN FUNCTIONS
    ***************/
    function mintPartyTokens(
        uint256 amountDA,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval
    ) private returns (uint256 fee, uint256 mintedPT) {
        // 1) Handle deposit amount is between min-max range
        if (amountDA < partyInfo.minDeposit) revert DepositNotEnough();
        if (partyInfo.maxDeposit > 0 && amountDA > partyInfo.maxDeposit)
            revert DepositExceeded();

        // 2) Calculate Platform Fee
        fee = getPlatformFee(amountDA);

        // 3) Transfer DA from user (deposit + fees)
        IERC20Metadata(denominationAsset).transferFrom(
            msg.sender,
            address(this),
            amountDA + fee
        );

        // 4) Collect protocol fees
        collectPlatformFee(amountDA, denominationAsset);

        // 5) Allocate deposit assets
        allocateAssets(msg.sender, allocation, approval);

        // 6) Mint PartyTokens to user
        uint256 totalSupply = totalSupply();
        if (totalSupply == 0 || allocation.partyTotalSupply == 0) {
            mintedPT =
                amountDA *
                10**(decimals() - IERC20Metadata(denominationAsset).decimals());
        } else {
            uint256 adjPartyValueDA = allocation.partyValueDA;
            /// Handle any totalSupply changes
            /// @dev Which will indicate the the allocated partyValueDA was updated in the same block by another tx
            if (allocation.partyTotalSupply != totalSupply) {
                // Since there has been a change in the totalSupply, we need to get the adjusted party value in DA
                /// @dev Example case:
                //          - allocation.totalSupply: 500
                //          - allocation.partyValueDA is 1000
                //          - totalSupply is 750
                //       This means that the current partyValueDA is no longer 1000, since there was a change in the totalSupply.
                //       The totalSupply delta is 50%. So the current partyValueDA should be 1500.
                adjPartyValueDA =
                    (adjPartyValueDA * totalSupply) /
                    allocation.partyTotalSupply;
            }
            mintedPT = (totalSupply * amountDA) / adjPartyValueDA;
        }
        _mint(msg.sender, mintedPT);
    }

    function redeemPartyTokens(
        uint256 amountPT,
        address _memberAddress,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval,
        bool liquidate
    ) private {
        // 1) Check if user has PartyTokens balance to redeem
        if (amountPT > balanceOf(_memberAddress)) revert UserBalanceNotEnough();

        // 2) Get the total supply of PartyTokens
        uint256 totalSupply = totalSupply();

        // 3) Burn PartyTokens
        _burn(_memberAddress, amountPT);

        if (amountPT > 0) {
            // 4) Handle holdings redemption: liquidate holdings or redeem as it is
            if (liquidate) {
                liquidateHoldings(
                    amountPT,
                    totalSupply,
                    _memberAddress,
                    allocation,
                    approval
                );
            } else {
                redeemHoldings(amountPT, totalSupply, _memberAddress);
            }
        }
    }

    /***************
    HELPER FUNCTIONS
    ***************/
    // Redeems assets without liquidating to DA
    function redeemHoldings(
        uint256 amountPT,
        uint256 totalSupply,
        address _memberAddress
    ) private {
        uint256[] memory redeemedAmounts = new uint256[](tokens.length);
        uint256[] memory redeemedFees = new uint256[](tokens.length);
        uint256[] memory redeemedNetAmounts = new uint256[](tokens.length);

        // 1) Handle token holdings
        for (uint256 i = 0; i < tokens.length; i++) {
            // 2) Get token amount to redeem
            uint256 tBalance = IERC20Metadata(tokens[i]).balanceOf(
                address(this)
            );
            redeemedAmounts[i] = ((tBalance * amountPT) / totalSupply);

            if (redeemedAmounts[i] > 0) {
                // 3) Collect fees
                redeemedFees[i] = collectPlatformFee(
                    redeemedAmounts[i],
                    tokens[i]
                );
                redeemedNetAmounts[i] = (redeemedAmounts[i] - redeemedFees[i]);

                // 4) Transfer relative asset funds to user
                IERC20Metadata(tokens[i]).transfer(
                    _memberAddress,
                    redeemedNetAmounts[i]
                );
            }
        }
        emit RedeemedShares(
            _memberAddress,
            amountPT,
            false,
            tokens,
            redeemedAmounts,
            redeemedFees,
            redeemedNetAmounts
        );
    }

    // Redeems assets by liquidating to DA
    function liquidateHoldings(
        uint256 amountPT,
        uint256 totalSupply,
        address _memberAddress,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval
    ) private {
        uint256[] memory redeemedAmounts = new uint256[](1);
        uint256[] memory redeemedFees = new uint256[](1);
        uint256[] memory redeemedNetAmounts = new uint256[](1);

        // 1) Get the portion of denomination asset to withdraw (before allocation)
        uint256 daBalance = IERC20Metadata(denominationAsset).balanceOf(
            address(this)
        );
        redeemedAmounts[0] = ((daBalance * amountPT) / totalSupply);

        // 2) Swap member's share of other assets into the denomination asset
        SharedStructs.Allocated memory allocated = allocateAssets(
            _memberAddress,
            allocation,
            approval
        );

        // 3) Iterate through allocation and accumulate pending withdrawal for the user
        for (uint256 i = 0; i < allocated.boughtAmounts.length; i++) {
            // Double check that bought tokens are same as DA
            if (allocated.buyTokens[i] == denominationAsset) {
                redeemedAmounts[0] += allocated.boughtAmounts[i];
            }
        }

        // 4) Collect fees
        redeemedFees[0] = collectPlatformFee(
            redeemedAmounts[0],
            denominationAsset
        );

        // 5) Transfer relative DA funds to user
        redeemedNetAmounts[0] = redeemedAmounts[0] - redeemedFees[0];
        IERC20Metadata(denominationAsset).transfer(
            _memberAddress,
            redeemedNetAmounts[0]
        );

        emit RedeemedShares(
            _memberAddress,
            amountPT,
            true,
            allocated.sellTokens,
            redeemedAmounts,
            redeemedFees,
            redeemedNetAmounts
        );
    }

    // Allocates multiple 0x quotes
    function allocateAssets(
        address sender,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval
    ) private returns (SharedStructs.Allocated memory allocated) {
        if (
            !SignatureHelpers.isValidAllocation(
                PLATFORM_SENTINEL,
                allocation,
                approval
            )
        ) {
            revert InvalidSignature();
        }

        // Declaring array with a known length
        allocated.sellTokens = new address[](allocation.sellTokens.length);
        allocated.buyTokens = new address[](allocation.sellTokens.length);
        allocated.soldAmounts = new uint256[](allocation.sellTokens.length);
        allocated.boughtAmounts = new uint256[](allocation.sellTokens.length);
        for (uint256 i = 0; i < allocation.sellTokens.length; i++) {
            SharedStructs.FilledQuote memory filledQuote = fillQuote(
                allocation.sellTokens[i],
                allocation.sellAmounts[i],
                allocation.buyTokens[i],
                allocation.spenders[i],
                allocation.swapsTargets[i],
                allocation.swapsCallData[i]
            );
            allocated.sellTokens[i] = address(allocation.sellTokens[i]);
            allocated.buyTokens[i] = address(allocation.buyTokens[i]);
            allocated.soldAmounts[i] = filledQuote.soldAmount;
            allocated.boughtAmounts[i] = filledQuote.boughtAmount;
        }

        // Emit AllocationFilled
        emit AllocationFilled(
            sender,
            allocated.sellTokens,
            allocated.buyTokens,
            allocated.soldAmounts,
            allocated.boughtAmounts,
            allocation.partyValueDA
        );
    }

    // Swap a token held by this contract using a 0x-API quote.
    function fillQuote(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        address spender,
        address payable swapTarget,
        bytes memory swapCallData
    ) private returns (SharedStructs.FilledQuote memory filledQuote) {
        if (!IERC20Metadata(sellToken).approve(spender, 0))
            revert FailedAproveReset();
        if (!IERC20Metadata(sellToken).approve(spender, sellAmount))
            revert FailedAprove();

        // Track initial balance of the sellToken to determine how much we've sold.
        filledQuote.initialSellBalance = IERC20Metadata(sellToken).balanceOf(
            address(this)
        );

        // Track initial balance of the buyToken to determine how much we've bought.
        filledQuote.initialBuyBalance = IERC20Metadata(buyToken).balanceOf(
            address(this)
        );
        // Execute 0xSwap
        (bool success, ) = swapTarget.call{value: msg.value}(swapCallData);
        if (!success) revert ZeroXFail();

        // Get how much we've sold.
        filledQuote.soldAmount =
            filledQuote.initialSellBalance -
            IERC20Metadata(sellToken).balanceOf(address(this));

        // Get how much we've bought.
        filledQuote.boughtAmount =
            IERC20Metadata(buyToken).balanceOf(address(this)) -
            filledQuote.initialBuyBalance;
    }

    /***************
    PLATFORM COLLECTOR
    ***************/

    function getPlatformFee(uint256 amount) private pure returns (uint256 fee) {
        fee = (amount * 50) / 10000; // Platform Fee: 50 bps -> 0.5%;
    }

    function collectPlatformFee(uint256 amount, address token)
        private
        returns (uint256 fee)
    {
        fee = getPlatformFee(amount);
        IERC20Metadata(token).transfer(PLATFORM_ADDRESS, fee);
    }

    /***************
    OTHER PARTY FUNCTIONS
    ***************/
    /// @inheritdoc IPartyOwnerActions
    function editPartyInfo(SharedStructs.PartyInfo memory _partyInfo)
        external
        override
        onlyOwner
    {
        partyInfo = _partyInfo;
        emit PartyInfoEdit(
            _partyInfo.name,
            _partyInfo.bio,
            _partyInfo.img,
            _partyInfo.model,
            _partyInfo.purpose,
            _partyInfo.isPublic,
            _partyInfo.minDeposit,
            _partyInfo.maxDeposit
        );
    }

    /// @inheritdoc IPartyState
    function getTokens() external view override returns (address[] memory) {
        return tokens;
    }

    /// @inheritdoc IPartyState
    function getJoinRequests()
        external
        view
        override
        returns (address[] memory)
    {
        return joinRequests.requests;
    }

    /// @inheritdoc IPartyState
    function isAcceptedRequest(address user)
        external
        view
        override
        returns (bool)
    {
        return joinRequests.accepted[user];
    }

    /// @inheritdoc IPartyActions
    function joinRequest() external override notMember isAlive {
        if (!JoinRequests.create(joinRequests)) revert AlreadyRequested();
        emit JoinRequest(msg.sender);
    }

    /// @inheritdoc IPartyOwnerActions
    function handleRequest(bool accepted, address user)
        external
        override
        onlyOwner
        isAlive
    {
        if (!JoinRequests.handle(joinRequests, accepted, user))
            revert AlreadyHandled();
        emit HandleJoinRequest(user, accepted);
    }

    /// @inheritdoc IPartyState
    function getPosts()
        external
        view
        override
        returns (Announcements.Post[] memory)
    {
        return announcements.posts;
    }

    /// @inheritdoc IPartyOwnerActions
    function createPost(
        string memory title,
        string memory description,
        string memory url,
        string memory img
    ) external override onlyOwner {
        Announcements.create(announcements, title, description, url, img);
    }

    /// @inheritdoc IPartyOwnerActions
    function editPost(
        string memory title,
        string memory description,
        string memory url,
        string memory img,
        uint256 announcementIdx
    ) external override onlyOwner {
        Announcements.edit(
            announcements,
            title,
            description,
            url,
            img,
            announcementIdx
        );
    }

    /// @inheritdoc IPartyOwnerActions
    function deletePost(uint256 announcementIdx) external override onlyOwner {
        Announcements.remove(announcements, announcementIdx);
    }

    function version() external pure virtual returns (string memory) {
        return "v1.2";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

// @openzeppelin/contracts-upgradeable
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract PartyInitializable is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

// Libraries
import "./libraries/Announcements.sol";
import "./libraries/JoinRequests.sol";
import "./libraries/SharedStructs.sol";

contract PartyStorage {
    /***************
    STATE
    ***************/
    // Main token for member's deposit/withdraws
    address public denominationAsset;

    // Platform fee collector
    address public PLATFORM_ADDRESS;

    // Party info
    SharedStructs.PartyInfo public partyInfo;
    bool public closed; // Party life status

    // Maping to get if address is member
    mapping(address => bool) public members;
    // Array of current party tokens
    address[] public tokens;

    // Announcements
    Announcements.Data announcements;
    // Join Requests
    JoinRequests.Data joinRequests;

    // Platform sentinel
    address public PLATFORM_SENTINEL;

    // Platform factory
    address public PLATFORM_FACTORY;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "./party/IPartyActions.sol";
import "./party/IPartyEvents.sol";
import "./party/IPartyMemberActions.sol";
import "./party/IPartyOwnerActions.sol";
import "./party/IPartyState.sol";

/**
 * @title Interface for a Party
 * @dev The party interface is broken up into smaller chunks
 */
interface IParty is
    IPartyActions,
    IPartyEvents,
    IPartyMemberActions,
    IPartyOwnerActions,
    IPartyState
{

}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

library Announcements {
    struct Data {
        Post[] posts;
    }
    struct Post {
        string title;
        string description;
        string url;
        string img;
        uint256 date;
    }

    function create(
        Data storage self,
        string memory title,
        string memory description,
        string memory url,
        string memory img
    ) internal {
        self.posts.push(Post(title, description, url, img, block.timestamp));
    }

    function edit(
        Data storage self,
        string memory title,
        string memory description,
        string memory url,
        string memory img,
        uint256 i
    ) internal {
        self.posts[i].title = title;
        self.posts[i].description = description;
        self.posts[i].url = url;
        self.posts[i].img = img;
    }

    function remove(Data storage self, uint256 i) internal {
        self.posts[i] = self.posts[self.posts.length - 1];
        self.posts.pop();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

library JoinRequests {
    struct Data {
        address[] requests;
        mapping(address => bool) accepted;
    }

    function create(Data storage self) internal returns (bool) {
        if (self.accepted[msg.sender]) return false; // Already accepted
        for (uint256 i = 0; i < self.requests.length; i++) {
            if (self.requests[i] == msg.sender) {
                return false; // Already requested
            }
        }
        self.requests.push(msg.sender);
        return true;
    }

    function handle(
        Data storage self,
        bool accepted,
        address user
    ) internal returns (bool) {
        if (self.accepted[user]) return false; // Already accepted
        // Search for the request
        for (uint256 i = 0; i < self.requests.length; i++) {
            if (self.requests[i] == user) {
                if (accepted) {
                    self.accepted[user] = true;
                }
                if (i < self.requests.length - 1) {
                    self.requests[i] = self.requests[self.requests.length - 1];
                }
                self.requests.pop();
                return true;
            }
        }
        return false;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

library AddressArrayLib {
    function contains(address[] memory self, address _address)
        internal
        pure
        returns (bool contained)
    {
        for (uint256 i; i < self.length; i++) {
            if (_address == self[i]) {
                return true;
            }
        }
        return false;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

library SharedStructs {
    /***************
    STRUCT
    ***************/
    struct PartyInfo {
        string name;
        string bio;
        string img; // path to storage without protocol/domain
        string model; // "Democracy", "Monarchy", "WeightedDemocracy", "Republic"
        string purpose; // "Trading", "YieldFarming", "LiquidityProviding", "NFT"
        bool isPublic;
        uint256 minDeposit;
        uint256 maxDeposit;
    }
    struct Allocation {
        address[] sellTokens;
        uint256[] sellAmounts;
        address[] buyTokens;
        address[] spenders;
        address payable[] swapsTargets;
        bytes[] swapsCallData;
        uint256 partyValueDA;
        uint256 partyTotalSupply;
        uint256 expiresAt;
    }
    struct FilledQuote {
        address sellToken;
        address buyToken;
        uint256 soldAmount;
        uint256 boughtAmount;
        uint256 initialSellBalance;
        uint256 initialBuyBalance;
    }
    struct Allocated {
        address[] sellTokens;
        address[] buyTokens;
        uint256[] soldAmounts;
        uint256[] boughtAmounts;
    }
    struct LimitOrder {
        uint256 salt;
        address makerAsset;
        address takerAsset;
        address maker;
        address receiver;
        address allowedSender;
        uint256 makingAmount;
        uint256 takingAmount;
        bytes makerAssetData;
        bytes takerAssetData;
        bytes getMakerAmount;
        bytes getTakerAmount;
        bytes predicate;
        bytes permit;
        bytes interaction;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "./SharedStructs.sol";

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

library SignatureHelpers {
    struct Sig {
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    /**
     * @notice Standard Signature Validation Method for Contracts EIP-1271.
     * @dev Verifies that the signer is the Party owner of the signing contract.
     */
    function isValidSignature(
        address partyOwner,
        bytes32 _hash,
        bytes calldata _signature
    ) internal pure returns (bytes4) {
        if (ECDSA.recover(_hash, _signature) == partyOwner) {
            return 0x1626ba7e;
        } else {
            return 0xffffffff;
        }
    }

    /**
     * @notice Returns an Ethereum Signed Message.
     * @dev Produces a hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     */
    function getMessageHash(bytes memory _abiEncoded)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    keccak256(_abiEncoded)
                )
            );
    }

    /**
     * @notice Verifies the tx signature against the PartyFi Sentinel address
     * @dev Used by the deposit, join, kick, leave and swap actions
     * @param signer The PartyFi Sentinel singer address
     * @param allocation The allocation struct to verify
     * @param rsv The values for the transaction's signature
     */
    function isValidAllocation(
        address signer,
        SharedStructs.Allocation memory allocation,
        Sig memory rsv
    ) internal view returns (bool) {
        // 1. Checks if the allocation hasn't expire
        if (allocation.expiresAt < block.timestamp) return false;

        // 2. Hashes the allocation struct to get the allocation hash
        bytes32 allocationHash = getMessageHash(
            abi.encodePacked(
                address(this),
                msg.sender,
                allocation.sellTokens,
                allocation.sellAmounts,
                allocation.buyTokens,
                allocation.spenders,
                allocation.swapsTargets,
                allocation.partyValueDA,
                allocation.partyTotalSupply,
                allocation.expiresAt
            )
        );

        // 3. Validates if the recovered signer is the PartyFi Sentinel
        return ECDSA.recover(allocationHash, rsv.v, rsv.r, rsv.s) == signer;
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity ^0.8.0;

import "../IERC20.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (proxy/utils/Initializable.sol)

pragma solidity ^0.8.2;

import "../../utils/AddressUpgradeable.sol";

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since proxied contracts do not make use of a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * The initialization functions use a version number. Once a version number is used, it is consumed and cannot be
 * reused. This mechanism prevents re-execution of each "step" but allows the creation of new initialization steps in
 * case an upgrade adds a module that needs to be initialized.
 *
 * For example:
 *
 * [.hljs-theme-light.nopadding]
 * ```
 * contract MyToken is ERC20Upgradeable {
 *     function initialize() initializer public {
 *         __ERC20_init("MyToken", "MTK");
 *     }
 * }
 * contract MyTokenV2 is MyToken, ERC20PermitUpgradeable {
 *     function initializeV2() reinitializer(2) public {
 *         __ERC20Permit_init("MyToken");
 *     }
 * }
 * ```
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {ERC1967Proxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 *
 * [CAUTION]
 * ====
 * Avoid leaving a contract uninitialized.
 *
 * An uninitialized contract can be taken over by an attacker. This applies to both a proxy and its implementation
 * contract, which may impact the proxy. To prevent the implementation contract from being used, you should invoke
 * the {_disableInitializers} function in the constructor to automatically lock it when it is deployed:
 *
 * [.hljs-theme-light.nopadding]
 * ```
 * /// @custom:oz-upgrades-unsafe-allow constructor
 * constructor() {
 *     _disableInitializers();
 * }
 * ```
 * ====
 */
abstract contract Initializable {
    /**
     * @dev Indicates that the contract has been initialized.
     * @custom:oz-retyped-from bool
     */
    uint8 private _initialized;

    /**
     * @dev Indicates that the contract is in the process of being initialized.
     */
    bool private _initializing;

    /**
     * @dev Triggered when the contract has been initialized or reinitialized.
     */
    event Initialized(uint8 version);

    /**
     * @dev A modifier that defines a protected initializer function that can be invoked at most once. In its scope,
     * `onlyInitializing` functions can be used to initialize parent contracts. Equivalent to `reinitializer(1)`.
     */
    modifier initializer() {
        bool isTopLevelCall = !_initializing;
        require(
            (isTopLevelCall && _initialized < 1) || (!AddressUpgradeable.isContract(address(this)) && _initialized == 1),
            "Initializable: contract is already initialized"
        );
        _initialized = 1;
        if (isTopLevelCall) {
            _initializing = true;
        }
        _;
        if (isTopLevelCall) {
            _initializing = false;
            emit Initialized(1);
        }
    }

    /**
     * @dev A modifier that defines a protected reinitializer function that can be invoked at most once, and only if the
     * contract hasn't been initialized to a greater version before. In its scope, `onlyInitializing` functions can be
     * used to initialize parent contracts.
     *
     * `initializer` is equivalent to `reinitializer(1)`, so a reinitializer may be used after the original
     * initialization step. This is essential to configure modules that are added through upgrades and that require
     * initialization.
     *
     * Note that versions can jump in increments greater than 1; this implies that if multiple reinitializers coexist in
     * a contract, executing them in the right order is up to the developer or operator.
     */
    modifier reinitializer(uint8 version) {
        require(!_initializing && _initialized < version, "Initializable: contract is already initialized");
        _initialized = version;
        _initializing = true;
        _;
        _initializing = false;
        emit Initialized(version);
    }

    /**
     * @dev Modifier to protect an initialization function so that it can only be invoked by functions with the
     * {initializer} and {reinitializer} modifiers, directly or indirectly.
     */
    modifier onlyInitializing() {
        require(_initializing, "Initializable: contract is not initializing");
        _;
    }

    /**
     * @dev Locks the contract, preventing any future reinitialization. This cannot be part of an initializer call.
     * Calling this in the constructor of a contract will prevent that contract from being initialized or reinitialized
     * to any version. It is recommended to use this to lock implementation contracts that are designed to be called
     * through proxies.
     */
    function _disableInitializers() internal virtual {
        require(!_initializing, "Initializable: contract is initializing");
        if (_initialized < type(uint8).max) {
            _initialized = type(uint8).max;
            emit Initialized(type(uint8).max);
        }
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.0;

import "./IERC20Upgradeable.sol";
import "./extensions/IERC20MetadataUpgradeable.sol";
import "../../utils/ContextUpgradeable.sol";
import "../../proxy/utils/Initializable.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC20
 * applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract ERC20Upgradeable is Initializable, ContextUpgradeable, IERC20Upgradeable, IERC20MetadataUpgradeable {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    function __ERC20_init(string memory name_, string memory symbol_) internal onlyInitializing {
        __ERC20_init_unchained(name_, symbol_);
    }

    function __ERC20_init_unchained(string memory name_, string memory symbol_) internal onlyInitializing {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        _balances[to] += amount;

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[45] private __gap;
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.5.0) (token/ERC20/extensions/ERC20Burnable.sol)

pragma solidity ^0.8.0;

import "../ERC20Upgradeable.sol";
import "../../../utils/ContextUpgradeable.sol";
import "../../../proxy/utils/Initializable.sol";

/**
 * @dev Extension of {ERC20} that allows token holders to destroy both their own
 * tokens and those that they have an allowance for, in a way that can be
 * recognized off-chain (via event analysis).
 */
abstract contract ERC20BurnableUpgradeable is Initializable, ContextUpgradeable, ERC20Upgradeable {
    function __ERC20Burnable_init() internal onlyInitializing {
    }

    function __ERC20Burnable_init_unchained() internal onlyInitializing {
    }
    /**
     * @dev Destroys `amount` tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint256 amount) public virtual {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, deducting from the caller's
     * allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for ``accounts``'s tokens of at least
     * `amount`.
     */
    function burnFrom(address account, uint256 amount) public virtual {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (security/ReentrancyGuard.sol)

pragma solidity ^0.8.0;
import "../proxy/utils/Initializable.sol";

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuardUpgradeable is Initializable {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    function __ReentrancyGuard_init() internal onlyInitializing {
        __ReentrancyGuard_init_unchained();
    }

    function __ReentrancyGuard_init_unchained() internal onlyInitializing {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (access/Ownable.sol)

pragma solidity ^0.8.0;

import "../utils/ContextUpgradeable.sol";
import "../proxy/utils/Initializable.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract OwnableUpgradeable is Initializable, ContextUpgradeable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    function __Ownable_init() internal onlyInitializing {
        __Ownable_init_unchained();
    }

    function __Ownable_init_unchained() internal onlyInitializing {
        _transferOwnership(_msgSender());
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (utils/Address.sol)

pragma solidity ^0.8.1;

/**
 * @dev Collection of functions related to the address type
 */
library AddressUpgradeable {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     *
     * [IMPORTANT]
     * ====
     * You shouldn't rely on `isContract` to protect against flash loan attacks!
     *
     * Preventing calls from contracts is highly discouraged. It breaks composability, breaks support for smart wallets
     * like Gnosis Safe, and does not provide security since it can be circumvented by calling from a contract
     * constructor.
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize/address.code.length, which returns 0
        // for contracts in construction, since the code is only stored at the end
        // of the constructor execution.

        return account.code.length > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verifies that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly
                /// @solidity memory-safe-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20Upgradeable {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity ^0.8.0;

import "../IERC20Upgradeable.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
 */
interface IERC20MetadataUpgradeable is IERC20Upgradeable {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (utils/Context.sol)

pragma solidity ^0.8.0;
import "../proxy/utils/Initializable.sol";

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal onlyInitializing {
    }

    function __Context_init_unchained() internal onlyInitializing {
    }
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

// Libraries
import "../../libraries/SignatureHelpers.sol";
import "../../libraries/SharedStructs.sol";

/**
 * @title Permissionless Party actions
 * @notice Contains party methods that can be called by anyone
 */
interface IPartyActions {
    /**
     * @notice Join a party
     * @dev Joins a party (public or with accepted invitation for private) with an allocation signature
     * @param amount The amount of the deposit for joining the party
     * @param allocation Struct containing the allocation of the deposit
     * @param approval The platform signature approval for the allocation
     */
    function joinParty(
        uint256 amount,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval
    ) external payable;

    /**
     * @notice Request to join a party
     * @dev User requests to join a private party.
     * Will be able to join the private party after request is accepted by the owner
     */
    function joinRequest() external;

    /**
     * @notice Interaction receiver function for 1nch LimitOrderProtocol when a party's limit order is filled
     * @param taker Taker address that filled the order
     * @param makerAsset Maker asset address
     * @param takerAsset Taker asset address
     * @param makingAmount Making asset amount
     * @param takingAmount Taking asset amount
     * @param interactiveData Interactive call data
     */
    function notifyFillOrder(
        address taker,
        address makerAsset,
        address takerAsset,
        uint256 makingAmount,
        uint256 takingAmount,
        bytes calldata interactiveData
    ) external;

    /**
     * @notice Implementation of EIP-1271
     */
    function isValidSignature(bytes32 _hash, bytes calldata _signature)
        external
        view
        returns (bytes4);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

/**
 * @title Events emitted by a party
 * @notice Contains all events emitted by the party
 */
interface IPartyEvents {
    /**
     * @notice Emitted exactly once by a party when #initialize is first called
     * @param partyCreator Address of the user that created the party
     * @param partyName Name of the party
     * @param isPublic Visibility of the party
     * @param dAsset Address of the denomination asset for the party
     * @param minDeposit Minimum deposit of the party
     * @param maxDeposit Maximum deposit of the party
     * @param mintedPT Minted party tokens for creating the party
     * @param bio Bio of the party
     * @param img Img url of the party
     * @param model Model of party created
     * @param purpose Purpose of party created
     */
    event PartyCreated(
        address partyCreator,
        string partyName,
        bool isPublic,
        address dAsset,
        uint256 minDeposit,
        uint256 maxDeposit,
        uint256 mintedPT,
        string bio,
        string img,
        string model,
        string purpose
    );

    /**
     * @notice Emitted when a user joins a party
     * @param member Address of the user
     * @param asset Address of the denomination asset
     * @param amount Amount of the deposit
     * @param fee Collected fee
     * @param mintedPT Minted party tokens for joining
     */
    event Join(
        address member,
        address asset,
        uint256 amount,
        uint256 fee,
        uint256 mintedPT
    );

    /**
     * @notice Emitted when a member deposits denomination assets into a party
     * @param member Address of the user
     * @param asset Address of the denomination asset
     * @param amount Amount of the deposit
     * @param fee Collected fee
     * @param mintedPT Minted party tokens for depositing
     */
    event Deposit(
        address member,
        address asset,
        uint256 amount,
        uint256 fee,
        uint256 mintedPT
    );

    /**
     * @notice Emitted when quotes are filled by 0x for allocation of funds
     * @dev SwapToken is not included on this event, since its have the same information
     * @param member Address of the user
     * @param sellTokens Array of sell tokens
     * @param buyTokens Array of buy tokens
     * @param soldAmounts Array of sold amount of tokens
     * @param boughtAmounts Array of bought amount of tokens
     * @param partyValueDA The party value in denomination asset prior to the allocation
     */
    event AllocationFilled(
        address member,
        address[] sellTokens,
        address[] buyTokens,
        uint256[] soldAmounts,
        uint256[] boughtAmounts,
        uint256 partyValueDA
    );

    /**
     * @notice Emitted when a member redeems shares from a party
     * @param member Address of the user
     * @param burnedPT Burned party tokens for redemption
     * @param liquidate Redemption by liquitating shares into denomination asset
     * @param redeemedAssets Array of asset addresses
     * @param redeemedAmounts Array of asset amounts
     * @param redeemedFees Array of asset fees
     * @param redeemedNetAmounts Array of net asset amounts
     */
    event RedeemedShares(
        address member,
        uint256 burnedPT,
        bool liquidate,
        address[] redeemedAssets,
        uint256[] redeemedAmounts,
        uint256[] redeemedFees,
        uint256[] redeemedNetAmounts
    );

    /**
     * @notice Emitted when a member withdraws from a party
     * @param member Address of the user
     * @param burnedPT Burned party tokens of member
     */
    event Withdraw(address member, uint256 burnedPT);

    /**
     * @notice Emitted when quotes are filled by 0x in the same tx
     * @param member Address of the user
     * @param sellToken Sell token address
     * @param buyToken Buy token address
     * @param soldAmount Sold amount of token
     * @param boughtAmount Bought amount of token
     * @param fee fee collected
     */
    event SwapToken(
        address member,
        address sellToken,
        address buyToken,
        uint256 soldAmount,
        uint256 boughtAmount,
        uint256 fee
    );

    /**
     * @notice Emitted when a member gets kicked from a party
     * @param kicker Address of the kicker (owner)
     * @param kicked Address of the kicked member
     * @param burnedPT Burned party tokens of member
     */
    event Kick(address kicker, address kicked, uint256 burnedPT);

    /**
     * @notice Emitted when a member leaves a party
     * @param member Address of the user
     * @param burnedPT Burned party tokens for withdrawing
     */
    event Leave(address member, uint256 burnedPT);

    /**
     * @notice Emitted when the owner closes a party
     * @param member Address of the user (should be party owner)
     * @param supply Total supply of party tokens when the party closed
     */
    event Close(address member, uint256 supply);

    /**
     * @notice Emitted when a user requests to join a private party
     * @param member Address of the user requesting to join
     */
    event JoinRequest(address member);

    /**
     * @notice Emitted when a join requests gets accepted or rejected
     * @param member Address of the user that requested to join
     * @param accepted Whether the request was accepted or rejected
     */
    event HandleJoinRequest(address member, bool accepted);

    /**
     * @notice Emitted when the party information changes after creation
     * @param name Name of the party
     * @param bio Bio of the party
     * @param img Img url of the party
     * @param model Model of party created
     * @param purpose Purpose of party created
     * @param isPublic Visibility of the party
     * @param minDeposit Minimum deposit of the party
     * @param maxDeposit Maximum deposit of the party
     */
    event PartyInfoEdit(
        string name,
        string bio,
        string img,
        string model,
        string purpose,
        bool isPublic,
        uint256 minDeposit,
        uint256 maxDeposit
    );

    /**
     * @notice Emitted when 1nch LimitOrderProtocol calls Party when a limit order is filled
     * @param taker Taker address that filled the order
     * @param makerAsset Maker asset address
     * @param takerAsset Taker asset address
     * @param makingAmount Making asset amount
     * @param takingAmount Taking asset amount
     */
    event LimitOrderFilled(
        address taker,
        address makerAsset,
        address takerAsset,
        uint256 makingAmount,
        uint256 takingAmount
    );
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

// Libraries
import "../../libraries/SignatureHelpers.sol";
import "../../libraries/SharedStructs.sol";

/**
 * @title Permissioned Party actions
 * @notice Contains party methods that can be called by a member of the party
 */
interface IPartyMemberActions {
    /**
     * @notice Deposit funds into a party
     * @dev Member deposits more funds into a party with an allocation signature
     * @param amount The amount of the deposit for joining the party
     * @param allocation Struct containing the allocation of the deposit
     * @param approval The platform signature approval for the allocation
     */
    function deposit(
        uint256 amount,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval
    ) external payable;

    /**
     * @notice Withdraw funds from a party
     * @dev Member withdraws funds by giving back the party tokens
     * @param amountPT The amount of party tokens to exchange for funds\
     * @param allocation Struct containing the allocation of the withdraw
     * @param approval The platform signature approval for the allocation
     * @param liquidate Liquidate redemption
     */
    function withdraw(
        uint256 amountPT,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval,
        bool liquidate
    ) external payable;

    /**
     * @notice Withdraw funds from a party
     * @dev Member leaves the party, giving back all of its party tokens.
     * @param allocation Struct containing the allocation of the withdraw
     * @param approval The platform signature approval for the allocation
     * @param liquidate Liquidate redemption
     */
    function leaveParty(
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval,
        bool liquidate
    ) external payable;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

// Libraries
import "../../libraries/SignatureHelpers.sol";
import "../../libraries/SharedStructs.sol";

/**
 * @title Permissioned Party actions
 * @notice Contains party methods that can be called by the owner of the Party
 */
interface IPartyOwnerActions {
    /**
     * @notice Swap a token with the party's fund
     * @dev Called by the owner of the Party, and only swaps a single token.
     * @param allocation The address of the party creator
     * @param approval The platform signature approval for the allocation
     */
    function swapToken(
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval
    ) external payable;

    /**
     * @notice Kick a member
     * @dev Owner kicks a member.
     * @param kickingMember The address of the member to be kicked
     * @param allocation Struct containing the allocation of the withdraw
     * @param approval The platform signature approval for the allocation
     * @param liquidate Liquidate redemption
     */
    function kickMember(
        address kickingMember,
        SharedStructs.Allocation memory allocation,
        SignatureHelpers.Sig memory approval,
        bool liquidate
    ) external payable;

    /**
     * @notice Closes a party
     * @dev Owner closes a party by giving ownership to zero address. Party won't have an owner afterwards.
     */
    function closeParty() external payable;

    /**
     * @notice Hanldes a request to join the party
     * @dev Owner can either accept or reject the request to join the party
     * @param accepted True if accepted; otherwise, false
     * @param user The address of the user join request
     */
    function handleRequest(bool accepted, address user) external;

    /**
     * @notice Create an annoucement
     * @dev Create a new announcement
     * @param title The title of the announcement
     * @param description The description of the announcement
     * @param url An url to display on the announcement
     * @param img The image url of the announcement
     */
    function createPost(
        string memory title,
        string memory description,
        string memory url,
        string memory img
    ) external;

    /**
     * @notice Edits an annoucement
     * @dev Edits a previously created announcement by its index
     * @param title The title of the announcement
     * @param description The description of the announcement
     * @param url An url to display on the announcement
     * @param img The image url of the announcement
     * @param announcementIdx The index of the announcement
     */
    function editPost(
        string memory title,
        string memory description,
        string memory url,
        string memory img,
        uint256 announcementIdx
    ) external;

    /**
     * @notice Delete an annoucement
     * @dev Deletes a previously created announcement by its index
     * @param announcementIdx The index of the announcement
     */
    function deletePost(uint256 announcementIdx) external;

    /**
     * @notice Edits the party information
     * @dev Edits partyInfo state
     * @param _partyInfo Party information
     */
    function editPartyInfo(SharedStructs.PartyInfo memory _partyInfo) external;

    /**
     * @notice Approves 1nch LimitOrderProtocol to consume party assets
     * @param sellToken ERC-20 sell token address
     * @param sellAmount ERC-20 sell token amount
     */
    function approveLimitOrder(address sellToken, uint256 sellAmount) external;

    /**
     * @notice Cancels a limit order on 1nch
     * @param order Limit Order
     */
    function cancelLimitOrder(SharedStructs.LimitOrder memory order) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

// Libraries
import "../../libraries/Announcements.sol";

/**
 * @title Party state that can change
 * @notice Methods that compose the party and that are mutable
 */
interface IPartyState {
    /**
     * @notice The assets (tokens) held by the party
     * @dev Includes also the denomination asset of the party
     */
    function getTokens() external view returns (address[] memory);

    /**
     * @notice The join requests for the party
     * @dev Contains the array of addresses of users which invitation is pending.
     * This behaves as a whitelist for users to join the private party.
     */
    function getJoinRequests() external view returns (address[] memory);

    /**
     * @notice The accepted join requests
     * @dev Checks if the request has been accepted by the owner
     */
    function isAcceptedRequest(address) external view returns (bool);

    /**
     * @notice The announcements created for the party
     * @dev Contains the array of Post structs for the party
     */
    function getPosts() external view returns (Announcements.Post[] memory);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (utils/cryptography/ECDSA.sol)

pragma solidity ^0.8.0;

import "../Strings.sol";

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS,
        InvalidSignatureV
    }

    function _throwError(RecoverError error) private pure {
        if (error == RecoverError.NoError) {
            return; // no error: do nothing
        } else if (error == RecoverError.InvalidSignature) {
            revert("ECDSA: invalid signature");
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert("ECDSA: invalid signature length");
        } else if (error == RecoverError.InvalidSignatureS) {
            revert("ECDSA: invalid signature 's' value");
        } else if (error == RecoverError.InvalidSignatureV) {
            revert("ECDSA: invalid signature 'v' value");
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature` or error string. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     *
     * Documentation for signature generation:
     * - with https://web3js.readthedocs.io/en/v1.3.4/web3-eth-accounts.html#sign[Web3.js]
     * - with https://docs.ethers.io/v5/api/signer/#Signer-signMessage[ethers]
     *
     * _Available since v4.3._
     */
    function tryRecover(bytes32 hash, bytes memory signature) internal pure returns (address, RecoverError) {
        // Check the signature length
        // - case 65: r,s,v signature (standard)
        // - case 64: r,vs signature (cf https://eips.ethereum.org/EIPS/eip-2098) _Available since v4.1._
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            /// @solidity memory-safe-assembly
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else if (signature.length == 64) {
            bytes32 r;
            bytes32 vs;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            /// @solidity memory-safe-assembly
            assembly {
                r := mload(add(signature, 0x20))
                vs := mload(add(signature, 0x40))
            }
            return tryRecover(hash, r, vs);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength);
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, signature);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `r` and `vs` short-signature fields separately.
     *
     * See https://eips.ethereum.org/EIPS/eip-2098[EIP-2098 short signatures]
     *
     * _Available since v4.3._
     */
    function tryRecover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address, RecoverError) {
        bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        uint8 v = uint8((uint256(vs) >> 255) + 27);
        return tryRecover(hash, v, r, s);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `r and `vs` short-signature fields separately.
     *
     * _Available since v4.2._
     */
    function recover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, r, vs);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `v`,
     * `r` and `s` signature fields separately.
     *
     * _Available since v4.3._
     */
    function tryRecover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address, RecoverError) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS);
        }
        if (v != 27 && v != 28) {
            return (address(0), RecoverError.InvalidSignatureV);
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature);
        }

        return (signer, RecoverError.NoError);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, v, r, s);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from a `hash`. This
     * produces hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        // 32 is the length in bytes of hash,
        // enforced by the type signature above
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from `s`. This
     * produces hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes memory s) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", Strings.toString(s.length), s));
    }

    /**
     * @dev Returns an Ethereum Signed Typed Data, created from a
     * `domainSeparator` and a `structHash`. This produces hash corresponding
     * to the one signed with the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`]
     * JSON-RPC method as part of EIP-712.
     *
     * See {recover}.
     */
    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (utils/Strings.sol)

pragma solidity ^0.8.0;

/**
 * @dev String operations.
 */
library Strings {
    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";
    uint8 private constant _ADDRESS_LENGTH = 20;

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT licence
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0x00";
        }
        uint256 temp = value;
        uint256 length = 0;
        while (temp != 0) {
            length++;
            temp >>= 8;
        }
        return toHexString(value, length);
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }

    /**
     * @dev Converts an `address` with fixed length of 20 bytes to its not checksummed ASCII `string` hexadecimal representation.
     */
    function toHexString(address addr) internal pure returns (string memory) {
        return toHexString(uint256(uint160(addr)), _ADDRESS_LENGTH);
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}