/**
 *Submitted for verification at Etherscan.io on 2022-11-30
*/

pragma solidity ^0.4.18;

contract Ownable {

  address public owner;

  function Ownable() public {
    owner = msg.sender;
  }

  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }

  function transferOwnership(address newOwner) public onlyOwner {
    owner = newOwner;
  }

}


contract HSEToken is Ownable{
    
    string public constant name = "HSE token";
    string public constant symbol = "hse";
    uint32 constant public decimals = 18;
    uint rate = 100;
    uint256 public totalSupply ;
    mapping(address=>uint256) public balances;
    
    mapping (address => mapping(address => uint)) allowed;
    
   

  function mint(address _to, uint _value) internal {
    assert(totalSupply + _value >= totalSupply && balances[_to] + _value >= balances[_to]);
    balances[_to] += _value;
    totalSupply += _value;
  }

  function balanceOf(address _owner) public constant returns (uint balance) {
    return balances[_owner];
  }

  function transfer(address _to, uint _value) public returns (bool success) {
    if(balances[msg.sender] >= _value && balances[_to] + _value >= balances[_to]) {
      balances[msg.sender] -= _value;
      balances[_to] += _value;
      Transfer(msg.sender, _to, _value);
      return true;
    }
    return false;
  }

  function transferFrom(address _from, address _to, uint _value) public returns (bool success) {
    if( allowed[_from][msg.sender] >= _value &&
    balances[_from] >= _value
    && balances[_to] + _value >= balances[_to]) {
      allowed[_from][msg.sender] -= _value;
      balances[_from] -= _value;
      balances[_to] += _value;
      Transfer(_from, _to, _value);
      return true;
    }
    return false;
  }

  function approve(address _spender, uint _value) public returns (bool success) {
    allowed[msg.sender][_spender] = _value;
    Approval(msg.sender, _spender, _value);
    return true;
  }

  function allowance(address _owner, address _spender) public constant returns (uint remaining) {
    return allowed[_owner][_spender];
  }

  event Transfer(address indexed _from, address indexed _to, uint _value);

  event Approval(address indexed _owner, address indexed _spender, uint _value);

  function getTokenAmount(uint256 _value) internal view returns (uint256) {
    return _value * rate;
  }

  function () payable {
    uint256 weiAmount = msg.value;
    uint256 tokens = getTokenAmount(weiAmount);
    mint(msg.sender, tokens);
  }

}