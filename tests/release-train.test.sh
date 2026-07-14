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

env "${common[@]}" RELEASE_ID=200 LATEST_STABLE_ID=200 "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'older release no-op does not announce'

env "${common[@]}" RELEASE_ID=202 LATEST_STABLE_ID=202 RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'prerelease is ignored'

env "${common[@]}" EVENT_ACTION=edited MARKETPLACE_DIR= "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 3 'edited release announces without promotion'

env "${common[@]}" EVENT_ACTION=edited RELEASE_PRERELEASE=true MARKETPLACE_DIR= "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 3 'edited prerelease remains production no-op'

echo 'ALL PASS'
