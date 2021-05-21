// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams, VaultAPI} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";


import "../interfaces/inverse.sol";
import "../interfaces/uniswap.sol";
import "../interfaces/weth.sol";


contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    modifier onlyInverseGovernance() {
        require(msg.sender == inverseGovernance, "!inverseGovernance");
        _;
    }

    uint private constant NO_ERROR = 0;

    IUniswapV2Router02 public router;
    VaultAPI public delegatedVault;
    ComptrollerInterface public comptroller;

    CErc20Interface public cWant;
    CEther public cBorrowed;
    CErc20Interface public cSupplied; // private market for Yearn, panDola
    xInvCoreInterface public xInv;

    IERC20 public borrowed;
    IERC20 public reward; // INV
    IWETH9 constant public weth = IWETH9(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    address[] public path;
    address[] public wethWantPath;
    address[] public claimableMarkets;

    address public inverseGovernance;
    uint256 public targetCollateralFactor;
    uint256 public collateralTolerance;
    uint256 public blocksToLiquidationDangerZone = uint256(7 days) / 13; // assuming 13 second block times
    uint256 public rewardEscrowPeriod = 14 days;
    uint256 public borrowLimit = 0; // TODO: set to 0, borrow nothing until set


    constructor(address _vault, address _cWant, address _cBorrowed, address _delegatedVault) public BaseStrategy(_vault) {
        inverseGovernance = 0x35d9f4953748b318f18c30634bA299b237eeDfff; // TODO temporarily GovernorAlpha

        delegatedVault = VaultAPI(_delegatedVault);
        router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        comptroller = ComptrollerInterface(0x4dCf7407AE5C07f8681e1659f626E114A7667339);

        cWant = CErc20Interface(_cWant);
        cBorrowed = CEther(_cBorrowed);
        xInv = xInvCoreInterface(0x65b35d6Eb7006e0e607BC54EB2dFD459923476fE);
        cSupplied = CErc20Interface(0xD60B06B457bFf7fc38AC5E7eCE2b5ad16B288326); // TODO temporarily Sushibar

        borrowed = IERC20(delegatedVault.token());
        reward = IERC20(0x41D5D79431A913C4aE7d69a668ecdfE5fF9DFB68); // INV

        require(cWant.underlying() != address(borrowed), "can't be delegating to your own vault");
        require(cWant.underlying() == address(want), "cWant does not match want");
        // TODO cETH uses a unique interface that does not have an underlying() fx
        //        require(cBorrowed.underlying() == address(borrowed), "cBorrowed does not match delegated vault token");
        //

        require(address(cWant) != address(cBorrowed), "want and borrowed markets can't be the same");
        require(address(cWant) != address(cSupplied), "want and supplied markets can't be the same");
        require(address(cWant) != address(xInv), "want and reward markets can't be the same");
        require(address(cBorrowed) != address(cSupplied), "borrowed and supplied markets can't be the same");
        require(address(cBorrowed) != address(xInv), "borrowed and reward markets can't be the same");
        require(address(cSupplied) != address(xInv), "supplied and reward markets can't be the same");

        path = [delegatedVault.token(), address(want)];
        wethWantPath = [address(weth), address(want)];

        claimableMarkets = new address[](3);
        claimableMarkets[0] = address(cWant);
        claimableMarkets[1] = address(cBorrowed);
        claimableMarkets[2] = address(cSupplied);
        comptroller.enterMarkets(claimableMarkets);

        targetCollateralFactor = 0.5 ether; // 50%
        collateralTolerance = 0.01 ether; // 1%

        want.safeApprove(address(cWant), uint256(-1));
        borrowed.safeApprove(address(delegatedVault), uint256(-1));
        weth.approve(address(this), uint256(-1));
        weth.approve(address(router), uint256(-1));
        reward.approve(address(xInv), uint256(-1));

        xInv.delegate(governance()); // delegate voting power to yearn gov
    }


    //
    // BaseContract overrides
    //

    function name() external view override returns (string memory) {
        return "StrategyInverseDolaLeverage";
        // return string(abi.encodePacked("StrategyInverse", IERC20Metadata(address(want)).symbol(), "Leverage"));
    }

    // User portion of the delegated assets in want
    function delegatedAssets() external override view returns (uint256) {
        uint256 _totalCollateral = valueOfTotalCollateral();
        if (_totalCollateral > 0) {
            uint256 _userDistribution = valueOfCWant().mul(1 ether).div(_totalCollateral);
            uint256 _userDelegated = valueOfDelegated().mul(_userDistribution).div(1 ether);
            return estimateAmountUsdInUnderlying(_userDelegated, cWant);
        } else {
            return 0;
        }
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(estimateAmountUsdInUnderlying(valueOfCWant().add(valueOfDelegated()).sub(valueOfBorrowedOwed()), cWant));
    }

    function ethToWant(uint256 _amtInWei) public view returns (uint256){
        uint256 amountOut = 0;
        if (_amtInWei > 0) {
            amountOut = router.getAmountsOut(_amtInWei, wethWantPath)[1];
        }
        return amountOut;
    }

    event Debug(string message, int256 amount);
    event Debug(string message, uint256 amount);
    event Debug(string message);

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        uint256 _looseBalance = balanceOfWant();

        sellProfits();

        // TODO lent interest

        uint256 _balanceAfterProfit = balanceOfWant();
        if (_balanceAfterProfit > _looseBalance) {
            _profit = _balanceAfterProfit.sub(_looseBalance);
        }

        if (_debtOutstanding > 0) {
            (uint256 _amountLiquidated, uint256 _amountLoss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_debtOutstanding, _amountLiquidated);
            if (_profit > _amountLoss) {
                _profit = _profit.sub(_amountLoss);
                _loss = 0;
            } else {
                _profit = 0;
                _loss = _amountLoss.sub(_profit);
            }
        }

        emit Debug("_loss", _loss);
        emit Debug("_balanceOfWant", balanceOfWant());
        emit Debug("_profit", _profit);
        emit Debug("_debtPayment", _debtPayment);

        comptroller.claimComp(address(this), claimableMarkets); // claim (but don't sell) INV
        emit Debug("_balanceOfReward", balanceOfReward());
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        assert(cWant.mint(balanceOfWant()) == NO_ERROR);
        assert(xInv.mint(balanceOfReward()) == NO_ERROR);

        rebalance(0);
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 looseBalance = balanceOfWant();
        if (_amountNeeded > looseBalance) {

            uint256 _desiredWithdraw = _amountNeeded.sub(looseBalance);
            safeUnwindCTokenUnderlying(_desiredWithdraw, cWant, true);
            uint256 _newLooseBalance = balanceOfWant();
            emit Debug("_liquidatePosition newLooseBalance", _newLooseBalance);
            emit Debug("_liquidatePosition _amountNeeded", _amountNeeded);

            _liquidatedAmount = Math.min(_amountNeeded, _newLooseBalance);
            if (_amountNeeded > _newLooseBalance) {
                _loss = _amountNeeded.sub(_newLooseBalance);
                emit Debug("_liquidatePosition _loss", _loss);
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function tendTrigger(uint256 callCostInWei) public override virtual view returns (bool) {
        if (harvestTrigger(ethToWant(callCostInWei))) {
            return false;
        }
        uint256 currentCF = currentCollateralFactor();
        bool isWithinCFRange = targetCollateralFactor.sub(collateralTolerance) < currentCF && currentCF < targetCollateralFactor.add(collateralTolerance);
        return blocksUntilLiquidation() <= blocksToLiquidationDangerZone || !isWithinCFRange;
        // return !isWithinCFRange;
    }

    function prepareMigration(address _newStrategy) internal override {
        // borrowed position can't be transferred so need to unwind everything before migrating
        liquidatePosition(estimatedTotalAssets());

        reward.transfer(_newStrategy, balanceOfReward());
        borrowed.transfer(_newStrategy, borrowed.balanceOf(address(this)));
        delegatedVault.transfer(_newStrategy, delegatedVault.balanceOf(address(this)));

        cWant.transfer(_newStrategy, cWant.balanceOf(address(this)));
        cSupplied.transfer(_newStrategy, cSupplied.balanceOf(address(this)));

        // can't transfer xINV. must redeem for INV and wait 14 days before withdrawing it from escrow.
        // gov to use withdrawEscrowedRewards() then sweep() after escrow period.
        xInv.redeem(xInv.balanceOf(address(this)));
    }

    function protectedTokens() internal view override returns (address[] memory){
        address[] memory protected = new address[](6);
        protected[0] = address(borrowed);
        protected[1] = address(delegatedVault);
        protected[2] = address(cWant);
        protected[3] = address(xInv);
        protected[4] = address(cSupplied);
        return protected;
    }

    receive() external payable {}


    //
    // Helpers
    //

    // calculate how long until assets can become liquidated based on:
    //   - supply rate of the collateral tokens: want, supplied, and reward
    //   - the borrow rate of the borrowed token
    //   - required collateral factor of the borrowed token
    // ((deposits*colateralThreshold - borrows) / (borrows*borrowrate - deposits*colateralThreshold*interestrate));
    function blocksUntilLiquidation() public view returns (uint256) {
        (, uint256 collateralFactorMantissa,) = comptroller.markets(address(cBorrowed));

        uint256 supplyRate1 = cWant.supplyRatePerBlock();
        uint256 collateralisedDeposit1 = valueOfCWant().mul(collateralFactorMantissa).div(1e18);

        uint256 supplyRate2 = cSupplied.supplyRatePerBlock();
        uint256 collateralisedDeposit2 = valueOfCSupplied().mul(collateralFactorMantissa).div(1e18);

        uint256 supplyRate3 = xInv.supplyRatePerBlock();
        uint256 collateralisedDeposit3 = valueOfxInv().mul(collateralFactorMantissa).div(1e18);

        uint256 borrowBalance = valueOfBorrowedOwed();
        uint256 borrrowRate = cBorrowed.borrowRatePerBlock();

        uint256 denom1 = borrowBalance.mul(borrrowRate);
        uint256 denom2 = collateralisedDeposit1.mul(supplyRate1).add(collateralisedDeposit2.mul(supplyRate2)).add(collateralisedDeposit3.mul(supplyRate3));

        if (denom2 >= denom1) {
            return uint256(- 1);
        } else {
            uint256 numer = collateralisedDeposit1.add(collateralisedDeposit2).add(collateralisedDeposit3).sub(borrowBalance);
            uint256 denom = denom1 - denom2;
            //minus 1 for this block
            return numer.mul(1e18).div(denom);
        }
    }

    // free up _amountUnderlying worth of borrowed while maintaining targetCollateralRatio.
    // function will try to free up as much as it can safely
    // @param redeem: True will redeem to cToken.underlying. False will remain as cToken
    function safeUnwindCTokenUnderlying(uint256 _amountUnderlying, CErc20Interface _cToken, bool redeem) internal {
        emit Debug("_safeUnwindCTokenUnderlying");
        _cToken.accrueInterest();
        uint256 _amountUnderlyingInUsd = estimateAmountUnderlyingInUsd(_amountUnderlying, _cToken);

        rebalance(_amountUnderlyingInUsd);
        // cTokens are now freed up

        if (redeem) {
            uint256 _valueCollatToMaintain = valueOfBorrowedOwed().mul(1 ether).div(targetCollateralFactor);
            uint256 _valueCollatRedeemable = valueOfTotalCollateral().sub(_valueCollatToMaintain);
            uint256 _amountCollatRedeemableInUnderlying = estimateAmountUsdInUnderlying(_valueCollatRedeemable, _cToken);
            uint256 _amountCTokenInUnderlying = estimateAmountCTokenInUnderlying(_cToken.balanceOf(address(this)), _cToken);
            uint256 _amountMarketCashInUnderlying = _cToken.getCash();

            // min of (market's cash available, safe amount redeemable for strat, cToken as underlying in strat)
            uint256 _valueUnderlyingRedeemable = Math.min(_amountCollatRedeemableInUnderlying, _amountCTokenInUnderlying);
            _valueUnderlyingRedeemable = Math.min(_valueUnderlyingRedeemable, _amountMarketCashInUnderlying);

            emit Debug("calculateAdjustment _amountCRedeemable", _valueUnderlyingRedeemable);
            uint256 error = _cToken.redeemUnderlying(_valueUnderlyingRedeemable);
            emit Debug("calculateAdjustment error", uint256(error));
            require(error == 0, "error redeeming");
            uint256 _want = balanceOfWant();
            emit Debug("calculateAdjustment _want", _want);
        }
    }

    // Calculate adjustments on borrowing market to maintain targetCollateralFactor and borrowLimit
    // @param _amountPendingWithdrawInUsd should be left out of adjustment
    function calculateAdjustmentInUsd(uint256 _amountPendingWithdrawInUsd) internal returns (uint256 adjustmentUsd, bool neg){
        uint256 _valueCollaterals = valueOfTotalCollateral();
        if (_valueCollaterals < _amountPendingWithdrawInUsd) {
            neg = true;
            _valueCollaterals = _amountPendingWithdrawInUsd.sub(_valueCollaterals);
        } else {
            _valueCollaterals = _valueCollaterals.sub(_amountPendingWithdrawInUsd);
        }
        uint256 _borrowTargetUsd = _valueCollaterals.mul(targetCollateralFactor).div(1e18);

        uint256 _borrowLimitUsd = estimateAmountUnderlyingInUsd(borrowLimit, cBorrowed);
        if (!neg && _borrowTargetUsd > _borrowLimitUsd) {
            _borrowTargetUsd = _borrowLimitUsd;
        }

        uint256 _borrowOwed = valueOfBorrowedOwed();
        if (neg) {
            adjustmentUsd = _borrowTargetUsd.add(_borrowOwed);
        } else if (_borrowOwed > _borrowTargetUsd) {
            neg = true;
            adjustmentUsd = _borrowOwed.sub(_borrowTargetUsd);
        } else {
            adjustmentUsd = _borrowTargetUsd.sub(_borrowOwed);
        }
    }

    // Rebalances supply/borrow to maintain targetCollaterFactor
    // @param _pendingWithdrawInUsd = collateral that needs to be freed up after rebalancing
    function rebalance(uint256 _pendingWithdrawInUsd) internal {
        emit Debug("rebalance _pendingWithdrawInUsd", _pendingWithdrawInUsd);
        (uint256 _adjustmentInUsd, bool _neg) = calculateAdjustmentInUsd(_pendingWithdrawInUsd);
        emit Debug("rebalance _adjustmentInUsd", _adjustmentInUsd);

        if (_adjustmentInUsd == 0) {
            // do nothing
        } else if (!_neg) {
            // overcollateralized, can borrow more
            uint256 _adjustmentInBorrowed = estimateAmountUsdInUnderlying(_adjustmentInUsd, cBorrowed);
            emit Debug("rebalance _adjustmentInBorrowed", _adjustmentInBorrowed);

            assert(cBorrowed.borrow(_adjustmentInBorrowed) == NO_ERROR);
            uint256 _actualBorrowed = address(this).balance;

            // wrap ether
            weth.deposit{value : _actualBorrowed}();
            uint256 _wethBalanace = weth.balanceOf(address(this));
            emit Debug("rebalance _actualBorrowed", _wethBalanace);

            delegatedVault.deposit(_wethBalanace);
        } else {
            emit Debug("_adjust negative");

            // undercollateralized, must unwind and repay to free up collateral
            uint256 _adjustmentInBorrowed = estimateAmountUsdInUnderlying(_adjustmentInUsd, cBorrowed);
            uint256 _adjustmentInShares = estimateAmountBorrowedInShares(_adjustmentInBorrowed);
            uint256 _adjustmentInSharesAllowed = Math.min(delegatedVault.balanceOf(address(this)), _adjustmentInShares);
            uint256 _amountBorrowedWithdrawn = delegatedVault.withdraw(_adjustmentInSharesAllowed);

            // unwrap eth
            weth.withdraw(_amountBorrowedWithdrawn);

            emit Debug("_adjust bal eth before", balanceOfEth());
            cBorrowed.repayBorrow{value : balanceOfEth()}();
            emit Debug("_adjust bal eth after", balanceOfEth());
        }
    }

    // sell profits earned from delegated vault
    function sellProfits() internal {
        uint256 _debt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        emit Debug("sell _debt", _debt);
        emit Debug("sell _totalAssets", _totalAssets);

        if (_totalAssets > _debt) {
            uint256 _amountProfitInWant = _totalAssets.sub(_debt);
            uint256 _amountInBorrowed = estimateAmountUsdInUnderlying(estimateAmountUnderlyingInUsd(_amountProfitInWant, cWant), cBorrowed);
            uint256 _amountInShares = estimateAmountBorrowedInShares(_amountInBorrowed);
            emit Debug("sell _amountInShares", _amountInShares);

            if (_amountInShares > delegatedVault.balanceOf(address(this))) {
                // max uint256 is uniquely set to withdraw everything
                _amountInShares = uint256(- 1);
            }
            uint256 _actualWithdrawn = delegatedVault.withdraw(_amountInShares);
            emit Debug("sell _actualWithdrawn", _actualWithdrawn);
            // sell to want
            if (_actualWithdrawn > 0) {
                router.swapExactTokensForTokens(_actualWithdrawn, 0, path, address(this), now);
            }
        }
    }

    // Loose want
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfReward() public view returns (uint256){
        return reward.balanceOf(address(this));
    }

    function balanceOfEth() public view returns (uint256){
        return address(this).balance;
    }

    function balanceOfUnderlying(CTokenInterface cToken) public view returns (uint256){
        return estimateAmountCTokenInUnderlying(cToken.balanceOf(address(this)), cToken);
    }

    // Value of deposited want in USD
    function valueOfCWant() public view returns (uint256){
        return estimateAmountUnderlyingInUsd(balanceOfUnderlying(cWant), cWant);
    }

    // Value of Inverse supplied tokens in USD
    function valueOfCSupplied() public view returns (uint256){
        return estimateAmountUnderlyingInUsd(balanceOfUnderlying(cSupplied), cSupplied);
    }

    // Value of reward tokens in USD
    function valueOfxInv() public view returns (uint256){
        return estimateAmountUnderlyingInUsd(balanceOfUnderlying(xInv), xInv);
    }

    function valueOfTotalCollateral() public view returns (uint256){
        return valueOfCWant().add(valueOfCSupplied()).add(valueOfxInv());
    }

    // Value of borrowed tokens in USD
    function valueOfBorrowedOwed() public view returns (uint256){
        return estimateAmountUnderlyingInUsd(cBorrowed.borrowBalanceStored(address(this)), cBorrowed);
    }

    // Value of delegated vault deposits in USD
    function valueOfDelegated() public view returns (uint256){
        uint256 _amountInBorrowed = delegatedVault.balanceOf(address(this)).mul(delegatedVault.pricePerShare()).div(10 ** delegatedVault.decimals());
        return estimateAmountUnderlyingInUsd(_amountInBorrowed, cBorrowed);
    }

    function estimateAmountUnderlyingInUsd(uint256 _amountUnderlying, CTokenInterface cToken) public view returns (uint256){
        uint256 _usdPerUnderlying = comptroller.oracle().getUnderlyingPrice(address(cToken));
        return _amountUnderlying.mul(_usdPerUnderlying).div(1 ether);
    }

    function estimateAmountUsdInUnderlying(uint256 _amountInUsd, CTokenInterface cToken) public view returns (uint256){
        uint256 _usdPerUnderlying = comptroller.oracle().getUnderlyingPrice(address(cToken));
        return _amountInUsd.mul(1 ether).div(_usdPerUnderlying);
    }

    function estimateAmountBorrowedInShares(uint256 _amountBorrowed) public view returns (uint256){
        uint256 _borrowedPerShare = delegatedVault.pricePerShare();
        return _amountBorrowed.mul(10 ** delegatedVault.decimals()).div(_borrowedPerShare);
    }

    function estimateAmountCTokenInUnderlying(uint256 _amountCToken, CTokenInterface cToken) public view returns (uint256){
        uint256 _underlyingPerCToken = cToken.exchangeRateStored();
        return _amountCToken.mul(_underlyingPerCToken).div(1 ether);
    }

    function estimateAmountUnderlyingInCToken(uint256 _amountUnderlying, CTokenInterface cToken) public view returns (uint256){
        uint256 _underlyingPerCToken = cToken.exchangeRateStored();
        return _amountUnderlying.mul(1 ether).div(_underlyingPerCToken);
    }

    // mantissa
    function currentCollateralFactor() internal view returns (uint256){
        return valueOfBorrowedOwed().mul(1 ether).div(valueOfTotalCollateral());
    }

    // used after a migration to redeem escrowed INV tokens that can then be swept by gov
    function withdrawEscrowedRewards() external onlyAuthorized {
        TimelockEscrowInterface _timelockEscrow = TimelockEscrowInterface(xInv.escrow());
        _timelockEscrow.withdraw();
    }


    //
    // Setters
    //

    function setComptroller(address _newComptroller) external onlyAuthorized {
        comptroller = ComptrollerInterface(address(_newComptroller));
    }

    function setTargetCollateralFactor(uint256 _targetMantissa) external onlyAuthorized {
        (, uint256 _safeCollateralFactor,) = comptroller.markets(address(cWant));
        require(_targetMantissa.add(collateralTolerance) < _safeCollateralFactor, "target collateral factor too high!!");
        require(_targetMantissa > collateralTolerance, "target collateral factor too low!!");

        targetCollateralFactor = _targetMantissa;
        rebalance(0);
    }

    function setRouter(address _address) external onlyGovernance {
        router = IUniswapV2Router02(_address);
    }

    function setCollateralTolerance(uint256 _toleranceMantissa) external onlyGovernance {
        collateralTolerance = _toleranceMantissa;
    }

    function setInvDelegate(address _address) external onlyGovernance {
        xInv.delegate(_address);
    }

    function setBorrowLimit(uint256 _borrowLimit) external onlyAuthorized {
        borrowLimit = _borrowLimit;
    }

    //
    // For Inverse Finance
    //

    function setInverseGovernance(address _inverseGovernance) external onlyInverseGovernance {
        inverseGovernance = _inverseGovernance;
    }

    function setCSupplied(address _address) external onlyInverseGovernance {
        require(_address != address(cWant), "supplied market cannot be same as want");

        // comptroller.exitMarket(address(cSupplied));
        cSupplied = CErc20Interface(address(_address));

        claimableMarkets[2] = _address;
        comptroller.enterMarkets(claimableMarkets);
    }


    // @param _amount in cToken from the private marketa
    function supplyCollateral(uint256 _amount) external onlyInverseGovernance returns (bool){
        cSupplied.approve(inverseGovernance, uint256(- 1));
        cSupplied.approve(address(this), uint256(- 1));
        return cSupplied.transferFrom(inverseGovernance, address(this), _amount);
    }

    function removeCollateral(uint256 _amount) external onlyInverseGovernance {
        safeUnwindCTokenUnderlying(estimateAmountCTokenInUnderlying(_amount, cSupplied), cSupplied, false);
        cSupplied.transfer(msg.sender, _amount);
    }
}
