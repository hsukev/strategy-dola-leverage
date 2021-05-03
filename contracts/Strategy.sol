// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams, VaultAPI} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../interfaces/inverse.sol";


contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    modifier onlyInverseGovernance() {
        require(msg.sender == inverseGovernance, "!inverseGovernance");
        _;
    }

    VaultAPI public delegatedVault;
    ComptrollerInterface public comptroller;
    CErc20Interface public cWant;
    CErc20Interface public cBorrowed;
    CErc20Interface public cSupplied; // private market for Yearn
    CErc20Interface public cReward;
    IERC20 public borrowed;
    IERC20 public reward;

    address public inverseGovernance;
    uint256 public targetCollateralFactor;
    uint256 public rewardEscrowPeriod = 14 days; // 14 days in seconds

    constructor(address _vault, address _cWant, address _cBorrowed, address _reward, address _delegatedVault) public BaseStrategy(_vault) {
        delegatedVault = VaultAPI(_delegatedVault);
        comptroller = ComptrollerInterface(0x4dCf7407AE5C07f8681e1659f626E114A7667339);

        cWant = CErc20Interface(_cWant);
        cBorrowed = CErc20Interface(_cBorrowed);
        borrowed = IERC20(delegatedVault.token());
        reward = IERC20(_reward);

        require(cWant.underlying() == address(want), "cWant does not match want");
        require(cBorrowed.underlying() == address(borrowed), "cBorrowed does not match delegated vault token");

        address[] memory _markets = new address[](2);
        _markets[0] = address(cWant);
        _markets[1] = address(cBorrowed);
        comptroller.enterMarkets(_markets);

        want.safeApprove(address(cWant), uint256(- 1));
    }

    //
    // BaseContract overrides
    //

    function name() external view override returns (string memory) {
        return "StrategyInverseDolaLeverage";
        // return string(abi.encodePacked("StrategyInverse", IERC20Metadata(address(want)).symbol(), "Leverage"));
    }

    // account for this when depositing to another vault
    function delegatedAssets() external override view returns (uint256) {
        // don't include leveraged
        return 0;
    }

    // only include user deposited assets, exclude any leveraging
    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 _price = comptroller.oracle().getUnderlyingPrice(address(cWant));
        return balanceOfWant().add(valueOfCWant()).add(valueOfDelegated()).sub(valueOfBorrowed()).div(_price);
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        uint256 _debt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        if (_totalAssets > _debt) {
            uint256 _unwindAmount = _totalAssets.sub(_debt).sub(balanceOfWant());
            // TODO instead of unwinding all the way to cToken, profits need to just unwind to eth and sell for want
            // shallow unwind and sell function here
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

        // TODO harvest reward but don't sell
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

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

    function protectedTokens() internal view override returns (address[] memory){
        address[] memory protected = new address[](5);
        protected[0] = address(cWant);
        protected[1] = address(cSupplied);
        protected[2] = address(borrowed);
        protected[3] = address(reward);
        protected[4] = address(delegatedVault);
        return protected;
    }


    //
    // Helpers
    //

    // free up _amountUnderlying worth of borrowed while maintaining targetCollateralRatio
    // @param redeem: True will redeem to cToken.underlying. False will remain as cToken
    function safeUnwindCTokenUnderlying(uint256 _amountUnderlying, CErc20Interface _cToken, bool redeem) internal {
        uint256 _usdPerUnderlying = comptroller.oracle().getUnderlyingPrice(address(_cToken));
        uint256 _amountUnderlyingInUsd = _amountUnderlying.mul(_usdPerUnderlying).div(decimals(_cToken));

        rebalance(_amountUnderlyingInUsd);

        if (redeem) {
            _cToken.redeemUnderlying(_amountUnderlying);
        }
    }

    // free up _amountCToken worth of borrowed while maintaining targetCollateralRatio
    function safeUnwindCToken(uint256 _amountCToken, CErc20Interface _cToken) internal {
        uint256 _underlyingPerCToken = _cToken.exchangeRateCurrent();
        uint256 _amountUnderlying = _amountCToken.mul(_underlyingPerCToken).div(1 ** 16);
        safeUnwindCTokenUnderlying(_amountUnderlying, _cToken, false);
    }

    // Calculate adjustments on borrowing market to maintain targetCollateralFactor
    // @param _amountPendingWithdrawInUsd should be left out of adjustment
    function calculateAdjustmentInUsd(uint256 _amountPendingWithdrawInUsd) internal returns (int256 adjustmentUsd){
        uint256 _valueCollaterals = valueOfCWant().add(valueOfCSupplied()).add(valueOfCReward()).sub(_amountPendingWithdrawInUsd);
        return int256(_valueCollaterals.mul(targetCollateralFactor).div(1 ether) - valueOfBorrowed());
    }

    // Rebalances supply/borrow to maintain targetCollaterFactor
    // @param _pendingWithdrawInUsd = collateral that needs to be freed up after rebalancing
    function rebalance(uint256 _pendingWithdrawInUsd) internal {
        uint256 _usdPerBorrowed = comptroller.oracle().getUnderlyingPrice(address(cBorrowed));
        int256 _adjustmentInUsd = calculateAdjustmentInUsd(_pendingWithdrawInUsd);

        if (_adjustmentInUsd > 0) {
            // overcollateralized, can borrow more
            uint256 _adjustmentInBorrowed = uint256(_adjustmentInUsd).mul(decimals(borrowed).div(_usdPerBorrowed));
            uint _actualBorrowed = cBorrowed.borrow(_adjustmentInBorrowed);
            delegatedVault.deposit(_actualBorrowed);
        } else {
            // undercollateralized, must unwind and repay to free up collateral
            uint256 _borrowedPerVaultShare = delegatedVault.pricePerShare();
            uint256 _adjustmentInShares = uint256(- _adjustmentInUsd).mul(decimals(borrowed)).div(_usdPerBorrowed).mul(delegatedVault.decimals()).div(_borrowedPerVaultShare);
            uint256 _amountBorrowedWithdrawn = delegatedVault.withdraw(_adjustmentInShares);
            cBorrowed.repayBorrow(_amountBorrowedWithdrawn);
        }
    }

    // Loose want
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfReward() public view returns (uint256){
        return reward.balanceOf(address(this));
    }

    // Value of loose want in USD
    function valueOfWant() public view returns (uint256) {
        uint256 _price = comptroller.oracle().getUnderlyingPrice(address(cWant));
        return balanceOfWant().mul(_price).div(decimals(want));
    }

    // Value of deposited want in USD
    function valueOfCWant() public view returns (uint256){
        uint256 _price = comptroller.oracle().getUnderlyingPrice(address(cWant));
        return cWant.balanceOfUnderlying(address(this)).mul(_price).div(decimalsUnderlying(cWant));
    }

    // Value of Inverse supplied tokens in USD
    function valueOfCSupplied() public view returns (uint256){
        uint256 _price = comptroller.oracle().getUnderlyingPrice(address(cSupplied));
        return cSupplied.balanceOfUnderlying(address(this)).mul(_price).div(decimalsUnderlying(cSupplied));
    }

    // Value of reward tokens in USD
    function valueOfCReward() public view returns (uint256){
        uint256 _price = comptroller.oracle().getUnderlyingPrice(address(cReward));
        return cReward.balanceOfUnderlying(address(this)).mul(_price).div(decimalsUnderlying(cReward));
    }

    function valueOfTotalCollateral() public view returns (uint256){
        return valueOfCWant().add(valueOfCSupplied).add(valueOfCReward);
    }

    // Value of borrowed tokens in USD
    function valueOfBorrowed() public view returns (uint256){
        uint256 _price = comptroller.oracle().getUnderlyingPrice(address(cBorrowed));
        return cBorrowed.borrowBalanceCurrent(address(this)).mul(_price).div(decimals(borrowed));
    }

    // Value of delegated vault deposits in USD
    function valueOfDelegated() public view returns (uint256){
        uint256 _price = comptroller.oracle().getUnderlyingPrice(address(cBorrowed));
        return delegatedVault.balanceOf(address(this))
        .mul(delegatedVault.pricePerShare())
        .mul(_price)
        .div(delegatedVault.decimals())
        .div(decimals(borrowed));
    }

    function decimals(CErc20Interface cToken) returns (uint256){
        return cToken.decimals();
    }

    function decimalsUnderlying(CErc20Interface cToken) returns (uint256){
        return ERC20(cToken.underlying()).decimals();
    }

    function decimals(IERC20 cToken) returns (uint256){
        return ERC20(cToken).decimals();
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

    // TODO: do we want this felxibility?
    function setRewardToken(address _reward) external onlyAuthorized {
        reward = IERC20(_reward);
    }

    function setTargetCollateralFactor(uint256 _targetMantissa) external onlyAuthorized {
        (, uint256 _safeCollateralFactor,) = comptroller.markets(address(cWant));
        require(_targetMantissa > _safeCollateralFactor, "target collateral factor too high!!");

        targetCollateralFactor = _targetMantissa;
        rebalance(0);
    }

    function setInverseGovernance(address _inverseGovernance) external onlyGovernance {
        inverseGovernance = _inverseGovernance;
    }

    //
    // For Inverse Finance
    //

    function setCSupplied(address _address) external onlyInverseGovernance {
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
        safeUnwindCToken(_amount, cSupplied);
        cSupplied.transfer(msg.sender, _amount);
    }
}
