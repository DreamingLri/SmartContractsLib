/**
 *Submitted for verification at polygonscan.com on 2022-07-02
*/

pragma solidity ^0.4.24;


contract Proxy_Storage {
    uint256 public value;
}
contract contrac_V1 is Proxy_Storage {
    function setvalue(uint256 _value) public {
        value = _value;
    }
}