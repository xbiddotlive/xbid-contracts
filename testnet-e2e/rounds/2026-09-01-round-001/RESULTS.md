# Round 001 Results

> Overall status: `PASSED_USER_PATH`; execution: 2026-09-02 06:36:54–06:37:24 Asia/Taipei; blocks: `111376571`–`111376771`; user transactions: `12 / 12 successful`.

## Conclusion

The activated XBID V1 real Testnet user path passed for `0x22B12Cbad5a3EA288fEB71Df4Cf52E4F08529cbc`. Approval, deterministic Contest creation, direct Creation Fee collection, BUY, atomic FLIP, SELL, SELL ALL, 70/20/10 fee accounting, Creator/Referrer claims and final solvency all matched the locked specification.

This round approves only the user path tested here. It is not Public Testnet or Mainnet release approval; governance, emergency, negative-path, frontend, indexer, reorg, source-verification and audit gates remain separate.

## Created Contest

| Field | Value |
| --- | --- |
| Contest ID | `0xb73517e2deacfc81a60953d1545f6602b186483d3e9b59fc43a5a8e75497513d` |
| Creator | `0x22B12Cbad5a3EA288fEB71Df4Cf52E4F08529cbc` |
| MarketVault | `0xB48B4B842c0fCbc18Fd616d3F89DE87562A8c494` |
| Side A | `0xFdFf0F040681b38A7275F8398338956296a8055C` |
| Side B | `0x5530BA151C61FCB21Ba55D3f116B60cb402FCd14` |
| Market Version | `1` |

Registry records, registered-address indexes, MarketVault bindings and both SideToken back-references were independently re-read and matched exactly.

## Case results

| Case | Result | Evidence summary |
| --- | --- | --- |
| PRE-001–005 | `PASSED` | Chain, activation, EOA, Gas, Test USDC, signer match and unused Contest ID verified before broadcast |
| E2E-CREATE-001 | `PASSED` | Exact 5 Test USDC Factory approval succeeded |
| E2E-CREATE-002 | `PASSED` | Deterministic MarketVault and two SideToken Clones deployed and registered |
| E2E-CREATE-003 | `PASSED` | Team Treasury increased by exactly 5 Test USDC; Factory/Registry stayed at zero |
| E2E-TRADE-001 | `PASSED` | BUY quote, mint, Reserve, Supply and fee events reconciled |
| E2E-TRADE-002 | `PASSED` | One FLIP receipt contained one `Flipped`, one `TradingFeeProcessed` and one `TradingFeeAccrued` event |
| E2E-TRADE-003 | `PASSED` | SELL burn, payout, Reserve and fee credit reconciled |
| E2E-TRADE-004 | `PASSED` | Both SELL ALL transactions succeeded; user balances and both total supplies ended at zero |
| E2E-FEE-001 | `PASSED` | Total `238.586658` split into Protocol `167.010664`, Creator `47.717330`, Referrer `23.858664` Test USDC |
| E2E-FEE-002 | `PASSED` | Creator and Referrer credits were paid to their exact beneficiaries and cleared to zero |
| E2E-SAFE-001 | `PASSED` | Market and FeeVault remained solvent; Factory/Registry held no Test USDC |

## Final accounting

| Account or ledger | Final units | Interpretation |
| --- | ---: | --- |
| User Test USDC | `99,804,130,670` | `99,804.130670` Test USDC |
| Team Treasury | `5,000,000` | Exact Creation Fee |
| FeeVault balance | `167,010,664` | Exactly equals remaining Protocol liability |
| Protocol claimable | `167,010,664` | 70% plus integer dust |
| Creator claimable | `0` | `47,717,330` already claimed |
| Referrer claimable | `0` | `23,858,664` already claimed |
| Referrer balance | `23,858,664` | Exact claimed amount |
| Market balance / Reserve | `2 / 2` | Positive rounding buffer; required Reserve is `0` after full exit |
| Factory / Registry | `0 / 0` | No retained Settlement Token |

The user's Test USDC decrease was `195,869,330` units and reconciles exactly to Team Creation Fee `5,000,000` + Protocol liability `167,010,664` + Referrer payout `23,858,664` + Market rounding buffer `2`. Creator trading fees were returned to the user through `claimFees()`.

Gas usage was `2,635,294` Gas across 12 user transactions, costing `0.00002635294 ETH` at the observed Testnet Gas price.

## Receipt verification

- All 12 receipts were independently re-read from RPC and returned `status = 1`.
- The deployment-wide `REQUIRE_ACTIVATED=true` Validator passed again after the E2E round.
- The execution bundle contains no private key, mnemonic, password or secret field.
- `script-result.json` contains the assertion-backed result; `broadcast.json` contains the public transaction bundle and RPC receipts; `transactions.json` is the normalized human-review index.

## Deferred rounds

- Duplicate Contest and Creation Fee rollback;
- Deadline, Minimum Output, balance-change and Referrer-rebind rejection;
- Per-Market Risk-Off and Full Pause with Emergency/Governance Safes;
- Factory upgrade rehearsal and historical Contest immutability;
- Frontend receipt fallback, Indexer replay, multi-Version ABI routing and reorg recovery.
