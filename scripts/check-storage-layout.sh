#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="${FORGE_BIN:-forge}"
SNAPSHOT="deployments/storage-layout/XBIDFactory.v1.json"
EXPECTED_NAMESPACE="0x2cdc82a277d9c9278933e3b9cae03f832da8b0dbfd0f5b103169073c57d12f00"

command -v "$FORGE_BIN" >/dev/null 2>&1 || {
  echo "forge not found; set FORGE_BIN or add Foundry to PATH" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required" >&2
  exit 1
}

jq -e \
  --arg namespace "$EXPECTED_NAMESPACE" \
  '.snapshotVersion == 1
   and .contract == "XBIDFactory"
   and .namespace == "xbid.storage.XBIDFactory"
   and .namespaceSlot == $namespace
   and (.fields | length) == 5
   and .fields[0] == {"name":"governanceTimelock","type":"address","slotIndex":0,"offsetBytes":0,"sizeBytes":20}
   and .fields[1] == {"name":"settlementToken","type":"address","slotIndex":1,"offsetBytes":0,"sizeBytes":20}
   and .fields[2] == {"name":"marketRegistry","type":"IMarketRegistry","slotIndex":2,"offsetBytes":0,"sizeBytes":20}
   and .fields[3] == {"name":"teamTreasury","type":"address","slotIndex":3,"offsetBytes":0,"sizeBytes":20}
   and .fields[4] == {"name":"defaultMarketVersion","type":"uint32","slotIndex":3,"offsetBytes":20,"sizeBytes":4}' \
  "$SNAPSHOT" >/dev/null

# solc reports ERC-7201 assembly-backed storage as empty, so the authoritative
# check executes getters against raw namespaced slots and verifies namespace isolation.
layout="$($FORGE_BIN inspect XBIDFactory storageLayout --json)"
jq -e '.storage == [] and .types == {}' <<<"$layout" >/dev/null
$FORGE_BIN test --match-path test/unit/XBIDFactoryStorageLayout.t.sol
