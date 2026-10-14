// @ts-check
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  readdirSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  DESCRIPTION_MAX_LENGTH,
  SHIP_VERDICT,
  STATUS_CONTEXT,
  UsageError,
  buildDescription,
  intersectFiles,
  isoDate,
  parseArgs,
  parseGitHubRemote,
  parseRecordedBase,
  run,
  shasEqual,
  stateForVerdict,
  verifyForMerge,
  checkBaseAdvance,
  checkGitBaseAdvance,
} from "../bin/record-pro-gate-verdict.mjs";

const SHA_A = "abc123def4567890abc123def4567890abc123d0";
const SHA_B = "000000000000000000000000000000000000000f";
const BASE_SHA = "1111111111112222222222223333333333334444";
const BASE_SHA_SHORT = BASE_SHA.slice(0, 12); // '111111111111'
const NEW_BASE_SHA = "5555555555556666666666667777777777778888";
const DEFAULT_BRANCH = "main";
const BASE_REPO = "StartupBros-com/pushbot";
// Short enough to fit the 140-char description cap alongside the new,
// longer `base <repo>@<ref>@<sha>` prefix (78 chars) without truncating --
// tests that specifically exercise truncation build their own long fixture.
const EVIDENCE = "https://github.com/StartupBros-com/pushbot/pull/1748#c1";

// ---------------------------------------------------------------------------
// parseArgs: missing-argument refusal (record mode)
// ---------------------------------------------------------------------------

test("parseArgs accepts all four required flags in any order", () => {
  const args = parseArgs([
    "--verdict",
    "SHIP",
    "--pr",
    "1748",
    "--evidence",
    EVIDENCE,
    "--reviewed-sha",
    SHA_A,
  ]);

  assert.deepEqual(args, {
    mode: "record",
    pr: 1748,
    verdict: "SHIP",
    reviewedSha: SHA_A,
    evidence: EVIDENCE,
  });
});

test("parseArgs refuses when any single required flag is missing", () => {
  const full = [
    "--pr",
    "1748",
    "--verdict",
    "SHIP",
    "--reviewed-sha",
    SHA_A,
    "--evidence",
    EVIDENCE,
  ];

  const flagsAndValues = [
    ["--pr", "1748"],
    ["--verdict", "SHIP"],
    ["--reviewed-sha", SHA_A],
    ["--evidence", EVIDENCE],
  ];

  for (const [flag, value] of flagsAndValues) {
    const withoutOne = full.filter(
      (_, i) => full[i] !== flag && full[i - 1] !== flag,
    );
    // Sanity: the filter above actually dropped the pair.
    assert.ok(!withoutOne.includes(flag), `expected ${flag} removed`);

    assert.throws(
      () => parseArgs(withoutOne),
      (err) => {
        assert.ok(err instanceof UsageError, flag);
        // Exactly the removed flag is named as missing -- not just "the
        // message mentions it somewhere", which the trailing USAGE block
        // would satisfy for all four flags regardless of which is missing.
        assert.equal(
          /** @type {Error} */ (err).message.startsWith(
            `missing required argument(s): ${flag}\n\n`,
          ),
          true,
          /** @type {Error} */ (err).message,
        );
        return true;
      },
      flag,
    );
  }
});

test("parseArgs refuses when every flag is missing", () => {
  assert.throws(() => parseArgs([]), UsageError);
});

test("parseArgs refuses a non-numeric or non-positive --pr", () => {
  const base = [
    "--verdict",
    "SHIP",
    "--reviewed-sha",
    SHA_A,
    "--evidence",
    EVIDENCE,
  ];

  for (const bad of ["not-a-number", "0", "-5", "1.5"]) {
    assert.throws(
      () => parseArgs([...base, "--pr", bad]),
      UsageError,
      `--pr ${bad}`,
    );
  }
});

test("parseArgs refuses a flag with no following value", () => {
  assert.throws(() => parseArgs(["--pr", "1748", "--verdict"]), UsageError);
});

// ---------------------------------------------------------------------------
// parseArgs: --verify-for-merge mode
// ---------------------------------------------------------------------------

test("parseArgs recognizes --verify-for-merge and only requires --pr", () => {
  const args = parseArgs(["--verify-for-merge", "--pr", "1748"]);
  assert.deepEqual(args, { mode: "verify", pr: 1748 });
});

test("parseArgs --verify-for-merge ignores record-mode flags if present", () => {
  const args = parseArgs([
    "--verify-for-merge",
    "--verdict",
    "SHIP",
    "--pr",
    "1748",
  ]);
  assert.deepEqual(args, { mode: "verify", pr: 1748 });
});

test("parseArgs --verify-for-merge refuses when --pr is missing", () => {
  assert.throws(() => parseArgs(["--verify-for-merge"]), UsageError);
});

test("parseArgs --verify-for-merge refuses a non-positive --pr", () => {
  assert.throws(
    () => parseArgs(["--verify-for-merge", "--pr", "0"]),
    UsageError,
  );
});

// ---------------------------------------------------------------------------
// stateForVerdict: verdict -> state mapping, with the planted-negative flip
// ---------------------------------------------------------------------------

test("SHIP maps to success", () => {
  assert.equal(stateForVerdict(SHIP_VERDICT), "success");
  assert.equal(stateForVerdict("SHIP"), "success");
});

test("every non-SHIP verdict maps to failure, never success", () => {
  for (const verdict of [
    "NO-SHIP",
    "BLOCKED",
    "ship",
    "Ship",
    "SHIP ",
    "",
    "REJECT",
  ]) {
    assert.equal(stateForVerdict(verdict), "failure", verdict);
  }
});

// The planted negative: if the mapping were ever inverted or widened (e.g.
// `verdict !== 'REJECT'` instead of `verdict === 'SHIP'`), this is the
// assertion that must fail. A required check that can go green on a verdict
// that was never actually "SHIP" is worse than no check at all.
test('planted negative: stateForVerdict is not merely "truthy string -> success"', () => {
  assert.notEqual(stateForVerdict("definitely not a real verdict"), "success");
  assert.notEqual(stateForVerdict(SHIP_VERDICT), "failure");
});

// ---------------------------------------------------------------------------
// buildDescription: format and 140-char truncation
// ---------------------------------------------------------------------------

test("buildDescription formats verdict, base repo/ref/sha, date, and evidence when it fits", () => {
  const now = new Date("2026-08-16T12:00:00Z");
  const description = buildDescription({
    verdict: "SHIP",
    baseRepo: BASE_REPO,
    baseRef: DEFAULT_BRANCH,
    baseSha: BASE_SHA,
    evidence: EVIDENCE,
    now,
  });

  assert.equal(
    description,
    `SHIP · base ${BASE_REPO}@${DEFAULT_BRANCH}@${BASE_SHA_SHORT} · recorded 2026-08-16 · ${EVIDENCE}`,
  );
  assert.ok(description.length <= DESCRIPTION_MAX_LENGTH);
});

test("isoDate returns a calendar date, not a full timestamp", () => {
  assert.equal(isoDate(new Date("2026-08-16T23:59:59Z")), "2026-08-16");
});

test("buildDescription truncates a long evidence URL to fit 140 chars, never dropping identity fields", () => {
  const now = new Date("2026-08-16T12:00:00Z");
  const longEvidence = `https://github.com/StartupBros-com/pushbot/pull/1748#${"x".repeat(200)}`;
  const description = buildDescription({
    verdict: "SHIP",
    baseRepo: BASE_REPO,
    baseRef: DEFAULT_BRANCH,
    baseSha: BASE_SHA,
    evidence: longEvidence,
    now,
  });

  assert.ok(
    description.length <= DESCRIPTION_MAX_LENGTH,
    `length ${description.length} exceeds ${DESCRIPTION_MAX_LENGTH}`,
  );
  // Safe truncation: the verdict/base/date prefix -- including the full
  // repo@ref@sha identity, never abbreviated further -- survives intact,
  // and the cut is signposted with an ellipsis rather than silently
  // producing what looks like a complete (and therefore wrong) URL.
  assert.ok(
    description.startsWith(
      `SHIP · base ${BASE_REPO}@${DEFAULT_BRANCH}@${BASE_SHA_SHORT} · recorded 2026-08-16 · `,
    ),
  );
  assert.ok(description.endsWith("…"));
});

test("buildDescription truncates even a non-SHIP verdict the same way", () => {
  const now = new Date("2026-08-16T12:00:00Z");
  const longEvidence = `https://github.com/x/${"y".repeat(200)}`;
  const description = buildDescription({
    verdict: "NO-SHIP",
    baseRepo: BASE_REPO,
    baseRef: DEFAULT_BRANCH,
    baseSha: BASE_SHA,
    evidence: longEvidence,
    now,
  });

  assert.ok(description.length <= DESCRIPTION_MAX_LENGTH);
  assert.ok(
    description.startsWith(
      `NO-SHIP · base ${BASE_REPO}@${DEFAULT_BRANCH}@${BASE_SHA_SHORT} · recorded 2026-08-16 · `,
    ),
  );
});

// ---------------------------------------------------------------------------
// parseRecordedBase
// ---------------------------------------------------------------------------

test("parseRecordedBase extracts the base repo, ref, and sha a description recorded", () => {
  const description = buildDescription({
    verdict: "SHIP",
    baseRepo: BASE_REPO,
    baseRef: DEFAULT_BRANCH,
    baseSha: BASE_SHA,
    evidence: EVIDENCE,
    now: new Date("2026-08-16T12:00:00Z"),
  });
  assert.deepEqual(parseRecordedBase(description), {
    repo: BASE_REPO,
    ref: DEFAULT_BRANCH,
    sha: BASE_SHA_SHORT,
  });
});

test("parseRecordedBase returns null for a pre-base-binding (legacy) description", () => {
  assert.equal(
    parseRecordedBase(`SHIP · recorded 2026-08-16 · ${EVIDENCE}`),
    null,
  );
});

test("parseRecordedBase returns null for a round-1, SHA-only (pre-repo/ref-binding) description", () => {
  assert.equal(
    parseRecordedBase(
      `SHIP · base ${BASE_SHA_SHORT} · recorded 2026-08-16 · ${EVIDENCE}`,
    ),
    null,
  );
});

test("parseRecordedBase returns null for unrelated text", () => {
  assert.equal(parseRecordedBase("not a status description at all"), null);
});

// ---------------------------------------------------------------------------
// intersectFiles
// ---------------------------------------------------------------------------

test("intersectFiles returns the common files, deduped and sorted", () => {
  assert.deepEqual(
    intersectFiles(["b.ts", "a.ts", "a.ts", "c.ts"], ["a.ts", "d.ts", "b.ts"]),
    ["a.ts", "b.ts"],
  );
});

test("intersectFiles returns an empty array when there is no overlap", () => {
  assert.deepEqual(intersectFiles(["a.ts"], ["b.ts"]), []);
});

// ---------------------------------------------------------------------------
// shasEqual
// ---------------------------------------------------------------------------

test("shasEqual is case- and whitespace-insensitive", () => {
  assert.equal(shasEqual(SHA_A, SHA_A), true);
  assert.equal(shasEqual(SHA_A.toUpperCase(), SHA_A), true);
  assert.equal(shasEqual(`  ${SHA_A}\n`, SHA_A), true);
});

test("shasEqual rejects different SHAs", () => {
  assert.equal(shasEqual(SHA_A, SHA_B), false);
});

// ---------------------------------------------------------------------------
// parseGitHubRemote
// ---------------------------------------------------------------------------

test("parseGitHubRemote reads owner/repo from an SSH remote", () => {
  assert.deepEqual(
    parseGitHubRemote("git@github.com:StartupBros-com/pushbot.git"),
    { owner: "StartupBros-com", repo: "pushbot" },
  );
});

test("parseGitHubRemote reads owner/repo from an HTTPS remote", () => {
  assert.deepEqual(
    parseGitHubRemote("https://github.com/StartupBros-com/pushbot.git"),
    { owner: "StartupBros-com", repo: "pushbot" },
  );
  assert.deepEqual(
    parseGitHubRemote("https://github.com/StartupBros-com/pushbot"),
    { owner: "StartupBros-com", repo: "pushbot" },
  );
});

test("parseGitHubRemote returns null for a non-GitHub remote", () => {
  assert.equal(parseGitHubRemote("git@gitlab.com:foo/bar.git"), null);
});

// ---------------------------------------------------------------------------
// run: the orchestration itself. gh is always a stub here -- no test in this
// file spawns a real process or touches the network.
// ---------------------------------------------------------------------------

/**
 * @returns {{calls: Array<Record<string, unknown>>, postStatus: (args: Record<string, unknown>) => void}}
 */
function statusSpy() {
  /** @type {Array<Record<string, unknown>>} */
  const calls = [];
  return { calls, postStatus: (args) => void calls.push(args) };
}

/**
 * Default args for `run()`: a matching head SHA, a default-branch base, a
 * live base tip equal to the fixture BASE_SHA, and no-op I/O. Each test
 * overrides only what it's exercising.
 *
 * @param {Partial<Parameters<typeof run>[0]>} [overrides]
 * @returns {Parameters<typeof run>[0]}
 */
function baseRunArgs(overrides = {}) {
  return {
    pr: 1748,
    verdict: "SHIP",
    reviewedSha: SHA_A,
    evidence: EVIDENCE,
    getPrInfo: () => ({
      headSha: SHA_A,
      baseRef: DEFAULT_BRANCH,
      baseRepo: BASE_REPO,
    }),
    getDefaultBranch: () => DEFAULT_BRANCH,
    getLiveBaseTip: () => BASE_SHA,
    getReviewFacts: () => acceptedProof(overrides.verdict ?? "SHIP"),
    postStatus: () => {},
    now: () => new Date("2026-08-16T12:00:00Z"),
    log: () => {},
    error: () => {},
    ...overrides,
  };
}

test("SHA-mismatch: refuses, posts nothing, and names both SHAs", async () => {
  const { calls, postStatus } = statusSpy();
  /** @type {string[]} */
  const errors = [];

  const result = await run(
    baseRunArgs({
      // current head has moved past the reviewed SHA
      getPrInfo: () => ({
        headSha: SHA_B,
        baseRef: DEFAULT_BRANCH,
        baseRepo: BASE_REPO,
      }),
      postStatus,
      error: (msg) => errors.push(msg),
    }),
  );

  assert.equal(result.ok, false);
  assert.equal(calls.length, 0, "no status may be posted on a SHA mismatch");
  assert.ok(errors.length >= 1);
  assert.match(errors[0], new RegExp(SHA_A));
  assert.match(errors[0], new RegExp(SHA_B));
  assert.match(errors[0], /re-review|re-run/i);
});

test("non-default base: refuses, posts nothing, and names both branches", async () => {
  const { calls, postStatus } = statusSpy();
  /** @type {string[]} */
  const errors = [];

  const result = await run(
    baseRunArgs({
      getPrInfo: () => ({
        headSha: SHA_A,
        baseRef: "some-feature-branch",
        baseRepo: BASE_REPO,
      }),
      postStatus,
      error: (msg) => errors.push(msg),
    }),
  );

  assert.equal(result.ok, false);
  assert.equal(
    calls.length,
    0,
    "no status may be posted against a non-default base",
  );
  assert.match(errors[0], /some-feature-branch/);
  assert.match(errors[0], new RegExp(DEFAULT_BRANCH));
});

// The planted negative for the base check specifically: prove the refusal
// really keys off "does baseRef equal the default branch", not merely "is
// baseRef non-empty" or some other looser condition that would let a
// non-default base slip through unflagged.
test("planted negative: a base equal to the default branch is accepted, a differently-named one never is", async () => {
  const okResult = await run(baseRunArgs({ postStatus: () => {} }));
  assert.equal(okResult.ok, true);

  const { calls: refusedCalls, postStatus: refusedPostStatus } = statusSpy();
  const refusedResult = await run(
    baseRunArgs({
      getPrInfo: () => ({
        headSha: SHA_A,
        baseRef: `${DEFAULT_BRANCH}-staging`,
        baseRepo: BASE_REPO,
      }),
      postStatus: refusedPostStatus,
    }),
  );
  assert.equal(refusedResult.ok, false);
  assert.equal(refusedCalls.length, 0);
});

test("SHA and base match: posts exactly one status, embedding the base repo/ref/sha", async () => {
  const { calls, postStatus } = statusSpy();

  const result = await run(baseRunArgs({ postStatus }));

  assert.equal(result.ok, true);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0], {
    sha: SHA_A,
    state: "success",
    description: `SHIP · base ${BASE_REPO}@${DEFAULT_BRANCH}@${BASE_SHA_SHORT} · recorded 2026-08-16 · ${EVIDENCE}`,
    targetUrl: EVIDENCE,
    context: STATUS_CONTEXT,
  });
});

test("a non-SHIP verdict at a matching SHA and base still posts, as failure", async () => {
  const { calls, postStatus } = statusSpy();

  const result = await run(baseRunArgs({ verdict: "FIX-FIRST", postStatus }));

  assert.equal(result.ok, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].state, "failure");
});

test("a case-differing head SHA still counts as a match", async () => {
  const { calls, postStatus } = statusSpy();

  const result = await run(
    baseRunArgs({
      getPrInfo: () => ({
        headSha: SHA_A.toUpperCase(),
        baseRef: DEFAULT_BRANCH,
        baseRepo: BASE_REPO,
      }),
      postStatus,
    }),
  );

  assert.equal(result.ok, true);
  assert.equal(calls.length, 1);
});

test("idempotent: re-running at the same SHA posts the same status again", async () => {
  const { calls, postStatus } = statusSpy();
  const opts = baseRunArgs({ postStatus });

  await run(opts);
  await run(opts);

  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0], calls[1]);
});

test("run works with async getPrInfo, getDefaultBranch, and getLiveBaseTip (a real gh call is synchronous, but the contract allows either)", async () => {
  const { calls, postStatus } = statusSpy();

  const result = await run(
    baseRunArgs({
      getPrInfo: async () => ({
        headSha: SHA_A,
        baseRef: DEFAULT_BRANCH,
        baseRepo: BASE_REPO,
      }),
      getDefaultBranch: async () => DEFAULT_BRANCH,
      getLiveBaseTip: async () => BASE_SHA,
      postStatus,
    }),
  );

  assert.equal(result.ok, true);
  assert.equal(calls.length, 1);
});

// The required planted negative for the live-tip fix: the recorded base SHA
// must come from `getLiveBaseTip`'s return value, never from any field that
// happens to live on the `getPrInfo` result. Before the fix, `run()` read
// `pull.base.sha` off the PR resource -- a value confirmed live (PR #1748)
// to sit up to 25 commits behind the real branch tip. If `run()` ever
// regressed to reading a field off `getPrInfo` instead of calling
// `getLiveBaseTip`, this test fails: the bait value below would show up in
// the recorded description instead of `BASE_SHA`.
test("planted negative: the recorded base SHA comes from getLiveBaseTip, never a stale field on getPrInfo", async () => {
  const { calls, postStatus } = statusSpy();
  const BAIT_SHA = "000000000000dead000000000000000000beef";

  const result = await run(
    baseRunArgs({
      getPrInfo: () => ({
        headSha: SHA_A,
        baseRef: DEFAULT_BRANCH,
        baseRepo: BASE_REPO,
        // Bait: mimics the real PR resource's `base.sha`, which PrInfo no
        // longer even has a slot for. If `run()` ever read it anyway, the
        // recorded description would embed BAIT_SHA instead of BASE_SHA.
        baseSha: BAIT_SHA,
      }),
      getLiveBaseTip: () => BASE_SHA,
      postStatus,
    }),
  );

  assert.equal(result.ok, true);
  assert.equal(calls.length, 1);
  const description = /** @type {string} */ (calls[0].description);
  assert.match(description, new RegExp(BASE_SHA_SHORT));
  assert.doesNotMatch(description, /dead.*beef/);
});

// Race-close: the PR's head or base could move in the interval between the
// live-tip resolution and posting. `run()` re-reads the PR a second time
// right before posting and must abort -- posting nothing -- if anything
// moved, rather than record a value that was true a moment ago.
test("planted negative: the head SHA moving between the two getPrInfo reads aborts and posts nothing", async () => {
  const { calls, postStatus } = statusSpy();
  /** @type {string[]} */
  const errors = [];
  let callCount = 0;

  const result = await run(
    baseRunArgs({
      getPrInfo: () => {
        callCount++;
        return callCount === 1
          ? { headSha: SHA_A, baseRef: DEFAULT_BRANCH, baseRepo: BASE_REPO }
          : { headSha: SHA_B, baseRef: DEFAULT_BRANCH, baseRepo: BASE_REPO };
      },
      postStatus,
      error: (msg) => errors.push(msg),
    }),
  );

  assert.equal(result.ok, false);
  assert.equal(calls.length, 0, "a race must post nothing");
  assert.equal(callCount, 2, "both reads must actually happen");
  assert.match(errors[0], /moved|changed/i);
});

test("planted negative: the base ref retargeting between the two getPrInfo reads aborts and posts nothing", async () => {
  const { calls, postStatus } = statusSpy();
  let callCount = 0;

  const result = await run(
    baseRunArgs({
      getPrInfo: () => {
        callCount++;
        return callCount === 1
          ? { headSha: SHA_A, baseRef: DEFAULT_BRANCH, baseRepo: BASE_REPO }
          : { headSha: SHA_A, baseRef: "staging", baseRepo: BASE_REPO };
      },
      postStatus,
    }),
  );

  assert.equal(result.ok, false);
  assert.equal(calls.length, 0);
  assert.equal(callCount, 2);
});

// ---------------------------------------------------------------------------
// verifyForMerge: the pre-merge check. gh/git are always stubs here -- no
// test in this file spawns a real process or touches the network.
// ---------------------------------------------------------------------------

const RECORDED_DESCRIPTION = `SHIP · base ${BASE_REPO}@${DEFAULT_BRANCH}@${BASE_SHA_SHORT} · recorded 2026-08-16 · ${EVIDENCE}`;

/** A diff/count stub that fails the test loudly if it's ever called -- used
 * to prove the various short-circuits genuinely skip the work downstream of
 * them, rather than merely happening to return an empty result.
 * @returns {never} */
function shouldNotBeCalled() {
  throw new Error("should not have been called");
}

test("verifyForMerge: no status at head refuses and skips everything downstream", async () => {
  /** @type {string[]} */
  const errors = [];

  const result = await verifyForMerge({
    pr: 1748,
    getPrInfo: () => ({
      headSha: SHA_A,
      baseRef: DEFAULT_BRANCH,
      baseRepo: BASE_REPO,
    }),
    getDefaultBranch: shouldNotBeCalled,
    getStatus: () => null,
    fetchBase: shouldNotBeCalled,
    getBaseTipSha: shouldNotBeCalled,
    getInterveningFiles: shouldNotBeCalled,
    getPrChangedFiles: shouldNotBeCalled,
    getInterveningCommitCount: shouldNotBeCalled,
    log: () => {},
    error: (msg) => errors.push(msg),
  });

  assert.equal(result.ok, false);
  assert.match(errors[0], new RegExp(STATUS_CONTEXT));
  assert.match(errors[0], new RegExp(SHA_A));
});

test("verifyForMerge: a failure status at head refuses", async () => {
  /** @type {string[]} */
  const errors = [];

  const result = await verifyForMerge({
    pr: 1748,
    getPrInfo: () => ({
      headSha: SHA_A,
      baseRef: DEFAULT_BRANCH,
      baseRepo: BASE_REPO,
    }),
    getDefaultBranch: shouldNotBeCalled,
    getStatus: () => ({
      state: "failure",
      description: RECORDED_DESCRIPTION,
    }),
    fetchBase: shouldNotBeCalled,
    getBaseTipSha: shouldNotBeCalled,
    getInterveningFiles: shouldNotBeCalled,
    getPrChangedFiles: shouldNotBeCalled,
    getInterveningCommitCount: shouldNotBeCalled,
    log: () => {},
    error: (msg) => errors.push(msg),
  });

  assert.equal(result.ok, false);
  assert.match(errors[0], /failure/);
});

test("verifyForMerge: a success status with an unparseable (pre-base-binding) description refuses", async () => {
  /** @type {string[]} */
  const errors = [];

  const result = await verifyForMerge({
    pr: 1748,
    getPrInfo: () => ({
      headSha: SHA_A,
      baseRef: DEFAULT_BRANCH,
      baseRepo: BASE_REPO,
    }),
    getDefaultBranch: shouldNotBeCalled,
    getStatus: () => ({
      state: "success",
      description: `SHIP · recorded 2026-08-16 · ${EVIDENCE}`,
    }),
    fetchBase: shouldNotBeCalled,
    getBaseTipSha: shouldNotBeCalled,
    getInterveningFiles: shouldNotBeCalled,
    getPrChangedFiles: shouldNotBeCalled,
    getInterveningCommitCount: shouldNotBeCalled,
    log: () => {},
    error: (msg) => errors.push(msg),
  });

  assert.equal(result.ok, false);
  assert.match(errors[0], /base/i);
});

// The required planted negative for the base-binding fix: retargeting the
// PR to a different base ref after the verdict was recorded must refuse
// verification and name the mismatch, WITHOUT ever reaching the file-diff
// logic -- a retarget whose changed files happen not to overlap this PR's
// must not be able to reach the no-overlap success path below.
test("verifyForMerge: a retargeted base ref refuses, naming the recorded and current ref, without diffing files", async () => {
  /** @type {string[]} */
  const errors = [];

  const result = await verifyForMerge({
    pr: 1748,
    getPrInfo: () => ({
      headSha: SHA_A,
      // Retargeted to a different branch after the verdict was recorded
      // against DEFAULT_BRANCH.
      baseRef: "some-other-branch",
      baseRepo: BASE_REPO,
    }),
    getDefaultBranch: shouldNotBeCalled,
    getStatus: () => ({
      state: "success",
      description: RECORDED_DESCRIPTION,
    }),
    fetchBase: shouldNotBeCalled,
    getBaseTipSha: shouldNotBeCalled,
    getInterveningFiles: shouldNotBeCalled,
    getPrChangedFiles: shouldNotBeCalled,
    getInterveningCommitCount: shouldNotBeCalled,
    log: () => {},
    error: (msg) => errors.push(msg),
  });

  assert.equal(result.ok, false);
  assert.match(errors[0], new RegExp(DEFAULT_BRANCH));
  assert.match(errors[0], /some-other-branch/);
});

test("verifyForMerge: a base repo mismatch (fork retarget) refuses, without diffing files", async () => {
  /** @type {string[]} */
  const errors = [];

  const result = await verifyForMerge({
    pr: 1748,
    getPrInfo: () => ({
      headSha: SHA_A,
      baseRef: DEFAULT_BRANCH,
      baseRepo: "someone-else/pushbot-fork",
    }),
    getDefaultBranch: shouldNotBeCalled,
    getStatus: () => ({
      state: "success",
      description: RECORDED_DESCRIPTION,
    }),
    fetchBase: shouldNotBeCalled,
    getBaseTipSha: shouldNotBeCalled,
    getInterveningFiles: shouldNotBeCalled,
    getPrChangedFiles: shouldNotBeCalled,
    getInterveningCommitCount: shouldNotBeCalled,
    log: () => {},
    error: (msg) => errors.push(msg),
  });

  assert.equal(result.ok, false);
  assert.match(errors[0], new RegExp(BASE_REPO));
  assert.match(errors[0], /someone-else\/pushbot-fork/);
});

test("verifyForMerge: base ref matches what was recorded but is no longer the default branch -> refuses before diffing", async () => {
  /** @type {string[]} */
  const errors = [];

  const result = await verifyForMerge({
    pr: 1748,
    getPrInfo: () => ({
      headSha: SHA_A,
      baseRef: DEFAULT_BRANCH,
      baseRepo: BASE_REPO,
    }),
    getDefaultBranch: () => "main-v2",
    getStatus: () => ({
      state: "success",
      description: RECORDED_DESCRIPTION,
    }),
    fetchBase: shouldNotBeCalled,
    getBaseTipSha: shouldNotBeCalled,
    getInterveningFiles: shouldNotBeCalled,
    getPrChangedFiles: shouldNotBeCalled,
    getInterveningCommitCount: shouldNotBeCalled,
    log: () => {},
    error: (msg) => errors.push(msg),
  });

  assert.equal(result.ok, false);
  assert.match(errors[0], /main-v2/);
});

test("verifyForMerge: base unchanged since recording -> merge OK, diff never runs", async () => {
  /** @type {string[]} */
  const logs = [];

  const result = await verifyForMerge({
    pr: 1748,
    getPrInfo: () => ({
      headSha: SHA_A,
      baseRef: DEFAULT_BRANCH,
      baseRepo: BASE_REPO,
    }),
    getDefaultBranch: () => DEFAULT_BRANCH,
    getStatus: () => ({
      state: "success",
      description: RECORDED_DESCRIPTION,
    }),
    fetchBase: () => {},
    // full current tip, sharing the recorded 12-char prefix -- i.e. genuinely
    // the same commit, not a coincidentally-equal short string.
    getBaseTipSha: () => BASE_SHA,
    getInterveningFiles: shouldNotBeCalled,
    getPrChangedFiles: shouldNotBeCalled,
    getInterveningCommitCount: shouldNotBeCalled,
    log: (msg) => logs.push(msg),
    error: () => {},
  });

  assert.equal(result.ok, true);
  assert.match(logs[0], /unchanged/);
});

test("verifyForMerge: base advanced with overlapping changes -> refuses and names the overlap", async () => {
  /** @type {string[]} */
  const errors = [];

  const result = await verifyForMerge({
    pr: 1748,
    getPrInfo: () => ({
      headSha: SHA_A,
      baseRef: DEFAULT_BRANCH,
      baseRepo: BASE_REPO,
    }),
    getDefaultBranch: () => DEFAULT_BRANCH,
    getStatus: () => ({
      state: "success",
      description: RECORDED_DESCRIPTION,
    }),
    fetchBase: () => {},
    getBaseTipSha: () => NEW_BASE_SHA,
    getInterveningFiles: () => [
      "apps/blog-writer/lib/shared.ts",
      "apps/blog-writer/lib/other.ts",
    ],
    getPrChangedFiles: () => [
      "apps/blog-writer/lib/shared.ts",
      "apps/blog-writer/lib/mine.ts",
    ],
    getInterveningCommitCount: () => 3,
    log: () => {},
    error: (msg) => errors.push(msg),
  });

  assert.equal(result.ok, false);
  assert.match(errors[0], /apps\/blog-writer\/lib\/shared\.ts/);
  assert.match(errors[0], /3/);
});

// The planted negative for overlap detection: pair the refusal above with an
// acceptance here on a disjoint change set. If overlap detection were ever
// vacuous (always true, or always false), one of this pair must fail.
test("verifyForMerge: base advanced with no overlapping changes -> merge OK, notes the skipped commit count", async () => {
  /** @type {string[]} */
  const logs = [];

  const result = await verifyForMerge({
    pr: 1748,
    getPrInfo: () => ({
      headSha: SHA_A,
      baseRef: DEFAULT_BRANCH,
      baseRepo: BASE_REPO,
    }),
    getDefaultBranch: () => DEFAULT_BRANCH,
    getStatus: () => ({
      state: "success",
      description: RECORDED_DESCRIPTION,
    }),
    fetchBase: () => {},
    getBaseTipSha: () => NEW_BASE_SHA,
    getInterveningFiles: () => ["apps/support/unrelated.ts"],
    getPrChangedFiles: () => ["apps/blog-writer/lib/mine.ts"],
    getInterveningCommitCount: () => 5,
    log: (msg) => logs.push(msg),
    error: () => {},
  });

  assert.equal(result.ok, true);
  assert.match(logs[0], /5/);
});

// ---------------------------------------------------------------------------
// P2 regression: the script must actually run main() when invoked as a real
// process, including from a path that needs percent-encoding to become a
// valid URL (e.g. a space). `process.argv[1]` is always an absolute,
// filesystem-form path for a real entry-point invocation -- it is NOT the
// "relative path" case that might look like the risk here. The actual defect
// in the original `import.meta.url === \`file://${process.argv[1]}\`` check
// is that hand-concatenating "file://" + a raw path never percent-encodes
// anything, while `import.meta.url` always does, so any path containing a
// character that needs encoding (a space is the common one) can never match
// -- main() silently never runs, and the process exits 0 with no output.
// ---------------------------------------------------------------------------

const SCRIPT_PATH = fileURLToPath(
  new URL("../bin/record-pro-gate-verdict.mjs", import.meta.url),
);

for (const renameSide of ["base", "candidate"]) {
  for (const overlapPath of ["old.txt", "new.txt", "unrelated.txt"]) {
    test(`CLI ${overlapPath === "unrelated.txt" ? "accepts disjoint change" : "refuses overlap"} on ${overlapPath} of a ${renameSide} rename`, (t) => {
      const dir = mkdtempSync(join(tmpdir(), "pro-gate-rename-"));
      t.after(() => rmSync(dir, { recursive: true, force: true }));
      const bin = join(dir, "bin");
      mkdirSync(bin);
      const env = {
        ...process.env,
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_CONFIG_GLOBAL: "/dev/null",
        GIT_AUTHOR_NAME: "Fixture",
        GIT_AUTHOR_EMAIL: "fixture@example.invalid",
        GIT_COMMITTER_NAME: "Fixture",
        GIT_COMMITTER_EMAIL: "fixture@example.invalid",
      };
      /** @param {...string} args */
      const git = (...args) =>
        execFileSync("git", args, { cwd: dir, env, encoding: "utf8" }).trim();
      git("init", "-q", "-b", "main");
      writeFileSync(join(dir, "old.txt"), "original content\n".repeat(20));
      git("add", "old.txt");
      git("commit", "-qm", "shared base");
      const base = git("rev-parse", "HEAD");
      /** @param {string} side */
      const change = (side) => {
        if (side === renameSide) git("mv", "old.txt", "new.txt");
        else {
          writeFileSync(
            join(dir, overlapPath),
            "candidate edit\n" + "original content\n".repeat(19),
          );
          git("add", overlapPath);
        }
        git("commit", "-qm", `${side} change`);
      };
      git("checkout", "-qb", "candidate");
      change("candidate");
      const head = git("rev-parse", "HEAD");
      git("checkout", "-q", "main");
      change("base");
      git("checkout", "-q", "candidate");
      git("remote", "add", "origin", dir);
      const description = buildDescription({
        verdict: "SHIP",
        baseRepo: BASE_REPO,
        baseRef: "main",
        baseSha: base,
        evidence: EVIDENCE,
        now: new Date("2026-10-13T04:00:00Z"),
      });
      const status = {
        statuses: [{ context: STATUS_CONTEXT, state: "success", description }],
      };
      writeFileSync(
        join(bin, "gh"),
        `#!/bin/bash\ncase "$1 $2" in\n'repo view') printf '%s\\n' '${BASE_REPO}';;\n'api repos/${BASE_REPO}/pulls/1748') printf '%s\\n' '{"head":{"sha":"${head}"},"base":{"ref":"main","repo":{"full_name":"${BASE_REPO}"}}}';;\n'api repos/${BASE_REPO}') printf '%s\\n' 'main';;\n'api repos/${BASE_REPO}/commits/${head}/status') printf '%s\\n' '${JSON.stringify(status)}';;\n*) exit 9;;\nesac\n`,
        { mode: 0o755 },
      );
      const result = spawnSync(
        process.execPath,
        [SCRIPT_PATH, "--verify-for-merge", "--pr", "1748"],
        {
          cwd: dir,
          env: { ...env, PATH: `${bin}:${process.env.PATH}` },
          encoding: "utf8",
        },
      );
      assert.equal(
        result.status,
        overlapPath === "unrelated.txt" ? 0 : 1,
        result.stdout + result.stderr,
      );
      if (overlapPath !== "unrelated.txt") {
        assert.match(result.stderr, /base moved with overlapping changes/);
        assert.ok(result.stderr.includes(overlapPath));
      }
    });
  }
}

test("P2 regression: invoking the script from a path containing a space still runs main()", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "pro-gate verdict-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const scriptCopy = join(dir, "record-pro-gate-verdict.mjs");
  copyFileSync(SCRIPT_PATH, scriptCopy);

  const result = spawnSync(process.execPath, [scriptCopy], {
    encoding: "utf8",
  });

  // Before the pathToFileURL fix: exit 0, empty stdout/stderr -- main()
  // silently never runs because the space in `scriptCopy` is never
  // percent-encoded on the naive side of the comparison. After the fix,
  // missing required args still reach parseArgs and produce the usual
  // usage error.
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing required argument\(s\)/);
});

test("P2 regression: invoking the script from an ordinary absolute path still runs main()", () => {
  const result = spawnSync(process.execPath, [SCRIPT_PATH], {
    encoding: "utf8",
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing required argument\(s\)/);
});

function acceptedProof(verdict = "SHIP") {
  return {
    facts: {
      schema: "review-facts/v1",
      status: "accepted",
      reason: "matching-current-proof",
      repository: {
        host: "github.com",
        owner: "StartupBros-com",
        repo: "pushbot",
      },
      pr: 1748,
      candidate_head: SHA_A,
      selected_marker: "pg-run-test-1748-1700000000-1",
      applicable: true,
      review: {
        canonical_identity: "c".repeat(64),
        artifact_digest: "d".repeat(64),
        charged_spend_epoch: 1700000000,
        reviewed_head: SHA_A,
        evidence_mode: "full-pr",
        evidence_identity: "full-pr:fixture",
        verdict,
        named_choice: null,
        named_choices: [],
        open_p0: 0,
        open_p1: 0,
      },
    },
    base: { repo: BASE_REPO, ref: DEFAULT_BRANCH, sha: BASE_SHA },
  };
}

test("claimed SHIP without accepted public facts posts nothing", async () => {
  const calls = [];
  const result = await run({
    pr: 1983,
    verdict: "SHIP",
    reviewedSha: "a".repeat(40),
    evidence: "https://example.invalid/review",
    getPrInfo: () => ({
      headSha: "a".repeat(40),
      baseRef: "main",
      baseRepo: "acme/widgets",
    }),
    getDefaultBranch: () => "main",
    getLiveBaseTip: () => "b".repeat(40),
    postStatus: (status) => calls.push(status),
    log: () => {},
    error: () => {},
  });
  assert.equal(result.ok, false);
  assert.deepEqual(calls, []);
});

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const hashBytes = (bytes) => createHash("sha256").update(bytes).digest("hex");
const canonical = (value) =>
  JSON.stringify(value, (_, item) =>
    item && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(
          Object.entries(item).sort(([a], [b]) => a.localeCompare(b)),
        )
      : item,
  );

// Real public acceptance, preparation and git objects; only GitHub/network IO is synthetic.
// These records are test inputs, not a live review, posted status, or release verification.
function cliFixture(t, installed = false) {
  const dir = mkdtempSync(join(tmpdir(), "pg-status integration-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const home = join(dir, "home");
  const bin = join(home, ".local", "bin");
  const checkout = join(dir, "checkout");
  const state = join(dir, "state");
  const temporary = join(dir, "temporary");
  for (const path of [bin, checkout, state, temporary])
    mkdirSync(path, { recursive: true });
  const env = Object.fromEntries(
    Object.entries(process.env).filter(
      ([key]) => !key.startsWith("PRO_GATE_") && !key.startsWith("ORACLE_"),
    ),
  );
  Object.assign(env, {
    HOME: home,
    PRO_GATE_HOME: state,
    ORACLE_DIR: join(dir, "oracle"),
    TMPDIR: temporary,
    PATH: `${bin}:${process.env.PATH}`,
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_AUTHOR_NAME: "Synthetic fixture",
    GIT_AUTHOR_EMAIL: "fixture@example.invalid",
    GIT_COMMITTER_NAME: "Synthetic fixture",
    GIT_COMMITTER_EMAIL: "fixture@example.invalid",
  });
  const realGit = execFileSync("which", ["git"], { encoding: "utf8" }).trim();
  const git = (...args) =>
    execFileSync(realGit, args, {
      cwd: checkout,
      env,
      encoding: "utf8",
    }).trim();
  git("init", "-q", "-b", "main");
  writeFileSync(join(checkout, "shared.txt"), "base content\n");
  git("add", "shared.txt");
  git("commit", "-qm", "synthetic base");
  const base = git("rev-parse", "HEAD");
  git("checkout", "-qb", "candidate");
  writeFileSync(join(checkout, "shared.txt"), "reviewed candidate\n");
  git("add", "shared.txt");
  git("commit", "-qm", "synthetic candidate");
  const head = git("rev-parse", "HEAD");
  git("remote", "add", "origin", "https://github.com/acme/widgets.git");
  const endpoint = join(dir, "endpoint.patch");
  const patch = execFileSync(realGit, ["diff", `${base}...${head}`], {
    cwd: checkout,
    env,
    encoding: "utf8",
  });
  writeFileSync(endpoint, patch);
  const evidenceFile = join(dir, "pr-evidence.json");
  const metadata = {
    repository: { host: "github.com", owner: "acme", repo: "widgets" },
    target: { pr: 1983, base_ref: "main", base_oid: base, head_oid: head },
  };
  const rawDigest = hashBytes(patch);
  writeFileSync(
    evidenceFile,
    canonical({
      record_type: "review-pr-evidence/v1",
      record_version: 1,
      patch_format: "github-compare-diff",
      metadata,
      endpoint_digest: rawDigest,
    }),
  );
  const configFile = join(dir, "network.json");
  const networkCalls = join(dir, "network-calls.jsonl");
  writeFileSync(networkCalls, "");
  const configure = (overrides = {}) =>
    writeFileSync(
      configFile,
      JSON.stringify({
        head,
        base,
        liveBase: base,
        snapshotBase: base,
        baseRef: "main",
        baseRepo: "acme/widgets",
        ...overrides,
      }),
    );
  configure();
  writeFileSync(
    join(bin, "gh"),
    String.raw`#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
const cfg = JSON.parse(fs.readFileSync(${JSON.stringify(configFile)}, 'utf8'));
const calls = fs.readFileSync(${JSON.stringify(networkCalls)}, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
fs.appendFileSync(${JSON.stringify(networkCalls)}, JSON.stringify(args)+'\n');
const output = (value) => process.stdout.write(typeof value === 'string' ? value+'\n' : JSON.stringify(value)+'\n');
if (args.includes('POST')) {
  if (cfg.postFail) process.exit(9);
  output({});
} else if (args[0] === 'pr' && args[1] === 'view') {
  if (cfg.metadataFail) process.exit(9);
  if (cfg.truncatedMetadata) output('{"number":1983');
  else output({number:1983,url:'https://github.com/acme/widgets/pull/1983',state:'OPEN',baseRefName:cfg.baseRef,baseRefOid:cfg.snapshotBase,headRefOid:cfg.head});
} else if (args[1] === 'repos/acme/widgets/pulls/1983') {
  if (cfg.pullFail) process.exit(9);
  const count = calls.filter((a) => a[1] === args[1]).length + 1;
  output({head:{sha:cfg.headMovesAt && count >= cfg.headMovesAt ? 'e'.repeat(40) : cfg.head},base:{ref:cfg.refMovesAt && count >= cfg.refMovesAt ? 'staging' : cfg.baseRef,sha:cfg.snapshotBase,repo:{full_name:cfg.baseRepo}}});
} else if (args[1] === 'repos/acme/widgets') output(cfg.defaultBranch || 'main');
else if (args[1]?.startsWith('repos/acme/widgets/branches/')) {
  const count = calls.filter((a) => a[1]?.startsWith('repos/acme/widgets/branches/')).length + 1;
  output(cfg.tipMovesAt && count >= cfg.tipMovesAt ? 'f'.repeat(40) : cfg.liveBase);
} else if (args[1]?.startsWith('repos/acme/widgets/compare/')) {
  if (cfg.prepareFail) { process.stderr.write('synthetic compare API failure\n'); process.exit(9); }
  process.stdout.write(fs.readFileSync(${JSON.stringify(endpoint)}, 'utf8'));
} else if (args[1]?.endsWith('/status')) {
  if (cfg.truncatedStatus) output('{"statuses":[');
  else if (cfg.statusResponse) output(cfg.statusResponse);
  else {
    const post = calls.filter((a) => a.includes('POST')).at(-1);
    const field = (name) => post?.find((a) => a.startsWith(name+'='))?.slice(name.length+1);
    output({statuses:post ? [{context:field('context'),state:field('state'),description:field('description')}] : []});
  }
} else { process.stderr.write('unexpected synthetic gh call '+args.join(' ')+'\n'); process.exit(9); }
`,
    { mode: 0o755 },
  );
  // Fetch is network IO. Publish the configured synthetic remote tip into real local git objects;
  // every rev-parse, diff, no-renames path and count operation uses the real git executable.
  writeFileSync(
    join(bin, "git"),
    `#!${process.execPath}
const fs = require('node:fs');
const cp = require('node:child_process');
const args = process.argv.slice(2);
if (args[0] === 'fetch') {
  const cfg = JSON.parse(fs.readFileSync(${JSON.stringify(configFile)}, 'utf8'));
  cp.execFileSync(${JSON.stringify(realGit)}, ['update-ref', 'refs/remotes/origin/'+args[2], cfg.liveBase]);
} else {
  const result = cp.spawnSync(${JSON.stringify(realGit)}, args, {stdio:'inherit'});
  process.exit(result.status ?? 1);
}
`,
    { mode: 0o755 },
  );
  let script = SCRIPT_PATH;
  if (installed) {
    const result = spawnSync(
      "/bin/bash",
      [join(ROOT, "install.sh"), "--local-source", "--skip-services"],
      { env, encoding: "utf8" },
    );
    assert.equal(result.status, 0, result.stdout + result.stderr);
    script = join(state, "record-pro-gate-verdict.mjs");
  }
  const marker = "pg-run-acme-widgets-1983-1700000700-1";
  const retainedPaths = [
    "completed",
    "review-input-bindings",
    "review-result-bindings",
  ].map((path) => join(state, path, marker));
  const identity = JSON.parse(
    readFileSync(join(ROOT, "skills/pro-gate/review-decision-v1.json"), "utf8"),
  );
  const retain = (verdict = "SHIP", options = {}) => {
    const reviewedHead = options.head ?? head;
    const mode = options.mode ?? "full-pr";
    const proof =
      mode === "full-pr"
        ? {
            base_oid: base,
            head_oid: reviewedHead,
            endpoint_digest: rawDigest,
            raw_patch_digest: rawDigest,
            pr_metadata_digest: hashBytes(canonical(metadata)),
          }
        : {
            base_oid: base,
            end_oid: reviewedHead,
            raw_digest: rawDigest,
            reviewed_payload_digest: hashBytes(readFileSync(options.diff)),
            filtering_manifest_digest: hashBytes(
              readFileSync(options.manifest),
            ),
            lineage_identity: `confirmation:${hashBytes(readFileSync(options.confirm))}`,
            pr_metadata_digest: hashBytes(canonical(metadata)),
            scope_algorithm: "unified-diff-v1",
          };
    const input = {
      charged_spend_epoch: 1700000700,
      contract_digest: identity.contract_digest,
      contract_id: "review-decision/v1",
      contract_version: 1,
      evidence: {
        identity:
          mode === "full-pr"
            ? `full-pr:${base}:${reviewedHead}`
            : `scoped-delta:${base}:${reviewedHead}:${proof.reviewed_payload_digest}`,
        mode,
        proof,
      },
      marker,
      record_type: "review-input-binding/v1",
      record_version: 1,
      repository: metadata.repository,
      target: {
        head_oid: reviewedHead,
        kind: "pull-request",
        pr: options.pr ?? 1983,
      },
    };
    const artifact = `P0: none\nP1: none\nP2: none\nSynthetic retained review, not a live model result.\n${options.choices ? "CHOICE: keep | Preserve | Keep compatibility\nCHOICE: break | Replace | Use new API\n" : ""}VERDICT: ${verdict}\n`;
    const result = {
      accepted_epoch: 1700000800,
      artifact: { digest: hashBytes(artifact), path: `completed/${marker}` },
      contract_digest: identity.contract_digest,
      contract_id: "review-decision/v1",
      contract_version: 1,
      input_binding_digest: hashBytes(canonical(input)),
      input_binding_identity: marker,
      marker,
      named_choice: null,
      provenance: { outcome: "accepted", validated_epoch: 1700000800 },
      record_type: "review-result-binding/v1",
      record_version: 1,
      ship_proof:
        verdict === "SHIP"
          ? { base_oid: base, head_oid: reviewedHead, diff_digest: rawDigest }
          : null,
      verdict,
    };
    for (const path of retainedPaths)
      mkdirSync(join(path, ".."), { recursive: true });
    retainedPaths.forEach((path, i) =>
      writeFileSync(path, [artifact, canonical(input), canonical(result)][i]),
    );
  };
  retain();
  const calls = () =>
    readFileSync(networkCalls, "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(JSON.parse);
  const invoke = (flags = [], extraEnv = {}) =>
    spawnSync(
      process.execPath,
      [
        script,
        "--pr",
        "1983",
        "--verdict",
        "SHIP",
        "--reviewed-sha",
        head,
        "--evidence",
        "https://example.invalid/review",
        ...flags,
      ],
      { cwd: checkout, env: { ...env, ...extraEnv }, encoding: "utf8" },
    );
  const posts = () => calls().filter((args) => args.includes("POST"));
  return {
    dir,
    state,
    checkout,
    temporary,
    env,
    base,
    head,
    endpoint,
    evidenceFile,
    retainedPaths,
    git,
    configure,
    retain,
    calls,
    posts,
    invoke,
    script,
  };
}

test("installed CLI records exactly one exact-current SHIP using real public facts and accepts unchanged/disjoint base", (t) => {
  const f = cliFixture(t, true);
  const before = f.retainedPaths.map((path) => readFileSync(path, "utf8"));
  const result = f.invoke();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(f.posts().length, 1);
  assert.ok(f.posts()[0].includes(`repos/acme/widgets/statuses/${f.head}`));
  assert.ok(f.posts()[0].includes("state=success"));
  assert.ok(
    f
      .posts()[0]
      .some((arg) =>
        arg.includes(`base acme/widgets@main@${f.base.slice(0, 12)}`),
      ),
  );
  assert.deepEqual(
    f.retainedPaths.map((path) => readFileSync(path, "utf8")),
    before,
  );
  assert.deepEqual(
    readdirSync(f.temporary),
    [],
    "private preparation files cleaned",
  );
  assert.equal(f.invoke(["--verify-for-merge"]).status, 0);
  f.git("checkout", "-q", "main");
  writeFileSync(
    join(f.checkout, "unrelated.txt"),
    "unrelated base advancement\n",
  );
  f.git("add", "unrelated.txt");
  f.git("commit", "-qm", "synthetic disjoint advancement");
  const advanced = f.git("rev-parse", "HEAD");
  f.git("checkout", "-q", "candidate");
  f.configure({ liveBase: advanced });
  const verified = f.invoke(["--verify-for-merge"]);
  assert.equal(verified.status, 0, verified.stdout + verified.stderr);
  assert.match(verified.stdout, /advanced 1 commit/);
  assert.equal(f.posts().length, 1, "verification never writes another status");
});

test("public adapter explicitly rejects owner-state in both modes, including equals spelling", () => {
  for (const prefix of [[], ["--verify-for-merge"]]) {
    for (const flags of [
      ["--owner-state", "/tmp/state"],
      ["--owner-state=/tmp/state"],
    ]) {
      assert.throws(
        () => parseArgs([...prefix, "--pr", "1983", ...flags]),
        /not supported/,
      );
      const result = spawnSync(
        process.execPath,
        [SCRIPT_PATH, ...prefix, "--pr", "1983", ...flags],
        { encoding: "utf8" },
      );
      assert.equal(result.status, 1);
      assert.match(result.stderr, /owner-state is not supported/);
    }
  }
});

test("record rejects unaccepted, noncurrent, mismatched, incomplete or choice-bearing SHIP facts", async () => {
  const initial = acceptedProof();
  const changes = [
    { schema: "review-facts/v2" },
    { status: "invalid" },
    { status: "missing" },
    { status: "ambiguous" },
    { status: "incomplete" },
    { applicable: false },
    { applicable: null },
    {
      repository: {
        host: "gitlab.com",
        owner: "StartupBros-com",
        repo: "pushbot",
      },
    },
    { repository: { host: "github.com", owner: "elsewhere", repo: "pushbot" } },
    { pr: 1749 },
    { candidate_head: SHA_B },
    { selected_marker: null },
    { review: null },
    ...[
      { reviewed_head: SHA_B },
      { canonical_identity: "" },
      { artifact_digest: "bad" },
      { evidence_identity: "" },
      { charged_spend_epoch: 0 },
      { evidence_mode: "connector" },
      { verdict: "FIX-FIRST" },
      { verdict: "MAYBE" },
      { open_p0: -1 },
      { open_p1: -1 },
      { open_p0: "0" },
      { named_choice: { id: "keep" } },
      { named_choices: [{ id: "keep" }] },
      { named_choices: undefined },
      { named_choice: undefined },
    ].map((review) => ({ review: { ...initial.facts.review, ...review } })),
  ];
  for (const change of changes) {
    const { calls, postStatus } = statusSpy();
    const result = await run(
      baseRunArgs({
        postStatus,
        getReviewFacts: () => ({
          ...initial,
          facts: { ...initial.facts, ...change },
        }),
      }),
    );
    assert.equal(result.ok, false, JSON.stringify(change));
    assert.equal(calls.length, 0);
  }
  for (const base of [
    { ...initial.base, sha: NEW_BASE_SHA },
    { ...initial.base, ref: "staging" },
    { ...initial.base, repo: "other/repo" },
    null,
  ]) {
    const { calls, postStatus } = statusSpy();
    const result = await run(
      baseRunArgs({ postStatus, getReviewFacts: () => ({ ...initial, base }) }),
    );
    assert.equal(result.ok, false);
    assert.equal(calls.length, 0);
  }
});

test("foreign current base refuses even when its asserted facts match that base", async () => {
  const { calls, postStatus } = statusSpy();
  assert.equal(
    (await run(baseRunArgs({ repoSlug: "other/repo", postStatus }))).ok,
    false,
  );
  assert.equal(calls.length, 0);
});

test("asynchronous accepted public facts preserve exact-current success", async () => {
  const { calls, postStatus } = statusSpy();
  assert.equal(
    (
      await run(
        baseRunArgs({
          getReviewFacts: async () => acceptedProof(),
          postStatus,
        }),
      )
    ).ok,
    true,
  );
  assert.equal(calls.length, 1);
});

test("base tip moving during proof inspection refuses without recording", async () => {
  let tips = 0;
  const { calls, postStatus } = statusSpy();
  const result = await run(
    baseRunArgs({
      postStatus,
      getLiveBaseTip: () => (++tips === 1 ? BASE_SHA : NEW_BASE_SHA),
    }),
  );
  assert.equal(result.ok, false);
  assert.equal(tips, 2);
  assert.equal(calls.length, 0);
});

for (const [label, change] of [
  ["absent evidence", (f) => rmSync(f.retainedPaths[0])],
  ["historical review", (f) => f.retain("SHIP", { head: "b".repeat(40) })],
  [
    "corrupt artifact",
    (f) => writeFileSync(f.retainedPaths[0], "corrupt after acceptance\n"),
  ],
  ["wrong target", (f) => f.retain("SHIP", { pr: 1984 })],
  ["choice-bearing SHIP", (f) => f.retain("SHIP", { choices: true })],
  ["verdict disagreement", (f) => f.retain("FIX-FIRST")],
  ["failed preparation", (f) => f.configure({ prepareFail: true })],
  ["metadata API error", (f) => f.configure({ metadataFail: true })],
  ["truncated metadata JSON", (f) => f.configure({ truncatedMetadata: true })],
  ["pull API error", (f) => f.configure({ pullFail: true })],
  ["wrong live head", (f) => f.configure({ head: "e".repeat(40) })],
  ["head moves in final read", (f) => f.configure({ headMovesAt: 2 })],
  ["base retargets in final read", (f) => f.configure({ refMovesAt: 2 })],
  ["base tip moves in final read", (f) => f.configure({ tipMovesAt: 2 })],
  [
    "foreign base repository",
    (f) => f.configure({ baseRepo: "foreign/widgets" }),
  ],
  ["nondefault base", (f) => f.configure({ defaultBranch: "main-v2" })],
  [
    "cached base snapshot differs from live tip",
    (f) => f.configure({ snapshotBase: "a".repeat(40) }),
  ],
]) {
  test(`real public CLI: ${label} cannot record success; restored allowed case passes`, (t) => {
    const f = cliFixture(t);
    change(f);
    const refused = f.invoke();
    assert.equal(refused.status, 1, refused.stdout + refused.stderr);
    assert.equal(f.posts().length, 0, label);
    assert.deepEqual(
      readdirSync(f.temporary),
      [],
      "failed preparation cleans private temporary files",
    );
    f.retain();
    f.configure();
    // Rechecks count earlier calls too; clearing the network transcript isolates the restored case.
    writeFileSync(join(f.dir, "network-calls.jsonl"), "");
    const restored = f.invoke();
    assert.equal(restored.status, 0, restored.stdout + restored.stderr);
    assert.equal(f.posts().length, 1);
  });
}

for (const verdict of ["FIX-FIRST", "NEEDS-DISCUSSION"]) {
  test(`real public CLI records accepted ${verdict} as failure, including named alternatives`, (t) => {
    const f = cliFixture(t);
    f.retain(verdict, { choices: true });
    const result = f.invoke(["--verdict", verdict]);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(f.posts().length, 1);
    assert.ok(f.posts()[0].includes("state=failure"));
    assert.ok(!f.posts()[0].includes("state=success"));
    assert.equal(f.invoke(["--verify-for-merge"]).status, 1);
    assert.equal(f.posts().length, 1);
  });
}

test("explicit public proof environment is reused but must bind to live base, not cached pull snapshot", (t) => {
  const f = cliFixture(t);
  const proofEnv = {
    PRO_GATE_REVIEW_ENDPOINT_PATCH: f.endpoint,
    PRO_GATE_REVIEW_PR_EVIDENCE: f.evidenceFile,
  };
  f.configure({ snapshotBase: "a".repeat(40), prepareFail: true });
  const allowed = f.invoke([], proofEnv);
  assert.equal(allowed.status, 0, allowed.stdout + allowed.stderr);
  assert.equal(f.posts().length, 1);
  assert.ok(
    f
      .calls()
      .every((args) => args[0] !== "pr" && !args[1]?.includes("/compare/")),
  );
  assert.ok(f.posts()[0].some((arg) => arg.includes(f.base.slice(0, 12))));
  f.configure({ liveBase: "b".repeat(40) });
  assert.equal(f.invoke([], proofEnv).status, 1);
  assert.equal(f.posts().length, 1);
  assert.ok(
    existsSync(f.endpoint) && existsSync(f.evidenceFile),
    "caller-owned proof is never cleaned",
  );
  f.configure();
  for (const partialProof of [
    { PRO_GATE_REVIEW_ENDPOINT_PATCH: f.endpoint },
    { PRO_GATE_REVIEW_PR_EVIDENCE: f.evidenceFile },
  ]) {
    const incomplete = f.invoke([], partialProof);
    assert.equal(incomplete.status, 1);
    assert.match(incomplete.stderr, /Explicit proof requires both/);
    assert.equal(f.posts().length, 1);
  }
  const restored = f.invoke([], proofEnv);
  assert.equal(restored.status, 0, restored.stdout + restored.stderr);
  assert.equal(f.posts().length, 2);
});

test("real scoped public proof requires separate reviewed payload, endpoint, manifest and confirmation; no full-PR fallback", (t) => {
  const f = cliFixture(t);
  const diff = join(f.dir, "scoped.patch");
  const manifest = join(f.dir, "manifest");
  const confirm = join(f.dir, "confirmation.md");
  writeFileSync(diff, "synthetic filtered payload\n");
  writeFileSync(manifest, "shared.txt\n");
  writeFileSync(
    confirm,
    "P0: none\nP1: none\nP2: none\nVERDICT: SHIP - synthetic confirmation.\n",
  );
  f.retain("SHIP", { mode: "scoped-delta", diff, manifest, confirm });
  const flags = ["--diff", diff, "--confirm", confirm];
  const env = { PRO_GATE_REVIEW_FILTER_MANIFEST: manifest };
  const allowed = f.invoke(flags, env);
  assert.equal(allowed.status, 0, allowed.stdout + allowed.stderr);
  assert.equal(f.posts().length, 1);
  for (const field of [diff, manifest, confirm]) {
    const old = readFileSync(field, "utf8");
    writeFileSync(field, old + "changed bytes\n");
    assert.equal(f.invoke(flags, env).status, 1, field);
    assert.equal(f.posts().length, 1);
    writeFileSync(field, old);
  }
  for (const [missingFlags, missingEnv] of [
    [[], env],
    [["--diff", diff], env],
    [flags, {}],
  ]) {
    assert.equal(f.invoke(missingFlags, missingEnv).status, 1);
    assert.equal(f.posts().length, 1);
  }
  assert.equal(f.invoke(flags, env).status, 0);
  assert.equal(
    f.posts().length,
    2,
    "restoring every required scoped input re-enables recording",
  );
});

test("CLI verification fails on missing, malformed, ambiguous, failed and truncated status reads", (t) => {
  const f = cliFixture(t);
  assert.equal(f.invoke(["--verify-for-merge"]).status, 1);
  assert.equal(f.invoke().status, 0);
  const description = `SHIP · base acme/widgets@main@${f.base.slice(0, 12)} · recorded 2026-10-13 · evidence`;
  for (const statusResponse of [
    {},
    { statuses: [{ context: STATUS_CONTEXT, state: "failure", description }] },
    {
      statuses: [
        { context: STATUS_CONTEXT, state: "success", description },
        { context: STATUS_CONTEXT, state: "success", description },
      ],
    },
    {
      statuses: [
        {
          context: STATUS_CONTEXT,
          state: "success",
          description: description.replace("SHIP", "FIX-FIRST"),
        },
      ],
    },
  ]) {
    f.configure({ statusResponse });
    assert.equal(f.invoke(["--verify-for-merge"]).status, 1);
  }
  f.configure({ truncatedStatus: true });
  assert.equal(f.invoke(["--verify-for-merge"]).status, 1);
  f.configure();
  assert.equal(f.invoke(["--verify-for-merge"]).status, 0);
  assert.equal(f.posts().length, 1);
});

test("shared base helpers compare git objects without statuses, fetches, or owner policy", async (t) => {
  const f = cliFixture(t);
  assert.deepEqual(
    await checkGitBaseAdvance(f.checkout, f.base, f.base, f.head),
    { ok: true, unchanged: true, overlap: [], commitCount: 0 },
  );
  f.git("checkout", "-q", "main");
  writeFileSync(join(f.checkout, "shared.txt"), "overlapping base edit\n");
  f.git("add", "shared.txt");
  f.git("commit", "-qm", "synthetic overlapping advancement");
  const advanced = f.git("rev-parse", "HEAD");
  f.git("checkout", "-q", "candidate");
  assert.deepEqual(
    await checkGitBaseAdvance(f.checkout, f.base, advanced, f.head),
    { ok: false, unchanged: false, overlap: ["shared.txt"], commitCount: 1 },
  );
  assert.deepEqual(f.calls(), []);
  await assert.rejects(
    checkBaseAdvance({
      originalBase: "bad",
      currentBase: advanced,
      head: f.head,
    }),
    /SHA/,
  );
});

for (const [label, field] of [
  ["head", "headSha"],
  ["base ref", "baseRef"],
  ["base repository", "baseRepo"],
]) {
  test(`strict verification refuses a ${label} change during final recheck`, async () => {
    let reads = 0;
    const result = await verifyForMerge({
      pr: 1748,
      getPrInfo: () => ({
        headSha: SHA_A,
        baseRef: DEFAULT_BRANCH,
        baseRepo: BASE_REPO,
        ...(++reads === 1
          ? {}
          : { [field]: field === "headSha" ? SHA_B : "changed" }),
      }),
      getDefaultBranch: () => DEFAULT_BRANCH,
      getStatus: () => ({
        state: "success",
        description: RECORDED_DESCRIPTION,
      }),
      fetchBase: () => {},
      getBaseTipSha: () => BASE_SHA,
      getInterveningFiles: shouldNotBeCalled,
      getPrChangedFiles: shouldNotBeCalled,
      getInterveningCommitCount: shouldNotBeCalled,
      log: () => {},
      error: () => {},
    });
    assert.equal(result.ok, false);
    assert.equal(reads, 2);
  });
}

test("strict verification refuses base-tip movement after an otherwise disjoint comparison", async () => {
  let reads = 0;
  const result = await verifyForMerge({
    pr: 1748,
    getPrInfo: () => ({
      headSha: SHA_A,
      baseRef: DEFAULT_BRANCH,
      baseRepo: BASE_REPO,
    }),
    getDefaultBranch: () => DEFAULT_BRANCH,
    getStatus: () => ({ state: "success", description: RECORDED_DESCRIPTION }),
    fetchBase: () => {},
    getBaseTipSha: () => (++reads === 1 ? NEW_BASE_SHA : "a".repeat(40)),
    getInterveningFiles: () => ["unrelated.ts"],
    getPrChangedFiles: () => ["reviewed.ts"],
    getInterveningCommitCount: () => 1,
    log: () => {},
    error: () => {},
  });
  assert.equal(result.ok, false);
  assert.equal(reads, 2);
});

test("malformed/truncated public facts cannot record a status", async () => {
  for (const facts of [null, [], {}, '{"schema":"review-facts/v1"']) {
    const { calls, postStatus } = statusSpy();
    const result = await run(
      baseRunArgs({
        postStatus,
        getReviewFacts: () => ({ ...acceptedProof(), facts }),
      }),
    );
    assert.equal(result.ok, false);
    assert.equal(calls.length, 0);
  }
});

test("accepted verdict is not reinterpreted by a second severity-based merge policy", async () => {
  const proof = acceptedProof();
  proof.facts.review.open_p1 = 1;
  const { calls, postStatus } = statusSpy();
  assert.equal(
    (await run(baseRunArgs({ getReviewFacts: () => proof, postStatus }))).ok,
    true,
  );
  assert.equal(calls.length, 1);
});

test("runtime archive includes and installs the sibling public adapter without a version bump", (t) => {
  const f = cliFixture(t);
  const output = join(f.dir, "package");
  const packaged = spawnSync(
    "/bin/bash",
    [join(ROOT, "scripts/package-runtime.sh"), output],
    {
      env: {
        ...f.env,
        RELEASE_TAG: `v${readFileSync(join(ROOT, "VERSION"), "utf8").trim()}`,
      },
      encoding: "utf8",
    },
  );
  assert.equal(packaged.status, 0, packaged.stdout + packaged.stderr);
  const archive = packaged.stdout.trim();
  const install = spawnSync(
    "/bin/bash",
    [
      join(ROOT, "install.sh"),
      "--version",
      readFileSync(join(ROOT, "VERSION"), "utf8").trim(),
      "--archive",
      archive,
      "--checksum",
      `${archive}.sha256`,
      "--skip-services",
    ],
    { env: f.env, encoding: "utf8" },
  );
  assert.equal(install.status, 0, install.stdout + install.stderr);
  const adapter = join(f.state, "record-pro-gate-verdict.mjs");
  assert.equal(
    readFileSync(adapter, "utf8"),
    readFileSync(SCRIPT_PATH, "utf8"),
  );
  const result = spawnSync(
    process.execPath,
    [
      adapter,
      "--pr",
      "1983",
      "--verdict",
      "SHIP",
      "--reviewed-sha",
      f.head,
      "--evidence",
      "https://example.invalid/review",
    ],
    { cwd: f.checkout, env: f.env, encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(f.posts().length, 1);
});

test("local-object comparison preserves whitespace and newline filenames without false disjointness", async (t) => {
  const f = cliFixture(t);
  f.git("checkout", "-q", "main");
  const file = " space\nname.txt ";
  writeFileSync(join(f.checkout, file), "shared base\n");
  f.git("add", file);
  f.git("commit", "-qm", "synthetic unusual path");
  const base = f.git("rev-parse", "HEAD");
  f.git("checkout", "-qb", "unusual-candidate");
  writeFileSync(join(f.checkout, file), "candidate edit\n");
  f.git("add", file);
  f.git("commit", "-qm", "synthetic unusual candidate");
  const head = f.git("rev-parse", "HEAD");
  f.git("checkout", "-q", "main");
  writeFileSync(join(f.checkout, file), "base edit\n");
  f.git("add", file);
  f.git("commit", "-qm", "synthetic unusual base");
  const current = f.git("rev-parse", "HEAD");
  const compared = await checkGitBaseAdvance(f.checkout, base, current, head);
  assert.equal(compared.ok, false);
  assert.deepEqual(compared.overlap, [file]);
});

test("a concurrent explicit-proof writer cannot bind facts from a different base to the earlier metadata read", (t) => {
  const f = cliFixture(t);
  f.git("checkout", "-q", "main");
  writeFileSync(
    join(f.checkout, "elsewhere.txt"),
    "synthetic alternate base\n",
  );
  f.git("add", "elsewhere.txt");
  f.git("commit", "-qm", "synthetic alternate base");
  const otherBase = f.git("rev-parse", "HEAD");
  f.git("checkout", "-q", "candidate");
  const original = [f.evidenceFile, ...f.retainedPaths].map((path) =>
    readFileSync(path, "utf8"),
  );
  const snapshot = JSON.parse(original[0]);
  snapshot.metadata.target.base_oid = otherBase;
  const input = JSON.parse(original[2]);
  input.evidence.identity = `full-pr:${otherBase}:${f.head}`;
  input.evidence.proof.base_oid = otherBase;
  input.evidence.proof.pr_metadata_digest = hashBytes(
    canonical(snapshot.metadata),
  );
  const result = JSON.parse(original[3]);
  result.input_binding_digest = hashBytes(canonical(input));
  result.ship_proof.base_oid = otherBase;
  const gitPath = join(f.env.HOME, ".local", "bin", "git");
  const originalGit = readFileSync(gitPath, "utf8");
  // A deterministic concurrent fixture writer changes files at the public inspection boundary.
  // Git still forwards every read to the real executable; no acceptance result is mocked.
  const writer = `if (args.includes('--is-inside-work-tree')) {
    fs.writeFileSync(${JSON.stringify(f.evidenceFile)}, ${JSON.stringify(canonical(snapshot))});
    fs.writeFileSync(${JSON.stringify(f.retainedPaths[1])}, ${JSON.stringify(canonical(input))});
    fs.writeFileSync(${JSON.stringify(f.retainedPaths[2])}, ${JSON.stringify(canonical(result))});
  }\n`;
  writeFileSync(
    gitPath,
    originalGit.replace(
      "if (args[0] === 'fetch')",
      writer + "if (args[0] === 'fetch')",
    ),
  );
  const proofEnv = {
    PRO_GATE_REVIEW_ENDPOINT_PATCH: f.endpoint,
    PRO_GATE_REVIEW_PR_EVIDENCE: f.evidenceFile,
  };
  const refused = f.invoke([], proofEnv);
  assert.equal(refused.status, 1, refused.stdout + refused.stderr);
  assert.equal(f.posts().length, 0);
  assert.deepEqual(readdirSync(f.temporary), []);
  writeFileSync(gitPath, originalGit);
  [f.evidenceFile, ...f.retainedPaths].forEach((path, i) =>
    writeFileSync(path, original[i]),
  );
  const restored = f.invoke([], proofEnv);
  assert.equal(restored.status, 0, restored.stdout + restored.stderr);
  assert.equal(f.posts().length, 1);
});

test("current accepted connector progress records failure through the existing public input proof contract", (t) => {
  const f = cliFixture(t);
  f.retain("FIX-FIRST");
  const input = JSON.parse(readFileSync(f.retainedPaths[1], "utf8"));
  input.evidence = {
    identity: `connector:github.com/acme/widgets:${f.head}`,
    mode: "connector",
    proof: {
      commit_target: f.head,
      endpoint_digest: null,
      raw_diff_digest: null,
      repository_target: "github.com/acme/widgets",
    },
  };
  const result = JSON.parse(readFileSync(f.retainedPaths[2], "utf8"));
  result.input_binding_digest = hashBytes(canonical(input));
  writeFileSync(f.retainedPaths[1], canonical(input));
  writeFileSync(f.retainedPaths[2], canonical(result));
  assert.equal(
    f.invoke(["--verdict", "FIX-FIRST"]).status,
    1,
    "default bundle proof does not match connector input",
  );
  const recorded = f.invoke(["--verdict", "FIX-FIRST", "--input", "connector"]);
  assert.equal(recorded.status, 0, recorded.stdout + recorded.stderr);
  assert.equal(f.posts().length, 1);
  assert.ok(f.posts()[0].includes("state=failure"));
  assert.equal(
    f.invoke(["--verdict", "SHIP", "--input", "connector"]).status,
    1,
  );
  assert.equal(
    f.posts().length,
    1,
    "connector progress never records successful SHIP",
  );
});

for (const [label, mutate] of [
  [
    "prose after choices",
    (artifact) =>
      artifact.replace("VERDICT:", "Choose before merging.\nVERDICT:"),
  ],
  [
    "duplicate choice IDs",
    (artifact) => artifact.replace("CHOICE: break", "CHOICE: keep"),
  ],
  [
    "one choice only",
    (artifact) =>
      artifact.replace("CHOICE: break | Replace | Use new API\n", ""),
  ],
  [
    "malformed choice grammar",
    (artifact) =>
      artifact.replace(
        "CHOICE: break | Replace | Use new API",
        "CHOICE: break | Replace",
      ),
  ],
]) {
  test(`malformed retained choices stay unknown and cannot record SHIP: ${label}`, (t) => {
    const f = cliFixture(t);
    f.retain("SHIP", { choices: true });
    const original = readFileSync(f.retainedPaths[0], "utf8");
    const artifact = mutate(original);
    assert.notEqual(artifact, original);
    writeFileSync(f.retainedPaths[0], artifact);
    const binding = JSON.parse(readFileSync(f.retainedPaths[2], "utf8"));
    binding.artifact.digest = hashBytes(artifact);
    writeFileSync(f.retainedPaths[2], canonical(binding));

    const refused = f.invoke();
    assert.equal(refused.status, 1, refused.stdout + refused.stderr);
    assert.equal(
      f.posts().length,
      0,
      "unknown choices must not become choice-free SHIP",
    );
    const inspected = spawnSync(
      "/bin/bash",
      [
        join(ROOT, "bin/oracle-review.sh"),
        "--review-facts",
        "--repo",
        f.checkout,
        "--pr",
        "1983",
        "--json",
      ],
      { env: f.env, encoding: "utf8" },
    );
    assert.equal(inspected.status, 0, inspected.stdout + inspected.stderr);
    const facts = JSON.parse(inspected.stdout);
    assert.equal(facts.status, "accepted");
    assert.equal(facts.review.artifact_digest, hashBytes(artifact));
    assert.equal(facts.review.named_choices, null);

    f.retain();
    const restored = f.invoke();
    assert.equal(restored.status, 0, restored.stdout + restored.stderr);
    assert.equal(f.posts().length, 1);
    assert.ok(f.posts()[0].includes("state=success"));
  });
}

test("inspection skill checks the matching runtime without browser or network preflight", (t) => {
  const f = cliFixture(t, true);
  const skill = readFileSync(join(ROOT, "skills/pro-gate/SKILL.md"), "utf8");
  const command = skill
    .split("## Retained inspection only\n")[1]
    .split("```bash\n")[1]
    .split("\n```")[0];
  const identity = JSON.parse(
    readFileSync(join(ROOT, "skills/pro-gate/review-decision-v1.json"), "utf8"),
  );
  const version = readFileSync(join(ROOT, "VERSION"), "utf8");
  const inspect = () =>
    spawnSync("/bin/bash", [], {
      input: command,
      encoding: "utf8",
      env: {
        ...f.env,
        REPO: f.checkout,
        PR: "1983",
        PG: join(f.state, "oracle-review.sh"),
        PLUGIN_VERSION: version.trim(),
        CONTRACT_ID: identity.contract_id,
        CONTRACT_VERSION: String(identity.contract_version),
        CONTRACT_DIGEST: identity.contract_digest,
        CORPUS_DIGEST: identity.corpus_digest,
      },
    });
  const matched = inspect();
  assert.equal(matched.status, 0, matched.stdout + matched.stderr);
  assert.equal(JSON.parse(matched.stdout).status, "accepted");
  for (const mismatchedVersion of ["0.0.0", "99.0.0", ""]) {
    writeFileSync(join(f.state, "VERSION"), mismatchedVersion);
    const refused = inspect();
    assert.equal(
      refused.status,
      1,
      `must refuse runtime version ${mismatchedVersion}: ${refused.stdout}`,
    );
    assert.match(refused.stderr, /exact version-update path/);
  }
  writeFileSync(join(f.state, "VERSION"), version);
  writeFileSync(
    join(f.state, "review-decision-v1.json"),
    canonical({ ...identity, corpus_digest: "0".repeat(64) }),
  );
  const mismatch = inspect();
  assert.equal(mismatch.status, 1, mismatch.stdout + mismatch.stderr);
  assert.match(mismatch.stderr, /exact version-update path/);
  writeFileSync(join(f.state, "review-decision-v1.json"), canonical(identity));
  const restored = inspect();
  assert.equal(restored.status, 0, restored.stdout + restored.stderr);
  assert.equal(JSON.parse(restored.stdout).status, "accepted");
  assert.deepEqual(f.calls(), [], "inspection never invokes network preflight");
});

for (const proofMode of ["prepared", "explicit"]) {
  test(`status recording uses the proven PR head from a default-branch checkout: ${proofMode}`, (t) => {
    const f = cliFixture(t);
    const proofEnv =
      proofMode === "explicit"
        ? {
            PRO_GATE_REVIEW_ENDPOINT_PATCH: f.endpoint,
            PRO_GATE_REVIEW_PR_EVIDENCE: f.evidenceFile,
          }
        : {};
    f.git("checkout", "-q", "main");
    assert.equal(f.git("rev-parse", "HEAD"), f.base);
    const recorded = f.invoke([], proofEnv);
    assert.equal(recorded.status, 0, recorded.stdout + recorded.stderr);
    assert.equal(f.posts().length, 1);
    assert.ok(f.posts()[0].includes(`repos/acme/widgets/statuses/${f.head}`));
    assert.ok(f.posts()[0].includes("state=success"));
    assert.equal(
      f.git("rev-parse", "HEAD"),
      f.base,
      "recording must not switch branches",
    );

    f.configure({ head: f.base });
    const stale = f.invoke([], proofEnv);
    assert.equal(stale.status, 1, stale.stdout + stale.stderr);
    assert.equal(f.posts().length, 1, "a changed live PR head still refuses");
  });
}

test("shared git helper refuses an absent checkout or unresolved unchanged-base objects", async (t) => {
  const f = cliFixture(t);
  await assert.rejects(
    checkGitBaseAdvance(join(f.dir, "absent"), f.base, f.base, f.head),
  );
  await assert.rejects(
    checkGitBaseAdvance(f.checkout, "a".repeat(40), "a".repeat(40), f.head),
  );
  assert.deepEqual(f.calls(), []);
});
