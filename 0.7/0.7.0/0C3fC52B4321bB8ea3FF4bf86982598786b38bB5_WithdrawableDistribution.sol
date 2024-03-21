// SPDX-License-Identifier: Apache license 2.0

pragma solidity ^0.7.0;

import "../utils/Context.sol";
import "../utils/Ownable.sol";
import "../token/ERC20Lockable.sol";
import "../libraries/SafeMathUint.sol";

/**
 * @dev Allows users to withdraw both the unlocked and locked tokens, triggers the `lock-in` period for locked ones.
 *
 * See {ERC20Lockable}.
 */
contract WithdrawableDistribution is Context, Ownable {
  using SafeMathUint for uint256;

  ERC20Lockable _lockableToken;
  uint32 private constant LOCK_DURATION = 7776000;

  mapping(address => uint256) internal _unlockedWithdrawalLimits;
  mapping(address => uint256) internal _lockedWithdrawalLimits;
  
  /**
   * @dev Sets the `lockableToken` token which will be distributed through
   * {WithdrawableDistribution} and which might have a `lock-in` period for lockable withdrawals.
   */
  constructor(ERC20Lockable lockableToken) {
    _lockableToken = lockableToken;
  }

  /**
   * @dev Makes each of 'to' accounts eligible to receive the corresponding 'values' amount of unlocked tokens.
   */
  function increaseUnlockedWithdrawalLimits(address[] calldata to, uint256[] calldata values)
    external onlyOwner
  {
    require(
      to.length == values.length && to.length > 0,
      "WithdrawableDistribution: to and values arrays should be equal in size and non-empty"
    );

    uint256 i = 0;
    while (i < to.length) {
      _unlockedWithdrawalLimits[to[i]] = _unlockedWithdrawalLimits[to[i]].add(values[i]);
      i++;
    }
  }

  /**
   * @dev Makes each of 'to' accounts eligible to receive the corresponding 'values' amount of locked tokens.
   */
  function increaseLockedWithdrawalLimits(address[] calldata to, uint256[] calldata values)
    external onlyOwner
  {
    require(
      to.length == values.length && to.length > 0,
      "WithdrawableDistribution: to and values arrays should be equal in size and non-empty"
    );

    uint256 i = 0;
    while (i < to.length) {
      _lockedWithdrawalLimits[to[i]] = _lockedWithdrawalLimits[to[i]].add(values[i]);
      i++;
    }
  }

  /**
   * @dev Sends unlocked tokens to sender account if eligible.
   */
  function withdrawUnlocked()
    external
  {
    uint256 unlockedTokens = _unlockedWithdrawalLimits[_msgSender()];
    require(
      unlockedTokens > 0,
      "WithdrawableDistribution: your wallet address is not eligible to receive the unlocked tokens"
    );
    require(
      _lockableToken.balanceOf(address(this)) >= unlockedTokens,
      "WithdrawableDistribution: not enough tokens left for distribution, please contact the contract owner organization"
    );

    _unlockedWithdrawalLimits[_msgSender()] = 0;
    _lockableToken.transfer(_msgSender(), unlockedTokens);
  }

  /**
   * @dev Sends locked tokens to sender account if eligible, triggers the `lock-in` period.
   */
  function withdrawLocked()
    external
  {
    uint256 lockedTokens = _lockedWithdrawalLimits[_msgSender()];
    require(
      lockedTokens > 0,
      "WithdrawableDistribution: your wallet address is not eligible to receive the locked tokens"
    );
    require(
      _lockableToken.balanceOf(address(this)) >= lockedTokens,
      "WithdrawableDistribution: not enough tokens left for distribution, please contact the contract owner organization"
    );

    _lockedWithdrawalLimits[_msgSender()] = 0;
    _lockableToken.lock(
      _msgSender(),
      lockedTokens,
      block.timestamp + LOCK_DURATION
    );
    _lockableToken.transfer(_msgSender(), lockedTokens);
  }

  /**
   * @dev Returns the amount of unlocked tokens available for a withdrawal by `user` account.
   */
  function unlockedWithdrawalLimit(address user) public view returns (uint256) {
    return _unlockedWithdrawalLimits[user];
  }

  /**
   * @dev Returns the amount of locked tokens available for a withdrawal by `user` account.
   */
  function lockedWithdrawalLimit(address user) public view returns (uint256) {
    return _lockedWithdrawalLimits[user];
  }

  /**
   * @dev Returns the `lock-in` duration in seconds.
   */
  function lockDuration() external pure returns (uint32) {
    return LOCK_DURATION;
  }
}

// SPDX-License-Identifier: Apache license 2.0

pragma solidity ^0.7.0;

import "./Context.sol";
import "./Ownable.sol";

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract Pausable is Context, Ownable {
  /**
   * @dev Emitted when the pause is triggered by `account`.
   */
  event LogPaused(address account);

  /**
   * @dev Emitted when the pause is lifted by `account`.
   */
  event LogUnpaused(address account);

  bool private _paused;

  /**
   * @dev Initializes the contract in unpaused state.
   */
  constructor() {
    _paused = false;
  }

  /**
   * @dev Returns true if the contract is paused, and false otherwise.
   */
  function paused() public view returns (bool) {
    return _paused;
  }

  /**
   * @dev Modifier to make a function callable only when the contract is not paused.
   *
   * Requirements:
   *
   * - The contract must not be paused.
   */
  modifier whenNotPaused() {
    require(!_paused, "Pausable: paused");
    _;
  }

  /**
   * @dev Modifier to make a function callable only when the contract is paused.
   *
   * Requirements:
   *
   * - The contract must be paused.
   */
  modifier whenPaused() {
    require(_paused, "Pausable: not paused");
    _;
  }

  /**
   * @dev Triggers stopped state.
   *
   * Requirements:
   *
   * - The contract must not be paused.
   */
  function pause() external virtual whenNotPaused onlyOwner {
    _paused = true;
    emit LogPaused(_msgSender());
  }

  /**
   * @dev Returns to normal state.
   *
   * Requirements:
   *
   * - The contract must be paused.
   */
  function unpause() external virtual whenPaused onlyOwner {
    _paused = false;
    emit LogUnpaused(_msgSender());
  }
}

// SPDX-License-Identifier: Apache license 2.0

pragma solidity ^0.7.0;

import "./Context.sol";

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
abstract contract Ownable is Context {
  event LogOwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  address private _owner;

  /**
   * @dev Initializes the contract setting the deployer as the initial owner.
   */
  constructor() {
    _owner = _msgSender();
  }

  /**
   * @dev Returns the address of the current owner.
   */
  function owner() public view returns (address) {
    return _owner;
  }

  /**
   * @dev Throws if called by any account other than the owner.
   */
  modifier onlyOwner() {
    require(_msgSender() == _owner, "Ownable: only contract owner can call this function.");
    _;
  }

  /**
   * @dev Checks if transaction sender account is an owner.
   */
  function isOwner() external view returns (bool) {
    return _msgSender() == _owner;
  }

  /**
   * @dev Transfers ownership of the contract to a new account (`newOwner`).
   * Can only be called by the current owner.
   */
  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "Ownable: new owner is the zero address");
    emit LogOwnershipTransferred(_owner, newOwner);
    _owner = newOwner;
  }
}

// SPDX-License-Identifier: Apache license 2.0

pragma solidity ^0.7.0;

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with GSN meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
  function _msgSender() internal virtual view returns (address payable) {
    return msg.sender;
  }

  function _msgData() internal virtual view returns (bytes memory) {
    this;
    return msg.data;
  }
}

// SPDX-License-Identifier: Apache license 2.0

pragma solidity ^0.7.0;

import "./ERC20.sol";
import "../utils/Pausable.sol";

/**
 * @dev Extension of {ERC20} with pausable token transfers, minting and burning.
 *
 * Useful for scenarios such as preventing trades until the end of an evaluation
 * period, or having an emergency switch for freezing all token transfers in the
 * event of a large bug.
 */
abstract contract ERC20Pausable is ERC20, Pausable {
  /**
   * @dev See {ERC20-_beforeTokenTransfer}.
   *
   * Requirements:
   *
   * - the contract must not be paused.
   */
  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);
    require(!paused(), "ERC20Pausable: token transfer while paused");
  }
}

// SPDX-License-Identifier: Apache license 2.0

pragma solidity ^0.7.0;

import "../utils/Context.sol";
import "./ERC20Pausable.sol";
import "../libraries/SafeMathUint.sol";

/**
 * @dev Extension of {ERC20} that allows to set up a 'lock-in' period for tokens,
 * which means a percentage of tokens received through from {LockableDistribution} contract
 * will not be transferrable until the end of 'lock-in' period.
 */
abstract contract ERC20Lockable is Context, ERC20Pausable {
  using SafeMathUint for uint256;

  address _lockableDistribution;

  struct BalanceLock {
    uint256 lockedAmount;
    uint256 unlockTimestamp;
  }
  mapping(address => BalanceLock) internal _balanceLocks;

  /**
   * @dev Creates a 'lock-in' period for `lockAmount` tokens on `lockFor` address
   * that lasts until `unlockTimestamp` timestamp.
   */
  function lock(
    address lockFor,
    uint256 lockAmount,
    uint256 unlockTimestamp
  ) external {
    require(
      _msgSender() == _lockableDistribution,
      "ERC20Lockable: only distribution contract can lock tokens"
    );

    _balanceLocks[lockFor].lockedAmount = lockAmount;
    _balanceLocks[lockFor].unlockTimestamp = unlockTimestamp;
  }

  /**
   * @dev Returns a 'lock-in' period details for `account` address.
   */
  function lockOf(address account)
    public
    view
    returns (uint256 lockedAmount, uint256 unlockTimestamp)
  {
    return (_balanceLocks[account].lockedAmount, _balanceLocks[account].unlockTimestamp);
  }

  /**
   * @dev Hook that restricts transfers according to the 'lock-in' period.
   *
   * See {ERC20-_beforeTokenTransfer}.
   *
   * Requirements:
   *
   * - transferred amount should not include tokens that are 'locked-in'.
   */
  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);

    uint256 lockedAmount;
    uint256 unlockTimestamp;
    (lockedAmount, unlockTimestamp) = lockOf(from);
    if (unlockTimestamp != 0 && block.timestamp < unlockTimestamp) {
      require(
        amount <= balanceOf(from).sub(lockedAmount),
        "ERC20Lockable: transfer amount exceeds the non-locked balance"
      );
    }
  }
}

// SPDX-License-Identifier: Apache license 2.0

pragma solidity ^0.7.0;

import "../utils/Context.sol";
import "../interfaces/IERC20.sol";
import "../libraries/SafeMathUint.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 *
 * Functions revert instead of returning `false` on failure.
 * This behavior is nonetheless conventional
 * and does not conflict with the expectations of ERC20 applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * The non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract ERC20 is Context, IERC20 {
  using SafeMathUint for uint256;

  mapping(address => uint256) internal _balances;

  mapping(address => mapping(address => uint256)) private _allowances;

  uint256 internal _totalSupply;

  string private _name;
  string private _symbol;
  uint8 private _decimals;

  /**
   * @dev Sets the values for {name} and {symbol}, initializes {decimals} with
   * a default value of 18.
   *
   * To select a different value for {decimals}, use {_setupDecimals}.
   *
   * All three of these values are immutable: they can only be set once during
   * construction.
   */
  constructor(string memory name, string memory symbol) {
    _name = name;
    _symbol = symbol;
    _decimals = 18;
  }

  /**
   * @dev Returns the name of the token.
   */
  function name() public view returns (string memory) {
    return _name;
  }

  /**
   * @dev Returns the symbol of the token, usually a shorter version of the
   * name.
   */
  function symbol() public view returns (string memory) {
    return _symbol;
  }

  /**
   * @dev Returns the number of decimals used to get its user representation.
   * For example, if `decimals` equals `2`, a balance of `505` tokens should
   * be displayed to a user as `5,05` (`505 / 10 ** 2`).
   *
   * Tokens usually opt for a value of 18, imitating the relationship between
   * Ether and Wei. This is the value {ERC20} uses, unless {_setupDecimals} is
   * called.
   *
   * NOTE: This information is only used for _display_ purposes: it in
   * no way affects any of the arithmetic of the contract, including
   * {IERC20-balanceOf} and {IERC20-transfer}.
   */
  function decimals() public view returns (uint8) {
    return _decimals;
  }

  /**
   * @dev See {IERC20-totalSupply}.
   */
  function totalSupply() public override view returns (uint256) {
    return _totalSupply;
  }

  /**
   * @dev See {IERC20-balanceOf}.
   */
  function balanceOf(address account) public override view returns (uint256) {
    return _balances[account];
  }

  /**
   * @dev See {IERC20-transfer}.
   *
   * Requirements:
   *
   * - `recipient` cannot be the zero address.
   * - the caller must have a balance of at least `amount`.
   */
  function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
    _transfer(_msgSender(), recipient, amount);
    return true;
  }

  /**
   * @dev See {IERC20-allowance}.
   */
  function allowance(address owner, address spender)
    public
    virtual
    override
    view
    returns (uint256)
  {
    return _allowances[owner][spender];
  }

  /**
   * @dev See {IERC20-approve}.
   *
   * Requirements:
   *
   * - `spender` cannot be the zero address.
   */
  function approve(address spender, uint256 amount) public virtual override returns (bool) {
    _approve(_msgSender(), spender, amount);
    return true;
  }

  /**
   * @dev See {IERC20-transferFrom}.
   *
   * Emits an {Approval} event indicating the updated allowance. This is not
   * required by the EIP. See the note at the beginning of {ERC20}.
   *
   * Requirements:
   *
   * - `sender` and `recipient` cannot be the zero address.
   * - `sender` must have a balance of at least `amount`.
   * - the caller must have allowance for ``sender``'s tokens of at least
   * `amount`.
   */
  function transferFrom(
    address sender,
    address recipient,
    uint256 amount
  ) public virtual override returns (bool) {
    _transfer(sender, recipient, amount);
    _approve(
      sender,
      _msgSender(),
      _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance")
    );
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
    _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
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
  function decreaseAllowance(address spender, uint256 subtractedValue)
    public
    virtual
    returns (bool)
  {
    _approve(
      _msgSender(),
      spender,
      _allowances[_msgSender()][spender].sub(
        subtractedValue,
        "ERC20: decreased allowance below zero"
      )
    );
    return true;
  }

  /**
   * @dev Moves tokens `amount` from `sender` to `recipient`.
   *
   * This is internal function is equivalent to {transfer}, and can be used to
   * e.g. implement automatic token fees, slashing mechanisms, etc.
   *
   * Emits a {Transfer} event.
   *
   * Requirements:
   *
   * - `sender` cannot be the zero address.
   * - `recipient` cannot be the zero address.
   * - `sender` must have a balance of at least `amount`.
   */
  function _transfer(
    address sender,
    address recipient,
    uint256 amount
  ) internal virtual {
    require(sender != address(0), "ERC20: transfer from the zero address");
    require(recipient != address(0), "ERC20: transfer to the zero address");

    _beforeTokenTransfer(sender, recipient, amount);

    _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
    _balances[recipient] = _balances[recipient].add(amount);
    emit Transfer(sender, recipient, amount);
  }

  /** @dev Creates `amount` tokens and assigns them to `account`, increasing
   * the total supply.
   *
   * Emits a {Transfer} event with `from` set to the zero address.
   *
   * Requirements:
   *
   * - `to` cannot be the zero address.
   */
  function _mint(address account, uint256 amount) internal virtual {
    require(account != address(0), "ERC20: mint to the zero address");

    _beforeMint();
    _beforeTokenTransfer(address(0), account, amount);

    _totalSupply = _totalSupply.add(amount);
    _balances[account] = _balances[account].add(amount);
    emit Transfer(address(0), account, amount);
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

    _balances[account] = _balances[account].sub(amount, "ERC20: burn amount exceeds balance");
    _totalSupply = _totalSupply.sub(amount);
    emit Transfer(account, address(0), amount);
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
   * @dev Hook that is called before any transfer of tokens. This includes
   * minting and burning.
   */
  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual {}

  /**
   * @dev Hook that is called before any token mint.
   */
  function _beforeMint() internal virtual {}
}

// SPDX-License-Identifier: Apache license 2.0

pragma solidity ^0.7.0;

/**
 * @dev Wrappers over Solidity's arithmetic operations with added overflow
 * checks.
 *
 * Arithmetic operations in Solidity wrap on overflow. This can easily result
 * in bugs, because programmers usually assume that an overflow raises an
 * error, which is the standard behavior in high level programming languages.
 * `SafeMathUint` restores this intuition by reverting the transaction when an
 * operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeMathUint {
  /**
   * @dev Returns the addition of two unsigned integers, reverting on
   * overflow.
   *
   * Counterpart to Solidity's `+` operator.
   *
   * Requirements:
   *
   * - Addition cannot overflow.
   */
  function add(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a + b;
    require(c >= a, "SafeMath: addition overflow");

    return c;
  }

  /**
   * @dev Returns the subtraction of two unsigned integers, reverting on
   * overflow (when the result is negative).
   *
   * Counterpart to Solidity's `-` operator.
   *
   * Requirements:
   *
   * - Subtraction cannot overflow.
   */
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    return sub(a, b, "SafeMath: subtraction overflow");
  }

  /**
   * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
   * overflow (when the result is negative).
   *
   * Counterpart to Solidity's `-` operator.
   *
   * Requirements:
   *
   * - Subtraction cannot overflow.
   */
  function sub(
    uint256 a,
    uint256 b,
    string memory errorMessage
  ) internal pure returns (uint256) {
    require(b <= a, errorMessage);
    uint256 c = a - b;

    return c;
  }

  /**
   * @dev Returns the multiplication of two unsigned integers, reverting on
   * overflow.
   *
   * Counterpart to Solidity's `*` operator.
   *
   * Requirements:
   *
   * - Multiplication cannot overflow.
   */
  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
    if (a == 0) {
      return 0;
    }

    uint256 c = a * b;
    require(c / a == b, "SafeMath: multiplication overflow");

    return c;
  }

  /**
   * @dev Returns the integer division of two unsigned integers. Reverts on
   * division by zero. The result is rounded towards zero.
   *
   * Counterpart to Solidity's `/` operator. Note: this function uses a
   * `revert` opcode (which leaves remaining gas untouched) while Solidity
   * uses an invalid opcode to revert (consuming all remaining gas).
   *
   * Requirements:
   *
   * - The divisor cannot be zero.
   */
  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    return div(a, b, "SafeMath: division by zero");
  }

  /**
   * @dev Returns the integer division of two unsigned integers. Reverts with custom message on
   * division by zero. The result is rounded towards zero.
   *
   * Counterpart to Solidity's `/` operator. Note: this function uses a
   * `revert` opcode (which leaves remaining gas untouched) while Solidity
   * uses an invalid opcode to revert (consuming all remaining gas).
   *
   * Requirements:
   *
   * - The divisor cannot be zero.
   */
  function div(
    uint256 a,
    uint256 b,
    string memory errorMessage
  ) internal pure returns (uint256) {
    require(b > 0, errorMessage);
    uint256 c = a / b;

    return c;
  }

  /**
   * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
   * Reverts when dividing by zero.
   *
   * Counterpart to Solidity's `%` operator. This function uses a `revert`
   * opcode (which leaves remaining gas untouched) while Solidity uses an
   * invalid opcode to revert (consuming all remaining gas).
   *
   * Requirements:
   *
   * - The divisor cannot be zero.
   */
  function mod(uint256 a, uint256 b) internal pure returns (uint256) {
    return mod(a, b, "SafeMath: modulo by zero");
  }

  /**
   * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
   * Reverts with custom message when dividing by zero.
   *
   * Counterpart to Solidity's `%` operator. This function uses a `revert`
   * opcode (which leaves remaining gas untouched) while Solidity uses an
   * invalid opcode to revert (consuming all remaining gas).
   *
   * Requirements:
   *
   * - The divisor cannot be zero.
   */
  function mod(
    uint256 a,
    uint256 b,
    string memory errorMessage
  ) internal pure returns (uint256) {
    require(b != 0, errorMessage);
    return a % b;
  }

  /**
   * @dev Converts an unsigned integer to a signed integer,
   * Reverts when convertation overflows.
   *
   * Requirements:
   *
   * - Operation cannot overflow.
   */
  function toInt256Safe(uint256 a) internal pure returns (int256) {
    int256 b = int256(a);
    require(b >= 0, "SafeMath: convertation overflow");
    return b;
  }
}

// SPDX-License-Identifier: Apache license 2.0

pragma solidity ^0.7.0;

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
   * @dev Moves `amount` tokens from the caller's account to `recipient`.
   *
   * Returns a boolean value indicating whether the operation succeeded.
   *
   * Emits a {Transfer} event.
   */
  function transfer(address recipient, uint256 amount) external returns (bool);

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
   * @dev Moves `amount` tokens from `sender` to `recipient` using the
   * allowance mechanism. `amount` is then deducted from the caller's
   * allowance.
   *
   * Returns a boolean value indicating whether the operation succeeded.
   *
   * Emits a {Transfer} event.
   */
  function transferFrom(
    address sender,
    address recipient,
    uint256 amount
  ) external returns (bool);
}