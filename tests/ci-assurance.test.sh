#!/usr/bin/env bash
# Exercise the commands trusted CI actually invokes, including planted negatives.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "$TDIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
helper="$ROOT/scripts/validate-source.sh"
workflow="$ROOT/.github/workflows/ci.yml"
[ "$(yq '.jobs.check.steps[] | select(.name == "Validate data and shell files") | .run' "$workflow")" = 'bash scripts/validate-source.sh' ] || fail 'CI must invoke the tested validator'
test_command="$(yq '.jobs.check.steps[] | select(.name == "Run tests") | .run' "$workflow" | sed -n '/^bash tests\/review-decision-adapters.test.sh$/p')"
[ "$test_command" = 'bash tests/review-decision-adapters.test.sh' ] || fail 'trusted CI must invoke adapter conformance'
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
