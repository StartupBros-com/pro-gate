#!/usr/bin/env bash
# A parser failure must fail CI, including a failure before the last filename.
set -euo pipefail
cd -- "${1:-.}"
find . -path './.git' -prune -o -name '*.json' -exec jq empty {} +
find . -path './.git' -prune -o \( -name '*.yaml' -o -name '*.yml' \) -exec yq eval '.' {} + >/dev/null
find . -path './.git' -prune -o -name '*.sh' -exec shellcheck --severity=error {} +
