# Results

Date: 2026-09-02  
Result: **PASS — read path and transaction preparation UI**

## Evidence

| Case | Result | Evidence |
| --- | --- | --- |
| FS-001 | PASS | Ponder completed backfill and PostgreSQL contained 1 Contest, 1 market state, and 5 trades |
| FS-002 | PASS | `/v1/health` reported chain `46630`, live block `111419371`, and database `ok` |
| FS-003 | PASS | `/v1/chains/46630/contests` returned the deployed Contest and its aggregate state |
| FS-004 | PASS | Browser rendered 1 Contest, `$23.86K` volume, 5 trades, and indexed block `111376738` |
| FS-005 | PASS | Contest page read the live market and returned a Testnet `previewBuy` quote for 10 Test USDC |
| FS-006 | PASS | Frontend lint/typecheck/build, backend typecheck/build, database typecheck, and Ponder codegen/typecheck passed |

## Security observations

- Frontend transaction preparation uses an exact settlement-token approval.
- Buy simulation runs before wallet submission.
- Minimum output applies 0.5% slippage protection.
- The wallet private key is never placed in frontend code or committed files.
- Environment files remain ignored; only safe `.env.example` files are tracked.

## Round 003 gate

Round 003 must use an injected browser wallet on chain `46630`, record the
approval and buy transaction hashes, wait for Ponder confirmation, and verify
that both the API and refreshed page show the new trade.
