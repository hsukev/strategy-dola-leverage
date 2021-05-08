import brownie
from brownie import Contract
import pytest


def test_operation(
    accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # tend()
    strategy.tend({"from": strategist})

    # withdrawal
    vault.withdraw({"from": user})
    assert (
        pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before
    )


def test_emergency_exit(
    accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # set emergency and exit
    strategy.setEmergencyExit({"from": strategist})
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets() < amount


def test_profitable_harvest(
    accounts, token, vault, delegatedVault, strategy, gov, user, strategist, amount, RELATIVE_APPROX, chain
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    delegatedStrat = Contract(delegatedVault.withdrawalQueue(0))
    delegatedStrat.harvest({"from": gov})
    chain.sleep(60*60 * 24)  # 1 day
    chain.mine(1)
    delegatedStrat.harvest({"from": gov})
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    # Harvest 2: Realize profit
    before_pps = vault.pricePerShare()

    # TODO check for profits
    # profit = token.balanceOf(vault.address)  # Profits go to vault
    # assert token.balanceOf(strategy) + profit > amount
    assert vault.pricePerShare() > before_pps


def test_change_debt(
    gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest()
    half = int(amount / 2)

    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # In order to pass this tests, you will need to implement prepareReturn.
    # TODO: uncomment the following lines.
    # vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    # strategy.harvest()
    # assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half


def test_sweep(gov, vault, strategy, token, user, amount, rook, rook_whale):
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    # TODO: If you add protected tokens to the strategy.
    # Protected token doesn't work
    with brownie.reverts("!protected"):
        strategy.sweep(strategy.reward(), {"from": gov})
        strategy.sweep(strategy.borrowed(), {"from": gov})
        strategy.sweep(strategy.delegated(), {"from": gov})
        strategy.sweep(strategy.cWant(), {"from": gov})
        strategy.sweep(strategy.cReward(), {"from": gov})
        strategy.sweep(strategy.cSupplied(), {"from": gov})

    before_balance = rook.balanceOf(gov)
    rook_amount = 10 * 10 ** 18
    rook.transfer(strategy, rook_amount, {"from": rook_whale})
    assert rook.address != strategy.want()
    strategy.sweep(rook, {"from": gov})
    assert rook.balanceOf(gov) == rook_amount + before_balance


def test_triggers(
    gov, vault, strategy, token, amount, user, weth, weth_amout, strategist
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest()

    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)
