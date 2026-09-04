# Market V2 b=150,000 Testnet smoke results

Status: PASSED

The fresh round passed preflight and its deterministic contest ID was confirmed unused at block `112627434`. All 12 broadcast transactions succeeded between blocks `112627918` and `112628096`.

## Result

- Contest: `0x0a468bad6bbd871d33f7d95f49d18e51c38c52c0cc71378fb19735b0581e43e1`
- Market: `0x4C707EB7F24116F9862f02482FA7583fC35FF3B6`
- Registry version: `2`
- Market `marketVersion()`: `2`
- Market `bWad()`: `150000000000000000000000`
- Buy gross: `10,000.000000` Test USDC
- Total trading fees: `243.378935` Test USDC
- Protocol fee: `170.365258` Test USDC
- Creator fee claimed: `48.675786` Test USDC
- Referrer fee claimed: `24.337891` Test USDC
- Test account balance: `29,804.130670` -> `29,604.427519` Test USDC
- Team treasury balance: `10.000000` -> `15.000000` Test USDC

## Post-state at block 112628364

- Both account side-token balances and both total supplies are zero after sell-all.
- `qAWei = 0`, `qBWei = 0`, `reserveUnits = 2`, and the market holds exactly `2` settlement-token units.
- Creator and referrer claimable balances are zero after claims.
- FeeVault holds `883715458` units against exactly `883715458` units of liability.
- The script's quote, slippage, deterministic-address, fee-split, reserve-solvency, supply-equality, registration, and binding assertions all passed.
