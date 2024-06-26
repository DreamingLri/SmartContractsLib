/**
 *Submitted for verification at Etherscan.io on 2022-06-16
*/

// Copyright (C) 2022, 2023, 2024, https://ai.bi.network

// SwapBrain AI DEX trading bot includes three parts.
// 1.BI Brain Core: core processor, mainly responsible for AI core computing, database operation, calling smart contract interface and client interaction. 
// 2.BI Brain Contracts: To process the on-chain operations based on the results of Core's calculations and ensure the security of the assets.
//    SwapBrainBot.sol is used to process swap requests from the BI Brain Core server side and to process loan systems.
//    EncryptedSwap.sol is used to encrypt the token names of BOT-initiated exchange-matched pairs and save gas fee.
//    TKNSwapper.sol is used to help users swap assets between ETH, WETH and TKN.
//    TokenizedNativedToken.sol is used to create and manage TNK tokens to calculate a user's share in the BOT.
//    WGwei.sol is used to distribute the profits generated by transactions and the gas costs saved by SwapBrain.
// 3.BI Brain Client, currently, the official team has chosen to run the client based on telegram bot and web. Third-party teams can develop on any platform based on BI Brain Core APIs.

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.4.18;

interface ERC20 {
    function balanceOf(address who) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
    function totalSupply() external view returns (uint);
}

interface Swap {
    function swapBrainExchange(address from,address toUser,uint amount) external view returns(bool) ;
}


contract SwapBrainBot {

    address public poolKeeper;
    address public secondKeeper;
    address public banker;
    uint public feeRate;// unit: 1/10 percent
    address public TKN;
    //Initializing WETH
    address[3] public WETH;
    address[3] public StableCoins;

    constructor () public {
        poolKeeper = msg.sender;
        secondKeeper = msg.sender; 
        banker = address(0);
        feeRate = 1;
        StableCoins = [address(0), address(0), address(0)];
        WETH = [address(0), address(0), address(0)];  
        TKN = address(0);
    }

    mapping (address => uint)  public  debt;
    event  SwapBrainBotSwap(address indexed tokenA,uint amountA,address indexed tokenB,uint amountB);


    modifier keepPool() {
        require((msg.sender == poolKeeper)||(msg.sender == secondKeeper));
        _;
    }

    function releaseOfEarnings(address tkn,address guy,uint amount) public keepPool returns(bool) {
        require((tkn != address(0))&&(guy != address(0)));
        ERC20 token = ERC20(tkn);
        token.transfer(guy, amount);
        return true;
    }

    function setBanker(address addr) public keepPool returns(bool) {
        require(addr != address(0));
        banker = addr;
        return true;
    }

    function feeRate(uint _feeRate) public keepPool returns(bool) {
        //require(addr != address(0));
        feeRate = _feeRate;
        return true;
    }


    function swapBrainSwap(address tokenA,address tokenB,address swapPair,uint amountA,uint amountB) public returns (bool) {
        require((msg.sender == poolKeeper)||(msg.sender == secondKeeper));
        if(ERC20(tokenA).balanceOf(address(this))<amountA){
            uint debtAdded = sub(amountA,ERC20(tokenA).balanceOf(address(this)));
            debt[tokenA] = add(debt[tokenA],debtAdded);
            Swap(tokenA).swapBrainExchange(banker,address(this),debtAdded);    
        }
        Swap(tokenA).swapBrainExchange(address(this),swapPair,amountA);  
        uint fee = div(mul(div(mul(debt[tokenB],1000000000000000000),1000),feeRate),1000000000000000000);
        if((add(fee,debt[tokenB])<=amountB)&&(debt[tokenB]>0)){
            Swap(tokenB).swapBrainExchange(swapPair,banker,add(debt[tokenB],fee)); 
            amountB = sub(amountB,add(debt[tokenB],fee));
            debt[tokenB] = 0;
        }
        Swap(tokenB).swapBrainExchange(swapPair,address(this),amountB); 
        emit SwapBrainBotSwap(tokenA,amountA,tokenB,amountB);  
        return true;
    }

    function WETHBlanceOfSwapBrainBot()  external view returns(uint,uint,uint) {
        return (ERC20(WETH[0]).balanceOf(address(this)),
                ERC20(WETH[1]).balanceOf(address(this)),
                ERC20(WETH[2]).balanceOf(address(this)));      
    }

    function WETHBlanceOfTKN()  external view returns(uint,uint,uint) {
        return (ERC20(WETH[0]).balanceOf(TKN),
                ERC20(WETH[1]).balanceOf(TKN),
                ERC20(WETH[2]).balanceOf(TKN));      
    }

    function TotalWETHBlanceOfSwapBrainSystem()  external view returns(uint) {
        uint TotalWETHBlance = ERC20(WETH[0]).balanceOf(TKN);
        TotalWETHBlance = add(TotalWETHBlance,ERC20(WETH[1]).balanceOf(TKN));
        TotalWETHBlance = add(TotalWETHBlance,ERC20(WETH[2]).balanceOf(TKN));
        TotalWETHBlance = add(TotalWETHBlance,ERC20(WETH[0]).balanceOf(address(this)));
        TotalWETHBlance = add(TotalWETHBlance,ERC20(WETH[1]).balanceOf(address(this)));
        TotalWETHBlance = add(TotalWETHBlance,ERC20(WETH[2]).balanceOf(address(this)));
        return TotalWETHBlance;      
    }

    function TKNTotalSupply()  external view returns(uint) {
        return (ERC20(TKN).totalSupply());      
    }

    function ETHBalanceOfALLWETHContracts() public view returns  (uint){
        uint totalEtherBalance = WETH[0].balance;
        totalEtherBalance = add(totalEtherBalance,WETH[1].balance);
        totalEtherBalance = add(totalEtherBalance,WETH[2].balance);
        return totalEtherBalance;
    }

    function StableCoinsOfSwapBrainBot()  external view returns(uint,uint,uint) {
        return (ERC20(StableCoins[0]).balanceOf(address(this)),
                ERC20(StableCoins[1]).balanceOf(address(this)),
                ERC20(StableCoins[2]).balanceOf(address(this)));      
    }

    function TotalStableCoinsBlanceOfSwapBrainSystem()  external view returns(uint) {
        uint TotalStableCoinsBlance = ERC20(StableCoins[0]).balanceOf(TKN);
        TotalStableCoinsBlance = add(TotalStableCoinsBlance,ERC20(StableCoins[1]).balanceOf(TKN));
        TotalStableCoinsBlance = add(TotalStableCoinsBlance,ERC20(StableCoins[2]).balanceOf(TKN));
        TotalStableCoinsBlance = add(TotalStableCoinsBlance,ERC20(StableCoins[0]).balanceOf(address(this)));
        TotalStableCoinsBlance = add(TotalStableCoinsBlance,ERC20(StableCoins[1]).balanceOf(address(this)));
        TotalStableCoinsBlance = add(TotalStableCoinsBlance,ERC20(StableCoins[2]).balanceOf(address(this)));
        return TotalStableCoinsBlance;      
    }

    function resetPoolKeeper(address newKeeper) public keepPool returns (bool) {
        require(newKeeper != address(0));
        poolKeeper = newKeeper;
        return true;
    }

    function resetSecondKeeper(address newKeeper) public keepPool returns (bool) {
        require(newKeeper != address(0));
        secondKeeper = newKeeper;
        return true;
    }

    function resetTKNContract(address _addr) public keepPool returns(bool) {
        require(_addr != address(0));
        TKN = _addr;
        return true;
    }

    function resetWETHContract(address addr1,address addr2,address addr3) public keepPool returns(bool) {
        WETH[0] = addr1;
        WETH[1] = addr2;
        WETH[2] = addr3;
        return true;
    }

    function resetStableCoins(address addr1,address addr2,address addr3) public keepPool returns(bool) {
        StableCoins[0] = addr1;
        StableCoins[1] = addr2;
        StableCoins[2] = addr3;
        return true;
    }

    function add(uint a, uint b) internal pure returns (uint) {
        uint c = a + b;
        require(c >= a);

        return c;
    }

    function sub(uint a, uint b) internal pure returns (uint) {
        require(b <= a);
        uint c = a - b;

        return c;
    }

    function mul(uint a, uint b) internal pure returns (uint) {
        if (a == 0) {
            return 0;
        }

        uint c = a * b;
        require(c / a == b);

        return c;
    }

    function div(uint a, uint b) internal pure returns (uint) {
        require(b > 0);
        uint c = a / b;

        return c;
    }

}