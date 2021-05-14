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

    IUniswapV2Router02 public router;
    VaultAPI public delegatedVault;
    ComptrollerInterface public comptroller;
    CErc20Interface public cWant;
    CEther public cBorrowed;
    CErc20Interface public cSupplied; // private market for Yearn
    CErc20Interface public cReward;
    IERC20 public borrowed;
    IERC20 public reward;
    IWETH9 constant public weth = IWETH9(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    address[] public path;
    address[] public wethWantPath;
    address public inverseGovernance;
    uint256 public targetCollateralFactor;
    uint256 public collateralTolerance;
    uint256 public blocksToLiquidationDangerZone = uint256(7 days) / 13; // assuming 13 second block times
    uint256 public rewardEscrowPeriod = 14 days;


    constructor(address _vault, address _cWant, address _cBorrowed, address _cReward, address _delegatedVault) public BaseStrategy(_vault) {
        delegatedVault = VaultAPI(_delegatedVault);
        router = IUniswapV2Router02(address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
        comptroller = ComptrollerInterface(address(0x4dCf7407AE5C07f8681e1659f626E114A7667339));
        inverseGovernance = 0x35d9f4953748b318f18c30634bA299b237eeDfff;
        // TODO temporarily GovernorAlpha
        cSupplied = CErc20Interface(0xD60B06B457bFf7fc38AC5E7eCE2b5ad16B288326);
        // TODO temporarily Sushibar

        cWant = CErc20Interface(_cWant);
        cBorrowed = CEther(_cBorrowed);
        cReward = CErc20Interface(_cReward);

        // TODO remove after testing, or when private market is out
        borrowed = IERC20(delegatedVault.token());
        reward = IERC20(cReward.underlying());

        require(cWant.underlying() != address(borrowed), "can't be delegating to your own vault");
        require(cWant.underlying() == address(want), "cWant does not match want");
        // TODO cETH uses a unique interface that does not have an underlying() fx
        //        require(cBorrowed.underlying() == address(borrowed), "cBorrowed does not match delegated vault token");
        //

        require(address(cWant) != address(cBorrowed), "want and borrowed markets can't be the same");
        require(address(cWant) != address(cSupplied), "want and supplied markets can't be the same");
        require(address(cWant) != address(cReward), "want and reward markets can't be the same");
        require(address(cBorrowed) != address(cSupplied), "borrowed and supplied markets can't be the same");
        require(address(cBorrowed) != address(cReward), "borrowed and reward markets can't be the same");
        require(address(cSupplied) != address(cReward), "supplied and reward markets can't be the same");

        path = [delegatedVault.token(), address(want)];
        wethWantPath = [address(weth), address(want)];

        address[] memory _markets = new address[](3);
        _markets[0] = address(cWant);
        _markets[1] = address(cBorrowed);
        _markets[2] = address(cSupplied);
        comptroller.enterMarkets(_markets);

        targetCollateralFactor = 0.5 ether;
        // 50%
        collateralTolerance = 0.01 ether;

        want.safeApprove(address(cWant), uint256(- 1));
        borrowed.safeApprove(address(delegatedVault), uint256(- 1));
        weth.approve(address(this), uint256(- 1));
        weth.approve(address(router), uint256(- 1));
    }


    //
    // BaseContract overrides
    //

    function name() external view override returns (string memory) {
        return "StrategyInverseDolaLeverage";
        // return string(abi.encodePacked("StrategyInverse", IERC20Metadata(address(want)).symbol(), "Leverage"));
    }

    // Delegated assets in want
    function delegatedAssets() external override view returns (uint256) {
        return estimateAmountUsdInUnderlying(valueOfDelegated(), cWant);
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

        // just claim but don't sell
        comptroller.claimComp(address(this));
        emit Debug("_balanceOfReward", balanceOfReward());

    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        assert(cWant.mint(balanceOfWant()) == 0);
        assert(cReward.mint(balanceOfReward()) == 0);

        rebalance(0);
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 looseBalance = balanceOfWant();
        if (_amountNeeded > looseBalance) {

            uint256 _desiredWithdraw = _amountNeeded.sub(looseBalance);
            safeUnwindCTokenUnderlying(_desiredWithdraw, cWant, true);
            uint256 newLooseBalance = balanceOfWant();
            emit Debug("_liquidatePosition newLooseBalance", newLooseBalance);

            _liquidatedAmount = newLooseBalance;
            if (_amountNeeded > newLooseBalance) {

                _loss = _amountNeeded.sub(newLooseBalance);
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
    }

    function prepareMigration(address _newStrategy) internal override {
        // borrowed position can't be transferred so needs to unwind everything and pay it off before migrating
        liquidatePosition(estimatedTotalAssets());

        reward.transfer(_newStrategy, balanceOfReward());
        borrowed.transfer(_newStrategy, borrowed.balanceOf(address(this)));
        delegatedVault.transfer(_newStrategy, delegatedVault.balanceOf(address(this)));

        cWant.transfer(_newStrategy, cWant.balanceOf(address(this)));
        cReward.transfer(_newStrategy, cReward.balanceOf(address(this)));
        cSupplied.transfer(_newStrategy, cSupplied.balanceOf(address(this)));
    }

    function protectedTokens() internal view override returns (address[] memory){
        address[] memory protected = new address[](6);
        protected[0] = address(reward);
        protected[1] = address(borrowed);
        protected[2] = address(delegatedVault);
        protected[3] = address(cWant);
        protected[4] = address(cReward);
        protected[5] = address(cSupplied);
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

        uint256 supplyRate3 = cReward.supplyRatePerBlock();
        uint256 collateralisedDeposit3 = valueOfCReward().mul(collateralFactorMantissa).div(1e18);

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

    // free up _amountUnderlying worth of borrowed while maintaining targetCollateralRatio
    // @param redeem: True will redeem to cToken.underlying. False will remain as cToken
    function safeUnwindCTokenUnderlying(uint256 _amountUnderlying, CErc20Interface _cToken, bool redeem) internal {
        emit Debug("_safeUnwindCTokenUnderlying");

        uint256 _amountUnderlyingInUsd = estimateAmountUnderlyingInUsd(_amountUnderlying, _cToken);

        rebalance(_amountUnderlyingInUsd);

        if (redeem) {
            uint256 _valueCollatToMaintain = valueOfBorrowedOwed().mul(1 ether).div(targetCollateralFactor);
            uint256 _valueCollatRedeemable = valueOfTotalCollateral().sub(_valueCollatToMaintain);
            uint256 _valueUnderlyingAvailable = estimateAmountCurrentCTokenInUnderlying(_cToken.balanceOf(address(this)), _cToken);
            uint256 _valueUnderlyingRedeemable = Math.min(_valueCollatRedeemable, _valueUnderlyingAvailable);
            emit Debug("calculateAdjustment _amountCRedeemable", uint256(_valueUnderlyingRedeemable));
            uint256 error = _cToken.redeemUnderlying(_valueUnderlyingRedeemable);
            emit Debug("calculateAdjustment error", uint256(error));
            require(error == 0, "error redeeming");
            uint256 _want = balanceOfWant();
            emit Debug("calculateAdjustment _want", uint256(_want));
        }
    }

    // Calculate adjustments on borrowing market to maintain targetCollateralFactor
    // @param _amountPendingWithdrawInUsd should be left out of adjustment
    function calculateAdjustmentInUsd(uint256 _amountPendingWithdrawInUsd) internal returns (int256 adjustmentUsd){
        int256 _valueCollaterals = int256(valueOfTotalCollateral()) - int256(_amountPendingWithdrawInUsd);
        return _valueCollaterals * int256(targetCollateralFactor) / 1e18 - int256(valueOfBorrowedOwed());
    }

    function testRedeem(uint256 _amount) public returns (uint256){
        return cWant.redeemUnderlying(_amount);
    }

    // Rebalances supply/borrow to maintain targetCollaterFactor
    // @param _pendingWithdrawInUsd = collateral that needs to be freed up after rebalancing
    function rebalance(uint256 _pendingWithdrawInUsd) internal {
        emit Debug("rebalance _pendingWithdrawInUsd", uint256(_pendingWithdrawInUsd));
        int256 _adjustmentInUsd = calculateAdjustmentInUsd(_pendingWithdrawInUsd);
        emit Debug("rebalance _adjustmentInUsd", int256(_adjustmentInUsd));

        if (_adjustmentInUsd > 0) {
            // overcollateralized, can borrow more
            uint256 _adjustmentInBorrowed = estimateAmountUsdInUnderlying(uint256(_adjustmentInUsd), cBorrowed);
            emit Debug("rebalance _adjustmentInBorrowed", uint256(_adjustmentInBorrowed));

            assert(cBorrowed.borrow(_adjustmentInBorrowed) == 0);
            uint256 _actualBorrowed = address(this).balance;

            // wrap ether
            weth.deposit{value : _actualBorrowed}();
            uint256 _wethBalanace = weth.balanceOf(address(this));
            emit Debug("rebalance _actualBorrowed", uint256(_wethBalanace));

            delegatedVault.deposit(_wethBalanace);
        } else if (_adjustmentInUsd < 0) {
            emit Debug("_adjust negative");

            // undercollateralized, must unwind and repay to free up collateral
            uint256 _adjustmentInBorrowed = estimateAmountUsdInUnderlying(uint256(- _adjustmentInUsd), cBorrowed);
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
            uint256 _actualWithdrawn = delegatedVault.withdraw(_amountInShares);

            // sell to want
            if (_actualWithdrawn > 0) {
                router.swapExactTokensForTokens(_actualWithdrawn, uint256(0), path, address(this), now);
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

    function balanceOfUnderlying(CErc20Interface cToken) public view returns (uint256){
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
    function valueOfCReward() public view returns (uint256){
        return estimateAmountUnderlyingInUsd(balanceOfUnderlying(cReward), cReward);
    }

    function valueOfTotalCollateral() public view returns (uint256){
        return valueOfCWant().add(valueOfCSupplied()).add(valueOfCReward());
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

    function estimateAmountCurrentCTokenInUnderlying(uint256 _amountCToken, CTokenInterface cToken) private returns (uint256){
        uint256 _underlyingPerCToken = cToken.exchangeRateCurrent();
        return _amountCToken.mul(_underlyingPerCToken).div(1 ether);
    }

    function estimateAmountUnderlyingInCToken(uint256 _amountUnderlying, CTokenInterface cToken) public view returns (uint256){
        uint256 _underlyingPerCToken = cToken.exchangeRateStored();
        return _amountUnderlying.mul(1 ether).div(_underlyingPerCToken);
    }

    function estimateAmountUnderlyingInCurrentCToken(uint256 _amountUnderlying, CTokenInterface cToken) private returns (uint256){
        uint256 _underlyingPerCToken = cToken.exchangeRateCurrent();
        return _amountUnderlying.mul(1 ether).div(_underlyingPerCToken);
    }

    // mantissa
    function currentCollateralFactor() internal view returns (uint256){
        return valueOfBorrowedOwed().mul(1 ether).div(valueOfTotalCollateral());
    }

    // unwind reward so it can be delegated for voting or sent to yearn gov
    function delegateRewardsTo(address _address) external onlyGovernance {
        // TODO: fix to correct start of escrow
        require(now.sub(0) > rewardEscrowPeriod, "Rewards are still in escrow!");

        safeUnwindCTokenUnderlying(balanceOfUnderlying(cReward), cReward, true);
        balanceOfReward();
        // TODO delegate or transfer? Not sure how vote delgation works
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

    function setRouter(address _uniswapV2Router) external onlyGovernance {
        router = IUniswapV2Router02(address(_uniswapV2Router));
    }

    function setCollateralTolerance(uint256 _toleranceMantissa) external onlyGovernance {
        collateralTolerance = _toleranceMantissa;
    }

    //
    // For Inverse Finance
    //

    function setInverseGovernance(address _inverseGovernance) external onlyInverseGovernance {
        inverseGovernance = _inverseGovernance;
    }

    function setCSupplied(address _address) external onlyInverseGovernance {
        require(_address != address(cWant), "supplied market cannot be same as want");

        //        comptroller.exitMarket(address(cSupplied));
        cSupplied = CErc20Interface(address(_address));

        address[] memory _markets = new address[](1);
        _markets[0] = _address;
        comptroller.enterMarkets(_markets);
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
