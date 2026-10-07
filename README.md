# Lucyd contracts

Smart contracts behind [Lucyd](https://testnet.lucyd.trade): binary UpDown markets on the BTC/USD price, settled by the Pyth oracle.

## Deployed (Sepolia testnet)

| Contract | Address |
|---|---|
| ConditionalTokens | [`0xB62eFc43C16b4E2Bf1aAAD33002368e55708538D`](https://sepolia.etherscan.io/address/0xB62eFc43C16b4E2Bf1aAAD33002368e55708538D) |
| MarketFactory | [`0xe4DC0a7c6eaa2ae66FdDe61e1882749430F7aAbd`](https://sepolia.etherscan.io/address/0xe4DC0a7c6eaa2ae66FdDe61e1882749430F7aAbd) |
| PriceResolver | [`0xe051D7D72DEb54F934F5DFa0846779232e7265dD`](https://sepolia.etherscan.io/address/0xe051D7D72DEb54F934F5DFa0846779232e7265dD) |
| AutoRedeemer | [`0x42Bf669f0A3DCc95510001Ddbc43D56FdE67268F`](https://sepolia.etherscan.io/address/0x42Bf669f0A3DCc95510001Ddbc43D56FdE67268F) |

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

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```sh
git clone --recursive https://github.com/Lucyd-trade/contracts
cd contracts
forge test
```

Deployment: `script/DeployAll.s.sol` (see the header of the file for the environment variables).

## License

MIT
