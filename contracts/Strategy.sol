// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams, VaultAPI} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";

import "../interfaces/inverse.sol";


contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    struct AccountBook {
        uint256 supply;
        uint256 externalSupply;
    }

    modifier onlyGuest() {
        require(msg.sender == guest, "!guest");
        _;
    }

    ComptrollerInterface public comptroller;
    CErc20Interface public suppliedToken;
    CErc20Interface public borrowedToken;
    AccountBook private account;
    VaultAPI public delegatedVault;
    CErc20Interface public rewardToken;

    address public guest;
    address[] private markets;

    constructor(address _vault, address _supplyToken, address _borrowToken, address _rewardToken, address _delegatedVault) public BaseStrategy(_vault) {
        suppliedToken = CErc20Interface(_supplyToken);
        borrowedToken = CErc20Interface(_borrowToken);
        rewardToken = CErc20Interface(_rewardToken);

        comptroller = ComptrollerInterface(address(0x4dCf7407AE5C07f8681e1659f626E114A7667339));
        delegatedVault = VaultAPI(_delegatedVault);

        markets = [address(suppliedToken), address(borrowedToken)];
        comptroller.enterMarkets(markets);

        account = AccountBook(0, 0);
        want.safeApprove(address(suppliedToken), uint256(- 1));
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyDolaLeverage";
    }

    // account for this when depositing to another vault
    function delegatedAssets() external override view returns (uint256) {
        return balanceOfDelegated();
    }


    function externalDeposit(uint256 _amount, address token) external {
        require(token == address(want), "wrong underlying token!");

        account = AccountBook(account.supply, account.externalSupply.add(_amount));
    }

    // TODO rough outline
    function burn(uint256 _amount) public onlyGuest {
        unwind(_amount);

        //        ERC20Burnable(want).burn(_amount);

        account = AccountBook(account.supply, account.externalSupply.sub(_amount));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        return balanceOfUnstaked().add(balanceOfDelegated());
    }

    function balanceOfUnstaked() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfDelegated() public view returns (uint256){
        return rewardToken.balanceOfUnderlying(address(delegatedVault));
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){

        uint256 _debt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        if (_totalAssets > _debt) {
            uint256 _unwindAmount = _totalAssets.sub(_debt).sub(balanceOfUnstaked());
            unwind(_unwindAmount);
            uint256 _harvestedProfit = balanceOfUnstaked();

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

    // unwind from delegated to dola
    function unwind(uint256 _amount) internal returns (uint256){
        // withdraw from yVault
        // TODO math here needs correct decimals and price conversion
        uint256 _amountInShares = _amount.div(delegatedVault.pricePerShare());
        uint256 _withdrawnAmount = delegatedVault.withdraw(_amountInShares, address(this));

        // repay borrowed YFI
        borrowedToken.repayBorrow(_withdrawnAmount);

        // redeem dola back
        return suppliedToken.redeemUnderlying(_amount);
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // deposit loose dola

        // rebalance borrow/supply
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

    function setComptroller(address _newComptroller) external onlyKeepers {
        comptroller = ComptrollerInterface(address(_newComptroller));
    }

    // Provide flexibility to switch borrow market in the future?
    function setBorrowToken(address _cToken, address _tokenVault) external onlyKeepers {
        comptroller.exitMarket(address(borrowedToken));

        address[] memory market;
        market[0] = _cToken;
        comptroller.enterMarkets(market);
    }

    function setGuest(address _guest) onlyGovernance external {
        guest = _guest;
    }

    function setRewardToken(address _rewardToken) onlyGovernance externalDeposit {
        rewardToken = _rewardToken;
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
}
