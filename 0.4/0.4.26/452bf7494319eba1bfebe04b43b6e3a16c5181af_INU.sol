/**
 *Submitted for verification at Etherscan.io on 2022-04-07
*/

// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.4.26;
contract INU {
    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
    string public constant name = "Inu_Infinity";
    string public constant symbol = "INU";
    uint8 public constant decimals = 18;
    // uint256 public constant totalSupply_ = 50000000;
    mapping(address => uint256) balances;

    mapping(address => mapping (address => uint256)) allowed;

   uint256 totalSupply_;

    constructor() {
      totalSupply_ = 50000000;
      balances[msg.sender] = totalSupply_;
    }

    function totalSupply() public view returns (uint256) {
      return totalSupply_;
    }

    function balanceOf(address tokenOwner) public view returns (uint) {
        return balances[tokenOwner];
    }

    function transfer(address receiver, uint numTokens) public returns (bool) {
        require(numTokens <= balances[msg.sender]);
        balances[msg.sender] -= numTokens;
        balances[receiver] += numTokens;
        emit Transfer(msg.sender, receiver, numTokens);
        return true;
    }

    function approve(address delegate, uint numTokens) public returns (bool) {
        allowed[msg.sender][delegate] = numTokens;
        emit Approval(msg.sender, delegate, numTokens);
        return true;
    }

    function allowance(address owner, address delegate) public view returns (uint) {
        return allowed[owner][delegate];
    }

    function transferFrom(address owner, address buyer, uint numTokens) public returns (bool) {
        require(numTokens <= balances[owner]);
        require(numTokens <= allowed[owner][msg.sender]);

        balances[owner] -= numTokens;
        allowed[owner][msg.sender] -= numTokens;
        balances[buyer] += numTokens;
        emit Transfer(owner, buyer, numTokens);
        return true;
    }
 address public owner;

    function Ownable() {
    owner = msg.sender;
  }

     modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }
  function transferOwnership(address newOwner) onlyOwner {
    if (newOwner != address(0)) {
      owner = newOwner;
    }
}
}