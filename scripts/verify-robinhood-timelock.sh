#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="${FORGE_BIN:-forge}"
CAST_BIN="${CAST_BIN:-cast}"
JQ_BIN="${JQ_BIN:-jq}"
MANIFEST="${1:-deployments/robinhood-testnet/timelock.json}"
VERIFIER_URL="${ROBINHOOD_TESTNET_BLOCKSCOUT_API_URL:-https://explorer.testnet.chain.robinhood.com/api/}"

: "${ROBINHOOD_TESTNET_RPC_URL:?ROBINHOOD_TESTNET_RPC_URL is required}"

chain_id="$($CAST_BIN chain-id --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
manifest_chain="$($JQ_BIN -er '.chainId' "$MANIFEST")"
status="$($JQ_BIN -er '.status' "$MANIFEST")"
if [[ "$chain_id" != "46630" || "$manifest_chain" != "46630" || "$status" != "ACTIVE" ]]; then
  echo "RPC and finalized Timelock manifest must identify active Robinhood Testnet deployment." >&2
  exit 1
fi

timelock="$($JQ_BIN -er '.timelock' "$MANIFEST")"
governance="$($JQ_BIN -er '.governanceSafe' "$MANIFEST")"
delay="$($JQ_BIN -er '.minimumDelaySeconds' "$MANIFEST")"
constructor_args="$($CAST_BIN abi-encode 'constructor(uint256,address[],address[],address)' \
  "$delay" "[$governance]" "[$governance]" 0x0000000000000000000000000000000000000000)"

"$FORGE_BIN" verify-contract \
  "$timelock" \
  lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController \
  --chain-id 46630 \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
  --verifier blockscout \
  --verifier-url "$VERIFIER_URL" \
  --constructor-args "$constructor_args" \
  --watch
