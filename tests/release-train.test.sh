#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected $2, got $1"; pass "$3"; }

mkdir -p "$TMP/bin" "$TMP/source/.claude-plugin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$CURL_LOG"\n' > "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
printf '{"name":"pro-gate","version":"0.1.0"}\n' > "$TMP/source/.claude-plugin/plugin.json"
git -C "$TMP/source" init -q
git -C "$TMP/source" config user.email test@example.com
git -C "$TMP/source" config user.name Test
git -C "$TMP/source" add .
git -C "$TMP/source" commit -qm source
printf '0.1.0\n' > "$TMP/source/VERSION"
git -C "$TMP/source" add VERSION
git -C "$TMP/source" commit -qm version
git -C "$TMP/source" tag v0.1.0
SOURCE_SHA="$(git -C "$TMP/source" rev-parse HEAD)"
mkdir -p "$TMP/assets"
printf 'runtime\n' > "$TMP/assets/pro-gate-runtime-0.1.0.tar.gz"
(cd "$TMP/assets" && sha256sum pro-gate-runtime-0.1.0.tar.gz > pro-gate-runtime-0.1.0.tar.gz.sha256)

mkdir -p "$TMP/seed/.claude-plugin" "$TMP/seed/scripts"
printf '%s\n' '{"name":"hov","owner":{"name":"House of Vibe","url":"https://houseofvibe.ai"},"metadata":{"description":"test","version":"0.2.0"},"plugins":[{"name":"token-eater","description":"test","source":{"source":"url","url":"https://github.com/StartupBros-com/token-eater.git","sha":"0000000000000000000000000000000000000000"}},{"name":"pro-gate","description":"test","source":{"source":"url","url":"https://github.com/StartupBros-com/pro-gate.git","sha":"1111111111111111111111111111111111111111"}}]}' > "$TMP/seed/.claude-plugin/marketplace.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/seed/scripts/validate-marketplace.sh"
chmod +x "$TMP/seed/scripts/validate-marketplace.sh"
git -C "$TMP/seed" init -q
git -C "$TMP/seed" config user.email test@example.com
git -C "$TMP/seed" config user.name Test
git -C "$TMP/seed" add .
git -C "$TMP/seed" commit -qm seed
git -C "$TMP/seed" branch -M main
git clone -q --bare "$TMP/seed" "$TMP/marketplace.git"
git clone -q "$TMP/marketplace.git" "$TMP/marketplace"
git -C "$TMP/marketplace" config user.email test@example.com
git -C "$TMP/marketplace" config user.name Test

export PATH="$TMP/bin:$PATH" CURL_LOG="$TMP/curl.log"
common=(
  EVENT_ACTION=published REPOSITORY=pro-gate RELEASE_ID=201 RELEASE_TAG=v0.1.0
  RELEASE_NAME='Pro Gate 0.1.0' RELEASE_URL='https://github.com/StartupBros-com/pro-gate/releases/tag/v0.1.0'
  RELEASE_PRERELEASE=false RELEASE_DRAFT=false LATEST_STABLE_ID=201 SOURCE_ROOT="$TMP/source" ASSET_DIR="$TMP/assets"
  SOURCE_SHA="$SOURCE_SHA" MARKETPLACE_DIR="$TMP/marketplace" ANNOUNCE_URL=https://example.test/tool-releases
  ANNOUNCE_SECRET=test-secret
)
env "${common[@]}" "$ROOT/scripts/release-train.sh" >/dev/null
fresh="$TMP/fresh"
git clone -q "$TMP/marketplace.git" "$fresh"
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$fresh/.claude-plugin/marketplace.json")" 201 'stable latest release promotes'
assert_eq "$(wc -l < "$TMP/curl.log")" 1 'promotion announces once'

env "${common[@]}" "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'rerun calls idempotent announce operation'

git clone -q --bare "$TMP/marketplace.git" "$TMP/retry-marketplace.git"
git clone -q "$TMP/retry-marketplace.git" "$TMP/retry-marketplace"
git -C "$TMP/retry-marketplace" config user.email test@example.com
git -C "$TMP/retry-marketplace" config user.name Test
cat > "$TMP/retry-marketplace.git/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
cat >/dev/null
if [ ! -e "$TMP/retry-push-rejected" ]; then
  : > "$TMP/retry-push-rejected"
  exit 1
fi
EOF
chmod +x "$TMP/retry-marketplace.git/hooks/pre-receive"
: > "$TMP/retry-curl.log"
CURL_LOG="$TMP/retry-curl.log" env "${common[@]}" RELEASE_ID=202 LATEST_STABLE_ID=202 \
  MARKETPLACE_DIR="$TMP/retry-marketplace" "$ROOT/scripts/release-train.sh" >/dev/null
retry_remote="$TMP/retry-remote-check"
git clone -q "$TMP/retry-marketplace.git" "$retry_remote"
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$retry_remote/.claude-plugin/marketplace.json")" 202 'rejected push retries from remote tip'
assert_eq "$(wc -l < "$TMP/retry-curl.log")" 1 'retry announces only after remote promotion'

printf '#!/usr/bin/env bash\nexit 23\n' > "$TMP/fail-validator"
chmod +x "$TMP/fail-validator"
git clone -q "$TMP/marketplace.git" "$TMP/invalid-marketplace"
git -C "$TMP/invalid-marketplace" config user.email test@example.com
git -C "$TMP/invalid-marketplace" config user.name Test
if env "${common[@]}" RELEASE_ID=202 LATEST_STABLE_ID=202 \
  MARKETPLACE_DIR="$TMP/invalid-marketplace" MARKETPLACE_VALIDATOR="$TMP/fail-validator" \
  "$ROOT/scripts/release-train.sh" >/dev/null 2>&1; then
  fail 'malformed marketplace validation failure was swallowed'
else
  pass 'malformed marketplace validation failure propagates'
fi

remote_check="$TMP/remote-check"
git clone -q "$TMP/marketplace.git" "$remote_check"
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$remote_check/.claude-plugin/marketplace.json")" 201 'failed validation prevents marketplace push'

env "${common[@]}" RELEASE_ID=200 LATEST_STABLE_ID=200 "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'older release no-op does not announce'

env "${common[@]}" RELEASE_ID=202 LATEST_STABLE_ID=202 RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'prerelease is ignored'

env "${common[@]}" EVENT_ACTION=edited "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 3 'edited release announces when marketplace exactly matches'

env "${common[@]}" EVENT_ACTION=edited RELEASE_ID=202 LATEST_STABLE_ID=202 "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 4 'newly stable edited release promotes and announces once'
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$TMP/marketplace/.claude-plugin/marketplace.json")" 202 'newly stable edited release advances marketplace'

env "${common[@]}" EVENT_ACTION=edited RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 4 'edited prerelease remains production no-op'

echo 'ALL PASS'
