// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "./libraries/DecimalsConverter.sol";

import "./interfaces/ICapitalPool.sol";
import "./interfaces/IClaimingRegistry.sol";
import "./interfaces/IContractsRegistry.sol";
import "./interfaces/ILeveragePortfolio.sol";
import "./interfaces/ILiquidityRegistry.sol";
import "./interfaces/IPolicyBook.sol";
import "./interfaces/IPolicyBookRegistry.sol";
import "./interfaces/IYieldGenerator.sol";
import "./interfaces/ILeveragePortfolioView.sol";

import "./abstract/AbstractDependant.sol";

import "./Globals.sol";

contract CapitalPool is ICapitalPool, OwnableUpgradeable, AbstractDependant {
    using SafeERC20 for ERC20;
    using SafeMath for uint256;
    using Math for uint256;

    uint256 public constant ADDITIONAL_WITHDRAW_PERIOD = 1 days;

    IClaimingRegistry public claimingRegistry;
    IPolicyBookRegistry public policyBookRegistry;
    IYieldGenerator public yieldGenerator;
    ILeveragePortfolio public reinsurancePool;
    ILiquidityRegistry public liquidityRegistry;
    ILeveragePortfolioView public leveragePortfolioView;
    ERC20 public stblToken;

    // reisnurance pool vStable balance updated by(premium, interest from defi)
    uint256 public reinsurancePoolBalance;
    // user leverage pool vStable balance updated by(premium, addliq, withdraw liq)
    mapping(address => uint256) public leveragePoolBalance;
    // policy books vStable balances updated by(premium, addliq, withdraw liq)
    mapping(address => uint256) public regularCoverageBalance;
    // all hStable capital balance , updated by (all pool transfer + deposit to dfi + liq cushion)
    uint256 public hardUsdtAccumulatedBalance;
    // all vStable capital balance , updated by (all pool transfer + withdraw from liq cushion)
    uint256 public override virtualUsdtAccumulatedBalance;
    // pool balances tracking
    uint256 public override liquidityCushionBalance;
    address public maintainer;

    uint256 public stblDecimals;

    // new state post v2 deployemnt
    bool public isLiqCushionPaused;
    bool public automaticHardRebalancing;

    uint256 public override rebalanceDuration;
    bool private deployFundsToDefi;

    event PoolBalancesUpdated(
        uint256 hardUsdtAccumulatedBalance,
        uint256 virtualUsdtAccumulatedBalance,
        uint256 liquidityCushionBalance,
        uint256 reinsurancePoolBalance
    );

    event LiquidityCushionRebalanced(
        uint256 liquidityNeede,
        uint256 liquidityWithdraw,
        uint256 liquidityDeposit
    );

    modifier broadcastBalancing() {
        _;
        emit PoolBalancesUpdated(
            hardUsdtAccumulatedBalance,
            virtualUsdtAccumulatedBalance,
            liquidityCushionBalance,
            reinsurancePoolBalance
        );
    }

    modifier onlyPolicyBook() {
        require(policyBookRegistry.isPolicyBook(msg.sender), "CAPL: Not a PolicyBook");
        _;
    }

    modifier onlyReinsurancePool() {
        require(
            address(reinsurancePool) == _msgSender(),
            "RP: Caller is not a reinsurance pool contract"
        );
        _;
    }

    modifier onlyClaimingRegistry() {
        require(
            address(claimingRegistry) == _msgSender(),
            "CP: Caller is not claiming registry contract"
        );
        _;
    }

    modifier onlyMaintainer() {
        require(_msgSender() == maintainer, "CP: not maintainer");
        _;
    }

    function __CapitalPool_init() external initializer {
        __Ownable_init();
        maintainer = _msgSender();
        rebalanceDuration = 3 days;
        deployFundsToDefi = true;
    }

    function setDependencies(IContractsRegistry _contractsRegistry)
        external
        override
        onlyInjectorOrZero
    {
        claimingRegistry = IClaimingRegistry(_contractsRegistry.getClaimingRegistryContract());
        policyBookRegistry = IPolicyBookRegistry(
            _contractsRegistry.getPolicyBookRegistryContract()
        );
        stblToken = ERC20(_contractsRegistry.getUSDTContract());
        yieldGenerator = IYieldGenerator(_contractsRegistry.getYieldGeneratorContract());
        reinsurancePool = ILeveragePortfolio(_contractsRegistry.getReinsurancePoolContract());
        liquidityRegistry = ILiquidityRegistry(_contractsRegistry.getLiquidityRegistryContract());
        leveragePortfolioView = ILeveragePortfolioView(
            _contractsRegistry.getLeveragePortfolioViewContract()
        );
        stblDecimals = stblToken.decimals();
    }

    /// @notice distributes the policybook premiums into pools (CP, ULP , RP)
    /// @dev distributes the balances acording to the established percentages
    /// @param _stblAmount amount hardSTBL ingressed into the system
    /// @param _epochsNumber uint256 the number of epochs which the policy holder will pay a premium for
    /// @param _protocolFee uint256 the amount of protocol fee earned by premium
    function addPolicyHoldersHardSTBL(
        uint256 _stblAmount,
        uint256 _epochsNumber,
        uint256 _protocolFee
    ) external override onlyPolicyBook broadcastBalancing returns (uint256) {
        PremiumFactors memory factors;

        factors.vStblOfCP = regularCoverageBalance[_msgSender()];
        factors.premiumPrice = _stblAmount.sub(_protocolFee);

        factors.policyBookFacade = IPolicyBookFacade(IPolicyBook(_msgSender()).policyBookFacade());

        factors.vStblDeployedByRP = DecimalsConverter.convertFrom18(
            factors.policyBookFacade.VUreinsurnacePool(),
            stblDecimals
        );

        factors.userLeveragePoolsCount = factors.policyBookFacade.countUserLeveragePools();
        factors.epochsNumber = _epochsNumber;

        uint256 reinsurancePoolPremium;
        uint256 coveragePoolPremium;

        if (factors.vStblDeployedByRP == 0 && factors.userLeveragePoolsCount == 0) {
            coveragePoolPremium = factors.premiumPrice;
        } else {
            (reinsurancePoolPremium, coveragePoolPremium) = _calcPremiumForAllPools(factors);
        }

        uint256 reinsurancePoolTotalPremium = reinsurancePoolPremium.add(_protocolFee);
        reinsurancePoolBalance = reinsurancePoolBalance.add(reinsurancePoolTotalPremium);
        reinsurancePool.addPolicyPremium(
            _epochsNumber,
            DecimalsConverter.convertTo18(reinsurancePoolTotalPremium, stblDecimals)
        );

        regularCoverageBalance[_msgSender()] = regularCoverageBalance[_msgSender()].add(
            coveragePoolPremium
        );
        hardUsdtAccumulatedBalance = hardUsdtAccumulatedBalance.add(_stblAmount);
        virtualUsdtAccumulatedBalance = virtualUsdtAccumulatedBalance.add(_stblAmount);
        return DecimalsConverter.convertTo18(coveragePoolPremium, stblDecimals);
    }

    function _calcPremiumForAllPools(PremiumFactors memory factors)
        internal
        returns (uint256 reinsurancePoolPremium, uint256 coveragePoolPremium)
    {
        uint256 _totalCoverTokens =
            DecimalsConverter.convertFrom18(
                (IPolicyBook(_msgSender())).totalCoverTokens(),
                stblDecimals
            );

        factors.poolUtilizationRation = _totalCoverTokens.mul(PERCENTAGE_100).div(
            factors.vStblOfCP
        );

        uint256 _participatedLeverageAmounts;

        if (factors.userLeveragePoolsCount > 0) {
            address[] memory _userLeverageArr =
                factors.policyBookFacade.listUserLeveragePools(0, factors.userLeveragePoolsCount);

            for (uint256 i = 0; i < _userLeverageArr.length; i++) {
                _participatedLeverageAmounts = _participatedLeverageAmounts.add(
                    clacParticipatedLeverageAmount(factors, _userLeverageArr[i])
                );
            }
        }
        uint256 totalLiqforPremium =
            factors.vStblOfCP.add(factors.vStblDeployedByRP).add(_participatedLeverageAmounts);

        factors.premiumPerDeployment = (factors.premiumPrice.mul(PRECISION)).div(
            totalLiqforPremium
        );

        reinsurancePoolPremium = _calcReinsurancePoolPremium(factors);

        if (factors.userLeveragePoolsCount > 0) {
            _calcUserLeveragePoolPremium(factors);
        }
        coveragePoolPremium = _calcCoveragePoolPremium(factors);
    }

    /// @notice distributes the hardSTBL from the coverage providers
    /// @dev emits PoolBalancedUpdated event
    /// @param _stblAmount amount hardSTBL ingressed into the system
    function addCoverageProvidersHardSTBL(uint256 _stblAmount)
        external
        override
        onlyPolicyBook
        broadcastBalancing
    {
        regularCoverageBalance[_msgSender()] = regularCoverageBalance[_msgSender()].add(
            _stblAmount
        );
        hardUsdtAccumulatedBalance = hardUsdtAccumulatedBalance.add(_stblAmount);
        virtualUsdtAccumulatedBalance = virtualUsdtAccumulatedBalance.add(_stblAmount);
    }

    //// @notice distributes the hardSTBL from the leverage providers
    /// @dev emits PoolBalancedUpdated event
    /// @param _stblAmount amount hardSTBL ingressed into the system
    function addLeverageProvidersHardSTBL(uint256 _stblAmount)
        external
        override
        onlyPolicyBook
        broadcastBalancing
    {
        leveragePoolBalance[_msgSender()] = leveragePoolBalance[_msgSender()].add(_stblAmount);
        hardUsdtAccumulatedBalance = hardUsdtAccumulatedBalance.add(_stblAmount);
        virtualUsdtAccumulatedBalance = virtualUsdtAccumulatedBalance.add(_stblAmount);
    }

    /// @notice distributes the hardSTBL from the reinsurance pool
    /// @dev emits PoolBalancedUpdated event
    /// @param _stblAmount amount hardSTBL ingressed into the system
    function addReinsurancePoolHardSTBL(uint256 _stblAmount)
        external
        override
        onlyReinsurancePool
        broadcastBalancing
    {
        reinsurancePoolBalance = reinsurancePoolBalance.add(_stblAmount);
        hardUsdtAccumulatedBalance = hardUsdtAccumulatedBalance.add(_stblAmount);
        virtualUsdtAccumulatedBalance = virtualUsdtAccumulatedBalance.add(_stblAmount);
    }

    /// @notice rebalances pools acording to v2 specification and dao enforced policies
    /// @dev  emits PoolBalancesUpdated
    function rebalanceLiquidityCushion() public override broadcastBalancing onlyMaintainer {
        require(!isLiqCushionPaused, "CP: liqudity cushion is pasued");

        //check defi protocol balances
        (, uint256 _lostAmount) = yieldGenerator.reevaluateDefiProtocolBalances();

        if (_lostAmount > 0) {
            isLiqCushionPaused = true;
            if (automaticHardRebalancing) {
                defiHardRebalancing();
            }
        }

        // hard rebalancing - Stop all withdrawals from all pools
        if (isLiqCushionPaused) {
            hardUsdtAccumulatedBalance = hardUsdtAccumulatedBalance.add(liquidityCushionBalance);
            liquidityCushionBalance = 0;
            return;
        }

        uint256 _pendingClaimAmount =
            claimingRegistry.getAllPendingClaimsAmount(
                claimingRegistry.getWithdrawClaimRequestIndexListCount()
            );
        uint256 _pendingRewardAmount =
            claimingRegistry.getAllPendingRewardsAmount(
                claimingRegistry.getWithdrawRewardRequestVoterListCount()
            );

        uint256 _pendingWithdrawlAmount =
            liquidityRegistry.getAllPendingWithdrawalRequestsAmount(
                liquidityRegistry.getWithdrawlRequestUsersListCount()
            );

        uint256 _requiredLiquidity =
            _pendingWithdrawlAmount.add(_pendingClaimAmount).add(_pendingRewardAmount);

        _requiredLiquidity = DecimalsConverter.convertFrom18(_requiredLiquidity, stblDecimals);

        (uint256 _deposit, uint256 _withdraw) = getDepositAndWithdraw(_requiredLiquidity);

        liquidityCushionBalance = _requiredLiquidity;

        hardUsdtAccumulatedBalance = 0;

        uint256 _actualAmount;
        if (_deposit > 0) {
            stblToken.safeApprove(address(yieldGenerator), 0);
            stblToken.safeApprove(address(yieldGenerator), _deposit);

            _actualAmount = yieldGenerator.deposit(_deposit);
            if (_actualAmount < _deposit) {
                hardUsdtAccumulatedBalance = hardUsdtAccumulatedBalance.add(
                    (_deposit.sub(_actualAmount))
                );
            }
        } else if (_withdraw > 0) {
            _actualAmount = yieldGenerator.withdraw(_withdraw);
            if (_actualAmount < _withdraw) {
                liquidityCushionBalance = liquidityCushionBalance.sub(
                    (_withdraw.sub(_actualAmount))
                );
            }
        }

        emit LiquidityCushionRebalanced(_requiredLiquidity, _withdraw, _deposit);
    }

    /// @param _rebalanceDuration parameter passes in seconds
    function setRebalanceDuration(uint256 _rebalanceDuration) public onlyOwner {
        require(_rebalanceDuration <= 7 days, "CP: invalid rebalance duration");
        rebalanceDuration = _rebalanceDuration;
    }

    function defiHardRebalancing() public onlyOwner {
        (uint256 _totalDeposit, uint256 _lostAmount) =
            yieldGenerator.reevaluateDefiProtocolBalances();

        if (_lostAmount > 0 && _totalDeposit > _lostAmount) {
            uint256 _lostPercentage =
                _lostAmount.mul(PERCENTAGE_100).div(virtualUsdtAccumulatedBalance);

            address[] memory _policyBooksArr =
                policyBookRegistry.list(0, policyBookRegistry.count());
            ///@dev we should update all coverage pools liquidity before leverage pool
            /// in order to do leverage rebalancing for all pools at once
            for (uint256 i = 0; i < _policyBooksArr.length; i++) {
                if (policyBookRegistry.isUserLeveragePool(_policyBooksArr[i])) continue;

                _updatePoolLiquidity(_policyBooksArr[i], 0, _lostPercentage, PoolType.COVERAGE);
            }

            address[] memory _userLeverageArr =
                policyBookRegistry.listByType(
                    IPolicyBookFabric.ContractType.VARIOUS,
                    0,
                    policyBookRegistry.countByType(IPolicyBookFabric.ContractType.VARIOUS)
                );

            for (uint256 i = 0; i < _userLeverageArr.length; i++) {
                _updatePoolLiquidity(_userLeverageArr[i], 0, _lostPercentage, PoolType.LEVERAGE);
            }
            yieldGenerator.defiHardRebalancing();
        }
    }

    /// @dev when calling this function we have to have either _lostAmount == 0 or _lostPercentage == 0
    function _updatePoolLiquidity(
        address _poolAddress,
        uint256 _lostAmount,
        uint256 _lostPercentage,
        PoolType poolType
    ) internal {
        IPolicyBook _pool = IPolicyBook(_poolAddress);

        if (_lostPercentage > 0) {
            uint256 _currentLiquidity = _pool.totalLiquidity();
            _lostAmount = _currentLiquidity.mul(_lostPercentage).div(PERCENTAGE_100);
        }
        _pool.updateLiquidity(_lostAmount);

        uint256 _stblLostAmount = DecimalsConverter.convertFrom18(_lostAmount, stblDecimals);

        if (poolType == PoolType.COVERAGE) {
            regularCoverageBalance[_poolAddress] = regularCoverageBalance[_poolAddress].sub(
                _stblLostAmount
            );
        } else if (poolType == PoolType.LEVERAGE) {
            leveragePoolBalance[_poolAddress] = leveragePoolBalance[_poolAddress].sub(
                _stblLostAmount
            );
        } else if (poolType == PoolType.REINSURANCE) {
            reinsurancePoolBalance = reinsurancePoolBalance.sub(_stblLostAmount);
        }

        if (_lostPercentage > 0) {
            virtualUsdtAccumulatedBalance = virtualUsdtAccumulatedBalance.sub(_stblLostAmount);
        }
    }

    /// @notice Fullfils policybook claims by transfering the balance to claimer
    /// @param _claimer, address of the claimer recieving the withdraw
    /// @param _stblClaimAmount uint256 amount to of the claim
    function fundClaim(
        address _claimer,
        uint256 _stblClaimAmount,
        address _policyBookAddress
    ) external override onlyClaimingRegistry returns (uint256 _actualAmount) {
        _actualAmount = _withdrawFromLiquidityCushion(_claimer, _stblClaimAmount);

        _dispatchLiquidities(
            _policyBookAddress,
            DecimalsConverter.convertTo18(_actualAmount, stblDecimals)
        );
    }

    function _dispatchLiquidities(address _policyBookAddress, uint256 _claimAmount) internal {
        IPolicyBook policyBook = IPolicyBook(_policyBookAddress);
        IPolicyBookFacade policyBookFacade = policyBook.policyBookFacade();

        uint256 totalCoveragedLiquidity = policyBook.totalLiquidity();
        uint256 totalLeveragedLiquidity = policyBookFacade.totalLeveragedLiquidity();
        uint256 totalPoolLiquidity = totalCoveragedLiquidity.add(totalLeveragedLiquidity);

        // COVERAGE CONTRIBUTION
        uint256 coverageContribution =
            totalCoveragedLiquidity.mul(PERCENTAGE_100).div(totalPoolLiquidity);
        uint256 coverageLoss = _claimAmount.mul(coverageContribution).div(PERCENTAGE_100);
        _updatePoolLiquidity(_policyBookAddress, coverageLoss, 0, PoolType.COVERAGE);

        // LEVERAGE CONTRIBUTION
        address[] memory _userLeverageArr =
            policyBookFacade.listUserLeveragePools(0, policyBookFacade.countUserLeveragePools());
        for (uint256 i = 0; i < _userLeverageArr.length; i++) {
            uint256 leverageContribution =
                policyBookFacade.LUuserLeveragePool(_userLeverageArr[i]).mul(PERCENTAGE_100).div(
                    totalPoolLiquidity
                );
            uint256 leverageLoss = _claimAmount.mul(leverageContribution).div(PERCENTAGE_100);
            _updatePoolLiquidity(_userLeverageArr[i], leverageLoss, 0, PoolType.LEVERAGE);
        }

        // REINSURANCE CONTRIBUTION
        uint256 reinsuranceContribution =
            (policyBookFacade.LUreinsurnacePool().add(policyBookFacade.VUreinsurnacePool()))
                .mul(PERCENTAGE_100)
                .div(totalPoolLiquidity);
        uint256 reinsuranceLoss = _claimAmount.mul(reinsuranceContribution).div(PERCENTAGE_100);
        _updatePoolLiquidity(address(reinsurancePool), reinsuranceLoss, 0, PoolType.REINSURANCE);
    }

    /// @notice Fullfils policybook claims by transfering the balance to claimer
    /// @param _voter, address of the voter recieving the withdraw
    /// @param _stblRewardAmount uint256 amount to of the reward
    function fundReward(address _voter, uint256 _stblRewardAmount)
        external
        override
        onlyClaimingRegistry
        returns (uint256 _actualAmount)
    {
        _actualAmount = _withdrawFromLiquidityCushion(_voter, _stblRewardAmount);

        _updatePoolLiquidity(
            address(reinsurancePool),
            DecimalsConverter.convertTo18(_actualAmount, stblDecimals),
            0,
            PoolType.REINSURANCE
        );
    }

    /// @notice Withdraws liquidity from a specific policbybook to the user
    /// @param _sender, address of the user beneficiary of the withdraw
    /// @param _stblAmount uint256 amount to be withdrawn
    function withdrawLiquidity(
        address _sender,
        uint256 _stblAmount,
        bool _isLeveragePool
    ) external override onlyPolicyBook broadcastBalancing returns (uint256 _actualAmount) {
        _actualAmount = _withdrawFromLiquidityCushion(_sender, _stblAmount);

        if (_isLeveragePool) {
            leveragePoolBalance[_msgSender()] = leveragePoolBalance[_msgSender()].sub(
                _actualAmount
            );
        } else {
            regularCoverageBalance[_msgSender()] = regularCoverageBalance[_msgSender()].sub(
                _actualAmount
            );
        }
    }

    function setMaintainer(address _newMainteiner) public onlyOwner {
        require(_newMainteiner != address(0), "CP: invalid maintainer address");
        maintainer = _newMainteiner;
    }

    function pauseLiquidityCushionRebalancing(bool _paused) public onlyOwner {
        require(_paused != isLiqCushionPaused, "CP: invalid paused state");

        isLiqCushionPaused = _paused;

        if (isLiqCushionPaused) {
            hardUsdtAccumulatedBalance = hardUsdtAccumulatedBalance.add(liquidityCushionBalance);
            liquidityCushionBalance = 0;
        }
    }

    function automateHardRebalancing(bool _isAutomatic) public onlyOwner {
        require(_isAutomatic != automaticHardRebalancing, "CP: invalid state");

        automaticHardRebalancing = _isAutomatic;
    }

    function allowDeployFundsToDefi(bool _deployFundsToDefi) public onlyOwner {
        require(_deployFundsToDefi != deployFundsToDefi, "CP: invalid input");

        //can not disabled deploy funds to defi in case there is deposited amount
        if (!_deployFundsToDefi) {
            require(yieldGenerator.totalDeposit() == 0, "CP: Can't disable deploy funds");
        }

        deployFundsToDefi = _deployFundsToDefi;

        // check isLiqCushionPaused isn't have the same state before update it
        if (isLiqCushionPaused != !deployFundsToDefi) {
            pauseLiquidityCushionRebalancing(!deployFundsToDefi);
        }
    }

    function _withdrawFromLiquidityCushion(address _sender, uint256 _stblAmount)
        internal
        broadcastBalancing
        returns (uint256 _actualAmount)
    {
        //withdraw from hardbalance if defi deployment is pasued
        if (!deployFundsToDefi) {
            require(hardUsdtAccumulatedBalance >= _stblAmount, "CP: insuficient liquidity");
            hardUsdtAccumulatedBalance = hardUsdtAccumulatedBalance.sub(_stblAmount);
            _actualAmount = _stblAmount;
        } else {
            //withdraw from liq cushion service if defi deployment is enabled
            require(!isLiqCushionPaused, "CP: withdraw is pasued");

            if (_stblAmount > liquidityCushionBalance) {
                uint256 _diffAmount = _stblAmount.sub(liquidityCushionBalance);
                if (hardUsdtAccumulatedBalance >= _diffAmount) {
                    hardUsdtAccumulatedBalance = hardUsdtAccumulatedBalance.sub(_diffAmount);
                    liquidityCushionBalance = liquidityCushionBalance.add(_diffAmount);
                } else if (hardUsdtAccumulatedBalance > 0) {
                    liquidityCushionBalance = liquidityCushionBalance.add(
                        hardUsdtAccumulatedBalance
                    );
                    hardUsdtAccumulatedBalance = 0;
                }
            }
            require(liquidityCushionBalance > 0, "CP: insuficient liquidity");

            _actualAmount = Math.min(_stblAmount, liquidityCushionBalance);

            liquidityCushionBalance = liquidityCushionBalance.sub(_actualAmount);
        }

        virtualUsdtAccumulatedBalance = virtualUsdtAccumulatedBalance.sub(_actualAmount);

        stblToken.safeTransfer(_sender, _actualAmount);
    }

    function _calcReinsurancePoolPremium(PremiumFactors memory factors)
        internal
        pure
        returns (uint256)
    {
        return (factors.premiumPerDeployment.mul(factors.vStblDeployedByRP).div(PRECISION));
    }

    function _calcUserLeveragePoolPremium(PremiumFactors memory factors) internal {
        address[] memory _userLeverageArr =
            factors.policyBookFacade.listUserLeveragePools(0, factors.userLeveragePoolsCount);

        uint256 premium;
        uint256 _participatedLeverageAmount;
        for (uint256 i = 0; i < _userLeverageArr.length; i++) {
            _participatedLeverageAmount = clacParticipatedLeverageAmount(
                factors,
                _userLeverageArr[i]
            );
            premium = (
                factors.premiumPerDeployment.mul(_participatedLeverageAmount).div(PRECISION)
            );

            leveragePoolBalance[_userLeverageArr[i]] = leveragePoolBalance[_userLeverageArr[i]]
                .add(premium);
            ILeveragePortfolio(_userLeverageArr[i]).addPolicyPremium(
                factors.epochsNumber,
                DecimalsConverter.convertTo18(premium, stblDecimals)
            );
        }
    }

    function clacParticipatedLeverageAmount(
        PremiumFactors memory factors,
        address userLeveragePool
    ) internal view returns (uint256) {
        return
            DecimalsConverter
                .convertFrom18(
                factors.policyBookFacade.LUuserLeveragePool(userLeveragePool),
                stblDecimals
            )
                .mul(leveragePortfolioView.calcM(factors.poolUtilizationRation, userLeveragePool))
                .div(PERCENTAGE_100);
    }

    function _calcCoveragePoolPremium(PremiumFactors memory factors)
        internal
        pure
        returns (uint256)
    {
        return factors.premiumPerDeployment.mul(factors.vStblOfCP).div(PRECISION);
    }

    function getDepositAndWithdraw(uint256 _requiredLiquidity)
        internal
        view
        returns (uint256 deposit, uint256 withdraw)
    {
        uint256 _availableBalance = hardUsdtAccumulatedBalance.add(liquidityCushionBalance);

        if (_requiredLiquidity > _availableBalance) {
            withdraw = _requiredLiquidity.sub(_availableBalance);
        } else if (_requiredLiquidity < _availableBalance) {
            deposit = _availableBalance.sub(_requiredLiquidity);
        }
    }

    function getWithdrawPeriod() external view override returns (uint256) {
        return rebalanceDuration + ADDITIONAL_WITHDRAW_PERIOD;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";

/// @notice the intention of this library is to be able to easily convert
///     one amount of tokens with N decimal places
///     to another amount with M decimal places
library DecimalsConverter {
    using SafeMath for uint256;

    function convert(
        uint256 amount,
        uint256 baseDecimals,
        uint256 destinationDecimals
    ) internal pure returns (uint256) {
        if (baseDecimals > destinationDecimals) {
            amount = amount.div(10**(baseDecimals - destinationDecimals));
        } else if (baseDecimals < destinationDecimals) {
            amount = amount.mul(10**(destinationDecimals - baseDecimals));
        }

        return amount;
    }

    function convertTo18(uint256 amount, uint256 baseDecimals) internal pure returns (uint256) {
        if (baseDecimals == 18) return amount;
        return convert(amount, baseDecimals, 18);
    }

    function convertFrom18(uint256 amount, uint256 destinationDecimals)
        internal
        pure
        returns (uint256)
    {
        if (destinationDecimals == 18) return amount;
        return convert(amount, 18, destinationDecimals);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

interface IYieldGenerator {
    enum DefiProtocols {DefiProtocol1, DefiProtocol2, DefiProtocol3}
    enum Networks {ETH, BSC, POL}

    struct DefiProtocol {
        uint256 targetAllocation;
        uint256 currentAllocation;
        uint256 rebalanceWeight;
        uint256 depositedAmount;
        bool whiteListed;
        bool threshold;
        bool withdrawMax;
        // new state post v2
        uint256 totalValue;
        uint256 depositCost;
    }

    function totalDeposit() external returns (uint256);

    function protocolsNumber() external returns (uint256);

    /// @notice deposit stable coin into multiple defi protocols using formulas, access: capital pool
    /// @param amount uint256 the amount of stable coin to deposit
    function deposit(uint256 amount) external returns (uint256);

    /// @notice withdraw stable coin from mulitple defi protocols using formulas, access: capital pool
    /// @param amount uint256 the amount of stable coin to withdraw
    function withdraw(uint256 amount) external returns (uint256);

    /// @notice set the protocol settings for each defi protocol (allocations, whitelisted, depositCost), access: owner
    /// @param whitelisted bool[] list of whitelisted values for each protocol
    /// @param allocations uint256[] list of allocations value for each protocol
    /// @param depositCost uint256[] list of depositCost values for each protocol
    function setProtocolSettings(
        bool[] calldata whitelisted,
        uint256[] calldata allocations,
        uint256[] calldata depositCost
    ) external;

    /// @notice Claims farmed tokens and sends it to the reinsurance pool
    function claimRewards() external;

    /// @notice returns defi protocol info by its index
    /// @param index uint256 the index of the defi protocol
    function defiProtocol(uint256 index)
        external
        view
        returns (
            uint256 _targetAllocation,
            uint256 _currentAllocation,
            uint256 _rebalanceWeight,
            uint256 _depositedAmount,
            bool _whiteListed,
            bool _threshold,
            uint256 _totalValue,
            uint256 _depositCost
        );

    function reevaluateDefiProtocolBalances()
        external
        returns (uint256 _totalDeposit, uint256 _lostAmount);

    function defiHardRebalancing() external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IPolicyBookFabric.sol";
import "./IClaimingRegistry.sol";
import "./IPolicyBookFacade.sol";

interface IUserLeveragePool {
    enum WithdrawalStatus {NONE, PENDING, READY, EXPIRED}

    struct WithdrawalInfo {
        uint256 withdrawalAmount;
        uint256 readyToWithdrawDate;
        bool withdrawalAllowed;
    }

    struct BMIMultiplierFactors {
        uint256 poolMultiplier;
        uint256 leverageProvided;
        uint256 multiplier;
    }

    /// @notice Returns type of contract this PolicyBook covers, access: ANY
    /// @return _type is type of contract
    function contractType() external view returns (IPolicyBookFabric.ContractType _type);

    function userLiquidity(address account) external view returns (uint256);

    function a2_ProtocolConstant() external view returns (uint256);

    function EPOCH_DURATION() external view returns (uint256);

    function READY_TO_WITHDRAW_PERIOD() external view returns (uint256);

    function epochStartTime() external view returns (uint256);

    function withdrawalsInfo(address _userAddr)
        external
        view
        returns (
            uint256 _withdrawalAmount,
            uint256 _readyToWithdrawDate,
            bool _withdrawalAllowed
        );

    function __UserLeveragePool_init(
        IPolicyBookFabric.ContractType _contractType,
        string calldata _description,
        string calldata _projectSymbol
    ) external;

    function getEpoch(uint256 time) external view returns (uint256);

    /// @notice get STBL equivalent
    function convertBMIXToSTBL(uint256 _amount) external view returns (uint256);

    /// @notice get BMIX equivalent
    function convertSTBLToBMIX(uint256 _amount) external view returns (uint256);

    /// @notice function to get precise current cover and liquidity
    function getNewCoverAndLiquidity()
        external
        view
        returns (uint256 newTotalCoverTokens, uint256 newTotalLiquidity);

    function updateEpochsInfo() external;

    function secondsToEndCurrentEpoch() external view returns (uint256);

    /// @notice Let user to add liquidity by supplying stable coin, access: ANY
    /// @param _liqudityAmount is amount of stable coin tokens to secure
    function addLiquidity(uint256 _liqudityAmount) external;

    // /// @notice Let eligible contracts add liqiudity for another user by supplying stable coin
    // /// @param _liquidityHolderAddr is address of address to assign cover
    // /// @param _liqudityAmount is amount of stable coin tokens to secure
    // function addLiquidityFor(address _liquidityHolderAddr, uint256 _liqudityAmount) external;

    function addLiquidityAndStake(uint256 _liquidityAmount, uint256 _stakeSTBLAmount) external;

    function getAvailableBMIXWithdrawableAmount(address _userAddr) external view returns (uint256);

    function getWithdrawalStatus(address _userAddr) external view returns (WithdrawalStatus);

    function requestWithdrawal(uint256 _tokensToWithdraw) external;

    // function requestWithdrawalWithPermit(
    //     uint256 _tokensToWithdraw,
    //     uint8 _v,
    //     bytes32 _r,
    //     bytes32 _s
    // ) external;

    function unlockTokens() external;

    /// @notice Let user to withdraw deposited liqiudity, access: ANY
    function withdrawLiquidity() external;

    function getAPY() external view returns (uint256);

    function whitelisted() external view returns (bool);

    function whitelist(bool _whitelisted) external;

    /// @notice set max total liquidity for the pool
    /// @param _maxCapacities uint256 the max total liquidity
    function setMaxCapacities(uint256 _maxCapacities) external;

    function setA2_ProtocolConstant(uint256 _a2_ProtocolConstant) external;

    /// @notice Getting number stats, access: ANY
    /// @return _maxCapacities is a max liquidity of the pool
    /// @return _buyPolicyCapacity is becuase to follow the same function in policy book
    /// @return _totalSTBLLiquidity is PolicyBook's liquidity
    /// @return _totalLeveragedLiquidity is becuase to follow the same function in policy book
    /// @return _stakedSTBL is how much stable coin are staked on this PolicyBook
    /// @return _annualProfitYields is its APY
    /// @return _annualInsuranceCost is becuase to follow the same function in policy book
    /// @return  _bmiXRatio is multiplied by 10**18. To get STBL representation
    function numberStats()
        external
        view
        returns (
            uint256 _maxCapacities,
            uint256 _buyPolicyCapacity,
            uint256 _totalSTBLLiquidity,
            uint256 _totalLeveragedLiquidity,
            uint256 _stakedSTBL,
            uint256 _annualProfitYields,
            uint256 _annualInsuranceCost,
            uint256 _bmiXRatio
        );

    /// @notice Getting info, access: ANY
    /// @return _symbol is the symbol of PolicyBook (bmiXCover)
    /// @return _insuredContract is an addres of insured contract
    /// @return _contractType is becuase to follow the same function in policy book
    /// @return _whitelisted is a state of whitelisting
    function info()
        external
        view
        returns (
            string memory _symbol,
            address _insuredContract,
            IPolicyBookFabric.ContractType _contractType,
            bool _whitelisted
        );
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IPolicyBookFabric.sol";

interface IPolicyBookRegistry {
    struct PolicyBookStats {
        string symbol;
        address insuredContract;
        IPolicyBookFabric.ContractType contractType;
        uint256 maxCapacity;
        uint256 totalSTBLLiquidity;
        uint256 totalLeveragedLiquidity;
        uint256 stakedSTBL;
        uint256 APY;
        uint256 annualInsuranceCost;
        uint256 bmiXRatio;
        bool whitelisted;
    }

    function policyBooksByInsuredAddress(address insuredContract) external view returns (address);

    function policyBookFacades(address facadeAddress) external view returns (address);

    /// @notice Adds PolicyBook to registry, access: PolicyFabric
    function add(
        address insuredContract,
        IPolicyBookFabric.ContractType contractType,
        address policyBook,
        address facadeAddress
    ) external;

    function whitelist(address policyBookAddress, bool whitelisted) external;

    /// @notice returns required allowances for the policybooks
    function getPoliciesPrices(
        address[] calldata policyBooks,
        uint256[] calldata epochsNumbers,
        uint256[] calldata coversTokens
    ) external view returns (uint256[] memory _durations, uint256[] memory _allowances);

    /// @notice Buys a batch of policies
    function buyPolicyBatch(
        address[] calldata policyBooks,
        uint256[] calldata epochsNumbers,
        uint256[] calldata coversTokens
    ) external;

    /// @notice Checks if provided address is a PolicyBook
    function isPolicyBook(address policyBook) external view returns (bool);

    /// @notice Checks if provided address is a policyBookFacade
    function isPolicyBookFacade(address _facadeAddress) external view returns (bool);

    /// @notice Checks if provided address is a user leverage pool
    function isUserLeveragePool(address policyBookAddress) external view returns (bool);

    /// @notice Returns number of registered PolicyBooks with certain contract type
    function countByType(IPolicyBookFabric.ContractType contractType)
        external
        view
        returns (uint256);

    /// @notice Returns number of registered PolicyBooks, access: ANY
    function count() external view returns (uint256);

    function countByTypeWhitelisted(IPolicyBookFabric.ContractType contractType)
        external
        view
        returns (uint256);

    function countWhitelisted() external view returns (uint256);

    /// @notice Listing registered PolicyBooks with certain contract type, access: ANY
    /// @return _policyBooksArr is array of registered PolicyBook addresses with certain contract type
    function listByType(
        IPolicyBookFabric.ContractType contractType,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory _policyBooksArr);

    /// @notice Listing registered PolicyBooks, access: ANY
    /// @return _policyBooksArr is array of registered PolicyBook addresses
    function list(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory _policyBooksArr);

    function listByTypeWhitelisted(
        IPolicyBookFabric.ContractType contractType,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory _policyBooksArr);

    function listWhitelisted(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory _policyBooksArr);

    /// @notice Listing registered PolicyBooks with stats and certain contract type, access: ANY
    function listWithStatsByType(
        IPolicyBookFabric.ContractType contractType,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory _policyBooksArr, PolicyBookStats[] memory _stats);

    /// @notice Listing registered PolicyBooks with stats, access: ANY
    function listWithStats(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory _policyBooksArr, PolicyBookStats[] memory _stats);

    function listWithStatsByTypeWhitelisted(
        IPolicyBookFabric.ContractType contractType,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory _policyBooksArr, PolicyBookStats[] memory _stats);

    function listWithStatsWhitelisted(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory _policyBooksArr, PolicyBookStats[] memory _stats);

    /// @notice Getting stats from policy books, access: ANY
    /// @param policyBooks is list of PolicyBooks addresses
    function stats(address[] calldata policyBooks)
        external
        view
        returns (PolicyBookStats[] memory _stats);

    /// @notice Return existing Policy Book contract, access: ANY
    /// @param insuredContract is contract address to lookup for created IPolicyBook
    function policyBookFor(address insuredContract) external view returns (address);

    /// @notice Getting stats from policy books, access: ANY
    /// @param insuredContracts is list of insuredContracts in registry
    function statsByInsuredContracts(address[] calldata insuredContracts)
        external
        view
        returns (PolicyBookStats[] memory _stats);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

import "./IPolicyBook.sol";
import "./IPolicyBookFabric.sol";
import "./ILeveragePortfolio.sol";

interface IPolicyBookFacade {
    /// @notice Let user to buy policy by supplying stable coin, access: ANY
    /// @param _epochsNumber period policy will cover
    /// @param _coverTokens amount paid for the coverage
    function buyPolicy(uint256 _epochsNumber, uint256 _coverTokens) external;

    /// @param _holder who owns coverage
    /// @param _epochsNumber period policy will cover
    /// @param _coverTokens amount paid for the coverage
    function buyPolicyFor(
        address _holder,
        uint256 _epochsNumber,
        uint256 _coverTokens
    ) external;

    function policyBook() external view returns (IPolicyBook);

    function userLiquidity(address account) external view returns (uint256);

    /// @notice forces an update of RewardsGenerator multiplier
    function forceUpdateBMICoverStakingRewardMultiplier() external;

    /// @notice view function to get precise policy price
    /// @param _epochsNumber is number of epochs to cover
    /// @param _coverTokens is number of tokens to cover
    /// @param _buyer address of the user who buy the policy
    /// @return totalSeconds is number of seconds to cover
    /// @return totalPrice is the policy price which will pay by the buyer
    function getPolicyPrice(
        uint256 _epochsNumber,
        uint256 _coverTokens,
        address _buyer
    )
        external
        view
        returns (
            uint256 totalSeconds,
            uint256 totalPrice,
            uint256 pricePercentage
        );

    function secondsToEndCurrentEpoch() external view returns (uint256);

    /// @notice virtual funds deployed by reinsurance pool
    function VUreinsurnacePool() external view returns (uint256);

    /// @notice leverage funds deployed by reinsurance pool
    function LUreinsurnacePool() external view returns (uint256);

    /// @notice leverage funds deployed by user leverage pool
    function LUuserLeveragePool(address userLeveragePool) external view returns (uint256);

    /// @notice total leverage funds deployed to the pool sum of (VUreinsurnacePool,LUreinsurnacePool,LUuserLeveragePool)
    function totalLeveragedLiquidity() external view returns (uint256);

    function userleveragedMPL() external view returns (uint256);

    function reinsurancePoolMPL() external view returns (uint256);

    function rebalancingThreshold() external view returns (uint256);

    function safePricingModel() external view returns (bool);

    /// @notice policyBookFacade initializer
    /// @param pbProxy polciybook address upgreadable cotnract.
    function __PolicyBookFacade_init(
        address pbProxy,
        address liquidityProvider,
        uint256 initialDeposit
    ) external;

    /// @param _epochsNumber period policy will cover
    /// @param _coverTokens amount paid for the coverage
    /// @param _distributor if it was sold buy a whitelisted distributor, it is distributor address to receive fee (commission)
    function buyPolicyFromDistributor(
        uint256 _epochsNumber,
        uint256 _coverTokens,
        address _distributor
    ) external;

    /// @param _buyer who is buying the coverage
    /// @param _epochsNumber period policy will cover
    /// @param _coverTokens amount paid for the coverage
    /// @param _distributor if it was sold buy a whitelisted distributor, it is distributor address to receive fee (commission)
    function buyPolicyFromDistributorFor(
        address _buyer,
        uint256 _epochsNumber,
        uint256 _coverTokens,
        address _distributor
    ) external;

    /// @notice Let user to add liquidity by supplying stable coin, access: ANY
    /// @param _liquidityAmount is amount of stable coin tokens to secure
    function addLiquidity(uint256 _liquidityAmount) external;

    /// @notice Let user to add liquidity by supplying stable coin, access: ANY
    /// @param _user the one taht add liquidity
    /// @param _liquidityAmount is amount of stable coin tokens to secure
    function addLiquidityFromDistributorFor(address _user, uint256 _liquidityAmount) external;

    function addLiquidityAndStakeFor(
        address _liquidityHolderAddr,
        uint256 _liquidityAmount,
        uint256 _stakeSTBLAmount
    ) external;

    /// @notice Let user to add liquidity by supplying stable coin and stake it,
    /// @dev access: ANY
    function addLiquidityAndStake(uint256 _liquidityAmount, uint256 _stakeSTBLAmount) external;

    /// @notice Let user to withdraw deposited liqiudity, access: ANY
    function withdrawLiquidity() external;

    /// @notice deploy leverage funds (RP lStable, ULP lStable)
    /// @param  deployedAmount uint256 the deployed amount to be added or substracted from the total liquidity
    /// @param leveragePool whether user leverage or reinsurance leverage
    function deployLeverageFundsAfterRebalance(
        uint256 deployedAmount,
        ILeveragePortfolio.LeveragePortfolio leveragePool
    ) external;

    /// @notice deploy virtual funds (RP vStable)
    /// @param  deployedAmount uint256 the deployed amount to be added to the liquidity
    function deployVirtualFundsAfterRebalance(uint256 deployedAmount) external;

    ///@dev in case ur changed of the pools by commit a claim or policy expired
    function reevaluateProvidedLeverageStable() external;

    /// @notice set the MPL for the user leverage and the reinsurance leverage
    /// @param _userLeverageMPL uint256 value of the user leverage MPL
    /// @param _reinsuranceLeverageMPL uint256  value of the reinsurance leverage MPL
    function setMPLs(uint256 _userLeverageMPL, uint256 _reinsuranceLeverageMPL) external;

    /// @notice sets the rebalancing threshold value
    /// @param _newRebalancingThreshold uint256 rebalancing threshhold value
    function setRebalancingThreshold(uint256 _newRebalancingThreshold) external;

    /// @notice sets the rebalancing threshold value
    /// @param _safePricingModel bool is pricing model safe (true) or not (false)
    function setSafePricingModel(bool _safePricingModel) external;

    /// @notice returns how many BMI tokens needs to approve in order to submit a claim
    function getClaimApprovalAmount(address user) external view returns (uint256);

    /// @notice upserts a withdraw request
    /// @dev prevents adding a request if an already pending or ready request is open.
    /// @param _tokensToWithdraw uint256 amount of tokens to withdraw
    function requestWithdrawal(uint256 _tokensToWithdraw) external;

    function listUserLeveragePools(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory _userLeveragePools);

    function countUserLeveragePools() external view returns (uint256);

    /// @notice Getting info, access: ANY
    /// @return _symbol is the symbol of PolicyBook (bmiXCover)
    /// @return _insuredContract is an addres of insured contract
    /// @return _contractType is a type of insured contract
    /// @return _whitelisted is a state of whitelisting
    function info()
        external
        view
        returns (
            string memory _symbol,
            address _insuredContract,
            IPolicyBookFabric.ContractType _contractType,
            bool _whitelisted
        );
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

interface IPolicyBookFabric {
    enum ContractType {CONTRACT, STABLECOIN, SERVICE, EXCHANGE, VARIOUS}

    /// @notice Create new Policy Book contract, access: ANY
    /// @param _contract is Contract to create policy book for
    /// @param _contractType is Contract to create policy book for
    /// @param _description is bmiXCover token desription for this policy book
    /// @param _projectSymbol replaces x in bmiXCover token symbol
    /// @param _initialDeposit is an amount user deposits on creation (addLiquidity())
    /// @return _policyBook is address of created contract
    function create(
        address _contract,
        ContractType _contractType,
        string calldata _description,
        string calldata _projectSymbol,
        uint256 _initialDeposit,
        address _shieldMiningToken
    ) external returns (address);

    function createLeveragePools(
        address _insuranceContract,
        ContractType _contractType,
        string calldata _description,
        string calldata _projectSymbol
    ) external returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IPolicyBookFabric.sol";
import "./IClaimingRegistry.sol";
import "./IPolicyBookFacade.sol";

interface IPolicyBook {
    enum WithdrawalStatus {NONE, PENDING, READY, EXPIRED}

    struct PolicyHolder {
        uint256 coverTokens;
        uint256 startEpochNumber;
        uint256 endEpochNumber;
        uint256 paid;
        uint256 reinsurancePrice;
    }

    struct WithdrawalInfo {
        uint256 withdrawalAmount;
        uint256 readyToWithdrawDate;
        bool withdrawalAllowed;
    }

    struct BuyPolicyParameters {
        address buyer;
        address holder;
        uint256 epochsNumber;
        uint256 coverTokens;
        uint256 distributorFee;
        address distributor;
    }

    function policyHolders(address _holder)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        );

    function policyBookFacade() external view returns (IPolicyBookFacade);

    function setPolicyBookFacade(address _policyBookFacade) external;

    function EPOCH_DURATION() external view returns (uint256);

    function stblDecimals() external view returns (uint256);

    function READY_TO_WITHDRAW_PERIOD() external view returns (uint256);

    function whitelisted() external view returns (bool);

    function epochStartTime() external view returns (uint256);

    // @TODO: should we let DAO to change contract address?
    /// @notice Returns address of contract this PolicyBook covers, access: ANY
    /// @return _contract is address of covered contract
    function insuranceContractAddress() external view returns (address _contract);

    /// @notice Returns type of contract this PolicyBook covers, access: ANY
    /// @return _type is type of contract
    function contractType() external view returns (IPolicyBookFabric.ContractType _type);

    function totalLiquidity() external view returns (uint256);

    function totalCoverTokens() external view returns (uint256);

    // /// @notice return MPL for user leverage pool
    // function userleveragedMPL() external view returns (uint256);

    // /// @notice return MPL for reinsurance pool
    // function reinsurancePoolMPL() external view returns (uint256);

    // function bmiRewardMultiplier() external view returns (uint256);

    function withdrawalsInfo(address _userAddr)
        external
        view
        returns (
            uint256 _withdrawalAmount,
            uint256 _readyToWithdrawDate,
            bool _withdrawalAllowed
        );

    function __PolicyBook_init(
        address _insuranceContract,
        IPolicyBookFabric.ContractType _contractType,
        string calldata _description,
        string calldata _projectSymbol
    ) external;

    function whitelist(bool _whitelisted) external;

    function getEpoch(uint256 time) external view returns (uint256);

    /// @notice get STBL equivalent
    function convertBMIXToSTBL(uint256 _amount) external view returns (uint256);

    /// @notice get BMIX equivalent
    function convertSTBLToBMIX(uint256 _amount) external view returns (uint256);

    /// @notice submits new claim of the policy book
    function submitClaimAndInitializeVoting(string calldata evidenceURI) external;

    /// @notice submits new appeal claim of the policy book
    function submitAppealAndInitializeVoting(string calldata evidenceURI) external;

    /// @notice updates info on claim when not accepted
    function commitClaim(
        address claimer,
        uint256 claimEndTime,
        IClaimingRegistry.ClaimStatus status
    ) external;

    /// @notice withdraw the claim after requested
    function commitWithdrawnClaim(address claimer) external;

    /// @notice function to get precise current cover and liquidity
    function getNewCoverAndLiquidity()
        external
        view
        returns (uint256 newTotalCoverTokens, uint256 newTotalLiquidity);

    /// @notice Let user to buy policy by supplying stable coin, access: ANY
    /// @param _buyer who is transferring funds
    /// @param _holder who owns coverage
    /// @param _epochsNumber period policy will cover
    /// @param _coverTokens amount paid for the coverage
    /// @param _distributorFee distributor fee (commission). It can't be greater than PROTOCOL_PERCENTAGE
    /// @param _distributor if it was sold buy a whitelisted distributor, it is distributor address to receive fee (commission)
    function buyPolicy(
        address _buyer,
        address _holder,
        uint256 _epochsNumber,
        uint256 _coverTokens,
        uint256 _distributorFee,
        address _distributor
    ) external returns (uint256, uint256);

    /// @notice end active policy from ClaimingRegistry in case of a new bought policy
    function endActivePolicy(address _holder) external;

    function updateEpochsInfo() external;

    /// @notice Let eligible contracts add liqiudity for another user by supplying stable coin
    /// @param _liquidityHolderAddr is address of address to assign cover
    /// @param _liqudityAmount is amount of stable coin tokens to secure
    function addLiquidityFor(address _liquidityHolderAddr, uint256 _liqudityAmount) external;

    /// @notice Let user to add liquidity by supplying stable coin, access: ANY
    /// @param _liquidityBuyerAddr address the one that transfer funds
    /// @param _liquidityHolderAddr address the one that owns liquidity
    /// @param _liquidityAmount uint256 amount to be added on behalf the sender
    /// @param _stakeSTBLAmount uint256 the staked amount if add liq and stake
    function addLiquidity(
        address _liquidityBuyerAddr,
        address _liquidityHolderAddr,
        uint256 _liquidityAmount,
        uint256 _stakeSTBLAmount
    ) external returns (uint256);

    function getAvailableBMIXWithdrawableAmount(address _userAddr) external view returns (uint256);

    function getWithdrawalStatus(address _userAddr) external view returns (WithdrawalStatus);

    function requestWithdrawal(uint256 _tokensToWithdraw, address _user) external;

    // function requestWithdrawalWithPermit(
    //     uint256 _tokensToWithdraw,
    //     uint8 _v,
    //     bytes32 _r,
    //     bytes32 _s
    // ) external;

    function unlockTokens() external;

    /// @notice Let user to withdraw deposited liqiudity, access: ANY
    function withdrawLiquidity(address sender)
        external
        returns (uint256 _tokensToWithdraw, uint256 _stblTokensToWithdraw);

    ///@notice for doing defi hard rebalancing, access: policyBookFacade
    function updateLiquidity(uint256 _newLiquidity) external;

    function getAPY() external view returns (uint256);

    /// @notice Getting user stats, access: ANY
    function userStats(address _user) external view returns (PolicyHolder memory);

    /// @notice Getting number stats, access: ANY
    /// @return _maxCapacities is a max token amount that a user can buy
    /// @return _buyPolicyCapacity new capacity which is a max token amount that a user can buy including withdraw amount
    /// @return _totalSTBLLiquidity is PolicyBook's liquidity
    /// @return _totalLeveragedLiquidity is PolicyBook's leveraged liquidity
    /// @return _stakedSTBL is how much stable coin are staked on this PolicyBook
    /// @return _annualProfitYields is its APY
    /// @return _annualInsuranceCost is percentage of cover tokens that is required to be paid for 1 year of insurance
    function numberStats()
        external
        view
        returns (
            uint256 _maxCapacities,
            uint256 _buyPolicyCapacity,
            uint256 _totalSTBLLiquidity,
            uint256 _totalLeveragedLiquidity,
            uint256 _stakedSTBL,
            uint256 _annualProfitYields,
            uint256 _annualInsuranceCost,
            uint256 _bmiXRatio
        );
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

interface ILiquidityRegistry {
    struct LiquidityInfo {
        address policyBookAddr;
        uint256 lockedAmount;
        uint256 availableAmount;
        uint256 bmiXRatio; // multiply availableAmount by this num to get stable coin
    }

    struct WithdrawalRequestInfo {
        address policyBookAddr;
        uint256 requestAmount;
        uint256 requestSTBLAmount;
        uint256 availableLiquidity;
        uint256 readyToWithdrawDate;
        uint256 endWithdrawDate;
    }

    struct WithdrawalSetInfo {
        address policyBookAddr;
        uint256 requestAmount;
        uint256 requestSTBLAmount;
        uint256 availableSTBLAmount;
    }

    function tryToAddPolicyBook(address _userAddr, address _policyBookAddr) external;

    function tryToRemovePolicyBook(address _userAddr, address _policyBookAddr) external;

    function removeExpiredWithdrawalRequest(address _userAddr, address _policyBookAddr) external;

    function getPolicyBooksArrLength(address _userAddr) external view returns (uint256);

    function getPolicyBooksArr(address _userAddr)
        external
        view
        returns (address[] memory _resultArr);

    function getLiquidityInfos(
        address _userAddr,
        uint256 _offset,
        uint256 _limit
    ) external view returns (LiquidityInfo[] memory _resultArr);

    function getWithdrawalRequests(
        address _userAddr,
        uint256 _offset,
        uint256 _limit
    ) external view returns (uint256 _arrLength, WithdrawalRequestInfo[] memory _resultArr);

    function registerWithdrawl(address _policyBook, address _users) external;

    function getAllPendingWithdrawalRequestsAmount(uint256 _limit)
        external
        view
        returns (uint256 _totalWithdrawlAmount);

    function getPendingWithdrawalAmountByPolicyBook(address _policyBook, uint256 _limit)
        external
        view
        returns (uint256 _totalWithdrawlAmount);

    function getWithdrawlRequestUsersListCount() external view returns (uint256);

    function getPoolWithdrawlRequestsUsersListCount(address _policyBook)
        external
        view
        returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./ILeveragePortfolio.sol";
import "./IUserLeveragePool.sol";

interface ILeveragePortfolioView {
    function calcM(uint256 poolUR, address leveragePoolAddress)
        external
        view
        returns (uint256 _multiplier);

    function calcMaxLevFunds(ILeveragePortfolio.LevFundsFactors memory factors)
        external
        view
        returns (uint256);

    function calcBMIMultiplier(IUserLeveragePool.BMIMultiplierFactors memory factors)
        external
        view
        returns (uint256);

    function getPolicyBookFacade(address _policybookAddress)
        external
        view
        returns (IPolicyBookFacade _coveragePool);

    function calcNetMPLn(
        ILeveragePortfolio.LeveragePortfolio leveragePoolType,
        address _policyBookFacade
    ) external view returns (uint256 _netMPLn);

    function calcMaxVirtualFunds(address policyBookAddress, uint256 vStableWeight)
        external
        returns (uint256 _amountToDeploy, uint256 _maxAmount);

    function calcvStableFormulaforAllPools() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

interface ILeveragePortfolio {
    enum LeveragePortfolio {USERLEVERAGEPOOL, REINSURANCEPOOL}
    struct LevFundsFactors {
        uint256 netMPL;
        uint256 netMPLn;
        address policyBookAddr;
    }

    function targetUR() external view returns (uint256);

    function d_ProtocolConstant() external view returns (uint256);

    function a_ProtocolConstant() external view returns (uint256);

    function max_ProtocolConstant() external view returns (uint256);

    /// @notice deploy lStable from user leverage pool or reinsurance pool using 2 formulas: access by policybook.
    /// @param leveragePoolType LeveragePortfolio is determine the pool which call the function
    function deployLeverageStableToCoveragePools(LeveragePortfolio leveragePoolType)
        external
        returns (uint256);

    /// @notice deploy the vStable from RP in v2 and for next versions it will be from RP and LP : access by policybook.
    function deployVirtualStableToCoveragePools() external returns (uint256);

    /// @notice set the threshold % for re-evaluation of the lStable provided across all Coverage pools : access by owner
    /// @param threshold uint256 is the reevaluatation threshold
    function setRebalancingThreshold(uint256 threshold) external;

    /// @notice set the protocol constant : access by owner
    /// @param _targetUR uint256 target utitlization ration
    /// @param _d_ProtocolConstant uint256 D protocol constant
    /// @param  _a1_ProtocolConstant uint256 A1 protocol constant
    /// @param _max_ProtocolConstant uint256 the max % included
    function setProtocolConstant(
        uint256 _targetUR,
        uint256 _d_ProtocolConstant,
        uint256 _a1_ProtocolConstant,
        uint256 _max_ProtocolConstant
    ) external;

    /// @notice calc M factor by formual M = min( abs((1/ (Tur-UR))*d) /a, max)
    /// @param poolUR uint256 utitilization ratio for a coverage pool
    /// @return uint256 M facotr
    //function calcM(uint256 poolUR) external returns (uint256);

    /// @return uint256 the amount of vStable stored in the pool
    function totalLiquidity() external view returns (uint256);

    /// @notice add the portion of 80% of premium to user leverage pool where the leverage provide lstable : access policybook
    /// add the 20% of premium + portion of 80% of premium where reisnurance pool participate in coverage pools (vStable)  : access policybook
    /// @param epochsNumber uint256 the number of epochs which the policy holder will pay a premium for
    /// @param  premiumAmount uint256 the premium amount which is a portion of 80% of the premium
    function addPolicyPremium(uint256 epochsNumber, uint256 premiumAmount) external;

    /// @notice Used to get a list of coverage pools which get leveraged , use with count()
    /// @return _coveragePools a list containing policybook addresses
    function listleveragedCoveragePools(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory _coveragePools);

    /// @notice get count of coverage pools which get leveraged
    function countleveragedCoveragePools() external view returns (uint256);

    function updateLiquidity(uint256 _lostLiquidity) external;

    function forceUpdateBMICoverStakingRewardMultiplier() external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

interface IContractsRegistry {
    function getAMMRouterContract() external view returns (address);

    function getAMMBMIToETHPairContract() external view returns (address);

    function getAMMBMIToUSDTPairContract() external view returns (address);

    function getSushiSwapMasterChefV2Contract() external view returns (address);

    function getWrappedTokenContract() external view returns (address);

    function getUSDTContract() external view returns (address);

    function getBMIContract() external view returns (address);

    function getPriceFeedContract() external view returns (address);

    function getPolicyBookRegistryContract() external view returns (address);

    function getPolicyBookFabricContract() external view returns (address);

    function getBMICoverStakingContract() external view returns (address);

    function getBMICoverStakingViewContract() external view returns (address);

    function getBMITreasury() external view returns (address);

    function getRewardsGeneratorContract() external view returns (address);

    function getBMIUtilityNFTContract() external view returns (address);

    function getNFTStakingContract() external view returns (address);

    function getLiquidityBridgeContract() external view returns (address);

    function getClaimingRegistryContract() external view returns (address);

    function getPolicyRegistryContract() external view returns (address);

    function getLiquidityRegistryContract() external view returns (address);

    function getClaimVotingContract() external view returns (address);

    function getReinsurancePoolContract() external view returns (address);

    function getLeveragePortfolioViewContract() external view returns (address);

    function getCapitalPoolContract() external view returns (address);

    function getPolicyBookAdminContract() external view returns (address);

    function getPolicyQuoteContract() external view returns (address);

    function getBMIStakingContract() external view returns (address);

    function getSTKBMIContract() external view returns (address);

    function getStkBMIStakingContract() external view returns (address);

    function getVBMIContract() external view returns (address);

    function getLiquidityMiningStakingETHContract() external view returns (address);

    function getLiquidityMiningStakingUSDTContract() external view returns (address);

    function getReputationSystemContract() external view returns (address);

    function getDefiProtocol1Contract() external view returns (address);

    function getAaveLendPoolAddressProvdierContract() external view returns (address);

    function getAaveATokenContract() external view returns (address);

    function getDefiProtocol2Contract() external view returns (address);

    function getCompoundCTokenContract() external view returns (address);

    function getCompoundComptrollerContract() external view returns (address);

    function getDefiProtocol3Contract() external view returns (address);

    function getYearnVaultContract() external view returns (address);

    function getYieldGeneratorContract() external view returns (address);

    function getShieldMiningContract() external view returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IPolicyBookFabric.sol";

interface IClaimingRegistry {
    enum ClaimStatus {
        CAN_CLAIM,
        UNCLAIMABLE,
        PENDING,
        AWAITING_CALCULATION,
        REJECTED_CAN_APPEAL,
        REJECTED,
        ACCEPTED,
        EXPIRED
    }

    struct ClaimInfo {
        address claimer;
        address policyBookAddress;
        string evidenceURI;
        uint256 dateSubmitted;
        uint256 dateEnded;
        bool appeal;
        ClaimStatus status;
        uint256 claimAmount;
        uint256 claimRefund;
    }

    struct ClaimWithdrawalInfo {
        uint256 readyToWithdrawDate;
        bool committed;
    }

    struct RewardWithdrawalInfo {
        uint256 rewardAmount;
        uint256 readyToWithdrawDate;
    }

    enum WithdrawalStatus {NONE, PENDING, READY, EXPIRED}

    function claimWithdrawalInfo(uint256 index)
        external
        view
        returns (uint256 readyToWithdrawDate, bool committed);

    function rewardWithdrawalInfo(address voter)
        external
        view
        returns (uint256 rewardAmount, uint256 readyToWithdrawDate);

    /// @notice returns anonymous voting duration
    function anonymousVotingDuration(uint256 index) external view returns (uint256);

    /// @notice returns the whole voting duration
    function votingDuration(uint256 index) external view returns (uint256);

    /// @notice returns the whole voting duration + view verdict duration
    function validityDuration(uint256 index) external view returns (uint256);

    /// @notice returns how many time should pass before anyone could calculate a claim result
    function anyoneCanCalculateClaimResultAfter(uint256 index) external view returns (uint256);

    function canCalculateClaim(uint256 index, address calculator) external view returns (bool);

    /// @notice check if a user can buy new policy of specified PolicyBook and end the active one if there is
    function canBuyNewPolicy(address buyer, address policyBookAddress) external;

    /// @notice returns withdrawal status of requested claim
    function getClaimWithdrawalStatus(uint256 index) external view returns (WithdrawalStatus);

    /// @notice returns withdrawal status of requested reward
    function getRewardWithdrawalStatus(address voter) external view returns (WithdrawalStatus);

    /// @notice returns true if there is ongoing claiming procedure
    function hasProcedureOngoing(address poolAddress) external view returns (bool);

    /// @notice submits new PolicyBook claim for the user
    function submitClaim(
        address user,
        address policyBookAddress,
        string calldata evidenceURI,
        uint256 cover,
        bool appeal
    ) external returns (uint256);

    /// @notice returns true if the claim with this index exists
    function claimExists(uint256 index) external view returns (bool);

    /// @notice returns claim submition time
    function claimSubmittedTime(uint256 index) external view returns (uint256);

    /// @notice returns claim end time or zero in case it is pending
    function claimEndTime(uint256 index) external view returns (uint256);

    /// @notice returns true if the claim is anonymously votable
    function isClaimAnonymouslyVotable(uint256 index) external view returns (bool);

    /// @notice returns true if the claim is exposably votable
    function isClaimExposablyVotable(uint256 index) external view returns (bool);

    /// @notice returns true if claim is anonymously votable or exposably votable
    function isClaimVotable(uint256 index) external view returns (bool);

    /// @notice returns true if a claim can be calculated by anyone
    function canClaimBeCalculatedByAnyone(uint256 index) external view returns (bool);

    /// @notice returns true if this claim is pending or awaiting
    function isClaimPending(uint256 index) external view returns (bool);

    /// @notice returns how many claims the holder has
    function countPolicyClaimerClaims(address user) external view returns (uint256);

    /// @notice returns how many pending claims are there
    function countPendingClaims() external view returns (uint256);

    /// @notice returns how many claims are there
    function countClaims() external view returns (uint256);

    /// @notice returns a claim index of it's claimer and an ordinal number
    function claimOfOwnerIndexAt(address claimer, uint256 orderIndex)
        external
        view
        returns (uint256);

    /// @notice returns pending claim index by its ordinal index
    function pendingClaimIndexAt(uint256 orderIndex) external view returns (uint256);

    /// @notice returns claim index by its ordinal index
    function claimIndexAt(uint256 orderIndex) external view returns (uint256);

    /// @notice returns current active claim index by policybook and claimer
    function claimIndex(address claimer, address policyBookAddress)
        external
        view
        returns (uint256);

    /// @notice returns true if the claim is appealed
    function isClaimAppeal(uint256 index) external view returns (bool);

    /// @notice returns current status of a claim
    function policyStatus(address claimer, address policyBookAddress)
        external
        view
        returns (ClaimStatus);

    /// @notice returns current status of a claim
    function claimStatus(uint256 index) external view returns (ClaimStatus);

    /// @notice returns the claim owner (claimer)
    function claimOwner(uint256 index) external view returns (address);

    /// @notice returns the claim PolicyBook
    function claimPolicyBook(uint256 index) external view returns (address);

    /// @notice returns claim info by its index
    function claimInfo(uint256 index) external view returns (ClaimInfo memory _claimInfo);

    function getAllPendingClaimsAmount(uint256 _limit)
        external
        view
        returns (uint256 _totalClaimsAmount);

    function getAllPendingRewardsAmount(uint256 _limit)
        external
        view
        returns (uint256 _totalRewardsAmount);

    function getClaimableAmounts(uint256[] memory _claimIndexes) external view returns (uint256);

    function getBMIRewardForCalculation(uint256 index) external view returns (uint256);

    /// @notice marks the user's claim as Accepted
    function acceptClaim(uint256 index, uint256 amount) external;

    /// @notice marks the user's claim as Rejected
    function rejectClaim(uint256 index) external;

    /// @notice marks the user's claim as Expired
    function expireClaim(uint256 index) external;

    /// @notice Update Image Uri in case it contains material that is ilegal
    ///         or offensive.
    /// @dev Only the owner of the PolicyBookAdmin can erase/update evidenceUri.
    /// @param claim_Index Claim Index that is going to be updated
    /// @param _newEvidenceURI New evidence uri. It can be blank.
    function updateImageUriOfClaim(uint256 claim_Index, string calldata _newEvidenceURI) external;

    function requestClaimWithdrawal(uint256 index) external;

    function requestRewardWithdrawal(address voter, uint256 rewardAmount) external;

    function getWithdrawClaimRequestIndexListCount() external view returns (uint256);

    function getWithdrawRewardRequestVoterListCount() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IPolicyBookFacade.sol";

interface ICapitalPool {
    struct PremiumFactors {
        uint256 epochsNumber;
        uint256 premiumPrice;
        uint256 vStblDeployedByRP;
        uint256 vStblOfCP;
        uint256 poolUtilizationRation;
        uint256 premiumPerDeployment;
        uint256 userLeveragePoolsCount;
        IPolicyBookFacade policyBookFacade;
    }

    enum PoolType {COVERAGE, LEVERAGE, REINSURANCE}

    function virtualUsdtAccumulatedBalance() external view returns (uint256);

    function liquidityCushionBalance() external view returns (uint256);

    /// @notice distributes the policybook premiums into pools (CP, ULP , RP)
    /// @dev distributes the balances acording to the established percentages
    /// @param _stblAmount amount hardSTBL ingressed into the system
    /// @param _epochsNumber uint256 the number of epochs which the policy holder will pay a premium for
    /// @param _protocolFee uint256 the amount of protocol fee earned by premium
    function addPolicyHoldersHardSTBL(
        uint256 _stblAmount,
        uint256 _epochsNumber,
        uint256 _protocolFee
    ) external returns (uint256);

    /// @notice distributes the hardSTBL from the coverage providers
    /// @dev emits PoolBalancedUpdated event
    /// @param _stblAmount amount hardSTBL ingressed into the system
    function addCoverageProvidersHardSTBL(uint256 _stblAmount) external;

    /// @notice distributes the hardSTBL from the leverage providers
    /// @dev emits PoolBalancedUpdated event
    /// @param _stblAmount amount hardSTBL ingressed into the system
    function addLeverageProvidersHardSTBL(uint256 _stblAmount) external;

    /// @notice distributes the hardSTBL from the reinsurance pool
    /// @dev emits PoolBalancedUpdated event
    /// @param _stblAmount amount hardSTBL ingressed into the system
    function addReinsurancePoolHardSTBL(uint256 _stblAmount) external;

    /// @notice rebalances pools acording to v2 specification and dao enforced policies
    /// @dev  emits PoolBalancesUpdated
    function rebalanceLiquidityCushion() external;

    /// @notice Fullfils policybook claims by transfering the balance to claimer
    /// @param _claimer, address of the claimer recieving the withdraw
    /// @param _claimAmount uint256 amount to be withdrawn
    /// @param _policyBookAddress address of the policybook
    function fundClaim(
        address _claimer,
        uint256 _claimAmount,
        address _policyBookAddress
    ) external returns (uint256);

    /// @notice Fullfils policybook claims by transfering the balance to claimer
    /// @param _voter, address of the voter recieving the withdraw
    /// @param _rewardAmount uint256 amount to of the reward
    function fundReward(address _voter, uint256 _rewardAmount) external returns (uint256);

    /// @notice Withdraws liquidity from a specific policbybook to the user
    /// @param _sender, address of the user beneficiary of the withdraw
    /// @param _stblAmount uint256 amount to be withdrawn
    /// @param _isLeveragePool bool wether the pool is ULP or CP(policybook)
    function withdrawLiquidity(
        address _sender,
        uint256 _stblAmount,
        bool _isLeveragePool
    ) external returns (uint256);

    function rebalanceDuration() external view returns (uint256);

    function getWithdrawPeriod() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

import "../interfaces/IContractsRegistry.sol";

abstract contract AbstractDependant {
    /// @dev keccak256(AbstractDependant.setInjector(address)) - 1
    bytes32 private constant _INJECTOR_SLOT =
        0xd6b8f2e074594ceb05d47c27386969754b6ad0c15e5eb8f691399cd0be980e76;

    modifier onlyInjectorOrZero() {
        address _injector = injector();

        require(_injector == address(0) || _injector == msg.sender, "Dependant: Not an injector");
        _;
    }

    function setInjector(address _injector) external onlyInjectorOrZero {
        bytes32 slot = _INJECTOR_SLOT;

        assembly {
            sstore(slot, _injector)
        }
    }

    /// @dev has to apply onlyInjectorOrZero() modifier
    function setDependencies(IContractsRegistry) external virtual;

    function injector() public view returns (address _injector) {
        bytes32 slot = _INJECTOR_SLOT;

        assembly {
            _injector := sload(slot)
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

uint256 constant SECONDS_IN_THE_YEAR = 365 * 24 * 60 * 60; // 365 days * 24 hours * 60 minutes * 60 seconds
uint256 constant DAYS_IN_THE_YEAR = 365;
uint256 constant MAX_INT = type(uint256).max;

uint256 constant DECIMALS18 = 10**18;

uint256 constant PRECISION = 10**25;
uint256 constant PERCENTAGE_100 = 100 * PRECISION;

uint256 constant BLOCKS_PER_DAY = 6450;
uint256 constant BLOCKS_PER_YEAR = BLOCKS_PER_DAY * 365;

uint256 constant APY_TOKENS = DECIMALS18;

uint256 constant PROTOCOL_PERCENTAGE = 20 * PRECISION;

uint256 constant DEFAULT_REBALANCING_THRESHOLD = 10**23;

uint256 constant EPOCH_DAYS_AMOUNT = 7;

// ClaimVoting ClaimingRegistry
uint256 constant APPROVAL_PERCENTAGE = 66 * PRECISION;
uint256 constant PENALTY_THRESHOLD = 11 * PRECISION;
uint256 constant QUORUM = 10 * PRECISION;
uint256 constant CALCULATION_REWARD_PER_DAY = PRECISION;
uint256 constant PERCENTAGE_50 = 50 * PRECISION;

// PolicyBook
uint256 constant MINUMUM_COVERAGE = 100 * DECIMALS18; // 100 STBL
uint256 constant ANNUAL_COVERAGE_TOKENS = MINUMUM_COVERAGE * 10; // 1000 STBL

uint256 constant PREMIUM_DISTRIBUTION_EPOCH = 1 days;
uint256 constant MAX_PREMIUM_DISTRIBUTION_EPOCHS = 90;

// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

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
        // According to EIP-1052, 0x0 is the value returned for not-yet created accounts
        // and 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470 is returned
        // for accounts without code, i.e. `keccak256('')`
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        // solhint-disable-next-line no-inline-assembly
        assembly { codehash := extcodehash(account) }
        return (codehash != accountHash && codehash != 0x0);
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
        return _functionCallWithValue(target, data, 0, errorMessage);
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
        return _functionCallWithValue(target, data, value, errorMessage);
    }

    function _functionCallWithValue(address target, bytes memory data, uint256 weiValue, string memory errorMessage) private returns (bytes memory) {
        require(isContract(target), "Address: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.call{ value: weiValue }(data);
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

// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import "./IERC20.sol";
import "../../math/SafeMath.sol";
import "../../utils/Address.sol";

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
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        // solhint-disable-next-line max-line-length
        require((value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).add(value);
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).sub(value, "SafeERC20: decreased allowance below zero");
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
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

// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import "../../GSN/Context.sol";
import "./IERC20.sol";
import "../../math/SafeMath.sol";
import "../../utils/Address.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin guidelines: functions revert instead
 * of returning `false` on failure. This behavior is nonetheless conventional
 * and does not conflict with the expectations of ERC20 applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract ERC20 is Context, IERC20 {
    using SafeMath for uint256;
    using Address for address;

    mapping (address => uint256) private _balances;

    mapping (address => mapping (address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    /**
     * @dev Sets the values for {name} and {symbol}, initializes {decimals} with
     * a default value of 18.
     *
     * To select a different value for {decimals}, use {_setupDecimals}.
     *
     * All three of these values are immutable: they can only be set once during
     * construction.
     */
    constructor (string memory name, string memory symbol) {
        _name = name;
        _symbol = symbol;
        _decimals = 18;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5,05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless {_setupDecimals} is
     * called.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view returns (uint8) {
        return _decimals;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20};
     *
     * Requirements:
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     *
     * This is internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements
     *
     * - `to` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        _balances[account] = _balances[account].sub(amount, "ERC20: burn amount exceeds balance");
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Sets {decimals} to a value other than the default one of 18.
     *
     * WARNING: This function should only be called from the constructor. Most
     * applications that interact with token contracts will not expect
     * {decimals} to ever change, and may work incorrectly if it does.
     */
    function _setupDecimals(uint8 decimals_) internal {
        _decimals = decimals_;
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be to transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual { }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

/**
 * @dev Wrappers over Solidity's arithmetic operations with added overflow
 * checks.
 *
 * Arithmetic operations in Solidity wrap on overflow. This can easily result
 * in bugs, because programmers usually assume that an overflow raises an
 * error, which is the standard behavior in high level programming languages.
 * `SafeMath` restores this intuition by reverting the transaction when an
 * operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts with custom message when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow, so we distribute
        return (a / 2) + (b / 2) + ((a % 2 + b % 2) / 2);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with GSN meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address payable) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

// SPDX-License-Identifier: MIT

// solhint-disable-next-line compiler-version
pragma solidity >=0.4.24 <0.8.0;


/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since a proxied contract can't have a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 * 
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {UpgradeableProxy-constructor}.
 * 
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 */
abstract contract Initializable {

    /**
     * @dev Indicates that the contract has been initialized.
     */
    bool private _initialized;

    /**
     * @dev Indicates that the contract is in the process of being initialized.
     */
    bool private _initializing;

    /**
     * @dev Modifier to protect an initializer function from being invoked twice.
     */
    modifier initializer() {
        require(_initializing || _isConstructor() || !_initialized, "Initializable: contract is already initialized");

        bool isTopLevelCall = !_initializing;
        if (isTopLevelCall) {
            _initializing = true;
            _initialized = true;
        }

        _;

        if (isTopLevelCall) {
            _initializing = false;
        }
    }

    /// @dev Returns true if and only if the function is running in the constructor
    function _isConstructor() private view returns (bool) {
        // extcodesize checks the size of the code stored in an address, and
        // address returns the current address. Since the code is still not
        // deployed when running a constructor, any checks on its code size will
        // yield zero, making it an effective way to detect if a contract is
        // under construction or not.
        address self = address(this);
        uint256 cs;
        // solhint-disable-next-line no-inline-assembly
        assembly { cs := extcodesize(self) }
        return cs == 0;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "../GSN/ContextUpgradeable.sol";
import "../proxy/Initializable.sol";
/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract OwnableUpgradeable is Initializable, ContextUpgradeable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    function __Ownable_init() internal initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
    }

    function __Ownable_init_unchained() internal initializer {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
    uint256[49] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;
import "../proxy/Initializable.sol";

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with GSN meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal initializer {
        __Context_init_unchained();
    }

    function __Context_init_unchained() internal initializer {
    }
    function _msgSender() internal view virtual returns (address payable) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
    uint256[50] private __gap;
}