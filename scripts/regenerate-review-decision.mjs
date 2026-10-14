#!/usr/bin/env node
// Regenerate compact canonical fixtures and their runtime/plugin identity pins.
// --check verifies reproducibility without writing; retired identities remain binding-only.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = new URL("../", import.meta.url);
const args = process.argv.slice(2);
if (args.length > 1 || (args.length === 1 && args[0] !== "--check")) {
  throw new Error("usage: regenerate-review-decision.mjs [--check]");
}
const check = args[0] === "--check";
const read = (path) => readFileSync(new URL(path, root), "utf8");
const canonical = (value) => {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])]),
    );
  }
  return value;
};
const encode = (value) => JSON.stringify(canonical(value));
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const contractPath = "tests/fixtures/review-decision/v1/contract.json";
const corpusPath = "tests/fixtures/review-decision/v1/corpus.json";
const contract = JSON.parse(read(contractPath));
const corpus = JSON.parse(read(corpusPath));
contract.reasons = [...new Set(contract.reasons)].sort();
for (const entry of corpus.cases) {
  if (!contract.reasons.includes(entry.expected.reason)) {
    throw new Error(`unknown corpus reason: ${entry.expected.reason}`);
  }
}
const contractBytes = encode(contract);
const corpusBytes = encode(corpus);
const contractDigest = digest(contractBytes);
const corpusDigest = digest(corpusBytes);
let lib = read("lib/pro-gate-lib.sh");
const replacePin = (name, value) => {
  const pattern = new RegExp(`^${name}='([^']*)'`, "m");
  const match = lib.match(pattern);
  if (!match) throw new Error(`missing identity pin: ${name}`);
  lib = lib.replace(pattern, `${name}='${value}'`);
  return match[1];
};
const previous = replacePin(
  "PG_REVIEW_DECISION_CONTRACT_DIGEST",
  contractDigest,
);
replacePin("PG_REVIEW_DECISION_CORPUS_DIGEST", corpusDigest);
if (previous !== contractDigest) {
  const name = "PG_REVIEW_DECISION_COMPATIBLE_CONTRACT_DIGESTS";
  const compatible = lib.match(new RegExp(`^${name}='([^']*)'`, "m"))?.[1];
  if (compatible === undefined)
    throw new Error("missing binding compatibility pin");
  replacePin(
    name,
    [...new Set([...compatible.split(" "), previous])].join(" "),
  );
}
const identity = encode({
  contract_digest: contractDigest,
  contract_id: contract.contract_id,
  contract_version: contract.contract_version,
  corpus_digest: corpusDigest,
});
for (const [path, bytes] of [
  [contractPath, contractBytes],
  [corpusPath, corpusBytes],
  ["lib/pro-gate-lib.sh", lib],
  ["skills/pro-gate/review-decision-v1.json", identity],
]) {
  if (check) {
    if (read(path) !== bytes)
      throw new Error(`stale generated metadata: ${path}`);
  } else writeFileSync(fileURLToPath(new URL(path, root)), bytes);
}
process.stdout.write(
  `review-decision fixtures: ${check ? "verified" : "regenerated"} (${corpus.cases.length} cases)\n`,
);
