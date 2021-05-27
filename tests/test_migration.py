# TODO: Add tests that show proper migration of the strategy to a newer one
#       Use another copy of the strategy to simulate the migration
#       Show that nothing is lost!

import pytest
import util


def test_migration(
        token, vault, strategy, amount, Strategy, strategist, gov, user, RELATIVE_APPROX, cWant, cBorrowed,
        delegatedVault
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    strategy.setBorrowLimit(1000 * 10 ** 18)
    vault.deposit(amount, {"from": user})
    strategy.harvest()
    util.stateOfStrat(strategy, token)
    util.stateOfVault(vault, strategy, token)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # migrate to a new strategy
    new_strategy = strategist.deploy(Strategy, vault, cWant, cBorrowed, delegatedVault)
    new_strategy.setBorrowLimit(1000 * 10 ** 18)
    strategy.migrate(new_strategy.address, {"from": gov})
    assert (
            pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
            == amount
    )
