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
# Used by the /ticket-dev orchestrator inside a session (they start no session):
#   ticket-worktree.sh claim [--session ID] [--force]   record that this session owns this
#                                             checkout; prints checkout=mine|busy|untracked
#   ticket-worktree.sh release --session ID   drop this session's claim on this checkout
#   ticket-worktree.sh servers                dev servers (expo, metro, vite, next, ...) running
#                                             from the main checkout instead of this worktree
#   ticket-worktree.sh bases                  saved default and candidate base branches
#   ticket-worktree.sh create NAME --base BRANCH [--set-default] [--dry-run]
#                                             new worktree from origin/BRANCH (fetched first)
#
# NAME may also be given as --name NAME. start, resume and clean run from your terminal.
#
# start is a thin layer over Claude Code's native `claude --worktree NAME` (worktree in
# .claude/worktrees/NAME on branch worktree-NAME, base from the worktree.baseRef
# setting: "fresh" = default branch, "head" = your current HEAD). create builds the
# same layout with git so any branch can be the base. Nothing here commits, merges,
# pushes, or removes a worktree that still holds work or a live session.
# Env: TICKET_DEV_CLAUDE_BIN (default: claude), TICKET_DEV_FETCH_TIMEOUT (seconds,
# default 20), TICKET_DEV_CLAIM_IDLE_MINUTES (default 30: a claim whose session
# transcript has not changed for this long is stale). Bash 3.2 compatible.

set -u
set -f

CLAUDE=${TICKET_DEV_CLAUDE_BIN:-claude}

die() { echo "ticket-worktree: $*" >&2; exit 2; }
usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

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
SESSION=""
FORCE=0
SET_DEFAULT=0
EXTRA=""
NEXTRA=0
while [ $# -gt 0 ]; do
	case "$1" in
	--name) NAME=${2:-}; shift ;;
	--session) SESSION=$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9._-'); shift ;;
	--force) FORCE=1 ;;
	--set-default) SET_DEFAULT=1 ;;
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

# ------------------------------------------------------------------ session ownership
# A checkout belongs to the Claude Code session that last ran /ticket-dev in it, while
# that session's process lives and its transcript keeps changing (an IDE extension's
# process outlives a finished chat). The workflow releases the claim when a ticket
# ends. The record sits in the checkout's own git dir (never in the working tree), so
# every worktree has its own and git ignores it.
claim_file() { echo "$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)/ticket-dev-session"; }
claim_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
pid_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'; }

# The Claude Code process this script runs under (empty if none). Comparing its start
# time as well means a reused PID never counts as the old session.
session_pid() {
	case "${TICKET_DEV_SESSION_PID:-}" in
	0) return ;;
	'') ;;
	*) echo "$TICKET_DEV_SESSION_PID"; return ;;
	esac
	sp=$PPID
	depth=0
	while [ "$depth" -lt 10 ] && [ "$sp" -gt 1 ] 2>/dev/null; do
		pc=$(ps -o comm= -p "$sp" 2>/dev/null)
		case "${pc##*/}" in
		claude | claude.exe) echo "$sp"; return ;;
		node) case "$(ps -o args= -p "$sp" 2>/dev/null)" in *claude*) echo "$sp"; return ;; esac ;;
		esac
		sp=$(ps -o ppid= -p "$sp" 2>/dev/null | tr -d ' ')
		depth=$((depth + 1))
	done
}

# session_idle ID: true when the session's transcript exists and neither it nor
# anything under <ID>/ (subagent transcripts, tool results) changed in the last
# TICKET_DEV_CLAIM_IDLE_MINUTES. No transcript found (PID-only session): not idle.
session_idle() {
	case "$1" in '' | pid-*) return 1 ;; esac
	pd="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
	tf=$(find "$pd" -mindepth 2 -maxdepth 2 -type f -name "$1.jsonl" 2>/dev/null | head -n 1)
	[ -n "$tf" ] || return 1
	recent=$(find "$tf" "${tf%.jsonl}" -mmin "-${TICKET_DEV_CLAIM_IDLE_MINUTES:-30}" 2>/dev/null | head -n 1)
	[ -z "$recent" ]
}

# live_holder DIR: prints "session since branch" of a live claim on DIR's checkout.
live_holder() {
	lf=$(claim_file "$1")
	[ -f "$lf" ] || return 1
	hp=$(claim_get "$lf" pid)
	hs=$(claim_get "$lf" started)
	[ -n "$hp" ] && [ -n "$hs" ] && [ "$(pid_start "$hp")" = "$hs" ] || return 1
	! session_idle "$(claim_get "$lf" session)" || return 1
	echo "$(claim_get "$lf" session) since $(claim_get "$lf" since) on $(claim_get "$lf" branch)"
}

# ------------------------------------------------------------------ dev servers
DEV_SERVERS='expo|metro|react-native start|vite|next dev|next start|nuxt|astro dev|ng serve|webpack serve|webpack-dev-server|remix dev|react-scripts start|parcel|rails s|rails server|manage.py runserver|flask run|uvicorn|php artisan serve'

# pid_cwd PID: the process's working directory (Linux /proc, else lsof).
pid_cwd() {
	if [ -d "/proc/$1" ]; then
		(cd "/proc/$1/cwd" 2>/dev/null && pwd -P)
	elif command -v lsof >/dev/null 2>&1; then
		lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
	fi
}

# ------------------------------------------------------------------ base branches
on_origin() { g remote get-url origin >/dev/null 2>&1; }
has_ref() { g show-ref --verify -q "$1"; }

# Bounded, non-interactive fetch of one branch: never waits for a password prompt.
fetch_branch() {
	t=""
	limit=${TICKET_DEV_FETCH_TIMEOUT:-20}
	if command -v timeout >/dev/null 2>&1; then t="timeout $limit"
	elif command -v gtimeout >/dev/null 2>&1; then t="gtimeout $limit"; fi
	GIT_TERMINAL_PROMPT=0 $t git -C "$MAIN" fetch -q --no-tags origin \
		"+refs/heads/$1:refs/remotes/origin/$1" </dev/null >/dev/null 2>&1
}

# The repository's own install command, from its lockfile. Only commands that do
# not rewrite the lockfile, so setting up a worktree never shows up in its diff.
setup_hint() {
	if [ -f "$1/pnpm-lock.yaml" ]; then echo "pnpm install --frozen-lockfile"
	elif [ -f "$1/yarn.lock" ]; then
		if [ -f "$1/.yarnrc.yml" ]; then echo "yarn install --immutable"; else echo "yarn install --frozen-lockfile"; fi
	elif [ -f "$1/bun.lock" ] || [ -f "$1/bun.lockb" ]; then echo "bun install --frozen-lockfile"
	elif [ -f "$1/package-lock.json" ]; then echo "npm ci"
	elif [ -f "$1/uv.lock" ]; then echo "uv sync --frozen"
	elif [ -f "$1/poetry.lock" ]; then echo "poetry install"
	elif [ -f "$1/Pipfile.lock" ]; then echo "pipenv sync"
	elif [ -f "$1/composer.lock" ]; then echo "composer install"
	elif [ -f "$1/Gemfile.lock" ]; then echo "bundle install"
	else echo none; fi
}

# Subdirectories with their own lockfile (a separate server/, functions/ or app) that
# an install at the root does not cover. Workspace members share the root lockfile,
# so they are not listed. Prints "dir<TAB>command".
nested_setup() {
	(cd "$1" && find . -mindepth 2 -maxdepth 3 \( -name node_modules -o -name .git -o -name .claude -o -name vendor -o -name .venv \) -prune -o \
		-type f \( -name pnpm-lock.yaml -o -name yarn.lock -o -name bun.lock -o -name bun.lockb -o -name package-lock.json \
		-o -name uv.lock -o -name poetry.lock -o -name Pipfile.lock -o -name composer.lock -o -name Gemfile.lock \) -print 2>/dev/null) |
		sed 's|^\./||; s|/[^/]*$||' | LC_ALL=C sort -u | while IFS= read -r d; do
			[ -n "$d" ] && printf '%s\t%s\n' "$d" "$(setup_hint "$1/$d")"
		done
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
			if h=$(live_holder "$path"); then state="in use (session ${h%% *})"
			elif [ "$lck" = yes ]; then state="in use (locked)"
			else state=idle; fi
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
	h=$(live_holder "$WT") && die "worktree '$NAME' is in use by Claude Code session $h. Close that chat first."
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

claim)
	f=$(claim_file "$TOP")
	pid=$(session_pid)
	if [ -z "$pid" ]; then
		echo "checkout=untracked (no Claude Code session process found, so parallel sessions cannot be detected)"
		exit 0
	fi
	[ -n "$SESSION" ] || SESSION="pid-$pid"
	echo "session=$SESSION"
	holder=$(live_holder "$TOP") && [ "$(claim_get "$f" session)" != "$SESSION" ] || holder=""
	if [ -n "$holder" ] && [ "$FORCE" -eq 0 ]; then
		echo "checkout=busy"
		echo "holder=session $holder"
		exit 3
	fi
	tmpf="$f.$$"
	{
		echo "session=$SESSION"
		echo "pid=$pid"
		echo "started=$(pid_start "$pid")"
		echo "since=$(date '+%Y-%m-%d %H:%M')"
		echo "branch=$(git -C "$TOP" symbolic-ref --short -q HEAD || echo detached)"
	} >"$tmpf" && mv -f "$tmpf" "$f" || { rm -f "$tmpf"; die "cannot write $f"; }
	echo "checkout=mine${holder:+ (taken over from session $holder)}"
	;;

release)
	[ -n "$SESSION" ] || die "release needs --session ID"
	f=$(claim_file "$TOP")
	if [ -f "$f" ] && { [ "$(claim_get "$f" session)" = "$SESSION" ] || ! live_holder "$TOP" >/dev/null; }; then
		rm -f "$f"
		echo "checkout=released"
	else
		echo "checkout=unchanged"
	fi
	;;

servers)
	# A dev server started in the main checkout keeps serving the old code while the
	# ticket's change sits in this worktree.
	[ "$TOP" != "$MAIN" ] || { echo "dev_servers=n/a (this is the main checkout)"; exit 0; }
	found=$(ps -eo pid=,args= 2>/dev/null | grep -E "($DEV_SERVERS)( |$)" |
		while read -r pid args; do
			case "$args" in grep* | *ticket-worktree.sh*) continue ;; esac
			cwd=$(pid_cwd "$pid")
			case "$cwd" in "$WT_DIR" | "$WT_DIR"/*) continue ;; "$MAIN" | "$MAIN"/*) ;; *) continue ;; esac
			echo "dev_server=$pid $(printf '%s' "$args" | cut -c1-100) (cwd $cwd)"
		done)
	if [ -n "$found" ]; then printf '%s\n' "$found"; else echo "dev_servers=none in $MAIN"; fi
	;;

bases)
	def=$(g config --get ticket-dev.worktreeBase 2>/dev/null)
	rdef=""
	on_origin && rdef=$(g symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
	rdef=${rdef#origin/}
	cur=$(g symbolic-ref --short -q HEAD 2>/dev/null)
	cands=""
	for b in "$def" "$rdef" staging develop development dev main master "$cur"; do
		[ -n "$b" ] || continue
		case " $cands " in *" $b "*) continue ;; esac
		has_ref "refs/remotes/origin/$b" || has_ref "refs/heads/$b" || continue
		cands="$cands${cands:+ }$b"
	done
	echo "default=$def"
	echo "remote=$(on_origin && echo origin || echo none)"
	echo "remote_default=$rdef"
	echo "main_checkout_branch=$cur"
	echo "candidates=$cands"
	;;

create)
	[ -n "$BASE" ] || die "create needs --base BRANCH (see: ticket-worktree.sh bases)"
	git check-ref-format --branch "$BASE" >/dev/null 2>&1 || die "invalid base branch '$BASE'"
	need_name
	g rev-parse --verify -q HEAD >/dev/null || die "the repository has no commits; a worktree needs a starting commit"
	for d in "$MAIN/.claude" "$WT_DIR"; do
		[ ! -L "$d" ] || die "$d is a symbolic link; Claude Code refuses worktrees there"
	done
	# Never reuse someone else's directory or branch: take the first free suffix.
	want=$NAME
	i=2
	while [ -e "$WT" ] || registered "$WT" || has_ref "refs/heads/$BR"; do
		[ "$i" -le 20 ] || die "no free worktree name for '$want'"
		NAME="$want-$i"
		i=$((i + 1))
		need_name
	done

	how="local branch"
	if on_origin; then
		if fetch_branch "$BASE"; then how="fetched just now"; else how="cached copy; fetch failed or timed out, may be stale"; fi
	fi
	if has_ref "refs/remotes/origin/$BASE"; then
		START="origin/$BASE"
	elif has_ref "refs/heads/$BASE"; then
		START=$BASE
		how="local branch (not on origin)"
	else
		die "base branch '$BASE' exists neither on origin nor locally (see: ticket-worktree.sh bases)"
	fi
	echo "worktree=$WT"
	echo "name=$NAME"
	echo "branch=$BR"
	echo "base=$START @ $(g rev-parse --short "$START") ($how)"
	[ "$DRY" -eq 0 ] || { echo "(dry run: nothing created)"; exit 0; }

	# Keep worktrees out of every checkout's git status: otherwise a ticket running in
	# the main checkout would see this directory as a new untracked file.
	if ! g check-ignore -q ".claude/worktrees/$NAME" 2>/dev/null; then
		mkdir -p "$COMMON/info" && printf '.claude/worktrees/\n' >>"$COMMON/info/exclude"
		echo "excluded=.claude/worktrees/ added to $COMMON/info/exclude (local only, never committed)"
	fi
	mkdir -p "$WT_DIR"
	# --no-track: the new branch must not push to the base branch by accident.
	g worktree add -q --no-track -b "$BR" "$WT" "$START" >&2 || die "git worktree add failed; nothing else was changed"

	# Same contract as Claude Code's .worktreeinclude: copy files that match it and
	# are git-ignored (so tracked files are never duplicated).
	copied=0
	if [ -f "$MAIN/.worktreeinclude" ]; then
		files=$(g -c core.quotePath=false ls-files -o -i --exclude-from="$MAIN/.worktreeinclude" 2>/dev/null |
			g check-ignore --stdin 2>/dev/null)
		while IFS= read -r p; do
			[ -n "$p" ] && [ -f "$MAIN/$p" ] && [ ! -e "$WT/$p" ] || continue
			mkdir -p "$WT/$(dirname "$p")" && cp -p "$MAIN/$p" "$WT/$p" && copied=$((copied + 1))
		done <<EOF
$files
EOF
	fi
	echo "copied=$copied file(s) listed in .worktreeinclude"
	echo "setup_hint=$(setup_hint "$WT")"
	nested_setup "$WT" | while IFS="$(printf '\t')" read -r d c; do echo "setup_hint_dir=$d: $c"; done
	if [ "$SET_DEFAULT" -eq 1 ]; then
		g config ticket-dev.worktreeBase "$BASE"
		echo "default_base=$BASE (saved in this repository's local git config)"
	fi
	;;

*) die "unknown command '$CMD' (start, resume, list, status, diff, clean, claim, release, servers, bases, create)" ;;
esac
