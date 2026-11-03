# INVARA Core · Smart Contracts

Non-custodial synthetic equity vault on **Robinhood Chain**. Lock stablecoin collateral, mint a synthetic that tracks a US stock (first market: **iAAPL**), repay it to get your collateral back.

- **No admin keys.** No pause, no upgrade proxy, no way for anyone to move user collateral.
- **0% vault fees.** You only pay network gas.
- **Over-collateralized.** Every position must stay at or above 130%; unsafe positions can be liquidated by anyone.

Website: [invaracore.com](https://www.invaracore.com) · Docs: [invaracore.com/docs](https://www.invaracore.com/docs)

## Contracts

| Contract | Role |
|---|---|
| [`InvaraVault`](src/InvaraVault.sol) | Positions, deposit & mint, repay & withdraw, liquidation, debt ceilings, bad-debt accounting |
| [`InvaraChainlinkOracle`](src/InvaraChainlinkOracle.sol) | Reads on-chain price feeds, rejects stale / invalid rounds, normalizes to 18 decimals |
| [`InvaraSyntheticToken`](src/InvaraSyntheticToken.sol) | ERC-20 synthetic (e.g. iAAPL) that only the vault can mint or burn |

## Parameters

| | |
|---|---|
| Minimum collateral ratio | 130% |
| Liquidation reward | 5% (liquidator receives 105% of the debt value repaid) |
| Minimum collateral for a position with debt | 100 (stablecoin units) |
| Price staleness limit (AAPL) | 26 hours: priced actions pause over weekends; full repay & withdraw always work |
| Debt ceiling (iAAPL) | 50 iAAPL, fixed at registration |

The deployer can register a new market once (token + price feed + ceiling). It has no other power: it cannot pause the vault, change parameters, or touch collateral.

## Develop

Requires [Foundry](https://book.getfoundry.sh/).

```bash
git clone --recurse-submodules https://github.com/invaracore/invara-contracts
cd invara-contracts
forge build
forge test
```

## Deployments

Robinhood Chain mainnet addresses are published on [invaracore.com](https://www.invaracore.com) and in the [docs](https://www.invaracore.com/docs/contracts) at launch.

## Security

These contracts are open source for transparency. An external audit is planned before real-money minting opens. If you find a vulnerability, please report it privately via X: [@INVARACore](https://x.com/INVARACore). Do not open a public issue.

## License

[MIT](LICENSE)
