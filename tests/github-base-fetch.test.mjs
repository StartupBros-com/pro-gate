import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import * as adapter from "../bin/record-pro-gate-verdict.mjs";

const script = fileURLToPath(
  new URL("../bin/record-pro-gate-verdict.mjs", import.meta.url),
);

// Git and the remote are real; GitHub status/PR responses are synthetic fixtures.
for (const scenario of [
  { name: "narrow overlap", overlap: true },
  { name: "narrow disjoint" },
  { name: "narrow unchanged", unchanged: true },
  { name: "wildcard overlap", wildcard: true, overlap: true },
  {
    name: "excluded base overlap",
    wildcard: true,
    excluded: true,
    overlap: true,
  },
  { name: "failed fetch with stale ref", failed: true },
  { name: "slash branch overlap", branch: "release/main", overlap: true },
]) {
  test(`real Git CLI fixture: ${scenario.name}`, (t) => {
    const directory = mkdtempSync(join(tmpdir(), "pg-base-fetch-"));
    t.after(() => rmSync(directory, { recursive: true, force: true }));
    const remote = join(directory, "remote.git");
    const tree = join(directory, "tree");
    const bin = join(directory, "bin");
    mkdirSync(tree);
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
    const git = (...args) =>
      execFileSync("git", args, { cwd: tree, env, encoding: "utf8" }).trim();
    const branch = scenario.branch || "main";
    git("init", "--bare", "-q", remote);
    git("init", "-q", "-b", branch);
    writeFileSync(join(tree, "shared.txt"), "original\n");
    git("add", "shared.txt");
    git("commit", "-qm", "base fixture");
    const base = git("rev-parse", "HEAD");
    git("remote", "add", "origin", remote);
    git("push", "-q", "origin", branch);
    git("checkout", "-qb", "candidate");
    writeFileSync(join(tree, "shared.txt"), "candidate\n");
    git("commit", "-qam", "candidate fixture");
    const head = git("rev-parse", "HEAD");
    git("push", "-q", "origin", "candidate");
    git("checkout", "-q", branch);
    if (!scenario.unchanged) {
      const file = scenario.overlap ? "shared.txt" : "other.txt";
      writeFileSync(join(tree, file), "base advance\n");
      git("add", file);
      git("commit", "-qm", "advance fixture");
      git("push", "-q", "origin", branch);
    }
    const liveBase = git("rev-parse", "HEAD");
    git("checkout", "-q", "candidate");
    git(
      "config",
      "remote.origin.fetch",
      scenario.wildcard
        ? "+refs/heads/*:refs/remotes/origin/*"
        : "+refs/heads/candidate:refs/remotes/origin/candidate",
    );
    if (scenario.excluded) {
      git("config", "--add", "remote.origin.fetch", `^refs/heads/${branch}`);
    }
    git("update-ref", `refs/remotes/origin/${branch}`, base);
    assert.equal(git("rev-parse", `refs/remotes/origin/${branch}`), base);
    if (!scenario.unchanged) assert.notEqual(liveBase, base);
    if (scenario.failed) {
      git("remote", "set-url", "origin", join(directory, "missing.git"));
    }
    const description = adapter.buildDescription({
      verdict: "SHIP",
      baseRepo: "acme/widgets",
      baseRef: branch,
      baseSha: base,
      evidence: "https://github.com/acme/widgets/pull/1#fixture",
      now: new Date("2026-10-14T00:00:00Z"),
    });
    const responses = {
      "repo view": "acme/widgets",
      "api repos/acme/widgets/pulls/1": JSON.stringify({
        head: { sha: head },
        base: { ref: branch, repo: { full_name: "acme/widgets" } },
      }),
      "api repos/acme/widgets": branch,
      [`api repos/acme/widgets/commits/${head}/status`]: JSON.stringify({
        statuses: [
          { context: adapter.STATUS_CONTEXT, state: "success", description },
        ],
      }),
    };
    writeFileSync(
      join(bin, "gh"),
      `#!${process.execPath}
const responses = ${JSON.stringify(responses)};
const response = responses[process.argv.slice(2,4).join(' ')];
if (response === undefined) process.exit(9);
console.log(response);
`,
      { mode: 0o755 },
    );
    const result = spawnSync(
      process.execPath,
      [script, "--verify-for-merge", "--pr", "1"],
      {
        cwd: tree,
        env: { ...env, PATH: `${bin}:${env.PATH}` },
        encoding: "utf8",
      },
    );
    assert.equal(
      result.status,
      scenario.overlap || scenario.failed ? 1 : 0,
      result.stdout + result.stderr,
    );
    if (scenario.overlap) {
      assert.match(result.stderr, /base moved with overlapping changes/);
      assert.match(result.stderr, /shared\.txt/);
    } else if (scenario.failed) {
      assert.match(result.stderr, /fetch/);
      assert.equal(git("rev-parse", `refs/remotes/origin/${branch}`), base);
    } else if (scenario.unchanged) {
      assert.match(result.stdout, /is unchanged/);
    } else {
      assert.match(result.stdout, /advanced 1 commit/);
    }
    if (!scenario.failed) {
      assert.equal(git("rev-parse", `refs/remotes/origin/${branch}`), liveBase);
    }
  });
}

test("shared base access rejects invalid branches", () => {
  assert.equal(typeof adapter.createGitBaseAccess, "function");
  const access = adapter.createGitBaseAccess();
  for (const branch of [
    "*",
    "main:refs/remotes/origin/other",
    "../main",
    "main..other",
    "main^{commit}",
    "",
    "main\nother",
  ]) {
    assert.throws(() => access.fetchBase(branch));
    assert.throws(() => access.getBaseTipSha(branch));
  }
});
