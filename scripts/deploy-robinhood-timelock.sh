#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="${FORGE_BIN:-forge}"
CAST_BIN="${CAST_BIN:-cast}"

: "${ROBINHOOD_TESTNET_RPC_URL:?ROBINHOOD_TESTNET_RPC_URL is required}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY is required}"

if [[ "${CONFIRM_ROBINHOOD_TIMELOCK_DEPLOYMENT:-}" != "YES" ]]; then
  echo "Set CONFIRM_ROBINHOOD_TIMELOCK_DEPLOYMENT=YES after confirming both Safe configurations." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to deploy Timelock from a dirty worktree." >&2
  exit 1
fi

chain_id="$($CAST_BIN chain-id --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
if [[ "$chain_id" != "46630" ]]; then
  echo "Wrong chain ID: expected 46630, got $chain_id" >&2
  exit 1
fi

deployer="$($CAST_BIN wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
balance="$($CAST_BIN balance "$deployer" --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
if [[ "$balance" == "0" ]]; then
  echo "Deployer $deployer has no testnet ETH for gas." >&2
  exit 1
fi

export SOURCE_COMMIT="$(git rev-parse HEAD)"
export TIMELOCK_OUTPUT_PATH="${TIMELOCK_OUTPUT_PATH:-deployments/robinhood-testnet/timelock.json}"

"$FORGE_BIN" script script/DeployRobinhoodTimelock.s.sol:DeployRobinhoodTimelock \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
  --broadcast \
  --slow
