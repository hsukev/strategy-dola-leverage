import pytest
from brownie import config
from brownie import Contract


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, user):
    amount = 10 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at("0x3ff33d9162ad47660083d7dc4bc02fb231c81677", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov, cWant, cBorrowed, cReward, delegatedVault):
    strategy = strategist.deploy(Strategy, vault, cWant, cBorrowed, cReward, delegatedVault)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture
def cWant():
    token_address = "0xde2af899040536884e062D3a334F2dD36F34b4a4"
    yield Contract(token_address)


@pytest.fixture
def cBorrowed():
    token_address = "0x697b4acAa24430F254224eB794d2a85ba1Fa1FB8"
    yield Contract(token_address)


@pytest.fixture
def cReward():
    token_address = "0xde2af899040536884e062D3a334F2dD36F34b4a4"
    yield Contract(token_address)


@pytest.fixture
def delegatedVault():
    token_address = "0xa9fE4601811213c340e850ea305481afF02f5b28"
    yield Contract(token_address)


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
