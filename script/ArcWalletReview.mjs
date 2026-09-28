// Local-only, read-only review surface. No signing or transaction-sending methods.
// node script/ArcWalletReview.mjs /absolute/path/to/unsigned-review.json
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { createRequire } from "node:module";
const require = createRequire(new URL("../../frontend-nextjs/package.json", import.meta.url));
const { decodeFunctionData } = require("viem");
const draft = JSON.parse(readFileSync(process.argv[2], "utf8"));
assert.equal(draft.status, "UNSIGNED_DRAFT_NOT_DEPLOYED");
assert.equal(draft.chainId, 5042);
assert.equal(draft.transactions.length, 10);
const factoryAbi = JSON.parse(readFileSync(new URL("../out/XBIDFactory.sol/XBIDFactory.json", import.meta.url), "utf8")).abi;
const initialization = decodeFunctionData({ abi: factoryAbi, data: draft.transactions.find((tx) => tx.name === "ERC1967Proxy").constructorArgs[1] });
assert.equal(initialization.functionName, "initialize");
draft.reviewParameters = { creationTreasury: initialization.args[3] };
const files = {
  "/": ["text/html; charset=utf-8", readFileSync(new URL("arc-wallet-review/index.html", import.meta.url))],
  "/review.js": ["text/javascript; charset=utf-8", readFileSync(new URL("arc-wallet-review/review.js", import.meta.url))],
  "/review.json": ["application/json; charset=utf-8", Buffer.from(JSON.stringify(draft))],
};
const server = createServer((req, res) => {
  if (req.headers.host !== "127.0.0.1:3199" || req.method !== "GET" || !Object.hasOwn(files, req.url)) {
    res.writeHead(404); res.end(); return;
  }
  res.writeHead(200, { "Content-Type": files[req.url][0], "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer", "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'" });
  res.end(files[req.url][1]);
});
server.listen(3199, "127.0.0.1", () => console.log("XBID unsigned review: http://127.0.0.1:3199/ — wallet connection only; no signing or broadcast."));
