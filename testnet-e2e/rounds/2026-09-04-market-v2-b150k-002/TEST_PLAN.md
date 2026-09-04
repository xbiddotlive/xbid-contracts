# Market V2 b=150,000 Testnet smoke

Status: PASSED

## Objective

Verify the activated Robinhood Testnet Factory creates Market Version 2 contests with immutable `bWad = 150000e18`, while the standard user path remains solvent and fee accounting remains exact.

## Authorized scope

- Use only the disposable `E2E_TEST_ACCOUNT` configured locally.
- Spend Test ETH for gas, the 5 Test USDC creation fee and curve trading fees.
- Do not use either Governance or Emergency Safe.

## Cases

1. Require Registry versions `[1, 2]` and Factory default version `2`.
2. Create one deterministic V2 smoke contest using a fresh, unused salt.
3. Verify its Registry record, clone bindings, `marketVersion = 2` and `bWad = 150000e18`.
4. Buy Side A with 10,000 Test USDC, atomically flip one quarter to Side B, then exit both sides with sell-all.
5. Verify quote slippage bounds, reserve solvency, token supply equality, fee splits, creator/referrer claims and treasury creation fee.

## Pass criteria

Every broadcast receipt succeeds and all post-state assertions in `RunRobinhoodTestnetE2E.s.sol` pass. The generated result and transaction bundle must be archived before this round is marked PASSED.
