#!/usr/bin/env bash
set -euo pipefail

JQ_BIN="${JQ_BIN:-jq}"
MANIFEST_PATH="${1:-deployments/robinhood-testnet/timelock.json}"
BROADCAST_PATH="${TIMELOCK_BROADCAST_PATH:-broadcast/DeployRobinhoodTimelock.s.sol/46630/run-latest.json}"

if [[ ! -f "$MANIFEST_PATH" || ! -f "$BROADCAST_PATH" ]]; then
  echo "Timelock manifest and confirmed broadcast receipt are both required." >&2
  exit 1
fi

receipt_count="$("$JQ_BIN" -r '.receipts | length' "$BROADCAST_PATH")"
transaction_count="$("$JQ_BIN" -r '.transactions | length' "$BROADCAST_PATH")"
receipt_status="$("$JQ_BIN" -r '.receipts[0].status' "$BROADCAST_PATH")"
transaction_hash="$("$JQ_BIN" -r '.receipts[0].transactionHash' "$BROADCAST_PATH")"
broadcast_hash="$("$JQ_BIN" -r '.transactions[0].hash' "$BROADCAST_PATH")"
block_hex="$("$JQ_BIN" -r '.receipts[0].blockNumber' "$BROADCAST_PATH")"
contract_address="$("$JQ_BIN" -r '.transactions[0].contractAddress' "$BROADCAST_PATH")"
contract_name="$("$JQ_BIN" -r '.transactions[0].contractName' "$BROADCAST_PATH")"
transaction_type="$("$JQ_BIN" -r '.transactions[0].transactionType' "$BROADCAST_PATH")"
manifest_timelock="$("$JQ_BIN" -r '.timelock' "$MANIFEST_PATH")"

if [[ "$receipt_count" != "1" || "$transaction_count" != "1" || "$receipt_status" != "0x1" ]]; then
  echo "Expected exactly one successful Timelock deployment receipt." >&2
  exit 1
fi
if [[ "$transaction_hash" != "$broadcast_hash" || "$contract_name" != "TimelockController" || "$transaction_type" != "CREATE" ]]; then
  echo "Broadcast metadata is not the expected TimelockController creation." >&2
  exit 1
fi

shopt -s nocasematch
if [[ "$contract_address" != "$manifest_timelock" ]]; then
  echo "Broadcast contract address does not match Timelock manifest." >&2
  exit 1
fi
shopt -u nocasematch

block_number=$((block_hex))
temporary_path="$(mktemp "${MANIFEST_PATH}.XXXXXX")"
trap 'rm -f "$temporary_path"' EXIT

"$JQ_BIN" \
  --arg transactionHash "$transaction_hash" \
  --argjson deploymentBlock "$block_number" \
  '.status = "ACTIVE"
   | .deploymentTransactionHash = $transactionHash
   | .deploymentBlock = $deploymentBlock' \
  "$MANIFEST_PATH" > "$temporary_path"
mv "$temporary_path" "$MANIFEST_PATH"
trap - EXIT
