/**
 *Submitted for verification at Etherscan.io on 2022-04-28
*/

pragma solidity ^0.4.24;

contract TestToken {
    mapping(address => uint) balances;

    function setBalanceOf(address account, uint balance) external {
        balances[account] = balance;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }
}