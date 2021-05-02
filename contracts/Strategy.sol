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
    IERC20 public borrowed;
    IERC20 public reward;

    address public inverseGovernance;
    uint256 public targetCollateralFactor;


    constructor(address _vault, address _cWant, address _cBorrowed, address _reward, address _delegatedVault) public BaseStrategy(_vault) {
        delegatedVault = VaultAPI(_delegatedVault);
        comptroller = ComptrollerInterface(0x4dCf7407AE5C07f8681e1659f626E114A7667339);

        cWant = CErc20Interface(_supplyToken);
        cBorrowed = CErc20Interface(_cBorrowed);
        borrowed = IERC20(delegatedVault.want());
        reward = IERC20(_reward);

        assert(cWant.underlying() == address(want), "cWant does not match want");
        assert(cBorrowed.underlying() == address(borrowed), "borrowed token does not match delegated vault");

        address[] memory markets = new address[](2);
        markets[0] = address(cWant);
        markets[1] = address(cBorrowed);
        comptroller.enterMarkets(markets);

        want.safeApprove(address(cWant), uint256(-1));
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
        return delegatedVault.balanceOf(address(this)).mul(delegatedVault.pricePerShare());
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 price = comptroller.oracle().getPrice(want);
        return balanceOfWant().add(valueOfCWant()).add(valueOfDelegated()).sub(valueOfBorrowed()).div(price);
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
        protected[0] = address(cWant);
        protected[1] = address(cBorrowed);
        protected[2] = address(reward);
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
        cBorrowed.repayBorrow(_withdrawnAmount);

        // redeem dola back
        return cWant.redeemUnderlying(_amount);
    }

    // _amountBorrowMore = overcollateralized, safe to borrow more
    // _amountRepay = undercollateralized, need to repay some borrowed
    function calculateBorrowAdjustment() internal returns (uint256 _amountBorrowMore, uint256 _amountRepay){
        // TODO need proper decimals
        uint256 valueBorrowed = valueOfBorrowed();
        uint256 valueSupplied = valueOfCSupplied();

        // TODO add supplied INV to valueSupplied as well

        // amount of borrowed token to adjust to maintain targetCollateralFactor
        uint256 priceBorrowed = comptroller.oracle().getPrice(borrowed);
        int256 delta = int256((valueSupplied.mul(targetCollateralFactor) - valueBorrowed).div(priceBorrowed));
        if (delta > 0) {
            return (uint256(delta), uint256(0));
        } else {
            return (uint256(0), uint256(- delta));
        }
    }

    // Loose want
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    // Value of loose want in USD
    function valueOfWant() public view returns (uint256) {
        uint256 price = comptroller.oracle().getPrice(want);
        return balanceOfWant().mul(price);
    }

    // Value of deposited want in USD
    function valueOfCWant() public view returns (uint256){
        uint256 price = comptroller.oracle().getUnderlyingPrice(cWant);
        return cWant.balanceOfUnderlying(address(this)).mul(price);
    }

    // Value of Inverse supplied tokens in USD
    function valueOfCSupplied() public view returns (uint256){
        uint256 price = comptroller.oracle().getUnderlyingPrice(cSupplied);
        return cSupplied.balanceOfUnderlying(address(this)).mul(price);
    }

    // Value of borrowed tokens in USD
    function valueOfBorrowed() public view returns (uint256){
        uint256 price = comptroller.oracle().getPrice(borrowed);
        return borrowed.balanceOf(address(this)).mul(price);
    }

    // Value of delegated vault deposits in USD
    function valueOfDelegated() public view returns (uint256){
        uint256 price = comptroller.oracle().getPrice(borrowed);
        delegatedVault.balanceOf(address(this)).mul(delegatedVault.pricePerShare()).mul(price);
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

        address[] memory markets = new address[](1);
        markets[0] = _address;
        comptroller.enterMarkets(market);
    }

    // TODO: do we want this felxibility?
    function setRewardToken(address _reward) external onlyAuthorized {
        reward = IERC20(_reward);
    }

    function setTargetCollateralFactor(uint256 _target) external onlyAuthorized {
        (, uint256 safeCollateralFactor,) = comptroller.markets(address(cWant));
        require(_target > safeCollateralFactor, "target collateral factor too low");

        targetCollateralFactor = _target;
        adjustPosition(0);
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

        address[] memory markets = new address[](1);
        markets[0] = _address;
        comptroller.enterMarkets(market);
    }

    function supplyCollateral(uint256 _amount) external onlyInverseGovernance {
        cSupplied.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function removeCollateral(uint256 _amount) external onlyInverseGovernance {
        // TODO: calculate amount to unwind to maintain collateral ratio, should be similar to adjust position
        // TODO: unwind from vault -> borrowed -> cWant

        cSupplied.safeTransfer(msg.sender, _amount);
    }
}
