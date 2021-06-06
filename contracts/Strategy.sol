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

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);
}

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
    IWETH9 internal weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address[] public path;
    address[] public wethWantPath;
    address[] public wantWethPath;
    address[] public claimableMarkets;

    uint public minRedeemPrecision;
    address public inverseGovernance;
    uint256 public targetCollateralFactor;
    uint256 public collateralTolerance;
    uint256 public borrowLimit; // borrow nothing until set
    uint256 internal repaymentLowerBound = 0.01 ether; // threshold for paying off borrowed dust

    constructor(address _vault, address _cWant, address _cBorrowed, address _delegatedVault) public BaseStrategy(_vault) {
        // TODO temporarily GovernorAlpha
        inverseGovernance = 0x35d9f4953748b318f18c30634bA299b237eeDfff;

        delegatedVault = VaultAPI(_delegatedVault);
        router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        comptroller = ComptrollerInterface(0x4dCf7407AE5C07f8681e1659f626E114A7667339);

        cWant = CErc20Interface(_cWant);
        cBorrowed = CEther(_cBorrowed);
        xInv = xInvCoreInterface(0x65b35d6Eb7006e0e607BC54EB2dFD459923476fE);
        // TODO temporarily Sushibar
        cSupplied = CErc20Interface(0xD60B06B457bFf7fc38AC5E7eCE2b5ad16B288326);

        borrowed = IERC20(delegatedVault.token());
        reward = IERC20(0x41D5D79431A913C4aE7d69a668ecdfE5fF9DFB68);

        require(cWant.underlying() != address(borrowed));
        require(cWant.underlying() == address(want));
        require(address(cWant) != address(cBorrowed));
        require(address(cWant) != address(cSupplied));
        require(address(cWant) != address(xInv));
        require(address(cBorrowed) != address(cSupplied));
        require(address(cBorrowed) != address(xInv));
        require(address(cSupplied) != address(xInv));

        path = [delegatedVault.token(), address(want)];
        wethWantPath = [address(weth), address(want)];
        wantWethPath = [address(want), address(weth)];

        claimableMarkets = [address(cWant), address(cBorrowed), address(cSupplied)];
        comptroller.enterMarkets(claimableMarkets);
        // 50%
        targetCollateralFactor = 0.5 ether;
        // 1%
        collateralTolerance = 0.01 ether;

        want.safeApprove(address(cWant), type(uint256).max);
        want.safeApprove(address(router), type(uint256).max);
        borrowed.safeApprove(address(delegatedVault), type(uint256).max);
        weth.approve(address(this), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        reward.approve(address(xInv), type(uint256).max);

        minRedeemPrecision = 10 ** (vault.decimals() - cWant.decimals());

        // delegate voting power to yearn gov
        xInv.delegate(governance());
    }

    //
    // BaseContract overrides
    //

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("StrategyInverse", IERC20Metadata(address(want)).symbol(), "Leverage"));
    }

    // User portion of the delegated assets in want
    function delegatedAssets() external override view returns (uint256) {
        uint256 _totalCollateral = valueOfTotalCollateral();
        if (_totalCollateral == 0) {
            return 0;
        }

        uint256 _userDelegated = valueOfDelegated().mul(valueOfCWant()).div(_totalCollateral);
        return _usdToBase(_userDelegated, cWant);
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(_usdToBase(valueOfCWant().add(valueOfDelegated()).sub(valueOfBorrowedOwed()), cWant));
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        uint256 _looseBalance = balanceOfWant();

        _sellDelegatedProfits();
//        _sellLendingProfits();

        uint256 _balanceAfterProfit = balanceOfWant();
        if (_balanceAfterProfit > _looseBalance) {
            _profit = _balanceAfterProfit.sub(_looseBalance);
        }

        if (_debtOutstanding > 0) {
            uint256 _amountLiquidated;
            (_amountLiquidated, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_debtOutstanding, _amountLiquidated);
            if (_loss > 0) {
                _profit = 0;
            }
        }

        // claim (but don't sell) INV
        comptroller.claimComp(address(this), claimableMarkets);
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        assert(cWant.mint(balanceOfWant()) == NO_ERROR);
        assert(xInv.mint(balanceOfReward()) == NO_ERROR);

        _rebalance();
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 _looseBalance = balanceOfWant();
        if (_amountNeeded > _looseBalance) {
            _loss = redeem(_amountNeeded.sub(_looseBalance));
            _liquidatedAmount = Math.min(_amountNeeded, balanceOfWant());
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function tendTrigger(uint256 callCostInWei) public override virtual view returns (bool) {
        uint256 _valueCollateral = valueOfTotalCollateral();
        if (harvestTrigger(_ethToWant(callCostInWei)) || _valueCollateral == 0) {
            return false;
        }

        uint256 currentCF = valueOfBorrowedOwed().mul(1e18).div(_valueCollateral);
        return targetCollateralFactor.sub(collateralTolerance) > currentCF || currentCF > targetCollateralFactor.add(collateralTolerance);
    }

    function prepareMigration(address _newStrategy) internal override {
        // borrowed position can't be transferred so need to unwind everything before migrating
        liquidatePosition(type(uint256).max);

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

    // repay borrowed position to free up collateral.
    function freeUpCollateral(uint256 _usdNeeded) public {
        cBorrowed.accrueInterest();

        uint256 _usdTotalFree = usdCollatFree();
        if (_usdNeeded > _usdTotalFree) {
            uint256 _usdMoreNeeded = _usdNeeded.sub(_usdTotalFree);
            uint256 _borrowed = _usdToBase(_usdMoreNeeded, cBorrowed);
            uint256 _shares = Math.min(_borrowedToShares(_borrowed), delegatedVault.balanceOf(address(this)));

            uint256 _borrowedWithdrawn = delegatedVault.withdraw(_shares);

            weth.withdraw(_borrowedWithdrawn);
            cBorrowed.repayBorrow{value : balanceOfEth()}();

            _usdTotalFree = usdCollatFree();

            // if unwinding delegatedVault was not enough (delegatedVault pps lowered, or market interest), start trading want -> eth to free up collateral
            if (_usdNeeded > _usdTotalFree) {
//                uint256 _usdShort = _usdNeeded.sub(_usdTotalFree);
//                uint256 _usdLocked = valueOfBorrowedOwed().mul(1e18).div(targetCollateralFactor);
//                uint256 _usdNeededToRepay = Math.min(_usdLocked, _usdShort).mul(targetCollateralFactor).div(1e18);
//                router.getAmountsIn(_remainingRepayment, wantWethPath)[0]
            }
        }
    }

    function usdCollatFree() public returns (uint256 _usdFree){
        uint256 _usdCollatToMaintain = valueOfBorrowedOwed().mul(1e18).div(targetCollateralFactor);
        uint256 _usdTotalCollat = valueOfTotalCollateral();
        if (_usdTotalCollat > _usdCollatToMaintain) {
            _usdFree = _usdTotalCollat.sub(_usdCollatToMaintain);
        }
    }

    function redeem(uint256 _wantNeeded) public returns (uint256 _wantShort){
        freeUpCollateral(_baseToUsd(_wantNeeded, cWant));

        uint256 _wantAllowed = _usdToBase(usdCollatFree(), cWant);
        uint256 _wantCash = cWant.getCash();
        uint256 _wantHeld = balanceOfBase(cWant);

        uint256 _wantRedeemable = Math.min(Math.min(Math.min(_wantNeeded, _wantCash), _wantHeld), _wantAllowed);

        if (_wantRedeemable > minRedeemPrecision) {
            cWant.redeemUnderlying(_wantRedeemable) == NO_ERROR;
        }

        uint256 _wantAfter = balanceOfWant();
        if (_wantNeeded > _wantAfter) {
            _wantShort = _wantNeeded.sub(_wantAfter);
        }
    }


    // Calculate adjustments on borrowing market to maintain healthy targetCollateralFactor and borrowLimit
    function calculateAdjustmentInUsd() internal returns (uint256 _usdAdjustment, bool _neg){
        uint256 _usdTotalCollat = valueOfTotalCollateral();
        _usdTotalCollat = _usdTotalCollat > repaymentLowerBound ? _usdTotalCollat : 0;
        uint256 _usdBorrowTarget = _usdTotalCollat.mul(targetCollateralFactor).div(1e18);

        // enforce borrow limit
        uint256 _usdBorrowLimit = _baseToUsd(borrowLimit, cBorrowed);
        if (_usdBorrowTarget > _usdBorrowLimit) {
            _usdBorrowTarget = _usdBorrowLimit;
        }

        uint256 _usdBorrowOwed = valueOfBorrowedOwed();
        if (_usdBorrowOwed > _usdBorrowTarget) {
            _neg = true;
            _usdAdjustment = _usdBorrowOwed.sub(_usdBorrowTarget);
        } else {
            _usdAdjustment = _usdBorrowTarget.sub(_usdBorrowOwed);
        }
    }


    function _rebalance() internal {
        cBorrowed.accrueInterest();
        (uint256 _usdAdjustment, bool _neg) = calculateAdjustmentInUsd();
        if (_neg) {
            // undercollateralized, must unwind and repay to free up collateral
            freeUpCollateral(_usdAdjustment);
        } else if (_usdAdjustment > 0) {
            // overcollateralized, can borrow more
            uint256 _borrowedAdjustment = _usdToBase(_usdAdjustment, cBorrowed);
            assert(cBorrowed.borrow(_borrowedAdjustment) == NO_ERROR);
            uint256 _borrowedActual = address(this).balance;
            weth.deposit{value : _borrowedActual}();
            uint256 _wethBalance = weth.balanceOf(address(this));
            delegatedVault.deposit(_wethBalance);
        }
    }

    // sell profits earned from delegated vault
    function _sellDelegatedProfits() internal {
        cBorrowed.accrueInterest();
        uint256 _valueOfBorrowed = valueOfBorrowedOwed();
        uint256 _valueOfDelegated = valueOfDelegated();

        if (_valueOfDelegated > _valueOfBorrowed) {
            uint256 _valueOfProfit = _valueOfDelegated.sub(_valueOfBorrowed);
            uint256 _amountInShares = _borrowedToShares(_usdToBase(_valueOfProfit, cBorrowed));
            if (_amountInShares >= delegatedVault.balanceOf(address(this))) {
                // max uint256 is uniquely set to withdraw everything
                _amountInShares = type(uint256).max;
            }
            uint256 _actualWithdrawn = delegatedVault.withdraw(_amountInShares);
            // sell to want
            if (_actualWithdrawn > 0) {
                router.swapExactTokensForTokens(_actualWithdrawn, 0, path, address(this), now);
            }
        }
    }

    function _sellLendingProfits() internal {
        cWant.accrueInterest();
        uint256 _debt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = balanceOfBase(cWant);

        if (_totalAssets > _debt) {
            redeem(_totalAssets.sub(_debt));
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

    function balanceOfBase(CTokenInterface cToken) internal view returns (uint256){
        return _cToBase(cToken.balanceOf(address(this)), cToken);
    }

    // Value of deposited want in USD
    function valueOfCWant() public view returns (uint256){
        return _baseToUsd(balanceOfBase(cWant), cWant);
    }

    // Value of Inverse supplied tokens in USD
    function valueOfCSupplied() public view returns (uint256){
        return _baseToUsd(balanceOfBase(cSupplied), cSupplied);
    }

    // Value of reward tokens in USD
    function valueOfxInv() public view returns (uint256){
        return _baseToUsd(balanceOfBase(xInv), xInv);
    }

    function valueOfTotalCollateral() public view returns (uint256){
        return valueOfCWant().add(valueOfCSupplied()).add(valueOfxInv());
    }

    // Value of borrowed tokens in USD
    function valueOfBorrowedOwed() public view returns (uint256){
        return _baseToUsd(cBorrowed.borrowBalanceStored(address(this)), cBorrowed);
    }

    // Value of delegated vault deposits in USD
    function valueOfDelegated() public view returns (uint256){
        uint256 _amountInBorrowed = delegatedVault.balanceOf(address(this)).mul(delegatedVault.pricePerShare()).div(10 ** delegatedVault.decimals());
        return _baseToUsd(_amountInBorrowed, cBorrowed);
    }

    function _baseToUsd(uint256 _amountUnderlying, CTokenInterface cToken) internal view returns (uint256){
        if (_amountUnderlying == type(uint256).max || _amountUnderlying == 0) return _amountUnderlying;
        uint256 _usdPerUnderlying = comptroller.oracle().getUnderlyingPrice(address(cToken));
        return _amountUnderlying.mul(_usdPerUnderlying).div(1e18);
    }

    function _usdToBase(uint256 _amountInUsd, CTokenInterface cToken) internal view returns (uint256){
        if (_amountInUsd == type(uint256).max || _amountInUsd == 0) return _amountInUsd;
        uint256 _usdPerUnderlying = comptroller.oracle().getUnderlyingPrice(address(cToken));
        return _amountInUsd.mul(1 ether).div(_usdPerUnderlying);
    }

    function _borrowedToShares(uint256 _amountBorrowed) internal view returns (uint256){
        if (_amountBorrowed == type(uint256).max || _amountBorrowed == 0) return _amountBorrowed;
        uint256 _borrowedPerShare = delegatedVault.pricePerShare();
        return _amountBorrowed.mul(10 ** delegatedVault.decimals()).div(_borrowedPerShare);
    }

    function _cToBase(uint256 _amountCToken, CTokenInterface cToken) internal view returns (uint256){
        if (_amountCToken == type(uint256).max || _amountCToken == 0) return _amountCToken;
        uint256 _underlyingPerCToken = cToken.exchangeRateStored();
        return _amountCToken.mul(_underlyingPerCToken).div(1e18);
    }

    function _ethToWant(uint256 _amtInWei) internal view returns (uint256 amountOut){
        if (_amtInWei > 0) {
            amountOut = router.getAmountsOut(_amtInWei, wethWantPath)[1];
        }
    }


    // used after a migration to redeem escrowed INV tokens that can then be swept by gov
    function withdrawEscrowedRewards() external onlyAuthorized {
        TimelockEscrowInterface _timelockEscrow = TimelockEscrowInterface(xInv.escrow());
        _timelockEscrow.withdraw();
    }


    //
    // Setters
    //

    function setTargetCollateralFactor(uint256 _targetMantissa) external onlyAuthorized {
        (, uint256 _safeCollateralFactor,) = comptroller.markets(address(cWant));
        require(_targetMantissa.add(collateralTolerance) < _safeCollateralFactor, "too high");
        require(_targetMantissa > collateralTolerance, "too low");

        targetCollateralFactor = _targetMantissa;
    }

    function setRouter(address _address) external onlyGovernance {
        want.safeApprove(address(router), type(uint256).max);
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
        require(_address != address(cWant), "same as want");

        // comptroller.exitMarket(address(cSupplied));
        cSupplied = CErc20Interface(address(_address));

        claimableMarkets[2] = _address;
        comptroller.enterMarkets(claimableMarkets);
    }

    // @param _amount in cToken from the private marketa
    function supplyCollateral(uint256 _amount) external onlyInverseGovernance returns (bool){
        cSupplied.approve(inverseGovernance, type(uint256).max);
        cSupplied.approve(address(this), type(uint256).max);
        return cSupplied.transferFrom(inverseGovernance, address(this), _amount);
    }

    function removeCollateral(uint256 _cTokenAmount) external onlyInverseGovernance {
        freeUpCollateral(_baseToUsd(_cToBase(_cTokenAmount, cSupplied), cSupplied));
        cSupplied.transfer(msg.sender, Math.min(_cTokenAmount, cSupplied.balanceOf(address(this))));
    }
}
