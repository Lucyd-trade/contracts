# Lucyd contracts

Smart contracts behind [Lucyd](https://testnet.lucyd.trade): binary UpDown markets on the BTC/USD price, settled by the Pyth oracle.

## Deployments

Each deployment has its own file in [`deployments/`](deployments) and a git tag with the exact source code at those addresses. `main` may be ahead of what is deployed.

### Sepolia testnet

> Testnet only: test USDC, no real funds.

Source: tag [`sepolia-2026-10-07`](https://github.com/Lucyd-trade/contracts/tree/sepolia-2026-10-07), addresses: [`deployments/sepolia.json`](deployments/sepolia.json).

| Contract | Address |
|---|---|
| ConditionalTokens | [`0xB62eFc43C16b4E2Bf1aAAD33002368e55708538D`](https://sepolia.etherscan.io/address/0xB62eFc43C16b4E2Bf1aAAD33002368e55708538D) |
| MarketFactory | [`0xe4DC0a7c6eaa2ae66FdDe61e1882749430F7aAbd`](https://sepolia.etherscan.io/address/0xe4DC0a7c6eaa2ae66FdDe61e1882749430F7aAbd) |
| PriceResolver | [`0xe051D7D72DEb54F934F5DFa0846779232e7265dD`](https://sepolia.etherscan.io/address/0xe051D7D72DEb54F934F5DFa0846779232e7265dD) |
| AutoRedeemer | [`0x42Bf669f0A3DCc95510001Ddbc43D56FdE67268F`](https://sepolia.etherscan.io/address/0x42Bf669f0A3DCc95510001Ddbc43D56FdE67268F) |
| PartnerProgram (deployed 2026-10-13, source `src/PartnerProgram.sol` on `main`) | [`0xf1552eEBe261c0438a31DcbC39c57d31Fa7b0A25`](https://sepolia.etherscan.io/address/0xf1552eEBe261c0438a31DcbC39c57d31Fa7b0A25) |
| ScoutProgram (deployed 2026-10-26, source `src/ScoutProgram.sol` on `main`) | [`0x03d75C08db918065DCdb86fcB813Fe2b5d619F27`](https://sepolia.etherscan.io/address/0x03d75C08db918065DCdb86fcB813Fe2b5d619F27) |

External: USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`, Pyth `0xBb86bCc951A62DF86826219d9251Ee05F2c1e286`.
## How a market works

1. **Create.** `MarketFactory` creates a market for a period (5m, 15m, 30m, 1h, 4h, 1d) and registers it in `ConditionalTokens`. The resolver of a market is fixed at creation. The strike (the Pyth BTC/USD price at the start of the market) is set once by the market creator when the market opens and cannot be changed afterwards.
2. **Trade.** 1 USDC splits into 1 UP token + 1 DOWN token (`splitPosition`); 1 UP + 1 DOWN merge back into 1 USDC (`mergePositions`). Every outstanding token is fully backed by USDC held in `ConditionalTokens`.
3. **Settle.** After the market ends, **anyone** can call `PriceResolver.settle` with a Pyth price update. The resolver takes the first Pyth BTC/USD price published at or after the end time:
   - price above the strike → UP wins, otherwise DOWN wins;
   - if Pyth published no price within 10 seconds after the end time → the market is void.
   If no price update can be obtained at all, anyone can void the market 24 hours after the end (`voidExpired`).
4. **Redeem.** A winning token pays 1 USDC, a losing token pays 0. On a void every token (UP or DOWN) pays 0.5 USDC. Holders who called `setApprovalForAll(AutoRedeemer, true)` are paid out automatically; anyone can trigger `AutoRedeemer.redeem`, and the USDC always goes to the token holder.

## What the operator can and cannot do

The owner of `ConditionalTokens` and `MarketFactory` can:

- add and remove market creators, set the resolver for **new** markets;
- set the protocol fee for **new** markets, capped at 3% (`MAX_FEE_BPS`), currently 0%; the fee of a market is fixed when it is created;
- point `ConditionalTokens` to a different factory (it can only register new markets, never change existing ones);
- withdraw USDC sent to `ConditionalTokens` by mistake, only above the amount owed to token holders (`sweepDust`).

The owner cannot:

- move or freeze user tokens or the USDC backing them;
- change the outcome, the strike, the end time, the resolver or the fee of an existing market;
- settle a market at a price other than the one published by Pyth.

`AutoRedeemer` has no admin at all.

## Partner program

`PartnerProgram` records partners, the traders bound to them and the daily USDC payouts. Partners earn a share of the trading volume their traders take; the amounts are computed off chain and can be re-checked with [`verify/verify-partner.mjs`](verify/verify-partner.mjs), which reads only the chain.

- The **operator** (a server key) adds partners, binds traders and pays: at most once per day (`dayPaid`), only to partners, never for a future day.
- A binding is permanent: no function changes or removes it.
- The **treasury** withdraws USDC and replaces the operator. The contract holds about a week of payouts, so a leaked operator key can lose at most that balance.

`PartnerProgram` also pays builders: apps and bots that put their builder code into the salt of the orders they send. A builder's earnings can be re-checked with [`verify/verify-builder.mjs`](verify/verify-builder.mjs).

## Scout program

`ScoutProgram` records scouts, the partners bound to them and the daily USDC payouts to scouts. A scout earns a share of what their partners are paid by `PartnerProgram`: 50% for the first 180 days after a partner is bound, 10% after. The amounts are computed off chain from `PartnerProgram` `Paid` events and can be re-checked with [`verify/verify-scout.mjs`](verify/verify-scout.mjs), which reads only the chain.

- The **operator** (the same server key as in `PartnerProgram`) adds scouts, binds partners and pays: at most once per day, only to scouts with at least `MIN_PARTNERS` (2) bound partners.
- A binding is permanent: no function changes or removes it.
- The **treasury** withdraws USDC and replaces the operator. The contract holds about a week of payouts.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```sh
git clone --recursive https://github.com/Lucyd-trade/contracts
cd contracts
forge test
```

Deployment: `script/DeployAll.s.sol`, `script/DeployPartnerProgram.s.sol`, `script/DeployScoutProgram.s.sol` (see the header of each file for the environment variables).

## License

MIT
