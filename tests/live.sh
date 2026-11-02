#!/usr/bin/env bash
# Optional LIVE integration checks for the three optional features. Not part of
# tests/run.sh: each part runs only when you enable it, uses real tools and accounts,
# and works on synthetic temporary repositories (no project code leaves the machine).
#
#   TICKET_DEV_LIVE_CODEX=1     real `codex exec review` of a seeded bug; uses your Codex
#                               login (ChatGPT plan usage). TICKET_DEV_CODEX_BIN optional.
#   TICKET_DEV_LIVE_BROWSER=1   real headless browser through playwright-cli (must already
#                               be installed with a browser): open, snapshot, click,
#                               mobile resize, screenshot.
#   TICKET_DEV_LIVE_WORKTREE=1  two concurrent headless `claude -p --worktree` runs of
#                               /ticket-dev --plan-only (uses Claude usage; CLAUDE_BIN).
#
# A part that is not enabled or whose tool is missing prints "NOT RUN" and never counts
# as passed.
. "$(dirname "$0")/lib.sh"

unset CLAUDECODE
not_run() { echo "  NOT RUN: $1"; }

# ---------------------------------------------------------------- Codex
describe "live: Codex CLI reviews only the ticket's changes, read-only"
CODEX=${TICKET_DEV_CODEX_BIN:-$(command -v codex || true)}
if [ "${TICKET_DEV_LIVE_CODEX:-}" != 1 ]; then
	not_run "Codex (set TICKET_DEV_LIVE_CODEX=1)"
elif [ -z "$CODEX" ]; then
	fail "TICKET_DEV_LIVE_CODEX=1 but no codex CLI (set TICKET_DEV_CODEX_BIN)"
else
	R="$TEST_TMP/codex-live"
	new_repo "$R"
	mkdir -p "$R/src"
	printf 'export function average(xs) {\n  let s = 0\n  for (const x of xs) s += x\n  return s / xs.length\n}\n' >"$R/src/stats.js"
	git -C "$R" add -A && git -C "$R" commit -qm stats
	printf 'developer scratch, not part of the ticket\n' >"$R/notes.txt"
	pre=$(cd "$R" && bash "$SCRIPTS/preflight.sh")
	base=$(printf '%s\n' "$pre" | sed -n 's/^baseline: \([0-9a-f]\{40\}\).*/\1/p')
	rec=$(printf '%s\n' "$pre" | sed -n 's/^baseline-untracked: \([0-9a-f]\{40\}\).*/\1/p')
	# Ticket: "return 0 for an empty list" - implemented with an off-by-one bug.
	printf 'export function average(xs) {\n  if (xs.length === 0) return 0\n  let s = 0\n  for (let i = 0; i <= xs.length; i++) s += xs[i]\n  return s / xs.length\n}\n' >"$R/src/stats.js"
	printf 'export const VERSION = 2\n' >"$R/src/version.js"
	fp=$(bash "$SCRIPTS/ticket-env.sh" --fingerprint "$R")
	out=$(cd "$R" && HOME="$REAL_HOME" TICKET_DEV_CODEX_BIN="$CODEX" TICKET_DEV_CODEX_TIMEOUT="${TICKET_DEV_CODEX_TIMEOUT:-540}" \
		bash "$SCRIPTS/codex-review.sh" --consent requested --baseline "$base" --untracked-at-baseline "$rec" --title "average of empty list")
	code=$?
	printf '%s\n' "$out" | sed 's/^/    /'
	case "$code" in 0 | 1) pass ;; *) fail "codex review did not complete (exit $code)" ;; esac
	assert_contains "$out" "Scope: ticket changes only - 2 file(s)"
	assert_not_contains "$out" "notes.txt" "pre-existing file not in scope"
	assert_eq "$(bash "$SCRIPTS/ticket-env.sh" --fingerprint "$R")" "$fp" "repository unchanged"
	[ "$code" -eq 1 ] && assert_contains "$out" "src/stats.js" "the seeded bug is in the reviewed file"
fi

# ---------------------------------------------------------------- browser
describe "live: real headless browser interaction through playwright-cli"
if [ "${TICKET_DEV_LIVE_BROWSER:-}" != 1 ]; then
	not_run "browser (set TICKET_DEV_LIVE_BROWSER=1)"
elif ! command -v playwright-cli >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
	fail "TICKET_DEV_LIVE_BROWSER=1 but playwright-cli or node is missing (npm install -g @playwright/cli@latest)"
else
	W="$TEST_TMP/web-live"
	new_repo "$W"
	mkdir -p "$W/.claude/ticket-dev"
	cat >"$W/server.js" <<'EOF'
const http = require('http');
const page = `<!doctype html><meta name=viewport content="width=device-width">
<h1>Counter</h1><p id=c>Count: 0</p><button onclick="n++;c.textContent='Count: '+n">Add one</button>
<script>let n=0;const c=document.getElementById('c')</script>`;
http.createServer((q, s) => { s.setHeader('content-type', 'text/html'); s.end(page) }).listen(process.env.PORT, '127.0.0.1');
EOF
	printf '{ "dependencies": { "react": "19.0.0" } }\n' >"$W/package.json"
	git -C "$W" add -A && git -C "$W" commit -qm web
	printf 'BROWSER_VERIFICATION=auto\nBROWSER_DEV_COMMAND=node server.js\nBROWSER_READY_TIMEOUT=30\n' >"$W/.claude/ticket-dev/browser.conf"
	export TICKET_DEV_PORT=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
	bc() { (cd "$W" && bash "$SCRIPTS/browser-check.sh" "$@"); }
	env_out=$(bc env)
	ART=$(kv artifacts "$env_out")
	PW=$(kv exploratory_cmd "$env_out")
	PWOPEN=$(kv exploratory_open "$env_out")
	out=$(bc server start)
	assert_contains "$out" "server: started"
	$PWOPEN "http://127.0.0.1:$TICKET_DEV_PORT/" >/dev/null
	$PW snapshot --filename="$ART/live-before.yml" >/dev/null
	assert_contains "$(cat "$ART/live-before.yml" 2>/dev/null)" "Count: 0" "initial state observed"
	ref=$(grep -o 'button "Add one" \[ref=[a-z0-9]*\]' "$ART/live-before.yml" | sed 's/.*ref=\([a-z0-9]*\).*/\1/')
	[ -n "$ref" ] && pass || fail "button ref not found in snapshot"
	$PW click "$ref" >/dev/null
	$PW snapshot --filename="$ART/live-after.yml" >/dev/null
	assert_contains "$(cat "$ART/live-after.yml" 2>/dev/null)" "Count: 1" "click changed the page"
	$PW resize 390 844 >/dev/null
	$PW screenshot --filename="$ART/live-mobile.png" >/dev/null
	assert_file "$ART/live-mobile.png" "mobile screenshot"
	$PW close >/dev/null 2>&1
	bc server stop >/dev/null
	assert_eq "$(git -C "$W" status --porcelain)" "?? .claude/" "no artifacts in the repository"
fi

# ---------------------------------------------------------------- worktrees
describe "live: two concurrent native worktree sessions"
CLAUDE=${CLAUDE_BIN:-$(command -v claude || true)}
if [ "${TICKET_DEV_LIVE_WORKTREE:-}" != 1 ]; then
	not_run "worktrees (set TICKET_DEV_LIVE_WORKTREE=1; uses Claude usage)"
elif [ -z "$CLAUDE" ]; then
	fail "TICKET_DEV_LIVE_WORKTREE=1 but no claude CLI (set CLAUDE_BIN)"
else
	A="$TEST_TMP/sample-app"
	cp -R "$REPO/examples/sample-app" "$A"
	git -C "$A" init -q && git -C "$A" add -A && git -C "$A" commit -qm app
	bash "$REPO/scripts/install.sh" --project "$A" >/dev/null
	git -C "$A" add .claude && git -C "$A" commit -qm "install ticket-dev" -- .claude
	echo '.claude/worktrees/' >>"$A/.git/info/exclude"
	printf 'dev note\n' >>"$A/README.md"
	before=$(git -C "$A" status --porcelain; git -C "$A" diff | cksum)
	run() { # name ticket
		(cd "$A" && HOME="$REAL_HOME" TICKET_DEV_CLAUDE_BIN="$CLAUDE" bash "$SCRIPTS/ticket-worktree.sh" start "$1" --ticket "--plan-only $2" \
			-- -p --model sonnet --max-budget-usd "${TICKET_DEV_LIVE_BUDGET:-3}" --permission-mode acceptEdits \
			--allowedTools "Bash(bash *)" "Bash(git *)" "Bash(npm *)" "Bash(node *)" "Bash(grep *)" "Bash(find *)" \
			"Bash(ls *)" "Bash(cat *)" "Bash(head *)" "Bash(sed -n *)" "Bash(wc *)" >"$TEST_TMP/$1.out" 2>&1)
	}
	run live-a "Add a limit query parameter to GET /orders" &
	p1=$!
	run live-b "Change the 404 message for unknown products to Product not found" &
	p2=$!
	wait "$p1" "$p2"
	for n in live-a live-b; do
		echo "  --- $n (last lines of the session output):"
		tail -n 25 "$TEST_TMP/$n.out" | sed 's/^/    /'
		assert_contains "$(cat "$TEST_TMP/$n.out")" "PLAN ONLY" "$n: /ticket-dev ran and stopped at plan-only"
		[ -d "$A/.claude/worktrees/$n" ] && pass || fail "worktree $n not created (see $TEST_TMP/$n.out)"
		assert_eq "$(git -C "$A/.claude/worktrees/$n" symbolic-ref --short HEAD 2>/dev/null)" "worktree-$n" "$n: own branch"
		assert_eq "$(git -C "$A/.claude/worktrees/$n" status --porcelain 2>/dev/null)" "" "$n: --plan-only changed nothing"
	done
	assert_eq "$(git -C "$A" status --porcelain; git -C "$A" diff | cksum)" "$before" "main checkout untouched"
fi

finish
