import brownie
import pytest
import util
from brownie import Contract, Wei


# def test_immediate_operation(
#         cWant,
#         chain,
#         accounts,
#         token,
#         vault,
#         strategy,
#         user,
#         strategist,
#         amount,
#         RELATIVE_APPROX,
#         delegatedVault,
# ):
#     # Deposit to the vault
#     user_balance_before = token.balanceOf(user)
#     strategy.setBorrowLimit(1000 * 10 ** 18)
#     token.approve(vault.address, amount, {"from": user})
#     vault.deposit(amount, {"from": user})
#     assert token.balanceOf(vault.address) == amount
#
#     # harvest
#     assert strategy.tendTrigger(0) == False
#     strategy.harvest({"from": strategist})
#     assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
#
#     # tend()
#     assert strategy.tendTrigger(0) == False
#     strategy.tend({"from": strategist})
#
#     # withdrawal
#     vault.withdraw({"from": user})
#     user_balance_after = token.balanceOf(user)
#     assert pytest.approx(user_balance_after, rel=RELATIVE_APPROX) == user_balance_before
#     print("loss: ", (user_balance_before - user_balance_after) / 1e18)
#     assert strategy.tendTrigger(0) == False
#
#
# # TODO: use asserts instead of just printing states
# def test_airdrop_want(
#         cWant,
#         chain,
#         accounts,
#         token,
#         vault,
#         strategy,
#         user,
#         strategist,
#         token_whale,
#         amount,
#         RELATIVE_APPROX,
#         delegatedVault,
# ):
#     # Deposit to the vault
#     user_balance_before = token.balanceOf(user)
#     strategy.setBorrowLimit(1000 * 1e18)
#     token.approve(vault, amount, {"from": user})
#     vault.deposit(amount, {"from": user})
#     assert token.balanceOf(vault) == amount
#
#     # harvest
#     strategy.harvest({"from": strategist})
#     assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
#
#     airdrop_amount = 500 * 1e18
#     starting_total_assets = strategy.estimatedTotalAssets()
#     token.transfer(strategy, airdrop_amount, {"from": token_whale})
#     assert token.balanceOf(strategy) == airdrop_amount
#     assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == starting_total_assets + airdrop_amount
#
#     print("==== Airdrop ====")
#     util.stateOfStrat(strategy, token)
#     util.stateOfVault(vault, strategy, token)
#
#     strategy.tend({"from": strategist})
#     assert token.balanceOf(strategy) == 0
#
#     print("==== Tend ====")
#     util.stateOfStrat(strategy, token)
#     util.stateOfVault(vault, strategy, token)
#
#     strategy.harvest({"from": strategist})
#
#     print("==== Harvest ====")
#     util.stateOfStrat(strategy, token)
#     util.stateOfVault(vault, strategy, token)
#
#     # withdrawal
#     vault.withdraw({"from": user})
#     # the airdrop gets reported properly and set to vault as profit, but then it's deposited back into the vault? Maybe needs to add 6 hr pps recovery time
#     user_balance_after = token.balanceOf(user)
#     assert pytest.approx(user_balance_after, rel=RELATIVE_APPROX) == user_balance_before
#     print("loss: ", (user_balance_before - user_balance_after) / 1e18)
#
#     print("==== Withdraw ====")
#     util.stateOfStrat(strategy, token)
#     util.stateOfVault(vault, strategy, token)
#
#
# def test_operation(
#         cWant,
#         chain,
#         accounts,
#         token,
#         vault,
#         strategy,
#         user,
#         strategist,
#         amount,
#         RELATIVE_APPROX,
#         delegatedVault,
# ):
#     # Deposit to the vault
#     user_balance_before = token.balanceOf(user)
#     token.approve(vault.address, amount, {"from": user})
#     strategy.setBorrowLimit(1000 * 10 ** 18)
#     vault.deposit(amount, {"from": user})
#     assert token.balanceOf(vault.address) == amount
#
#     # harvest
#     assert strategy.tendTrigger(0) == False
#     strategy.harvest({"from": strategist})
#     assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
#
#     chain.sleep(3600 * 6)  # 6 hrs for pps to recover
#     chain.mine(1)
#
#     # tend()
#     assert strategy.tendTrigger(0) == False
#     strategy.tend({"from": strategist})
#
#     # withdrawal
#     vault.withdraw({"from": user})
#     assert (
#             pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before
#     )
#     assert strategy.tendTrigger(0) == False
#

# def test_emergency_exit(
#         accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, chain
# ):
#     # Deposit to the vault
#     token.approve(vault.address, amount, {"from": user})
#     vault.deposit(amount, {"from": user})
#     strategy.setBorrowLimit(100 * 1e18)
#     print(f"vault pps: {vault.pricePerShare() / 1e18}")
#     strategy.harvest()
#     assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
#     util.stateOfVault(vault, strategy, token)
#
#     chain.sleep(3600 * 6)  # 6 hrs for pps to recover
#     chain.mine(1)
#
#     # set emergency and exit
#     strategy.setEmergencyExit({"from": strategist})
#     print(f"\n before harvest")
#     print(f"vault pps: {vault.pricePerShare()}")
#     util.stateOfStrat(strategy, token)
#     strategy.harvest({"from": strategist})
#     print(f"\n after harvest")
#     print(f"vault pps: {vault.pricePerShare()}")
#     util.stateOfStrat(strategy, token)
#     # dust
#     assert strategy.estimatedTotalAssets() < 1e16
#
#     util.stateOfVault(vault, strategy, token)
#
#
# def test_profitable_harvest(
#         accounts,
#         token,
#         vault,
#         weth,
#         delegatedVault,
#         strategy,
#         user,
#         strategist,
#         weth_whale,
#         amount,
#         RELATIVE_APPROX,
#         chain,
# ):
#     # Deposit to the vault
#     token.approve(vault.address, amount, {"from": user})
#     vault.deposit(amount, {"from": user})
#     assert token.balanceOf(vault.address) == amount
#
#     # 1000 eth, roughly 3m
#     strategy.setBorrowLimit(1000 * 10 ** 18)
#
#     # Harvest 1: Send funds through the strategy
#     strategy.harvest({"from": strategist})
#     assert (
#             strategy.valueOfDelegated() > 0
#     )  # ensure funds have been deposited into delegated vault
#     assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
#
#     # increase rewards, lending interest and borrowing interests
#     # assets_before = vault.totalAssets()
#     chain.sleep(30 * 24 * 3600)  # 30 days
#     chain.mine(1)
#
#     strategy.harvest()
#     weth.transfer(
#         delegatedVault, Wei("20_000 ether"), {"from": weth_whale}
#     )  # simulate delegated vault interest
#
#     # Harvest 2: Realize profit
#     before_pps = vault.pricePerShare()
#     strategy.harvest()
#     chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
#     chain.mine(1)
#
#     # print(
#     #     "Estimated APR: ", "{:.2%}".format((vault.totalAssets() - assets_before) / assets_before * 12),
#     # )
#
#     profit = token.balanceOf(vault.address)  # Profits go to vault
#     assert strategy.estimatedTotalAssets() + profit > amount
#     assert vault.pricePerShare() > before_pps
#     assert vault.totalAssets() > amount
#
#
# def test_profitable_harvest_with_collateral_injection(
#         accounts,
#         token,
#         vault,
#         weth,
#         delegatedVault,
#         strategy,
#         user,
#         strategist,
#         weth_whale,
#         amount,
#         RELATIVE_APPROX,
#         chain,
#         cSupplied,
#         cSupplied_whale,
#         inverseGov,
#         cSupply_amount,
# ):
#     # Deposit to the vault
#     token.approve(vault.address, amount, {"from": user})
#     vault.deposit(amount, {"from": user})
#     assert token.balanceOf(vault.address) == amount
#
#     # 1000 eth, roughly 3m
#     strategy.setBorrowLimit(1000 * 10 ** 18)
#
#     # Harvest 1: Send funds through the strategy
#     strategy.harvest({"from": strategist})
#     assert (
#             strategy.valueOfDelegated() > 0
#     )  # ensure funds have been deposited into delegated vault
#     assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
#
#     cSupplied.approve(strategy, 2 ** 256 - 1, {"from": inverseGov})
#
#     print("before injection")
#     util.stateOfStrat(strategy, token)
#     strategy.supplyCollateral(cSupply_amount, {"from": inverseGov})
#
#     assert strategy.valueOfCSupplied() > 0
#
#     print("after injection")
#     util.stateOfStrat(strategy, token)
#     # increase rewards, lending interest and borrowing interests
#     # assets_before = vault.totalAssets()
#     chain.sleep(30 * 24 * 3600)  # 30 days
#     chain.mine(1)
#     strategy.harvest()
#     weth.transfer(
#         delegatedVault, Wei("20 ether"), {"from": weth_whale}
#     )  # simulate delegated vault interest
#
#     # Harvest 2: Realize profit
#     before_pps = vault.pricePerShare()
#     strategy.harvest()
#     chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
#     chain.mine(1)
#
#     # print(
#     #     "Estimated APR: ", "{:.2%}".format((vault.totalAssets() - assets_before) / assets_before * 12),
#     # )
#
#     profit = token.balanceOf(vault.address)  # Profits go to vault
#     assert strategy.estimatedTotalAssets() + profit > amount
#     assert vault.pricePerShare() > before_pps
#     assert vault.totalAssets() > amount
#     print("before removed")
#     util.stateOfStrat(strategy, token)
#
#     strategy.removeCollateral(cSupply_amount, {"from": inverseGov})
#
#     print("after removed")
#     util.stateOfStrat(strategy, token)
#     assert cSupplied.balanceOf(inverseGov) == cSupply_amount
#

def test_change_debt(
        gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, weth, delegatedVault, weth_whale
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    strategy.setBorrowLimit(1000 * 10 ** 18)
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest()
    half = int(amount / 2)
    print("debtRatio 5000")
    util.stateOfStrat(strategy, token)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    strategy.harvest()

    print("debtRatio 10000")
    util.stateOfStrat(strategy, token)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    strategy.harvest()
    weth.transfer(
        delegatedVault, Wei("20_000 ether"), {"from": weth_whale}
    )  # simulate delegated vault interest

    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    assert False
    strategy.harvest()

    print("debtRatio 5000")
    util.stateOfStrat(strategy, token)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half


def test_change_debt_with_injection(
        gov,
        token,
        vault,
        strategy,
        user,
        strategist,
        amount,
        RELATIVE_APPROX,
        cSupplied,
        cSupply_amount,
        inverseGov,
):
    # Inject cSupplied
    cSupplied.approve(strategy, 2 ** 256 - 1, {"from": inverseGov})
    print("before injection")
    util.stateOfStrat(strategy, token)
    strategy.supplyCollateral(cSupply_amount, {"from": inverseGov})

    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    strategy.setBorrowLimit(1000 * 10 ** 18)
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest()

    print("debtRatio 5000")
    util.stateOfStrat(strategy, token)

    half = int(amount / 2)

    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    strategy.harvest()

    print("debtRatio 10000")
    util.stateOfStrat(strategy, token)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # In order to pass this tests, you will need to implement prepareReturn.
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest()

    print("debtRatio 5000")
    util.stateOfStrat(strategy, token)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half


def test_collateral_factor(
        token,
        vault,
        cBorrowed,
        strategy,
        user,
        strategist,
        amount,
        RELATIVE_APPROX,
        weth,
        weth_whale,
        delegatedVault,
        chain,
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    strategy.setBorrowLimit(1000 * 1e18, {"from": strategist})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    assert strategy.harvestTrigger(0) == True
    assert strategy.tendTrigger(0) == False
    strategy.harvest({"from": strategist})
    util.stateOfStrat(strategy, token)
    util.stateOfVault(vault, strategy, token)

    with brownie.reverts("too low"):
        strategy.setTargetCollateralFactor(0.01 * 1e18)
    with brownie.reverts("too high"):
        strategy.setTargetCollateralFactor(0.6 * 1e18)

    strategy.setTargetCollateralFactor(0.1 * 1e18)
    assert strategy.harvestTrigger(0) == False
    assert strategy.tendTrigger(0) == True
    strategy.tend({"from": strategist})
    util.stateOfStrat(strategy, token)
    util.stateOfVault(vault, strategy, token)

    strategy.setTargetCollateralFactor(0.5 * 1e18)
    assert strategy.harvestTrigger(0) == False
    assert strategy.tendTrigger(0) == True
    strategy.tend({"from": strategist})
    util.stateOfStrat(strategy, token)
    util.stateOfVault(vault, strategy, token)

    # give it some profits
    weth.transfer(
        delegatedVault, Wei("20_000 ether"), {"from": weth_whale}
    )  # simulate delegated vault interest
    assert strategy.harvestTrigger(0) == True
    assert strategy.tendTrigger(0) == False
    strategy.harvest()
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    util.stateOfStrat(strategy, token)
    util.stateOfVault(vault, strategy, token)

    strategy.setTargetCollateralFactor(0.1 * 1e18)
    assert strategy.harvestTrigger(0) == True
    assert strategy.tendTrigger(0) == False
    strategy.harvest({"from": strategist})
    util.stateOfStrat(strategy, token)
    util.stateOfVault(vault, strategy, token)


def test_borrow_limit(
        token, vault, cBorrowed, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # default no borrowing
    strategy.harvest({"from": strategist})
    assert cBorrowed.borrowBalanceStored(strategy) == 0
    assert strategy.valueOfBorrowedOwed() == 0
    assert strategy.valueOfDelegated() == 0

    strategy.tend({"from": strategist})
    assert cBorrowed.borrowBalanceStored(strategy) == 0
    assert strategy.valueOfBorrowedOwed() == 0
    assert strategy.valueOfDelegated() == 0

    # set borrow limit to 1000 eth, roughly 3m
    strategy.setBorrowLimit(1000 * 1e18, {"from": strategist})
    strategy.tend({"from": strategist})
    borrowed_amount = cBorrowed.borrowBalanceStored(strategy)
    borrowed_value = strategy.valueOfBorrowedOwed()
    assert borrowed_amount > 0
    assert borrowed_value > 0
    assert (
            pytest.approx(strategy.valueOfDelegated(), rel=RELATIVE_APPROX)
            == borrowed_value
    )

    # reduce borrow limit
    half_borrowed_amount = borrowed_amount / 2
    half_borrowed_value = borrowed_value / 2
    strategy.setBorrowLimit(half_borrowed_amount, {"from": strategist})
    strategy.tend({"from": strategist})
    assert (
            pytest.approx(cBorrowed.borrowBalanceStored(strategy), rel=RELATIVE_APPROX)
            == half_borrowed_amount
    )
    assert (
            pytest.approx(strategy.valueOfBorrowedOwed(), rel=RELATIVE_APPROX)
            == half_borrowed_value
    )

    # disable borrowing
    strategy.setBorrowLimit(0, {"from": strategist})
    strategy.tend({"from": strategist})
    assert strategy.valueOfDelegated() == 0
    assert cBorrowed.borrowBalanceStored(strategy) == 0
    assert strategy.valueOfBorrowedOwed() == 0


def test_sweep(
        gov, vault, strategy, token, user, amount, inv, inv_whale, rook, rook_whale
):
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    # Protected token doesn't work
    with brownie.reverts("!protected"):
        strategy.sweep(strategy.borrowed(), {"from": gov})
        strategy.sweep(strategy.delegated(), {"from": gov})
        strategy.sweep(strategy.cWant(), {"from": gov})
        strategy.sweep(strategy.xInv(), {"from": gov})
        strategy.sweep(strategy.cSupplied(), {"from": gov})

    inv_before_balance = rook.balanceOf(gov)
    inv_amount = 10 * 1e18
    inv.transfer(strategy, inv_amount, {"from": inv_whale})
    assert inv.address != strategy.want()
    strategy.sweep(inv, {"from": gov})
    assert inv.balanceOf(gov) == inv_amount + inv_before_balance

    rook_before_balance = rook.balanceOf(gov)
    rook_amount = 10 * 1e18
    rook.transfer(strategy, rook_amount, {"from": rook_whale})
    assert rook.address != strategy.want()
    strategy.sweep(rook, {"from": gov})
    assert rook.balanceOf(gov) == rook_amount + rook_before_balance


def test_triggers(
        gov, vault, strategy, token, amount, user, weth, weth_amout, strategist
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    strategy.setBorrowLimit(1000 * 10 ** 18)

    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest()

    assert strategy.harvestTrigger(0) == False
    assert strategy.tendTrigger(0) == False
