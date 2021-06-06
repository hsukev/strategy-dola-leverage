import brownie
import pytest
import util
from brownie import Contract, Wei

def test_airdrop_want(
        cWant,
        chain,
        accounts,
        token,
        vault,
        strategy,
        user,
        strategist,
        token_whale,
        amount,
        RELATIVE_APPROX,
        delegatedVault,
):
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    strategy.setBorrowLimit(1000 * 1e18)
    token.approve(vault, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault) == amount

    # harvest
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    airdrop_amount = 500 * 1e18
    starting_total_assets = strategy.estimatedTotalAssets()
    token.transfer(strategy, airdrop_amount, {"from": token_whale})
    assert token.balanceOf(strategy) == airdrop_amount
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == starting_total_assets + airdrop_amount

    print("==== Airdrop ====")
    util.stateOfStrat(strategy, token)
    util.stateOfVault(vault, strategy, token)

    strategy.tend({"from": strategist})
    assert token.balanceOf(strategy) == 0

    print("==== Tend ====")
    util.stateOfStrat(strategy, token)
    util.stateOfVault(vault, strategy, token)

    strategy.harvest({"from": strategist})

    chain.sleep(3600 * 7)  # 6 hrs for pps to recover
    chain.mine(1)
    print("==== Harvest ====")
    util.stateOfStrat(strategy, token)
    util.stateOfVault(vault, strategy, token)

    # withdrawal
    vault.withdraw({"from": user})
    # the airdrop gets reported properly and set to vault as profit, but then it's deposited back into the vault? Maybe needs to add 6 hr pps recovery time
    user_balance_after = token.balanceOf(user)
    assert user_balance_after > user_balance_before
    print("loss: ", (user_balance_before - user_balance_after) / 1e18)

    print("==== Withdraw ====")
    util.stateOfStrat(strategy, token)
    util.stateOfVault(vault, strategy, token)
