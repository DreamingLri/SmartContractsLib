/**
 *Submitted for verification at polygonscan.com on 2021-12-13
*/

pragma solidity ^0.4.11;

contract AddressStore {
    address[] public bought;

    // set the addresses in store
    function setStore(address[] _addresses) public {
        bought = _addresses;
    }
}