// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

import "./IMarketDistribution.sol";
import "./IMarketGeneration.sol";
import "./TokensRecoverable.sol";
import "./SafeERC20.sol";
import "./SafeMath.sol";
import "./IERC20.sol";
import "./IWBNB.sol";

contract MarketGeneration is TokensRecoverable, IMarketGeneration
{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    mapping (address => uint256) public override contribution;
    mapping (address => uint256) public override referralPoints;
    mapping (address => bool) public mgeController;
    uint256 public override totalReferralPoints;
    uint256 public override totalContribution;
    address public immutable devAddress;
    uint public startDate;
    uint public endDate;   
    bool public dateLimitActive; 

    bool public isActive;
    uint public hardCap;
    uint public softCap;
    IERC20 public baseToken;
    IMarketDistribution public marketDistribution;
    uint256 public refundsAllowedUntil;

    constructor(address _devAddress)
    {
        devAddress = _devAddress;
        mgeController[owner] = true;
    }

    modifier active()
    {
        require (isActive, "Distribution not active");
        _;
    }
    modifier isController(){
        require(mgeController[msg.sender] || msg.sender == owner, "Only controller or owner can do this");
        _;
    }

    function init(IERC20 _baseToken) public  isController()
    {
        require (!isActive && block.timestamp >= refundsAllowedUntil, "Already activated");
        baseToken = _baseToken;
    }
    function setHardCap(uint _hardCap) public  isController()
    {
        //require (!isActive, "Already activated");
        require(_hardCap > hardCap, "Hard cap must be greater than current hard cap");
        hardCap = _hardCap;
    }
    function setSoftCap(uint _softCap) public  isController()
    {
        softCap = _softCap;
    }
    function setMGEController(address _controller) public  isController()
    {
        mgeController[_controller] = !mgeController[_controller];
    }

    function activate(IMarketDistribution _marketDistribution, uint mgeLengthInSeconds) public  isController()
    {
        require (!isActive && block.timestamp >= refundsAllowedUntil, "Already activated");        
        require (address(_marketDistribution) != address(0));
        marketDistribution = _marketDistribution;
        startDate = block.timestamp;
        endDate = startDate + mgeLengthInSeconds;
        isActive = true;
    }
    function activateDeactivateDateLimit() public  isController()
    {
        dateLimitActive = !dateLimitActive;
    }
    function setMGELength(uint timeInSeconds) public  isController()
    {
        require (isActive);
        endDate = startDate + timeInSeconds;
    }

    function setMarketDistribution(IMarketDistribution _marketDistribution) public  isController() active()
    {
        require (address(_marketDistribution) != address(0), "Invalid market distribution");
        if (_marketDistribution == marketDistribution) { return; }
        marketDistribution = _marketDistribution;

        // Give everyone 1 day to claim refunds if they don't approve of the new distributor
        refundsAllowedUntil = block.timestamp + 86400;
    }

    function complete(
        uint16 _preBuyForReferralsPercent, 
        uint16 _preBuyForContributorsPercent, 
        uint16 _preBuyForMarketStabilizationPercent
    ) public  isController() active()
    {
        require (block.timestamp >= refundsAllowedUntil, "Refund period is still active");
        isActive = false;
        if (address(this).balance == 0) { return; }
        IWBNB(address(baseToken)).deposit{ value: address(this).balance }();
        baseToken.safeApprove(address(marketDistribution), uint256(-1));
        endDate = block.timestamp;
        marketDistribution.distribute(_preBuyForReferralsPercent, _preBuyForContributorsPercent, _preBuyForMarketStabilizationPercent);
    }

    function allowRefunds() public  isController() active()
    {
        isActive = false;
        refundsAllowedUntil = uint256(-1);
    }

    function refund(uint256 amount) private
    {
        (bool success,) = msg.sender.call{ value: amount }("");
        require (success, "Refund transfer failed");  
          
        totalContribution -= amount;
        contribution[msg.sender] = 0;

        uint256 refPoints = referralPoints[msg.sender];

        if (refPoints > 0)
        {
            totalReferralPoints -= refPoints;
            referralPoints[msg.sender] = 0;
        }
    }

    function claim() public 
    {
        uint256 amount = contribution[msg.sender];

        require (amount > 0, "Nothing to claim");
        
        if (refundsAllowedUntil > block.timestamp) 
        {
            refund(amount);
        }
        else 
        {
            marketDistribution.claim(msg.sender);
        }
    }

    function claimReferralRewards() public
    {
        require (referralPoints[msg.sender] > 0, "No rewards to claim");
        
        uint256 refShare = referralPoints[msg.sender];
        referralPoints[msg.sender] = 0;
        marketDistribution.claimReferralRewards(msg.sender, refShare);
    }

    function contribute(address referral) public payable active() 
    {
        //require contribution does not exceed hard cap
        require (totalContribution + msg.value <= hardCap, "Contribution exceeds hard cap");
        //require contribution to be before end date
        require (block.timestamp < endDate, "Contribution after end date");
        
        if (referral == address(0) || referral == msg.sender) 
        {
            referralPoints[devAddress] += msg.value;
            totalReferralPoints += msg.value;
        }
        else 
        {
            referralPoints[msg.sender] += msg.value;
            referralPoints[referral] += msg.value;
            totalReferralPoints +=(msg.value + msg.value);
        }

        contribution[msg.sender] += msg.value;
        totalContribution += msg.value;
    }

    receive() external payable active()
    {
        contribute(address(0));
    }
}

// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

/* ROOTKIT:
Allows recovery of unexpected tokens (airdrops, etc)
Inheriters can customize logic by overriding canRecoverTokens
*/

import "./IERC20.sol";
import "./SafeERC20.sol";
import "./Owned.sol";
import "./ITokensRecoverable.sol";

abstract contract TokensRecoverable is Owned, ITokensRecoverable
{
    using SafeERC20 for IERC20;

    function recoverTokens(IERC20 token) public override ownerOnly() 
    {
        require (canRecoverTokens(token));
        token.safeTransfer(msg.sender, token.balanceOf(address(this)));
    }

    function canRecoverTokens(IERC20 token) internal virtual view returns (bool) 
    { 
        return address(token) != address(this); 
    }
}

// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

library SafeMath 
{
    function add(uint256 a, uint256 b) internal pure returns (uint256) 
    {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) 
    {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) 
    {
        require(b <= a, errorMessage);
        uint256 c = a - b;
        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) 
    {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) 
        {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    
    function div(uint256 a, uint256 b) internal pure returns (uint256) 
    {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) 
    {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) 
    {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) 
    {
        require(b != 0, errorMessage);
        return a % b;
    }
}

// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

/* ROOTKIT:
Modified to remove some junk
Also modified to remove silly restrictions (traps!) within safeApprove
*/

import "./IERC20.sol";
import "./SafeMath.sol";
import "./Address.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using SafeMath for uint256;
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {        
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

/* ROOTKIT:
Provides ownerOnly() modifier
Allows for ownership transfer but requires the new
owner to claim (accept) ownership
Safer because no accidental transfers or renouncing
*/

import "./IOwned.sol";

abstract contract Owned is IOwned
{
    address public override owner = msg.sender;
    address internal pendingOwner;

    modifier ownerOnly()
    {
        require (msg.sender == owner, "Owner only");
        _;
    }

    function transferOwnership(address newOwner) public override ownerOnly()
    {
        pendingOwner = newOwner;
    }

    function claimOwnership() public override
    {
        require (pendingOwner == msg.sender);
        pendingOwner = address(0);
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
    }
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

interface IWBNB
{    
    function deposit() external payable;
}

// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

import "./IERC20.sol";

interface ITokensRecoverable
{
    function recoverTokens(IERC20 token) external;
}

// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

interface IOwned
{
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function owner() external view returns (address);

    function transferOwnership(address newOwner) external;
    function claimOwnership() external;
}

// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

interface IMarketGeneration
{
    function contribution(address) external view returns (uint256);
    function referralPoints(address) external view returns (uint256);    
    function totalContribution() external view returns (uint256);
    function totalReferralPoints() external view returns (uint256);
}

// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

interface IMarketDistribution
{
    function distributionComplete() external view returns (bool);
    function vestingPeriodStartTime() external view returns (uint256); 
    function vestingPeriodEndTime() external view returns (uint256);
    
    function distribute(uint16 _preBuyForReferralsPercent, uint16 _preBuyForContributorsPercent, uint16 _preBuyForMarketStabilizationPercent) external;        
    function claim(address account) external;
    function claimReferralRewards(address account, uint256 referralShare) external;
}

// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

interface IERC20 
{
    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event Approval(address indexed _owner, address indexed _spender, uint256 _value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address _account) external view returns (uint256);
    function transfer(address _recipient, uint256 _amount) external returns (bool);
    function allowance(address _owner, address _spender) external view returns (uint256);
    function approve(address _spender, uint256 _amount) external returns (bool);
    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

// SPDX-License-Identifier: U-U-U-UPPPPP!!!
pragma solidity ^0.7.4;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
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
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
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

        // solhint-disable-next-line avoid-low-level-calls, avoid-call-value
        (bool success, ) = recipient.call{ value: amount }("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain`call` is an unsafe replacement for a function call: use this
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
    function functionCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
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
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.call{ value: value }(data);
        return _verifyCallResult(success, returndata, errorMessage);
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
    function functionStaticCall(address target, bytes memory data, string memory errorMessage) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.staticcall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.3._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.3._
     */
    function functionDelegateCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        require(isContract(target), "Address: delegate call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    function _verifyCallResult(bool success, bytes memory returndata, string memory errorMessage) private pure returns(bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                // solhint-disable-next-line no-inline-assembly
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