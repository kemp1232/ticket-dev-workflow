#!/usr/bin/env bash
# ticket-env.sh - per-ticket identity, scratch paths and change scope for /ticket-dev.
#
#   ticket-env.sh [DIR]                       key=value lines: root, worktree, branch,
#                                             ticket id, private temp dir, dev-server port
#   ticket-env.sh --changed-files --baseline SHA [--untracked-at-baseline BLOB|none|unknown] [DIR]
#                                             the ticket's own changes since the baseline:
#                                               changed <path>   tracked file changed or deleted
#                                               new <path>       file created by the ticket
#                                               gap <why> <path> cannot be attributed reliably
#                                             (unknown: preflight could not record untracked
#                                             files, so every untracked file is a gap)
#   ticket-env.sh --fingerprint [DIR]         one checksum of HEAD, refs, index, working tree and
#                                             untracked files, to prove a read-only step changed nothing
#
# Everything is derived from the checkout's path, so two worktrees of one repository
# never share a temp dir, log dir, browser session or port, and every artifact can be
# attributed to its ticket. Writes nothing inside the repository (the temp dir lives
# under $TMPDIR). Env: TICKET_DEV_TICKET (label), TICKET_DEV_PORT (fixed port),
# TICKET_DEV_TMP_BASE (default $TMPDIR or /tmp). Bash 3.2 compatible.

set -u
set -f

MODE=env
BASE=""
REC=none
DIR=""
while [ $# -gt 0 ]; do
	case "$1" in
	--changed-files) MODE=changes ;;
	--fingerprint) MODE=fingerprint ;;
	--baseline) BASE=${2:-}; shift ;;
	--untracked-at-baseline) REC=${2:-none}; shift ;;
	-h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) echo "ticket-env.sh: unknown option $1" >&2; exit 2 ;;
	*) DIR=$1 ;;
	esac
	shift
done

[ -n "$DIR" ] || DIR=$(pwd)
ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$DIR" 2>/dev/null && pwd))
[ -n "$ROOT" ] || { echo "ticket-env.sh: cannot resolve $DIR" >&2; exit 2; }
IS_GIT=0
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 && IS_GIT=1
g() { git -C "$ROOT" -c core.quotePath=false --no-optional-locks "$@"; }

# ------------------------------------------------------------------ fingerprint
if [ "$MODE" = fingerprint ]; then
	[ "$IS_GIT" -eq 1 ] || { echo "fingerprint: none (not a git repository)"; exit 0; }
	{
		g rev-parse HEAD 2>/dev/null
		g for-each-ref --format='%(refname) %(objectname)'
		g status --porcelain=v1 --untracked-files=all
		g diff --binary
		g diff --cached --binary
		g ls-files -o --exclude-standard | grep -v '/$' | (cd "$ROOT" && git hash-object --stdin-paths 2>/dev/null)
	} | cksum | awk '{ print "fingerprint: " $1 "-" $2 }'
	exit 0
fi

# ------------------------------------------------------------------ changed files
if [ "$MODE" = changes ]; then
	[ "$IS_GIT" -eq 1 ] || { echo "ticket-env.sh: not a git repository" >&2; exit 2; }
	[ -n "$BASE" ] && g cat-file -e "$BASE^{commit}" 2>/dev/null ||
		{ echo "ticket-env.sh: baseline '$BASE' is not a commit in this repository" >&2; exit 2; }
	# Tracked files: the baseline snapshot already contains the developer's
	# uncommitted edits, so this lists only what changed after preflight.
	g diff --name-only --no-renames "$BASE" -- | sed 's/^/changed /'
	# Pre-existing untracked files, recorded by preflight as "<blob> <path>" lines.
	recorded=""
	if [ "$REC" = unknown ]; then
		g ls-files -o --exclude-standard | sed 's/^/gap unknown-if-preexisting /'
		exit 0
	elif [ "$REC" != none ] && [ -n "$REC" ]; then
		recorded=$(g cat-file blob "$REC" 2>/dev/null) || {
			echo "gap unreadable-untracked-record $REC"
			recorded=""
		}
	fi
	now=$(g ls-files -o --exclude-standard)
	files=$(printf '%s\n' "$now" | grep -v '/$' | grep -v '^$')
	printf '%s\n' "$now" | grep '/$' | sed 's/^/gap nested-repository /'
	if [ -n "$files" ]; then
		hashes=$(printf '%s\n' "$files" | (cd "$ROOT" && git hash-object --stdin-paths 2>/dev/null))
		# BSD awk rejects newlines in -v values, so the record travels through ENVIRON.
		paste -d ' ' <(printf '%s\n' "$hashes") <(printf '%s\n' "$files") |
			TD_REC="$recorded" awk '
				BEGIN { n = split(ENVIRON["TD_REC"], lines, "\n"); for (i = 1; i <= n; i++) { if (lines[i] == "") continue
					s = index(lines[i], " "); seen[substr(lines[i], s + 1)] = substr(lines[i], 1, s - 1) } }
				{ s = index($0, " "); h = substr($0, 1, s - 1); p = substr($0, s + 1)
				  if (!(p in seen)) print "new " p
				  else if (seen[p] != h) print "gap modified-preexisting-untracked " p }'
	fi
	# Pre-existing untracked files that are gone now: the ticket deleted developer work.
	if [ -n "$recorded" ]; then
		printf '%s\n' "$recorded" | while IFS= read -r line; do
			[ -n "$line" ] || continue
			p=${line#* }
			[ -e "$ROOT/$p" ] || echo "gap deleted-preexisting-untracked $p"
		done
	fi
	exit 0
fi

# ------------------------------------------------------------------ environment
hash=$(printf '%s' "$ROOT" | cksum | awk '{ print $1 }')
name=$(printf '%s' "$(basename "$ROOT")" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)
KEY="$name-$((hash % 100000))"
TMP_BASE=${TICKET_DEV_TMP_BASE:-${TMPDIR:-/tmp}}
TMP="${TMP_BASE%/}/ticket-dev/$KEY"
(umask 077 && mkdir -p "$TMP") 2>/dev/null || true
PORT=${TICKET_DEV_PORT:-$((3100 + hash % 800))}

KIND=none
MAIN=$ROOT
BRANCH=""
if [ "$IS_GIT" -eq 1 ]; then
	gd=$(cd "$ROOT" && cd "$(git rev-parse --git-dir)" && pwd -P)
	cd_=$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
	if [ "$gd" = "$cd_" ]; then KIND=main; else KIND=linked; MAIN=$(dirname "$cd_"); fi
	BRANCH=$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
fi

echo "ticket_id=${TICKET_DEV_TICKET:-$name}"
echo "ticket_key=$KEY"
echo "root=$ROOT"
echo "worktree=$KIND"
echo "main_checkout=$MAIN"
echo "branch=$BRANCH"
echo "tmp=$TMP"
echo "port=$PORT"
exit 0
