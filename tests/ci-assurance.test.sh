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
leg_coverage() { # workflow file; prints the problem and returns 1 on any gap
  local wf="$1" invoked expected
  invoked="$(yq '.jobs.tests.strategy.matrix.include[].tests' "$wf" | grep -v '^---$' | sed '/^$/d' | sort)"
  expected="$(cd "$ROOT" && for f in tests/*.test.sh; do printf 'bash %s\n' "$f"; done
              for f in tests/*.test.mjs; do printf 'node --test %s\n' "$f"; done | sort)"
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
echo 'ok - every test file runs in exactly one CI leg; a dropped or doubled suite is rejected'

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
