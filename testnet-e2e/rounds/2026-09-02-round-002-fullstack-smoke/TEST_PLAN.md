# Testnet E2E Round 002 — Full-stack smoke

## Objective

Validate the first browser-visible XBID vertical slice against Robinhood Chain
Testnet without using mocked market data.

## Data path

`Robinhood Testnet contracts -> Ponder -> PostgreSQL -> NestJS -> Next.js`

## Cases

| ID | Case | Expected |
| --- | --- | --- |
| FS-001 | Backfill the deployed Registry and MarketVault | One Contest and all confirmed trade events are projected |
| FS-002 | Query API readiness | Chain and database both report `ok` |
| FS-003 | Query Contest collection | Deployed Contest and aggregate market state are returned |
| FS-004 | Load the home page | Indexed volume, trade count, reserve, and block are visible |
| FS-005 | Load the Contest page | Live contract state and `previewBuy` quote are visible |
| FS-006 | Production builds | Frontend, backend, database, and indexer type checks pass |

## Excluded from this round

Wallet-extension signing and a new state-changing trade are intentionally left
for Round 003. Round 002 proves the read path and transaction preparation UI;
it does not claim that a browser wallet transaction was executed.
