#!/usr/bin/env bash
# ticket-worktree.sh - run /ticket-dev tickets in parallel, one git worktree per ticket.
#
#   ticket-worktree.sh start NAME --ticket "TEXT" [--base fresh|head] [--tmux] [--dry-run] [-- CLAUDE_ARGS...]
#   ticket-worktree.sh start NAME --ticket-file FILE ...
#   ticket-worktree.sh resume NAME [--dry-run]
#   ticket-worktree.sh list
#   ticket-worktree.sh status NAME            git status, commits and diffstat of that ticket
#   ticket-worktree.sh diff NAME [--against REF]   everything the ticket changed (incl. uncommitted)
#   ticket-worktree.sh clean NAME [--delete-branch] [--discard-ignored]
#
# NAME may also be given as --name NAME. Run it from your terminal inside the repository.
#
# A thin layer over Claude Code's native `claude --worktree NAME` (worktree in
# .claude/worktrees/NAME on branch worktree-NAME, base from the worktree.baseRef
# setting: "fresh" = default branch, "head" = your current HEAD). It adds checks
# before starting and a safe cleanup; it never commits, merges, pushes, or removes
# a worktree that still holds work. Each session is interactive, so the ticket's
# approval gates and guard hooks behave exactly as in a normal /ticket-dev run.
# Env: TICKET_DEV_CLAUDE_BIN (default: claude). Bash 3.2 compatible.

set -u
set -f

CLAUDE=${TICKET_DEV_CLAUDE_BIN:-claude}

die() { echo "ticket-worktree: $*" >&2; exit 2; }
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

CMD=${1:-}
[ -n "$CMD" ] || usage
shift
case "$CMD" in -h | --help | help) usage 0 ;; esac

NAME=""
TICKET=""
TICKET_FILE=""
BASE=""
TMUX_MODE=0
DRY=0
AGAINST=""
DELETE_BRANCH=0
DISCARD_IGNORED=0
EXTRA=""
NEXTRA=0
while [ $# -gt 0 ]; do
	case "$1" in
	--name) NAME=${2:-}; shift ;;
	--ticket) TICKET=${2:-}; shift ;;
	--ticket-file) TICKET_FILE=${2:-}; shift ;;
	--base) BASE=${2:-}; shift ;;
	--tmux) TMUX_MODE=1 ;;
	--dry-run) DRY=1 ;;
	--against) AGAINST=${2:-}; shift ;;
	--delete-branch) DELETE_BRANCH=1 ;;
	--discard-ignored) DISCARD_IGNORED=1 ;;
	--) shift; NEXTRA=$#; break ;;
	-*) die "unknown option $1 (see --help)" ;;
	*) [ -z "$NAME" ] || die "unexpected argument '$1'"; NAME=$1 ;;
	esac
	shift
done
# Anything after -- is passed to claude unchanged ("$@" keeps it).
[ "$NEXTRA" -gt 0 ] || set --

# ------------------------------------------------------------------ repository
command -v git >/dev/null 2>&1 || die "git is not installed"
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
COMMON=$(cd "$TOP" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
MAIN=$(dirname "$COMMON")
[ -d "$MAIN" ] && git -C "$MAIN" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
	die "cannot find the main checkout (bare repository?)"
WT_DIR="$MAIN/.claude/worktrees"
g() { git -C "$MAIN" "$@"; }

nested_guard() {
	# Inside a Claude Code session (CLAUDECODE=1) this would start a session within a
	# session and bypass the developer's own terminal: refuse.
	if [ -n "${CLAUDECODE:-}" ]; then
		die "refusing to $CMD from inside a Claude Code session; run it in your own terminal"
	fi
}

valid_name() {
	case "$1" in
	'' | *..* | *.lock | .* | -* | */* | *[!A-Za-z0-9._-]*) return 1 ;;
	esac
	[ "${#1}" -le 64 ] || return 1
	git check-ref-format --branch "worktree-$1" >/dev/null 2>&1
}

need_name() {
	[ -n "$NAME" ] || die "$CMD needs a worktree name"
	valid_name "$NAME" || die "invalid name '$NAME': use 1-64 of A-Z a-z 0-9 . _ - (no leading dot or dash, no '..')"
	WT="$WT_DIR/$NAME"
	BR="worktree-$NAME"
}

# Prints "path<TAB>branch<TAB>locked" for each registered worktree.
worktrees() {
	g worktree list --porcelain | awk '
		/^worktree / { if (p != "") print p "\t" b "\t" l; p = substr($0, 10); b = ""; l = "no" }
		/^branch / { b = substr($0, 8); sub("^refs/heads/", "", b) }
		/^detached/ { b = "(detached)" }
		/^locked/ { l = "yes" }
		END { if (p != "") print p "\t" b "\t" l }'
}
registered() { worktrees | awk -F '\t' -v p="$1" '$1 == p { found = 1 } END { exit !found }'; }
locked() { worktrees | awk -F '\t' -v p="$1" '$1 == p && $3 == "yes" { found = 1 } END { exit !found }'; }

need_existing() {
	need_name
	[ -d "$WT" ] && registered "$WT" || die "no ticket worktree '$NAME' at $WT (see: ticket-worktree.sh list)"
}

quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
show_cmd() {
	printf '%s' "(cd $(quote "$MAIN") &&"
	for a in "$@"; do printf ' %s' "$(quote "$a")"; done
	printf ')\n'
}

# Fork point used to show a ticket's own changes.
base_of() {
	if [ -n "$AGAINST" ]; then
		git -C "$1" merge-base "$AGAINST" HEAD 2>/dev/null || die "cannot find a merge base with '$AGAINST'"
		return
	fi
	main_head=$(g rev-parse HEAD 2>/dev/null)
	git -C "$1" merge-base "$main_head" HEAD 2>/dev/null || g rev-parse HEAD
}

# ------------------------------------------------------------------ commands
case "$CMD" in
start)
	nested_guard
	need_name
	[ -z "$TICKET_FILE" ] || { [ -f "$TICKET_FILE" ] || die "ticket file not found: $TICKET_FILE"; TICKET=$(cat "$TICKET_FILE"); }
	[ -n "$(printf '%s' "$TICKET" | tr -d '[:space:]')" ] || die "start needs --ticket \"TEXT\" or --ticket-file FILE"
	case "$BASE" in '' | fresh | head) ;; *) die "--base must be fresh or head" ;; esac
	g rev-parse --verify -q HEAD >/dev/null || die "the repository has no commits; a worktree needs a starting commit"
	command -v "$CLAUDE" >/dev/null 2>&1 || die "Claude Code CLI not found ('$CLAUDE'); install it or set TICKET_DEV_CLAUDE_BIN"
	[ "$TMUX_MODE" -eq 0 ] || command -v tmux >/dev/null 2>&1 || die "--tmux needs tmux on PATH (or start each ticket in its own terminal)"

	# Conflicts: never reuse or overwrite someone else's directory or branch.
	[ ! -e "$WT" ] || die "worktree '$NAME' already exists at $WT; continue it with: ticket-worktree.sh resume $NAME"
	! g show-ref --verify -q "refs/heads/$BR" || die "branch $BR already exists; pick another name or remove the branch yourself"
	! registered "$WT" || die "git still has a worktree registered at $WT; run: git worktree prune"

	# The new checkout must contain the workflow, or its guard hooks fail closed.
	gconf=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
	if [ ! -f "$gconf/skills/ticket-dev/SKILL.md" ] &&
		! g ls-files --error-unmatch .claude/skills/ticket-dev/SKILL.md >/dev/null 2>&1; then
		die "ticket-dev is neither installed globally nor committed in this repository, so a new worktree would not contain it. Install globally (scripts/install.sh --global) or commit .claude/skills/ticket-dev and .claude/agents/ticket-dev-*.md first."
	fi
	if ! g check-ignore -q ".claude/worktrees/$NAME" 2>/dev/null; then
		echo "warning: .claude/worktrees/ is not git-ignored, so worktrees show up as untracked in the main checkout."
		echo "         Fix once with: echo '.claude/worktrees/' >> $(quote "$MAIN/.git/info/exclude")  (or add it to .gitignore)"
	fi

	# The prompt goes before pass-through arguments, so a variadic option such as
	# --allowedTools cannot swallow it.
	set -- "$CLAUDE" --worktree "$NAME" --name "ticket-$NAME" \
		${BASE:+--settings "{\"worktree\":{\"baseRef\":\"$BASE\"}}"} \
		$([ "$TMUX_MODE" -eq 0 ] || echo --tmux) "/ticket-dev $TICKET" "$@"

	echo "ticket:   $NAME"
	echo "worktree: $WT"
	echo "branch:   $BR (base: ${BASE:-worktree.baseRef setting, default fresh = your default branch})"
	echo "command:  $(show_cmd "$@")"
	[ "$DRY" -eq 0 ] || { echo "(dry run: nothing started)"; exit 0; }
	(cd "$MAIN" && TICKET_DEV_TICKET="$NAME" "$@")
	code=$?
	if [ -d "$WT" ]; then
		echo "Ticket worktree kept: $WT on branch $BR. Review: ticket-worktree.sh diff $NAME | resume: ticket-worktree.sh resume $NAME"
	else
		echo "No worktree remains for $NAME (Claude Code removed it on exit, or it was never created)."
	fi
	exit "$code"
	;;

resume)
	nested_guard
	need_existing
	command -v "$CLAUDE" >/dev/null 2>&1 || die "Claude Code CLI not found ('$CLAUDE')"
	set -- "$CLAUDE" --worktree "$NAME" --resume "$@"
	echo "worktree: $WT (branch $(git -C "$WT" symbolic-ref --short -q HEAD || echo detached))"
	echo "command:  $(show_cmd "$@")"
	[ "$DRY" -eq 0 ] || { echo "(dry run: nothing started)"; exit 0; }
	cd "$MAIN" && TICKET_DEV_TICKET="$NAME" exec "$@"
	;;

list)
	printf '%-24s %-32s %-9s %-8s %s\n' NAME BRANCH CHANGES COMMITS STATE
	worktrees | while IFS="$(printf '\t')" read -r path branch lck; do
		case "$path" in "$WT_DIR"/*) ;; *) continue ;; esac
		n=${path#"$WT_DIR"/}
		if [ -d "$path" ]; then
			changes=$(git -C "$path" status --porcelain --untracked-files=all 2>/dev/null | grep -c . | tr -d ' ')
			commits=$(git -C "$path" rev-list --count "$(base_of "$path")..HEAD" 2>/dev/null || echo "?")
			state=$([ "$lck" = yes ] && echo "in use (locked)" || echo idle)
		else
			changes="-"; commits="-"; state="missing directory (git worktree prune)"
		fi
		printf '%-24s %-32s %-9s %-8s %s\n' "$n" "$branch" "$changes" "$commits" "$state"
	done
	[ -n "$(worktrees | awk -F '\t' -v d="$WT_DIR/" 'index($1, d) == 1')" ] || echo "(no ticket worktrees under $WT_DIR)"
	;;

status)
	need_existing
	mb=$(base_of "$WT") && [ -n "$mb" ] || exit 2
	echo "worktree: $WT"
	echo "branch:   $(git -C "$WT" symbolic-ref --short -q HEAD || echo detached)$(locked "$WT" && echo ' (in use by a session)')"
	echo "base:     $(git -C "$WT" rev-parse --short "$mb")"
	echo "--- uncommitted (git status --short)"
	git -C "$WT" status --short --untracked-files=all
	echo "--- commits since base"
	git -C "$WT" log --oneline "$mb..HEAD"
	echo "--- diffstat since base (committed and uncommitted tracked changes)"
	git -C "$WT" diff --stat "$mb"
	;;

diff)
	need_existing
	mb=$(base_of "$WT") && [ -n "$mb" ] || exit 2
	echo "# git -C $(quote "$WT") diff $(git -C "$WT" rev-parse --short "$mb")   (committed + uncommitted tracked changes)"
	git -C "$WT" --no-pager diff "$mb"
	untracked=$(git -C "$WT" ls-files -o --exclude-standard)
	if [ -n "$untracked" ]; then
		echo "# untracked files (new, not in the diff above):"
		printf '%s\n' "$untracked" | sed 's/^/#   /'
	fi
	;;

clean)
	nested_guard
	need_existing
	locked "$WT" && die "worktree '$NAME' is locked (a Claude Code session is using it). Exit that session first."
	dirty=$(git -C "$WT" status --porcelain --untracked-files=all)
	if [ -n "$dirty" ]; then
		echo "Refusing to remove $WT: it has uncommitted changes or untracked files:" >&2
		printf '%s\n' "$dirty" | head -n 20 | sed 's/^/  /' >&2
		echo "Commit them on $BR, move them elsewhere, or discard them yourself, then retry." >&2
		exit 1
	fi
	ignored=$(git -C "$WT" status --porcelain --ignored --untracked-files=normal | sed -n 's/^!! //p')
	if [ -n "$ignored" ] && [ "$DISCARD_IGNORED" -eq 0 ]; then
		echo "Refusing to remove $WT: these git-ignored paths would be deleted with it:" >&2
		printf '%s\n' "$ignored" | head -n 20 | sed 's/^/  /' >&2
		echo "If they are disposable (dependencies, build output, copied .env), rerun with --discard-ignored." >&2
		exit 1
	fi
	g worktree remove "$WT" || die "git worktree remove failed; nothing else was changed"
	echo "Removed worktree $WT."
	if [ "$DELETE_BRANCH" -eq 1 ]; then
		# -d (not -D): git refuses to delete a branch whose commits are not merged.
		if g branch -d "$BR"; then
			echo "Deleted branch $BR (it was fully merged)."
		else
			echo "Kept branch $BR: it has commits that are not merged. Delete it yourself with git branch -D if you are sure."
			exit 1
		fi
	else
		echo "Kept branch $BR ($(g rev-list --count "$(g rev-parse HEAD)..$BR" 2>/dev/null || echo '?') commit(s) not on your current branch). Merge it or delete it yourself."
	fi
	;;

*) die "unknown command '$CMD' (start, resume, list, status, diff, clean)" ;;
esac
