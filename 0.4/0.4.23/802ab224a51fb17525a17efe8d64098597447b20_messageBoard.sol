/**
 *Submitted for verification at Etherscan.io on 2021-12-15
*/

pragma solidity ^0.4.23;

contract messageBoard {
    string public message;
    int public num = 129;
    int public people = 0;
    function messageBoard(string initMessage) public {
        message = initMessage;
    }
    function editMessage(string _editMessage) public{
        message = _editMessage;
    }
    function showMessage() public view{
        message = 'abcd';
    }
    // 函式 return 傳值
    function callMessage() public view returns(string){
        return message;
    }
    function pay() public payable{
        people++;
    }
    
}