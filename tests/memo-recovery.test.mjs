#!/usr/bin/env node
// Real memo functions with deterministic filesystem faults, plus the actual no-tabs process.
// Override PRO_GATE_TEST_SALVAGE_SOURCE with extracted baseline code for red-before-green.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import { createServer } from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
import test from "node:test";

const sourceFile =
  process.env.PRO_GATE_TEST_SALVAGE_SOURCE ??
  fileURLToPath(new URL("../bin/cdp-salvage.mjs", import.meta.url));
const source = fs.readFileSync(sourceFile, "utf8");
const marker = "pg-run-memo-recovery-1700000000-1";
const foreign = "https://chatgpt.com/c/foreign";
const genuine = "https://chatgpt.com/c/genuine";
const newer = "https://chatgpt.com/c/newer";
const fail = () =>
  Object.assign(new Error("injected I/O failure"), { code: "EIO" });
const topLevel = (name) => {
  const match = source.match(new RegExp(`^function ${name}\\([^]*?^}`, "m"));
  assert.ok(match, `actual ${name} function is present`);
  return match[0];
};
const start = source.indexOf("const CONVERSATION_URL_RE =");
const end = source.indexOf("// #68 gate r3 P2:", start);
assert.ok(
  start >= 0 && end > start,
  "actual memo source boundaries are present",
);

function fixture(t, { legacy = false, hooks = {} } = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pg-memo-recovery-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const dirs = {
    URL_MEMO_DIR: path.join(home, "conversation-urls"),
    TITLE_MEMO_DIR: path.join(home, "conversation-titles"),
    LEGACY_RECEIPT_DIR: path.join(home, "legacy-review-receipts"),
    INPUT_BINDING_DIR: path.join(home, "review-input-bindings"),
    RESERVATION_DIR: path.join(home, "in-progress"),
  };
  for (const dir of Object.values(dirs)) fs.mkdirSync(dir);
  const memo = path.join(dirs.URL_MEMO_DIR, marker);
  const blacklist = path.join(home, "salvage-nonmatching.txt");
  if (legacy)
    fs.writeFileSync(
      path.join(dirs.INPUT_BINDING_DIR, marker),
      JSON.stringify({
        evidence: { mode: "full-pr", proof: { base_oid: "a".repeat(40) } },
      }),
    );
  const proxy = Object.assign(Object.create(fs), hooks);
  const makeApi = (filesystem) =>
    runInNewContext(
      `${source.slice(start, end)}\n${topLevel("legacyReviewBinding")}\n${topLevel("rememberUrl")}\n${topLevel("blacklist")}\n${topLevel("discardForeignUrl")}\n({
    forget: forgetUrl, recall: recallUrl, remember: rememberUrl,
    discard: discardForeignUrl,
    unresolved: (m) => typeof memoUnresolved === 'function' && memoUnresolved(m)
  })`,
      {
        fs: filesystem,
        path,
        process,
        randomUUID,
        createHash,
        Buffer,
        ...dirs,
        BLACKLIST_FILE: blacklist,
        PG_HOME: home,
        marker,
        knownUrl: foreign,
        memoStale: false,
        ourUrls: new Set([foreign]),
        nonMatching: new Set(),
        blacklistLines: [],
        MARKER_SAFE_RE: /^pg-run-[A-Za-z0-9.-]+$/,
        MEMO_KEEP: 200,
        console: { error() {} },
      },
    );
  const claims = () =>
    [dirs.URL_MEMO_DIR, dirs.LEGACY_RECEIPT_DIR].flatMap((dir) =>
      fs
        .readdirSync(dir)
        .filter((n) => n.startsWith(`${marker}.rej.`))
        .map((n) => path.join(dir, n)),
    );
  return {
    home,
    memo,
    blacklist,
    dirs,
    api: makeApi(proxy),
    fresh: () => makeApi(fs),
    claims,
    proxy,
  };
}

for (const legacy of [false, true]) {
  for (const held of [foreign, genuine]) {
    test(`failed blacklist append plus claim read EIO: ${legacy ? "legacy" : "current"} ${held === foreign ? "conviction" : "replacement"} survives fresh recall`, (t) => {
      const f = fixture(t, { legacy });
      const previous = `pg-run-other-1-1\t${newer}\n`;
      fs.writeFileSync(f.blacklist, previous);
      fs.writeFileSync(f.memo, held);
      f.proxy.appendFileSync = () => {
        throw fail();
      };
      f.proxy.readSync = () => { throw fail(); };
      f.api.discard(foreign);
      assert.equal(f.claims().length, 1);
      assert.equal(fs.readFileSync(f.claims()[0], "utf8"), held);
      assert.equal(f.fresh().recall(marker), held === foreign ? null : genuine);
      assert.equal(f.claims().length, 0);
      assert.equal(fs.existsSync(f.memo), held !== foreign);
      // Recovery publishes the conviction before removing its last record.
      assert.equal(
        fs.readFileSync(f.blacklist, "utf8"),
        held === foreign ? `${previous}${marker}\t${foreign}\n` : previous,
      );
      assert.equal(
        fs.readdirSync(f.dirs.LEGACY_RECEIPT_DIR).length,
        legacy ? 1 : 0,
      );
    });
  }

  test(`concurrent fresh recall cannot resurrect ${legacy ? "legacy" : "current"} conviction when blacklist append fails`, (t) => {
    const f = fixture(t, { legacy });
    fs.writeFileSync(f.memo, foreign);
    f.proxy.appendFileSync = () => {
      throw fail();
    };
    let recalled = "not-called";
    f.proxy.renameSync = (from, to) => {
      fs.renameSync(from, to);
      if (from === f.memo) recalled = f.fresh().recall(marker);
    };
    f.api.discard(foreign);
    assert.equal(recalled, null);
    assert.equal(f.fresh().recall(marker), null);
    assert.equal(fs.existsSync(f.memo), false);
  });

  for (const sameInode of [false, true]) {
    test(`${legacy ? "legacy" : "current"} EEXIST with ${sameInode ? "same inode" : "identical bytes"} resolves duplicate claim`, (t) => {
      const f = fixture(t, { legacy });
      fs.writeFileSync(f.memo, genuine);
      f.proxy.renameSync = (from, to) => {
        fs.renameSync(from, to);
        if (from === f.memo) {
          if (sameInode) fs.linkSync(to, from);
          else fs.writeFileSync(from, genuine);
        }
      };
      assert.equal(f.api.forget(marker, foreign), genuine);
      assert.equal(f.claims().length, 0);
      assert.equal(f.fresh().recall(marker), genuine);
      assert.equal(
        fs.readdirSync(f.dirs.LEGACY_RECEIPT_DIR).length,
        legacy ? 1 : 0,
      );
    });
  }
}

for (const legacy of [false, true]) {
  for (const concurrent of [false, true]) {
    for (const held of [foreign, genuine]) {
      test(`shell failed append/read, ${legacy ? "legacy" : "current"}, ${concurrent ? "concurrent" : "fresh"} recall: ${held}`, (t) => {
        const f = fixture(t);
        fs.writeFileSync(f.memo, held);
        const previous = `pg-run-other-1-1\t${newer}\n`;
        fs.writeFileSync(f.blacklist, previous);
        const recaller = path.join(f.home, "recall.mjs");
        fs.writeFileSync(
          recaller,
          `import fs from 'node:fs';
import path from 'node:path';
import {createHash, randomUUID} from 'node:crypto';
const {URL_MEMO_DIR,TITLE_MEMO_DIR,LEGACY_RECEIPT_DIR,INPUT_BINDING_DIR,RESERVATION_DIR}=${JSON.stringify(f.dirs)};
const PG_HOME=${JSON.stringify(f.home)}, BLACKLIST_FILE=${JSON.stringify(f.blacklist)};
const MARKER_SAFE_RE=/^pg-run-[A-Za-z0-9.-]+$/;
${source.slice(start, end)}
${topLevel("legacyReviewBinding")}
process.stdout.write(JSON.stringify(recallUrl(${JSON.stringify(marker)})));
`,
        );
        const script = path.join(f.home, "reject.sh");
        fs.writeFileSync(
          script,
          `#!/usr/bin/env bash
set -u
. "$1"
export PRO_GATE_HOME="$2"
if [ "$5" = true ]; then
  jq -cnjS --arg marker "$3" --arg cd "$(pg_review_decision_contract_digest)" '
    {record_type:"review-input-binding/v1",record_version:1,contract_id:"review-decision/v1",contract_version:1,
     contract_digest:$cd,marker:$marker,charged_spend_epoch:1700000000,
     repository:{host:"github.com",owner:"acme",repo:"widgets"},
     target:{kind:"pull-request",pr:1,head_oid:("a"*40)},
     evidence:{identity:"legacy-fixture",mode:"full-pr",proof:{base_oid:("b"*40),head_oid:("a"*40),endpoint_digest:("c"*64),raw_patch_digest:("d"*64)}}}' \
    > "$PRO_GATE_HOME/review-input-bindings/$3"
  pg_review_input_binding_read "$3" >/dev/null || exit 91
fi
recaller="$6"; concurrent="$7"; canonical="$PRO_GATE_HOME/conversation-urls/$3"; node_bin="$8"
# Fail only the blacklist append, preserving earlier lines and leaving reads available.
printf() { if [ "$1" = '%s\\t%s\\n' ]; then return 1; fi; builtin printf "$@"; }
cat() { case "$1" in *.rej.*) return 1;; esac; command cat "$@"; }
head() { local arg; for arg in "$@"; do case "$arg" in *.rej.*) return 1;; esac; done; command head "$@"; }
mv() {
  command mv "$@" || return
  if [ "$concurrent" = true ] && [ "$1" = "$canonical" ]; then
    "$node_bin" "$recaller" > "$PRO_GATE_HOME/concurrent-recall" || exit 92
  fi
}
pg_provenance_reject "$3" "$4"
`,
        );
        const lib =
          process.env.PRO_GATE_TEST_LIB_SOURCE ??
          fileURLToPath(new URL("../lib/pro-gate-lib.sh", import.meta.url));
        const child = spawnSync(
          "bash",
          [
            script,
            lib,
            f.home,
            marker,
            foreign,
            String(legacy),
            recaller,
            String(concurrent),
            process.execPath,
          ],
          { encoding: "utf8" },
        );
        assert.equal(child.status, 0, child.stderr);
        if (!concurrent) {
          assert.equal(f.claims().length, 1);
          assert.equal(fs.readFileSync(f.claims()[0], "utf8"), held);
        } else {
          assert.equal(
            JSON.parse(
              fs.readFileSync(path.join(f.home, "concurrent-recall"), "utf8"),
            ),
            held === foreign ? null : genuine,
          );
        }
        assert.equal(
          f.fresh().recall(marker),
          held === foreign ? null : genuine,
        );
        assert.equal(f.claims().length, 0);
        assert.equal(fs.existsSync(f.memo), held !== foreign);
        assert.equal(
          fs.readFileSync(f.blacklist, "utf8"),
          held === foreign ? `${previous}${marker}\t${foreign}\n` : previous,
        );
        assert.equal(
          fs.readdirSync(f.dirs.LEGACY_RECEIPT_DIR).length,
          legacy ? 1 : 0,
        );
      });
    }
  }
}

const urlDigest = (url) => createHash("sha256").update(url).digest("hex");
// Claims written before bounded names carried the full digest and a UUID.
const oldClaim = (f, url) =>
  path.join(f.dirs.URL_MEMO_DIR, `${marker}.rej.${urlDigest(url)}.${randomUUID()}`);

test("a sibling's conviction blocks restoration and stays until the blacklist records it", (t) => {
  const f = fixture(t);
  // One interrupted revocation convicted another URL but claimed the replacement memo; a
  // later one convicted that replacement. Neither conviction reached the blacklist.
  const replacedClaim = oldClaim(f, foreign);
  const convictingClaim = oldClaim(f, newer);
  fs.writeFileSync(replacedClaim, newer);
  fs.writeFileSync(convictingClaim, newer);
  f.proxy.appendFileSync = () => {
    throw fail();
  };
  assert.equal(f.api.recall(marker), null);
  assert.equal(fs.existsSync(f.memo), false);
  assert.deepEqual(f.claims().sort(), [replacedClaim, convictingClaim].sort());
  assert.equal(f.api.unresolved(marker), true);
  assert.equal(f.fresh().recall(marker), null);
  assert.equal(fs.existsSync(f.memo), false);
  assert.equal(f.claims().length, 0);
  assert.equal(fs.readFileSync(f.blacklist, "utf8"), `${marker}\t${newer}\n`);
});

test("an unread sibling keeps a restored claim's unpublished conviction", (t) => {
  const f = fixture(t);
  // The restored claim names the URL its process convicted; the unread sibling may hold it.
  const restoredClaim = oldClaim(f, foreign);
  const unreadClaim = oldClaim(f, newer);
  fs.writeFileSync(restoredClaim, genuine);
  fs.writeFileSync(unreadClaim, foreign);
  f.proxy.openSync = (file, ...rest) => {
    if (file === unreadClaim) throw fail();
    return fs.openSync(file, ...rest);
  };
  assert.equal(f.api.recall(marker), genuine);
  assert.deepEqual(f.claims().sort(), [restoredClaim, unreadClaim].sort());
  assert.equal(f.api.unresolved(marker), true);
  assert.equal(f.fresh().recall(marker), genuine);
  assert.equal(f.claims().length, 0);
  assert.equal(fs.readFileSync(f.blacklist, "utf8"), `${marker}\t${foreign}\n`);
});

test("the longest runtime marker is claimed within the filename limit", (t) => {
  const f = fixture(t);
  // 39-byte GitHub owner, 100-byte repository, 7-digit PR, epoch and 7-digit pid.
  const long = `pg-run-${"o".repeat(39)}-${"r".repeat(100)}-9999999-1700000000-4194304`;
  assert.equal(long.length, 174);
  const memo = path.join(f.dirs.URL_MEMO_DIR, long);
  const longClaims = () =>
    fs.readdirSync(f.dirs.URL_MEMO_DIR).filter((n) => n.startsWith(`${long}.rej.`));
  fs.writeFileSync(memo, foreign);
  f.proxy.readSync = () => {
    throw fail();
  };
  assert.equal(f.api.forget(long, foreign), null);
  assert.equal(fs.existsSync(memo), false);
  assert.equal(longClaims().length, 1);
  assert.ok(Buffer.byteLength(longClaims()[0]) <= 255);
  assert.equal(f.fresh().recall(long), null);
  assert.equal(longClaims().length, 0);
  assert.equal(fs.readFileSync(f.blacklist, "utf8"), `${long}\t${foreign}\n`);
});

const boundedClaim = (f, url) =>
  path.join(f.dirs.URL_MEMO_DIR, `${marker}.rej.${urlDigest(url).slice(0, 16)}.${"0".repeat(16)}`);

for (const rejection of ["identical bytes", "hard link", "blacklist only", "unpublished claim"]) {
  test(`recall revokes a remembered URL its marker rejected: ${rejection}`, (t) => {
    const f = fixture(t);
    // A concurrent writer republished the URL an interrupted revocation had convicted.
    fs.writeFileSync(f.memo, foreign);
    if (rejection === "hard link") fs.linkSync(f.memo, boundedClaim(f, foreign));
    else if (rejection === "blacklist only") fs.writeFileSync(f.blacklist, `${marker}\t${foreign}\n`);
    else fs.writeFileSync(boundedClaim(f, foreign), foreign);
    if (rejection === "unpublished claim")
      f.proxy.appendFileSync = () => {
        throw fail();
      };
    assert.equal(f.api.recall(marker), null);
    assert.equal(fs.existsSync(f.memo), false);
    if (rejection === "unpublished claim") {
      assert.equal(f.claims().length, 2);
      assert.equal(f.api.unresolved(marker), true);
    }
    assert.equal(f.fresh().recall(marker), null);
    assert.equal(f.claims().length, 0);
    assert.equal(fs.readFileSync(f.blacklist, "utf8"), `${marker}\t${foreign}\n`);
  });
}

for (const fault of ["blacklist read", "claim listing"]) {
  for (const held of [foreign, genuine]) {
    test(`an unreadable ${fault} leaves a ${held === foreign ? "rejected" : "genuine"} memo untrusted and untouched`, (t) => {
      const f = fixture(t);
      fs.writeFileSync(f.memo, held);
      // The rejection record exists but cannot be read.
      if (fault === "blacklist read") {
        fs.writeFileSync(f.blacklist, `${marker}\t${foreign}\n`);
        f.proxy.readFileSync = (file, ...args) => {
          if (file === f.blacklist) throw fail();
          return fs.readFileSync(file, ...args);
        };
      } else {
        fs.writeFileSync(boundedClaim(f, foreign), foreign);
        f.proxy.readdirSync = (dir, ...args) => {
          if (dir === f.dirs.URL_MEMO_DIR) throw fail();
          return fs.readdirSync(dir, ...args);
        };
      }
      assert.equal(f.api.recall(marker), null);
      assert.equal(fs.readFileSync(f.memo, "utf8"), held);
      assert.equal(f.api.unresolved(marker), true);
      assert.equal(f.fresh().recall(marker), held === foreign ? null : genuine);
      assert.equal(fs.existsSync(f.memo), held !== foreign);
      assert.equal(f.claims().length, 0);
      assert.equal(fs.readFileSync(f.blacklist, "utf8"), `${marker}\t${foreign}\n`);
    });
  }
}

test("an incomplete claim listing restores nothing an unlisted claim may convict", (t) => {
  const f = fixture(t);
  // The listed claim holds a URL that only the unlisted claim's name convicts.
  const listed = path.join(
    f.dirs.LEGACY_RECEIPT_DIR,
    path.basename(oldClaim(f, newer)),
  );
  fs.writeFileSync(listed, foreign);
  fs.writeFileSync(boundedClaim(f, foreign), newer);
  f.proxy.readdirSync = (dir, ...args) => {
    if (dir === f.dirs.URL_MEMO_DIR) throw fail();
    return fs.readdirSync(dir, ...args);
  };
  assert.equal(f.api.recall(marker), null);
  assert.equal(fs.existsSync(f.memo), false);
  assert.equal(f.claims().length, 2);
  assert.equal(f.fresh().recall(marker), null);
  assert.equal(fs.existsSync(f.memo), false);
  assert.equal(f.claims().length, 0);
  assert.ok(fs.readFileSync(f.blacklist, "utf8").includes(`${marker}\t${foreign}\n`));
});

test("revoking a rejected memo preserves a different concurrent replacement", (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.memo, foreign);
  fs.writeFileSync(f.blacklist, `${marker}\t${foreign}\n`);
  f.proxy.renameSync = (from, to) => {
    fs.renameSync(from, to);
    if (from === f.memo) fs.writeFileSync(f.memo, genuine);
  };
  assert.equal(f.api.recall(marker), genuine);
  assert.equal(fs.readFileSync(f.memo, "utf8"), genuine);
  assert.equal(f.claims().length, 0);
});

test("a restoration keeps an unpublished conviction that a sibling claim still holds", (t) => {
  const f = fixture(t);
  // An earlier revocation of another URL claimed the now-rejected URL as its replacement.
  const sibling = oldClaim(f, newer);
  fs.writeFileSync(sibling, foreign);
  fs.writeFileSync(f.memo, genuine);
  f.proxy.appendFileSync = () => {
    throw fail();
  };
  assert.equal(f.api.forget(marker, foreign), genuine);
  assert.equal(fs.readFileSync(f.memo, "utf8"), genuine);
  assert.ok(
    f.claims().some((claim) => memoClaimNames(claim, foreign)),
    "the claim naming the unpublished conviction survives restoration",
  );
  assert.equal(f.api.unresolved(marker), true);
  delete f.proxy.appendFileSync;
  assert.equal(f.api.forget(marker, genuine), null);
  assert.equal(f.fresh().recall(marker), null);
  assert.equal(fs.existsSync(f.memo), false);
  assert.equal(f.claims().length, 0);
  assert.deepEqual(
    fs.readFileSync(f.blacklist, "utf8").split("\n").filter(Boolean).sort(),
    [`${marker}\t${foreign}`, `${marker}\t${genuine}`].sort(),
  );
});

function memoClaimNames(claim, url) {
  const name = path.basename(claim);
  return name.startsWith(`${marker}.rej.${urlDigest(url).slice(0, 16)}.`);
}

test("replacement before claim restores the actual newer inode", (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.memo, foreign);
  const replacement = path.join(f.home, "replacement-memo");
  fs.writeFileSync(replacement, genuine);
  fs.utimesSync(
    replacement,
    new Date(1_700_000_000_000),
    new Date(1_700_000_000_000),
  );
  const replacementStat = fs.statSync(replacement);
  f.proxy.renameSync = (from, to) => {
    if (from === f.memo) fs.renameSync(replacement, f.memo);
    return fs.renameSync(from, to);
  };
  assert.equal(f.api.forget(marker, foreign), genuine);
  assert.equal(fs.readFileSync(f.memo, "utf8"), genuine);
  assert.equal(fs.statSync(f.memo).ino, replacementStat.ino);
  assert.equal(fs.statSync(f.memo).mtimeMs, replacementStat.mtimeMs);
  assert.equal(f.claims().length, 0);
});

test("publication after claim is returned; EEXIST preserves the alternate bytes", (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.memo, genuine);
  f.proxy.renameSync = (from, to) => {
    fs.renameSync(from, to);
    if (from === f.memo) fs.writeFileSync(f.memo, newer);
  };
  assert.equal(f.api.forget(marker, foreign), newer);
  assert.equal(fs.readFileSync(f.memo, "utf8"), newer);
  assert.equal(f.claims().length, 1);
  assert.equal(fs.readFileSync(f.claims()[0], "utf8"), genuine);
  assert.equal(f.api.recall(marker), newer);
  assert.equal(
    f.claims().length,
    1,
    "ordinary recall must not discard the alternate on EEXIST",
  );
});

for (const legacy of [false, true]) {
  for (const fault of ["read", "link"]) {
    test(`${legacy ? "legacy" : "current"} ${fault} EIO retains bytes and ordinary recall recovers`, (t) => {
      const f = fixture(t, { legacy });
      fs.writeFileSync(f.memo, genuine);
      const originalTime = new Date("2026-01-10T00:00:00Z");
      fs.utimesSync(f.memo, originalTime, originalTime);
      if (fault === "read")
        f.proxy.readSync = () => { throw fail(); };
      else
        f.proxy.linkSync = () => {
          throw fail();
        };
      f.api.forget(marker, foreign);
      assert.equal(f.claims().length, 1);
      assert.equal(fs.readFileSync(f.claims()[0], "utf8"), genuine);
      assert.equal(fs.statSync(f.claims()[0]).mtimeMs, originalTime.getTime());
      assert.equal(f.api.unresolved(marker), true);
      delete f.proxy.readSync;
      delete f.proxy.linkSync;
      assert.equal(f.api.recall(marker), genuine);
      assert.equal(f.claims().length, 0);
      assert.equal(fs.readFileSync(f.memo, "utf8"), genuine);
      const receipts = fs.readdirSync(f.dirs.LEGACY_RECEIPT_DIR);
      assert.equal(receipts.length, legacy ? 1 : 0);
      if (legacy)
        assert.equal(
          fs.statSync(path.join(f.dirs.LEGACY_RECEIPT_DIR, receipts[0]))
            .mtimeMs,
          originalTime.getTime(),
        );
    });
  }
}

test("repeated revocation cannot overwrite a surviving claim from the same process", (t) => {
  const f = fixture(t);
  f.proxy.linkSync = () => {
    throw fail();
  };
  fs.writeFileSync(f.memo, genuine);
  f.api.forget(marker, foreign);
  fs.writeFileSync(f.memo, newer);
  f.api.forget(marker, foreign);
  assert.equal(f.claims().length, 2);
  assert.deepEqual(
    f
      .claims()
      .map((p) => fs.readFileSync(p, "utf8"))
      .sort(),
    [genuine, newer].sort(),
  );
});

test("convicted claim is never restored and legacy conviction retains a resolved receipt", (t) => {
  for (const legacy of [false, true]) {
    const f = fixture(t, { legacy });
    fs.writeFileSync(f.memo, foreign);
    f.proxy.readSync = () => { throw fail(); };
    f.api.forget(marker, foreign);
    fs.writeFileSync(
      f.blacklist,
      `${marker}\t${foreign}\npg-run-other-1-1\t${genuine}\n`,
    );
    delete f.proxy.readSync;
    assert.equal(f.api.recall(marker), null);
    assert.equal(fs.existsSync(f.memo), false);
    assert.equal(f.claims().length, 0);
    assert.equal(
      fs.readdirSync(f.dirs.LEGACY_RECEIPT_DIR).length,
      legacy ? 1 : 0,
    );
    assert.equal(
      fs.readFileSync(f.blacklist, "utf8"),
      `${marker}\t${foreign}\npg-run-other-1-1\t${genuine}\n`,
    );
  }
});

test("ordinary recall during revocation cannot restore the just-convicted URL", (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.memo, foreign);
  const otherLine = `pg-run-other-1-1\t${genuine}\n`;
  fs.writeFileSync(f.blacklist, otherLine);
  let recovery = "not-called";
  f.proxy.renameSync = (from, to) => {
    fs.renameSync(from, to);
    if (from === f.memo) recovery = f.api.recall(marker);
  };
  f.api.discard(foreign);
  assert.equal(recovery, null);
  assert.equal(fs.existsSync(f.memo), false);
  assert.equal(
    fs.readFileSync(f.blacklist, "utf8"),
    `${otherLine}${marker}\t${foreign}\n`,
  );
});

test("blacklist read uncertainty never republishes a possibly convicted claim", (t) => {
  const f = fixture(t);
  const claim = `${f.memo}.rej.seeded`;
  fs.writeFileSync(claim, genuine);
  f.proxy.readFileSync = (file, ...args) => {
    if (file === f.blacklist) throw fail();
    return fs.readFileSync(file, ...args);
  };
  assert.equal(f.api.recall(marker), null);
  assert.equal(fs.readFileSync(claim, "utf8"), genuine);
  assert.equal(f.api.unresolved(marker), true);
});

test("a claim growing after metadata inspection stays bounded and unresolved", (t) => {
  const f = fixture(t);
  const claim = `${f.memo}.rej.growing`;
  fs.writeFileSync(claim, genuine);
  let grew = false;
  f.proxy.fstatSync = (fd) => {
    const before = fs.fstatSync(fd);
    if (!grew) { grew = true; fs.appendFileSync(claim, "x".repeat(8192)); }
    return before;
  };
  assert.equal(f.api.recall(marker), null);
  assert.equal(f.api.unresolved(marker), true);
  assert.equal(fs.existsSync(f.memo), false);
  assert.equal(fs.statSync(claim).size, Buffer.byteLength(genuine) + 8192);
});

test("a claim swapped for a symlink while opening is never followed", (t) => {
  const f = fixture(t);
  const claim = `${f.memo}.rej.swapped`;
  const target = path.join(f.home, "unrelated");
  fs.writeFileSync(claim, genuine);
  fs.writeFileSync(target, newer);
  f.proxy.openSync = (file, ...args) => {
    if (file === claim) { fs.unlinkSync(claim); fs.symlinkSync(target, claim); }
    return fs.openSync(file, ...args);
  };
  assert.equal(f.api.recall(marker), null);
  assert.equal(f.api.unresolved(marker), true);
  assert.equal(fs.existsSync(f.memo), false);
  assert.equal(fs.readFileSync(target, "utf8"), newer);
});

test("ordinary memo read EIO remains unresolved", (t) => {
  const f = fixture(t);
  fs.writeFileSync(f.memo, genuine);
  f.proxy.readSync = () => { throw fail(); };
  assert.equal(f.api.recall(marker), null);
  assert.equal(f.api.unresolved(marker), true);
  assert.equal(fs.readFileSync(f.memo, "utf8"), genuine);
});

test("count pruning protects owned claims and canonical markers containing .rej.; unowned claims retain the cap", (t) => {
  const f = fixture(t);
  const claim = `${f.memo}.rej.old`;
  fs.writeFileSync(claim, genuine);
  fs.utimesSync(claim, new Date(0), new Date(0));
  fs.writeFileSync(path.join(f.dirs.RESERVATION_DIR, marker), "reserved");
  const named = "pg-run-repo-12-34.rej.part-1700000000-9";
  const canonical = path.join(f.dirs.URL_MEMO_DIR, named);
  fs.writeFileSync(canonical, genuine);
  fs.writeFileSync(`${canonical}.rej.old`, genuine);
  fs.writeFileSync(path.join(f.dirs.RESERVATION_DIR, named), "reserved");
  const unowned = path.join(
    f.dirs.URL_MEMO_DIR,
    "pg-run-unowned-1700000000-2.rej.old",
  );
  fs.writeFileSync(unowned, genuine);
  for (const file of [canonical, `${canonical}.rej.old`, unowned])
    fs.utimesSync(file, new Date(0), new Date(0));
  for (let i = 0; i < 205; i++)
    fs.writeFileSync(
      path.join(f.dirs.URL_MEMO_DIR, `pg-run-count-${i}-1`),
      foreign,
    );
  f.api.remember("pg-run-new-count-1700000000-2", newer);
  assert.equal(fs.readFileSync(claim, "utf8"), genuine);
  assert.equal(fs.readFileSync(canonical, "utf8"), genuine);
  assert.equal(fs.readFileSync(`${canonical}.rej.old`, "utf8"), genuine);
  assert.equal(fs.existsSync(unowned), false);
});

test("ordinary recall does not claim another canonical marker containing .rej.", (t) => {
  const f = fixture(t);
  const owner = "pg-run-repo-12-34";
  const other = `${owner}.rej.part-1700000000-9`;
  const otherMemo = path.join(f.dirs.URL_MEMO_DIR, other);
  fs.writeFileSync(otherMemo, genuine);
  assert.equal(f.fresh().recall(owner), null);
  assert.equal(fs.readFileSync(otherMemo, "utf8"), genuine);
  assert.equal(fs.existsSync(path.join(f.dirs.URL_MEMO_DIR, owner)), false);
});

async function noTabsChild(t, { kind, mode = "--probe" }) {
  const f = fixture(t);
  const faultPath = kind === "memo" ? f.memo : `${f.memo}.rej.seeded`;
  const injectedRead = kind === "memo" || kind === "claim";
  if (kind === "fifo") {
    const made = spawnSync("mkfifo", [faultPath], { encoding: "utf8" });
    assert.equal(made.status, 0, made.stderr);
  } else if (kind === "symlink") {
    const target = path.join(f.home, "alternate-bytes");
    fs.writeFileSync(target, genuine);
    fs.symlinkSync(target, faultPath);
  } else if (kind === "oversized") {
    fs.writeFileSync(faultPath, `${genuine}?${"x".repeat(4096)}`);
  } else if (kind === "directory") {
    fs.mkdirSync(faultPath);
  } else fs.writeFileSync(faultPath, genuine);
  const before = fs.lstatSync(faultPath);
  const result = await salvageChild(t, f, {
    mode,
    faultPath: injectedRead ? faultPath : "",
  });
  return {
    ...result,
    retained: injectedRead ? fs.readFileSync(faultPath, "utf8") : null,
    unchanged: fs.lstatSync(faultPath).ino === before.ino && fs.lstatSync(faultPath).size === before.size,
  };
}

// Runs the actual salvage entry point against a CDP endpoint listing `tabs`.
async function salvageChild(t, f, { mode = "--probe", tabs = [], faultPath = "" } = {}) {
  const preload = path.join(f.home, "fault.mjs");
  fs.writeFileSync(
    preload,
    `import fs from 'node:fs';
const originalOpen = fs.openSync, originalRead = fs.readSync, originalClose = fs.closeSync;
const faultFds = new Set();
fs.openSync = function(file, ...args) {
  const fd = originalOpen.call(this, file, ...args);
  if (String(file) === process.env.PRO_GATE_TEST_MEMO_FAULT_PATH) faultFds.add(fd);
  return fd;
};
fs.readSync = function(fd, ...args) {
  if (faultFds.has(fd)) throw Object.assign(new Error('injected EIO'), {code: 'EIO'});
  return originalRead.call(this, fd, ...args);
};
fs.closeSync = function(fd) { faultFds.delete(fd); return originalClose.call(this, fd); };\n`,
  );
  const server = createServer((_req, response) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(tabs));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return await new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [
        "--import",
        preload,
        sourceFile,
        mode,
        marker,
        "1",
        String(server.address().port),
      ],
      {
        timeout: 5_000,
        env: {
          ...process.env,
          PRO_GATE_HOME: f.home,
          PRO_GATE_TEST_MEMO_FAULT_PATH: faultPath,
        },
      },
    );
    let stdout = "",
      stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

test("actual scan with the rejected conversation's tab open reports absence instead of holding the run", async (t) => {
  const f = fixture(t);
  // Recovery records this claim's conviction, but the same URL was republished as the memo.
  fs.writeFileSync(f.memo, foreign);
  fs.linkSync(f.memo, boundedClaim(f, foreign));
  const result = await salvageChild(t, f, {
    tabs: [{ type: "page", id: "rejected-tab", url: foreign }],
  });
  assert.equal(result.code, 4, result.stderr);
  assert.match(result.stderr, /evidence-kind: absent/);
  assert.equal(fs.existsSync(f.memo), false);
  assert.equal(f.claims().length, 0);
  assert.equal(fs.readFileSync(f.blacklist, "utf8"), `${marker}\t${foreign}\n`);
});

for (const kind of ["fifo", "symlink", "oversized", "directory"]) {
  test(`actual empty CDP scan treats ${kind} claim as bounded uncertainty`, async (t) => {
    const result = await noTabsChild(t, { kind });
    assert.equal(result.code, 7, result.stderr);
    assert.match(result.stderr, /evidence-kind: inconclusive/);
    assert.equal(result.unchanged, true);
  });
}

for (const kind of ["memo", "claim"]) {
  test(`actual empty CDP scan with ${kind} EIO cannot report absence`, async (t) => {
    const result = await noTabsChild(t, { kind });
    assert.equal(result.code, 7, result.stderr);
    assert.match(result.stderr, /evidence-kind: inconclusive/);
    assert.equal(result.retained, genuine);
  });
}

test("actual organizer reports unresolved memo instead of target absence", async (t) => {
  const result = await noTabsChild(t, { kind: "claim", mode: "--organize" });
  assert.match(result.stdout, /reason=memo-unresolved/, result.stderr);
  assert.equal(result.retained, genuine);
});
