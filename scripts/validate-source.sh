#!/usr/bin/env bash
# A parser failure must fail CI, including a failure before the last filename.
set -euo pipefail
cd -- "${1:-.}"
find . -path './.git' -prune -o -name '*.json' -exec jq empty {} +
find . -path './.git' -prune -o \( -name '*.yaml' -o -name '*.yml' \) -exec yq eval '.' {} + >/dev/null
find . -path './.git' -prune -o -name '*.sh' -exec shellcheck --norc --severity=error {} +

# Stock macOS /bin/bash is 3.2, whose parser rejects some scripts bash 5 accepts: a case pattern
# without its leading parenthesis inside $( ) or <( ) ends the substitution early, so nothing that
# sourced lib/pro-gate-lib.sh could start on a Mac (#295). Parse every shell file with bash 3.2.57.
# The suites under tests/ are left out because they need bash 4 or later anyway.
BASH32_IMAGE='bash:3.2@sha256:0fd7cb8499c63a3c9345e7088a9cd83bb69f6e895e83833859aff838a0312091'
shells="$(mktemp)"
trap 'rm -f "$shells"' EXIT
find . -path './.git' -prune -o -path './tests' -prune -o -name '*.sh' -print0 > "$shells"
if [ -s "$shells" ]; then
  docker run --rm -i -v "$PWD:/w:ro" -w /w "$BASH32_IMAGE" \
    bash -c 'rc=0; while IFS= read -r -d "" f; do bash -n "$f" || rc=1; done; exit "$rc"' < "$shells"
fi
