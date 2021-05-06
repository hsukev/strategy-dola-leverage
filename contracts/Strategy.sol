// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams, VaultAPI} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../interfaces/inverse.sol";
import "../interfaces/uniswap.sol";


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
    CErc20Interface public cBorrowed;
    CErc20Interface public cSupplied; // private market for Yearn
    CErc20Interface public cReward;
    IERC20 public borrowed;
    IERC20 public reward;
    IERC20 constant public weth = IERC20(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    address[] public path;
    address[] public wethWantPath;
    address public inverseGovernance;
    uint256 public targetCollateralFactor;
    uint256 public collateralTolerance;
    uint256 public blocksToLiquidationDangerZone = uint256(7 days) / 13; // assuming 13 second block times
    uint256 public rewardEscrowPeriod = 14 days;


    constructor(address _vault, address _cWant, address _cBorrowed, address _reward, address _delegatedVault) public BaseStrategy(_vault) {
        delegatedVault = VaultAPI(_delegatedVault);
        router = IUniswapV2Router02(address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
        comptroller = ComptrollerInterface(address(0x4dCf7407AE5C07f8681e1659f626E114A7667339));

        cWant = CErc20Interface(_cWant);
        cBorrowed = CErc20Interface(_cBorrowed);
        borrowed = IERC20(delegatedVault.token());
        reward = IERC20(_reward);

        require(cWant.underlying() != address(borrowed), "can't be delegating to your own vault");
        require(cWant.underlying() == address(want), "cWant does not match want");
        require(cBorrowed.underlying() == address(borrowed), "cBorrowed does not match delegated vault token");

        path = [delegatedVault.token(), address(want)];
        wethWantPath = [address(weth), address(want)];

        address[] memory _markets = new address[](2);
        _markets[0] = address(cWant);
        _markets[1] = address(cBorrowed);
        comptroller.enterMarkets(_markets);

        collateralTolerance = 0.01 ether;

        want.safeApprove(address(cWant), uint256(- 1));
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
        return balanceOfWant().add(estimateAmountUsdInUnderlying(valueOfCWant().add(valueOfDelegated()).sub(valueOfBorrowed()), cWant));
    }

    function ethToWant(uint256 _amtInWei) public view returns (uint256){
        uint256 amountOut = 0;
        if (_amtInWei > 0) {
            amountOut = router.getAmountsOut(_amtInWei, wethWantPath)[1];
        }
        return amountOut;
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        uint256 _debt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        if (_totalAssets > _debt) {
            uint256 _unwindAmountInWant = _totalAssets.sub(_debt).sub(balanceOfWant());

            sellProfits(_unwindAmountInWant);
            uint256 _balanceWithProfit = balanceOfWant();

            _debtPayment = _debtOutstanding;
            _loss = 0;
            if (_balanceWithProfit > _debtOutstanding) {
                _profit = _balanceWithProfit.sub(_debtOutstanding);
            } else {
                _profit = 0;
            }
        } else {
            _loss = _debt.sub(_totalAssets);
            _profit = 0;
            _debtPayment = 0;
        }

        // just claim but don't sell
        comptroller.claimComp(address(this));
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        cWant.mint(balanceOfWant());
        cReward.mint(balanceOfReward());

        rebalance(0);
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }

        safeUnwindCTokenUnderlying(_liquidatedAmount, cWant, true);
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

        uint256 borrowBalance = valueOfBorrowed();
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
        uint256 _amountUnderlyingInUsd = estimateAmountUnderlyingInUsd(_amountUnderlying, _cToken);

        rebalance(_amountUnderlyingInUsd);

        if (redeem) {
            _cToken.redeemUnderlying(_amountUnderlying);
        }
    }

    // Calculate adjustments on borrowing market to maintain targetCollateralFactor
    // @param _amountPendingWithdrawInUsd should be left out of adjustment
    function calculateAdjustmentInUsd(uint256 _amountPendingWithdrawInUsd) internal returns (int256 adjustmentUsd){
        uint256 _valueCollaterals = valueOfCWant().add(valueOfCSupplied()).add(valueOfCReward()).sub(_amountPendingWithdrawInUsd);
        return int256(_valueCollaterals.mul(targetCollateralFactor).div(1 ether) - valueOfBorrowed());
    }

    // Rebalances supply/borrow to maintain targetCollaterFactor
    // @param _pendingWithdrawInUsd = collateral that needs to be freed up after rebalancing
    function rebalance(uint256 _pendingWithdrawInUsd) public onlyKeepers {
        int256 _adjustmentInUsd = calculateAdjustmentInUsd(_pendingWithdrawInUsd);

        if (_adjustmentInUsd > 0) {
            // overcollateralized, can borrow more
            uint256 _adjustmentInBorrowed = estimateAmountUsdInUnderlying(uint256(_adjustmentInUsd), cBorrowed);
            uint _actualBorrowed = cBorrowed.borrow(_adjustmentInBorrowed);
            delegatedVault.deposit(_actualBorrowed);
        } else {
            // undercollateralized, must unwind and repay to free up collateral
            uint256 _adjustmentInBorrowed = estimateAmountUsdInUnderlying(uint256(- _adjustmentInUsd), cBorrowed);
            uint256 _adjustmentInShares = estimateAmountBorrowedInShares(_adjustmentInBorrowed);
            uint256 _amountBorrowedWithdrawn = delegatedVault.withdraw(_adjustmentInShares);
            cBorrowed.repayBorrow(_amountBorrowedWithdrawn);
        }
    }

    // sell profits earned from delegated vault
    function sellProfits(uint256 _amountInWant) internal {
        uint256 _amountInBorrowed = estimateAmountUnderlyingInUnderlying(_amountInWant, cWant, cBorrowed);
        uint256 _amountInShares = estimateAmountBorrowedInShares(_amountInBorrowed);
        uint256 _actualWithdrawn = delegatedVault.withdraw(_amountInShares);

        // sell to want
        router.swapExactTokensForTokens(_actualWithdrawn, uint256(0), path, address(this), now);
    }

    // Loose want
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfReward() public view returns (uint256){
        return reward.balanceOf(address(this));
    }

    // Value of deposited want in USD
    function valueOfCWant() public view returns (uint256){
        return estimateAmountUnderlyingInUsd(cWant.balanceOfUnderlying(address(this)), cWant);
    }

    // Value of Inverse supplied tokens in USD
    function valueOfCSupplied() public view returns (uint256){
        return estimateAmountUnderlyingInUsd(cSupplied.balanceOfUnderlying(address(this)), cSupplied);
    }

    // Value of reward tokens in USD
    function valueOfCReward() public view returns (uint256){
        return estimateAmountUnderlyingInUsd(cReward.balanceOfUnderlying(address(this)), cReward);
    }

    function valueOfTotalCollateral() public view returns (uint256){
        return valueOfCWant().add(valueOfCSupplied()).add(valueOfCReward());
    }

    // Value of borrowed tokens in USD
    function valueOfBorrowed() public view returns (uint256){
        return estimateAmountUnderlyingInUsd(cBorrowed.borrowBalanceCurrent(address(this)), cBorrowed);
    }

    // Value of delegated vault deposits in USD
    function valueOfDelegated() public view returns (uint256){
        uint256 _amountInBorrowed = delegatedVault.balanceOf(address(this)).mul(delegatedVault.pricePerShare()).div(delegatedVault.decimals());
        return estimateAmountUnderlyingInUsd(_amountInBorrowed, cBorrowed);
    }

    function estimateAmountUnderlyingInUnderlying(uint256 _amount, CErc20Interface _fromCToken, CErc20Interface _toCToken) public view returns (uint256){
        return estimateAmountUsdInUnderlying(estimateAmountUnderlyingInUsd(_amount, _fromCToken), _toCToken);
    }

    function estimateAmountUnderlyingInUsd(uint256 _amountUnderlying, CErc20Interface cToken) public view returns (uint256){
        uint256 _usdPerUnderlying = comptroller.oracle().getUnderlyingPrice(address(cToken));
        return _amountUnderlying.mul(_usdPerUnderlying).div(1 ether);
    }

    function estimateAmountUsdInUnderlying(uint256 _amountInUsd, CErc20Interface cToken) public view returns (uint256){
        uint256 _usdPerUnderlying = comptroller.oracle().getUnderlyingPrice(address(cReward));
        return _amountInUsd.mul(1 ether).div(_usdPerUnderlying);
    }

    function estimateAmountBorrowedInShares(uint256 _amountBorrowed) public view returns (uint256){
        uint256 _borrowedPerShare = delegatedVault.pricePerShare();
        return _amountBorrowed.mul(delegatedVault.decimals()).div(_borrowedPerShare);
    }

    function estimateAmountCTokenInUnderlying(uint256 _amountCToken, CErc20Interface cToken) public view returns (uint256){
        uint256 _underlyingPerCToken = cToken.exchangeRateCurrent();
        return _amountCToken.mul(_underlyingPerCToken).div(1 ether);
    }

    // mantissa
    function currentCollateralFactor() internal view returns (uint256){
        return valueOfBorrowed().mul(1 ether).div(valueOfTotalCollateral());
    }

    // unwind reward so it can be delegated for voting or sent to yearn gov
    function delegateRewardsTo(address _address) external onlyGovernance {
        // TODO: fix to correct start of escrow
        require(now.sub(0) > rewardEscrowPeriod, "Rewards are still in escrow!");

        safeUnwindCTokenUnderlying(cReward.balanceOfUnderlying(address(this)), cReward, true);
        balanceOfReward();
        // TODO delegate or transfer? Not sure how vote delgation works
    }


    //
    // Setters
    //

    function setComptroller(address _newComptroller) external onlyAuthorized {
        comptroller = ComptrollerInterface(address(_newComptroller));
    }

    // Provide flexibility to switch borrow market in the future
    function setCBorrowed(address _address, address _tokenVault) external onlyAuthorized {
        comptroller.exitMarket(address(cBorrowed));
        cBorrowed = CErc20Interface(_address);

        address[] memory _markets = new address[](1);
        _markets[0] = _address;
        comptroller.enterMarkets(_markets);
    }

    function setRewardToken(address _reward) external onlyAuthorized {
        reward = IERC20(_reward);
    }

    function setTargetCollateralFactor(uint256 _targetMantissa) external onlyAuthorized {
        (, uint256 _safeCollateralFactor,) = comptroller.markets(address(cWant));
        require(_targetMantissa.add(collateralTolerance) < _safeCollateralFactor, "target collateral factor too high!!");
        require(_targetMantissa > collateralTolerance, "target collateral factor too low!!");

        targetCollateralFactor = _targetMantissa;
        rebalance(0);
    }

    function setInverseGovernance(address _inverseGovernance) external onlyGovernance {
        inverseGovernance = _inverseGovernance;
    }

    function setRouter(address _router) external onlyGovernance {
        router = IUniswapV2Router02(address(_router));
    }

    function setCollateralTolerance(uint256 _toleranceMantissa) external onlyGovernance {
        collateralTolerance = _toleranceMantissa;
    }
    //
    // For Inverse Finance
    //

    function setCSupplied(address _address) external onlyInverseGovernance {
        require(_address != address(cWant), "supplied market cannot be same as want");

        comptroller.exitMarket(address(cSupplied));
        cSupplied = CErc20Interface(address(_address));

        address[] memory _markets = new address[](1);
        _markets[0] = _address;
        comptroller.enterMarkets(_markets);
    }

    function supplyCollateral(uint256 _amount) external onlyInverseGovernance {
        cSupplied.transferFrom(msg.sender, address(this), _amount);
    }

    function removeCollateral(uint256 _amount) external onlyInverseGovernance {
        safeUnwindCTokenUnderlying(estimateAmountCTokenInUnderlying(_amount, cSupplied), cSupplied, false);
        cSupplied.transfer(msg.sender, _amount);
    }
}
