#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="${FORGE_BIN:-forge}"
CAST_BIN="${CAST_BIN:-cast}"
JQ_BIN="${JQ_BIN:-jq}"
MANIFEST="${1:-deployments/robinhood-testnet/latest.json}"
VERIFIER_URL="${ROBINHOOD_TESTNET_BLOCKSCOUT_API_URL:-https://explorer.testnet.chain.robinhood.com/api/}"

: "${ROBINHOOD_TESTNET_RPC_URL:?ROBINHOOD_TESTNET_RPC_URL is required}"

chain_id="$($CAST_BIN chain-id --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
manifest_chain="$($JQ_BIN -er '.chainId' "$MANIFEST")"
if [[ "$chain_id" != "46630" || "$manifest_chain" != "46630" ]]; then
  echo "RPC and manifest must both use Robinhood Testnet chain ID 46630." >&2
  exit 1
fi

value() {
  "$JQ_BIN" -er ".$1" "$MANIFEST"
}

verify() {
  local address="$1"
  local contract="$2"
  local constructor_args="${3:-}"
  local args=(
    "$address"
    "$contract"
    --chain-id 46630
    --rpc-url "$ROBINHOOD_TESTNET_RPC_URL"
    --verifier blockscout
    --verifier-url "$VERIFIER_URL"
    --watch
  )
  if [[ -n "$constructor_args" ]]; then
    args+=(--constructor-args "$constructor_args")
  fi
  "$FORGE_BIN" verify-contract "${args[@]}"
}

deployer="$(value deployer)"
governance="$(value governanceTimelock)"
emergency="$(value emergencyRole)"
protocol="$(value protocolTreasury)"
settlement="$(value settlementToken)"
registry="$(value marketRegistry)"
risk="$(value riskController)"
fee_vault="$(value feeVault)"
market_impl="$(value marketVaultImplementation)"
side_impl="$(value sideTokenImplementation)"
factory_impl="$(value factoryImplementation)"
factory_proxy="$(value factoryProxy)"
team="$(value teamTreasury)"

registry_args="$($CAST_BIN abi-encode 'constructor(address,address)' "$governance" "$deployer")"
risk_args="$($CAST_BIN abi-encode 'constructor(uint32,address,address)' 1 "$governance" "$emergency")"
fee_args="$($CAST_BIN abi-encode 'constructor(uint32,address,address,address,address,address,uint16,uint16,uint16)' \
  1 "$settlement" "$registry" "$governance" "$emergency" "$protocol" 7000 2000 1000)"
initializer="$($CAST_BIN calldata 'initialize(address,address,address,address)' \
  "$governance" "$settlement" "$registry" "$team")"
proxy_args="$($CAST_BIN abi-encode 'constructor(address,bytes)' "$factory_impl" "$initializer")"

verify "$registry" src/core/MarketRegistry.sol:MarketRegistry "$registry_args"
verify "$risk" src/core/RiskController.sol:RiskController "$risk_args"
verify "$fee_vault" src/core/FeeVault.sol:FeeVault "$fee_args"
verify "$market_impl" src/core/MarketVault.sol:MarketVault
verify "$side_impl" src/core/SideToken.sol:SideToken
verify "$factory_impl" src/core/XBIDFactory.sol:XBIDFactory
verify "$factory_proxy" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy "$proxy_args"
