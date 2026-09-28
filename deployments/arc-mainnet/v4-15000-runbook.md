# Arc V4: 15,000 USDC crown activation

Status: source prepared; NOT deployed or activated by this document.

Scope: deploy one new immutable `MarketVaultV4`, append version 4 using existing
V3 bindings, then make V4 the Factory default. No proxy upgrade, role transfer,
fee change, database reset or legacy contest migration. V1-V3 stay immutable.
The 15,000 threshold is curve reserve (6-decimal units: 15000000000), not volume.
Trading math, fees, crown dominance boundaries and 60-second hold are unchanged.

## Checks and preparation

1. `forge test --offline`
2. `FOUNDRY_DYNAMIC_TEST_LINKING=false forge build --offline --skip-lint`
3. `node --test script/MarketV4Scope.test.mjs`
4. Commit and push the reviewed source; ensure HEAD equals origin/main.
5. Use a new private temporary directory, never overwrite the initial journals:
   `node script/PrepareArcMarketV4.mjs /absolute/new-directory/review.json`
6. Start the deployment-only page:
   `node script/ArcWalletDeploy.mjs /absolute/new-directory/review.json /absolute/new-directory/deployment-receipts.json 3196`

The preparation and coordinator only perform read RPC calls against Arc 5042.
The user must open http://127.0.0.1:3196/ in Brave, select the deployer wallet,
review the single V4 deployment and explicitly confirm the transaction.
The approved 1.5 USDC cumulative cap includes the previous 0.467219255020537485
USDC deployment/activation gas; subsequent governance gas is additional within
that same budget. Above-budget spending requires separate user approval.

## Activation and application release

Before making V4 the default, release frontend/backend version-4 pricing
support (same curve parameters as V3). The indexer uses generic version IDs and
unchanged V3-compatible events; do not reset/reindex existing data.

After verifying the deployment receipt, start a separate governance journal:
`node script/ArcGovernance.mjs /absolute/new-directory/review.json /absolute/new-directory/deployment-receipts.json /absolute/new-directory/governance-journal.json 3195`

Only two batch calls are allowed: register V4 and set default version 4.
The existing governance Safe requires two distinct owners. The user explicitly
signs/sends the schedule stage, waits 600 seconds, then signs/sends execute.
Neither server signs, broadcasts nor automatically activates anything.

After execution verify versionCount=4, defaultMarketVersion=4, the V4 code hash
and getter=15000000000, and legacy version bindings unchanged. Then publish the
mainnet 15,000-USDC explanation with explicit legacy-rule preservation; leave
testnet dictionaries at their actual on-chain threshold. Check public homepage,
how-it-works/docs, create flow, backend health and indexer readiness. Record actual
receipts and release commits without marking a simulated rehearsal as mainnet
acceptance. Production signing/trading smoke tests require the user's wallet.
