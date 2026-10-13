#!/usr/bin/env node
// @ts-check
/**
 * Optional GitHub status adapter. Accepted public review facts establish review truth;
 * recording and verification bind it to an exact revision and default-base identity.
 * Exit 0 is an advisory check, never merge authorization. Owner exceptions stay downstream.
 */
import { execFileSync } from "node:child_process";
import {
  lstatSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

/** Stable context for consumers that opt into GitHub status integration. */
export const STATUS_CONTEXT = "Pro-Gate Verdict";

/** The only verdict that records a passing status. */
export const SHIP_VERDICT = "SHIP";

/** GitHub truncates (and pro-gate's own review comments favor) a 140-char cap
 * on a commit status description. */
export const DESCRIPTION_MAX_LENGTH = 140;

/** How many hex characters of the base SHA get embedded in the description.
 * Short enough to leave room for the evidence URL, long enough (48 bits) that
 * a collision within one repo's history is not a realistic concern. */
export const BASE_SHA_LENGTH = 12;

export class UsageError extends Error {}

const USAGE = `Usage:
  node record-pro-gate-verdict.mjs --pr <n> --verdict <SHIP|...> --reviewed-sha <sha> --evidence <url>
  node record-pro-gate-verdict.mjs --verify-for-merge --pr <n>

Record mode (default):
  --pr             Pull request number.
  --verdict        Accepted public verdict assertion. Current "SHIP" records
                    success; accepted FIX-FIRST/NEEDS-DISCUSSION record failure.
  --reviewed-sha   The commit SHA the pro-gate engine actually reviewed. If
                    the PR's current head has moved past this, the recorder
                    refuses and posts nothing.
  --evidence       URL of the posted review comment/report. Used as the
                    status target_url and, possibly truncated, in its
                    description.

Verify mode:
  --verify-for-merge   Run before merging, instead of recording: checks that
                        the PR's current head carries a success status AND
                        that the base hasn't advanced with changes that
                        overlap this PR's own changed files since that status
                        was recorded. Exit 0 = advisory check passed. Exit 1 =
                        re-review required.
  --pr                 Pull request number.

Proof inputs (record mode):
  --diff               Reviewed payload; defaults to the prepared full-PR endpoint.
  --confirm            Prior review required by scoped proof. Its filtering manifest
                        is supplied through PRO_GATE_REVIEW_FILTER_MANIFEST.
  --input              Existing public proof mode: bundle (default), both, or connector.
                        Connector progress can record failure, never successful SHIP.

--owner-state is not supported. Owner merge dispositions remain downstream.`;

const REQUIRED_RECORD_FLAGS = /** @type {const} */ ([
  ["--pr", "pr"],
  ["--verdict", "verdict"],
  ["--reviewed-sha", "reviewedSha"],
  ["--evidence", "evidence"],
]);

/**
 * @typedef {{mode: 'record', pr: number, verdict: string, reviewedSha: string, evidence: string, diff?: string, confirm?: string, input?: string}} RecordArgs
 * @typedef {{mode: 'verify', pr: number}} VerifyModeArgs
 * @typedef {RecordArgs | VerifyModeArgs} Args
 */

/**
 * Parses argv into either record-mode or verify-mode args. `--verify-for-merge`
 * switches the whole parse: in that mode only `--pr` is required, and the
 * four record-mode flags (even if present) are ignored, since verifying
 * doesn't take a verdict to record.
 *
 * @param {string[]} argv
 * @returns {Args}
 */
export function parseArgs(argv) {
  if (
    argv.some(
      (arg) => arg === "--owner-state" || arg.startsWith("--owner-state="),
    )
  ) {
    throw new UsageError(
      "--owner-state is not supported; owner merge policy remains downstream.",
    );
  }
  if (argv.includes("--verify-for-merge")) return parseVerifyModeArgs(argv);
  return parseRecordArgs(argv);
}

/**
 * @param {string[]} argv
 * @returns {RecordArgs}
 */
function parseRecordArgs(argv) {
  /** @type {Record<string, string>} */
  const raw = {};

  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    const flag = [
      ...REQUIRED_RECORD_FLAGS,
      ["--diff", "diff"],
      ["--confirm", "confirm"],
      ["--input", "input"],
    ].find(([name]) => name === token);
    if (!flag) continue;

    const value = argv[i + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new UsageError(`${token} requires a value.\n\n${USAGE}`);
    }

    raw[flag[1]] = value;
    i++;
  }

  const missing = REQUIRED_RECORD_FLAGS.filter(([, key]) => !raw[key]).map(
    ([flag]) => flag,
  );
  if (missing.length) {
    throw new UsageError(
      `missing required argument(s): ${missing.join(", ")}\n\n${USAGE}`,
    );
  }

  const pr = Number(raw.pr);
  if (!Number.isInteger(pr) || pr <= 0) {
    throw new UsageError(`--pr must be a positive integer, got: ${raw.pr}`);
  }

  return {
    mode: "record",
    pr,
    verdict: /** @type {string} */ (raw.verdict),
    reviewedSha: /** @type {string} */ (raw.reviewedSha),
    evidence: /** @type {string} */ (raw.evidence),
    ...(raw.diff === undefined ? {} : { diff: raw.diff }),
    ...(raw.confirm === undefined ? {} : { confirm: raw.confirm }),
    ...(raw.input === undefined ? {} : { input: raw.input }),
  };
}

/**
 * @param {string[]} argv
 * @returns {VerifyModeArgs}
 */
function parseVerifyModeArgs(argv) {
  /** @type {string | undefined} */
  let prRaw;

  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag !== "--pr") continue;
    const value = argv[i + 1];
    if (!value?.trim() || value.startsWith("--")) {
      throw new UsageError(`${flag} requires a value.\n\n${USAGE}`);
    }
    prRaw = value;
    i++;
  }

  if (!prRaw) {
    throw new UsageError(`missing required argument(s): --pr\n\n${USAGE}`);
  }

  const pr = Number(prRaw);
  if (!Number.isInteger(pr) || pr <= 0) {
    throw new UsageError(`--pr must be a positive integer, got: ${prRaw}`);
  }

  return {
    mode: "verify",
    pr,
  };
}

/**
 * `SHIP` maps to `success`. Everything else -- `NO-SHIP`, `BLOCKED`, a typo,
 * an empty string -- maps to `failure`. There is no third state: an unrecorded
 * or ambiguous verdict must never read as passing.
 *
 * @param {string} verdict
 * @returns {'success' | 'failure'}
 */
export function stateForVerdict(verdict) {
  return verdict === SHIP_VERDICT ? "success" : "failure";
}

/**
 * @param {Date} date
 * @returns {string} calendar date, e.g. "2026-08-16"
 */
export function isoDate(date) {
  return date.toISOString().slice(0, 10);
}

/**
 * Builds the status description, truncated to fit GitHub's 140-character cap.
 *
 * Truncation keeps the `<verdict> · base <repo>@<ref>@<sha> · recorded
 * <date> · ` prefix intact and shortens only the evidence URL, appending an
 * ellipsis so a shortened description can never be mistaken for a complete
 * (and therefore wrong) URL. The full, untruncated evidence URL still goes
 * out as `target_url` -- truncation only ever affects this description
 * string, and the evidence URL is always what shortens first: identity
 * fields (repo, ref, SHA) are never dropped or abbreviated further to make
 * room.
 *
 * The base repo, ref, AND SHA are all embedded (not just the SHA) so
 * `--verify-for-merge` can later tell not only whether the base advanced,
 * but whether the PR is even still pointed at the base repo/ref the verdict
 * was recorded against -- a retarget changes the merge diff completely
 * without necessarily touching the head SHA at all.
 *
 * Assumes `baseRepo` and `baseRef` never contain a literal `@` -- true for
 * every GitHub owner/repo and branch name in practice (GitHub restricts
 * owner/repo to alphanumerics, hyphens, underscores, and dots; a bare `@` in
 * a ref name, while not forbidden by git the way `@{` is, is not something
 * any tooling here produces). `parseRecordedBase` below relies on the same
 * assumption to split the three `@`-joined fields back apart unambiguously.
 *
 * @param {{verdict: string, baseRepo: string, baseRef: string, baseSha: string, evidence: string, now: Date}} args
 * @returns {string}
 */
export function buildDescription({
  verdict,
  baseRepo,
  baseRef,
  baseSha,
  evidence,
  now,
}) {
  const shortBase = baseSha.slice(0, BASE_SHA_LENGTH);
  const prefix = `${verdict} · base ${baseRepo}@${baseRef}@${shortBase} · recorded ${isoDate(now)} · `;
  const full = `${prefix}${evidence}`;
  if (full.length <= DESCRIPTION_MAX_LENGTH) return full;

  const ellipsis = "…";
  const room = DESCRIPTION_MAX_LENGTH - prefix.length - ellipsis.length;

  // Degenerate case: even the verdict/base/date prefix alone doesn't fit.
  // Hard-cut the whole string rather than produce a negative-length slice.
  if (room < 0) {
    return full.slice(0, DESCRIPTION_MAX_LENGTH - ellipsis.length) + ellipsis;
  }

  return prefix + evidence.slice(0, room) + ellipsis;
}

const BASE_RE = / · base ([^@]+)@([^@]+)@([0-9a-f]{12}) · /;

/**
 * @typedef {{repo: string, ref: string, sha: string}} RecordedBase
 */

/**
 * Extracts the base repo, ref, and SHA a status description recorded, per
 * `buildDescription`'s format. The base segment sits in the prefix, which
 * truncation never touches (only the evidence URL shortens), so this is
 * exact whenever it matches at all.
 *
 * Returns `null` for anything that doesn't match -- including descriptions
 * recorded by a pre-base-binding (or pre-repo/ref-binding) version of this
 * script, which is a real case: a status recorded before this change has no
 * base segment (or only a bare SHA) in it, and `--verify-for-merge` must
 * treat that as "can't verify", not as if the base were unknown-but-fine.
 *
 * @param {string} description
 * @returns {RecordedBase | null}
 */
export function parseRecordedBase(description) {
  const m = BASE_RE.exec(description);
  if (!m) return null;
  return {
    repo: /** @type {string} */ (m[1]),
    ref: /** @type {string} */ (m[2]),
    sha: /** @type {string} */ (m[3]),
  };
}

/**
 * The set of files present in both lists, deduped and sorted for a stable,
 * readable error message. Order and duplicates in the inputs don't matter --
 * this only answers "do these two change sets touch anything in common".
 *
 * @param {string[]} a
 * @param {string[]} b
 * @returns {string[]}
 */
export function intersectFiles(a, b) {
  const setB = new Set(b);
  return [...new Set(a)].filter((f) => setB.has(f)).sort();
}

/**
 * Case- and whitespace-insensitive SHA comparison. GitHub returns lowercase
 * hex, but a value typed or pasted by an operator should not fail the
 * equality check on case alone.
 *
 * @param {string} a
 * @param {string} b
 * @returns {boolean}
 */
export function shasEqual(a, b) {
  return (
    typeof a === "string" &&
    typeof b === "string" &&
    a.trim().toLowerCase() === b.trim().toLowerCase()
  );
}

const GITHUB_REMOTE_RE = /github\.com[:/]([^/]+)\/([^/]+?)(?:\.git)?\/?$/;

/**
 * Parses `owner/repo` out of a git remote URL, SSH or HTTPS.
 *
 * @param {string} url
 * @returns {{owner: string, repo: string} | null}
 */
export function parseGitHubRemote(url) {
  const m = GITHUB_REMOTE_RE.exec(url.trim());
  if (!m) return null;
  return {
    owner: /** @type {string} */ (m[1]),
    repo: /** @type {string} */ (m[2]),
  };
}

/** @typedef {{headSha: string, baseRef: string, baseRepo: string}} PrInfo */
/** @typedef {{repo: string, ref: string, sha: string}} ProofBase */
/**
 * @typedef {{facts: unknown, base: ProofBase}} ReviewProof
 * @typedef {{pr: number, verdict: string, reviewedSha: string, evidence: string,
 *   repoSlug?: string,
 *   getReviewFacts?: (pr: number) => Promise<ReviewProof> | ReviewProof,
 *   getPrInfo: (pr: number) => Promise<PrInfo> | PrInfo,
 *   getDefaultBranch: () => Promise<string> | string,
 *   getLiveBaseTip: (ref: string) => Promise<string> | string,
 *   postStatus: (args: {sha: string, state: 'success' | 'failure', description: string, targetUrl: string, context: string}) => Promise<void> | void,
 *   now?: () => Date, log?: (msg: string) => void, error?: (msg: string) => void}} RunArgs
 */

/** @param {unknown} value @returns {value is Record<string, unknown>} */
function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
/** @param {unknown} value @returns {value is string} */
function fullSha(value) {
  return typeof value === "string" && /^[0-9a-f]{40}$/i.test(value);
}
/** @param {unknown} value @returns {value is string} */
function digest(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/i.test(value);
}
/** @param {unknown} value @returns {value is number} */
function count(value) {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

/**
 * Assertions supplied on the command line are not review evidence. Only the public
 * reader can accept retained artifacts; the adapter checks its exact current target
 * and the base of the proof supplied to that reader against live GitHub identity.
 * @param {ReviewProof} proof
 * @param {{pr: number, verdict: string, head: string, repo: string, ref: string, base: string}} expected
 */
function proofMatches(proof, expected) {
  const facts = proof?.facts;
  if (
    !isObject(facts) ||
    !isObject(facts.repository) ||
    !isObject(facts.review)
  )
    return false;
  const review = facts.review;
  return (
    facts.schema === "review-facts/v1" &&
    facts.status === "accepted" &&
    facts.applicable === true &&
    facts.pr === expected.pr &&
    facts.repository.host === "github.com" &&
    `${facts.repository.owner}/${facts.repository.repo}`.toLowerCase() ===
      expected.repo.toLowerCase() &&
    fullSha(facts.candidate_head) &&
    shasEqual(facts.candidate_head, expected.head) &&
    typeof facts.selected_marker === "string" &&
    facts.selected_marker.startsWith("pg-run-") &&
    fullSha(review.reviewed_head) &&
    shasEqual(review.reviewed_head, expected.head) &&
    digest(review.canonical_identity) &&
    digest(review.artifact_digest) &&
    typeof review.evidence_identity === "string" &&
    review.evidence_identity.length > 0 &&
    count(review.charged_spend_epoch) &&
    review.charged_spend_epoch > 0 &&
    ["full-pr", "scoped-delta", "connector"].includes(
      String(review.evidence_mode),
    ) &&
    ["SHIP", "FIX-FIRST", "NEEDS-DISCUSSION"].includes(
      String(review.verdict),
    ) &&
    review.verdict === expected.verdict &&
    count(review.open_p0) &&
    count(review.open_p1) &&
    (expected.verdict !== SHIP_VERDICT ||
      (["full-pr", "scoped-delta"].includes(String(review.evidence_mode)) &&
        review.named_choice === null &&
        Array.isArray(review.named_choices) &&
        review.named_choices.length === 0)) &&
    isObject(proof.base) &&
    typeof proof.base.repo === "string" &&
    proof.base.repo.toLowerCase() === expected.repo.toLowerCase() &&
    proof.base.ref === expected.ref &&
    fullSha(proof.base.sha) &&
    shasEqual(proof.base.sha, expected.base)
  );
}

/** Record exactly one status only after validating accepted, current public facts.
 * @param {RunArgs} args @returns {Promise<{ok: boolean}>}
 */
export async function run({
  pr,
  verdict,
  reviewedSha,
  evidence,
  repoSlug,
  getReviewFacts,
  getPrInfo,
  getDefaultBranch,
  getLiveBaseTip,
  postStatus,
  now = () => new Date(),
  log = console.log,
  error = console.error,
}) {
  const { headSha, baseRef, baseRepo } = await getPrInfo(pr);
  const defaultBranch = await getDefaultBranch();
  if (baseRef !== defaultBranch) {
    error(
      `PR #${pr} targets "${baseRef}", not the default branch ("${defaultBranch}"). Posting nothing.`,
    );
    return { ok: false };
  }
  if (!shasEqual(headSha, reviewedSha)) {
    error(
      `PR #${pr}'s current head (${headSha}) does not match --reviewed-sha (${reviewedSha}). Re-run the review. Posting nothing.`,
    );
    return { ok: false };
  }
  if (!getReviewFacts) {
    error(
      "Accepted public review facts are required; assertions alone cannot record a status.",
    );
    return { ok: false };
  }
  const liveBaseSha = await getLiveBaseTip(baseRef);
  const expectedRepo = repoSlug ?? baseRepo;
  const proof = await getReviewFacts(pr);
  if (
    baseRepo.toLowerCase() !== expectedRepo.toLowerCase() ||
    !proofMatches(proof, {
      pr,
      verdict,
      head: headSha,
      repo: expectedRepo,
      ref: baseRef,
      base: liveBaseSha,
    })
  ) {
    error(
      "Public review facts or proof do not match the asserted verdict, current head and live default base. Posting nothing.",
    );
    return { ok: false };
  }
  const finalBaseSha = await getLiveBaseTip(baseRef);
  const recheck = await getPrInfo(pr);
  if (
    !shasEqual(recheck.headSha, headSha) ||
    recheck.baseRef !== baseRef ||
    recheck.baseRepo !== baseRepo ||
    !shasEqual(finalBaseSha, liveBaseSha) ||
    (await getDefaultBranch()) !== defaultBranch
  ) {
    error(
      `PR #${pr} changed while recording: head or base moved. Posting nothing; re-run fresh.`,
    );
    return { ok: false };
  }
  const state = stateForVerdict(verdict);
  const description = buildDescription({
    verdict,
    baseRepo,
    baseRef,
    baseSha: liveBaseSha,
    evidence,
    now: now(),
  });
  // Refuse identities that the stable description format cannot represent exactly.
  const recorded = parseRecordedBase(description);
  if (
    !recorded ||
    recorded.repo !== baseRepo ||
    recorded.ref !== baseRef ||
    recorded.sha !== liveBaseSha.slice(0, BASE_SHA_LENGTH).toLowerCase()
  ) {
    error("Base identity cannot fit the status description. Posting nothing.");
    return { ok: false };
  }
  await postStatus({
    sha: headSha,
    state,
    description,
    targetUrl: evidence,
    context: STATUS_CONTEXT,
  });
  log(
    `recorded ${verdict} (${state}) for PR #${pr} at ${headSha}\n  base: ${baseRepo}@${baseRef} @ ${liveBaseSha}\n  target_url: ${evidence}`,
  );
  return { ok: true };
}

/**
 * @typedef {{originalBase: string, currentBase: string, head: string,
 *   getInterveningFiles: (from: string, to: string) => Promise<string[]> | string[],
 *   getPrChangedFiles: (base: string, head: string) => Promise<string[]> | string[],
 *   getInterveningCommitCount: (from: string, to: string) => Promise<number> | number}} BaseAdvanceArgs
 */
/** @param {string} originalBase @param {string} currentBase @param {string} head */
function validateBaseShas(originalBase, currentBase, head) {
  if (
    !/^[0-9a-f]{12}([0-9a-f]{28})?$/i.test(originalBase) ||
    !fullSha(currentBase) ||
    !fullSha(head)
  ) {
    throw new Error(
      "Base comparison requires a 12- or 40-character original SHA and full current/head SHAs.",
    );
  }
}

/** Status-independent base comparison for downstream owner composition. Reads only.
 * Both the original and destination paths of renames must be supplied by the diff callbacks.
 * @param {BaseAdvanceArgs} args
 */
export async function checkBaseAdvance({
  originalBase,
  currentBase,
  head,
  getInterveningFiles,
  getPrChangedFiles,
  getInterveningCommitCount,
}) {
  validateBaseShas(originalBase, currentBase, head);
  if (currentBase.toLowerCase().startsWith(originalBase.toLowerCase())) {
    return { ok: true, unchanged: true, overlap: [], commitCount: 0 };
  }
  const interveningFiles = await getInterveningFiles(originalBase, currentBase);
  const prFiles = await getPrChangedFiles(originalBase, head);
  const commitCount = await getInterveningCommitCount(
    originalBase,
    currentBase,
  );
  const overlap = intersectFiles(interveningFiles, prFiles);
  return { ok: overlap.length === 0, unchanged: false, overlap, commitCount };
}

/** Compare local git objects, without statuses, fetching, or owner exceptions.
 * @param {string} tree @param {string} originalBase @param {string} currentBase @param {string} head
 */
export async function checkGitBaseAdvance(
  tree,
  originalBase,
  currentBase,
  head,
) {
  validateBaseShas(originalBase, currentBase, head);
  const [original, current, candidate] = [originalBase, currentBase, head].map(
    (sha) =>
      execFileSync("git", ["rev-parse", "--verify", `${sha}^{commit}`], {
        cwd: tree,
        encoding: "utf8",
      }).trim(),
  );
  return checkBaseAdvance({
    originalBase: original,
    currentBase: current,
    head: candidate,
    getInterveningFiles: makeGetInterveningFiles(tree),
    getPrChangedFiles: makeGetPrChangedFiles(tree),
    getInterveningCommitCount: makeGetInterveningCommitCount(tree),
  });
}

/**
 * @typedef {{pr: number, repoSlug?: string,
 *   getPrInfo: (pr: number) => Promise<PrInfo> | PrInfo,
 *   getDefaultBranch: () => Promise<string> | string,
 *   getStatus: (sha: string) => Promise<{state: string, description: string} | null> | {state: string, description: string} | null,
 *   fetchBase: (ref: string) => Promise<void> | void,
 *   getBaseTipSha: (ref: string) => Promise<string> | string,
 *   getInterveningFiles: BaseAdvanceArgs['getInterveningFiles'],
 *   getPrChangedFiles: BaseAdvanceArgs['getPrChangedFiles'],
 *   getInterveningCommitCount: BaseAdvanceArgs['getInterveningCommitCount'],
 *   log?: (msg: string) => void, error?: (msg: string) => void}} VerifyForMergeArgs
 */
/** A successful advisory check is not merge permission.
 * @param {VerifyForMergeArgs} args @returns {Promise<{ok: boolean}>}
 */
export async function verifyForMerge({
  pr,
  repoSlug,
  getPrInfo,
  getDefaultBranch,
  getStatus,
  fetchBase,
  getBaseTipSha,
  getInterveningFiles,
  getPrChangedFiles,
  getInterveningCommitCount,
  log = console.log,
  error = console.error,
}) {
  const { headSha, baseRef, baseRepo } = await getPrInfo(pr);
  const status = await getStatus(headSha);
  if (!status) {
    error(
      `no "${STATUS_CONTEXT}" status recorded at PR #${pr}'s head (${headSha}).`,
    );
    return { ok: false };
  }
  if (status.state !== "success") {
    error(
      `the "${STATUS_CONTEXT}" status at ${headSha} is "${status.state}", not success.`,
    );
    return { ok: false };
  }
  const recordedBase = parseRecordedBase(status.description);
  if (!recordedBase) {
    error(
      `the recorded status at ${headSha} has no parseable base repo/ref/SHA.`,
    );
    return { ok: false };
  }
  if (!status.description.startsWith("SHIP · base ")) {
    error("A successful status must record SHIP.");
    return { ok: false };
  }
  if (
    baseRepo !== recordedBase.repo ||
    baseRef !== recordedBase.ref ||
    (repoSlug !== undefined &&
      baseRepo.toLowerCase() !== repoSlug.toLowerCase())
  ) {
    error(
      `PR #${pr}'s base has changed: recorded ${recordedBase.repo}@${recordedBase.ref}, currently ${baseRepo}@${baseRef}. Re-review required.`,
    );
    return { ok: false };
  }
  const defaultBranch = await getDefaultBranch();
  if (baseRef !== defaultBranch) {
    error(
      `PR #${pr}'s base ("${baseRef}") is no longer the default branch ("${defaultBranch}").`,
    );
    return { ok: false };
  }
  await fetchBase(baseRef);
  const currentBaseTip = await getBaseTipSha(baseRef);
  const compared = await checkBaseAdvance({
    originalBase: recordedBase.sha,
    currentBase: currentBaseTip,
    head: headSha,
    getInterveningFiles,
    getPrChangedFiles,
    getInterveningCommitCount,
  });
  if (!compared.ok) {
    error(
      `base moved with overlapping changes; re-review required.\n  "${baseRef}" advanced ${compared.commitCount} commit(s):\n${compared.overlap.map((f) => `    ${f}`).join("\n")}`,
    );
    return { ok: false };
  }
  await fetchBase(baseRef);
  const finalBaseTip = await getBaseTipSha(baseRef);
  const recheck = await getPrInfo(pr);
  if (
    !shasEqual(finalBaseTip, currentBaseTip) ||
    !shasEqual(recheck.headSha, headSha) ||
    recheck.baseRef !== baseRef ||
    recheck.baseRepo !== baseRepo ||
    (await getDefaultBranch()) !== defaultBranch
  ) {
    error("PR head or base changed during verification.");
    return { ok: false };
  }
  log(
    compared.unchanged
      ? `base "${baseRef}" is unchanged (${recordedBase.sha}); advisory check passed, not merge authorization.`
      : `base "${baseRef}" advanced ${compared.commitCount} commit(s), none touching a PR file; advisory check passed, not merge authorization.`,
  );
  return { ok: true };
}

/**
 * Repo owner/repo, from `git remote get-url origin` first, falling back to
 * `gh repo view` when the remote is missing or unparseable (e.g. a worktree
 * with a non-standard remote name, or a CI checkout with no git remote at
 * all).
 *
 * @returns {{owner: string, repo: string}}
 */
function resolveRepo() {
  try {
    const remote = execFileSync("git", ["remote", "get-url", "origin"], {
      encoding: "utf8",
    }).trim();
    const parsed = parseGitHubRemote(remote);
    if (parsed) return parsed;
  } catch {
    // Fall through to `gh repo view` below.
  }

  const nameWithOwner = execFileSync(
    "gh",
    ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
    { encoding: "utf8" },
  ).trim();
  const [owner, repo] = nameWithOwner.split("/");
  if (!owner || !repo) {
    throw new Error(
      `could not resolve owner/repo from \`gh repo view\`: ${nameWithOwner || "(empty)"}`,
    );
  }
  return { owner, repo };
}

/**
 * @param {string} owner
 * @param {string} repo
 * @returns {(pr: number) => PrInfo}
 */
function makeGetPrInfo(owner, repo) {
  return (pr) => {
    const raw = execFileSync(
      "gh",
      ["api", `repos/${owner}/${repo}/pulls/${pr}`],
      { encoding: "utf8" },
    );
    const data = JSON.parse(raw);
    return {
      headSha: data.head.sha,
      baseRef: data.base.ref,
      baseRepo: data.base.repo.full_name,
    };
  };
}

/**
 * @param {string} owner
 * @param {string} repo
 * @returns {() => string}
 */
function makeGetDefaultBranch(owner, repo) {
  return () =>
    execFileSync(
      "gh",
      ["api", `repos/${owner}/${repo}`, "--jq", ".default_branch"],
      { encoding: "utf8" },
    ).trim();
}

/**
 * Resolves the LIVE tip of a base branch via the branches endpoint, not the
 * PR resource's `base.sha` -- which is a snapshot from the PR's last sync,
 * not the current branch tip, and can be many commits stale.
 *
 * @param {string} owner
 * @param {string} repo
 * @returns {(baseRef: string) => string}
 */
function makeGetLiveBaseTip(owner, repo) {
  return (baseRef) =>
    execFileSync(
      "gh",
      [
        "api",
        `repos/${owner}/${repo}/branches/${encodeURIComponent(baseRef)}`,
        "--jq",
        ".commit.sha",
      ],
      { encoding: "utf8" },
    ).trim();
}

/**
 * @param {string} owner
 * @param {string} repo
 * @returns {(args: {sha: string, state: string, description: string, targetUrl: string, context: string}) => void}
 */
function makePostStatus(owner, repo) {
  return ({ sha, state, description, targetUrl, context }) => {
    execFileSync(
      "gh",
      [
        "api",
        "--method",
        "POST",
        `repos/${owner}/${repo}/statuses/${sha}`,
        "-f",
        `state=${state}`,
        "-f",
        `context=${context}`,
        "-f",
        `description=${description}`,
        "-f",
        `target_url=${targetUrl}`,
      ],
      { encoding: "utf8" },
    );
  };
}

/**
 * @param {string} owner
 * @param {string} repo
 * @returns {(sha: string) => {state: string, description: string} | null}
 */
function makeGetStatus(owner, repo) {
  return (sha) => {
    const raw = execFileSync(
      "gh",
      ["api", `repos/${owner}/${repo}/commits/${sha}/status`],
      { encoding: "utf8" },
    );
    const data = JSON.parse(raw);
    /** @type {Array<{context: string, state: string, description: string}>} */
    const statuses = data.statuses;
    if (!Array.isArray(statuses))
      throw new Error("Malformed GitHub status response.");
    const matches = statuses.filter((s) => s.context === STATUS_CONTEXT);
    if (matches.length > 1)
      throw new Error("Ambiguous Pro-Gate status response.");
    const match = matches[0];
    return match
      ? { state: match.state, description: match.description }
      : null;
  };
}

/**
 * @returns {(baseRef: string) => void}
 */
function makeFetchBase() {
  return (baseRef) => {
    execFileSync("git", ["fetch", "origin", baseRef], { encoding: "utf8" });
  };
}

/**
 * @returns {(baseRef: string) => string}
 */
function makeGetBaseTipSha() {
  return (baseRef) =>
    execFileSync("git", ["rev-parse", `origin/${baseRef}`], {
      encoding: "utf8",
    }).trim();
}

/**
 * @param {string} output
 * @returns {string[]}
 */
function parseNameOnlyOutput(output) {
  return output.split("\0").filter(Boolean);
}

/**
 * @returns {(fromSha: string, toSha: string) => string[]}
 */
function makeGetInterveningFiles(cwd = process.cwd()) {
  return (fromSha, toSha) =>
    parseNameOnlyOutput(
      execFileSync(
        "git",
        ["diff", "--no-renames", "--name-only", "-z", fromSha, toSha, "--"],
        {
          encoding: "utf8",
          cwd,
        },
      ),
    );
}

/**
 * @returns {(baseSha: string, headSha: string) => string[]}
 */
function makeGetPrChangedFiles(cwd = process.cwd()) {
  return (baseSha, headSha) =>
    parseNameOnlyOutput(
      execFileSync(
        "git",
        [
          "diff",
          "--no-renames",
          "--name-only",
          "-z",
          `${baseSha}...${headSha}`,
          "--",
        ],
        {
          encoding: "utf8",
          cwd,
        },
      ),
    );
}

/**
 * @returns {(fromSha: string, toSha: string) => number}
 */
function makeGetInterveningCommitCount(cwd = process.cwd()) {
  return (fromSha, toSha) =>
    Number(
      execFileSync("git", ["rev-list", "--count", `${fromSha}..${toSha}`], {
        encoding: "utf8",
        cwd,
      }).trim(),
    );
}

/** Invoke the supported sibling public CLI, in repository or flattened installed layout. */
function publicCommand() {
  const command = join(
    dirname(fileURLToPath(import.meta.url)),
    "oracle-review.sh",
  );
  if (!lstatSync(command).isFile())
    throw new Error("Sibling public oracle-review.sh is unavailable.");
  return command;
}

/** @param {string} command @param {string[]} args @param {NodeJS.ProcessEnv} env */
function publicJson(command, args, env) {
  const raw = execFileSync("/bin/bash", [command, ...args], {
    encoding: "utf8",
    env,
    timeout: 120_000,
    killSignal: "SIGKILL",
    maxBuffer: 1024 * 1024,
  });
  return JSON.parse(raw);
}

/** Read only an explicit public preparation output, never retained engine storage.
 * @param {string} path
 */
function readPreparedJson(path) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.size > 65536)
    throw new Error("Invalid public preparation output file.");
  return JSON.parse(readFileSync(path, "utf8"));
}

/**
 * Preparation is an explicit, separate no-spend effect. Public inspection itself stays file-only.
 * An existing explicit proof pair can be reused, but run() still binds its base/head to live IO.
 * @param {string} owner @param {string} repo @param {RecordArgs} args
 * @returns {(pr: number) => ReviewProof}
 */
function makeGetReviewFacts(owner, repo, args) {
  return (pr) => {
    const command = publicCommand();
    const checkout = execFileSync("git", ["rev-parse", "--show-toplevel"], {
      encoding: "utf8",
    }).trim();
    const target = `https://github.com/${owner}/${repo}/pull/${pr}`;
    const env = { ...process.env };
    let endpoint = env.PRO_GATE_REVIEW_ENDPOINT_PATCH;
    let snapshot = env.PRO_GATE_REVIEW_PR_EVIDENCE;
    /** @type {string | undefined} */
    let temporary;
    try {
      if (Boolean(endpoint) !== Boolean(snapshot))
        throw new Error(
          "Explicit proof requires both PRO_GATE_REVIEW_ENDPOINT_PATCH and PRO_GATE_REVIEW_PR_EVIDENCE.",
        );
      if (!endpoint || !snapshot) {
        temporary = mkdtempSync(join(tmpdir(), "pro-gate-status-"));
        const output = join(temporary, "proof");
        const prepared = publicJson(
          command,
          [
            "--prepare-review-evidence",
            output,
            "--repo",
            checkout,
            "--pr",
            target,
          ],
          env,
        );
        endpoint = join(output, "endpoint.patch");
        snapshot = join(output, "pr-evidence.json");
        if (
          !isObject(prepared) ||
          prepared.endpoint_patch !== endpoint ||
          prepared.pr_evidence !== snapshot
        ) {
          throw new Error("Malformed public preparation response.");
        }
      } else {
        // Reused outputs can change between our metadata read and public inspection.
        // Certify one private pair, never a base read from different caller-owned bytes.
        temporary = mkdtempSync(join(tmpdir(), "pro-gate-status-"));
        const pairs = /** @type {const} */ ([
          [snapshot, "pr-evidence.json", 65536],
          [endpoint, "endpoint.patch", 26214400],
        ]);
        for (const [source, name, limit] of pairs) {
          const stat = lstatSync(source);
          if (!stat.isFile() || stat.size > limit)
            throw new Error("Invalid explicit public proof file.");
          writeFileSync(join(temporary, name), readFileSync(source), {
            mode: 0o600,
          });
        }
        snapshot = join(temporary, "pr-evidence.json");
        endpoint = join(temporary, "endpoint.patch");
      }
      const proof = readPreparedJson(snapshot);
      if (
        !isObject(proof) ||
        proof.record_type !== "review-pr-evidence/v1" ||
        proof.record_version !== 1 ||
        proof.patch_format !== "github-compare-diff" ||
        !digest(proof.endpoint_digest) ||
        !isObject(proof.metadata) ||
        !isObject(proof.metadata.repository) ||
        !isObject(proof.metadata.target)
      ) {
        throw new Error("Malformed public PR proof.");
      }
      const identity = proof.metadata.repository;
      const targetProof = proof.metadata.target;
      if (
        identity.host !== "github.com" ||
        identity.owner !== owner ||
        identity.repo !== repo ||
        targetProof.pr !== pr ||
        !fullSha(targetProof.head_oid) ||
        !fullSha(targetProof.base_oid) ||
        typeof targetProof.base_ref !== "string" ||
        !targetProof.base_ref
      ) {
        throw new Error("Mismatched public PR proof target.");
      }
      env.PRO_GATE_REVIEW_ENDPOINT_PATCH = endpoint;
      env.PRO_GATE_REVIEW_PR_EVIDENCE = snapshot;
      const flags = [
        "--review-facts",
        "--repo",
        checkout,
        "--pr",
        target,
        "--json",
        "--diff",
        args.diff ?? endpoint,
      ];
      if (args.confirm !== undefined) flags.push("--confirm", args.confirm);
      if (args.input !== undefined) flags.push("--input", args.input);
      const facts = publicJson(command, flags, env);
      return {
        facts,
        base: {
          repo: `${identity.owner}/${identity.repo}`,
          ref: targetProof.base_ref,
          sha: targetProof.base_oid,
        },
      };
    } finally {
      if (temporary !== undefined)
        rmSync(temporary, { recursive: true, force: true });
    }
  };
}

async function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    const { owner, repo } = resolveRepo();
    const common = {
      pr: args.pr,
      repoSlug: `${owner}/${repo}`,
      getPrInfo: makeGetPrInfo(owner, repo),
      getDefaultBranch: makeGetDefaultBranch(owner, repo),
    };
    const result =
      args.mode === "verify"
        ? await verifyForMerge({
            ...common,
            getStatus: makeGetStatus(owner, repo),
            fetchBase: makeFetchBase(),
            getBaseTipSha: makeGetBaseTipSha(),
            getInterveningFiles: makeGetInterveningFiles(),
            getPrChangedFiles: makeGetPrChangedFiles(),
            getInterveningCommitCount: makeGetInterveningCommitCount(),
          })
        : await run({
            ...common,
            verdict: args.verdict,
            reviewedSha: args.reviewedSha,
            evidence: args.evidence,
            getLiveBaseTip: makeGetLiveBaseTip(owner, repo),
            getReviewFacts: makeGetReviewFacts(owner, repo, args),
            postStatus: makePostStatus(owner, repo),
          });
    process.exitCode = result.ok ? 0 : 1;
  } catch (err) {
    console.error(
      `record-pro-gate-verdict failed: ${err instanceof Error ? err.message : String(err)}`,
    );
    process.exitCode = 1;
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
)
  main();
