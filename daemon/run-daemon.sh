#!/usr/bin/env bash
# Service wrapper for the daemon (systemd/launchd ExecStart). Sets PATH, then execs daemon.sh.
PRO_GATE_HOME="${PRO_GATE_HOME:-$HOME/.pro-review-daemon}"
. "$PRO_GATE_HOME/lib.sh" 2>/dev/null || true
type pg_augment_path >/dev/null 2>&1 && pg_augment_path
cd "$PRO_GATE_HOME"
exec "$PRO_GATE_HOME/daemon.sh"
