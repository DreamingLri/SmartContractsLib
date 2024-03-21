pragma solidity ^0.4.11;

import './ERC20Basic.sol';
import './SafeERC20.sol';
import './Ownable.sol';
import './Math.sol';
import './SafeMath.sol';

/**
 * @title TokenVesting
 * @dev A token holder contract that can release its token balance gradually like a
 * typical vesting scheme, with a cliff and vesting period. Optionally revocable by the
 * owner.
 */

contract TokenVesting is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for ERC20Basic;

  struct TokenVestingData  {
    ERC20Basic token;
    address beneficiary;
    uint256 cliff;
    uint256 start;
    uint256 duration;
    bool revocable;
    bool exist;
    mapping (address => uint256) released;
    mapping (address => bool) revoked;
  }

  event Redeemed(uint256 amount);
  event Revoked();

  /**
   * @dev Creates a vesting contract that vests its balance of any ERC20 token to the
   * _beneficiary, gradually in a linear fashion until _start + _duration. By then all
   * of the balance will have vested.
   * @param _beneficiary address of the beneficiary to whom vested tokens are transferred
   * @param _cliff duration in seconds of the cliff in which tokens will begin to vest
   * @param _duration duration in seconds of the period in which the tokens will vest
   * @param _revocable whether the vesting is revocable or not
   */

  mapping(uint256 => TokenVestingData) tokens;
  uint256 count;

  function _mint(ERC20Basic _token, address _beneficiary, uint256 _start, uint256 _cliff, uint256 _duration, bool _revocable) public {
    require(_beneficiary != address(0));
    require(_cliff <= _duration);
    uint256 cliff = _start.add(_cliff);
    tokens[count] = TokenVestingData(_token, _beneficiary, cliff, _start, _duration, _revocable, true);
    count++;
  }

  function getBeneficiary(uint256 id) public view returns (address) {
    require(tokens[id].exist == true, "The supplied Id does not exist");
    return tokens[id].beneficiary;
  }

  function getCliff(uint256 id) public view returns (uint256) {
    require(tokens[id].exist == true, "The supplied Id does not exist");
    return tokens[id].cliff;
  }

  function getStart(uint256 id) public view returns (uint256) {
    require(tokens[id].exist == true, "The supplied Id does not exist");
    return tokens[id].start;
  }

  function getDuration(uint256 id) public view returns (uint256) {
    require(tokens[id].exist == true, "The supplied Id does not exist");
    return tokens[id].duration;
  }

  function getRevocable(uint256 id) public view returns (bool) {
    require(tokens[id].exist == true, "The supplied Id does not exist");
    return tokens[id].revocable;
  }

  function getReleased(address addre, uint256 id) public view returns (uint256) {
    require(tokens[id].exist == true, "The supplied Id does not exist");
    return tokens[id].released[addre];
  }

  function getRevoked(address addre, uint256 id) public view returns (bool) {
    require(tokens[id].exist == true, "The supplied Id does not exist");
    return tokens[id].revoked[addre];
  }

  function addMoney() public payable {

  }


  function redeem(uint256 id) public {
    require(tokens[id].exist == true, "The supplied Id does not exist");

    ERC20Basic token = tokens[id].token;

    uint256 unreleased = releasableAmount(token, id);

    require(unreleased > 0);

    tokens[id].released[token] = tokens[id].released[token].add(unreleased);

    token.safeTransfer(tokens[id].beneficiary, unreleased);

    emit Redeemed(unreleased);
  }

  /**
   * @notice Allows the owner to revoke the vesting. Tokens already vested
   * remain in the contract, the rest are returned to the owner.
   * @param token ERC20 token which is being vested
   */
  function revoke(ERC20Basic token, uint256 id) public onlyOwner {
    require(tokens[id].exist == true, "The supplied Id does not exist");
    require(tokens[id].revocable);
    require(!tokens[id].revoked[token]);

    uint256 balance = token.balanceOf(this);

    uint256 unreleased = releasableAmount(token, id);
    uint256 refund = balance.sub(unreleased);

    tokens[id].revoked[token] = true;

    token.safeTransfer(owner, refund);

    emit Revoked();
  }

  /**
   * @dev Calculates the amount that has already vested but hasn't been released yet.
   * @param token ERC20 token which is being vested
   */
  function releasableAmount(ERC20Basic token, uint256 id) public constant returns (uint256) {
    require(tokens[id].exist == true, "The supplied Id does not exist");
    return vestedAmount(token, id).sub(tokens[id].released[token]);
  }

  function getBalance() public view returns (uint256) {
    return address(this).balance;
  }

  /**
   * @dev Calculates the amount that has already vested.
   * @param token ERC20 token which is being vested
   */
  function vestedAmount(ERC20Basic token, uint256 id) public constant returns (uint256) {
    require(tokens[id].exist == true, "The supplied Id does not exist");
    uint256 currentBalance = token.balanceOf(this);
    uint256 totalBalance = currentBalance.add(tokens[id].released[token]);

    if (now < tokens[id].cliff) {
      return 0;
    } else if (now >= tokens[id].start.add(tokens[id].duration) || tokens[id].revoked[token]) {
      return totalBalance;
    } else {
      return totalBalance.mul(now.sub(tokens[id].start)).div(tokens[id].duration);
    }
  }
}