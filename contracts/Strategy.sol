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

    address public guest;
    address[] private markets;

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;

        // anDola to supply
        suppliedToken = CErc20Interface(address(0x7Fcb7DAC61eE35b3D4a51117A7c58D53f0a8a670));
        // anYFI
        borrowedToken = CErc20Interface(address(0xde2af899040536884e062D3a334F2dD36F34b4a4));
        comptroller = ComptrollerInterface(address(0x4dCf7407AE5C07f8681e1659f626E114A7667339));
        delegatedVault = VaultAPI(address(0xa9fE4601811213c340e850ea305481afF02f5b28));
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
        return 0;
    }

    function externalDeposit(uint256 _amount, address token) external {
        require(token == address(want), "wrong underlying token!");


        account = AccountBook(account.supply, account.externalSupply.add(_amount));
    }

    // TODO rough outline
    function burn(uint256 _amount) public onlyGuest {
        // withdraw from yVault
        // TODO math here needs correct decimals and price conversion
        uint256 _amountInShares = _amount.div(delegatedVault.pricePerShare());
        uint256 _withdrawnAmount = delegatedVault.withdraw(_amountInShares, address(this));

        // repay borrowed YFI
        borrowedToken.repayBorrow(_withdrawnAmount);

        // redeem dola back
        suppliedToken.redeemUnderlying(_amount);

//        ERC20Burnable(want).burn(_amount);

        account = AccountBook(account.supply, account.externalSupply.sub(_amount));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        return balanceOfUnstaked();
    }

    function balanceOfUnstaked() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        // not sure how this works with a delegated vault
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
        CTokenInterface newToken = CTokenInterface(address(_cToken));
        comptroller.exitMarket(address(borrowedToken));

        address[] memory market;
        market[0] = _cToken;
        comptroller.enterMarkets(market);
    }

    function setGuest(address _guest) onlyGovernance external {
        guest = _guest;
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
        return protected;
    }
}
