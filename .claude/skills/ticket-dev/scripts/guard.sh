#!/usr/bin/env bash
# guard.sh MODE - PreToolUse hook that keeps a ticket-dev subagent inside its role.
#
#   explore    Bash limited to a read-only allowlist; no file edits
#   verify     may run checks; blocks edits, fixers, snapshot updates, installs,
#              git changes, deploys and database access
#   implement  may edit; blocks pushes/commits, discarding changes, history rewrites,
#              installs, migrations, database clients, deploys/publishing, and
#              credential files
#   browser    verify rules, plus: every URL (in commands and MCP browser tools) must
#              pass browser.conf's host allowlist, playwright-cli must use a named
#              session opened with the ticket's --config (artifacts outside the repo)
#              and never attach to a real browser or profile, dev servers start only through
#              browser-check.sh, and browser/skill installs are blocked
# All modes refuse to read or write secret files (.env, keys, credentials), and
# refuse to start Claude Code or Codex sessions or manage worktrees.
#
# As a hook it reads the PreToolUse JSON on stdin and exits 0 (allow) or 2
# (block; the reason on stderr goes back to the subagent).
# For tests:  guard.sh MODE --command CMD | --edit PATH | --read PATH
#
# This is a guardrail against mistakes, not a sandbox: it inspects command text
# and can be bypassed by deliberately obfuscated commands. Bash 3.2 compatible.

set -u
set -f

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-}
case "$MODE" in explore | verify | implement | browser) ;; *)
	echo "usage: guard.sh explore|verify|implement|browser [--command CMD | --edit PATH | --read PATH | --url URL]" >&2
	exit 2
	;;
esac
shift

TOOL=""
CMD=""
FPATH=""
URL=""
case "${1:-}" in
--command) TOOL=Bash; CMD=${2:-} ;;
--edit) TOOL=Edit; FPATH=${2:-} ;;
--read) TOOL=Read; FPATH=${2:-} ;;
--url) TOOL=mcp__browser__navigate; URL=${2:-} ;;
*)
	INPUT=$(cat)
	if command -v jq >/dev/null 2>&1 && [ -z "${TICKET_DEV_GUARD_NO_JQ:-}" ]; then
		TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
		CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
		FPATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
		URL=$(printf '%s' "$INPUT" | jq -r '.tool_input.url // empty' 2>/dev/null)
	else
		# Approximate extraction of a JSON string field without jq.
		extract() {
			printf '%s' "$INPUT" | tr '\n' ' ' |
				sed -n -E 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n 1 |
				sed -e 's/\\n/; /g' -e 's/\\t/ /g' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
		}
		TOOL=$(extract tool_name)
		CMD=$(extract command)
		FPATH=$(extract file_path)
		[ -n "$FPATH" ] || FPATH=$(extract notebook_path)
		URL=$(extract url)
	fi
	if [ -z "$TOOL" ]; then
		if [ -n "$CMD" ]; then TOOL=Bash; elif [ -n "$FPATH" ]; then TOOL=Edit; fi
	fi
	;;
esac

block() {
	echo "ticket-dev guard ($MODE): $1" >&2
	case "$MODE" in
	explore) echo "You are read-only. Use search/read commands only and report what you could not check." >&2 ;;
	*) echo "Do not work around this. Stop and report STATUS: BLOCKED with the exact command you need, so the developer can decide." >&2 ;;
	esac
	exit 2
}

is_secret_path() {
	_b=${1##*/}
	case "$_b" in
	*.example | *.sample | *.template | *.dist) return 1 ;;
	.env | .env.* | *.pem | *.key | *.p12 | *.pfx | *.jks | *.keystore | id_rsa | id_rsa.* | id_ed25519* | id_ecdsa* | \
		.npmrc | .pypirc | .netrc | .htpasswd | *.tfvars | *.tfstate | credentials | credentials.json | \
		*credentials*.json | service-account*.json | kubeconfig | *.kubeconfig) return 0 ;;
	esac
	case "$1" in */.aws/* | */.ssh/* | */.gnupg/* | */.kube/* | */.docker/config.json) return 0 ;; esac
	return 1
}

# ------------------------------------------------------------------ non-Bash tools

case "$TOOL" in
Bash) ;;
Read)
	[ -n "$FPATH" ] && is_secret_path "$FPATH" && block "secret files are not read by ticket-dev agents ($FPATH); use the .example file or ask the developer"
	exit 0
	;;
Edit | Write | MultiEdit | NotebookEdit)
	[ "$MODE" = implement ] || block "this agent does not edit files (${FPATH:-unknown path})"
	[ -n "$FPATH" ] && is_secret_path "$FPATH" && block "editing credential or secret files needs developer approval ($FPATH)"
	exit 0
	;;
*)
	# MCP browser tools (e.g. Claude in Chrome): only approved hosts may be opened.
	if [ "$MODE" = browser ] && [ -n "$URL" ]; then
		why=$(bash "$SCRIPT_DIR/browser-check.sh" url-allowed "$URL" 2>&1) || block "$why"
	fi
	exit 0
	;;
esac
[ -n "$CMD" ] || exit 0

# The browser verifier hands its report to `browser-check.sh save-report <<'EOF'`.
# The heredoc body is data written to the ticket's artifact dir, not commands, so
# only that exact first line is checked.
_first=$(printf '%s\n' "$CMD" | head -n 1)
if printf '%s' "$_first" | grep -Eq "^ *bash +[^ ;|&<>]*browser-check\.sh save-report( --required)? *<< *-?['\"]?[A-Za-z_]+['\"]? *$"; then
	CMD=$_first
fi

# ------------------------------------------------------------------ helpers

# Split a command into simple segments at ; && || | & ( ) $( ` and newlines.
segments() {
	printf '%s\n' "$1" | sed -E -e 's/[0-9]*>&[0-9]+//g' -e 's/&>/>/g' |
		awk '{ gsub(/\$\(|`|\(|\)|&&|\|\||;|\||&/, "\n"); print }'
}

# Replace quoted text with Q so quoted characters are not read as shell syntax.
mask_single() { printf '%s' "$1" | sed -E "s/'[^']*'/ Q /g"; }
mask_double() { printf '%s' "$1" | sed -E 's/"([^"\\]|\\.)*"/ Q /g'; }

# Targets of output redirections in a masked command.
redirect_targets() {
	printf '%s\n' "$1" | sed -E -e 's/[0-9]*>&[0-9]+//g' -e 's/&>/>/g' |
		grep -oE '>>?[[:space:]]*[^[:space:];|&<>()]*' | sed -E 's/^>>?[[:space:]]*//'
}

is_temp_target() {
	case "$1" in /dev/null | /dev/stdout | /dev/stderr | /tmp/* | /var/folders/*) return 0 ;; esac
	if [ -n "${TMPDIR:-}" ]; then
		case "$1" in "${TMPDIR%/}"/*) return 0 ;; esac
	fi
	return 1
}

# Refuse any command that names a secret file, except existence checks.
check_secret_words() {
	set -- $1
	case "${1:-}" in ls | test | "[" | stat) return 0 ;; esac
	for _w in "$@"; do
		case "$_w" in -*) continue ;; esac
		is_secret_path "$_w" && block "secret files are not read or written by ticket-dev agents ($_w)"
	done
	return 0
}

# ------------------------------------------------------------------ explore: allowlist

READ_CMDS=" grep egrep fgrep rg ag ack ls tree cat head tail wc sort uniq cut tr file stat du basename dirname realpath readlink pwd echo printf diff cmp jq nl column true false test [ cd which type strings od hexdump xxd md5sum sha1sum sha256sum shasum cksum date "
GIT_READ=" log show diff status grep ls-files ls-tree blame rev-parse cat-file shortlog describe merge-base rev-list name-rev show-ref for-each-ref count-objects check-ignore whatchanged "

explore_git() {
	shift # git
	while [ $# -gt 0 ]; do
		case "$1" in
		-C | -c) shift ;;
		-*) ;;
		*) break ;;
		esac
		shift
	done
	[ $# -gt 0 ] || return 0
	_sub=$1
	shift
	for _a in "$@"; do
		case "$_a" in --output | --output=*) block "git $_sub $_a writes a file" ;; esac
	done
	case "$GIT_READ" in *" $_sub "*) return 0 ;; esac
	case "$_sub:${1:-}" in
	stash:list | stash:show | reflog: | reflog:show | worktree:list | remote: | remote:-v | remote:show | remote:get-url) return 0 ;;
	tag: | tag:-l | tag:--list) return 0 ;;
	config:--get | config:--get-all | config:--list | config:-l | config:--get-regexp) return 0 ;;
	branch:*)
		_prev=""
		for _a in "$@"; do
			case "$_a" in
			-a | -r | -v | -vv | -l | --list | --all | --remotes | --verbose | --show-current | --contains | --no-contains | \
				--merged | --no-merged | --points-at | --sort=* | --format=* | --color* | --no-color | --column* | --no-column | --abbrev*) ;;
			-*) block "git branch $_a is not read-only" ;;
			*)
				case "$_prev" in
				--contains | --no-contains | --merged | --no-merged | --points-at | -l | --list) ;;
				*) block "git branch $_a would create a branch" ;;
				esac
				;;
			esac
			_prev=$_a
		done
		return 0
		;;
	esac
	block "'git $_sub${1:+ $1}' is not read-only"
}

explore_segment() {
	set -- $1
	while [ $# -gt 0 ]; do
		case "$1" in [A-Za-z_]*=*) shift ;; *) break ;; esac
	done
	[ $# -gt 0 ] || return 0
	_cmd=$1
	case "$_cmd" in
	find)
		_prev=""
		for _a in "$@"; do
			case "$_prev" in -exec | -execdir | -ok | -okdir)
				case " grep egrep fgrep rg cat head tail wc ls file stat " in *" $_a "*) ;; *) block "find $_prev $_a is not read-only" ;; esac
				;;
			esac
			case "$_a" in -delete | -fprint | -fprint0 | -fprintf | -fls) block "find $_a modifies files" ;; esac
			_prev=$_a
		done
		;;
	fd | fdfind)
		for _a in "$@"; do case "$_a" in -x | -X | --exec | --exec-batch) block "fd $_a runs commands" ;; esac; done
		;;
	sed)
		_n=0
		for _a in "$@"; do
			case "$_a" in
			-i* | --in-place*) block "sed -i edits files" ;;
			-n | --quiet | --silent) _n=1 ;;
			--*) ;;
			-*n*) _n=1 ;;
			esac
		done
		[ "$_n" -eq 1 ] || block "use sed -n (print only) in read-only mode"
		;;
	sort | tree)
		for _a in "$@"; do case "$_a" in -o | -o* | --output*) block "$_cmd $_a writes a file" ;; esac; done
		;;
	git) explore_git "$@" ;;
	xargs)
		shift
		while [ $# -gt 0 ]; do
			case "$1" in
			-n | -I | -L | -P | -d | -E | -s) shift ;;
			-*) ;;
			*) break ;;
			esac
			shift
		done
		[ $# -gt 0 ] || return 0
		case " grep egrep fgrep rg wc cat head tail ls file stat " in *" $1 "*) return 0 ;; esac
		block "xargs $1 is not read-only"
		;;
	*)
		case "$READ_CMDS" in *" $_cmd "*) return 0 ;; esac
		block "'$_cmd' is not in the read-only allowlist (allowed: grep, rg, find, ls, cat, head, tail, sed -n, wc, git log/show/diff/grep/blame/ls-files ...)"
		;;
	esac
	return 0
}

if [ "$MODE" = explore ]; then
	s1=$(mask_single "$CMD")
	case "$s1" in *'$('* | *'`'*) block "command substitution is not allowed in read-only mode" ;; esac
	s2=$(mask_double "$s1")
	targets=$(redirect_targets "$s2")
	for _t in $targets; do
		[ "$_t" = /dev/null ] || block "output redirection to '$_t' writes a file"
	done
	case "$s2" in *'>'*) [ -n "$targets" ] || block "output redirection is not allowed in read-only mode" ;; esac
	_oldifs=$IFS
	IFS='
'
	for seg in $(segments "$s2"); do
		IFS=$_oldifs
		check_secret_words "$seg"
		explore_segment "$seg"
	done
	IFS=$_oldifs
	exit 0
fi

# ------------------------------------------------------------------ verify / implement: denylist

# Command position: optional VAR=value words and wrappers (npx, pnpm exec, bash -c,
# run-check.sh NAME --, ...), so the command a wrapper runs is checked too.
P='^ *([A-Za-z_][A-Za-z0-9_]*=[^ ]* )*((sudo|doas|(bash )?[^ ]*run-check\.sh [A-Za-z0-9._-]+ --|npx|bunx|pnpx|yarn|pnpm|npm exec|pnpm exec|pnpm dlx|yarn dlx|bun x|bun run|uv run|poetry run|pipenv run|bundle exec|python3? -m|time|nice|nohup|env|command|exec|xargs|timeout [0-9]+[smh]?|bash -c|sh -c|zsh -c)( -[^ ]+)* )*'
G='git( -[cC] [^ ]+| -[^ ]+)*'

# modes@@extended-regex@@reason
#   i = implement, v = verify (and browser), b = browser only,
#   c = skip when --check/--diff/--dry-run is present
#   @P@ = command position (after VAR=value words and wrappers), @G@ = git plus global options
RULES='
iv@@@P@(sudo|doas|su)( |$)@@privilege escalation is never automatic
iv@@@P@@G@ (push|commit|reset|checkout|restore|stash|clean|rebase|merge|cherry-pick|revert|am|pull|tag|switch|rm|apply|add|update-ref|filter-branch|filter-repo|gc|prune|worktree|submodule|init|clone|replace|notes)( |$)@@git index, history, remote and working-tree changes are reserved for the developer (pre-existing changes must be preserved)
iv@@@P@@G@ branch( [^ ]+)* (-d|-D|-m|-M|-f|-c|-C|--delete|--move|--force|--copy)( |$)@@branch changes are reserved for the developer
v@@@P@@G@ mv( |$)@@the verifier does not change files
iv@@@P@find( [^ ]+)* (-delete|-fprint|-fprint0|-fprintf|-fls)( |$)@@find would delete or write files
iv@@@P@find( [^ ]+)* -(exec|execdir|ok|okdir) (rm|mv|shred|unlink|chmod|chown|sed)( |$)@@find -exec would modify files
i@@@P@rm( [^ ]+)* (-[a-zA-Z]*[rRf][a-zA-Z]*|--recursive|--force)( |$)@@recursive or forced deletion needs developer approval; delete individual files named in the contract with plain rm
i@@@P@rm( [^ ]+)* ([^ ]*[*?][^ ]*|/|~|~/[^ ]*|\.|\.\.|\./|\.\./[^ ]*)( |$)@@wildcard or broad deletion needs developer approval
v@@@P@(rm|rmdir|unlink|shred|truncate|dd|mv|cp|touch|ln|tee|install|mkdir|patch)( |$)@@the verifier does not change files
v@@@P@sed( [^ ]+)* (-i[^ ]*|--in-place[^ ]*)( |$)@@the verifier does not change files
v@@@P@perl( [^ ]+)* -[a-zA-Z]*i[^ ]*( |$)@@the verifier does not change files
v@@ (--fix|--fix-type[^ ]*|--write|--apply|--apply-unsafe)( |=|$)@@auto-fixers change files; report the failure instead
v@@@P@(gofmt|goimports)( [^ ]+)* -w( |$)@@formatters that write change files
v@@@P@go (fmt|generate)( |$)@@the verifier does not change files
vc@@@P@(black|isort|rustfmt|ruff format|cargo fmt|dart format|terraform fmt|biome format)( |$)@@formatters change files; add --check to only report
v@@@P@(jest|vitest|playwright|npm|pnpm|yarn|bun|go|pytest|cargo)( [^ ]+)* (-u|--update|--update-snapshots?|--updateSnapshot|-update|--snapshot-update)( |$)@@updating snapshots or golden files hides failures; report them instead
v@@@P@(npm|pnpm|bun) run [^ ]*(fix|format|fmt|prettify)[^ ]*( |$)@@format/fix scripts change files
v@@@P@(yarn|pnpm) [^ ]*(fix|format|fmt|prettify)[^ ]*( |$)@@format/fix scripts change files
v@@@P@make [^ ]*(fmt|format|fix|generate)[^ ]*( |$)@@the verifier does not change files
iv@@@P@(npm|pnpm|yarn|bun)( -[^ ]+( [^ -][^ ]*)?)* (install|i|ci|add|remove|rm|uninstall|update|upgrade|up|link|unlink|dedupe|prune)( |$)@@installing or changing dependencies needs developer approval
iv@@^ *yarn *$@@installing dependencies needs developer approval
iv@@@P@(npm|pnpm|yarn)( [^ ]+)* (-g|--global)( |$)@@global installs are never automatic
iv@@@P@(pip|pip3)( -[^ ]+)* (install|uninstall|download)( |$)@@installing or changing dependencies needs developer approval
iv@@ -m pip (install|uninstall)( |$)@@installing or changing dependencies needs developer approval
iv@@@P@uv (add|remove|sync|lock|pip install|tool install)( |$)@@installing or changing dependencies needs developer approval
iv@@@P@poetry (add|remove|install|update|lock)( |$)@@installing or changing dependencies needs developer approval
iv@@@P@go (get|install|mod tidy|mod download|mod vendor|work sync)( |$)@@changing Go dependencies needs developer approval
iv@@@P@cargo (add|remove|install|update|uninstall)( |$)@@changing Rust dependencies needs developer approval
iv@@@P@(gem install|bundle install|bundle update|bundle add|composer install|composer require|composer update|composer remove|pipx install)( |$)@@installing or changing dependencies needs developer approval
iv@@@P@(brew|apt|apt-get|dnf|yum|apk|pacman|port|snap|choco|winget)( |$)@@system package changes are never automatic
iv@@@P@prisma (migrate|db push|db execute|db seed)( |$)@@applying migrations or touching a database needs developer approval
iv@@@P@drizzle-kit (push|migrate|drop|up)( |$)@@applying migrations needs developer approval
iv@@@P@knex( [^ ]+)* (migrate:[a-z]+|seed:run)( |$)@@applying migrations needs developer approval
iv@@@P@sequelize( [^ ]+)* db:[a-z:]+( |$)@@applying migrations needs developer approval
iv@@@P@typeorm( [^ ]+)* (migration:run|migration:revert|schema:sync|schema:drop)( |$)@@applying migrations needs developer approval
iv@@@P@mikro-orm( [^ ]+)* (migration:up|migration:down|schema:update|schema:drop|schema:fresh)( |$)@@applying migrations needs developer approval
iv@@@P@(rails|rake|bin/rails)( [^ ]+)* db:[a-z:_]+( |$)@@database tasks need developer approval
iv@@ manage\.py (migrate|flush|loaddata|sqlflush|dbshell)( |$)@@database tasks need developer approval
iv@@@P@alembic (upgrade|downgrade|stamp)( |$)@@applying migrations needs developer approval
iv@@@P@(flyway|liquibase|sqitch|dbmate|goose|atlas|hasura)( |$)@@migration tools need developer approval
iv@@@P@migrate( [^ ]+)* (up|down|drop|force|goto)( |$)@@applying migrations needs developer approval
iv@@@P@supabase (db push|db reset|migration up|migration repair)( |$)@@database changes need developer approval
iv@@@P@(npm|pnpm|bun) run [^ ]*(migrat|deploy|release|publish|db:reset|db:drop|db:push|seed)[^ ]*( |$)@@migration, seed, deploy and release scripts need developer approval
iv@@@P@(yarn|pnpm) [^ ]*(migrat|deploy|release|db:reset|db:drop|db:push|seed)[^ ]*( |$)@@migration, seed, deploy and release scripts need developer approval
iv@@@P@make [^ ]*(migrat|deploy|release|publish|db-)[^ ]*( |$)@@migration, deploy and release targets need developer approval
iv@@@P@(psql|mysql|mariadb|sqlite3|mongosh|mongo|redis-cli|cqlsh|sqlcmd|clickhouse-client)( |$)@@direct database access needs developer approval
iv@@@P@(npm|pnpm|yarn|bun|cargo|poetry|uv|gem)( [^ ]+)* publish( |$)@@publishing is never automatic
iv@@@P@(twine upload|gem push)( |$)@@publishing is never automatic
iv@@@P@docker( [^ ]+)* (push|login|system prune|volume rm|volume prune|image prune)( |$)@@registry and volume changes need developer approval
iv@@@P@docker( [^ ]+)* down( [^ ]+)* (-v|--volumes)( |$)@@removing volumes destroys data
iv@@@P@kubectl( [^ ]+)* (apply|delete|create|replace|patch|scale|rollout|drain|cordon|edit|set|label|annotate|exec)( |$)@@cluster changes are never automatic
iv@@@P@helm (install|upgrade|uninstall|delete|rollback)( |$)@@cluster changes are never automatic
iv@@@P@(terraform|tofu) (apply|destroy|import|taint|state)( |$)@@infrastructure changes are never automatic
iv@@@P@pulumi (up|destroy|refresh|import)( |$)@@infrastructure changes are never automatic
iv@@@P@(vercel|netlify|fly|flyctl|heroku|railway|firebase|amplify|serverless|sls|cdk|sam|wrangler)( [^ ]+)* (deploy|publish|--prod|up|destroy|release|rollback)( |$)@@deployments are never automatic
iv@@@P@(aws|gcloud|az|doctl|oci|ibmcloud|gh|glab|stripe|twilio)( |$)@@cloud, forge and vendor CLIs can change shared or production state; ask the developer
iv@@@P@(ssh|scp|sftp)( |$)@@remote access is never automatic
iv@@@P@curl( [^ ]+)* (-X ?|--request )(POST|PUT|PATCH|DELETE)( |$)@@mutating HTTP requests need developer approval
iv@@@P@curl( [^ ]+)* (-d|--data[^ ]*|-F|--form|-T|--upload-file)( |$)@@mutating HTTP requests need developer approval
iv@@@P@wget( [^ ]+)* (--post-data|--post-file|--method|--body-data)[^ ]*( |$)@@mutating HTTP requests need developer approval
iv@@@P@(chown|chgrp)( |$)@@ownership changes are never automatic
iv@@@P@chmod( [^ ]+)* -R( |$)@@recursive permission changes need developer approval
iv@@@P@(kill|pkill|killall|shutdown|reboot|halt|fdisk|diskutil|launchctl|systemctl|crontab)( |$)@@system and process control is never automatic
iv@@@P@(claude|codex)( |$)@@starting Claude Code or Codex sessions is reserved for the developer and the orchestrator
iv@@@P@(bash )?[^ ]*(codex-review|ticket-worktree)\.sh( |$)@@cross-model review and worktree management are reserved for the orchestrator and the developer
iv@@@P@(playwright|playwright-cli)( [^ ]+)* install[^ ]*( |$)@@installing browsers or agent skills needs developer approval
b@@@P@((npm|pnpm|bun) run|yarn|pnpm|npm) (dev|start|serve|preview)( |$)@@start the dev server with browser-check.sh server start (port, logs and cleanup per ticket)
b@@@P@(next|vite|nuxt|astro|ng) (dev|start|serve|preview)( |$)@@start the dev server with browser-check.sh server start (port, logs and cleanup per ticket)
iv@@@P@mkfs[^ ]*( |$)@@system and process control is never automatic
'

# Expand the placeholders once (bash substitution; P and G contain no '&' or '\').
RULES=${RULES//@P@/$P}
RULES=${RULES//@G@/$G}

check_segment() {
	_seg=" $(printf '%s' "$1" | tr -d "\"'" | tr -s '[:space:]' ' ') "
	check_secret_words "$_seg"
	_oldifs2=$IFS
	IFS='
'
	for _rule in $RULES; do
		IFS=$_oldifs2
		_modes=${_rule%%@@*}
		_rest=${_rule#*@@}
		_re=${_rest%%@@*}
		_why=${_rest#*@@}
		case "$MODE:$_modes" in implement:*i* | verify:*v* | browser:*v* | browser:*b*) ;; *) continue ;; esac
		case "$_modes:$_seg" in *c*:*" --check "* | *c*:*" --diff "* | *c*:*" --dry-run "*) continue ;; esac
		if printf '%s' "$_seg" | grep -Eq -- "$_re"; then
			_shown=$(printf '%s' "$_seg" | sed -E -e 's/^ +//' -e 's/ +$//' | cut -c1-120)
			block "blocked '$_shown': $_why"
		fi
	done
	IFS=$_oldifs2
	return 0
}

# Browser mode: URLs must be approved, and playwright-cli must write its snapshots and
# screenshots to the ticket's artifact dir (browser-check.sh env prints the command).
browser_segment() {
	_bs=" $(printf '%s' "$1" | tr -d "\"'" | tr -s '[:space:]' ' ') "
	if printf '%s' "$_bs" | grep -Eq -- "$P[^ ]*(playwright-cli|playwright|curl|wget|http|https|xh|lynx|w3m|open|xdg-open)( |$)"; then
		for _w in $_bs; do
			case "$_w" in http://* | https://* | HTTP://* | HTTPS://* | *=http://* | *=https://*)
				_why=$(bash "$SCRIPT_DIR/browser-check.sh" url-allowed "${_w#*=}" 2>&1) || block "$_why"
				;;
			esac
		done
	fi
	if printf '%s' "$_bs" | grep -Eq -- "$P[^ ]*playwright-cli( |$)"; then
		case "$_bs" in *" -s="* | *" --session="*) ;; *)
			block "use the ticket's named session: exploratory_cmd from browser-check.sh env (playwright-cli -s=...)" ;;
		esac
		case "$_bs" in *" open "*)
			case "$_bs" in *" --config "* | *" --config="*) ;; *)
				block "open the session with exploratory_open from browser-check.sh env (--config keeps artifacts outside the repository)" ;;
			esac
			;;
		esac
		case "$_bs" in *" attach "* | *" --persistent "* | *" --profile "* | *" --profile="* | *" --extension "*)
			block "do not attach to a real browser or use a persistent profile; the ticket uses an isolated in-memory session" ;;
		esac
	fi
	return 0
}

# Redirections, with quoted text masked so '=>' in a search pattern is not a redirect.
masked=$(mask_double "$(mask_single "$CMD")")
for _t in $(redirect_targets "$masked"); do
	if [ "$MODE" = verify ] || [ "$MODE" = browser ]; then
		is_temp_target "$_t" || block "the verifier may only redirect output to /dev/null or a temp directory (got '$_t')"
	else
		is_secret_path "$_t" && block "writing credential or secret files needs developer approval ($_t)"
	fi
done

_oldifs=$IFS
IFS='
'
for seg in $(segments "$CMD"); do
	IFS=$_oldifs
	check_segment "$seg"
	[ "$MODE" = browser ] && browser_segment "$seg"
done
IFS=$_oldifs
exit 0
