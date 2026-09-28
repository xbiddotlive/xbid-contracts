import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');
test('V4 differs from V2/V3 only in identity and crown activation threshold', () => {
  const expected = read('../src/core/MarketVaultV2.sol')
    .replace('Market Version 2 implementation for', 'Market Version 4 implementation (V3 trading math; 15,000 USDC activation) for')
    .replace('contract MarketVaultV2 ', 'contract MarketVaultV4 ')
    .replace('CROWN_ACTIVATION_RESERVE_UNITS = 70_000_000_000', 'CROWN_ACTIVATION_RESERVE_UNITS = 15_000_000_000')
    .replace('return 2;', 'return 4;');
  assert.equal(read('../src/core/MarketVaultV4.sol'), expected);
  assert.match(read('../src/core/MarketVaultV3.sol'), /is MarketVaultV2/);
});

test('V4 retains the V3 runtime ABI and method selectors', () => {
  const v3 = JSON.parse(read('../out/MarketVaultV3.sol/MarketVaultV3.json'));
  const v4 = JSON.parse(read('../out/MarketVaultV4.sol/MarketVaultV4.json'));
  const normalize = abi => JSON.parse(JSON.stringify(abi.filter(entry => entry.type !== 'constructor')).replaceAll('MarketVaultV3', 'MarketVault').replaceAll('MarketVaultV2', 'MarketVault').replaceAll('MarketVaultV4', 'MarketVault'));
  assert.deepEqual(normalize(v4.abi), normalize(v3.abi));
  assert.deepEqual(v4.methodIdentifiers, v3.methodIdentifiers);
});
