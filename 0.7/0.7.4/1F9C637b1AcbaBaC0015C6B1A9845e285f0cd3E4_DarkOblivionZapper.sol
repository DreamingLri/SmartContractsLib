// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity 0.7.4;

import "./interfaces/IAxMatic.sol";
import "./interfaces/IaxMatic_Direct.sol";
import "./openzeppelin/TokensRecoverable.sol";
import "./openzeppelin/Owned.sol";
import "./libraries/UniswapV2LibrarySushi.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IMagicTransferGate.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IERC31337.sol";
import "./interfaces/IDragonZapper.sol";
import "./openzeppelin/ReentrancyGuard.sol";
import "./interfaces/IERC1155.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Pair.sol";

// zapper contract for Drax-dMagic LP => Dark Oblivion
contract DarkOblivionZapper is Owned, TokensRecoverable, ReentrancyGuard
{
    using SafeMath for uint256;
    
    IAxMatic public immutable axMatic;
    IERC20 public immutable dmagic;
    IERC20 public immutable Drax;
    IDragonZapper public immutable dragonDirect;
    IaxMatic_Direct public immutable axMaticDirect;
    IERC31337 public immutable LPNFTWrapper;
    IERC1155 public immutable ERC1155Token;

    address public LPAddress; // LP address of Drax-dMagic Sushi
    uint256 erc1155TokenID;
    
    IUniswapV2Router02 private uniswapV2Router = IUniswapV2Router02(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);
    IUniswapV2Factory private uniswapV2Factory = IUniswapV2Factory(0xc35DADB65012eC5796536bD9864eD8773aBc74C4);
    
    event SlippageSet(uint slippage);

    constructor(IAxMatic _axMatic, IERC20 _dmagic, address _LPAddress, IERC20 _Drax, IaxMatic_Direct _axMaticDirect, IDragonZapper _dragonDirect, IERC31337 _LPNFTWrapper, IERC1155 _ERC1155Token, uint _erc1155TokenID){

        axMatic = _axMatic;
        Drax = _Drax;
        axMaticDirect = _axMaticDirect;
        dragonDirect = _dragonDirect;
        LPNFTWrapper = _LPNFTWrapper;
        dmagic = _dmagic;
        ERC1155Token = _ERC1155Token;

        LPAddress = _LPAddress;

        _axMatic.approve(address(_dragonDirect), uint256(-1));
        _dmagic.approve(address(_dragonDirect), uint256(-1));
        _Drax.approve(address(_dragonDirect), uint256(-1));
        
        _axMatic.approve(address(_axMaticDirect), uint256(-1));
        _dmagic.approve(address(_axMaticDirect), uint256(-1));

        _Drax.approve(address(uniswapV2Router), uint256(-1));
        _dmagic.approve(address(uniswapV2Router), uint256(-1));

        IERC20(LPAddress).approve(address(_LPNFTWrapper),uint256(-1));

        erc1155TokenID = _erc1155TokenID;
    }

    receive() external payable
    {
        require (msg.sender == address(axMatic));
    }
   
   
     function onERC1155Received(address _operator, address _from, uint256 _id, uint256 _value, bytes calldata _data) external  returns(bytes4){
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(address _operator, address _from, uint256[] calldata _ids, uint256[] calldata _values, bytes calldata _data) external  returns(bytes4){
        return 0xbc197c81;
    }     


    //  Matic => NFT
    function easyBuyNFT() external payable nonReentrant returns (uint256)
    {
        uint256 prevAxMaticAmount = axMatic.balanceOf(address(this));
        uint256 prevdmagicAmount = dmagic.balanceOf(address(this));
        uint256 prevLPNFTWrapperAmount = ERC1155Token.balanceOf(address(this), erc1155TokenID);
        uint256 prevDrax = Drax.balanceOf(address(this));

        //swap half Matic to Drax    
        uint256 tMatic=SafeMath.div(msg.value,2);
        dragonDirect.easyBuy{ value: tMatic }();

        uint256 draxAmt = Drax.balanceOf(address(this)).sub(prevDrax);
        axMaticDirect.easyBuy{ value: tMatic }();
        uint256 dmagicAmt = dmagic.balanceOf(address(this)).sub(prevdmagicAmount);

        uint256 prevLPBalance = IERC20(LPAddress).balanceOf(address(this));
        uniswapV2Router.addLiquidity(address(Drax), address(dmagic), draxAmt, dmagicAmt, 1, 1, address(this), block.timestamp+60);

        uint mints = LPNFTWrapper.depositTokens(LPAddress, IERC20(LPAddress).balanceOf(address(this)).sub(prevLPBalance));    
        uint256 currLPNFTWrapperAmount = ERC1155Token.balanceOf(address(this), erc1155TokenID);
        
        require(currLPNFTWrapperAmount.sub(prevLPNFTWrapperAmount)>0,"NFT mints should be more than 1");
        ERC1155Token.safeTransferFrom(address(this), msg.sender, erc1155TokenID, currLPNFTWrapperAmount.sub(prevLPNFTWrapperAmount), "0x");

        // any residue sent back to buyer/seller
        if(Drax.balanceOf(address(this))>prevDrax)
            Drax.transfer(msg.sender, Drax.balanceOf(address(this)).sub(prevDrax));

        if(IERC20(LPAddress).balanceOf(address(this))>prevLPBalance)
            IERC20(LPAddress).transfer(msg.sender, IERC20(LPAddress).balanceOf(address(this)).sub(prevLPBalance));

        if(dmagic.balanceOf(address(this))>prevdmagicAmount)
            dmagic.transfer(msg.sender,dmagic.balanceOf(address(this)).sub(prevdmagicAmount));

        if(axMatic.balanceOf(address(this))>prevAxMaticAmount)
            axMatic.transfer(msg.sender,axMatic.balanceOf(address(this)).sub(prevAxMaticAmount));
        
        return mints;
    }

   
    //  axMatic => NFT
    function easyBuyNFTFromAXMatic(uint256 axMaticAmt) public nonReentrant returns (uint256)
    {

        uint256 prevAxMaticAmount = axMatic.balanceOf(address(this));
        uint256 prevdmagicAmount = dmagic.balanceOf(address(this));
        uint256 prevDrax = Drax.balanceOf(address(this));
        uint256 prevLPNFTWrapperAmount = ERC1155Token.balanceOf(address(this), erc1155TokenID);

        axMatic.transferFrom(msg.sender,address(this),axMaticAmt);

        //swap half axMatic to Drax    
        uint256 axMaticForBuy = axMaticAmt.div(2);
        axMaticDirect.easyBuyFromAxMatic(axMaticForBuy);
        uint256 dmagicAmt = dmagic.balanceOf(address(this)).sub(prevdmagicAmount);

        dragonDirect.easyBuyFromAxMatic(axMaticForBuy);
        uint256 draxAmt = Drax.balanceOf(address(this)).sub(prevDrax);

        uint256 prevLPBalance = IERC20(LPAddress).balanceOf(address(this));
        uniswapV2Router.addLiquidity(address(Drax), address(dmagic), draxAmt, dmagicAmt, 1, 1, address(this), block.timestamp+60);

        uint mints = LPNFTWrapper.depositTokens(LPAddress, IERC20(LPAddress).balanceOf(address(this)).sub(prevLPBalance));    
        uint256 currLPNFTWrapperAmount = ERC1155Token.balanceOf(address(this), erc1155TokenID);
        
        require(currLPNFTWrapperAmount.sub(prevLPNFTWrapperAmount)>0,"NFT mints should be more than 1");

        ERC1155Token.safeTransferFrom(address(this), msg.sender, erc1155TokenID, currLPNFTWrapperAmount.sub(prevLPNFTWrapperAmount), "0x");

        // any residue sent back to buyer/seller
        if(Drax.balanceOf(address(this))>prevDrax)
            Drax.transfer(msg.sender, Drax.balanceOf(address(this)).sub(prevDrax));

        if(IERC20(LPAddress).balanceOf(address(this))>prevLPBalance)
            IERC20(LPAddress).transfer(msg.sender, IERC20(LPAddress).balanceOf(address(this)).sub(prevLPBalance));

        if(dmagic.balanceOf(address(this))>prevdmagicAmount)
            dmagic.transfer(msg.sender,dmagic.balanceOf(address(this)).sub(prevdmagicAmount));

        if(axMatic.balanceOf(address(this))>prevAxMaticAmount)
            axMatic.transfer(msg.sender,axMatic.balanceOf(address(this)).sub(prevAxMaticAmount));

        return mints;
    }

    //  dmagic => NFT
    function easyBuyNFTFromMagic(uint256 dmagicAmt) external nonReentrant returns (uint256)
    {
        uint256 prevAxMaticAmount = axMatic.balanceOf(address(this));
        uint256 prevdmagicAmount = dmagic.balanceOf(address(this));
        uint256 prevDrax = Drax.balanceOf(address(this));
        uint256 prevLPNFTWrapperAmount = ERC1155Token.balanceOf(address(this), erc1155TokenID);

        dmagic.transferFrom(msg.sender,address(this),dmagicAmt);
        
        //swap half dmagic to Drax    
        uint256 dmagicForBuy = dmagicAmt.div(2);

        dragonDirect.easyBuyFromDmagic(dmagicForBuy);
        uint256 draxAmt = Drax.balanceOf(address(this)).sub(prevDrax);

        uint256 prevLPBalance = IERC20(LPAddress).balanceOf(address(this));
        uniswapV2Router.addLiquidity(address(Drax), address(dmagic), draxAmt, dmagicAmt, 1, 1, address(this), block.timestamp+60);

        uint mints = LPNFTWrapper.depositTokens(LPAddress, IERC20(LPAddress).balanceOf(address(this)).sub(prevLPBalance));    
        uint256 currLPNFTWrapperAmount = ERC1155Token.balanceOf(address(this), erc1155TokenID);
        
        require(currLPNFTWrapperAmount.sub(prevLPNFTWrapperAmount)>0,"NFT mints should be more than 1");

        ERC1155Token.safeTransferFrom(address(this), msg.sender, erc1155TokenID, currLPNFTWrapperAmount.sub(prevLPNFTWrapperAmount), "0x");

        // any residue sent back to buyer/seller
        if(Drax.balanceOf(address(this))>prevDrax)
            Drax.transfer(msg.sender, Drax.balanceOf(address(this)).sub(prevDrax));

        if(IERC20(LPAddress).balanceOf(address(this))>prevLPBalance)
            IERC20(LPAddress).transfer(msg.sender, IERC20(LPAddress).balanceOf(address(this)).sub(prevLPBalance));

        if(dmagic.balanceOf(address(this))>prevdmagicAmount)
            dmagic.transfer(msg.sender,dmagic.balanceOf(address(this)).sub(prevdmagicAmount));

        if(axMatic.balanceOf(address(this))>prevAxMaticAmount)
            axMatic.transfer(msg.sender,axMatic.balanceOf(address(this)).sub(prevAxMaticAmount));

        

    }


    //  axMatic => NFT
    function easyBuyNFTFromDrax(uint256 draxAmt) public nonReentrant returns (uint256)
    {

        uint256 prevAxMaticAmount = axMatic.balanceOf(address(this));
        uint256 prevdmagicAmount = dmagic.balanceOf(address(this));
        uint256 prevDrax = Drax.balanceOf(address(this));
        uint256 prevLPNFTWrapperAmount = ERC1155Token.balanceOf(address(this), erc1155TokenID);

        Drax.transferFrom(msg.sender,address(this),draxAmt);

        //swap half Drax to dmagic    
        uint256 DraxForBuy = draxAmt.div(2);
        dragonDirect.easySellTodMagic(DraxForBuy);
        uint256 dmagicAmt = dmagic.balanceOf(address(this)).sub(prevdmagicAmount);
        
        uint256 prevLPBalance = IERC20(LPAddress).balanceOf(address(this));

        uniswapV2Router.addLiquidity(address(Drax), address(dmagic), draxAmt, dmagicAmt, 1, 1, address(this), block.timestamp+60);
        uint mints = LPNFTWrapper.depositTokens(LPAddress, IERC20(LPAddress).balanceOf(address(this)).sub(prevLPBalance));    
        uint256 currLPNFTWrapperAmount = ERC1155Token.balanceOf(address(this), erc1155TokenID);
        
        require(currLPNFTWrapperAmount.sub(prevLPNFTWrapperAmount)>0,"NFT mints should be more than 1");

        ERC1155Token.safeTransferFrom(address(this), msg.sender, erc1155TokenID, currLPNFTWrapperAmount.sub(prevLPNFTWrapperAmount), "0x");

        // any residue sent back to buyer/seller
        if(Drax.balanceOf(address(this))>prevDrax)
            Drax.transfer(msg.sender, Drax.balanceOf(address(this)).sub(prevDrax));

        if(IERC20(LPAddress).balanceOf(address(this))>prevLPBalance)
            IERC20(LPAddress).transfer(msg.sender, IERC20(LPAddress).balanceOf(address(this)).sub(prevLPBalance));

        if(dmagic.balanceOf(address(this))>prevdmagicAmount)
            dmagic.transfer(msg.sender,dmagic.balanceOf(address(this)).sub(prevdmagicAmount));

        if(axMatic.balanceOf(address(this))>prevAxMaticAmount)
            axMatic.transfer(msg.sender,axMatic.balanceOf(address(this)).sub(prevAxMaticAmount));

        return mints;
    }
    
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;
import "./IWETH.sol";

interface IAxMatic is IWETH
{
    
    function FEE() external view returns (uint256);
    function FEE_ADDRESS() external view returns (address);
    function isIgnored(address _ignoredAddress) external view returns (bool);
    
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

interface IaxMatic_Direct 
{
    function estimateBuy(uint256 axBNBAmountIn) external view returns (uint256 darkMagicAmount);
    function estimateSell(uint256 darkMagicAmountIn) external view returns (uint256 ethAmount);

    function easyBuy() external payable returns (uint256 darkMagicAmount);
    function easyBuyFromAxMatic(uint256 axBNBIn) external  returns (uint256 darkMagicAmount);

    function easySell(uint256 darkMagicAmountIn) external returns (uint256 axBNBAmount);
    function easySellToAxMatic(uint256 darkMagicAmountIn) external returns (uint256 axBNBAmount);

    function buy(uint256 axBNBIn, uint256 dMagicOutMin) external payable returns (uint256 darkMagicAmount);
    function sell(uint256 darkMagicAmountIn, uint256 axBNBOutMin) external returns (uint256 axBNBAmount);
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

/* ROOTKIT:
Allows recovery of unexpected tokens (airdrops, etc)
Inheriters can customize logic by overriding canRecoverTokens
*/

import "../interfaces/IERC20.sol";
import "../libraries/SafeERC20.sol";
import "./Owned.sol";
import "../interfaces/ITokensRecoverable.sol";

abstract contract TokensRecoverable is Owned, ITokensRecoverable
{
    using SafeERC20 for IERC20;

    function recoverTokens(IERC20 token) public override ownerOnly() 
    {
        require (canRecoverTokens(token));
        
        token.safeTransfer(msg.sender, token.balanceOf(address(this)));
    }

    function recoverETH(uint256 amount) public override ownerOnly() 
    {        
        msg.sender.transfer(amount);
    }

    function canRecoverTokens(IERC20 token) internal virtual view returns (bool) 
    { 
        return address(token) != address(this); 
    }
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

/* ROOTKIT:
Provides ownerOnly() modifier
Allows for ownership transfer but requires the new
owner to claim (accept) ownership
Safer because no accidental transfers or renouncing
*/

import "../interfaces/IOwned.sol";

abstract contract Owned is IOwned
{
    address public override owner = msg.sender;
    address internal pendingOwner;

    modifier ownerOnly()
    {
        require (msg.sender == owner, "Owner only");
        _;
    }

    function transferOwnership(address newOwner) public override ownerOnly()
    {
        pendingOwner = newOwner;
    }

    function claimOwnership() public override
    {
        require (pendingOwner == msg.sender);
        pendingOwner = address(0);
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
    }
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

import "../interfaces/IUniswapV2Pair.sol";
import "./SafeMath.sol";

library UniswapV2Library {
    using SafeMath for uint;

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        address sushiFactory=0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
        if(factory==sushiFactory)
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'e18a34eb0e04b04f7a0ac29a6e80748dca96319b42c54d679cb821dca90c6303' // init code hash
            ))));
        else
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
            ))));
    }

    // fetches and sorts the reserves for a pair
    function getReserves(address factory, address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IUniswapV2Pair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        require(amountA > 0, 'UniswapV2Library: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(address factory, uint amountIn, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(address factory, uint amountOut, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IOwned.sol";
import "./ITokensRecoverable.sol";
import "./IUniswapV2Router02.sol";
import "./IUniswapV2Factory.sol";


enum AddressState
{
    Unknown,
    NotPool,
    DisallowedPool,
    AllowedPool
} 
struct TransferGateTarget
{
    address destination;
    uint256 amount;
}

interface IMagicTransferGate is IOwned, ITokensRecoverable
{   


    function allowedPoolTokensCount() external view returns (uint256);
    function setUnrestrictedController(address unrestrictedController, bool allow) external;

    function setFreeParticipant(address participant, bool free) external;

    function setUnrestricted(bool _unrestricted) external;

    function setParameters(address _dev, address _stake, uint16 _stakeRate, uint16 _burnRate, uint16 _devRate) external;
    function allowPool(IUniswapV2Factory _uniswapV2Factory, IERC20 token) external;

    function safeAddLiquidity(IUniswapV2Router02 _uniswapRouter02, IERC20 token, uint256 tokenAmount, uint256 MagicAmount//, uint256 minTokenAmount, uint256 minMagicAmount
// ,uint256 deadline //stack deep issue coming so had to use fix values
    ) external returns (uint256 MagicUsed, uint256 tokenUsed, uint256 liquidity);

    function handleTransfer(address msgSender, address from, address to, uint256 amount) external
    returns (uint256 burn, TransferGateTarget[] memory targets);

  
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

import './IUniswapV2Router01.sol';

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

import "./IWrappedERC20Multiple.sol";
import "./IFloorCalculator.sol";

interface IERC31337 is IWrappedERC20Multiple
{
    function floorCalculator() external view returns (IFloorCalculator);
    function sweepers(address _sweeper) external view returns (bool);
    
    function setFloorCalculator(IFloorCalculator _floorCalculator) external;
    function setSweeper(address _sweeper, bool _allow) external;
    function sweepFloor(address _to) external returns (uint256 amountSwept);
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

interface IDragonZapper
{

    function easyBuy() external payable;
    function easyBuyFromAxMatic(uint256 axBNBIn) external;
    function easyBuyFromDmagic(uint magicIn) external;

    function easySell(uint256 wiz) external;
    function easySellToAxMatic(uint256 wiz) external;
    function easySellTodMagic(uint256 wiz) external;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor () internal {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2 <0.8.0;

import "../openzeppelin/introspection/IERC165.sol";

/**
 * @dev Required interface of an ERC1155 compliant contract, as defined in the
 * https://eips.ethereum.org/EIPS/eip-1155[EIP].
 *
 * _Available since v3.1._
 */
interface IERC1155 is IERC165 {
    /**
     * @dev Emitted when `value` tokens of token type `id` are transferred from `from` to `to` by `operator`.
     */
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    /**
     * @dev Equivalent to multiple {TransferSingle} events, where `operator`, `from` and `to` are the same for all
     * transfers.
     */
    event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values);

    /**
     * @dev Emitted when `account` grants or revokes permission to `operator` to transfer their tokens, according to
     * `approved`.
     */
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);

    /**
     * @dev Emitted when the URI for token type `id` changes to `value`, if it is a non-programmatic URI.
     *
     * If an {URI} event was emitted for `id`, the standard
     * https://eips.ethereum.org/EIPS/eip-1155#metadata-extensions[guarantees] that `value` will equal the value
     * returned by {IERC1155MetadataURI-uri}.
     */
    event URI(string value, uint256 indexed id);

    function totalSupply(
        uint256 _id
    ) external view returns (uint256);
    
    /**
     * @dev Returns the amount of tokens of token type `id` owned by `account`.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function balanceOf(address account, uint256 id) external view returns (uint256);

    /**
     * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {balanceOf}.
     *
     * Requirements:
     *
     * - `accounts` and `ids` must have the same length.
     */
    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids) external view returns (uint256[] memory);

    /**
     * @dev Grants or revokes permission to `operator` to transfer the caller's tokens, according to `approved`,
     *
     * Emits an {ApprovalForAll} event.
     *
     * Requirements:
     *
     * - `operator` cannot be the caller.
     */
    function setApprovalForAll(address operator, bool approved) external;

    /**
     * @dev Returns true if `operator` is approved to transfer ``account``'s tokens.
     *
     * See {setApprovalForAll}.
     */


    function isApprovedForAll(address account, address operator) external view returns (bool);

    function create( address _to, uint256 _initialSupply, string calldata _Uri, bytes calldata _data) external returns(uint256) ;
  
    function mint(address to, uint256 id, uint256 value, bytes memory data) external;

    function mintBatch(address to, uint256[] memory ids, uint256[] memory values, bytes memory data) external;

    function burn(address owner, uint256 id, uint256 value) external;

    function burnBatch(address owner, uint256[] memory ids, uint256[] memory values) external;


    /**
     * @dev Transfers `amount` tokens of token type `id` from `from` to `to`.
     *
     * Emits a {TransferSingle} event.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - If the caller is not `from`, it must be have been approved to spend ``from``'s tokens via {setApprovalForAll}.
     * - `from` must have a balance of tokens of type `id` of at least `amount`.
     * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155Received} and return the
     * acceptance magic value.
     */
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;

    /**
     * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {safeTransferFrom}.
     *
     * Emits a {TransferBatch} event.
     *
     * Requirements:
     *
     * - `ids` and `amounts` must have the same length.
     * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155BatchReceived} and return the
     * acceptance magic value.
     */
    function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external;
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

interface IERC20 
{
    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event Approval(address indexed _owner, address indexed _spender, uint256 _value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address _account) external view returns (uint256);
    function transfer(address _recipient, uint256 _amount) external returns (bool);
    function allowance(address _owner, address _spender) external view returns (uint256);
    function approve(address _spender, uint256 _amount) external returns (bool);
    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

import "./IERC20.sol";
import "./IWrappedERC20Events.sol";

interface IWETH is IERC20, IWrappedERC20Events
{    
    function deposit() external payable;
    function withdraw(uint256 _amount) external;
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

interface IWrappedERC20Events
{
    event Deposit(address indexed from, uint256 amount);
    event Withdrawal(address indexed to, uint256 amount);
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

/* ROOTKIT:
Modified to remove some junk
Also modified to remove silly restrictions (traps!) within safeApprove
*/

import "../interfaces/IERC20.sol";
import "./SafeMath.sol";
import "./Address.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using SafeMath for uint256;
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {        
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }


    function safeIncreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 newAllowance =
            token.allowance(address(this), spender).add(value);
        _callOptionalReturn(
            token,
            abi.encodeWithSelector(
                token.approve.selector,
                spender,
                newAllowance
            )
        );
    }

    function safeDecreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 newAllowance =
            token.allowance(address(this), spender).sub(
                value,
                "SafeERC20: decreased allowance below zero"
            );
        _callOptionalReturn(
            token,
            abi.encodeWithSelector(
                token.approve.selector,
                spender,
                newAllowance
            )
        );
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

import "./IERC20.sol";

interface ITokensRecoverable
{
    function recoverTokens(IERC20 token) external;
    function recoverETH(uint256 amount) external; 
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

/* ROOTKIT:
O wherefore art thou 8 point O
*/

library SafeMath 
{
    function add(uint256 a, uint256 b) internal pure returns (uint256) 
    {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) 
    {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) 
    {
        require(b <= a, errorMessage);
        uint256 c = a - b;
        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) 
    {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) 
        {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    
    function div(uint256 a, uint256 b) internal pure returns (uint256) 
    {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) 
    {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) 
    {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) 
    {
        require(b != 0, errorMessage);
        return a % b;
    }
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        // solhint-disable-next-line avoid-low-level-calls, avoid-call-value
        (bool success, ) = recipient.call{ value: amount }("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain`call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
      return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.call{ value: value }(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data, string memory errorMessage) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.staticcall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.3._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.3._
     */
    function functionDelegateCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        require(isContract(target), "Address: delegate call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    function _verifyCallResult(bool success, bytes memory returndata, string memory errorMessage) private pure returns(bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                // solhint-disable-next-line no-inline-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

interface IOwned
{
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function owner() external view returns (address);

    function transferOwnership(address newOwner) external;
    function claimOwnership() external;
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

// SPDX-License-Identifier: J-J-J-JENGA!!!
pragma solidity ^0.7.4;

import "./IERC20.sol";
import "./IWrappedERC20Events.sol";

interface IWrappedERC20Multiple is IERC20, IWrappedERC20Events
{
    function depositTokens(address LPAddress, uint256 _amount) external returns (uint256 totalNFTsToGive);
}

// SPDX-License-Identifier: J-J-J-JENGA!!!

pragma solidity ^0.7.4;
import "./IERC20.sol";

interface IFloorCalculator
{
    function calculateSubFloorPBNB(IERC20 wrappedToken, IERC20 backingToken) external view returns (uint256);
    function calculateSubFloorCircleNFT(IERC20[] memory wrappedTokens, IERC20 backingToken) external view returns ( uint256);
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}