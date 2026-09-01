# Round 001 Results

> Overall status: `BLOCKED_AWAITING_ACCOUNT_SIGNER`  
> Evidence cutoff block: `111181599`  
> Last updated: 2026-09-01

## Passed preflight checks

- Chain ID is `46630`.
- The locked account has no bytecode and is therefore an EOA.
- Native balance is `0.02 ETH`; current Nonce is `0`.
- Registry Registrar is the Factory Proxy and `defaultMarketVersion = 1`.
- Global Risk Mode is `Normal`.
- The account was funded with `100,000 Test USDC` in successful transaction `0xf12e5ea1833c7c7a7e2db7752f3868f82b7140799fd3d67944fa351ed58956f6`.
- Post-funding Test USDC balance is `100,000`; Factory Allowance remains `0` as expected.
- Team Treasury and FeeVault baselines are zero before the first Contest.

## Runner verification

The standard runner compiled successfully and completed a full no-broadcast simulation against the latest Robinhood Testnet state using a separate local development signer. The simulated path covered funding, Approval, deterministic Contest creation, BUY, atomic FLIP, SELL, two SELL ALL exits, exact 70/20/10 accrual, Creator/Referrer claims, Registry bindings and Reserve/FeeVault solvency. This proves the runner is executable but is not evidence that the locked E2E account performed those actions.

## Blocking condition

The only locally configured private key derives to deployment account `0x9352e25bCE67fE650BC8Ab7fBda5E92c36273E91`, not the locked E2E account. The user-path transactions therefore have not been broadcast. Substituting the deployment account or impersonating the locked account on a local fork would not be a real Testnet E2E for the requested address.

The disposable Testnet signer must be configured locally or the transactions must be approved by that address's wallet. The private key must never be pasted into chat or committed.

## Current conclusion

Infrastructure activation, account Gas and Test USDC preparation passed. Real user-path E2E remains inconclusive until the locked EOA signs the Approval, Contest creation and trading transactions. No contract behavior has failed in this round, and no unexecuted case is marked as passed.

## Required continuation

1. Configure a disposable Testnet-only signer that derives to `0x22b12cbad5a3ea288feb71df4cf52e4f08529cbc`.
2. Run the reviewed standard E2E script.
3. Copy the Foundry broadcast bundle into this round.
4. Re-read every receipt and contract post-state independently.
5. Replace `BLOCKED` case states with `PASSED` or `FAILED`, and add a final release conclusion.
