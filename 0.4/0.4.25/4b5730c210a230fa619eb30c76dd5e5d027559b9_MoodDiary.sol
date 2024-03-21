/**
 *Submitted for verification at Etherscan.io on 2022-09-25
*/

pragma solidity ^0.4.25;

/// a simple set and get function for mood defined: 

contract MoodDiary{
    
    string mood;
    
    function setMood(string _mood) public{
        mood = _mood;
    }
    
    function getMood() public view returns(string){
        return mood;
    }
}