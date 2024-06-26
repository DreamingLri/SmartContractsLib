/**
 *Submitted for verification at Etherscan.io on 2021-04-23
*/

pragma solidity ^0.4.24;
pragma experimental ABIEncoderV2;


contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor () internal {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), _owner);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(isOwner(), "Ownable: caller is not the owner");
        _;
    }

    function isOwner() public view returns (bool) {
        return msg.sender == _owner;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        _transferOwnership(newOwner);
    }
    
    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

contract ERC20Interface {
    function totalSupply() public view returns (uint);
    function balanceOf(address tokenOwner) public view returns (uint balance);
    function allowance(address tokenOwner, address spender) public view returns (uint remaining);
    function transfer(address to, uint tokens) public returns (bool success);
    function approve(address spender, uint tokens) public returns (bool success);
    function transferFrom(address from, address to, uint tokens) public returns (bool success);

    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}


contract SafeMath {
    function safeAdd(uint a, uint b) internal pure returns (uint c) {
        c = a + b;
        require(c >= a);
    }
    
    function safeSub(uint a, uint b) internal pure returns (uint c) {
        require(b <= a); c = a - b; 
        
    } 
    
    function safeMul(uint a, uint b) internal pure returns (uint c) { 
        c = a * b; require(a == 0 || c / a == b); 
        
    } 
    
    function safeDiv(uint a, uint b) internal pure returns (uint c) { 
        require(b > 0);
        c = a / b;
    }
}


contract eXTM is ERC20Interface, SafeMath, Ownable {

    string public name;	
    string public symbol;	
    uint8 public decimals;
    uint256 internal _totalSupply;

    mapping(address => uint) balances;	
    mapping(address => mapping(address => uint)) allowed;

    event Mint(address indexed minter, address indexed account, uint256 amount);
    event Burn(address indexed burner, address indexed account, uint256 amount);
    event BridgeToBSC(address indexed fromAccount, address indexed toAccount, uint256 amount);
    
    struct OffchainMetaData {
        address[] offChainToAddress;
        uint256[] tokenAmount;
        uint256[] txFee;
        uint16[] chain;
    }
    
    address public onChainBridgeAddress;
    mapping(address => OffchainMetaData) metaData;
    
    address public feeVaultAddress;
    uint256 public transactionFee;
    bool public isFeePercentage;
    uint256 actualTokenAmount;
    uint256 actualTransactionFee;
    
    

    constructor () public {
        symbol = "eXTM";
        name = "Torum";
        decimals = 18;
        _totalSupply = 0;
        balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }
    
    modifier onlyAllocatedOwner() {
        require(msg.sender == onChainBridgeAddress, "Ownable: caller is not the owner");
        _;
    }

    
    function totalSupply() public view returns (uint) {
        return _totalSupply  - balances[address(0)];
    }
    
    function balanceOf(address tokenOwner) public view returns (uint balance) {
        return balances[tokenOwner];
    }
    
    function allowance(address tokenOwner, address spender) public view returns (uint remaining) {
        return allowed[tokenOwner][spender];
    }
    
    function approve(address spender, uint tokens) public returns (bool success) {
        allowed[msg.sender][spender] = tokens;
        emit Approval(msg.sender, spender, tokens);
        return true;
    }
    
    function transfer(address to, uint tokens) public returns (bool success) {
        balances[msg.sender] = safeSub(balances[msg.sender], tokens);
        balances[to] = safeAdd(balances[to], tokens);
        emit Transfer(msg.sender, to, tokens);
        return true;
    }
    
    function transferFrom(address from, address to, uint tokens) public returns (bool success) {
        balances[from] = safeSub(balances[from], tokens);
        allowed[from][msg.sender] = safeSub(allowed[from][msg.sender], tokens);
        balances[to] = safeAdd(balances[to], tokens);
        emit Transfer(from, to, tokens);
        return true;
    }
 
    function mintTo(address _to, uint _amount) public onlyAllocatedOwner {
        require(_to != address(0), 'ERC20: to address is not valid');
        require(_amount > 0, 'ERC20: amount is not valid');

        _totalSupply = safeAdd(_totalSupply, _amount);
        balances[_to] = safeAdd(balances[_to], _amount);

        emit Mint(msg.sender, _to, _amount);
    }

    function burnFrom(address _from, uint _amount) public {
        require(_from != address(0), 'ERC20: from address is not valid');
        require(balances[_from] >= _amount, 'ERC20: insufficient balance');
        
        balances[_from] = safeSub(balances[_from], _amount);
        _totalSupply = safeSub(_totalSupply, _amount);

        emit Burn(msg.sender, _from, _amount);
    }

    function setOnChainBridgeAddress(address _onChainBridgeAddress) public onlyOwner returns (bool success) {
        require(_onChainBridgeAddress != address(0));
        onChainBridgeAddress = _onChainBridgeAddress;
        return true;
    }
    
    function createMetaData(address _offChainToAddress, uint256 _tokenAmount, uint256 _transactionFee, uint16 _chain) internal returns(bool) {
        metaData[msg.sender].offChainToAddress.push(_offChainToAddress);
        metaData[msg.sender].tokenAmount.push(_tokenAmount);
        metaData[msg.sender].txFee.push(_transactionFee);
        metaData[msg.sender].chain.push(_chain);
        return true;
    }
    
    function getMetaData(address inputAddress) public view returns (OffchainMetaData memory) {
        return (metaData[inputAddress]);
    }
    
    function setFeeVaultAddress(address _feeVaultAddress) public onlyOwner returns (bool success) {
        require(_feeVaultAddress != address(0));
        feeVaultAddress = _feeVaultAddress;
        return true;
    }
    
    function setTransactionFee(bool _isFeePercentage, uint256 _transactionFee) public onlyOwner returns (bool success) {
        require(_transactionFee >= 0);
        if(_isFeePercentage) {
            require(_transactionFee < 100);
        }
        
        isFeePercentage = _isFeePercentage;
        transactionFee = _transactionFee;
        return true;
    }
    
    function calculateTransactionFee(uint256 _tokenAmount) internal returns (uint256 _actualTokenAmount, uint256 _actualTransactionFee) {
        if(isFeePercentage) {
            require(_tokenAmount > 0);
            actualTransactionFee = safeDiv(safeMul(_tokenAmount, transactionFee), 100);
        } else {
            actualTransactionFee = transactionFee;
        }
        actualTokenAmount = safeSub(_tokenAmount, actualTransactionFee);
        
        return (actualTokenAmount, actualTransactionFee);
    }
    
    function forwardToAddress(address _offChainToAddress, uint256 _tokenAmount) public returns (bool success) {
        require(_offChainToAddress != address(0));
        require(_tokenAmount > 0);
        mintTo(_offChainToAddress, _tokenAmount);
        return true;
    }
    
    function transferToBridge(address _offChainToAddress, uint256 _tokenAmount, uint16 _chain) public returns (bool success) {
        require(onChainBridgeAddress != address(0));
        (actualTokenAmount, actualTransactionFee) = calculateTransactionFee(_tokenAmount);
        
        require((safeAdd(actualTokenAmount, actualTransactionFee)) <= _tokenAmount);
        
        burnFrom(msg.sender, actualTokenAmount);
        balances[feeVaultAddress] = safeAdd(balances[feeVaultAddress], actualTransactionFee);
        
        createMetaData(_offChainToAddress, actualTokenAmount, actualTransactionFee, _chain);
        emit BridgeToBSC(msg.sender, onChainBridgeAddress, actualTokenAmount);
        
        if(actualTransactionFee > 0){
            emit BridgeToBSC(msg.sender, feeVaultAddress, actualTransactionFee);
        }
        
        return true;
    }

    function pauseTransferToBridge() public onlyOwner returns (bool success) {
        onChainBridgeAddress = address(0);
        return true;
    }

}