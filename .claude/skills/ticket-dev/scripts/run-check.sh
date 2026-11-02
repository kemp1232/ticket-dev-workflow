#!/usr/bin/env bash
# run-check.sh - run one verification command and report an unambiguous status.
#
#   run-check.sh NAME -- COMMAND [ARGS...]    run argv directly
#   run-check.sh NAME -- "COMMAND STRING"     a single argument runs through sh -c
#   run-check.sh NAME --skip "REASON"         record a check that was not run
#
# Prints one status line, then (on failure) the most relevant output lines:
#   [PASS] NAME (exit 0, 3s) - COMMAND
#   [FAIL] NAME (exit 1, 12s) - COMMAND
#   [TIMEOUT] NAME (after 540s) - COMMAND
#   [SKIP] NAME - REASON
# Full output is kept in a log file outside the repository.
#
# Exit codes: 0 PASS, 1 FAIL, 3 SKIP, 4 TIMEOUT, 2 usage error.
# Env: TICKET_DEV_CHECK_TIMEOUT (seconds, default 540), TICKET_DEV_LOG_DIR
# (default: <ticket temp dir>/checks, see ticket-env.sh).

set -u

usage() {
	sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

[ $# -ge 2 ] || usage
NAME=$1
shift
case "$NAME" in '' | *[!A-Za-z0-9._-]*) echo "run-check.sh: NAME must be [A-Za-z0-9._-]" >&2; exit 2 ;; esac

if [ "$1" = "--skip" ]; then
	echo "[SKIP] $NAME - ${2:-no reason given}"
	exit 3
fi
[ "$1" = "--" ] || usage
shift
[ $# -ge 1 ] || usage

if [ $# -eq 1 ]; then
	DISPLAY=$1
	set -- sh -c "$1"
else
	DISPLAY="$*"
fi
# First real word of the command (skipping VAR=value prefixes), for "not installed" detection.
FIRST=$(printf '%s\n' "$DISPLAY" | awk '{ for (i = 1; i <= NF; i++) if ($i !~ /^[A-Za-z_][A-Za-z0-9_]*=/) { print $i; exit } }')

# Default: the ticket's private temp dir, so parallel worktrees never mix their logs.
if [ -z "${TICKET_DEV_LOG_DIR:-}" ]; then
	tdir=$(bash "$(dirname "$0")/ticket-env.sh" 2>/dev/null | sed -n 's/^tmp=//p')
	TICKET_DEV_LOG_DIR=${tdir:+$tdir/checks}
fi
LOG_DIR=${TICKET_DEV_LOG_DIR:-${TMPDIR:-/tmp}/ticket-dev-checks}
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR=${TMPDIR:-/tmp}
LOG="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$-$NAME.log"

LIMIT=${TICKET_DEV_CHECK_TIMEOUT:-540}
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
	TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
	TIMEOUT_BIN=gtimeout
fi

start=$(date +%s)
if [ -n "$TIMEOUT_BIN" ] && [ "$LIMIT" -gt 0 ] 2>/dev/null; then
	"$TIMEOUT_BIN" "$LIMIT" "$@" >"$LOG" 2>&1 </dev/null
else
	"$@" >"$LOG" 2>&1 </dev/null
fi
code=$?
secs=$(($(date +%s) - start))

if [ "$code" -eq 0 ]; then
	echo "[PASS] $NAME (exit 0, ${secs}s) - $DISPLAY"
	exit 0
fi

if [ "$code" -eq 124 ] && [ -n "$TIMEOUT_BIN" ]; then
	echo "[TIMEOUT] $NAME (after ${LIMIT}s) - $DISPLAY"
	echo "  log: $LOG"
	exit 4
fi

if [ "$code" -eq 127 ] && [ -n "$FIRST" ] && ! command -v "$FIRST" >/dev/null 2>&1; then
	echo "[SKIP] $NAME - not installed: $FIRST (exit 127; the check did not run)"
	exit 3
fi

echo "[FAIL] $NAME (exit $code, ${secs}s) - $DISPLAY"
echo "  log: $LOG ($(wc -l <"$LOG" | tr -d ' ') lines)"
# Error-looking lines first (capped), then the tail.
errs=$(grep -n -i -E 'error|fail|panic|exception|assert|expected|✗|×' "$LOG" 2>/dev/null | head -25)
if [ -n "$errs" ]; then
	echo "  --- matching lines (line:text) ---"
	printf '%s\n' "$errs" | cut -c1-240 | sed 's/^/  /'
fi
echo "  --- last 20 lines ---"
tail -n 20 "$LOG" | cut -c1-240 | sed 's/^/  /'
exit 1
