# Robinhood Testnet E2E archive

Every real Testnet E2E run has exactly one immutable round directory under `rounds/`. Never overwrite a completed round or reuse its salt. Corrections are appended to that round's report; a rerun uses the next round number.

Required files per round:

- `TEST_PLAN.md`: scope, cases, expected results, prerequisites and signing boundaries;
- `test-data.json`: locked inputs, addresses and preflight snapshot;
- `transactions.json`: every real state-changing transaction and receipt status;
- `RESULTS.md`: observed result, evidence, failures, limitations and conclusion;
- `script-result.json`: generated only after the standard E2E broadcast succeeds;
- `broadcast.json`: generated Foundry transaction bundle copied after a successful broadcast.

Status vocabulary:

- `PLANNED`: specified but not started;
- `BLOCKED`: cannot proceed without a named prerequisite;
- `RUNNING`: transactions are in progress and the round is not yet conclusive;
- `PASSED`: expected result and receipt-backed evidence both exist;
- `FAILED`: observed behavior differs from the expected result;
- `NOT_RUN`: intentionally excluded from the round.

Private keys, mnemonics, Safe signatures, RPC credentials and wallet exports are forbidden in this directory. A transaction hash alone is not a pass: the receipt, emitted events and post-state must also match the case.

The standard user-path runner validates that `E2E_PRIVATE_KEY` derives exactly to `E2E_TEST_ACCOUNT` before broadcasting. Use only a disposable Testnet key and never paste it into chat or commit it. Governance, Emergency Safe, reorg and destructive incident tests use separate rounds because they require different signers and safety controls.
