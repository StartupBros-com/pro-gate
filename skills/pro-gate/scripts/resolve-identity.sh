#!/usr/bin/env bash
set -euo pipefail

skill_root="${PRO_GATE_SKILL_ROOT:-${SKILL_ROOT:-}}"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  skill_root="$CLAUDE_PLUGIN_ROOT/skills/pro-gate"
fi
[ -n "$skill_root" ] || {
  echo "ERROR: set SKILL_ROOT or PRO_GATE_SKILL_ROOT to the directory containing pro-gate SKILL.md" >&2
  exit 1
}

identity="$skill_root/review-decision-v1.json"
manifest="${PRO_GATE_PLUGIN_MANIFEST:-}"
if [ -z "$manifest" ]; then
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    manifest="$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"
  else
    manifest="$skill_root/../../.claude-plugin/plugin.json"
  fi
fi

[ -f "$identity" ] && [ ! -L "$identity" ] && [ -f "$manifest" ] && [ ! -L "$manifest" ] || {
  echo "ERROR: could not resolve the pro-gate manifest and canonical identity" >&2
  exit 1
}

python3 - "$manifest" "$identity" <<'PY'
import json
import re
import sys

manifest_path, identity_path = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    manifest = json.load(stream)
with open(identity_path, "rb") as stream:
    raw = stream.read()
identity = json.loads(raw.decode("utf-8"))
canonical = json.dumps(
    identity,
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=False,
).encode()
keys = {"contract_id", "contract_version", "contract_digest", "corpus_digest"}
version = manifest.get("version")
valid = (
    isinstance(version, str)
    and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
    and isinstance(identity, dict)
    and set(identity) == keys
    and raw == canonical
    and identity["contract_id"] == "review-decision/v1"
    and isinstance(identity["contract_version"], int)
    and identity["contract_version"] > 0
    and all(
        isinstance(identity[key], str)
        and re.fullmatch(r"[0-9a-f]{64}", identity[key])
        for key in ("contract_digest", "corpus_digest")
    )
)
if not valid:
    raise SystemExit("ERROR: pro-gate plugin identity is malformed")
print(
    version,
    identity["contract_id"],
    identity["contract_version"],
    identity["contract_digest"],
    identity["corpus_digest"],
    sep="\t",
)
PY
