#!/usr/bin/env bash
# Exercise the commands trusted CI actually invokes, including planted negatives.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "$TDIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
helper="$ROOT/scripts/validate-source.sh"
workflow="$ROOT/.github/workflows/ci.yml"
[ "$(yq '.jobs.tests.steps[] | select(.name == "Validate data and shell files") | .run' "$workflow")" = 'bash scripts/validate-source.sh' ] || fail 'CI must invoke the tested validator'
[ "$(yq '.jobs.tests.steps[] | select(.name == "Run tests") | .run' "$workflow")" = '${{ matrix.tests }}' ] || fail 'each CI leg must run its own test list'
test_command="$(yq '.jobs.tests.strategy.matrix.include[].tests' "$workflow" | sed -n '/^bash tests\/review-decision-adapters.test.sh$/p')"
[ "$test_command" = 'bash tests/review-decision-adapters.test.sh' ] || fail 'trusted CI must invoke adapter conformance'

# #254: the suites run as parallel legs. Splitting them must never drop or double a suite, so every
# tests/*.test.sh and tests/*.test.mjs file must be invoked by exactly one leg, and nothing else.
# A file that declares PG_TEST_SHARDS=N is instead invoked once per shard, PG_TEST_SHARD=1..N.
leg_coverage() { # workflow file; prints the problem and returns 1 on any gap
  local wf="$1" invoked expected
  invoked="$(yq '.jobs.tests.strategy.matrix.include[].tests' "$wf" | grep -v '^---$' | sed '/^$/d' | LC_ALL=C sort)"
  expected="$(cd "$ROOT" && {
    for f in tests/*.test.sh; do
      shards="$(sed -n 's/^PG_TEST_SHARDS=\([1-9][0-9]*\)$/\1/p' "$f")"
      if [ -z "$shards" ]; then printf 'bash %s\n' "$f"; continue; fi
      for k in $(seq 1 "$shards"); do printf 'PG_TEST_SHARD=%s bash %s\n' "$k" "$f"; done
    done
    for f in tests/*.test.mjs; do printf 'node --test %s\n' "$f"; done
  } | LC_ALL=C sort)"
  [ "$invoked" = "$expected" ] && return 0
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$invoked") >&2 || true
  return 1
}
leg_coverage "$workflow" || fail 'every test file must run in exactly one CI leg'
yq '(.jobs.tests.strategy.matrix.include[] | select(.leg == "rest") | .tests) |= sub("bash tests/round-continue.test.sh\n"; "")' \
  "$workflow" > "$TDIR/ci-dropped.yml"
if leg_coverage "$TDIR/ci-dropped.yml" 2>/dev/null; then fail 'planted dropped suite passed the leg coverage check'; fi
yq '(.jobs.tests.strategy.matrix.include[] | select(.leg == "cdp-salvage") | .tests) += "bash tests/engine.test.sh\n"' \
  "$workflow" > "$TDIR/ci-doubled.yml"
if leg_coverage "$TDIR/ci-doubled.yml" 2>/dev/null; then fail 'planted doubled suite passed the leg coverage check'; fi
yq 'del(.jobs.tests.strategy.matrix.include[] | select(.leg == "engine-2"))' "$workflow" > "$TDIR/ci-shard-dropped.yml"
if leg_coverage "$TDIR/ci-shard-dropped.yml" 2>/dev/null; then fail 'planted dropped engine shard passed the leg coverage check'; fi
yq '(.jobs.tests.strategy.matrix.include[] | select(.leg == "engine-3") | .tests) = "PG_TEST_SHARD=1 bash tests/engine.test.sh\n"' \
  "$workflow" > "$TDIR/ci-shard-doubled.yml"
if leg_coverage "$TDIR/ci-shard-doubled.yml" 2>/dev/null; then fail 'planted doubled engine shard passed the leg coverage check'; fi
echo 'ok - every test file runs in exactly one CI leg; a dropped or doubled suite or engine shard is rejected'

# The engine suite's shard regions must be numbered 1..PG_TEST_SHARDS in file order, and in_shard k
# must select region k and no other, so one leg per shard runs every region once; an in_shard that
# selected every region would keep coverage and silently undo the split. A shard outside
# 1..PG_TEST_SHARDS, including a pattern such as `.`, must refuse instead of running nothing.
engine_suite="$ROOT/tests/engine.test.sh"
engine_shards="$(sed -n 's/^PG_TEST_SHARDS=\([1-9][0-9]*\)$/\1/p' "$engine_suite")"
[ "$(sed -n 's/^if in_shard \([0-9][0-9]*\); then$/\1/p' "$engine_suite" | tr '\n' ' ')" = "$(seq -s ' ' 1 "$engine_shards") " ] \
  || fail 'engine shard regions must be numbered 1..PG_TEST_SHARDS in file order'
eval "$(sed -n '/^in_shard() {/p' "$engine_suite")"
[ "$(type -t in_shard)" = function ] || fail 'the engine suite must define in_shard() on one line'
for k in $(seq 1 "$engine_shards"); do
  for region in $(seq 1 "$engine_shards"); do
    selected=0; PG_TEST_SHARD="$k" in_shard "$region" && selected=1
    [ "$selected" = "$([ "$k" = "$region" ] && echo 1 || echo 0)" ] || fail "PG_TEST_SHARD=$k: in_shard $region returned selected=$selected"
  done
  PG_TEST_SHARD='' in_shard "$k" || fail "an unsharded engine run skips region $k"
done
for shard in $((engine_shards + 1)) .; do
  if PG_TEST_SHARD="$shard" bash "$engine_suite" > "$TDIR/shard-range.log" 2>&1; then
    fail "engine shard '$shard' ran instead of refusing"
  fi
  grep -Fq 'PG_TEST_SHARD must be' "$TDIR/shard-range.log" || fail "engine shard '$shard' refused for another reason"
done
echo 'ok - engine shard regions are numbered 1..PG_TEST_SHARDS, each shard selects only its own, and an invalid shard refuses'

# Source validation and the release-notes gate run once, in the rest leg. A renamed leg or a
# mistyped condition would skip them on every leg while trusted check stays green.
rest_steps() { # workflow file; returns 1 unless one rest leg exists and both steps run only there
  local wf="$1" step
  [ "$(yq '[.jobs.tests.strategy.matrix.include[] | select(.leg == "rest")] | length' "$wf")" = 1 ] || return 1
  for step in 'Validate data and shell files' 'Require customer-ready notes for a version bump'; do
    [ "$(step="$step" yq '.jobs.tests.steps[] | select(.name == strenv(step)) | .if' "$wf")" = "matrix.leg == 'rest'" ] || return 1
  done
}
rest_steps "$workflow" || fail 'source validation and the release-notes gate must run in the rest leg'
yq '(.jobs.tests.strategy.matrix.include[] | select(.leg == "rest") | .leg) = "misc"' "$workflow" > "$TDIR/ci-renamed.yml"
if rest_steps "$TDIR/ci-renamed.yml"; then fail 'planted renamed rest leg passed the rest-step check'; fi
bad="matrix.leg == 'misc'" yq '(.jobs.tests.steps[] | select(.name == "Require customer-ready notes for a version bump") | .if) = strenv(bad)' \
  "$workflow" > "$TDIR/ci-misrouted.yml"
if rest_steps "$TDIR/ci-misrouted.yml"; then fail 'planted misrouted release-notes step passed the rest-step check'; fi
echo 'ok - source validation and the release-notes gate run in the rest leg; a renamed leg or misrouted step is rejected'

# The legs run on every push and every same-repository PR; only fork PRs skip them. The release gate
# trusts the push run, so a guard that skipped pushes would let an untested commit ship.
[ "$(yq '.jobs.tests.if' "$workflow")" = "github.event_name == 'push' || (github.event.pull_request.head.repo.full_name == github.repository && github.event.pull_request.head.repo.fork == false)" ] \
  || fail 'the legs must run on every push and every same-repository PR'

# The required context stays "trusted check" and passes only when every leg passed. Its guard is
# the legs' fork guard behind always(), so a failed or cancelled leg still reports a failure.
[ "$(yq '.jobs.check.name' "$workflow")" = 'trusted check' ] || fail 'the aggregator must report the required context'
[ "$(yq '.jobs.check.needs' "$workflow")" = 'tests' ] || fail 'the aggregator must wait for every leg'
[ "$(yq '.jobs.check.if' "$workflow")" = "always() && ($(yq '.jobs.tests.if' "$workflow"))" ] \
  || fail 'the aggregator must run after failed legs and skip exactly where the legs skip'
[ "$(yq '.jobs.check.steps[0].env.LEGS_RESULT' "$workflow")" = '${{ needs.tests.result }}' ] \
  && yq '.jobs.check.steps[0].run' "$workflow" | grep -qx 'test "$LEGS_RESULT" = success' \
  || fail 'the aggregator must fail unless the legs succeeded'
echo 'ok - trusted check aggregates every leg and fails unless all of them passed'
mkdir -p "$TDIR/data/nested space" "$TDIR/data/.git"
bash "$helper" "$TDIR/data" || fail 'empty set'
printf '{"ok":true}\n' > "$TDIR/data/nested space/good file.json"
printf 'ok: true\n' > "$TDIR/data/nested space/good file.yaml"
printf 'bad: [\n' > "$TDIR/data/.git/ignored.yml"
bash "$helper" "$TDIR/data" || fail 'valid files and ignored git metadata'
for suffix in json yaml yml; do
  bad="$TDIR/data/nested space/bad file.$suffix"
  printf '[}\n' > "$bad"
  if bash "$helper" "$TDIR/data" > "$TDIR/parser.log" 2>&1; then fail "malformed $suffix passed"; fi
  rm "$bad"
done
echo 'ok - actual CI validator accepts empty/valid files and rejects malformed JSON/YAML with spaces'

# Copy only the adapter test's dependencies; never mutate the working tree's identity.
mkdir -p "$TDIR/repo/tests" "$TDIR/repo/daemon" "$TDIR/repo/bin"
cp -R "$ROOT/lib" "$ROOT/skills" "$ROOT/agents" "$ROOT/.claude-plugin" "$TDIR/repo/"
cp -R "$ROOT/tests/fixtures" "$TDIR/repo/tests/"
cp "$ROOT/tests/review-decision-adapters.test.sh" "$TDIR/repo/tests/"
cp "$ROOT/daemon/daemon.sh" "$TDIR/repo/daemon/"
cp "$ROOT/bin/oracle-review.sh" "$TDIR/repo/bin/"
cd "$TDIR/repo"
$test_command > "$TDIR/adapters-valid.log" 2>&1 || { cat "$TDIR/adapters-valid.log"; fail 'unmodified adapter fixture'; }
identity=skills/pro-gate/review-decision-v1.json
cp "$identity" "$TDIR/identity"
jq -cjS '.corpus_digest="0000000000000000000000000000000000000000000000000000000000000000"' "$TDIR/identity" > "$identity"
if $test_command > "$TDIR/adapters-bad-identity.log" 2>&1; then fail 'planted bad identity passed CI command'; fi
grep -Fq 'not ok - plugin identity' "$TDIR/adapters-bad-identity.log" || fail 'identity did not fail for expected reason'
cp "$TDIR/identity" "$identity"
corpus=tests/fixtures/review-decision/v1/corpus.json
cp "$corpus" "$TDIR/corpus"
jq -cjS '.cases[0].expected.action="invented-action"' "$TDIR/corpus" > "$corpus"
if $test_command > "$TDIR/adapters-bad-corpus.log" 2>&1; then fail 'planted bad corpus passed CI command'; fi
grep -Fq 'not ok - frozen corpus' "$TDIR/adapters-bad-corpus.log" || fail 'corpus did not fail for expected reason'
echo 'ok - CI-invoked adapter suite rejects planted identity and corpus corruption'
