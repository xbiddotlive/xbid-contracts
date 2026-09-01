#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="${FORGE_BIN:-forge}"
ROUND_DIRECTORY="${1:?usage: scripts/run-robinhood-testnet-e2e.sh testnet-e2e/rounds/<round-id>}"

case "$ROUND_DIRECTORY" in
  testnet-e2e/rounds/*) ;;
  *) echo "ROUND_DIRECTORY must be under testnet-e2e/rounds/" >&2; exit 1 ;;
esac

: "${ROBINHOOD_TESTNET_RPC_URL:?ROBINHOOD_TESTNET_RPC_URL is required}"
: "${E2E_TEST_ACCOUNT:?E2E_TEST_ACCOUNT is required}"
: "${E2E_PRIVATE_KEY:?E2E_PRIVATE_KEY is required}"
: "${E2E_ROUND_ID:?E2E_ROUND_ID is required}"

if [[ "${CONFIRM_ROBINHOOD_TESTNET_E2E:-NO}" != "YES" ]]; then
  echo "Refusing broadcast: set CONFIRM_ROBINHOOD_TESTNET_E2E=YES after reviewing the round plan." >&2
  exit 1
fi

if [[ ! -d "$ROUND_DIRECTORY" ]]; then
  echo "Round directory does not exist: $ROUND_DIRECTORY" >&2
  exit 1
fi

if [[ "$ROUND_DIRECTORY" != "testnet-e2e/rounds/$E2E_ROUND_ID" ]]; then
  echo "Round directory and E2E_ROUND_ID do not match." >&2
  exit 1
fi

export E2E_RESULT_PATH="$ROUND_DIRECTORY/script-result.json"

"$FORGE_BIN" script script/RunRobinhoodTestnetE2E.s.sol:RunRobinhoodTestnetE2E \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
  --broadcast \
  --slow

cp broadcast/RunRobinhoodTestnetE2E.s.sol/46630/run-latest.json "$ROUND_DIRECTORY/broadcast.json"
