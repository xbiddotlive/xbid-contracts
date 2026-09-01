# Round 001 Test Plan

## Identity and scope

- Round ID: `2026-09-01-round-001`
- Network: Robinhood Chain Testnet, Chain ID `46630`
- User EOA: `0x22b12cbad5a3ea288feb71df4cf52e4f08529cbc`
- Objective: validate the activated V1 user path with a real Contest and real Testnet receipts.
- Excluded: Governance/Emergency Safe transitions, global pause, Factory upgrade, reorg recovery and frontend/indexer behavior. These require independent rounds and signers.

## Prerequisites

| ID | Requirement | State |
| --- | --- | --- |
| PRE-001 | Activated Registrar and default Market Version 1 | `PASSED` |
| PRE-002 | User address is an EOA with Testnet ETH | `PASSED` |
| PRE-003 | At least 20,000 Test USDC | `PASSED` after funding transaction |
| PRE-004 | Local signer derives exactly to the user EOA | `BLOCKED` — signer not available locally |
| PRE-005 | Explicit broadcast confirmation | `BLOCKED` until PRE-004 is resolved |

## User-path cases

| Case | Category | Action | Expected result | Current state |
| --- | --- | --- | --- | --- |
| E2E-CREATE-001 | Approval | Approve exactly 5 Test USDC to Factory | Allowance succeeds; no Token leaves account | `BLOCKED` |
| E2E-CREATE-002 | Contest | Create deterministic V1 Contest | One MarketVault and two SideToken Clones registered with permanent bindings | `BLOCKED` |
| E2E-CREATE-003 | Creation fee | Inspect balances and events | Exactly 5 Test USDC reaches Team Treasury; Factory and Registry retain zero | `BLOCKED` |
| E2E-TRADE-001 | BUY | BUY Side A with 10,000 Test USDC and 0.5% minimum-output tolerance | Quote, receipt, minted balance, Reserve and Supply agree | `BLOCKED` |
| E2E-TRADE-002 | FLIP | Atomically FLIP 25% of Side A to Side B | One atomic transaction and one Trading Fee only | `BLOCKED` |
| E2E-TRADE-003 | SELL | SELL half of Side B | Net Test USDC, burn, Reserve and fee ledger agree | `BLOCKED` |
| E2E-TRADE-004 | SELL ALL | Exit remaining Side B and Side A | Both user SideToken balances become zero; Reserve remains solvent | `BLOCKED` |
| E2E-FEE-001 | Fee split | Reconcile every trade | Protocol/Creator/Referrer equals 70/20/10 with integer dust to Protocol | `BLOCKED` |
| E2E-FEE-002 | Claims | Claim Creator and Referrer credits | Credits clear and Test USDC reaches the exact beneficiaries | `BLOCKED` |
| E2E-SAFE-001 | Solvency | Inspect final balances | Market balance covers Reserve; FeeVault balance covers total liability | `BLOCKED` |

## Negative and governance cases deferred to later rounds

- Duplicate Contest retry and atomic Creation Fee rollback;
- expired Deadline and Minimum Output rejection;
- bound Referrer replacement rejection;
- Per-Market Risk-Off: BUY/FLIP blocked while SELL remains live;
- Full Pause: SELL blocked;
- Emergency Safe cannot lower risk; Governance Timelock recovery;
- Indexer replay, frontend receipt fallback and multi-Version ABI routing.

## Execution command

After a disposable Testnet-only signer is configured locally and the plan is reviewed:

```bash
set -a
source .env
set +a
export CONFIRM_ROBINHOOD_TESTNET_E2E=YES
FORGE_BIN=/private/tmp/xbid-foundry-v1.8.1/forge \
  bash scripts/run-robinhood-testnet-e2e.sh \
  testnet-e2e/rounds/2026-09-01-round-001
```

The runner refuses to broadcast if the private key does not derive exactly to the locked user EOA.
