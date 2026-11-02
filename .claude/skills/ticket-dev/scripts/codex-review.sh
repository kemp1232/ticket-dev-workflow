#!/usr/bin/env bash
# codex-review.sh - independent, read-only Codex CLI review of ONE ticket's changes.
#
#   codex-review.sh --consent requested|configured --baseline SHA
#                   [--untracked-at-baseline BLOB|none|unknown] [--title TEXT]
#                   [--scope-only] [--project-dir DIR]
#
# --consent states why code may go to OpenAI: "requested" (the developer passed
# --codex-review for this ticket) or "configured" (verified here: the project's own
# .claude/ticket-dev/routing.conf sets CODEX_REVIEW_ROUTES). Without it nothing is sent.
#
# Codex's own targets do not fit a ticket: --uncommitted also reviews the developer's
# pre-existing edits and untracked files, and --base reviews the whole branch. So the
# script builds a synthetic commit "baseline -> ticket result" with a TEMPORARY index
# (the developer's index, working tree, stash and refs are never touched; like
# preflight's `git stash create`, it only adds unreferenced git objects) and runs
#   codex exec review --commit <that commit>
# with sandbox_mode="read-only". New files created by the ticket are included,
# untracked files that existed before preflight are excluded, and anything that cannot
# be attributed is reported as a scope gap. The repository is fingerprinted before and
# after; any change makes the result INCOMPLETE.
#
# Output: a normalized "CROSS-MODEL REVIEW:" block. Exit codes: 0 PASS, 1 FINDINGS,
# 3 SKIP (nothing sent: Codex missing or logged out, no changes), 4 INCOMPLETE, 2 usage.
# Codex runs with --ignore-user-config: your ~/.codex/config.toml (MCP servers, which
# the file sandbox does not cover, profiles, model) is not loaded; the login still is.
# Env: TICKET_DEV_CODEX_BIN (default codex), TICKET_DEV_CODEX_TIMEOUT (seconds,
# default 540), TICKET_DEV_CODEX_USER_CONFIG=1 (load your config.toml after all).
# Uses the Codex CLI's own login (ChatGPT sign-in works; no API key is read or
# required). Bash 3.2 compatible.

set -u
set -f

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CODEX=${TICKET_DEV_CODEX_BIN:-codex}
LIMIT=${TICKET_DEV_CODEX_TIMEOUT:-540}

BASE=""
CONSENT=""
REC=none
TITLE="ticket-dev ticket"
SCOPE_ONLY=0
PROJECT_DIR=""
while [ $# -gt 0 ]; do
	case "$1" in
	--baseline) BASE=${2:-}; shift ;;
	--consent) CONSENT=${2:-}; shift ;;
	--untracked-at-baseline) REC=${2:-none}; shift ;;
	--title) TITLE=${2:-}; shift ;;
	--scope-only) SCOPE_ONLY=1 ;;
	--project-dir) PROJECT_DIR=${2:-}; shift ;;
	-h | --help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "codex-review.sh: unknown argument $1 (see --help)" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$BASE" ] || { echo "codex-review.sh: --baseline SHA is required (from preflight)" >&2; exit 2; }
case "$LIMIT" in '' | *[!0-9]*) LIMIT=540 ;; esac

REVIEWER="Codex CLI"
SCOPE_LINES=""
EXCLUDED=""
GAPS=""
READONLY=""
RAW=""
finish() { # STATUS EXIT REASON [FINDINGS-TEXT]
	echo "CROSS-MODEL REVIEW: $1"
	echo
	echo "Reviewer: $REVIEWER"
	echo "Scope: ${SCOPE_SUMMARY:-not established}"
	[ -z "$SCOPE_LINES" ] || printf '%s\n' "$SCOPE_LINES" | head -n 40 | sed 's/^/  /'
	[ -z "$EXCLUDED" ] || echo "Excluded: $EXCLUDED"
	echo "Scope gaps: ${GAPS:-none}"
	[ -z "$READONLY" ] || echo "Read-only check: $READONLY"
	[ -z "${3:-}" ] || echo "Reason: $3"
	if [ -n "${4:-}" ]; then
		echo
		printf '%s\n' "$4"
		echo
		echo "Disposition: pending - validate each finding against the repository (VERIFIED, CONFLICTS, UNVERIFIABLE, OUT OF SCOPE) before acting on it."
	fi
	[ -z "$RAW" ] || echo "Raw output: $RAW"
	exit "$2"
}

# ------------------------------------------------------------------ repository and scope
[ -n "$PROJECT_DIR" ] || PROJECT_DIR=$(pwd)
ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || finish SKIP 3 "not a git repository; the ticket's changes cannot be isolated"
cd "$ROOT" || finish INCOMPLETE 4 "cannot enter $ROOT"
git cat-file -e "$BASE^{commit}" 2>/dev/null || finish INCOMPLETE 4 "baseline '$BASE' is not a commit here, so the review scope cannot be established"

TMPD=$(bash "$SCRIPT_DIR/ticket-env.sh" "$ROOT" | sed -n 's/^tmp=//p')
WORK="${TMPD:-${TMPDIR:-/tmp}/ticket-dev}/codex-$(date +%Y%m%d-%H%M%S)-$$"
(umask 077 && mkdir -p "$WORK") || finish INCOMPLETE 4 "cannot create $WORK"

changes=$(bash "$SCRIPT_DIR/ticket-env.sh" --changed-files --baseline "$BASE" --untracked-at-baseline "$REC" "$ROOT") ||
	finish INCOMPLETE 4 "cannot list the ticket's changes"
paths=$(printf '%s\n' "$changes" | sed -n -e 's/^changed //p' -e 's/^new //p')
GAPS=$(printf '%s\n' "$changes" | sed -n 's/^gap //p' | head -n 10 | tr '\n' ';' | sed -e 's/;$//' -e 's/;/; /g')
case "$REC" in none | unknown) ;; *) EXCLUDED="pre-existing untracked files unchanged since preflight (record $REC); pre-existing tracked edits are part of the baseline" ;; esac
[ "$REC" = none ] && EXCLUDED="pre-existing tracked edits are part of the baseline (no untracked files at preflight)"

# Synthetic commit: baseline tree + the ticket's files, built in a throwaway index.
IDX="$WORK/index"
export GIT_INDEX_FILE="$IDX"
git read-tree "$BASE" || finish INCOMPLETE 4 "git read-tree failed"
if [ -n "$paths" ]; then
	printf '%s\n' "$paths" | git update-index --add --remove --stdin || finish INCOMPLETE 4 "git update-index failed on the temporary index"
fi
tree=$(git write-tree) || finish INCOMPLETE 4 "git write-tree failed"
unset GIT_INDEX_FILE
REVIEW_SHA=$(GIT_AUTHOR_NAME=ticket-dev GIT_AUTHOR_EMAIL=ticket-dev@localhost \
	GIT_COMMITTER_NAME=ticket-dev GIT_COMMITTER_EMAIL=ticket-dev@localhost \
	git commit-tree "$tree" -p "$BASE" -m "ticket-dev review scope: $TITLE" </dev/null) || finish INCOMPLETE 4 "git commit-tree failed"
SCOPE_LINES=$(git -c core.quotePath=false diff-tree -r --no-commit-id --name-status --no-renames "$BASE" "$REVIEW_SHA")
nfiles=$(printf '%s' "$SCOPE_LINES" | grep -c . | tr -d ' ')
SCOPE_SUMMARY="ticket changes only - $nfiles file(s) since baseline $(git rev-parse --short "$BASE"), review commit $(git rev-parse --short "$REVIEW_SHA")"
rm -f "$IDX"

[ "$nfiles" -gt 0 ] || finish SKIP 3 "the ticket has no changes to review$([ -n "$GAPS" ] && echo ' (only unattributable files, see scope gaps)')"
[ "$SCOPE_ONLY" -eq 0 ] || finish SKIP 3 "--scope-only: nothing was sent to Codex"

# ------------------------------------------------------------------ consent
case "$CONSENT" in
requested) ;;
configured)
	routes=$(bash "$SCRIPT_DIR/route.sh" --print-config --project-dir "$ROOT" 2>/dev/null | sed -n 's/^CODEX_REVIEW_ROUTES=\([^ ]*\).*/\1/p')
	case "$routes" in '' | none) finish SKIP 3 "--consent configured, but this project's .claude/ticket-dev/routing.conf does not set CODEX_REVIEW_ROUTES - nothing was sent" ;; esac
	;;
*) finish SKIP 3 "no --consent requested|configured given; code is sent to OpenAI only after the developer opted in - nothing was sent" ;;
esac

# ------------------------------------------------------------------ Codex availability
command -v "$CODEX" >/dev/null 2>&1 || finish SKIP 3 "Codex CLI not installed ('$CODEX' not on PATH): npm install -g @openai/codex, then codex login"
ver=$("$CODEX" --version 2>/dev/null </dev/null | head -n 1)
REVIEWER="Codex CLI (${ver:-version unknown})"
"$CODEX" exec review --help 2>/dev/null </dev/null | grep -q -- '--commit' ||
	finish INCOMPLETE 4 "this Codex CLI has no 'codex exec review --commit'; update it (codex update) - nothing was sent"
login=$("$CODEX" login status 2>&1 </dev/null)
lcode=$?
case "$login" in
*ChatGPT* | *chatgpt*) auth="ChatGPT sign-in (counts against your ChatGPT plan; no API key used)" ;;
*"API key"* | *"api key"* | *"API Key"*) auth="API key (billed to that OpenAI API account)" ;;
*) auth="unknown method" ;;
esac
[ "$lcode" -eq 0 ] || finish SKIP 3 "Codex CLI is not logged in: run 'codex login' (ChatGPT sign-in is enough) - nothing was sent"
note=""
{ [ -n "${OPENAI_API_KEY:-}" ] || [ -n "${CODEX_API_KEY:-}" ]; } && note="; note: an OpenAI/Codex API key variable is set in this environment and may be billed"
REVIEWER="$REVIEWER, auth: $auth$note"

# ------------------------------------------------------------------ review
TIMEOUT_BIN=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN=timeout
[ -n "$TIMEOUT_BIN" ] || { command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN=gtimeout; }
OUT="$WORK/review.md"
LOG="$WORK/codex.log"
RAW="$OUT (log: $LOG)"
before=$(bash "$SCRIPT_DIR/ticket-env.sh" --fingerprint "$ROOT")
set -- "$CODEX" exec review --commit "$REVIEW_SHA" --title "$TITLE" \
	-c 'sandbox_mode="read-only"' -c 'approval_policy="never"' --ephemeral -o "$OUT"
if [ "${TICKET_DEV_CODEX_USER_CONFIG:-}" = 1 ]; then
	REVIEWER="$REVIEWER; user config.toml loaded (TICKET_DEV_CODEX_USER_CONFIG=1)"
else
	set -- "$@" --ignore-user-config
fi
start=$(date +%s)
if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$LIMIT" "$@" </dev/null >"$LOG" 2>&1; else "$@" </dev/null >"$LOG" 2>&1; fi
code=$?
secs=$(($(date +%s) - start))
after=$(bash "$SCRIPT_DIR/ticket-env.sh" --fingerprint "$ROOT")
if [ "$before" = "$after" ]; then
	READONLY="repository unchanged by the review (HEAD, refs, index, working tree, untracked files)"
else
	READONLY="UNEXPECTED MODIFICATION: the repository changed while Codex ran; inspect git status before continuing"
fi

# ------------------------------------------------------------------ parse findings
# Codex renders findings as "- [P1] Title — /abs/path:10-12" followed by indented body lines.
# LC_ALL=C: byte semantics, so the UTF-8 em dash matches in every awk. Fields are
# separated by \037 (not whitespace), so an empty location does not shift them.
US=$(printf '\037')
findings=$(LC_ALL=C awk -v root="$ROOT/" -v us="$US" '
	function flush() {
		if (t == "") return
		n++
		gsub(us, " ", body); gsub(/^ +| +$/, "", body)
		if (length(body) > 600) body = substr(body, 1, 597) "..."
		printf "%s%s%s%s%s%s%s\n", sev, us, loc, us, t, us, body
		t = ""; body = ""
	}
	/^[[:space:]]*([-*][[:space:]]+|[0-9]+\.[[:space:]]+)?(\[[ xX]\][[:space:]]+)?\[P[0-3]\]/ {
		flush()
		line = $0
		match(line, /\[P[0-3]\]/); sev = substr(line, RSTART + 1, 2); rest = substr(line, RSTART + RLENGTH)
		sub(/^[[:space:]]+/, "", rest)
		loc = ""; cut = 0; seplen = 0
		for (i = 1; i <= length(rest); i++) {
			if (substr(rest, i, 5) == " \342\200\224 ") { cut = i; seplen = 5 }
		}
		if (cut > 0) { loc = substr(rest, cut + seplen); rest = substr(rest, 1, cut - 1) }
		else if (match(rest, / (-|at) [^ ]+:[0-9]+(-[0-9]+)?$/)) { loc = substr(rest, RSTART); sub(/^ (-|at) /, "", loc); rest = substr(rest, 1, RSTART - 1) }
		if (index(loc, root) == 1) loc = substr(loc, length(root) + 1)
		t = rest
		next
	}
	t != "" && /^[[:space:]]+[^[:space:]]/ { l = $0; sub(/^[[:space:]]+/, "", l); body = body (body == "" ? "" : " ") l; next }
	t != "" && /^[[:space:]]*$/ { next }
	t != "" { flush() }
	END { flush() }' "$OUT" 2>/dev/null)
nf=$(printf '%s' "$findings" | grep -c . | tr -d ' ')
block=""
if [ "$nf" -gt 0 ]; then
	block="Findings: $nf"
	i=0
	oldifs=$IFS
	IFS='
'
	for f in $findings; do
		IFS=$US
		set -- $f
		IFS='
'
		i=$((i + 1))
		case "$1" in P0) sv="P0 (critical)" ;; P1) sv="P1 (high)" ;; P2) sv="P2 (medium)" ;; *) sv="P3 (low)" ;; esac
		block="$block
- F$i Severity: $sv
  File and line: ${2:-not given}
  Description: ${3:-}
  Evidence: ${4:-(no detail given)}
  Recommended action: decide after validation (fix if VERIFIED and in scope)"
	done
	IFS=$oldifs
fi

# ------------------------------------------------------------------ status
if [ "$code" -eq 124 ] && [ -n "$TIMEOUT_BIN" ]; then
	finish INCOMPLETE 4 "Codex review timed out after ${LIMIT}s (raise TICKET_DEV_CODEX_TIMEOUT; run the command in the background)" "$block"
fi
if [ "$code" -ne 0 ]; then
	why="Codex exited with code $code after ${secs}s"
	if grep -qiE '401|unauthori[sz]ed|not logged in|log ?in again|expired|re-?authenticat' "$LOG" 2>/dev/null; then
		why="$why: authentication failed, run 'codex login'"
	elif grep -qiE 'usage limit|rate limit|429|quota' "$LOG" 2>/dev/null; then
		why="$why: usage or rate limit reached"
	fi
	finish INCOMPLETE 4 "$why; see the log" "$block"
fi
case "$READONLY" in UNEXPECTED*) finish INCOMPLETE 4 "the repository changed during the review" "$block" ;; esac
[ -s "$OUT" ] || finish INCOMPLETE 4 "Codex exited 0 but wrote no review"
grep -q 'Reviewer failed to output a response' "$OUT" && finish INCOMPLETE 4 "Codex reported that the reviewer produced no response"
if [ "$nf" -eq 0 ] && grep -Eq '\[P[0-3]\]' "$OUT"; then
	finish FINDINGS 1 "the review contains prioritized findings this script could not parse; read the raw output" "Findings: unparsed (see raw output)"
fi
[ "$nf" -gt 0 ] && finish FINDINGS 1 "" "$block"
[ -z "$GAPS" ] || finish INCOMPLETE 4 "no findings, but part of the change could not be attributed to the ticket (scope gaps)"
finish PASS 0 "no findings ($(head -c 300 "$OUT" | tr '\n' ' '))"
