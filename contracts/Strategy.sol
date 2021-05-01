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

    ComptrollerInterface public comptroller;
    CErc20Interface public suppliedToken;
    CErc20Interface public borrowedToken;
    CErc20Interface public privateMarket;
    VaultAPI public delegatedVault;
    CErc20Interface public rewardToken;
    ERC20 public stableToken;

    address public inverseGovernance;
    address[] private markets;
    uint256 public targetCollateralFactor;
    uint256 public inverseSuppliedWant;


    constructor(address _vault, address _supplyToken, address _borrowToken, address _rewardToken, address _delegatedVault) public BaseStrategy(_vault) {
        suppliedToken = CErc20Interface(_supplyToken);
        borrowedToken = CErc20Interface(_borrowToken);
        rewardToken = CErc20Interface(_rewardToken);

        comptroller = ComptrollerInterface(address(0x4dCf7407AE5C07f8681e1659f626E114A7667339));
        stableToken = ERC20(address(0x865377367054516e17014CcdED1e7d814EDC9ce4));
        delegatedVault = VaultAPI(_delegatedVault);

        markets = [address(suppliedToken), address(borrowedToken)];
        comptroller.enterMarkets(markets);

        want.safeApprove(address(suppliedToken), uint256(- 1));
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
        return balanceOfDelegated();
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        return balanceOfWant().add(valueOfDelegated(balanceOfDelegated()));
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        uint256 _debt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        if (_totalAssets > _debt) {
            uint256 _unwindAmount = _totalAssets.sub(_debt).sub(balanceOfWant());
            unwind(_unwindAmount);
            uint256 _harvestedProfit = balanceOfWant();

            _debtPayment = _debtOutstanding;
            _loss = 0;
            if (_harvestedProfit > _debtOutstanding) {
                _profit = _harvestedProfit.sub(_debtOutstanding);
            } else {
                _profit = 0;
            }
        } else {
            _loss = _debt.sub(_totalAssets);
            _profit = 0;
            _debtPayment = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO deposit loose want to mint more supply -> increase borrowed
        // TODO claim rewards here (INV), deposit to xINV -> increase borrowed

        (uint256 _amountBorrowMore, uint256 _amountRepay) = calculateBorrowAdjustment();
        if (_amountRepay > 0) {
            // unwind from yVault and repay
        } else {
            // borrow more
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens() internal view override returns (address[] memory){
        address[] memory protected = new address[](2);
        protected[0] = address(suppliedToken);
        protected[1] = address(borrowedToken);
        protected[2] = address(rewardToken);
        return protected;
    }


    //
    // Helpers
    //

    // unwind from delegated to dola
    function unwind(uint256 _amount) internal returns (uint256){
        // withdraw from yVault
        // TODO math here needs correct decimals and price conversion
        uint256 _amountInShares = _amount.div(delegatedVault.pricePerShare());
        uint256 _withdrawnAmount = delegatedVault.withdraw(_amountInShares, address(this));

        // repay borrowed
        borrowedToken.repayBorrow(_withdrawnAmount);

        // redeem dola back
        return suppliedToken.redeemUnderlying(_amount);
    }

    // _amountBorrowMore = overcollateralized, safe to borrow more
    // _amountRepay = undercollateralized, need to repay some borrowed
    function calculateBorrowAdjustment() internal returns (uint256 _amountBorrowMore, uint256 _amountRepay){
        // TODO need proper decimals
        (,, uint256 borrowedBal,) = borrowedToken.getAccountSnapshot(address(this));
        uint256 priceBorrowed = comptroller.oracle().getUnderlyingPrice(address(borrowedToken));
        uint256 valueBorrowed = borrowedBal.mul(priceBorrowed);

        (, uint256 suppliedCTokenBal, , uint256 supplyExchangeRate) = suppliedToken.getAccountSnapshot(address(this));
        uint256 priceSupplied = comptroller.oracle().getUnderlyingPrice(address(suppliedToken));
        uint256 valueSupplied = suppliedCTokenBal.mul(supplyExchangeRate).mul(priceSupplied);

        // TODO add supplied INV to valueSupplied as well

        // amount of borrowed token to adjust to maintain targetCollateralFactor
        int256 delta = int256((valueSupplied.mul(targetCollateralFactor) - valueBorrowed).div(priceBorrowed));
        if (delta > 0) {
            return (uint256(delta), uint256(0));
        } else {
            return (uint256(0), uint256(- delta));
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfDelegated() public view returns (uint256){
        // TODO is this how..?
        return delegatedVault.balanceOf(address(this)).mul(delegatedVault.pricePerShare());
    }

    // valued in terms of want
    function valueOfDelegated(uint256 _amount) public view returns (uint256){
        return 0;
    }

    //
    // Setters
    //

    function setComptroller(address _newComptroller) external onlyAuthorized {
        comptroller = ComptrollerInterface(address(_newComptroller));
    }

    // Provide flexibility to switch borrow market in the future
    function setBorrowToken(address _cToken, address _tokenVault) external onlyAuthorized {
        comptroller.exitMarket(address(borrowedToken));

        address[] memory market;
        market[0] = _cToken;
        comptroller.enterMarkets(market);
    }

    function setInverseGovernance(address _inverseGovernance) external onlyAuthorized {
        inverseGovernance = _inverseGovernance;
    }

    function setRewardToken(address _rewardToken) external onlyAuthorized {
        rewardToken = CErc20Interface(_rewardToken);
    }

    function setTargetCollateralFactor(uint256 _target) external onlyAuthorized {
        (, uint256 safeCollateralFactor,) = comptroller.markets(address(suppliedToken));
        require(_target > safeCollateralFactor, "target collateral factor too low");

        targetCollateralFactor = _target;
        adjustPosition(0);
    }

    //
    // For Inverse Finance
    //
    function setPrivateMarket(address _address) external onlyInverseGovernance {
        privateMarket = CErc20Interface(address(_address));
    }

    function setStableToken(address _address) external onlyInverseGovernance {
        stableToken = ERC20(address(_address));
    }

    function mintStable(uint256 _amount) external onlyInverseGovernance {
        //TODO internal method...not sure how to mint yet
        //        stableToken._mint(address(this), _amount);
        inverseSuppliedWant += _amount;
    }

    function burnStable(uint256 _amount) external onlyInverseGovernance {
        require(_amount <= inverseSuppliedWant, "insufficient supply");

        uint256 unwoundAmount;
        if (_amount > balanceOfWant()) {
            unwoundAmount = unwind(_amount - balanceOfWant());
        }

        //TODO internal method...not sure how to burn yet
        //        stableToken._burn(address(this), unwoundAmount);
        inverseSuppliedWant -= _amount;
    }
}
