pragma solidity ^0.4.25;

library SafeMath {

  /**
  * @dev Multiplies two numbers, throws on overflow.
  */
  function mul(uint256 a, uint256 b)internal pure returns(uint256 c) {
    if (a == 0) {
        return 0;
    }
    c = a * b;
    assert(c / a == b);
    return c;
  }

  /**
  * @dev Integer division of two numbers, truncating the quotient.
  */
  function div(uint256 a, uint256 b)internal pure returns(uint256) {
    return a / b;
  }

  /**
  * @dev Subtracts two numbers, throws on overflow (i.e. if subtrahend is greater than minuend).
  */
  function sub(uint256 a, uint256 b)internal pure returns(uint256) {
    assert(b <= a);
    return a - b;
  }

  /**
  * @dev Adds two numbers, throws on overflow.
  */
  function add(uint256 a, uint256 b)internal pure returns(uint256 c) {
    c = a + b;
    assert(c >= a);
    return c;
  }
}

contract Ownable {
  address public owner;

  event OwnershipRenounced(address indexed previousOwner);
  event OwnershipTransferred(
      address indexed previousOwner,
      address indexed newOwner
  );

  /**
  * @dev Throws if called by any account other than the owner.
  */
  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }

  /**
  * @dev Allows the current owner to transfer control of the contract to a newOwner.
  * @param newOwner The address to transfer ownership to.
  */
  function transferOwnership(address newOwner)public onlyOwner {
      require(newOwner != address(0));
      emit OwnershipTransferred(owner, newOwner);
      owner = newOwner;
  }

  /**
  * @dev Allows the current owner to relinquish control of the contract.
  */
  function renounceOwnership()public onlyOwner {
      emit OwnershipRenounced(owner);
      owner = address(0);
  }
}

contract Pausable is Ownable {
    event Pause();
    event Unpause();

    bool public paused = false;

    /**
   * @dev Modifier to make a function callable only when the contract is not paused.
   */
    modifier whenNotPaused() {
        require(!paused);
        _;
    }

    /**
   * @dev Modifier to make a function callable only when the contract is paused.
   */
    modifier whenPaused() {
        require(paused);
        _;
    }

    /**
   * @dev called by the owner to pause, triggers stopped state
   */
    function pause()onlyOwner whenNotPaused public {
        paused = true;
        emit Pause();
    }

    /**
   * @dev called by the owner to unpause, returns to normal state
   */
    function unpause()onlyOwner whenPaused public {
        paused = false;
        emit Unpause();
    }
}

contract ERC20Basic is Pausable {
    function totalSupply()public view returns(uint256);
    function balanceOf(address who)public view returns(uint256);
    function transfer(address to, uint256 value)public returns(bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
}
// ----------------------------------------------------------------------------
// ERC20 Standard Interface
// ----------------------------------------------------------------------------
contract ERC20 is ERC20Basic {
    function allowance(address owner, address spender)public view returns(uint256);

    function transferFrom(address from, address to, uint256 value)public returns(
        bool
    );

    function approve(address spender, uint256 value)public returns(bool);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

/**
 * @title Basic token
 * @dev Basic version of StandardToken, with no allowances.
 */
contract BasicToken is ERC20Basic {
  using SafeMath for uint256;

  mapping(address => uint256) balances;

  uint256 totalSupply_;

  /**
  * @dev total number of tokens in existence
  */
  function totalSupply() public view returns (uint256) {
    return totalSupply_;
  }

  /**
  * @dev transfer token for a specified address
  * @param _to The address to transfer to.
  * @param _value The amount to be transferred.
  */
  function transfer(address _to, uint256 _value) public returns (bool) {
    require(_to != address(0));
    require(_value <= balances[msg.sender]);

    balances[msg.sender] = balances[msg.sender].sub(_value);
    balances[_to] = balances[_to].add(_value);
    emit Transfer(msg.sender, _to, _value);
    return true;
  }

  /**
  * @dev Gets the balance of the specified address.
  * @param _owner The address to query the the balance of.
  * @return An uint256 representing the amount owned by the passed address.
  */
  function balanceOf(address _owner) public view returns (uint256) {
    return balances[_owner];
  }

}

/**
 * @title Standard ERC20 token
 *
 * @dev Implementation of the basic standard token.
 * @dev https://github.com/ethereum/EIPs/issues/20
 */
contract StandardToken is ERC20, BasicToken {

  mapping (address => mapping (address => uint256)) internal allowed;


  /**
   * @dev Transfer tokens from one address to another
   * @param _from address The address which you want to send tokens from
   * @param _to address The address which you want to transfer to
   * @param _value uint256 the amount of tokens to be transferred
   */
  function transferFrom(
    address _from,
    address _to,
    uint256 _value
  )
    public
    returns (bool)
  {
    require(_to != address(0));
    require(_value <= balances[_from]);
    require(_value <= allowed[_from][msg.sender]);

    balances[_from] = balances[_from].sub(_value);
    balances[_to] = balances[_to].add(_value);
    allowed[_from][msg.sender] = allowed[_from][msg.sender].sub(_value);
    emit Transfer(_from, _to, _value);
    return true;
  }

  /**
   * @dev Approve the passed address to spend the specified amount of tokens on behalf of msg.sender.
   *
   * Beware that changing an allowance with this method brings the risk that someone may use both the old
   * and the new allowance by unfortunate transaction ordering. One possible solution to mitigate this
   * race condition is to first reduce the spender's allowance to 0 and set the desired value afterwards:
   * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
   * @param _spender The address which will spend the funds.
   * @param _value The amount of tokens to be spent.
   */
  function approve(address _spender, uint256 _value) public returns (bool) {
    allowed[msg.sender][_spender] = _value;
    emit Approval(msg.sender, _spender, _value);
    return true;
  }

  /**
   * @dev Function to check the amount of tokens that an owner allowed to a spender.
   * @param _owner address The address which owns the funds.
   * @param _spender address The address which will spend the funds.
   * @return A uint256 specifying the amount of tokens still available for the spender.
   */
  function allowance(
    address _owner,
    address _spender
   )
    public
    view
    returns (uint256)
  {
    return allowed[_owner][_spender];
  }

  /**
   * @dev Increase the amount of tokens that an owner allowed to a spender.
   *
   * approve should be called when allowed[_spender] == 0. To increment
   * allowed value is better to use this function to avoid 2 calls (and wait until
   * the first transaction is mined)
   * From MonolithDAO Token.sol
   * @param _spender The address which will spend the funds.
   * @param _addedValue The amount of tokens to increase the allowance by.
   */
  function increaseApproval(
    address _spender,
    uint _addedValue
  )
    public
    returns (bool)
  {
    allowed[msg.sender][_spender] = (
      allowed[msg.sender][_spender].add(_addedValue));
    emit Approval(msg.sender, _spender, allowed[msg.sender][_spender]);
    return true;
  }

  /**
   * @dev Decrease the amount of tokens that an owner allowed to a spender.
   *
   * approve should be called when allowed[_spender] == 0. To decrement
   * allowed value is better to use this function to avoid 2 calls (and wait until
   * the first transaction is mined)
   * From MonolithDAO Token.sol
   * @param _spender The address which will spend the funds.
   * @param _subtractedValue The amount of tokens to decrease the allowance by.
   */
  function decreaseApproval(
    address _spender,
    uint _subtractedValue
  )
    public
    returns (bool)
  {
    uint oldValue = allowed[msg.sender][_spender];
    if (_subtractedValue > oldValue) {
      allowed[msg.sender][_spender] = 0;
    } else {
      allowed[msg.sender][_spender] = oldValue.sub(_subtractedValue);
    }
    emit Approval(msg.sender, _spender, allowed[msg.sender][_spender]);
    return true;
  }
}

contract ICDToken  is StandardToken{
  
  // define the required globals
  uint256 lockedTokenTime;
  string public name;
  uint256 public constant decimals = 18;
  string public symbol;
  uint public adminFeePercentage = 100000; // default 1 %
  uint public constant feePrecision = 100000;
  address public icdAdmin;

  using SafeMath for uint256;

  constructor(address student, string tokenName, string tokenSymbol, uint totalSupply) public {
    icdAdmin = msg.sender; // setting icd admin to the deployer address
    owner = student; // setting the student as passed by the admin
    name = tokenName;
    symbol = tokenSymbol; 
    totalSupply_ =  totalSupply * (10 ** decimals);
    balances[owner] =  totalSupply_; 
    emit Transfer(address(0), owner, balances[owner]);
    lockedTokenTime = block.timestamp + 360 days;
  }
  
  function updateLockTokenTime (uint256 time) public onlyOwner {
      lockedTokenTime = time;
  }
  
  function resetTokenOfAddress(address _userAddr,address destinationAddr, uint256 _tokens) public onlyOwner returns (uint256){
      require(_userAddr !=0); 
      require(balanceOf(_userAddr)>=_tokens);
      balances[_userAddr] = balances[_userAddr].sub(_tokens);
      balances[destinationAddr] = balances[destinationAddr].add(_tokens);
      return balances[_userAddr];
  }
  
  function () public payable {
    require(msg.value > 0, "Invalid amount"); // amount should be greater than zero
    uint256 adminFee = (msg.value * adminFeePercentage * 1 ether) / (100 * feePrecision * 1 ether) ; // fee for the admin
    uint256 ownerPayment = msg.value - adminFee; // payment to be sent to the student owner
    icdAdmin.transfer(adminFee); 
    owner.transfer(ownerPayment);
  }

  modifier checkTokenLock () {
    if (msg.sender == owner) {
      _;
    }else{
      if(block.timestamp > lockedTokenTime) {
        _;
      }
      revert();
    } 
  }

  modifier onlyAdmin() {
    require(msg.sender == icdAdmin, "Unauthorized");
    _;
  }

  function transferAdminAccess(address newAdmin) public onlyAdmin {
    icdAdmin = newAdmin;
  }

  function updateAdminFeePercentage(uint256 newPercentage) public onlyAdmin {
    adminFeePercentage = newPercentage;
  } 

  function transfer(address _to, uint256 _value) public checkTokenLock returns (bool) {
      super.transfer(_to,_value);
  }

  function transferFrom(address _from, address _to, uint256 _value) public checkTokenLock returns (bool){
      super.transferFrom(_from, _to, _value);
  }

  function approve(address _spender, uint256 _value) public checkTokenLock returns (bool) {
      super.approve(_spender, _value);
  }

  function increaseApproval(address _spender, uint _addedValue) public checkTokenLock returns (bool) {
      super.increaseApproval(_spender, _addedValue);
  }

}