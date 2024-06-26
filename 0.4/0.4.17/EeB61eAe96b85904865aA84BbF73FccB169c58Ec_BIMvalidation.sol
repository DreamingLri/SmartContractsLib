/**
 *Submitted for verification at polygonscan.com on 2022-03-22
*/

// File: https://github.com/giupt/BIMvalidation/blob/main/Ownable.sol

pragma solidity ^0.4.17;

//@title Ownable
//@dev The Ownable contract has an owner address, and provides basic authorization control
//functions, this simplifies the implementation of "user permissions"

contract Ownable {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

//@dev The Ownable constructor sets the original `owner` of the contract to the sender

    constructor() public {
        owner = msg.sender;
    }


//@dev Throws if called by any account other than the owner
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }


//@dev Allows the current owner to transfer control of the contract to a newOwner
//@param newOwner The address to transfer ownership to
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0));
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

// File: https://github.com/giupt/BIMvalidation/blob/main/OracleInterface.sol

pragma solidity ^0.4.17;

contract OracleInterface {

enum VerificationResult {
        Pending,    //verification is under decision
        Validated,  //verification has met the minimum level of compliance
        Rejected    //verification hasn't met the minimum level of compliance
    }

    function verificationExists(bytes32 _verificationId) public view returns (bool); 
   
    function getVerification(bytes32 _verificationId) public view returns (
       bytes32 id,
        string discipline,
        string team,
        uint cycle,
        uint date,
        uint percentage,
        VerificationResult result);

    function testConnection() public pure returns (bool);

    function addTestData() public; 
}

// File: thesis/BIMValidation.sol

pragma solidity ^0.4.17;




/// @title BIMvalidation
/// @notice Takes verifications and handles payouts if they are validated 
contract BIMvalidation is Ownable {
    

    //this creates a simple mapping of an ethereum address to a number
    mapping(address => uint) public balances;

    //mappings 
    mapping(bytes32 => Validation[]) private verificationToValidations;

    /// send/deposit money in the contract
    function deposit() onlyOwner public payable {
        balances[msg.sender] += msg.value;
    }
    
    //This returns the full amount of ETH the contract holds
    function getBalance() public view returns (uint) {
        return balances[msg.sender];
    }

    //BIM verification results oracle 
    address internal BIMOracleAddr = 0;
    OracleInterface internal BIMOracle = OracleInterface(BIMOracleAddr); 


    struct Validation {
        bytes32 verificationId;
        uint amount;
        uint obtainedPercentage;
        uint8 chosenResult;
    }


    /// @notice sets the address of the boxing oracle contract to use 
    /// @dev setting a wrong address may result in false return value, or error 
    /// @param _oracleAddress the address of the boxing oracle 
    /// @return true if connection to the new oracle address was successful
    function setOracleAddress(address _oracleAddress) external onlyOwner returns (bool) {
        BIMOracleAddr = _oracleAddress;
        BIMOracle = OracleInterface(BIMOracleAddr); 
        return BIMOracle.testConnection();
    }

    /// @notice gets the address of the boxing oracle being used 
    /// @return the address of the currently set oracle 
    function getOracleAddress() external view returns (address) {
        return BIMOracleAddr;
    }
 

    /// @notice returns the full data of the specified verification 
    /// @param _verificationId the id of the desired verification
    /// @return verification data 
    function getVerification(bytes32 _verificationId) public view returns (
        bytes32 id,
        string discipline,
        string team,
        uint cycle,
        uint date,
        uint percentage,
        OracleInterface.VerificationResult result) {

        return BIMOracle.getVerification(_verificationId); 
    }

    ///a specific account can withdraw the money if the result is approved this withdraws all the money that an account has send to the contract
    /// @param _amount is the amount of money to be sent to the design team 
    function withdraw(address _receiver, uint _amount, uint _obtainedPercentage, uint8 _chosenResult) onlyOwner public payable {
        require(balances[msg.sender] >= _amount, "Insufficient funds");
        require(_obtainedPercentage >=90, "Insufficient percentage");
        require(_chosenResult == 1, "Design not validated");
        balances[msg.sender] -= _amount;
        balances[_receiver] += _amount;
    }


    /// @notice for testing; tests that the BIM oracle is callable 
    /// @return true if connection successful 
    function testOracleConnection() public view returns (bool) {
        return BIMOracle.testConnection(); 
    }
}