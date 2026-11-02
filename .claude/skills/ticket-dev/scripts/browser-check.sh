#!/usr/bin/env bash
# browser-check.sh - deterministic support for /ticket-dev browser verification.
#
#   browser-check.sh config [--summary]          resolved browser.conf settings
#   browser-check.sh detect --baseline SHA [--untracked-at-baseline BLOB|none] [--override on|off]
#                                                should this ticket get browser verification?
#   browser-check.sh env                         URL, tools, artifact dir, commands to use
#   browser-check.sh server start|status|stop    the project-defined dev server for this ticket
#   browser-check.sh url-allowed URL             exit 0 if the URL may be opened
#   browser-check.sh validate-report FILE [--required]
#                                                reject reports that claim more than they show
#   browser-check.sh save-report [--required] < REPORT
#                                                store the report in the artifact dir, then validate it
# Common option: --project-dir DIR (default: git root or $PWD).
#
# Never installs anything and never browses: the ticket-dev-browser-verifier agent
# does the interaction; this script decides, prepares and checks. Artifacts and the
# server log go to the ticket's private temp dir, never into the repository.
# Exit codes: 0 ok, 1 no / invalid, 2 usage, 3 unavailable, 4 failed or timed out.
# Env (tests): TICKET_DEV_PLAYWRIGHT_CLI. Bash 3.2 compatible.

set -u
set -f

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SKILL_DIR=$(dirname "$SCRIPT_DIR")

die() { echo "browser-check.sh: $*" >&2; exit 2; }

CMD=${1:-}
[ -n "$CMD" ] || { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
case "$CMD" in -h | --help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

SUB=""
ARG=""
SUMMARY=0
BASE=""
REC=none
OVERRIDE=""
REQUIRED_FLAG=0
PROJECT_DIR=""
while [ $# -gt 0 ]; do
	case "$1" in
	--summary) SUMMARY=1 ;;
	--baseline) BASE=${2:-}; shift ;;
	--untracked-at-baseline) REC=${2:-none}; shift ;;
	--override) OVERRIDE=${2:-}; shift ;;
	--required) REQUIRED_FLAG=1 ;;
	--project-dir) PROJECT_DIR=${2:-}; shift ;;
	-*) die "unknown option $1" ;;
	*) if [ -z "$SUB" ] && [ "$CMD" = server ]; then SUB=$1; else ARG=$1; fi ;;
	esac
	shift
done

[ -n "$PROJECT_DIR" ] || PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
ROOT=$(cd "$PROJECT_DIR" 2>/dev/null && pwd) || die "cannot enter $PROJECT_DIR"

# ------------------------------------------------------------------ config
BROWSER_VERIFICATION=off
BROWSER_BASE_URL='http://127.0.0.1:{port}'
BROWSER_ALLOWED_HOSTS='localhost,127.0.0.1,::1'
BROWSER_DEV_COMMAND=''
BROWSER_READY_TIMEOUT=90
BROWSER_DESKTOP_VIEWPORT=1280x800
BROWSER_MOBILE_VIEWPORT=390x844
BROWSER_FRONTEND_PATHS=''
BROWSER_E2E_COMMAND=''
SOURCES=""
WARNINGS=""
warn() { WARNINGS="${WARNINGS:+$WARNINGS; }$1"; }

load_conf() { # KEY=value; leading/trailing blanks trimmed, inner spaces kept, nothing executed
	[ -f "$1" ] || return 0
	SOURCES="${SOURCES:+$SOURCES }$1"
	while IFS= read -r _line || [ -n "$_line" ]; do
		_t=$(printf '%s' "$_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
		case "$_t" in '' | '#'*) continue ;; *=*) ;; *) warn "ignored line without '=' in $1"; continue ;; esac
		_key=${_t%%=*}
		_val=${_t#*=}
		case "$_key" in
		BROWSER_VERIFICATION)
			case "$_val" in off | auto | required) BROWSER_VERIFICATION=$_val ;; *) warn "ignored invalid BROWSER_VERIFICATION=$_val in $1" ;; esac ;;
		BROWSER_READY_TIMEOUT)
			case "$_val" in '' | *[!0-9]*) warn "ignored invalid BROWSER_READY_TIMEOUT=$_val in $1" ;; *) BROWSER_READY_TIMEOUT=$_val ;; esac ;;
		BROWSER_DESKTOP_VIEWPORT | BROWSER_MOBILE_VIEWPORT)
			if printf '%s' "$_val" | grep -Eq '^[0-9]+x[0-9]+$'; then eval "$_key=\$_val"; else warn "ignored invalid $_key=$_val in $1"; fi ;;
		BROWSER_BASE_URL | BROWSER_ALLOWED_HOSTS | BROWSER_DEV_COMMAND | BROWSER_FRONTEND_PATHS | BROWSER_E2E_COMMAND)
			eval "$_key=\$_val" ;;
		*) warn "ignored unknown key $_key in $1" ;;
		esac
	done <"$1"
}
load_conf "$SKILL_DIR/browser.conf"
load_conf "$ROOT/.claude/ticket-dev/browser.conf"

envval() { printf '%s\n' "$TENV" | sed -n "s/^$1=//p"; }
TENV=$(bash "$SCRIPT_DIR/ticket-env.sh" "$ROOT" 2>/dev/null)
PORT=$(envval port)
TMPD=$(envval tmp)
KEY=$(envval ticket_key)
[ -n "$TMPD" ] || TMPD="${TMPDIR:-/tmp}/ticket-dev/unknown"
ART="$TMPD/browser"
subst() { printf '%s' "$1" | sed "s/{port}/$PORT/g"; }
URL=$(subst "$BROWSER_BASE_URL")
DEV_CMD=$(subst "$BROWSER_DEV_COMMAND")

# ------------------------------------------------------------------ url policy
url_host() { # scheme://[user@]host[:port][/...] -> host (lowercase, no brackets)
	printf '%s' "$1" | sed -n -E 's#^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*@)?(\[[^]]*\]|[^]:/?#[]*).*#\2#p' |
		tr -d '[]' | tr '[:upper:]' '[:lower:]'
}
url_allowed() { # URL -> 0 allowed; prints the reason when not
	case "$1" in
	about:blank) return 0 ;;
	http://* | https://* | HTTP://* | HTTPS://*) ;;
	*) echo "scheme not allowed (only http and https to approved hosts): $1"; return 1 ;;
	esac
	_h=$(url_host "$1")
	[ -n "$_h" ] || { echo "cannot read the host of $1"; return 1; }
	case "$_h" in *.localhost) return 0 ;; esac
	for _a in $(printf '%s' "$BROWSER_ALLOWED_HOSTS" | tr ',' ' '); do
		[ "$_h" = "$(printf '%s' "$_a" | tr '[:upper:]' '[:lower:]')" ] && return 0
	done
	echo "host '$_h' is not in BROWSER_ALLOWED_HOSTS ($BROWSER_ALLOWED_HOSTS); production and external sites are not browsed"
	return 1
}

# ------------------------------------------------------------------ server helpers
PIDFILE="$ART/server.pid"
SLOG="$ART/server.log"
responds() { # URL answers with any HTTP status
	if command -v curl >/dev/null 2>&1; then
		_code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$1" 2>/dev/null)
		[ -n "$_code" ] && [ "$_code" != 000 ]
		return
	fi
	_h=$(url_host "$1")
	_p=$(printf '%s' "$1" | sed -n -E 's#^[a-z]+://[^/]*:([0-9]+).*#\1#p')
	[ -n "$_p" ] || case "$1" in https://*) _p=443 ;; *) _p=80 ;; esac
	(exec 3<>"/dev/tcp/$_h/$_p") 2>/dev/null
}
alive() { # a zombie (exited, not yet reaped by this script) is not alive
	kill -0 "$1" 2>/dev/null || return 1
	case "$(ps -o stat= -p "$1" 2>/dev/null)" in *Z*) return 1 ;; esac
	return 0
}
our_pid() { [ -f "$PIDFILE" ] && _p=$(cat "$PIDFILE") && alive "$_p" && echo "$_p"; }
stop_server() {
	_p=$(our_pid) || { rm -f "$PIDFILE"; return 0; }
	kill -TERM -- "-$_p" 2>/dev/null || kill -TERM "$_p" 2>/dev/null
	_i=0
	while alive "$_p" && [ "$_i" -lt 10 ]; do sleep 0.5; _i=$((_i + 1)); done
	alive "$_p" && { kill -KILL -- "-$_p" 2>/dev/null || kill -KILL "$_p" 2>/dev/null; }
	rm -f "$PIDFILE"
	echo "server: stopped pid $_p (started by this ticket)"
}

# ------------------------------------------------------------------ change detection
is_test_path() {
	case "/$1" in
	*.test.* | *.spec.* | */__tests__/* | */test/* | */tests/* | */e2e/* | */cypress/* | */playwright/* | *.stories.* | *.snap) return 0 ;;
	esac
	return 1
}
is_frontend_path() {
	_p=$1
	for _pat in $(printf '%s' "$BROWSER_FRONTEND_PATHS" | tr ',' ' '); do
		case "$_p" in $_pat) return 0 ;; esac
	done
	is_test_path "$_p" && return 1
	case "$_p" in
	*.tsx | *.jsx | *.vue | *.svelte | *.astro | *.html | *.htm | *.css | *.scss | *.sass | *.less | *.styl) return 0 ;;
	next.config.* | */next.config.* | vite.config.* | */vite.config.* | nuxt.config.* | svelte.config.* | astro.config.* | \
		tailwind.config.* | */tailwind.config.* | postcss.config.* | */postcss.config.*) return 0 ;;
	public/* | */public/* | static/* | */static/*) return 0 ;;
	esac
	case "$_p" in
	*.ts | *.js | *.mjs | *.cjs | *.mts)
		case "/$_p" in
		*/app/* | */pages/* | */components/* | */views/* | */layouts/* | */hooks/* | */client/* | */frontend/* | \
			*/web/* | */ui/* | */styles/* | */store/* | */stores/* | */composables/*) return 0 ;;
		esac
		;;
	esac
	return 1
}
web_frameworks() { # prints frameworks found in package.json files (depth <= 3)
	find "$ROOT" -maxdepth 3 -name package.json -not -path '*/node_modules/*' 2>/dev/null |
		xargs grep -hoE '"(next|react-dom|vue|nuxt|svelte|@sveltejs/kit|astro|@angular/core|solid-js|preact|@remix-run/react|gatsby|vite)"[[:space:]]*:' 2>/dev/null |
		sed -E 's/^"([^"]*)".*/\1/' | sort -u | tr '\n' ' ' | sed 's/ $//'
	for _f in index.html public/index.html src/index.html; do
		[ -f "$ROOT/$_f" ] && { echo " html:$_f"; break; }
	done
}

# ------------------------------------------------------------------ commands
case "$CMD" in
config)
	if [ "$SUMMARY" -eq 1 ]; then
		echo "browser: BROWSER_VERIFICATION=$BROWSER_VERIFICATION url=$URL dev_command=${DEV_CMD:-none} (sources: ${SOURCES:-defaults})${WARNINGS:+ warnings: $WARNINGS}"
		exit 0
	fi
	echo "sources=${SOURCES:-none (built-in defaults)}"
	echo "BROWSER_VERIFICATION=$BROWSER_VERIFICATION"
	echo "url=$URL"
	echo "allowed_hosts=$BROWSER_ALLOWED_HOSTS,*.localhost"
	echo "dev_command=${DEV_CMD:-none}"
	echo "ready_timeout=$BROWSER_READY_TIMEOUT"
	echo "viewports=desktop $BROWSER_DESKTOP_VIEWPORT, mobile $BROWSER_MOBILE_VIEWPORT"
	echo "frontend_paths=${BROWSER_FRONTEND_PATHS:-none}"
	echo "warnings=$WARNINGS"
	;;

detect)
	[ -n "$BASE" ] || die "detect needs --baseline SHA (from preflight)"
	case "$OVERRIDE" in '' | on | off) ;; *) die "--override must be on or off" ;; esac
	mode=$BROWSER_VERIFICATION
	src="browser.conf"
	[ "$OVERRIDE" = on ] && { mode=required; src="--browser for this ticket"; }
	[ "$OVERRIDE" = off ] && { mode=off; src="--no-browser for this ticket"; }
	changes=$(bash "$SCRIPT_DIR/ticket-env.sh" --changed-files --baseline "$BASE" --untracked-at-baseline "$REC" "$ROOT") ||
		{ echo "decision=skip"; echo "reason=cannot list the ticket's changes (bad baseline?)"; exit 1; }
	fe=""
	n=0
	total=0
	oldifs=$IFS
	IFS='
'
	for line in $changes; do
		IFS=$oldifs
		case "$line" in changed\ * | new\ *) ;; *) continue ;; esac
		p=${line#* }
		total=$((total + 1))
		if is_frontend_path "$p"; then
			n=$((n + 1))
			[ "$n" -le 8 ] && fe="${fe:+$fe, }$p"
		fi
	done
	IFS=$oldifs
	[ "$n" -gt 8 ] && fe="$fe, ... $((n - 8)) more"
	fw=$(web_frameworks)
	echo "mode=$mode ($src)"
	echo "web_project=$([ -n "$fw" ] && echo "yes ($fw)" || echo no)"
	echo "changed_files=$total"
	echo "frontend_changes=$n${fe:+: $fe}"
	required=no
	case "$mode" in
	off)
		echo "decision=skip"
		if [ "$n" -gt 0 ] && [ -n "$fw" ] && [ -z "$OVERRIDE" ]; then
			echo "reason=disabled (BROWSER_VERIFICATION=off) although browser-facing files changed; use --browser or set auto"
		else
			echo "reason=disabled ($src)"
		fi
		;;
	auto)
		if [ -z "$fw" ]; then
			echo "decision=skip"; echo "reason=not a web project (no web framework or index.html found)"
		elif [ "$n" -eq 0 ]; then
			echo "decision=skip"; echo "reason=no browser-facing files changed (backend, tests, docs or config only)"
		else
			echo "decision=run"; echo "reason=browser-facing files changed in a web project"
		fi
		;;
	required)
		required=yes
		echo "decision=run"
		echo "reason=required ($src)$([ -z "$fw" ] && echo '; warning: no web framework detected')"
		;;
	esac
	echo "required=$required"
	;;

env)
	mkdir -p "$ART" 2>/dev/null
	allowed_msg=$(url_allowed "$URL") && ok=yes || ok=no
	echo "url=$URL"
	echo "url_allowed=$ok${allowed_msg:+ ($allowed_msg)}"
	echo "artifacts=$ART"
	echo "viewports=desktop $BROWSER_DESKTOP_VIEWPORT, mobile $BROWSER_MOBILE_VIEWPORT"
	echo "dev_command=${DEV_CMD:-none}"
	if our_pid >/dev/null; then echo "server=running (started by this ticket, pid $(our_pid))"
	elif responds "$URL"; then echo "server=responding (not started by ticket-dev)"
	else echo "server=down"; fi

	# Exploratory: Playwright CLI (agent-driven, headless by default).
	pcli=${TICKET_DEV_PLAYWRIGHT_CLI:-}
	if [ -z "$pcli" ]; then
		if command -v playwright-cli >/dev/null 2>&1; then pcli=playwright-cli
		elif [ -x "$ROOT/node_modules/.bin/playwright-cli" ]; then pcli="$ROOT/node_modules/.bin/playwright-cli"; fi
	fi
	session="td-$(printf '%s' "${KEY:-ticket}" | tr -c 'A-Za-z0-9-' '-' | cut -c1-40)"
	if [ -n "$pcli" ] && command -v "$pcli" >/dev/null 2>&1; then
		ver=$("$pcli" --version 2>/dev/null </dev/null | head -n 1)
		conf="$ART/playwright-cli.json"
		printf '{\n  "outputDir": "%s"\n}\n' "$ART" >"$conf"
		echo "exploratory=playwright-cli ${ver:-(version unknown)}"
		# --config is an option of `open` only; it binds the session's outputDir, so later
		# commands on the same -s= session write their default artifacts there too.
		echo "exploratory_open=$pcli -s=$session open --config $conf"
		echo "exploratory_cmd=$pcli -s=$session"
	else
		echo "exploratory=unavailable"
		echo "setup=exploratory: npm install -g @playwright/cli@latest (Node 18+), then playwright-cli install-browser chromium (developer runs these; the workflow never installs)"
	fi
	echo "chrome=optional: if this session was started with 'claude --chrome' and the Claude in Chrome extension is connected, mcp__claude-in-chrome__* tools can be used instead"

	# Repeatable: Playwright Test (or a project-defined command).
	if [ -n "$BROWSER_E2E_COMMAND" ]; then
		echo "e2e_cmd=$(subst "$BROWSER_E2E_COMMAND")"
	else
		cfg=""
		for f in playwright.config.ts playwright.config.js playwright.config.mjs playwright.config.cjs; do
			[ -f "$ROOT/$f" ] && { cfg=$f; break; }
		done
		if [ -z "$cfg" ]; then
			echo "e2e=none (no playwright.config.* and no BROWSER_E2E_COMMAND)"
		elif [ -x "$ROOT/node_modules/.bin/playwright" ]; then
			echo "e2e_cmd=npx playwright test --reporter=line --output $ART/test-results"
			echo "e2e_note=$cfg found; its baseURL/webServer settings decide which server the suite uses"
		else
			echo "e2e=unavailable ($cfg found but node_modules/.bin/playwright is missing; dependencies are not installed)"
		fi
	fi
	;;

server)
	mkdir -p "$ART" 2>/dev/null
	case "$SUB" in
	status)
		if p=$(our_pid); then echo "server: running (pid $p, started by this ticket)"
		elif responds "$URL"; then echo "server: responding at $URL (not started by ticket-dev)"
		else echo "server: down at $URL"; exit 1; fi
		;;
	stop)
		if our_pid >/dev/null; then stop_server; else rm -f "$PIDFILE"; echo "server: nothing started by this ticket is running (other servers are left alone)"; fi
		;;
	start)
		msg=$(url_allowed "$URL") || { echo "server: refused: $msg"; exit 4; }
		if p=$(our_pid) && responds "$URL"; then echo "server: running at $URL (pid $p, started by this ticket)"; exit 0; fi
		if responds "$URL"; then
			if [ -z "$DEV_CMD" ]; then
				echo "server: reused at $URL (already responding; not started by ticket-dev, left running)"
				exit 0
			fi
			echo "server: refused: something not started by this ticket already answers at $URL (another ticket's server?). Stop it, or set TICKET_DEV_PORT for this session."
			exit 4
		fi
		[ -n "$DEV_CMD" ] || { echo "server: unavailable: nothing answers at $URL and BROWSER_DEV_COMMAND is not configured"; exit 3; }
		# The dev command comes from project config; still refuse anything the verifier
		# guard would block (deploys, migrations, installs, database clients...).
		if ! why=$(bash "$SCRIPT_DIR/guard.sh" verify --command "$DEV_CMD" 2>&1); then
			echo "server: refused: BROWSER_DEV_COMMAND is blocked by the guard: $(printf '%s' "$why" | head -n 1)"
			exit 4
		fi
		set -m # own process group, so stop also ends the server's children
		(cd "$ROOT" && PORT=$PORT exec nohup sh -c "$DEV_CMD" >"$SLOG" 2>&1 </dev/null) &
		pid=$!
		set +m
		echo "$pid" >"$PIDFILE"
		i=0
		while [ "$i" -lt "$BROWSER_READY_TIMEOUT" ]; do
			if ! alive "$pid"; then
				rm -f "$PIDFILE"
				echo "server: FAILED: the dev command exited before $URL answered (log: $SLOG)"
				tail -n 15 "$SLOG" 2>/dev/null | cut -c1-200 | sed 's/^/  /'
				exit 4
			fi
			if responds "$URL"; then echo "server: started at $URL (pid $pid, ready after ${i}s, log: $SLOG)"; exit 0; fi
			sleep 1
			i=$((i + 1))
		done
		stop_server >/dev/null
		echo "server: TIMEOUT: $URL did not answer within ${BROWSER_READY_TIMEOUT}s; stopped it (log: $SLOG)"
		tail -n 15 "$SLOG" 2>/dev/null | cut -c1-200 | sed 's/^/  /'
		exit 4
		;;
	*) die "server needs start, status or stop" ;;
	esac
	;;

url-allowed)
	[ -n "$ARG" ] || die "url-allowed needs a URL"
	if msg=$(url_allowed "$ARG"); then echo "allowed: $ARG"; exit 0; fi
	echo "refused: $msg"
	exit 1
	;;

save-report)
	mkdir -p "$ART" 2>/dev/null
	cat >"$ART/report.md"
	echo "saved: $ART/report.md"
	set -- validate-report "$ART/report.md"
	[ "$REQUIRED_FLAG" -eq 1 ] && set -- "$@" --required
	exec bash "$0" "$@" --project-dir "$ROOT"
	;;

validate-report)
	[ -n "$ARG" ] && [ -f "$ARG" ] || die "validate-report needs a report file"
	parsed=$(awk '
		function flush() {
			if (!inj) return
			nj++
			r = toupper(res); sub(/^[[:space:]]+/, "", r)
			if (r ~ /^PASS/) { np++; kind = "PASS" } else if (r ~ /^FAIL/) { nf++; kind = "FAIL" } else { no++; kind = "OTHER" }
			e = ev; gsub(/^[[:space:]]+|[[:space:]]+$/, "", e)
			le = tolower(e)
			if ((kind == "PASS" || kind == "FAIL") && (e == "" || le == "none" || le == "n/a" || le == "-")) print "noevidence " nj
			if (kind == "PASS" && (obs == "" )) print "noobserved " nj
			n = split(e, w, /[[:space:],;()]+/)
			for (i = 1; i <= n; i++) if (w[i] ~ /^\//) print "path " w[i]
			inj = 0; res = ""; ev = ""; obs = ""
		}
		/^BROWSER VERIFICATION:/ && status == "" { s = $0; sub(/^BROWSER VERIFICATION:[[:space:]]*/, "", s); split(s, a, /[[:space:]|]+/); status = a[1] }
		/^[[:space:]]*-[[:space:]]*Scenario:/ { flush(); inj = 1; next }
		inj && /^[[:space:]]*Result:/ { res = $0; sub(/^[[:space:]]*Result:/, "", res); next }
		inj && /^[[:space:]]*Observed:/ { obs = $0; sub(/^[[:space:]]*Observed:[[:space:]]*/, "", obs); next }
		inj && /^[[:space:]]*Evidence:/ { ev = $0; sub(/^[[:space:]]*Evidence:/, "", ev); next }
		/^(Console\/navigation errors|Responsive checks|Artifacts|Limitations):/ { flush(); sec[$0 ~ /^Console/ ? "console" : ($0 ~ /^Responsive/ ? "responsive" : "other")] = 1 }
		/^Artifacts:/ { a2 = $0; sub(/^Artifacts:/, "", a2); n2 = split(a2, w2, /[[:space:],;()]+/); for (i = 1; i <= n2; i++) if (w2[i] ~ /^\//) print "path " w2[i] }
		END { flush(); print "status " status; print "counts " nj + 0 " " np + 0 " " nf + 0 " " no + 0
			print "sections " (sec["console"] ? "console" : "-") " " (sec["responsive"] ? "responsive" : "-") }' "$ARG")
	claimed=$(printf '%s\n' "$parsed" | sed -n 's/^status //p')
	set -- $(printf '%s\n' "$parsed" | sed -n 's/^counts //p')
	nj=$1 np=$2 nf=$3 no=$4
	problems=""
	problem() { problems="${problems}  - $1
"; }
	case "$claimed" in PASS | FAIL | INCOMPLETE | SKIP) ;; *) problem "no 'BROWSER VERIFICATION: PASS|FAIL|INCOMPLETE|SKIP' status line" ;; esac
	for j in $(printf '%s\n' "$parsed" | sed -n 's/^noevidence //p'); do problem "journey $j has a PASS/FAIL result without evidence"; done
	for j in $(printf '%s\n' "$parsed" | sed -n 's/^noobserved //p'); do problem "journey $j passed without an Observed line"; done
	for pth in $(printf '%s\n' "$parsed" | sed -n 's/^path //p'); do
		[ -e "$pth" ] || problem "evidence file does not exist: $pth"
	done
	sections=$(printf '%s\n' "$parsed" | sed -n 's/^sections //p')
	if [ "$claimed" = PASS ]; then
		[ "$nj" -gt 0 ] || problem "PASS without any executed journey"
		[ "$nf" -eq 0 ] && [ "$no" -eq 0 ] || problem "PASS although $nf journey(s) failed and $no did not run"
		case "$sections" in console\ *) ;; *) problem "PASS without a 'Console/navigation errors:' section" ;; esac
		case "$sections" in *responsive) ;; *) problem "PASS without a 'Responsive checks:' section (write n/a and why if not relevant)" ;; esac
	fi
	[ "$nf" -gt 0 ] && [ "$claimed" != FAIL ] && problem "$nf journey(s) failed but the status is $claimed"
	# Secrets, cookies and tokens must not appear in the report.
	leaks=$(bash "$SCRIPT_DIR/scan-secrets.sh" "$ARG" 2>/dev/null | grep '^FOUND' | grep -vE '^FOUND (email address|ip address) ' || true)
	[ -z "$leaks" ] || problem "possible credentials in the report, redact them: $(printf '%s' "$leaks" | tr '\n' ' ')"

	effective=$claimed
	if [ "$nf" -gt 0 ]; then effective=FAIL
	elif [ -n "$problems" ]; then effective=INCOMPLETE; fi
	[ "$REQUIRED_FLAG" -eq 1 ] && [ "$effective" = SKIP ] && effective=INCOMPLETE
	echo "claimed=${claimed:-none}"
	echo "effective=$effective"
	echo "journeys=$nj passed=$np failed=$nf not_run=$no"
	if [ -n "$problems" ]; then
		echo "report: INVALID"
		printf '%s' "$problems"
		exit 1
	fi
	echo "report: valid"
	;;

*) die "unknown command '$CMD' (config, detect, env, server, url-allowed, validate-report, save-report)" ;;
esac
exit 0
