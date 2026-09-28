#!/usr/bin/env bash
# Actual shell rejection, retirement and engine clean-scan seams under isolated I/O faults.
set -uo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-memo-shell.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT
export TMPDIR="$TDIR" PRO_GATE_HOME="$TDIR/home"
LIB="${PRO_GATE_TEST_LIB_SOURCE:-$HERE/../lib/pro-gate-lib.sh}"
ENGINE="${PRO_GATE_TEST_ENGINE_SOURCE:-$HERE/../bin/oracle-review.sh}"
. "$LIB"
FAILURES=0
check() {
  if [ "$2" -eq 0 ]; then printf 'ok - %s\n' "$1";
  else printf 'not ok - %s (%s)\n' "$1" "${3:-}" >&2; FAILURES=$((FAILURES + 1)); fi
}
MARKER=pg-run-memo-shell-1700000000-1
FOREIGN=https://chatgpt.com/c/foreign
GENUINE=https://chatgpt.com/c/genuine
NEWER=https://chatgpt.com/c/newer

seed() { # scenario legacy
  export PRO_GATE_HOME="$TDIR/$1"
  mkdir -p "$PRO_GATE_HOME/conversation-urls" "$PRO_GATE_HOME/review-input-bindings" "$PRO_GATE_HOME/legacy-review-receipts"
  MEMO="$PRO_GATE_HOME/conversation-urls/$MARKER"
  printf '%s\n' "$GENUINE" > "$MEMO"
  if [ "$2" = legacy ]; then
    jq -cnS --arg marker "$MARKER" --arg cd "$(pg_review_decision_contract_digest)" '
      {record_type:"review-input-binding/v1",record_version:1,contract_id:"review-decision/v1",contract_version:1,
       contract_digest:$cd,marker:$marker,charged_spend_epoch:1700000000,
       repository:{host:"github.com",owner:"acme",repo:"widgets"},
       target:{kind:"pull-request",pr:1,head_oid:("a"*40)},
       evidence:{identity:"legacy-fixture",mode:"full-pr",proof:{base_oid:("b"*40),head_oid:("a"*40),endpoint_digest:("c"*64),raw_patch_digest:("d"*64)}}}' \
      | tr -d '\n' > "$PRO_GATE_HOME/review-input-bindings/$MARKER"
    check 'legacy fixture passes the actual binding validator' "$(pg_review_input_binding_read "$MARKER" >/dev/null; echo $?)"
  fi
}
claims() { find "$PRO_GATE_HOME/conversation-urls" "$PRO_GATE_HOME/legacy-review-receipts" -maxdepth 1 -type f -name "$MARKER.rej.*"; }
claim_count() { claims | wc -l | tr -d ' '; }
retained_body() { local f; while IFS= read -r f; do command cat "$f"; done < <(claims); }

for legacy in current legacy; do
  for fault in read link; do
    seed "$legacy-$fault" "$legacy"
    touch -t 202601100000 "$MEMO"
    original_mtime="$(date -r "$MEMO" +%s)"
    if [ "$fault" = read ]; then
      cat() { case "${1:-}" in *.rej.*) return 1;; esac; command cat "$@"; }
      head() { local arg; for arg in "$@"; do case "$arg" in *.rej.*) return 1;; esac; done; command head "$@"; }
    else
      ln() { return 1; }
    fi
    pg_provenance_reject "$MARKER" "$FOREIGN"
    unset -f cat head ln
    check "$legacy $fault failure retains the genuine bytes in a discoverable claim" \
      "$([ "$(claim_count)" = 1 ] && [ "$(retained_body)" = "$GENUINE" ]; echo $?)"
    claim="$(claims | head -1)"
    check "$legacy $fault preserves the original inode clock" \
      "$([ -n "$claim" ] && [ "$(date -r "$claim" +%s 2>/dev/null)" = "$original_mtime" ]; echo $?)"
    check "$legacy $fault counts as a review record" "$(pg_run_left_review_record "$MARKER"; echo $?)"
    check "$legacy $fault retains the exact convicted URL in the accumulated blacklist" \
      "$(grep -qxF "$(printf '%s\t%s' "$MARKER" "$FOREIGN")" "$PRO_GATE_HOME/salvage-nonmatching.txt"; echo $?)"
  done
done

seed repeated current
ln() { return 1; }
pg_provenance_reject "$MARKER" "$FOREIGN"
printf '%s\n' "$NEWER" > "$MEMO"
pg_provenance_reject "$MARKER" "$FOREIGN"
unset -f ln
check 'repeated shell revocations never overwrite an earlier claim' \
  "$([ "$(claim_count)" = 2 ] && retained_body | grep -xF "$GENUINE" >/dev/null && retained_body | grep -xF "$NEWER" >/dev/null; echo $?)"

seed preclaim current
printf '%s\n' "$FOREIGN" > "$MEMO"
replacement="$PRO_GATE_HOME/replacement-memo"
printf '%s\n' "$GENUINE" > "$replacement"
touch -t 202601100000 "$replacement"
replacement_inode="$(stat -c %i "$replacement")"
replacement_mtime="$(date -r "$replacement" +%s)"
mv() {
  if [ "${1:-}" = "$MEMO" ]; then command mv "$replacement" "$MEMO" || return; fi
  command mv "$@"
}
pg_provenance_reject "$MARKER" "$FOREIGN"
unset -f mv
check 'replacement before shell claim restores the newer inode and original clock' \
  "$([ "$(cat "$MEMO")" = "$GENUINE" ] && [ "$(claim_count)" = 0 ] \
    && [ "$(stat -c %i "$MEMO")" = "$replacement_inode" ] && [ "$(date -r "$MEMO" +%s)" = "$replacement_mtime" ]; echo $?)"

seed empty-preclaim current
: > "$MEMO"
mv() {
  if [ "${1:-}" = "$MEMO" ]; then printf '%s\n' "$GENUINE" > "$MEMO"; fi
  command mv "$@"
}
pg_provenance_reject "$MARKER"
unset -f mv
check 'empty implicit conviction cannot change into a genuine replacement after claim' \
  "$([ "$(cat "$MEMO")" = "$GENUINE" ] && [ "$(claim_count)" = 0 ] && [ ! -s "$PRO_GATE_HOME/salvage-nonmatching.txt" ]; echo $?)"

for legacy in current legacy; do
  seed "postclaim-$legacy" "$legacy"
  mv() {
    command mv "$@" || return
    if [ "${1:-}" = "$MEMO" ]; then
      grep -qxF "$(printf '%s\t%s' "$MARKER" "$FOREIGN")" "$PRO_GATE_HOME/salvage-nonmatching.txt" \
        || printf 'missing conviction\n' > "$PRO_GATE_HOME/missing-conviction"
      printf '%s\n' "$NEWER" > "$MEMO"
    fi
  }
  pg_provenance_reject "$MARKER" "$FOREIGN"
  unset -f mv
  check "$legacy EEXIST keeps the concurrent memo and the genuine alternate" \
    "$([ "$(cat "$MEMO")" = "$NEWER" ] && [ "$(claim_count)" = 1 ] && [ "$(retained_body)" = "$GENUINE" ]; echo $?)"
  check "$legacy publishes explicit conviction before exposing the claim, exactly once" \
    "$([ ! -e "$PRO_GATE_HOME/missing-conviction" ] && [ "$(wc -l < "$PRO_GATE_HOME/salvage-nonmatching.txt")" -eq 1 ]; echo $?)"
done

for legacy in current legacy; do
  seed "conviction-$legacy" "$legacy"
  touch -t 202601100000 "$MEMO"
  original_mtime="$(date -r "$MEMO" +%s)"
  pg_provenance_reject "$MARKER" "$GENUINE"
  check "$legacy successful conviction removes the memo and resolves its claim" \
    "$([ ! -e "$MEMO" ] && [ "$(claim_count)" = 0 ]; echo $?)"
  receipts="$(find "$PRO_GATE_HOME/legacy-review-receipts" -type f)"
  if [ "$legacy" = legacy ]; then
    check 'resolved legacy receipt keeps original bytes and 14-day clock' \
      "$([ -n "$receipts" ] && [ "$(cat "$receipts")" = "$GENUINE" ] && [ "$(date -r "$receipts" +%s)" = "$original_mtime" ]; echo $?)"
  else check 'nonlegacy successful conviction leaves no receipt' "$([ -z "$receipts" ]; echo $?)"; fi
done

for legacy in current legacy; do
  for duplicate in inode bytes; do
    seed "duplicate-$legacy-$duplicate" "$legacy"
    mv() {
      command mv "$@" || return
      if [ "${1:-}" = "$MEMO" ]; then
        if [ "$duplicate" = inode ]; then command ln "$2" "$MEMO"; else command cp "$2" "$MEMO"; fi
      fi
    }
    pg_provenance_reject "$MARKER" "$FOREIGN"
    unset -f mv
    check "$legacy EEXIST with identical $duplicate resolves duplicate without losing genuine memo" \
      "$([ "$(cat "$MEMO")" = "$GENUINE" ] && [ "$(claim_count)" = 0 ]; echo $?)"
    if [ "$legacy" = legacy ]; then
      check 'duplicate resolution retains legacy receipt' \
        "$([ "$(find "$PRO_GATE_HOME/legacy-review-receipts" -type f | wc -l)" -eq 1 ]; echo $?)"
    fi
  done
done

seed marker-prefix current
other_marker="$MARKER.rej.repository-1700000001-2"
printf '%s\n' "$GENUINE" > "$PRO_GATE_HOME/conversation-urls/$other_marker"
check 'another canonical marker containing .rej. is not a pending claim' \
  "$(pg_memo_claim_pending "$MARKER"; [ "$?" -ne 0 ]; echo $?)"
printf '%s\n' "$GENUINE" > "$MEMO.rej.pending"
check 'an actual claim still blocks absence beside a similarly named marker' "$(pg_memo_claim_pending "$MARKER"; echo $?)"

seed interrupted-legacy legacy
( mv() { exit 99; }; pg_provenance_reject "$MARKER" "$FOREIGN" )
crash_rc=$?
check 'crash before claim rename leaves no empty legacy evidence' \
  "$([ "$crash_rc" = 99 ] && [ "$(cat "$MEMO")" = "$GENUINE" ] && [ "$(claim_count)" = 0 ] \
    && [ "$(find "$PRO_GATE_HOME/legacy-review-receipts" -type f | wc -l)" -eq 0 ]; echo $?)"

for shape in fifo symlink directory oversized; do
  seed "special-$shape" current
  special="$MEMO.rej.special"
  case "$shape" in
    fifo) mkfifo "$special";;
    symlink) ln -s "$MEMO" "$special";;
    directory) mkdir "$special";;
    oversized) head -c 4097 /dev/zero > "$special";;
  esac
  check "shell memo reader rejects $shape without dropping its recovery path" \
    "$(pg_memo_read "$special" >/dev/null; [ "$?" -ne 0 ] && [ -e "$special" ]; echo $?)"
done

# Extract the actual short engine predicate without executing the engine entry point.
awk '/^pg_attempt_clean_scan\(\)/ {copy=1} copy {print} copy && /^}/ {exit}' "$ENGINE" > "$TDIR/clean-scan.sh"
check 'actual engine clean-scan function was extracted' "$(grep -q '^pg_attempt_clean_scan()' "$TDIR/clean-scan.sh"; echo $?)"
. "$TDIR/clean-scan.sh"
seed publication-directory current
mv() {
  command mv "$@" || return
  if [ "${1:-}" = "$MEMO" ]; then mkdir "$MEMO"; fi
}
pg_provenance_reject "$MARKER" "$FOREIGN"
unset -f mv
check 'directory publication cannot masquerade as successful shell memo restoration' \
  "$([ -d "$MEMO" ] && [ "$(claim_count)" = 1 ] && [ "$(retained_body)" = "$GENUINE" ]; echo $?)"
RUN_MARKER="$MARKER" RUN_START=1 LIVE_CONVERSATION=0 THROTTLED=0
ORACLE_LOG_TRANSCRIPTS=("$TDIR/attempt")
pg_browser_restarted_midrun() { return 1; }
check 'actual engine clean-scan rejects directory publication after claim' "$(pg_attempt_clean_scan 4; [ "$?" -ne 0 ]; echo $?)"
# Even without a pending claim, an unreadable path is not proof that no memo exists.
seed directory-only current
rm "$MEMO"; mkdir "$MEMO"
check 'actual engine clean-scan rejects a canonical directory without a claim' "$(pg_attempt_clean_scan 4; [ "$?" -ne 0 ]; echo $?)"
rmdir "$MEMO"; ln -s "$TDIR/missing-target" "$MEMO"
check 'actual engine clean-scan rejects a dangling memo symlink without a claim' "$(pg_attempt_clean_scan 4; [ "$?" -ne 0 ]; echo $?)"
seed absence current
mv "$MEMO" "$MEMO.rej.pending"
RUN_MARKER="$MARKER" RUN_START=1 LIVE_CONVERSATION=0 THROTTLED=0
ORACLE_LOG_TRANSCRIPTS=("$TDIR/attempt")
pg_browser_restarted_midrun() { return 1; }
check 'actual engine clean-scan rejects an unresolved claim despite stale exit4' "$(pg_attempt_clean_scan 4; [ "$?" -ne 0 ]; echo $?)"

mkdir -p "$(pg_reservation_dir)"
reservation="$(pg_reservation_dir)/$MARKER"
printf '1\t%s\t1\t2\tchatgpt-pro\tpro\t1700000000\tgenerating\n' "$TDIR/review.md" > "$reservation"
before="$(cat "$reservation")"
export PRO_GATE_RECONCILE_INTERVAL=0 PRO_GATE_RESERVATION_TTL=1
# A reached terminal transition would be a defect; record it instead of altering unrelated state.
pg_attempt_terminal_from_meta() { printf 'called\n' > "$TDIR/terminal-called"; return 0; }
result="$(pg_reservation_note_miss "$MARKER")"
check 'actual miss admission preserves reservation, miss count and charge with unresolved claim' \
  "$([ "$result" = 'retained unresolved-memo' ] && [ -f "$reservation" ] && [ "$(cat "$reservation")" = "$before" ] && [ ! -e "$TDIR/terminal-called" ]; echo $?)" "$result"

mv "$MEMO.rej.pending" "$TDIR/held-claim"
for store in conversation-urls legacy-review-receipts; do
  ls() { [ "${2:-}" != "$PRO_GATE_HOME/$store" ] && command ls "$@"; }
  result="$(pg_reservation_note_miss "$MARKER")"
  unset -f ls
  check "$store enumeration failure retains reservation and miss history" \
    "$([ "$result" = 'retained unresolved-memo' ] && [ "$(cat "$reservation")" = "$before" ] \
      && [ ! -e "$TDIR/terminal-called" ]; echo $?)"
done
# Exercise the actual non-root permission failure, not only an injected ls error.
chmod 000 "$PRO_GATE_HOME/conversation-urls"
pending_rc=0; pg_memo_claim_pending "$MARKER" || pending_rc=$?
chmod 700 "$PRO_GATE_HOME/conversation-urls"
check 'unreadable claim directory cannot be mistaken for absent claims' "$pending_rc"
mv "$TDIR/held-claim" "$MEMO.rej.pending"
ls() {
  command ls "$@" || return
  if [ "${2:-}" = "$PRO_GATE_HOME/conversation-urls" ]; then chmod 000 "$2"; fi
}
pending_rc=0; pg_memo_claim_pending "$MARKER" || pending_rc=$?
unset -f ls
chmod 700 "$PRO_GATE_HOME/conversation-urls"
check 'checked listing retains its claim when storage fails before a second enumeration' "$pending_rc"

# Execute the real memo/receipt sweep commands, bounded by stable neighbouring comments.
awk '/^_pg_res_dir="\$\(pg_reservation_dir\)"/ {copy=1} /^# v0.42 \(#109\): salvage classification/ {copy=0} copy {print}' "$ENGINE" > "$TDIR/memo-sweep.sh"
check 'actual memo sweep was extracted' "$(grep -q '^find ' "$TDIR/memo-sweep.sh"; echo $?)"
touch -t 200001010000 "$MEMO.rej.pending"
printf '%s\n' "$GENUINE" > "$PRO_GATE_HOME/legacy-review-receipts/$MARKER.resolved"
printf '%s\n' "$GENUINE" > "$PRO_GATE_HOME/legacy-review-receipts/$MARKER.rej.pending"
touch -t 200001010000 "$PRO_GATE_HOME/legacy-review-receipts/$MARKER.resolved" "$PRO_GATE_HOME/legacy-review-receipts/$MARKER.rej.pending"
. "$TDIR/memo-sweep.sh"
check 'age sweep preserves unresolved current and legacy claims but expires resolved receipts' \
  "$([ -f "$MEMO.rej.pending" ] && [ -f "$PRO_GATE_HOME/legacy-review-receipts/$MARKER.rej.pending" ] && [ ! -e "$PRO_GATE_HOME/legacy-review-receipts/$MARKER.resolved" ]; echo $?)"

# Distinguish a canonical marker containing .rej. from the suffix added by a claim.
named=pg-run-repo-12-34.rej.part-1700000000-9
printf 'reserved\n' > "$(pg_reservation_dir)/$named"
for name in "$named" "$named.rej.pending" pg-run-unowned-1700000000-2.rej.pending; do
  printf '%s\n' "$GENUINE" > "$PRO_GATE_HOME/conversation-urls/$name"
  touch -t 200001010000 "$PRO_GATE_HOME/conversation-urls/$name"
done
unowned=pg-run-unowned-1700000000-2.rej.pending
printf '%s\n' "$GENUINE" > "$PRO_GATE_HOME/legacy-review-receipts/$unowned"
touch -t 200001010000 "$PRO_GATE_HOME/legacy-review-receipts/$unowned"
printf '%s\n' "$GENUINE" > "$PRO_GATE_HOME/conversation-urls/pg-run-fresh-1700000000-3.rej.pending"
. "$TDIR/memo-sweep.sh"
check 'age sweep parses original marker and preserves reserved canonical/claim bytes' \
  "$([ -f "$PRO_GATE_HOME/conversation-urls/$named" ] && [ -f "$PRO_GATE_HOME/conversation-urls/$named.rej.pending" ]; echo $?)"
check 'expired unowned current and legacy claims follow original age horizon' \
  "$([ ! -e "$PRO_GATE_HOME/conversation-urls/$unowned" ] && [ ! -e "$PRO_GATE_HOME/legacy-review-receipts/$unowned" ] \
    && [ -f "$PRO_GATE_HOME/conversation-urls/pg-run-fresh-1700000000-3.rej.pending" ]; echo $?)"
seed legacy-owned-sweep legacy
mv "$MEMO" "$PRO_GATE_HOME/legacy-review-receipts/$MARKER.rej.pending"
touch -t 200001010000 "$PRO_GATE_HOME/legacy-review-receipts/$MARKER.rej.pending"
. "$TDIR/memo-sweep.sh"
check 'legacy binding preserves unresolved recovery bytes without a reservation' \
  "$([ -f "$PRO_GATE_HOME/legacy-review-receipts/$MARKER.rej.pending" ]; echo $?)"

# Without a blacklist line, the claim is the conviction's only durable record.
seed unpublished-conviction current
printf '%s\n' "$FOREIGN" > "$MEMO"
printf() { if [ "$1" = '%s\t%s\n' ]; then return 1; fi; builtin printf "$@"; }
pg_provenance_reject "$MARKER" "$FOREIGN"
unset -f printf
check 'a conviction whose blacklist append failed keeps its claim' \
  "$([ "$(claim_count)" = 1 ] && [ "$(retained_body)" = "$FOREIGN" ] && [ ! -e "$MEMO" ] \
    && pg_memo_claim_pending "$MARKER"; echo $?)"
# Whatever the claim holds, its name alone records that conviction; another claim may hold the URL.
for held in genuine empty; do
  seed "unpublished-$held" current
  if [ "$held" = empty ]; then : > "$MEMO"; fi
  printf() { if [ "$1" = '%s\t%s\n' ]; then return 1; fi; builtin printf "$@"; }
  pg_provenance_reject "$MARKER" "$FOREIGN"
  unset -f printf
  check "a $held claim whose conviction append failed is kept after restoration" \
    "$([ "$(claim_count)" = 1 ] && pg_memo_claim_pending "$MARKER" \
      && if [ "$held" = empty ]; then [ ! -e "$MEMO" ]; else [ "$(cat "$MEMO")" = "$GENUINE" ] && [ "$(claims)" -ef "$MEMO" ]; fi; echo $?)"
done

# 39-byte GitHub owner, 100-byte repository, 7-digit PR, epoch and 7-digit pid.
seed long-marker current
long="pg-run-$(printf '%39s' '' | tr ' ' o)-$(printf '%100s' '' | tr ' ' r)-9999999-1700000000-4194304"
printf '%s\n' "$FOREIGN" > "$PRO_GATE_HOME/conversation-urls/$long"
cat() { case "${1:-}" in *.rej.*) return 1;; esac; command cat "$@"; }
head() { local arg; for arg in "$@"; do case "$arg" in *.rej.*) return 1;; esac; done; command head "$@"; }
pg_provenance_reject "$long" "$FOREIGN"
unset -f cat head
long_claim="$(find "$PRO_GATE_HOME/conversation-urls" -maxdepth 1 -type f -name "$long.rej.*")"
check 'the longest runtime marker is claimed within the filename limit' \
  "$([ "${#long}" -eq 174 ] && [ -n "$long_claim" ] && [ "$(printf '%s' "${long_claim##*/}" | wc -c)" -le 255 ] \
    && [ ! -e "$PRO_GATE_HOME/conversation-urls/$long" ] && [ "$(pg_memo_claim_marker "$long_claim")" = "$long" ] \
    && pg_memo_claim_pending "$long"; echo $?)"

if [ "$FAILURES" -gt 0 ]; then printf '%s memo recovery assertions failed\n' "$FAILURES" >&2; exit 1; fi
printf 'ALL PASS: shell memo recovery\n'
