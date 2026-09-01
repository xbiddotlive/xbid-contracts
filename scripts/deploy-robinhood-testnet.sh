#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="${FORGE_BIN:-forge}"
CAST_BIN="${CAST_BIN:-cast}"

: "${ROBINHOOD_TESTNET_RPC_URL:?ROBINHOOD_TESTNET_RPC_URL is required}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY is required}"
: "${XBID_GOVERNANCE_TIMELOCK:?XBID_GOVERNANCE_TIMELOCK is required}"
: "${XBID_EMERGENCY_ROLE:?XBID_EMERGENCY_ROLE is required}"
: "${XBID_TEAM_TREASURY:?XBID_TEAM_TREASURY is required}"
: "${XBID_PROTOCOL_TREASURY:?XBID_PROTOCOL_TREASURY is required}"

if [[ "${CONFIRM_ROBINHOOD_TESTNET_DEPLOYMENT:-}" != "YES" ]]; then
  echo "Set CONFIRM_ROBINHOOD_TESTNET_DEPLOYMENT=YES after completing the runbook review." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to deploy from a dirty worktree." >&2
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
export DEPLOYMENT_OUTPUT_PATH="${DEPLOYMENT_OUTPUT_PATH:-deployments/robinhood-testnet/latest.json}"

"$FORGE_BIN" script script/DeployRobinhoodTestnet.s.sol:DeployRobinhoodTestnet \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
  --broadcast \
  --slow
