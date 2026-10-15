#!/usr/bin/env node
// Canonicalize decision fixtures and regenerate every runtime/plugin identity pin.
// Optional --additions <json> accepts additive {reasons:[],cases:[]} fixture declarations.
// --check verifies reproducibility without writing files.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const args = process.argv.slice(2);
const check = args.includes("--check");
let additions = { reasons: [], cases: [] };
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--check") continue;
  if (args[i] !== "--additions" || !args[i + 1]) {
    throw new Error(
      "usage: regenerate-review-decision.mjs [--additions <json>] [--check]",
    );
  }
  additions = JSON.parse(readFileSync(resolve(args[++i]), "utf8"));
}
const read = (path) => readFileSync(resolve(root, path), "utf8");
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
contract.reasons = [
  ...new Set([...contract.reasons, ...(additions.reasons ?? [])]),
].sort();
for (const entry of additions.cases ?? []) {
  const existing = corpus.cases.find((item) => item.name === entry.name);
  if (existing) {
    if (encode(existing) !== encode(entry))
      throw new Error(`conflicting case: ${entry.name}`);
  } else corpus.cases.push(entry);
}
for (const entry of corpus.cases) {
  if (!contract.reasons.includes(entry.expected.reason))
    throw new Error(`unknown reason: ${entry.expected.reason}`);
}
const contractBytes = encode(contract);
const corpusBytes = encode(corpus);
const contractDigest = digest(contractBytes);
const corpusDigest = digest(corpusBytes);
let lib = read("lib/pro-gate-lib.sh");
const replacePin = (name, value) => {
  const pattern = new RegExp(`^${name}='([^']*)'`, "m");
  if (!pattern.test(lib)) throw new Error(`missing identity pin: ${name}`);
  const previous = lib.match(pattern)[1];
  lib = lib.replace(pattern, `${name}='${value}'`);
  return previous;
};
const previous = replacePin(
  "PG_REVIEW_DECISION_CONTRACT_DIGEST",
  contractDigest,
);
replacePin("PG_REVIEW_DECISION_CORPUS_DIGEST", corpusDigest);
// This additive metadata update preserves predecessor binding reads, never old envelopes.
if (previous !== contractDigest) {
  const name = "PG_REVIEW_DECISION_COMPATIBLE_CONTRACT_DIGESTS";
  const prior = lib.match(new RegExp(`^${name}='([^']*)'`, "m"))?.[1];
  if (prior === undefined) throw new Error("missing binding compatibility pin");
  replacePin(name, [...new Set([...prior.split(" "), previous])].join(" "));
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
  } else writeFileSync(resolve(root, path), bytes);
}
process.stdout.write(
  `review-decision fixtures: ${check ? "verified" : "regenerated"} (${corpus.cases.length} cases)\n`,
);
