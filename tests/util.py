

def stateOfStrat(strategy, token):
    print('\n-----State of Strat-----')
    print('balanceOfWant : ', strategy.balanceOfWant())
    print('balanceOfReward: ', strategy.balanceOfReward())
    print('balanceOfEth: ', strategy.balanceOfEth())
    print('valueOfCWant: ', strategy.valueOfCWant()/1e18)
    print('valueOfCSupplied (usd): ', strategy.valueOfCSupplied()/1e18)
    print('valueOfxInv (usd): ', strategy.valueOfxInv()/1e18)
    print('valueOfTotalCollateral (usd): ', strategy.valueOfTotalCollateral()/1e18)
    print('valueOfBorrowedOwed (usd): ', strategy.valueOfBorrowedOwed()/1e18)
    print('valueOfDelegated (usd): ', strategy.valueOfDelegated()/1e18)
    print('estimatedTotalAssets (want): ', strategy.estimatedTotalAssets()/10**token.decimals())
    print('delegatedAssets (want): ', strategy.delegatedAssets()/10**token.decimals())
    print('\n')
