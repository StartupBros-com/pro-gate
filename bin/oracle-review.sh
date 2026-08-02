#!/usr/bin/env bash
# oracle-review.sh: run a FINAL-TIER Pro review of a PR (or diff) via oracle.
# Single source of truth for "how we call oracle for a review" — the /pro-gate skill and the
# daemon both call this. Cross-platform: macOS drives signed-in Chrome natively; WSL/Linux
# attaches to the durable Xvfb Chrome over CDP.
#
# CALLERS — keep in sync IN THE SAME PR whenever the caller contract changes (status file,
# exit codes, recovery semantics); they have drifted before (v0.18 missed the agent):
#   skills/pro-gate/SKILL.md      (authoritative caller guide)
#   agents/oracle-reviewer.md     (thin relay agent for other pipelines)
#
# Usage:
#   oracle-review.sh --pr <url|number> [--repo <dir>] [--input both|bundle|connector]
#                    [--out <file>] [--timeout <dur>] [--extra-files <glob>]
#                    [--confirm <prior-review-file>]
#   oracle-review.sh --diff <patchfile> --repo <dir> [--out <file>] ...
#       Pass --pr TOGETHER with --diff when the diff belongs to a PR: the change identity
#       (round budget, per-change lock, reservations) stays the PR's instead of forking into
#       a separate repo+branch identity.
#   oracle-review.sh --confirm <prior-review-file> ...
#       Confirming pass (v0.22): attaches the prior review and instructs the model to verify
#       EVERY prior P0/P1 as RESOLVED or STILL-PRESENT before reporting new findings. A
#       budget-accounted engine run like any other.
#   oracle-review.sh --harvest <run-marker> --out <file> [--timeout <dur>]
#       Collect a review whose run ended in-progress (exit 9): the Pro slot was spent but the
#       model was still generating when the salvage budget ran out. No new slot is spent.
#   oracle-review.sh --status [<pr-number|pr-url|pg-run-marker>] [--json]
#       Read-only run rediscovery (v0.27): join reservations, round budget, remembered
#       conversation URLs, and the ledger, and print each matching run's state plus the exact
#       next command. For callers that lost their context (compaction, new session): answers
#       "what runs exist for this change, what do I harvest, how many rounds remain" from
#       nothing but a PR number. No locks, no browser, no writes; omit the query for all state.
set -uo pipefail

# --- locate + source the shared lib (works from repo and from deployed location) ---
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in "$SELF/lib.sh" "$SELF/../lib/pro-gate-lib.sh" "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/lib.sh"; do
  [ -f "$c" ] && { . "$c"; break; }
done
type pg_os >/dev/null 2>&1 || { echo "ERROR: pro-gate lib not found (lib.sh)" >&2; exit 10; }

pg_augment_path
pg_load_env
OS="$(pg_os)"; MODE="$(pg_browser_mode)"

PR=""; REPO=""; DIFF_FILE=""; INPUT="both"; OUT=""; TIMEOUT="30m"; EXTRA_GLOB=""; HARVEST_MARKER=""; HARVEST_REQUESTED=0; CONFIRM_FILE=""
STATUS_REQUESTED=0; STATUS_QUERY=""; AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --diff) DIFF_FILE="$2"; shift 2;;
    --input) INPUT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --extra-files) EXTRA_GLOB="$2"; shift 2;;
    --confirm) CONFIRM_FILE="$2"; shift 2;;
    --harvest) HARVEST_REQUESTED=1; HARVEST_MARKER="${2:-}"; shift 2;;
    # --status takes an OPTIONAL query (a following --flag or nothing means "all state").
    --status) STATUS_REQUESTED=1
      case "${2:-}" in ''|--*) shift 1;; *) STATUS_QUERY="$2"; shift 2;; esac;;
    --json) AS_JSON=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
if [ "$AS_JSON" = 1 ] && [ "$STATUS_REQUESTED" != 1 ]; then
  echo "ERROR: --json is only meaningful with --status" >&2
  exit 2
fi
if [ "$HARVEST_REQUESTED" = 1 ] && [ -z "$HARVEST_MARKER" ]; then
  echo "ERROR: --harvest requires a non-empty run marker" >&2
  exit 2
fi
if [ -n "$CONFIRM_FILE" ] && [ ! -s "$CONFIRM_FILE" ]; then
  echo "ERROR: --confirm file not found or empty: $CONFIRM_FILE" >&2
  exit 2
fi

# --- v0.27: --status — read-only run rediscovery (issue #47) ---
# Joins the state the engine already keeps (in-progress/ reservations, rounds/<key> budget,
# conversation-urls/ memos, ledger.jsonl) so a caller with NOTHING but a PR number can answer:
# what runs exist for this change, what state are they in, where is the output, what marker do
# I harvest, and how many budget rounds remain. Pure inspection — no locks, no status file, no
# browser, no writes — safe any time, including while a run is live. Exit 0 even when nothing
# is found (absence is an answer); 2 on usage errors.
if [ "$STATUS_REQUESTED" = 1 ]; then
  if [ "$AS_JSON" = 1 ] && ! pg_have jq; then
    echo "ERROR: --status --json requires jq" >&2; exit 2
  fi
  ST_RES_DIR="$(pg_reservation_dir)"
  ST_ROUNDS_DIR="$(pg_rounds_dir)"
  ST_LEDGER="${PRO_GATE_LEDGER:-$PRO_GATE_HOME/ledger.jsonl}"
  ST_URLS_DIR="$PRO_GATE_HOME/conversation-urls"
  ST_ENGINE="$PRO_GATE_HOME/oracle-review.sh"
  ST_CAP="${PRO_GATE_MAX_ROUNDS_PER_PR:-4}"; case "$ST_CAP" in ''|*[!0-9]*) ST_CAP=4;; esac
  ST_WIN="$(pg_round_window_secs)"
  ST_NOW="$(date +%s)"
  ST_LOCKFILE="${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}"
  ST_INFLIGHT_KEY=""; ST_SPENT_KEY=""; ST_SPENT_N=0; ST_ACTIVE_HINT=""

  # Non-blocking in-flight probe (same technique as round_capped's): a held per-change lock
  # means a same-change review is RUNNING right now — the one state with no reservation and no
  # ledger row yet, where "no state found" would wrongly invite a duplicate launch. Read-only:
  # probe only locks that already exist (opening would otherwise create the file).
  st_inflight() {  # $1 = round key -> rc 0 when a same-change run holds the lock now
    local lf="${ST_LOCKFILE}.pr-$1" pfd opid
    if [ -d "${lf}.d" ]; then
      # mkdir-fallback lock (no flock, e.g. stock macOS): live only when the recorded owner
      # is a running pid. A dead/absent owner is a stale dir from SIGKILL/reboot — pg_lock
      # self-heals it at the next acquisition; report it NOT live, mutate nothing
      # (gate #53 r3 P1: existence alone reported stale locks as RUNNING forever).
      opid="$(cat "${lf}.d/pid" 2>/dev/null || true)"
      case "$opid" in ''|*[!0-9]*) return 1;; *) kill -0 "$opid" 2>/dev/null; return $?;; esac
    fi
    [ -e "$lf" ] || return 1
    pg_have flock || return 1
    if { exec {pfd}>>"$lf"; } 2>/dev/null; then
      if flock -n "$pfd" 2>/dev/null; then eval "exec ${pfd}>&-" 2>/dev/null; return 1; fi
      eval "exec ${pfd}>&-" 2>/dev/null; return 0
    fi
    return 1
  }

  # Normalize the query: marker, PR URL (repo-scoped slug + number), bare number, or all.
  Q_NUM=""; Q_SLUG=""; Q_MARKER=""
  case "$STATUS_QUERY" in
    '') ;;
    pg-run-*)
      pg_reservation_marker_ok "$STATUS_QUERY" \
        || { echo "ERROR: invalid marker syntax: $STATUS_QUERY" >&2; exit 2; }
      Q_MARKER="$STATUS_QUERY";;
    http*://*/pull/*)
      Q_NUM="${STATUS_QUERY##*/}"; Q_NUM="${Q_NUM%%[!0-9]*}"
      Q_SLUG="$(printf '%s' "$STATUS_QUERY" \
        | sed -nE 's#https?://[^/]+/([^/]+)/([^/]+)/pull/.*#\1-\2#p' | tr -c 'A-Za-z0-9.\n-' '-')"
      [ -n "$Q_NUM" ] || { echo "ERROR: could not parse a PR number from: $STATUS_QUERY" >&2; exit 2; };;
    *[!0-9]*)
      echo "ERROR: --status takes a PR number, a PR URL, or a pg-run-... marker (omit for all)" >&2
      exit 2;;
    *) Q_NUM="$STATUS_QUERY";;
  esac

  # A reservation matches on: exact marker; or the COMPLETE key embedded in the marker
  # (strip the pg-run- prefix and the trailing -epoch-pid). Round keys are not prefix-free
  # (acme-widgets-42-tools-7 contains acme-widgets-42-), so slugged queries compare the whole
  # key for equality and bare-number queries require the key's FINAL segment — substring
  # matches leak foreign changes, and reservations outrank every other status source
  # (gate #53 r3 P1). A bare number still shows every repo's match by design (keys are
  # repo-scoped precisely so numbers can collide; the marker display disambiguates).
  st_match() {  # $1 marker, $2 recorded pr field ('' when unknown)
    local m="$1" pr="${2:-}" km
    [ -n "$Q_MARKER" ] && { [ "$m" = "$Q_MARKER" ]; return; }
    [ -n "$Q_NUM" ] || return 0
    km="${m#pg-run-}"; km="${km%-*-*}"
    if [ -n "$Q_SLUG" ]; then
      [ "$km" = "${Q_SLUG}-${Q_NUM}" ]; return
    fi
    [ "$pr" = "$Q_NUM" ] && return 0
    case "$km" in *"-${Q_NUM}") return 0;; esac
    return 1
  }

  ST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pg-status.XXXXXX")"
  trap 'rm -rf "$ST_TMP"' EXIT
  : > "$ST_TMP/res.jsonl"; : > "$ST_TMP/rounds.jsonl"; : > "$ST_TMP/ledger.jsonl"
  ST_HINT=""

  # 1) Reservations: in-progress runs whose review is collectable for FREE.
  if [ -d "$ST_RES_DIR" ]; then
    for f in "$ST_RES_DIR"/pg-run-*; do
      [ -f "$f" ] || continue
      m="$(basename "$f")"
      r_pr=""; r_out=""; r_created=""; r_miss=""; r_slot=""; r_model=""
      IFS=$'\t' read -r r_pr r_out r_created r_miss r_slot r_model < "$f" 2>/dev/null || true
      st_match "$m" "$r_pr" || continue
      case "$r_created" in ''|*[!0-9]*) r_age="";; *) r_age=$(( ST_NOW - r_created ));; esac
      r_url=""; [ -f "$ST_URLS_DIR/$m" ] && r_url="$(head -c 300 "$ST_URLS_DIR/$m" 2>/dev/null | tr -d '\n')"
      [ -n "$r_out" ] || r_out="${TMPDIR:-/tmp}/pro-gate-${r_pr:-review}.md"
      r_cmd="$ST_ENGINE --harvest '$m' --out '$r_out' --timeout 20m"
      [ -n "$ST_HINT" ] || ST_HINT="in-progress reservation found — collect it for FREE: $r_cmd"
      if pg_have jq; then
        jq -nc --arg marker "$m" --arg pr "${r_pr:-}" --arg out "$r_out" \
          --arg age "${r_age:-}" --arg miss "${r_miss:-}" --arg model "${r_model:-}" \
          --arg url "$r_url" --arg harvest_cmd "$r_cmd" \
          '{marker:$marker,pr:$pr,out:$out,age_secs:(($age|tonumber?)//null),miss_streak:(($miss|tonumber?)//null),model:$model,conversation_url:$url,harvest_cmd:$harvest_cmd}' \
          >> "$ST_TMP/res.jsonl" 2>/dev/null
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$m" "${r_pr:-?}" "${r_age:-?}" "${r_miss:-?}" "$r_cmd" >> "$ST_TMP/res.tsv"
      fi
    done
  fi

  # 2) Round budget + live-run probes, per change key. The key set is the UNION of rounds/*,
  # active/*, held per-change lock files, and the query-derived key — not rounds/* alone: a
  # first-ever run holds the per-change lock (and, once committed, an active record) while it
  # waits for an account slot, BEFORE any rounds file exists; enumerating only rounds/ would
  # report "no state" for that whole wait and invite a duplicate wrapper (gate #53 r2 P1).
  ST_KEYS=""
  st_add_key() { pg_round_key_ok "$1" || return 0; case " $ST_KEYS " in *" $1 "*) ;; *) ST_KEYS="$ST_KEYS $1";; esac; }
  if [ -d "$ST_ROUNDS_DIR" ]; then
    for f in "$ST_ROUNDS_DIR"/*; do
      [ -f "$f" ] || continue
      case "$f" in *.last) continue;; esac
      st_add_key "$(basename "$f")"
    done
  fi
  if [ -d "$PRO_GATE_HOME/active" ]; then
    for f in "$PRO_GATE_HOME/active"/*; do [ -f "$f" ] && st_add_key "$(basename "$f")"; done
  fi
  for f in "${ST_LOCKFILE}.pr-"*; do
    [ -e "$f" ] || continue
    k="${f#"${ST_LOCKFILE}".pr-}"; k="${k%.d}"; st_add_key "$k"
  done
  [ -n "$Q_SLUG" ] && [ -n "$Q_NUM" ] && st_add_key "${Q_SLUG}-${Q_NUM}"
  for k in $ST_KEYS; do
    if [ -n "$Q_MARKER" ]; then
      km="${Q_MARKER#pg-run-}"; km="${km%-*-*}"   # same best-effort strip the harvest path uses
      [ "$k" = "$km" ] || continue
    elif [ -n "$Q_NUM" ]; then
      case "$k" in "${Q_SLUG:+${Q_SLUG}-}${Q_NUM}"|*"-${Q_NUM}") [ -z "$Q_SLUG" ] || [ "$k" = "${Q_SLUG}-${Q_NUM}" ] || continue;; *) continue;; esac
    fi
    spent="$(pg_round_count "$k")"
    k_live=0; st_inflight "$k" && { k_live=1; ST_INFLIGHT_KEY="$k"; }
    # Active-run index: sees a live run before any reservation/ledger row exists, AND the
    # wrapper-died-mid-generation case (which releases the flock, so st_inflight misses it).
    a_marker=""; a_out=""; a_pid=""; a_epoch=""; a_mode=""; a_alive=""
    if [ -f "$PRO_GATE_HOME/active/$k" ]; then
      IFS=$'\t' read -r a_marker a_out a_pid a_epoch a_mode < "$PRO_GATE_HOME/active/$k" 2>/dev/null || true
      case "$a_pid" in ''|*[!0-9]*) a_alive=0;; *) if kill -0 "$a_pid" 2>/dev/null; then a_alive=1; else a_alive=0; fi;; esac
      if [ "$a_alive" = 1 ]; then
        k_live=1; ST_INFLIGHT_KEY="$k"
        [ -n "$ST_ACTIVE_HINT" ] || ST_ACTIVE_HINT="a same-change review is RUNNING right now (pid ${a_pid}): poll ${a_out}.status — do NOT launch another"
      elif [ "$a_mode" = native ]; then
        # Native has no marker-addressable harvest (--harvest exits 3 there): pointing at it
        # would be an unusable loop that never clears (gate #53 r2 P1). Manual recovery only.
        [ -n "$ST_ACTIVE_HINT" ] || ST_ACTIVE_HINT="the last run's wrapper DIED (native mode: no harvest path) — check ${a_out} and ${a_out}.status, and look for the conversation in the ChatGPT UI; once resolved, rm '$PRO_GATE_HOME/active/$k' to retire this notice (it also expires with the 24h sweep)"
      elif [ -n "$a_marker" ]; then
        [ -n "$ST_ACTIVE_HINT" ] || ST_ACTIVE_HINT="the last run's wrapper DIED but the browser may still be generating — recover by marker, never a fresh run: $ST_ENGINE --harvest '$a_marker' --out '${a_out:-${TMPDIR:-/tmp}/pro-gate-recovered.md}' --timeout 20m"
      fi
    fi
    # 'all' queries skip idle debris — but never a key with anything live on it.
    if [ -z "$Q_NUM$Q_MARKER" ] && ! [ "$spent" -gt 0 ] 2>/dev/null && [ "$k_live" != 1 ] && [ -z "$a_marker$a_out" ]; then
      continue
    fi
    rem=$(( ST_CAP - spent )); [ "$rem" -lt 0 ] && rem=0
    if [ "$spent" -gt 0 ] 2>/dev/null; then ST_SPENT_KEY="$k"; ST_SPENT_N="$spent"; fi
    if pg_have jq; then
      jq -nc --arg key "$k" --argjson spent "$spent" --argjson cap "$ST_CAP" \
        --argjson remaining "$rem" --argjson window_secs "$ST_WIN" --argjson in_flight "$k_live" \
        --arg amarker "$a_marker" --arg aout "$a_out" --arg aalive "$a_alive" --arg amode "$a_mode" \
        '{key:$key,spent:$spent,cap:$cap,remaining:$remaining,window_secs:$window_secs,in_flight:($in_flight == 1),active:(if $amarker == "" and $aout == "" then null else {marker:$amarker,out:$aout,wrapper_alive:($aalive == "1"),mode:$amode} end)}' \
        >> "$ST_TMP/rounds.jsonl" 2>/dev/null
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$spent" "$ST_CAP" "$rem" "$k_live" >> "$ST_TMP/rounds.tsv"
    fi
  done

  # 3) Ledger: recent finished runs for the query (newest first). Rows from engines <v0.27
  # carry no marker/round_key fields; treat them as empty rather than skipping the row. A URL
  # query pins the repo slug: PR numbers repeat across repositories, and a newer FOREIGN row
  # must never drive next_step or point at another repo's output (gate #53 P1) — legacy rows
  # with no scoping identity are excluded under a slugged query rather than guessed at. The
  # bare-number query also matches round_key suffixes, which is what harvest rows record.
  if [ -s "$ST_LEDGER" ] && pg_have jq; then
    tail -n 400 "$ST_LEDGER" | jq -c --arg num "$Q_NUM" --arg slug "$Q_SLUG" --arg marker "$Q_MARKER" '
      select(
        if $marker != "" then (.marker // "") == $marker
        elif $num == "" then true
        elif $slug != "" then
          # exact key only: round keys are NOT prefix-free (acme-widgets-42-tools-7 would pass
          # a startswith("…acme-widgets-42-") marker check), and every marker-carrying v0.27
          # row carries round_key too, so the exact match loses nothing (gate #53 r2 P1)
          ((.round_key // "") == ($slug + "-" + $num))
        else
          (.pr == $num) or ((.marker // "") | contains("-" + $num + "-")) or
          ((.round_key // "") | endswith("-" + $num))
        end
      )' 2>/dev/null | tail -n 8 \
      | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' >> "$ST_TMP/ledger.jsonl" || true
  fi

  # Hint priority after reservations: the active-run index (live run OR dead wrapper with the
  # browser possibly still generating), then a held per-change lock, then the newest matching
  # ledger row — never "no state" while any of those say otherwise.
  [ -n "$ST_HINT" ] || ST_HINT="$ST_ACTIVE_HINT"
  if [ -z "$ST_HINT" ] && [ -n "$ST_INFLIGHT_KEY" ]; then
    ST_HINT="a same-change review is RUNNING right now (per-change lock held for ${ST_INFLIGHT_KEY}): do NOT launch another — wait, then run --status again"
  fi
  if [ -z "$ST_HINT" ] && [ -s "$ST_TMP/ledger.jsonl" ] && pg_have jq; then
    ST_LAST_OUTCOME="$(head -n1 "$ST_TMP/ledger.jsonl" | jq -r '.outcome // ""')"
    ST_LAST_OUT="$(head -n1 "$ST_TMP/ledger.jsonl" | jq -r '.out // ""')"
    ST_LAST_MARKER="$(head -n1 "$ST_TMP/ledger.jsonl" | jq -r '.marker // ""')"
    case "$ST_LAST_OUTCOME" in
      in-progress)
        if [ -n "$ST_LAST_MARKER" ]; then
          ST_HINT="last run is in-progress — harvest it for FREE: $ST_ENGINE --harvest '$ST_LAST_MARKER' --out '$ST_LAST_OUT' --timeout 20m"
        else
          ST_HINT="last run is in-progress but predates v0.27 (no marker in ledger): read the run's <out>.status for .marker, or re-run the identical --pr command and let the engine redirect"
        fi;;
      clean)
        ST_HINT="last run completed clean — the review is already on disk: $ST_LAST_OUT (spend nothing)";;
      '') ;;
      *)
        ST_HINT="last run ended '$ST_LAST_OUTCOME' with no reservation held — a fresh run will SPEND a slot (round budget permitting)";;
    esac
  fi
  # Fail CLOSED when the ledger exists but cannot be read: without jq a clean row (review
  # already on disk) is invisible here, and a fresh-run recommendation would be a blind spend.
  if [ -z "$ST_HINT" ] && [ -s "$ST_LEDGER" ] && ! pg_have jq; then
    ST_HINT="a ledger exists but jq is unavailable to read it — inspect $ST_LEDGER for this change BEFORE spending anything"
  fi
  if [ -z "$ST_HINT" ] && [ "$ST_SPENT_N" -gt 0 ] 2>/dev/null; then
    ST_HINT="${ST_SPENT_N} round(s) already spent in the window for ${ST_SPENT_KEY} but no reservation, active record, ledger row, or live lock — a run may have just started or died early; a fresh run will SPEND a slot"
  fi
  [ -n "$ST_HINT" ] || ST_HINT="no engine state found for this query — a fresh run will SPEND a slot"

  if [ "$AS_JSON" = 1 ]; then
    jq -n --arg query "${STATUS_QUERY:-all}" --arg home "$PRO_GATE_HOME" --arg hint "$ST_HINT" \
      --slurpfile res <(cat "$ST_TMP/res.jsonl" 2>/dev/null; echo null) \
      --slurpfile rounds <(cat "$ST_TMP/rounds.jsonl" 2>/dev/null; echo null) \
      --slurpfile ledger <(cat "$ST_TMP/ledger.jsonl" 2>/dev/null; echo null) \
      '{query:$query,home:$home,reservations:($res[:-1]),rounds:($rounds[:-1]),recent_runs:($ledger[:-1]),next_step:$hint}'
    exit 0
  fi

  echo "[pro-gate status] query: ${STATUS_QUERY:-all}   home: $PRO_GATE_HOME"
  if [ -s "$ST_TMP/res.jsonl" ] || [ -s "$ST_TMP/res.tsv" ]; then
    echo "in-progress reservations (harvest these for FREE — never re-run):"
    if pg_have jq && [ -s "$ST_TMP/res.jsonl" ]; then
      jq -r '"  " + .marker + "  pr=" + .pr + (if .age_secs then "  age=\(.age_secs / 60 | floor)m" else "" end) + (if .conversation_url != "" then "  url=remembered" else "" end) + "\n    harvest: " + .harvest_cmd' "$ST_TMP/res.jsonl"
    else
      awk -F'\t' '{printf "  %s  pr=%s  age=%ss  miss=%s\n    harvest: %s\n", $1, $2, $3, $4, $5}' "$ST_TMP/res.tsv" 2>/dev/null
    fi
  else
    echo "in-progress reservations: none"
  fi
  if [ -s "$ST_TMP/rounds.jsonl" ] || [ -s "$ST_TMP/rounds.tsv" ]; then
    echo "round budget (rolling window $(( ST_WIN / 3600 ))h, cap $ST_CAP):"
    if pg_have jq && [ -s "$ST_TMP/rounds.jsonl" ]; then
      jq -r '"  " + .key + ": \(.spent) spent, \(.remaining) remaining" + (if .in_flight then "  [REVIEW RUNNING NOW]" else "" end)' "$ST_TMP/rounds.jsonl"
    else
      awk -F'\t' '{printf "  %s: %s spent, %s remaining (cap %s)%s\n", $1, $2, $4, $3, ($5 == 1 ? "  [REVIEW RUNNING NOW]" : "")}' "$ST_TMP/rounds.tsv" 2>/dev/null
    fi
  else
    echo "round budget: nothing spent in the current window for this query"
  fi
  if [ -s "$ST_TMP/ledger.jsonl" ]; then
    echo "recent runs (newest first):"
    jq -r '"  " + .ts + "  exit=\(.exit) " + .outcome + "  \(.secs)s  out=" + .out' "$ST_TMP/ledger.jsonl"
  elif ! pg_have jq; then
    echo "recent runs: (jq not installed — read $ST_LEDGER directly)"
  else
    echo "recent runs: none matching"
  fi
  echo "next step: $ST_HINT"
  exit 0
fi

PORT="${ORACLE_BROWSER_PORT:-9222}"
MODEL="${ORACLE_MODEL:-gpt-5.6}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pro-review.XXXXXX")"
[ -n "$OUT" ] || OUT="$WORK/findings.md"
# Fresh runs need oracle; --harvest only needs node+CDP and checks that prerequisite inside
# its branch below (moving this gate matters when oracle is temporarily unavailable but a spent
# review is waiting in an open conversation).

# --- machine-readable run status (v0.18) ---
# Callers (the /pro-gate skill, the daemon's headless agent) poll "$OUT.status" — a
# single-line JSON updated ATOMICALLY at every phase change — instead of scraping the
# engine's stderr. Phases: preflight, waiting-pr-lock, waiting-slot, launching,
# watchdog-killed, live-detected, salvaging, retry-wait, throttled, cloudflare, oversized,
# round-capped, deferred, done, failed, in-progress.
# Terminal phases: done (read $OUT), failed, deferred (no slot spent: retry later),
# oversized (no slot spent: past the hard ceiling PRO_GATE_DIFF_HARD_MAX; scope the diff — a
# merely large diff instead proceeds and lands in-progress), round-capped (no slot spent: this PR/branch
# already used its review round budget for the window; escalate to a human, do not re-run),
# in-progress (slot SPENT, model still generating: collect later with --harvest <marker>,
# NEVER relaunch).
# v0.20: the JSON carries `marker`, the run's conversation correlation id, so callers can
# harvest an in-progress review without grepping engine logs.
STATUS_FILE="$OUT.status"
pg_status() {  # $1 phase, $2 optional detail — variable fields are JSON-escaped (v0.18.1:
  # $OUT is caller-supplied; a quote/backslash in it would corrupt the polling contract)
  local phase="$1" detail="${2:-}" ts model_label
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
  # v0.21: `model` is the run's resolved model rendered through pg_model_label (captured label or
  # role-based fallback, never a hardcoded version); `model_warn` carries the advisory downgrade
  # marker (empty unless the model looked weak/unreadable). Human surfaces read both from here.
  model_label="$(pg_model_label "${RESOLVED_MODEL:-}")"
  if pg_have jq; then
    jq -nc --arg phase "$phase" --argjson attempt "${attempt:-0}" --arg detail "$detail" \
       --arg pr "${PR_NUM:-diff}" --arg out "$OUT" --arg ts "$ts" --arg marker "${RUN_MARKER:-}" \
       --arg model "$model_label" --arg model_warn "${MODEL_WARN:-}" \
       '{phase:$phase,attempt:$attempt,detail:$detail,pr:$pr,out:$out,ts:$ts,marker:$marker,model:$model,model_warn:$model_warn}' \
       > "$STATUS_FILE.tmp" 2>/dev/null
  else
    printf '{"phase":"%s","attempt":%d,"detail":"%s","pr":"%s","out":"%s","ts":"%s","marker":"%s","model":"%s","model_warn":"%s"}\n' \
      "$phase" "${attempt:-0}" "$(printf '%s' "$detail" | tr -d '"\\' | tr '\n' ' ')" \
      "${PR_NUM:-diff}" "$(printf '%s' "$OUT" | tr -d '"\\' | tr '\n' ' ')" "$ts" \
      "$(printf '%s' "${RUN_MARKER:-}" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "$model_label" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "${MODEL_WARN:-}" | tr -d '"\\' | tr '\n' ' ')" \
      > "$STATUS_FILE.tmp" 2>/dev/null
  fi
  { [ -s "$STATUS_FILE.tmp" ] && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"; } 2>/dev/null || true
}
pg_status preflight

# --- v0.19: run bookkeeping for the ledger + adaptive ramp ---
RUN_START="$(date +%s)"
SALVAGED=0
EFF_CONC=0
# v0.21: the model oracle actually resolved for THIS run, plus the selection status. Captured
# (best-effort) from oracle's "Model selection evidence:" line on fresh paths, or read back from
# the reservation record on --harvest; empty until known and whenever the resolved label is
# "(unavailable)". Oracle 0.15.2 emits that line only at completion, so exit-9/harvest runs
# usually leave this empty (dogfood PR #20); every model surface renders it through
# pg_model_label so an unknown model degrades to role-based text, never a hardcoded version.
RESOLVED_MODEL=""
MODEL_STATUS=""   # oracle's status= field (e.g. already-selected); gates the R6 warning
MODEL_WARN=""     # U5: advisory downgrade marker (weak/unconfirmable model); never blocks the run
# v0.27: active-run index — $PRO_GATE_HOME/active/<ROUND_KEY> (marker\tout\tpid\tstarted_epoch),
# written the moment a fresh run commits to spending a slot, cleared by pg_finish. Covers the
# window where a run is live — or its wrapper DIED while the browser kept generating — but
# neither a reservation nor a ledger row exists yet: --status reads this instead of concluding
# "no state" and inviting a duplicate spend (gate #53 P1; a dead wrapper also releases the
# per-change flock, so the lock probe alone cannot see that case).
pg_active_dir() { echo "$PRO_GATE_HOME/active"; }
PG_ACTIVE_WRITTEN=0
pg_active_write() {
  [ -n "${ROUND_KEY:-}" ] || return 0
  mkdir -p "$(pg_active_dir)" 2>/dev/null || return 0
  # 5th field: browser mode — recovery differs (native has no marker-addressable harvest, so a
  # dead native wrapper must NOT be routed into a --harvest loop that always exits 3).
  printf '%s\t%s\t%s\t%s\t%s\n' "${RUN_MARKER:-}" "$OUT" "$$" "$(date +%s)" "$MODE" \
    > "$(pg_active_dir)/$ROUND_KEY" 2>/dev/null && PG_ACTIVE_WRITTEN=1
  return 0
}
pg_active_clear() {  # $1 = exit code
  local f m o p e md
  f="$(pg_active_dir)/${ROUND_KEY:-}"
  { [ -n "${ROUND_KEY:-}" ] && [ -f "$f" ]; } || return 0
  if [ "${HARVEST:-0}" = 1 ]; then
    # A harvest may conclude a DEAD wrapper's run (collected: 0, or confirmed lost: 6) — then
    # its record is stale and goes. But only the record whose MARKER this harvest actually
    # collected/declared lost (legacy empty markers accepted), and only when its wrapper is
    # dead: a live wrapper still owns its record and clears it itself.
    case "$1" in 0|6) ;; *) return 0;; esac
    IFS=$'\t' read -r m o p e md < "$f" 2>/dev/null || true
    [ -z "$m" ] || [ "$m" = "${RUN_MARKER:-}" ] || return 0
    case "$p" in ''|*[!0-9]*) ;; *) kill -0 "$p" 2>/dev/null && return 0;; esac
  else
    # Fresh path: clear ONLY a record THIS process wrote (gate #53 r3 P1). Exits that occur
    # before pg_active_write — diff-fetch failure, round-cap refusal, health deferral — must
    # never erase a dead predecessor's record: it may be the only marker/output pointer that
    # run left, and deleting it lets a later --status authorize a duplicate spend.
    [ "${PG_ACTIVE_WRITTEN:-0}" = 1 ] || return 0
    IFS=$'\t' read -r m o p e md < "$f" 2>/dev/null || true
    [ "$p" = "$$" ] || return 0
  fi
  rm -f "$f" 2>/dev/null || true
}
pg_finish() {  # $1 exit code — write the ledger line, feed the ramp governor, exit
  local rc="$1" outcome dur line model_label
  dur=$(( $(date +%s) - RUN_START ))
  model_label="$(pg_model_label "${RESOLVED_MODEL:-}")"   # resolved model or role-based fallback
  case "$rc" in
    0) outcome=clean ;;
    4) outcome=bad-repo ;;
    5) outcome=diff-fetch-failed ;;
    6) outcome=failed ;;
    7) outcome=lock-timeout ;;
    8) outcome=deferred ;;
    9) outcome=in-progress ;;
    11) outcome=oversized ;;
    12) outcome=round-capped ;;
    *) outcome=other ;;
  esac
  [ "${THROTTLED:-0}" = 1 ] && outcome=throttle
  [ "${CLOUDFLARE:-0}" = 1 ] && outcome=cloudflare
  # cloudflare is an account-level block just like a throttle: drop concurrency (feed the ramp
  # the throttle signal) while recording the distinct outcome in the ledger.
  # in-progress and oversized teach the ramp nothing (the account behaved fine); harvest runs
  # (HARVEST=1) never feed it either: a harvest is not a fresh Pro spend, so a clean harvest
  # must not inflate the clean streak that earns concurrency.
  if [ "${HARVEST:-0}" != 1 ]; then
    case "$outcome" in
      clean|throttle|failed) pg_ramp_update "$outcome" "${MAX_CONC:-1}" ;;
      cloudflare)            pg_ramp_update throttle "${MAX_CONC:-1}" ;;
    esac
  fi
  # v0.27: `marker` and `round_key` land in every ledger line so --status (and any caller with
  # only the ledger) can reconstruct a harvest command without the original status file. Rows
  # from failures before identity derivation (exit 4/5) carry them empty — present, not absent.
  if pg_have jq; then
    line="$(jq -nc --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg pr "${PR_NUM:-diff}" \
      --arg repo "${REPO:-}" --argjson exit "$rc" --arg outcome "$outcome" \
      --argjson secs "$dur" --argjson attempts "${attempt:-0}" \
      --argjson conc "${EFF_CONC:-0}" --argjson ceiling "${MAX_CONC:-1}" \
      --argjson live "${LIVE_CONVERSATION:-0}" --argjson salvaged "${SALVAGED:-0}" \
      --argjson diff_lines "${DIFF_LINES:-0}" --arg out "$OUT" --arg model "$model_label" \
      --arg marker "${RUN_MARKER:-}" --arg round_key "${ROUND_KEY:-}" \
      '{ts:$ts,pr:$pr,repo:$repo,exit:$exit,outcome:$outcome,secs:$secs,attempts:$attempts,conc:$conc,ceiling:$ceiling,live:$live,salvaged:$salvaged,diff_lines:$diff_lines,out:$out,model:$model,marker:$marker,round_key:$round_key}' 2>/dev/null)"
  else
    line="$(printf '{"ts":"%s","pr":"%s","exit":%d,"outcome":"%s","secs":%d,"attempts":%d,"conc":%d,"ceiling":%d,"live":%d,"salvaged":%d,"out":"%s","model":"%s","marker":"%s","round_key":"%s"}' \
      "$(date +%Y-%m-%dT%H:%M:%S%z)" "${PR_NUM:-diff}" "$rc" "$outcome" "$dur" "${attempt:-0}" \
      "${EFF_CONC:-0}" "${MAX_CONC:-1}" "${LIVE_CONVERSATION:-0}" "${SALVAGED:-0}" \
      "$(printf '%s' "$OUT" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "$model_label" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "${RUN_MARKER:-}" | tr -d '"\\' | tr '\n' ' ')" \
      "$(printf '%s' "${ROUND_KEY:-}" | tr -d '"\\' | tr '\n' ' ')")"
  fi
  pg_ledger_append "$line"
  pg_active_clear "$rc"
  # Close this run's conversation tab. We run oracle with --browser-archive=never (so probe and
  # salvage can always find the conversation by marker), which means WE own cleanup, otherwise
  # /c/ tabs accumulate and add load to the account. Best-effort, bounded, non-fatal; matched by
  # RUN_MARKER so we never touch another run's tab. remote-chrome only (native drives the user's
  # own Chrome, where closing tabs is not ours to do). PRO_GATE_KEEP_TABS=1 opts out (debugging).
  # Skip cleanup for lock-timeout (7), deferred (8), oversized (11), and round-capped (12): no
  # slot was spent, so no conversation tab exists, and a CDP scan there would just waste time.
  # Skip it for in-progress (9) because the model is STILL GENERATING in that tab: closing it
  # destroys a spent Pro slot's answer (a 65-minute Pro review was lost exactly this way on
  # 2026-07-09); the tab stays open for --harvest, which closes it once finally captured.
  # Skip it for engine/browser trouble (3) too (v0.25): that path tells the caller "reservation
  # and tab kept, retry once CDP is healthy", so closing the tab here would contradict the
  # promise and throw away the conversation the retry is supposed to collect.
  if [ "$rc" != 3 ] && [ "$rc" != 7 ] && [ "$rc" != 8 ] && [ "$rc" != 9 ] && [ "$rc" != 11 ] && [ "$rc" != 12 ] \
     && [ "$MODE" = remote-chrome ] && [ "${PRO_GATE_KEEP_TABS:-0}" != 1 ] \
     && [ -n "${RUN_MARKER:-}" ] && command -v node >/dev/null 2>&1; then
    timeout 30 node "$SELF/cdp-salvage.mjs" --close "$RUN_MARKER" 25 "$PORT" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}

# --- preflight: browser reachable / signed in (per platform) ---
if [ "$MODE" = "remote-chrome" ]; then
  export DISPLAY="${ORACLE_DISPLAY:-:99}"
  # v0.19: one self-heal attempt (non-interactive service start) before giving up.
  if ! pg_cdp_heal; then
    echo "ERROR: oracle browser session (CDP) not reachable on ${PORT} (self-heal attempted)." >&2
    [ "$(pg_service_mgr)" = systemd ] && echo "  start it: sudo systemctl start oracle-chrome" >&2
    pg_status failed "browser CDP unreachable"
    exit 3
  fi
else
  # native (macOS): oracle drives your signed-in Chrome. Nothing to pre-start; oracle errors
  # clearly if you're not signed into ChatGPT.
  :
fi

# --- v0.20: harvest mode: collect an in-progress run's review, spending NO new slot ---
# A run that exits 9 (in-progress) spent its Pro slot but hit the salvage budget while the
# model was still generating; its conversation tab was deliberately left open. This mode
# re-runs ONLY the marker-matched CDP collection. Exit: 0 done, 9 still generating / retry later
# (also: the browser never answered, which is NOT counted as a miss), 8 deferred (cooldown/box
# unfit: the account must not be rendered against), 6 conversation gone (review lost; only now is
# a re-run justified).
# v0.25: the collection is no longer limited to OPEN TABS. cdp-salvage remembers the run's
# conversation URL once it proves which conversation is ours, and re-renders that URL when no tab
# carries the marker — so a Chrome restart (the common ending on a memory-pressured box) stops
# turning a finished, server-side review into "conversation gone".
if [ -n "$HARVEST_MARKER" ]; then
  HARVEST=1
  RUN_MARKER="$HARVEST_MARKER"
  if ! pg_reservation_marker_ok "$RUN_MARKER"; then
    echo "ERROR: invalid --harvest marker (expected pg-run-... safe filename syntax)." >&2
    pg_status failed "invalid harvest marker"
    pg_finish 2
  fi
  # KTD3: name the model the original in-progress run persisted into the reservation record. The
  # harvest runs in a separate process with no $RUNLOG to grep, so it reads the model straight
  # back; a legacy/empty record leaves RESOLVED_MODEL empty -> role-based fallback. Derive the R6
  # warning HERE too (dogfood PR #20 P2): the harvest branch pg_finishes before the fresh-path
  # warning block, so without this a harvested weak/unconfirmable model would lose its marker. No
  # selection status is available in this process, so an empty model here warns "cannot confirm".
  RESOLVED_MODEL="$(pg_reservation_read_model "$RUN_MARKER" 2>/dev/null || true)"
  MODEL_WARN="$(pg_derive_model_warn "$RESOLVED_MODEL" "")"
  [ -n "$MODEL_WARN" ] && echo "[oracle-review] WARNING: ${MODEL_WARN}." >&2
  if [ "$MODE" != remote-chrome ]; then
    echo "ERROR: --harvest requires remote-chrome/CDP mode; native browser mode exposes no marker-addressable CDP tab." >&2
    pg_status failed "harvest unsupported in native browser mode"
    pg_finish 3
  fi
  # ledger/status pr field from the marker's "pg-run-<key>-<epoch>-<pid>" shape (best-effort;
  # the key may itself contain dashes, so strip the two trailing numeric segments instead)
  PR_NUM="${HARVEST_MARKER#pg-run-}"
  PR_NUM="${PR_NUM%-*-*}"
  # v0.27: record the stripped key as round_key in this harvest's ledger line too (best-effort,
  # same heuristic as HARVEST_KEY below) so --status can join harvest rows to their change.
  ROUND_KEY="$PR_NUM"
  command -v node >/dev/null 2>&1 || { echo "ERROR: --harvest needs node for CDP salvage" >&2; pg_status failed "node missing"; pg_finish 3; }
  # Serialize the entire marker harvest. Without this, two collectors can share $OUT.cdp,
  # both read the same completed tab, and one closes it underneath the other (exit 6 + false
  # reservation removal). Linux uses flock; macOS/no-flock uses the existing pg_lock mkdir path.
  HARVEST_LOCK="${PRO_GATE_HARVEST_LOCK_DIR:-$PRO_GATE_HOME/harvest-locks}/${RUN_MARKER}"
  mkdir -p "$(dirname "$HARVEST_LOCK")" 2>/dev/null || { pg_status failed "harvest lock dir unavailable"; pg_finish 3; }
  if ! pg_lock "$HARVEST_LOCK" "${PRO_GATE_HARVEST_LOCK_WAIT:-5}"; then
    echo "ERROR: another harvest is already collecting marker ${RUN_MARKER}; not racing it." >&2
    pg_status failed "harvest already running"
    pg_finish 7
  fi
  # A harvest spends NO Pro slot and only reads over CDP, so the box-fitness parts of
  # pg_health_gate (memory, service uptime) don't apply: memory pressure is likeliest exactly
  # when a long review forced the harvest. Only the account cooldown defers it: salvage renders
  # against a throttled/challenged account deepen the block.
  if GATE_REASON="$(pg_cooldown_active)"; then
    echo "[oracle-review] harvest deferred: ${GATE_REASON}." >&2
    pg_status deferred "$GATE_REASON"
    pg_finish 8
  fi
  HARVEST_SECS="$(pg_dur_secs "$TIMEOUT")"
  echo "[oracle-review] harvesting in-progress review (marker ${RUN_MARKER}, up to ${HARVEST_SECS}s, no new slot spent)..." >&2
  pg_status salvaging "harvest up to ${HARVEST_SECS}s"
  HARVEST_RC=0
  HARVEST_TMP="$OUT.cdp.$$"
  node "$SELF/cdp-salvage.mjs" "$RUN_MARKER" "$HARVEST_SECS" "$PORT" > "$HARVEST_TMP" || HARVEST_RC=$?
  if [ "$HARVEST_RC" -eq 0 ] && pg_is_review "$HARVEST_TMP"; then
    # v0.28 (#48): provenance before acceptance. The run's manifest (written when the exit-9
    # run reserved) carries the change's file list; a complete review citing NONE of those
    # files is a foreign conversation's answer, not ours. Legacy reservations have no manifest
    # and skip the check (pg_review_matches_change accepts on a missing manifest). Rejection
    # preserves the reservation and counts no miss — and invalidates the memoized candidate
    # (blacklist + memo removal) so the NEXT pass rescans instead of replaying the same
    # foreign conversation forever.
    if ! pg_review_matches_change "$HARVEST_TMP" "$(pg_manifest_dir)/${RUN_MARKER}"; then
      mv "$HARVEST_TMP" "$OUT.foreign.$$" 2>/dev/null || rm -f "$HARVEST_TMP"
      pg_provenance_reject "$RUN_MARKER"
      echo "ERROR: harvested a complete review that cites NONE of this change's files — foreign conversation suspected. Reservation kept, its memoized candidate invalidated; retry --harvest (the real review may still be generating). The rejected capture is at $OUT.foreign.$$ for inspection." >&2
      pg_status in-progress "harvested review failed provenance (cites no change files); reservation kept"
      pg_finish 9
    fi
    mv "$HARVEST_TMP" "$OUT"
    pg_reservation_remove "$RUN_MARKER" || true
    # v0.22: a harvest completes the round the exit-9 run already recorded, so refresh the
    # round budget's last-severity sidecar too. The marker embeds ROUND_KEY
    # ("pg-run-<key>-<epoch>-<pid>") for PR and --diff runs alike; legacy markers resolve to
    # keys with no recorded rounds and are skipped inside the helper (best-effort, advisory).
    HARVEST_KEY="${RUN_MARKER#pg-run-}"; HARVEST_KEY="${HARVEST_KEY%-*-*}"
    pg_round_note_severity "$HARVEST_KEY" "$OUT"
    SALVAGED=1
    echo "[oracle-review] harvest recovered the completed review ($(wc -c < "$OUT" 2>/dev/null) bytes)." >&2
    pg_status done
    cat "$OUT"
    echo "RESULT_FILE=$OUT"
    pg_finish 0
  fi
  rm -f "$HARVEST_TMP"
  case "$HARVEST_RC" in
    3) pg_reservation_write "$RUN_MARKER" "" "$OUT" || true
       echo "[oracle-review] still generating: tab left open; run --harvest again later." >&2
       pg_status in-progress "still generating; retry --harvest later"
       pg_finish 9 ;;
    5) echo "[oracle-review] ChatGPT throttle hit during harvest: cooldown written; retry --harvest after it expires." >&2
       THROTTLED=1
       pg_status deferred "throttle during harvest; retry after cooldown"
       pg_finish 8 ;;
    7) # v0.25: INCONCLUSIVE — either the salvage never got one successful CDP tab list (browser
       # down or restarting, the very condition that loses tabs in the first place), or the
       # remembered conversation would not render decisively. Absence of evidence, so it must NOT
       # advance the miss counter toward "conversation gone": keep the reservation untouched and
       # let the caller retry. The reservation TTL bounds how long an undecidable marker can hold
       # capacity.
       if [ -f "$(pg_reservation_dir)/$RUN_MARKER" ]; then
         echo "[oracle-review] harvest inconclusive (browser unreachable, or the conversation would not render decisively). Reservation kept, NO miss counted. Retry --harvest once the browser is healthy." >&2
         pg_status in-progress "harvest inconclusive; retry later"
         pg_finish 9
       fi
       # No reservation is held (already collected, or released/expired while the URL memo was
       # deliberately kept for later human recovery). Do NOT promise an in-progress review that
       # will never complete — but do NOT claim the conversation is gone either: rc=7 is still
       # absence of evidence, and exit 6 both invites a fresh Pro spend and permits tab cleanup
       # (gate P1). Exit 3 says exactly what is true: engine/browser trouble, nothing destroyed,
       # retry when healthy. pg_finish skips tab cleanup on 3.
       echo "ERROR: harvest inconclusive for ${RUN_MARKER} and no reservation is held (already collected, or released earlier). Nothing was destroyed; retry once the browser is healthy, or open the conversation in ChatGPT." >&2
       pg_status failed "harvest inconclusive; no reservation held; retry when healthy"
       pg_finish 3 ;;
    4) # Confirmed absent THIS probe, which is not yet proof of loss (suspended renderer,
       # hydration): apply the shared consecutive-miss policy instead of destroying the
       # reservation on one observation (dogfood review P1).
       MISS_VERDICT="$(pg_reservation_note_miss "$RUN_MARKER")"
       if [ "$MISS_VERDICT" = released ]; then
         # v0.28 (#52 item 2): "released" conflates two very different states — a genuine
         # miss-limit loss, and a reservation ALREADY ABSENT because another pass collected
         # this review (its collection removed the reservation and ledgered a clean row).
         # Declaring the second one lost invited a duplicate Pro spend; return the collected
         # review idempotently instead, spending nothing. The LEDGERED SOURCE is the only
         # acceptable proof: validate it, copy through a temp file, and atomically replace a
         # CLEARED $OUT — pre-existing $OUT content (a stale review from an earlier reuse of
         # the path) must never pass as evidence of collection (gate #54 P1).
         PRIOR_OUT="$(pg_ledger_lookup_clean "$RUN_MARKER")"
         COLLECT_OK=0
         if [ -n "$PRIOR_OUT" ] && [ -s "$PRIOR_OUT" ] && pg_is_review "$PRIOR_OUT" 2>/dev/null; then
           if [ "$PRIOR_OUT" = "$OUT" ]; then
             COLLECT_OK=1
           elif rm -f "$OUT" 2>/dev/null && cp "$PRIOR_OUT" "$OUT.already.$$" 2>/dev/null \
                && mv -f "$OUT.already.$$" "$OUT" 2>/dev/null; then
             COLLECT_OK=1
           fi
         fi
         if [ "$COLLECT_OK" = 1 ]; then
           SALVAGED=1
           echo "[oracle-review] this review was ALREADY collected (ledger: $PRIOR_OUT); returning it idempotently — nothing spent, nothing lost." >&2
           pg_status done "already collected; returned from $PRIOR_OUT"
           cat "$OUT"
           echo "RESULT_FILE=$OUT"
           pg_finish 0
         fi
         if [ -n "$PRIOR_OUT" ]; then
           echo "ERROR: this review was already collected (ledger row exists) but its output file is gone or unreadable ($PRIOR_OUT). Not a loss — find the review in the PR comment/audit trail or the ChatGPT conversation; do NOT spend a fresh slot for it." >&2
           pg_status failed "already collected; prior output missing ($PRIOR_OUT)"
           pg_finish 6
         fi
         echo "ERROR: no conversation matches marker ${RUN_MARKER} after repeated confirmed misses, and no collected copy is ledgered (review lost, or collected by an engine <v0.27 that ledgered no marker)." >&2
         pg_status failed "harvest found no matching conversation (miss limit reached)"
         pg_finish 6
       fi
       echo "[oracle-review] conversation not found this pass (${MISS_VERDICT}); reservation kept fail-closed. Retry --harvest later." >&2
       pg_status in-progress "harvest miss (${MISS_VERDICT}); retry --harvest later"
       pg_finish 9 ;;
    *) # Runtime trouble (node crash, CDP outage, usage error) or a capture that failed
       # validation: NOT evidence the conversation is gone. Keep the reservation and the tab;
       # exit 3 = engine/browser trouble, safe to retry.
       echo "ERROR: harvest failed (salvage rc=${HARVEST_RC}); reservation and tab kept. Retry --harvest once the browser/CDP is healthy." >&2
       pg_status failed "harvest runtime error rc=${HARVEST_RC}; reservation kept"
       pg_finish 3 ;;
  esac
fi

# --- resolve repo + PR, assemble the diff (ground truth) ---
PR_URL=""; PR_NUM=""
if [ -n "$PR" ]; then
  if [[ "$PR" =~ ^https?:// ]]; then
    PR_URL="$PR"; PR_NUM="${PR##*/}"
    if [ -z "$REPO" ]; then
      NAME="$(printf '%s' "$PR_URL" | sed -E 's#https?://github.com/[^/]+/([^/]+)/pull/.*#\1#')"
      for base in "${PRO_GATE_REPOS_DIR:-$HOME/SITES}" "$HOME/src" "$HOME/code" "$HOME/dev"; do
        [ -d "$base/$NAME/.git" ] && { REPO="$base/$NAME"; break; }
      done
    fi
  else
    PR_NUM="$PR"
  fi
fi
[ -n "$REPO" ] || REPO="$(pwd)"
cd "$REPO" || { echo "ERROR: repo dir not found: $REPO" >&2; pg_status failed "repo dir not found"; pg_finish 4; }
[ -n "$PR_URL" ] || PR_URL="$(gh pr view "$PR_NUM" --json url -q .url 2>/dev/null || echo "")"

# PR_KEY: repo-scoped identity for locks, reservations, and markers. PR numbers repeat across
# repositories; keying on the bare number let an in-progress repo-A#77 redirect a repo-B#77 gate
# to repo A's conversation (dogfood review P1, 2026-07-10). Derived from the PR URL when known,
# else from the git remote, else the checkout name; sanitized to the marker-safe charset.
REPO_SLUG=""
if [ -n "$PR_URL" ]; then
  REPO_SLUG="$(printf '%s' "$PR_URL" | sed -nE 's#https?://[^/]+/([^/]+)/([^/]+)/pull/.*#\1-\2#p')"
fi
[ -n "$REPO_SLUG" ] || REPO_SLUG="$(git -C "$REPO" remote get-url origin 2>/dev/null \
  | sed -nE 's#.*[:/]([^/]+)/([^/]+?)(\.git)?$#\1-\2#p')"
[ -n "$REPO_SLUG" ] || REPO_SLUG="$(basename "$REPO")"
PR_KEY=""
[ -n "$PR_NUM" ] && PR_KEY="$(printf '%s-%s' "$REPO_SLUG" "$PR_NUM" | tr -c 'A-Za-z0-9.\n-' '-')"

# ROUND_KEY (v0.22): identity for the review round budget. PR runs use PR_KEY. --diff runs loop
# just as hard (ledger: 11 diff re-gates of one worktree in a day) but have no PR number, so
# they key on repo+branch: the unit a review->fix->re-review loop actually iterates on.
if [ -n "$PR_KEY" ]; then
  ROUND_KEY="$PR_KEY"
else
  ROUND_BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  # A detached checkout reports the literal ref name "HEAD" (typical for CI checkouts of a
  # bare SHA): one shared per-repo bucket would cross-cap unrelated diffs, so key those
  # per-commit instead. That under-caps a detached loop that rewrites its SHA every round,
  # but false-capping strangers is the worse failure for a default-on guard.
  if [ -z "$ROUND_BRANCH" ] || [ "$ROUND_BRANCH" = HEAD ]; then
    ROUND_BRANCH="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo detached)"
  fi
  # Disambiguate with a checksum of the RAW identity: sanitization is lossy ("feature/foo"
  # and "feature-foo" both sanitize to "feature-foo"), and colliding keys would share one
  # branch's budget and lock across unrelated branches (dogfood gate P1). The checksum input
  # must be UNSANITIZED end to end: the remote URL (or absolute checkout path) plus the raw
  # branch, never REPO_SLUG, whose owner/repo separator is itself already flattened
  # (a-b/c and a/b-c share a slug; dogfood gate round-2 P1). The human-readable prefix is
  # bounded so a deeply nested ref can never push the key past NAME_MAX, where state writes
  # fail and pg_lock silently proceeds unlocked.
  ROUND_RAW="$(git -C "$REPO" remote get-url origin 2>/dev/null || printf '%s' "$REPO"):${ROUND_BRANCH}"
  ROUND_SUM="$(printf '%s' "$ROUND_RAW" | cksum 2>/dev/null | awk '{print $1}')"
  ROUND_KEY="$(printf '%.120s%s-diff' "${REPO_SLUG}-${ROUND_BRANCH}" "${ROUND_SUM:+-$ROUND_SUM}" | tr -c 'A-Za-z0-9.\n-' '-')"
fi

if [ -z "$DIFF_FILE" ]; then
  DIFF_FILE="$WORK/pr.diff"
  gh pr diff "$PR_NUM" --patch > "$DIFF_FILE" 2>"$WORK/diff.err" || {
    echo "ERROR: gh pr diff $PR_NUM failed in $REPO: $(cat "$WORK/diff.err")" >&2; pg_status failed "gh pr diff failed"; pg_finish 5; }
fi

# --- diff hygiene: drop lockfiles/generated/vendored from the review payload so the Pro model
# spends its (finite, disconnect-exposed) thinking window on real code, not lockfile churn. ---
if [ -s "$DIFF_FILE" ] && [ "${PRO_GATE_DIFF_FILTER:-1}" = 1 ]; then
  FILTERED="$WORK/pr.filtered.diff"
  if pg_filter_diff "$DIFF_FILE" "$FILTERED" 2>"$WORK/excluded.raw" && [ -s "$FILTERED" ]; then
    # a path can appear in several per-commit patches (gh pr diff --patch) — dedupe for the report
    sort -u "$WORK/excluded.raw" 2>/dev/null > "$WORK/excluded.txt" || cp "$WORK/excluded.raw" "$WORK/excluded.txt"
    # grep -c prints "0" AND exits 1 on an empty file, so `|| echo 0` produced "0\n0"
    # (the "[: 0\n0: integer expression expected" noise on every run). Default only when empty.
    NEX="$(grep -c . "$WORK/excluded.txt" 2>/dev/null)"; [ -n "$NEX" ] || NEX=0
    if [ "$NEX" -gt 0 ] 2>/dev/null; then
      echo "[oracle-review] diff hygiene: excluded ${NEX} noise file(s) from the payload: $(paste -sd', ' "$WORK/excluded.txt" 2>/dev/null | cut -c1-200)" >&2
      DIFF_FILE="$FILTERED"
    fi
  fi
fi

DIFF_LINES=$(wc -l < "$DIFF_FILE" 2>/dev/null || echo 0)
# v0.28 (#48): the change's file manifest, used to provenance-check any salvaged/reattached
# capture before accepting it as this change's review (and persisted beside an exit-9
# reservation so a later --harvest can run the same check).
pg_diff_paths "$DIFF_FILE" > "$WORK/diff.paths" 2>/dev/null || true
echo "[oracle-review] os=$OS mode=$MODE repo=$REPO pr=#${PR_NUM} url=${PR_URL:-n/a} diff_lines=$DIFF_LINES input=$INPUT" >&2

# --- v0.20/v0.24: diff-size handling. The deep think IS the product of this gate, and the engine
# already has a harvest path (exit 9 -> --harvest) that collects a review outlasting the slot
# window for FREE. So a large diff no longer refuses: past PRO_GATE_MAX_DIFF_LINES (the "cook"
# threshold, default 6000) the run proceeds and is EXPECTED to exit 9 (in-progress), then be
# harvested. Only past the hard ceiling PRO_GATE_DIFF_HARD_MAX (default 25000) does the engine
# still refuse up front (exit 11, BEFORE any lock/slot, no spend): a payload that large risks
# context overflow and is almost always a generated blob the diff filter missed. PRO_GATE_DIFF_GUARD=0
# disables even the hard ceiling (cook any size). Ledger origin: 984-1402-line diffs complete in
# 12-21 min; a ~10k-line diff reasoned 65 min (2026-07-09) then had to be harvested — which is
# exactly the path this now takes by default instead of refusing.
DIFF_WARN_LINES="${PRO_GATE_DIFF_WARN_LINES:-2500}"
DIFF_COOK_LINES="${PRO_GATE_MAX_DIFF_LINES:-6000}"
DIFF_HARD_MAX="${PRO_GATE_DIFF_HARD_MAX:-25000}"
# A nonnumeric override must not silently disable the size checks: with stderr suppressed, a bad
# value used to propagate through the reconciliation below and let ANY diff through. Validate every
# operand as a nonnegative integer, restoring each invalid threshold to its own documented default.
case "$DIFF_WARN_LINES" in ''|*[!0-9]*) DIFF_WARN_LINES=2500 ;; esac
case "$DIFF_COOK_LINES" in ''|*[!0-9]*) DIFF_COOK_LINES=6000 ;; esac
case "$DIFF_HARD_MAX"   in ''|*[!0-9]*) DIFF_HARD_MAX=25000 ;; esac
case "$DIFF_LINES"      in ''|*[!0-9]*) DIFF_LINES=0 ;; esac
# The hard ceiling can never sit below the cook threshold: raising PRO_GATE_MAX_DIFF_LINES past
# the ceiling floats the ceiling up with it (so that knob still means "refuse above N" when set
# high), and setting PRO_GATE_DIFF_HARD_MAX <= the cook threshold collapses the cook band, which
# restores the pre-v0.24 hard-refuse-at-N behavior for anyone who wants it.
[ "$DIFF_HARD_MAX" -ge "$DIFF_COOK_LINES" ] || DIFF_HARD_MAX="$DIFF_COOK_LINES"
# Cooking a large diff only pays off where the harvest path can collect a run that outlasts the
# slot window. Native browser mode (macOS) has NO marker-addressable harvest and creates no
# reservation, so a cooked large diff there spends a slot it can never collect (exit 6, quota
# wasted). Keep the hard refusal at the cook threshold when harvest is unavailable: no cook band on
# native. (An explicit PRO_GATE_DIFF_GUARD=0 still overrides everything, native included.)
[ "$MODE" = remote-chrome ] || DIFF_HARD_MAX="$DIFF_COOK_LINES"
if [ "$DIFF_LINES" -gt "$DIFF_HARD_MAX" ] && [ "${PRO_GATE_DIFF_GUARD:-1}" = 1 ]; then
  if [ "$MODE" = remote-chrome ]; then
    echo "ERROR: diff is ${DIFF_LINES} lines (> PRO_GATE_DIFF_HARD_MAX=${DIFF_HARD_MAX}): beyond the size the Pro model can review even via the harvest path; not spending a slot." >&2
  else
    echo "ERROR: diff is ${DIFF_LINES} lines (> ${DIFF_HARD_MAX}): native browser mode has no harvest path, so a diff over the cook threshold cannot be collected if it outruns the review window; not spending a slot." >&2
  fi
  echo "  Scope the gate to what actually needs the final tier, then re-run with the patch:" >&2
  echo "    git -C <repo> diff <last-gated-sha>..<head> -- ':!*.lock' > delta.patch" >&2
  echo "    oracle-review.sh --diff delta.patch --repo <repo> --extra-files '<context globs>' --out <out>" >&2
  echo "  (Or split the PR; or raise PRO_GATE_DIFF_HARD_MAX / set PRO_GATE_DIFF_GUARD=0 to override.)" >&2
  pg_status oversized "diff ${DIFF_LINES} lines > hard max ${DIFF_HARD_MAX}; scope with --diff"
  pg_finish 11
elif [ "$DIFF_LINES" -gt "$DIFF_COOK_LINES" ]; then
  echo "[oracle-review] NOTE: diff is ${DIFF_LINES} lines (> PRO_GATE_MAX_DIFF_LINES=${DIFF_COOK_LINES}): a payload this size usually reasons past the slot window. Proceeding — the deep review is the point; expect exit 9 (in-progress) and collect it with --harvest (no new slot spent). To narrow instead, scope with --diff to the unreviewed delta." >&2
elif [ "$DIFF_LINES" -gt "$DIFF_WARN_LINES" ]; then
  echo "[oracle-review] WARNING: diff is ${DIFF_LINES} lines (> ${DIFF_WARN_LINES}); large diffs risk exceeding the Pro review window: consider scoping with --diff to the unreviewed delta." >&2
fi

ORACLE_BIN="${PRO_GATE_ORACLE_BIN:-oracle}"
TIMEOUT_BIN="${PRO_GATE_TIMEOUT_BIN:-timeout}"
if [[ "$TIMEOUT_BIN" == */* ]]; then
  [ -x "$TIMEOUT_BIN" ] || { echo "ERROR: configured timeout executable not found: $TIMEOUT_BIN" >&2; pg_status failed "timeout missing"; pg_finish 3; }
else
  pg_have "$TIMEOUT_BIN" || { echo "ERROR: coreutils timeout not installed" >&2; pg_status failed "timeout missing"; pg_finish 3; }
fi
if [[ "$ORACLE_BIN" == */* ]]; then
  [ -x "$ORACLE_BIN" ] || { echo "ERROR: configured oracle executable not found: $ORACLE_BIN" >&2; pg_status failed "oracle missing"; pg_finish 3; }
else
  pg_have "$ORACLE_BIN" || { echo "ERROR: oracle not installed (pnpm add -g @steipete/oracle)" >&2; pg_status failed "oracle missing"; pg_finish 3; }
fi

# --- build the review prompt (the product) ---
# RUN_MARKER (v0.15, pro-gate PR#5 review P1): a per-attempt correlation id
# embedded in the prompt, so the CDP probe/salvage match THIS run's
# conversation tab and never a leftover tab from an earlier review of the
# same PR (which would suppress the retry and serve a stale review for a
# new head). The marker lands in the user message, hence in the tab's
# innerText, without asking the model to echo anything.
# v0.22 (dogfood gate P1): embed ROUND_KEY, not PR_KEY. It is identical for PR runs, but it
# gives --diff runs a real per-change identity instead of the shared literal "diff", so their
# exit-9 reservations can redirect same-branch re-runs to harvest like PR runs always could.
RUN_MARKER="pg-run-${ROUND_KEY:-diff}-$(date +%s)-$$"
PROMPT_FILE="$WORK/prompt.md"
{
  # Lead with the @GitHub connector tag + an explicit directive (belt-and-suspenders: oracle
  # pastes the prompt in one shot, so @GitHub is a recognized hint, not a bound mention pill;
  # ORACLE_CHATGPT_URL can pin a connector-bound Project for true binding).
  if [ "$INPUT" = "connector" ] || [ "$INPUT" = "both" ]; then
    [ -n "$PR_URL" ] && cat <<EOF
@GitHub — use the GitHub connector for anything GitHub-related in this review. Fetch this pull request and read its full diff plus the surrounding code, callers, tests, and history directly from GitHub via the connector (do not answer from memory): $PR_URL

EOF
  fi
  cat <<EOF
You are the FINAL, highest-tier code reviewer for a pull request that has ALREADY been through automated review tiers (Claude correctness/security/maintainability personas and a cloud bug+security scan) and their fixes have been applied. The cheap, obvious issues are already gone.

Your job is to find what those tiers MISSED — go deep:
- logic errors and incorrect assumptions; intent-vs-implementation mismatches
- subtle edge cases, off-by-one, null/empty/boundary handling
- race conditions, ordering, idempotency, partial-failure and retry behavior
- security holes (authz, injection, SSRF, secret handling, unsafe deserialization)
- data integrity (migrations, transactions, constraints, irreversible/lossy ops)
- broken invariants, resource leaks, error-swallowing, performance cliffs at scale

Be skeptical, specific, and concrete. Prefer a few HIGH-CONFIDENCE real defects over a long list of style nits.

Cite a concrete <file>:<line> for EVERY finding — if you cannot point to a specific changed line, do not raise it.
Do NOT flag: style/formatting/naming; anything CI, linters, or type-checkers already enforce; generated files or lockfiles; pre-existing issues unrelated to this change; or speculative/theoretical problems with no demonstrated impact path.
EOF
  if [ "$INPUT" = "bundle" ] || [ "$INPUT" = "both" ]; then
    cat <<EOF

The AUTHORITATIVE change is the attached unified diff "pr.diff" (ground truth — review EVERY changed hunk). Do not assume; if the diff contradicts what the connector shows, trust the diff for what changed.
EOF
  fi
  if [ -n "$CONFIRM_FILE" ]; then
    cat <<'EOF'

THIS IS A CONFIRMING PASS: this change was already reviewed once and fixes were applied. The previous review is attached as "prior-review.md". BEFORE anything else, verify EVERY P0 and P1 finding in that prior review against the CURRENT code and list each one as either RESOLVED (with the file:line of the fix) or STILL-PRESENT (report it again as a finding). Only then report genuinely NEW findings per the standard format. Do not re-litigate a prior finding whose fix is present but shaped differently than you would have chosen.
EOF
  fi
  cat <<'EOF'

OUTPUT FORMAT — output ONLY findings, nothing else, each exactly:

[Pn] <file>:<line> — <one-line issue>
  Why it's a real problem: <concise reasoning>
  Confidence: <high|medium|low>
  Suggested fix: <concrete change>

where Pn is one of: P0 (critical / blocker / data-loss / security), P1 (major bug), P2 (minor), P3 (nit).
Group by severity, P0 first. If a severity has no findings, write "Pn: none".
End with one final line:  VERDICT: SHIP | FIX-FIRST | NEEDS-DISCUSSION  — <=15 word reason.
EOF
  echo
  echo "(run marker: ${RUN_MARKER} — internal correlation id; ignore it and do not mention it)"
} > "$PROMPT_FILE"

# --- assemble --file attachments (bundle mode) ---
FILES=()
if [ "$INPUT" = "bundle" ] || [ "$INPUT" = "both" ]; then
  FILES+=("$DIFF_FILE")
  if [ -n "$EXTRA_GLOB" ]; then
    while IFS= read -r f; do [ -f "$f" ] && FILES+=("$f"); done < <(compgen -G "$EXTRA_GLOB" 2>/dev/null || true)
  fi
fi
# --confirm attaches the prior review REGARDLESS of input mode: the confirming instructions
# in the prompt reference it by the stable name "prior-review.md".
if [ -n "$CONFIRM_FILE" ]; then
  cp "$CONFIRM_FILE" "$WORK/prior-review.md" 2>/dev/null \
    && FILES+=("$WORK/prior-review.md") \
    || { echo "ERROR: could not stage --confirm file: $CONFIRM_FILE" >&2; pg_status failed "confirm file unreadable"; pg_finish 2; }
fi
FILE_ARGS=(); for f in "${FILES[@]:-}"; do [ -n "$f" ] && FILE_ARGS+=(--file "$f"); done

# Route through a connector-bound ChatGPT Project when configured (pre-binds GitHub).
URL_ARGS=()
if [ -n "${ORACLE_CHATGPT_URL:-}" ] && [ "${ORACLE_CHATGPT_URL}" != "https://chatgpt.com/" ]; then
  URL_ARGS+=(--chatgpt-url "$ORACLE_CHATGPT_URL")
fi

# Platform browser flags: WSL/Linux attaches to the Xvfb Chrome; macOS lets oracle drive Chrome.
ENGINE_ARGS=(-e browser)
[ "$MODE" = "remote-chrome" ] && ENGINE_ARGS+=(--remote-chrome "127.0.0.1:${PORT}")
# Keep oracle from auto-archiving the conversation. Its default (auto) archives a "successful"
# one-shot and navigates the tab off the conversation, which strips the RUN_MARKER from the
# open tabs and blinds BOTH the pre-retry liveness probe (-> false "dead submission" -> a
# double-spending retry) and the last-resort CDP salvage. We own the conversation lifecycle:
# leave the tab intact so probe/salvage can always find it, and close it ourselves once the
# review is confirmed (pg_close_run_tab in pg_finish). Override with PRO_GATE_BROWSER_ARCHIVE.
ENGINE_ARGS+=(--browser-archive "${PRO_GATE_BROWSER_ARCHIVE:-never}")

# --- Bound concurrent Pro review runs against the single ChatGPT account ---
# DEFAULT IS SERIALIZED (1). The 2026-07-03 throttle incident showed one account under
# 3 parallel runs (plus their salvage page-loads) trips ChatGPT's anti-scraping limiter
# ("temporarily limited access to your conversations"). PRO_GATE_MAX_CONCURRENCY is the
# CEILING; v0.19's ramp governor (pg_ramp_level) decides the EFFECTIVE slots — earned up
# one level per PRO_GATE_RAMP_STREAK clean runs, dropped to 1 on any throttle. Excess
# callers QUEUE on the semaphore. A SEPARATE per-PR guard ensures the SAME pr is never
# under two simultaneous reviews (that would double-spend a slot on one diff). NOTE:
# oracle itself caps concurrent browser tabs (default 3; since 0.16.0 configurable via the
# ORACLE_BROWSER_MAX_CONCURRENT_TABS env). A ceiling above oracle's cap just queues inside
# oracle unless that env raises the cap to match (the ChatGPT account throttle, not oracle's
# tab cap, is the real limiter, so raising it only helps a genuinely tolerant account).
LOCKFILE="${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}"
LOCK_WAIT="${PRO_GATE_LOCK_WAIT:-2400}"
MAX_CONC="${PRO_GATE_MAX_CONCURRENCY:-1}"
EFF_CONC="$(pg_ramp_level "$MAX_CONC")"

# Housekeeping: per-PR lock files are 0-byte and used to accumulate forever. Sweep ones
# untouched for >24h — any legitimate holder finishes within the ~35 min hard cap. Same for
# per-marker harvest locks (v0.20.2 dogfood left one stale for 10h; flock holders keep the
# file's inode alive, so deleting an unheld file is always safe).
find "$(dirname "$LOCKFILE")" -maxdepth 1 -name "$(basename "$LOCKFILE").pr-*" -mmin +1440 -delete 2>/dev/null || true
find "${PRO_GATE_HARVEST_LOCK_DIR:-$PRO_GATE_HOME/harvest-locks}" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null || true
find "$(pg_active_dir)" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null || true
find "$(pg_manifest_dir)" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null || true
# Round-budget state (v0.22): entries self-prune on write, but a key never gated again keeps
# its file (and its 0-byte .lock) forever. Sweep files untouched for longer than the rounds
# window (every entry inside is expired), floored at 24h so a short window never deletes a
# lock a live process might hold (same safety argument as the sweeps above).
ROUND_SWEEP_MIN=$(( $(pg_round_window_secs) / 60 ))
[ "$ROUND_SWEEP_MIN" -lt 1440 ] && ROUND_SWEEP_MIN=1440
find "$(pg_rounds_dir)" -maxdepth 1 -type f -mmin "+${ROUND_SWEEP_MIN}" -delete 2>/dev/null || true
# Sweep idle chatgpt.com ROOT tabs (leaked by killed pre-submission runs; the marker-based
# close can't see them, and each is a renderer eating the review box's memory headroom).
# Only when NO oracle CLI is <120s old: a younger one may still be pre-navigation on a root
# tab. Age check engine-side (CDP can't see processes). PRO_GATE_TAB_SWEEP=0 disables.
if [ "$MODE" = remote-chrome ] && [ "${PRO_GATE_TAB_SWEEP:-1}" = 1 ] && command -v node >/dev/null 2>&1; then
  YOUNGEST_ORACLE=999999
  while read -r ORACLE_AGE; do
    case "$ORACLE_AGE" in ''|*[!0-9]*) continue;; esac
    [ "$ORACLE_AGE" -lt "$YOUNGEST_ORACLE" ] && YOUNGEST_ORACLE="$ORACLE_AGE"
  done < <(pgrep -f 'bin/oracle-cli\.js' 2>/dev/null | xargs -r -I{} ps -o etimes= -p {} 2>/dev/null | tr -d ' ')
  if [ "$YOUNGEST_ORACLE" -ge 120 ]; then
    timeout 30 node "$SELF/cdp-salvage.mjs" --sweep-root - 25 "$PORT" 2>&1 | sed 's/^/[oracle-review] /' >&2 || true
  fi
fi

# Reconcile durable reservations from earlier exit-9 runs before dispatch. A same-change
# reservation redirects this invocation to HARVEST instead of spending a second slot. This is
# enforced in the engine (not merely caller docs), so a killed headless caller cannot double-
# spend on its next daemon cycle. v0.22 (dogfood gate P1): keyed by ROUND_KEY so --diff runs
# redirect too; before, their reservations carried the shared literal "diff" and a same-branch
# re-run could submit a duplicate while the first review was still generating. Native mode has
# no marker-addressable CDP, so no reservations are created there.
if [ "$MODE" = remote-chrome ]; then
  pg_reservation_reconcile "$SELF/cdp-salvage.mjs" "$PORT"
  RESERVED_MARKER="$(pg_reservation_find_pr "$ROUND_KEY" 2>/dev/null || true)"
  if [ -n "$RESERVED_MARKER" ]; then
    # Publish the RESERVED conversation's marker, not this invocation's fresh one: callers
    # harvest whatever the status JSON names (dogfood review P1: the fresh marker names a
    # conversation that does not exist).
    RUN_MARKER="$RESERVED_MARKER"
    echo "[oracle-review] ${ROUND_KEY} already has an in-progress Pro conversation (${RESERVED_MARKER}): harvesting it instead of submitting again." >&2
    pg_status in-progress "existing reservation ${RESERVED_MARKER}; harvest required"
    echo "  ${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh --harvest '${RESERVED_MARKER}' --out '${OUT}' --timeout 20m" >&2
    pg_finish 9
  fi
fi

# v0.22: review round budget. Refuse to spend ANOTHER Pro slot on a PR/branch that already
# used its rounds inside the rolling window (default 4 per 24h): unbounded review->fix->
# re-review loops burned 10-16 slots on single PRs (8h+ gates, queue starvation). Checked
# AFTER the reservation redirect above: an in-progress conversation harvests for FREE and must
# never be blocked by the budget. Exit 12, NO quota spent; escalate remaining findings to a
# human instead of re-running.
round_capped() {  # $1 = reason
  # Severity-aware stop note: the budget still refuses the run (severity labels are the
  # reviewer's own claims, exactly the signal observed to oscillate across rounds), but a cap
  # hit while the change's LAST completed review reported P0s is the one case a human may
  # want to grant PRO_GATE_FORCE_ROUND=1, so say it loudly instead of burying it.
  local sev="" last_p0="" last_p1="" note="" pfd inflight=0
  if sev="$(pg_round_last_severity "$ROUND_KEY")"; then
    last_p0="${sev%% *}"; last_p1="${sev##* }"
    note="; last completed review: ${last_p0} P0 / ${last_p1} P1 unconfirmed by a re-review"
  fi
  # Non-blocking probe: a same-change run holding the per-change lock right now means the
  # sidecar note above describes the round BEFORE the one in flight; its completion may
  # change the picture, so tell the human to re-read before granting a forced round (the
  # refusal itself stays correct either way: a recorded spend never un-spends). Skipped when
  # THIS process owns the lock (post-lock re-check site): flock on a second fd would report
  # our own lock as a foreign in-flight run.
  if [ "${CHANGE_LOCK_HELD:-0}" = 1 ]; then
    inflight=0
  elif pg_have flock; then
    if { exec {pfd}>>"${LOCKFILE}.pr-${ROUND_KEY}"; } 2>/dev/null; then
      flock -n "$pfd" 2>/dev/null || inflight=1
      eval "exec ${pfd}>&-" 2>/dev/null
    fi
  elif [ -d "${LOCKFILE}.pr-${ROUND_KEY}.d" ]; then
    inflight=1
  fi
  [ "$inflight" = 1 ] && [ -n "$note" ] && note="${note} (a same-change review is in flight NOW: re-check this note after it completes)"
  echo "ERROR: ${1}; not spending another Pro review slot on this change." >&2
  if [ "${last_p0:-0}" -gt 0 ] 2>/dev/null; then
    echo "  ATTENTION: OPEN P0. The most recent completed review reported ${last_p0} P0 finding(s) that no re-review has confirmed fixed. If the fixes have landed, this is the case PRO_GATE_FORCE_ROUND=1 exists for: surface it to a human now." >&2
    [ "$inflight" = 1 ] && echo "  (A same-change review is in flight right now; wait for it before deciding, its result may already settle these.)" >&2
  fi
  echo "  A gate that keeps cycling review->fix->re-review is not converging: escalate the remaining findings to a human instead." >&2
  echo "  Deliberate override for ONE run: PRO_GATE_FORCE_ROUND=1. Tunables: PRO_GATE_MAX_ROUNDS_PER_PR, PRO_GATE_ROUNDS_WINDOW; PRO_GATE_ROUND_GUARD=0 disables." >&2
  pg_status round-capped "${1}${note}"
  pg_finish 12
}
if ! ROUND_REASON="$(pg_round_guard "$ROUND_KEY")"; then
  round_capped "$ROUND_REASON"
fi

# Per-change guard (acquire BEFORE a slot, so same-change callers serialize without holding a
# scarce slot). Keyed by ROUND_KEY: the repo-scoped PR_KEY for PR runs (bare numbers collide
# across repositories; the lock filename is unchanged for them), repo+branch for --diff runs.
# v0.22: --diff runs serialize here too. Without this, concurrent same-branch diff gates raced
# the round-budget check-then-record window and overshot the cap (review P0: 5 concurrent
# diff runs all passed a cap of 1), and two parallel reviews of one branch are the same
# double-spend the per-PR lock exists to stop.
echo "[oracle-review] per-change guard for ${PR_NUM:+pr #}${PR_NUM:-this diff} (${ROUND_KEY}; serializes same-change reviews)..." >&2
pg_status waiting-pr-lock
if ! pg_lock "${LOCKFILE}.pr-${ROUND_KEY}" "$LOCK_WAIT"; then
  echo "ERROR: timed out after ${LOCK_WAIT}s — ${ROUND_KEY} is already under review elsewhere." >&2
  pg_status failed "per-change lock timeout"
  pg_finish 7
fi
CHANGE_LOCK_HELD=1   # round_capped's in-flight probe must not mistake our own lock for a peer
# The previous same-change process may have exited 9 while we waited and written a reservation
# just before releasing this flock. Re-check now that we own the per-change lock; otherwise
# this waiter would immediately submit a duplicate review.
RESERVED_MARKER="$(pg_reservation_find_pr "$ROUND_KEY" 2>/dev/null || true)"
if [ -n "$RESERVED_MARKER" ]; then
  RUN_MARKER="$RESERVED_MARKER"
  echo "[oracle-review] ${ROUND_KEY} became in-progress while waiting (${RESERVED_MARKER}): harvest required, not resubmitting." >&2
  pg_status in-progress "existing reservation ${RESERVED_MARKER}; harvest required"
  pg_finish 9
fi
# Round-budget re-check for ALL runs, now that we own the per-change lock: the same-change
# run(s) this waiter queued behind may have consumed the last round during the (up to 40 min)
# wait. Check-then-record is race-free from here on because the lock is held until exit.
if ! ROUND_REASON="$(pg_round_guard "$ROUND_KEY")"; then
  round_capped "$ROUND_REASON (spent while this run waited on the per-change lock)"
fi

echo "[oracle-review] acquiring a review slot (effective ${EFF_CONC} of ceiling ${MAX_CONC}; waits up to ${LOCK_WAIT}s if all busy)..." >&2
pg_status waiting-slot "effective ${EFF_CONC} / ceiling ${MAX_CONC}"
# v0.19.1 (pro-gate self-review P1): re-read the ramp level every wait slice — a run that
# queued at level 3 must NOT acquire slot 3 after a concurrent throttle dropped the level
# to 1 mid-wait. Short pg_lock_n slices keep the wait responsive to governor changes.
SLOT_DEADLINE=$(( $(date +%s) + LOCK_WAIT ))
SLOT_OK=0
SLOT_HELD=""
while :; do
  EFF_CONC="$(pg_ramp_level "$MAX_CONC")"
  # Durable reservations occupy real account capacity even though their wrapper process has
  # exited. Slot-tagged reservations EXCLUDE their exact slot from acquisition (shrinking the
  # scan range instead overbooked capacity when a lower-numbered slot freed: dogfood review
  # P1); legacy/out-of-range reservations shrink the range.
  if ! pg_reservation_guard_acquire; then sleep 3; continue; fi
  SLOT_PLAN="$(pg_reservation_slot_plan "$EFF_CONC")"
  SCAN_MAX="${SLOT_PLAN%%|*}"
  SCAN_EXCLUDE="${SLOT_PLAN#*|}"
  # Nonblocking while holding the short handoff guard: waiting here would prevent an active
  # run from writing its reservation before releasing its process slot (writer waits 10s).
  # One immediate scan gives an atomic plan+acquire decision; the outer loop releases the
  # guard and retries.
  if [ "${SCAN_MAX:-0}" -gt 0 ] 2>/dev/null && pg_lock_n "$LOCKFILE" "$SCAN_MAX" 0 "$SCAN_EXCLUDE"; then
    # Keep the acquired process slot, release only the short reservation handoff guard.
    SLOT_HELD="$PG_SLOT_ACQUIRED"
    pg_reservation_guard_release; SLOT_OK=1; break
  fi
  pg_reservation_guard_release
  if [ "$(date +%s)" -ge "$SLOT_DEADLINE" ]; then break; fi
  sleep 3
done
if [ "$SLOT_OK" != 1 ]; then
  echo "ERROR: timed out after ${LOCK_WAIT}s — all ${EFF_CONC} review slots are busy." >&2
  pg_status failed "slot timeout"
  pg_finish 7
fi

RUNLOG="$WORK/oracle.log"

# The oracle CLI's own --timeout has been observed NOT to fire while it waits on a ChatGPT
# tab that never starts thinking (a "dead submission" squatted a browser slot for 3.5h on
# 2026-07-02). The engine therefore enforces its own bounds:
#   hard cap   — coreutils timeout at TIMEOUT + PRO_GATE_TIMEOUT_GRACE (default +120s)
#   stall      — no oracle log output for PRO_GATE_STALL_SECS (default 600) and no findings
#   no-think   — still "no thinking status detected" after PRO_GATE_NOTHINK_SECS (default 600)
# A watchdog kill returns 124; the caller's salvage + guarded-retry path takes over. Dead
# submissions never consumed the Pro thinking window, so the retry is not a
# double-spend.
HARD_SECS=$(( $(pg_dur_secs "$TIMEOUT") + ${PRO_GATE_TIMEOUT_GRACE:-120} ))
STALL_SECS="${PRO_GATE_STALL_SECS:-600}"
NOTHINK_SECS="${PRO_GATE_NOTHINK_SECS:-600}"

run_oracle() {  # $1 = browser model strategy (select|current|ignore)
  local strategy="$1" job started size last_size last_change now last_line prc
  # v0.16 (#873 lesson): a watchdog-killed attempt leaves its session record
  # status "running", and oracle's duplicate-prompt guard then blocks the
  # engine's OWN retry of the same prompt/slug. Retries only happen after the
  # probe judged the submission truly dead (no conversation tab, quota not
  # spent), so forcing a fresh session on retry is exactly oracle's documented
  # escape hatch for this state.
  local force_args=()
  [ "${attempt:-0}" -gt 0 ] && force_args+=(--force)
  ( stdbuf -oL -eL "$TIMEOUT_BIN" --signal=TERM --kill-after=30 "$HARD_SECS" \
      "$ORACLE_BIN" "${ENGINE_ARGS[@]}" -m "$MODEL" \
      --browser-model-strategy "$strategy" ${force_args[0]:+"${force_args[@]}"} \
      --slug "pro gate review pr ${PR_NUM:-diff}" \
      "${URL_ARGS[@]}" "${FILE_ARGS[@]}" \
      -p "$(cat "$PROMPT_FILE")" \
      --no-notify --timeout "$TIMEOUT" \
      --write-output "$OUT" 2>&1 | tee -a "$RUNLOG" | stdbuf -oL sed 's/^/[oracle] /' >&2 ) &
  job=$!
  started=$SECONDS; last_size=-1; last_change=$SECONDS
  while kill -0 "$job" 2>/dev/null; do
    sleep 10
    [ -s "$OUT" ] && continue   # findings are landing — let the run finish undisturbed
    size=$(wc -c < "$RUNLOG" 2>/dev/null) || size=0
    if [ "$size" != "$last_size" ]; then last_size="$size"; last_change=$SECONDS; fi
    now=$SECONDS
    last_line="$(tail -n 1 "$RUNLOG" 2>/dev/null || true)"
    if [ $(( now - last_change )) -ge "$STALL_SECS" ]; then
      echo "[oracle-review] watchdog: oracle silent for ${STALL_SECS}s with no findings — killing this attempt (salvage/retry follows)." >&2
      pg_status watchdog-killed "stall ${STALL_SECS}s"
    elif [ $(( now - started )) -ge "$NOTHINK_SECS" ] && printf '%s' "$last_line" | grep -q "no thinking status detected"; then
      # v0.14: oracle's thinking detection can lag reality (ChatGPT UI drift,
      # first seen PR pushbot#863 2026-07-02: killed a run that was 11m into a
      # live Pro thought). Before declaring the submission dead, ask
      # Chrome whether a conversation tab matching this PR exists. If it does,
      # the run is LIVE: quota is already spent and a resubmit would
      # double-spend. Kill the blind CLI anyway (frees the browser slot) but
      # flag it so the caller skips reattach+retry and goes straight to the
      # outcome-based CDP salvage with the full remaining budget.
      # v0.18: probe exit 5 = ChatGPT throttle interstitial. The submission's
      # fate is UNKNOWN (it may have landed before the throttle), so treat it
      # like live: never resubmit, and let the post-cooldown salvage decide.
      prc=2
      if command -v node >/dev/null 2>&1; then
        node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 "$PORT" >/dev/null 2>>"$RUNLOG"; prc=$?
      fi
      if [ "$prc" -eq 0 ]; then
        echo "[oracle-review] watchdog: no-think after $(( now - started ))s BUT a conversation tab matches this PR — submission is LIVE, detection missed. Freeing the slot; CDP salvage will collect the review (retry suppressed: quota already spent)." >&2
        LIVE_CONVERSATION=1
        pg_status live-detected "no-think probe found the conversation"
      elif [ "$prc" -eq 5 ]; then
        echo "[oracle-review] watchdog: ChatGPT is rate-limiting this account — killing this attempt; retry suppressed, cooldown started (salvage after the pause)." >&2
        THROTTLED=1
        pg_status throttled "interstitial during no-think probe"
      else
        echo "[oracle-review] watchdog: ChatGPT never started thinking after $(( now - started ))s — dead submission; killing this attempt (salvage/retry follows)." >&2
        pg_status watchdog-killed "no-think ${NOTHINK_SECS}s"
      fi
    else
      continue
    fi
    pkill -TERM -P "$job" 2>/dev/null; kill -TERM "$job" 2>/dev/null
    sleep 5
    pkill -KILL -P "$job" 2>/dev/null; kill -KILL "$job" 2>/dev/null
    wait "$job" 2>/dev/null
    return 124
  done
  wait "$job"
}

# --- spend the slot: health-gate -> run -> salvage -> one guarded retry ---
# A precious Pro review slot is spent only when the box is fit; a dropped connection is first
# SALVAGED (the answer may have finished server-side), and only a truly-lost run is retried once.
# Exit 8 = deferred (no slot spent); exit 6 = ran but produced nothing after salvage + retry.
SLUG_BASE="pro-gate-review-pr-${PR_NUM:-diff}"
REATTACH_TIMEOUT="${PRO_GATE_REATTACH_TIMEOUT:-150}"
MAX_RETRIES="${PRO_GATE_MAX_RETRIES:-1}"
BACKOFF="${PRO_GATE_RETRY_BACKOFF:-20}"
LIVE_CONVERSATION=0
THROTTLED=0
CLOUDFLARE=0
attempt=0
while :; do
  if ! GATE_REASON="$(pg_health_gate)"; then
    # v0.18: exit 8 ("deferred, NO slot spent") is only true before the first attempt.
    # On a retry iteration a slot HAS been spent — abandoning to exit 8 here would skip
    # the salvage of a possibly-completed review. Stop retrying and salvage instead.
    if [ "$attempt" -eq 0 ]; then
      echo "ERROR: not spending a Pro review slot (${GATE_REASON})." >&2
      case "$GATE_REASON" in
        *memory*|*thrashing*|*swap*)
          echo "  Your machine is low on memory, so the Pro review browser can't run reliably right now. Nothing was spent. Close some apps / browser tabs / other AI tools to free memory, then retry." >&2 ;;
        *)
          echo "  Deferred (no slot spent). Retry once the box settles, or run on macOS (native Chrome)." >&2 ;;
      esac
      pg_status deferred "$GATE_REASON"
      pg_finish 8
    fi
    echo "[oracle-review] not retrying (${GATE_REASON}) — falling through to salvage." >&2
    # v0.18.1 (pro-gate self-review P1): when the gate failure IS the throttle cooldown,
    # take the throttle path — otherwise the final salvage would render conversations
    # against the still-throttled account immediately, bypassing the protective pause.
    case "$GATE_REASON" in *"throttle cooldown"*) THROTTLED=1 ;; esac
    break
  fi

  # v0.22: this invocation is now committed to spending a slot: record its round (once; the
  # guarded retry below is the same round, and pre-launch exits above never record).
  # v0.27: and publish the active-run record at the same moment, so --status can see a live
  # (or wrapper-dead-but-generating) run before any reservation or ledger row exists.
  [ "$attempt" -eq 0 ] && { pg_round_record "$ROUND_KEY"; pg_active_write; }

  # A non-blocking heads-up when memory is tight but not blocking (the gate is deliberately
  # conservative, so a swap-heavy box with moderate free RAM still runs). Warns low-memory users
  # BEFORE a long review that a mid-run browser restart is the likely failure mode. Advisory only.
  if [ "$attempt" -eq 0 ] && MEM_NOTE="$(pg_mem_pressure_note)"; then
    echo "[oracle-review] NOTE: ${MEM_NOTE}. Proceeding; if the review fails, this is the likely reason — free memory and retry." >&2
  fi

  echo "[oracle-review] launching the final-tier Pro review (attempt $((attempt + 1)), oracle timeout $TIMEOUT, hard cap ${HARD_SECS}s, stall/no-think watchdog ${STALL_SECS}s/${NOTHINK_SECS}s)..." >&2
  pg_status launching "strategy ${PRO_GATE_MODEL_STRATEGY:-current}"
  # v0.28 (#48, #45 residual): capture the conversation URL EARLY. One bounded background
  # probe shortly after submission writes the conversation-urls memo the moment the
  # marker-bearing tab is identifiable — before v0.28 the memo was learned only at the first
  # successful salvage/probe, so a whole-Chrome death mid-generation could still lose the only
  # pointer to a review that exists server-side. Open-tab scan only in the common case (the
  # run's own tab is open, so no page loads and no throttle exposure); non-fatal; bounded;
  # remote-chrome only. PRO_GATE_EARLY_PROBE_SECS sets the delay, 0 disables.
  EARLY_PROBE_DELAY="${PRO_GATE_EARLY_PROBE_SECS:-75}"
  case "$EARLY_PROBE_DELAY" in ''|*[!0-9]*) EARLY_PROBE_DELAY=75;; esac
  # Armed on EVERY attempt (gate #54 P1): a dead first attempt commonly outlives the probe
  # window, and a successful retry would otherwise generate with no early pointer at all.
  if [ "$MODE" = remote-chrome ] && [ "$EARLY_PROBE_DELAY" -gt 0 ] \
     && command -v node >/dev/null 2>&1; then
    # Close inherited descriptors FIRST: the subshell inherits every open fd, including the
    # per-change flock and the account-slot fd — without this, the sleeping probe holds the
    # lock AND a Pro slot for up to ~165s after the engine exits, blocking the next same-change
    # run (found the hard way: the whole test suite serialized behind it).
    ( i=3; while [ "$i" -le 40 ]; do eval "exec $i>&-" 2>/dev/null; i=$((i + 1)); done
      sleep "$EARLY_PROBE_DELAY"
      timeout 90 node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 60 "$PORT" ) >/dev/null 2>&1 &
  fi
  : > "$RUNLOG"; rm -f "$OUT"   # clear any prior attempt's output so stale garbage can't survive
  run_oracle "${PRO_GATE_MODEL_STRATEGY:-current}" || true
  # UI fallback: the requested model was not selectable in the picker (select strategy) -> retry
  # pinned to the account's already-selected model. oracle's wording varies ("model selector",
  # "model picker", "model switcher", "Unable to find model option matching ..."), so match them
  # all: without the switcher/option forms a `select` mismatch failed the WHOLE run instead of
  # falling back (dogfood 2026-07-17, PR #32: `select` + gpt-5.6 emitted "Unable to find model
  # option matching 'GPT-5.6 Sol' in the model switcher" and released the slot without submitting,
  # then the engine burned ~32 min on a pointless salvage). Skip when the primary run was already
  # `current` (a second current pass changes nothing).
  if [ ! -s "$OUT" ] && [ "${PRO_GATE_MODEL_STRATEGY:-current}" != current ] \
     && grep -qiE "model selector|model.?picker|model switcher|unable to find model option" "$RUNLOG" 2>/dev/null; then
    echo "[oracle-review] requested model not selectable in the picker; retrying with --browser-model-strategy current (reviews whichever model your ChatGPT account already has selected)..." >&2
    run_oracle current || true
  fi
  # Accept ONLY a real review, not just any non-empty file — a corrupted capture (e.g. a stray "A")
  # must NOT pass as success; it falls through to salvage + retry below.
  if pg_is_review "$OUT"; then
    echo "[oracle-review] findings written ($(wc -c < "$OUT" 2>/dev/null) bytes)." >&2; break
  fi
  if [ -s "$OUT" ]; then
    echo "[oracle-review] discarding a non-review capture ($(wc -c < "$OUT" 2>/dev/null) bytes, no VERDICT/Pn markers) — will salvage/retry." >&2
  fi

  # Cloudflare / ChatGPT anti-bot challenge: oracle detects the "Just a moment" interstitial and
  # logs "Cloudflare anti-bot page detected" / throws stage=cloudflare-challenge. The submission
  # did NOT land, so a retry only hammers the challenge and deepens the block (the headless,
  # concurrency-driven trigger that a warm interactive session never hits). Treat it like the
  # throttle: back off. Write the account cooldown the health gate already honors, drop the ramp
  # to 1 (concurrency is the real trigger), suppress the retry, and skip salvage (nothing landed).
  # Match oracle's own Cloudflare emissions ("Cloudflare anti-bot page detected" logger line and
  # the "Cloudflare challenge detected ..." thrown-error message / cloudflare-challenge stage).
  # Guarded by `! pg_is_review`, so a successful review that merely discusses Cloudflare (its text
  # also lands in the log) can never be misread as a block.
  if ! pg_is_review "$OUT" \
     && grep -qiE 'Cloudflare (anti-bot page|challenge) detected|cloudflare-challenge' "$RUNLOG" 2>/dev/null; then
    echo "[oracle-review] ChatGPT/Cloudflare anti-bot challenge detected; backing off (account cooldown + concurrency drop), NOT retrying (a resubmit only deepens the block)." >&2
    CLOUDFLARE=1
    # The challenge PROVES no prompt reached the model: refund this invocation's round so a
    # few challenge hits inside the window cannot exit-12-block a change that spent nothing
    # (dogfood gate round-2 P1). Unknown-fate paths (throttle, watchdogs) never refund.
    pg_round_unrecord "$ROUND_KEY"
    pg_status cloudflare "anti-bot challenge; cooldown started"
    cdf="${PRO_GATE_COOLDOWN_FILE:-$PRO_GATE_HOME/throttle.cooldown}"
    { printf '%s cloudflare-challenge (pr %s)\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "${PR_NUM:-diff}" > "$cdf"; } 2>/dev/null || true
    break
  fi

  # v0.14: a live conversation means the quota is already spent. Reattach is
  # useless here (it binds the pre-kill tab target, which goes stale) and a
  # resubmit would double-spend — skip both and let the outcome-based CDP
  # salvage below collect the review when it finishes.
  # v0.18: same for a throttle kill — the submission's fate is unknown, and
  # both reattach and a resubmit would hit the throttled account again.
  if [ "$LIVE_CONVERSATION" = 1 ] || [ "$THROTTLED" = 1 ]; then
    break
  fi

  # No output. The generation may have COMPLETED server-side after a dropped Chrome connection —
  # try a bounded salvage (never hangs) before spending another slot. Capture the slug oracle
  # actually used (it may differ from SLUG_BASE on a collision, e.g. ...-pr-804-2).
  SLUG="$(grep -oE 'oracle session [A-Za-z0-9._-]+' "$RUNLOG" 2>/dev/null | tail -1 | awk '{print $NF}')"
  [ -n "$SLUG" ] || SLUG="$SLUG_BASE"
  echo "[oracle-review] no output — bounded salvage via reattach (session ${SLUG}, ${REATTACH_TIMEOUT}s)..." >&2
  pg_status salvaging "reattach ${SLUG}"
  if pg_reattach_render "$SLUG" "$OUT" "$REATTACH_TIMEOUT"; then
    REATTACHED=1   # v0.28: browser-matched capture — subject to the provenance choke below
    echo "[oracle-review] salvaged a completed review via reattach." >&2
    SALVAGED=1
    break
  fi

  attempt=$((attempt + 1))
  [ "$attempt" -gt "$MAX_RETRIES" ] && break
  # v0.16.1 (self-review P1): the retry passes --force, which bypasses
  # oracle's duplicate-prompt guard — previously the LAST defense against
  # resubmitting a live-but-silent run. The no-think path probes before its
  # kill, but stall and hard-cap kills reach here unprobed. Probe RIGHT
  # BEFORE every retry: a conversation tab matching this run's marker means
  # the quota is spent, so suppress the retry and let the CDP salvage below
  # collect the review instead. (If Chrome itself is unreachable the probe
  # errors and the retry proceeds — a server-side-completed run cannot be
  # salvaged through a dead browser anyway.)
  PRC=2
  if command -v node >/dev/null 2>&1; then
    node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 "$PORT" >/dev/null 2>>"$RUNLOG"; PRC=$?
  fi
  if [ "$PRC" -eq 0 ]; then
    echo "[oracle-review] pre-retry probe found a live conversation for this run — retry suppressed (quota already spent); CDP salvage will collect it." >&2
    LIVE_CONVERSATION=1
    pg_status live-detected "pre-retry probe found the conversation"
    break
  elif [ "$PRC" -eq 5 ]; then
    echo "[oracle-review] pre-retry probe hit the ChatGPT throttle — retry suppressed; cooldown started (salvage after the pause)." >&2
    THROTTLED=1
    pg_status throttled "interstitial during pre-retry probe"
    break
  fi
  # FAIL CLOSED (self-review P1): a probe that neither found the conversation (0) nor throttle
  # (5) is INCONCLUSIVE, not proof of a dead submission: a transient CDP/render hiccup returns
  # the same non-0/5 code, and retrying a submission that actually LANDED double-spends the Pro
  # slot. Only a run that died BEFORE it submitted is safe to retry. Oracle logs "Acquired
  # ChatGPT browser slot" / "Session: ..." once the prompt is in flight; if that evidence is
  # present the quota is spent, so suppress the retry and let the full-budget CDP salvage below
  # collect it (now reliable: we run --browser-archive=never, so the tab is still findable).
  # RUNLOG holds oracle's RAW output (the "[oracle] " prefix is added only to the live display),
  # so match oracle's own strings. Bias toward "landed" (suppress the retry): a double-spend is
  # worse than a missed retry, which the caller re-runs.
  if grep -qE 'Launching browser mode|Acquired ChatGPT browser slot|Reattach: oracle session ' "$RUNLOG" 2>/dev/null; then
    echo "[oracle-review] pre-retry probe inconclusive, but oracle had already submitted (browser slot/session in the log); treating as spent, retry suppressed, falling through to CDP salvage." >&2
    LIVE_CONVERSATION=1
    pg_status live-detected "submission landed (log evidence); retry suppressed"
    break
  fi
  echo "[oracle-review] pre-retry probe found no conversation AND no evidence oracle ever submitted (genuine dead submission). Retrying once after ${BACKOFF}s + a health re-check..." >&2
  pg_status retry-wait "backoff ${BACKOFF}s"
  sleep "$BACKOFF"
done

# v0.21 (R4/R5): capture the model oracle resolved for THIS run from its "Model selection
# evidence: ...; resolved=<label>; status=<st>; ..." line in $RUNLOG, plus the selection status.
# BEST-EFFORT by design: dogfooding PR #20 showed oracle 0.15.2 emits this line at COMPLETION
# (right after it releases the browser slot), NOT early at model selection. So on the fresh
# in-progress/exit-9 path the watchdog kills oracle before the line is emitted and capture yields
# nothing (empty -> role-based fallback, and the reservation persists no model). On the fresh
# SUCCESS path the line is present; under `current` a model that was already selected reports
# resolved=(unavailable); status=already-selected (still healthy). resolved=(unavailable) or
# absence degrades to empty. Mirrors the $RUNLOG session-slug recovery grep above.
if [ -f "$RUNLOG" ]; then
  EVIDENCE_LINE="$(grep -a 'Model selection evidence:' "$RUNLOG" 2>/dev/null | tail -1)"
  if [ -n "$EVIDENCE_LINE" ] && [ "${EVIDENCE_LINE#*resolved=}" != "$EVIDENCE_LINE" ]; then
    RM="${EVIDENCE_LINE#*resolved=}"; RM="${RM%%;*}"; RM="${RM%.}"
    RM="$(printf '%s' "$RM" | tr -d '\t\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$RM" in ''|'(unavailable)') RESOLVED_MODEL="" ;; *) RESOLVED_MODEL="$RM" ;; esac
    if [ "${EVIDENCE_LINE#*status=}" != "$EVIDENCE_LINE" ]; then
      ST="${EVIDENCE_LINE#*status=}"; ST="${ST%%;*}"; ST="${ST%.}"
      MODEL_STATUS="$(printf '%s' "$ST" | tr -d '\t\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    fi
  fi
fi

# v0.21 (R6): soft, advisory downgrade warning (see pg_derive_model_warn). Fires on a weak-model
# denylist match or a genuinely unconfirmable model (killed before oracle reported, or none
# captured); it stays SILENT on the benign `current`+already-selected steady state so it does not
# cry wolf on healthy default runs. A WARN log line plus a status-file marker the composer shows;
# it NEVER changes the exit code.
MODEL_WARN="$(pg_derive_model_warn "$RESOLVED_MODEL" "$MODEL_STATUS")"
[ -n "$MODEL_WARN" ] && echo "[oracle-review] WARNING: ${MODEL_WARN}." >&2

# v0.13: last-resort CDP tab salvage. oracle (historically <=0.15.x; hardened upstream in
# 0.16.0) could fail to DETECT thinking after ChatGPT UI drift even though the submission landed: the
# no-think watchdog then kills a LIVE run, and reattach harvests a stale tab
# target ("Assistant turns: 0") while the real conversation finishes in
# another tab. Before declaring failure, read the review straight off the
# conversation tab's DOM, matched by PR marker so concurrent review slots
# cannot cross-contaminate. First seen: pushbot PR #863, 2026-07-02.
# Skip salvage entirely on a Cloudflare challenge: the submission never landed (nothing to
# collect), and rendering conversation pages against a challenged account only deepens the block.
if ! pg_is_review "$OUT" && [ "${CLOUDFLARE:-0}" != 1 ] && command -v node >/dev/null 2>&1; then
  # Live conversation (v0.14 probe hit): the review may still be thinking, so
  # wait with the full hard-cap budget; otherwise a short window suffices.
  SALVAGE_SECS="$STALL_SECS"; [ "$LIVE_CONVERSATION" = 1 ] && SALVAGE_SECS="$HARD_SECS"
  # v0.18: after a throttle hit, pause before the single polite salvage pass —
  # rendering the conversation immediately just re-triggers the limiter. The
  # salvage itself exits 5 fast if the account is still throttled.
  if [ "$THROTTLED" = 1 ]; then
    THROTTLE_PAUSE="${PRO_GATE_THROTTLE_PAUSE:-300}"
    echo "[oracle-review] throttled — pausing ${THROTTLE_PAUSE}s before one polite salvage attempt..." >&2
    pg_status throttled "pausing ${THROTTLE_PAUSE}s before salvage"
    sleep "$THROTTLE_PAUSE"
    SALVAGE_SECS="$HARD_SECS"
  fi
  echo "[oracle-review] last-resort CDP tab salvage (marker ${RUN_MARKER}, up to ${SALVAGE_SECS}s)..." >&2
  pg_status salvaging "cdp up to ${SALVAGE_SECS}s"
  SALVAGE_RC=0
  SALVAGE_RAN=1
  SALVAGE_TMP="$OUT.cdp.$$"
  node "$SELF/cdp-salvage.mjs" "$RUN_MARKER" "$SALVAGE_SECS" "$PORT" > "$SALVAGE_TMP" 2>>"$RUNLOG" || SALVAGE_RC=$?
  if [ "$SALVAGE_RC" -eq 0 ] && pg_is_review "$SALVAGE_TMP"; then
    mv "$SALVAGE_TMP" "$OUT"
    echo "[oracle-review] CDP salvage recovered a completed review." >&2
    SALVAGED=1
  else
    rm -f "$SALVAGE_TMP"
  fi
  # v0.25 (gate P1 x3): rc 4 is the ONLY salvage result that is evidence the review is absent —
  # "scanned the browser successfully and nothing carried this marker". Everything else is either
  # positive evidence the conversation exists or no evidence at all, so the default is to PRESERVE:
  #   3 still generating                        — the classic reserve-and-harvest case
  #   7 inconclusive                            — CDP down, or the remembered conversation
  #                                               would not render decisively
  #   5 ChatGPT throttle                        — literally means "do NOT resubmit"; the
  #                                               submission's fate is unknown
  #   0 but pg_is_review rejected the capture   — the conversation demonstrably EXISTS (the
  #                                               salvage read a VERDICT off it); only our
  #                                               stricter shape check failed, e.g. mid-render
  #   anything unexpected (helper crash, bug)   — proves nothing about the conversation
  # Preserving means persisting the reservation and exiting 9 (which also skips tab cleanup)
  # instead of falling through to exit 6, which both closes the conversation and leaves no
  # reservation to stop the next invocation spending a second Pro slot on a review that exists.
  case "$SALVAGE_RC" in
    4) : ;;
    0) [ "${SALVAGED:-0}" = 1 ] || SALVAGE_PRESERVE=1 ;;
    *) SALVAGE_PRESERVE=1 ;;
  esac
fi

# v0.28 (#48): provenance choke point for BROWSER-MATCHED captures — session reattach and CDP
# salvage. Those find "our" conversation by marker/URL heuristics and can bind the wrong one
# (seen live: a failed send salvaged a different PR's finished review, pushbot #1245). A
# structurally-complete capture citing none of this change's files is such a foreign answer:
# never return it as ours; route to the preserve path — the real review may still be
# generating, and preserving (reservation + exit 9) costs nothing while a foreign acceptance
# poisons the gate. Direct oracle output is EXEMPT: the process that submitted the prompt
# writes its own conversation's answer, and a legitimate review may cite a caller/context
# file outside the diff (the fixture suite does exactly that) — rejecting those would turn
# clean runs into phantom exit-9s.
if { [ "${SALVAGED:-0}" = 1 ] || [ "${REATTACHED:-0}" = 1 ]; } \
   && pg_is_review "$OUT" && ! pg_review_matches_change "$OUT" "$WORK/diff.paths"; then
  echo "[oracle-review] captured a complete review but it cites NONE of this change's files — foreign conversation suspected; NOT accepting it as ours. Preserving the run for --harvest. The rejected capture is at $OUT.foreign.$$." >&2
  mv "$OUT" "$OUT.foreign.$$" 2>/dev/null || rm -f "$OUT"
  # Invalidate the memoized candidate ONLY for CDP captures: the memo names the conversation
  # the salvage just read, so it identifies the rejected text's source. A REATTACH capture
  # carries no URL identity — its rejected text may be a stale oracle session while the memo
  # (possibly written by the early probe) points at the GENUINE current conversation;
  # blacklisting that would make the real review unrecoverable after a Chrome restart
  # (gate #54 r2 P1).
  [ "${SALVAGED:-0}" = 1 ] && pg_provenance_reject "$RUN_MARKER"
  SALVAGE_RAN=1; SALVAGE_PRESERVE=1   # route to the reserve-and-harvest branch below
fi
if pg_is_review "$OUT"; then
  # v0.22: remember this review's P0/P1 counts so a later round-capped refusal can flag an
  # unconfirmed open P0 to the human (advisory sidecar; see pg_round_note_severity).
  pg_round_note_severity "$ROUND_KEY" "$OUT"
  pg_status done
  cat "$OUT"
  echo "RESULT_FILE=$OUT"
  pg_finish 0
elif [ "${SALVAGE_RAN:-0}" = 1 ] && [ "${SALVAGE_PRESERVE:-0}" = 1 ]; then
  # The salvage budget ran out while the conversation was STILL GENERATING (or the outcome was
  # inconclusive / the capture failed validation — see the case above): the Pro slot is
  # spent and the answer may land any minute. Persist a durable reservation BEFORE this process
  # releases its flock slot, leave the tab open (pg_finish skips close for exit 9), and hand the
  # caller a no-respend collection path. Fresh runs reconcile/respect the reservation, so actual
  # account concurrency and same-PR serialization remain correct after this wrapper exits.
  # v0.28 (#48): persist the change's file manifest (its OWN directory — never inside
  # in-progress/, whose enumerators would misread it as a reservation) so a later --harvest
  # (a separate process with no diff) can provenance-check its capture. Written before the
  # reservation itself so a reader never sees a reservation without its manifest.
  if [ -s "$WORK/diff.paths" ]; then
    mkdir -p "$(pg_manifest_dir)" 2>/dev/null || true
    if ! cp "$WORK/diff.paths" "$(pg_manifest_dir)/${RUN_MARKER}" 2>/dev/null; then
      # Loud, not silent (gate #54 r2 P1): without the manifest a later harvest accepts any
      # structurally-valid capture as legacy — the operator should know provenance is off for
      # this run. Full fail-closed semantics (harvest refusing without provenance) is part of
      # the immutable completed-artifact design tracked in the follow-up issue.
      echo "[oracle-review] WARNING: could not persist the change manifest to $(pg_manifest_dir); a later --harvest of this run will accept its capture WITHOUT provenance checking." >&2
    fi
  fi
  if ! pg_reservation_write "$RUN_MARKER" "${ROUND_KEY:-diff}" "$OUT" "${SLOT_HELD:-}" "$RESOLVED_MODEL"; then
    # Fail closed: without the durable reservation, exit 9 would under-count a live Pro tab and
    # let the next invocation double-spend. Keep the process/locks alive rather than release
    # unreserved capacity; this should only happen on a broken/unwritable PRO_GATE_HOME.
    echo "ERROR: review still generating, but could not persist its capacity reservation; keeping the engine alive to preserve the slot." >&2
    pg_status salvaging "still generating; reservation write failed; slot held"
    while node "$SELF/cdp-salvage.mjs" --probe "$RUN_MARKER" 30 "$PORT" >/dev/null 2>&1; do sleep 60; done
    echo "ERROR: live conversation disappeared before it could be reserved; review lost." >&2
    pg_status failed "reservation write failed; conversation gone"
    pg_finish 6
  fi
  case "${SALVAGE_RC:-0}" in
    3) echo "ERROR: review still generating after the salvage budget: conversation LEFT OPEN and account capacity RESERVED." >&2 ;;
    7) echo "ERROR: the salvage could not determine this review's fate (browser unreachable, or the conversation would not render decisively). Treating it as LIVE and RESERVED rather than lost — the slot is spent and the review may well exist." >&2 ;;
    *) echo "ERROR: the salvage read this run's conversation but the capture failed validation (truncated or malformed). Conversation KEPT and account capacity RESERVED — re-collect rather than re-spend." >&2 ;;
  esac
  echo "  Collect it later WITHOUT spending another Pro slot:" >&2
  echo "    ${PRO_GATE_HOME:-\$HOME/.pro-review-daemon}/oracle-review.sh --harvest '${RUN_MARKER}' --out '${OUT}' --timeout 20m" >&2
  pg_status in-progress "slot spent, model still generating; harvest with --harvest"
  pg_finish 9
else
  RETRIES=$(( attempt > 0 ? attempt - 1 : 0 ))
  echo "ERROR: oracle produced no usable review after salvage + ${RETRIES} retr$([ "${RETRIES}" -eq 1 ] && echo y || echo ies) (reattach: oracle session ${SLUG_BASE})." >&2
  # Attribute the failure when the review browser restarted mid-run — almost always memory pressure
  # on a small box (Chrome's subprocesses get reclaimed, oracle-chrome restarts, the CDP tab is
  # lost). Say so plainly so a non-technical user knows what happened, that quota was likely already
  # spent, and that the review may still exist server-side (no need to immediately re-run).
  FAIL_DETAIL="no usable review after salvage"
  if _svc_up="$(pg_browser_restarted_midrun "$RUN_START")"; then
    _mem="$(pg_mem_status)"; [ -n "$_mem" ] || _mem="memory usage unknown"
    echo "  LIKELY CAUSE: the review browser (Chrome) restarted ${_svc_up}s ago — mid-review — almost always because the machine ran low on memory (${_mem})." >&2
    echo "  The slot was likely already spent and the review may still exist in ChatGPT, so do NOT immediately re-run. Free memory (close other apps / browser tabs) and try again." >&2
    FAIL_DETAIL="review browser restarted mid-run (chrome up ${_svc_up}s); likely out of memory"
  fi
  pg_status failed "$FAIL_DETAIL"
  pg_finish 6
fi
