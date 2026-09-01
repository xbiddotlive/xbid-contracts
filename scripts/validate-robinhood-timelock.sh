#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="${FORGE_BIN:-forge}"

: "${ROBINHOOD_TESTNET_RPC_URL:?ROBINHOOD_TESTNET_RPC_URL is required}"

"$FORGE_BIN" script script/ValidateRobinhoodTimelock.s.sol:ValidateRobinhoodTimelock \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL"
