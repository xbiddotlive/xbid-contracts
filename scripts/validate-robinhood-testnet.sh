#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="${FORGE_BIN:-forge}"
: "${ROBINHOOD_TESTNET_RPC_URL:?ROBINHOOD_TESTNET_RPC_URL is required}"

export DEPLOYMENT_MANIFEST_PATH="${1:-deployments/robinhood-testnet/latest.json}"
export REQUIRE_ACTIVATED="${REQUIRE_ACTIVATED:-true}"

"$FORGE_BIN" script script/ValidateRobinhoodTestnet.s.sol:ValidateRobinhoodTestnet \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL"
