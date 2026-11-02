#!/usr/bin/env bash
# Browser verification support: deterministic detection, modes and overrides, tool
# discovery without installing anything, URL policy, dev-server lifecycle with bounded
# readiness, and report validation that refuses unproven PASS claims. Offline: no real
# browser; a stub playwright-cli and (when node exists) a tiny local HTTP server.
. "$(dirname "$0")/lib.sh"

BC="$SCRIPTS/browser-check.sh"
bc() { (cd "$P" && bash "$BC" "$@"); }
P="$TEST_TMP/web"
new_repo "$P"
mkdir -p "$P/src/components" "$P/app/products" "$P/internal/api" "$P/docs" "$P/.claude/ticket-dev"
printf '{ "dependencies": { "next": "15.0.0", "react": "19.0.0" } }\n' >"$P/package.json"
printf 'package api\n' >"$P/internal/api/handler.go"
printf 'export default function Page() { return null }\n' >"$P/app/products/page.tsx"
git -C "$P" add -A && git -C "$P" commit -qm web
printf 'dev scratch\n' >"$P/scratch.tsx" # pre-existing untracked work, not the ticket's
pre=$(cd "$P" && bash "$SCRIPTS/preflight.sh")
BASE=$(printf '%s\n' "$pre" | sed -n 's/^baseline: \([0-9a-f]\{40\}\).*/\1/p')
REC=$(printf '%s\n' "$pre" | sed -n 's/^baseline-untracked: \([0-9a-f]\{40\}\).*/\1/p')
[ -n "$REC" ] && pass || fail "preflight recorded no untracked files"
setconf() { printf '%s\n' "$@" >"$P/.claude/ticket-dev/browser.conf"; }
det() { bc detect --baseline "$BASE" --untracked-at-baseline "$REC" "$@"; }
reset_changes() { git -C "$P" checkout -q -- . && git -C "$P" clean -qfd -e scratch.tsx -e .claude && mkdir -p "$P/src/components"; }

describe "defaults: off, and the existing workflow is unchanged"
out=$(bc config)
assert_contains "$out" "BROWSER_VERIFICATION=off"
assert_contains "$out" "url=http://127.0.0.1:"
assert_contains "$(cat "$SKILL/browser.conf")" "BROWSER_VERIFICATION=off" "shipped default"
assert_contains "$pre" "browser: BROWSER_VERIFICATION=off" "preflight summary"

describe "backend-only, docs-only and test-only changes skip in auto mode"
setconf BROWSER_VERIFICATION=auto
printf 'package api // changed\n' >"$P/internal/api/handler.go"
printf '# notes\n' >"$P/docs/guide.md"
printf 'test("x", () => {})\n' >"$P/src/components/Button.test.tsx"
out=$(det)
assert_eq "$(kv decision "$out")" "skip" "backend/docs/tests"
assert_contains "$(kv reason "$out")" "no browser-facing files changed"
assert_eq "$(kv frontend_changes "$out")" "0" "count"
assert_not_contains "$out" "scratch.tsx" "pre-existing untracked file is not the ticket's"

describe "frontend changes in a web project run in auto mode"
printf 'export function Button() { return <button>Next</button> }\n' >"$P/src/components/Button.tsx"
out=$(det)
assert_eq "$(kv decision "$out")" "run" "tsx change"
assert_eq "$(kv required "$out")" "no" "auto is not required"
assert_contains "$(kv web_project "$out")" "yes (next" "framework detected"
assert_contains "$(kv frontend_changes "$out")" "src/components/Button.tsx"
reset_changes
for f in app/products/page.tsx styles/site.css public/logo.svg next.config.js src/components/useCart.ts; do
	mkdir -p "$P/$(dirname "$f")" && printf 'x\n' >>"$P/$f"
	assert_eq "$(kv decision "$(det)")" "run" "$f"
	reset_changes
done
for f in src/server/db.ts lib/util.go README.md e2e/cart.spec.ts; do
	mkdir -p "$P/$(dirname "$f")" && printf 'x\n' >>"$P/$f"
	assert_eq "$(kv decision "$(det)")" "skip" "$f"
	reset_changes
done
setconf BROWSER_VERIFICATION=auto 'BROWSER_FRONTEND_PATHS=src/i18n/*,lib/ui/*'
mkdir -p "$P/src/i18n" && printf 'x\n' >"$P/src/i18n/en.json"
assert_eq "$(kv decision "$(det)")" "run" "project-defined frontend path"
reset_changes

describe "off, required and per-ticket overrides"
printf 'export function Button() {}\n' >"$P/src/components/Button.tsx"
setconf BROWSER_VERIFICATION=off
out=$(det)
assert_eq "$(kv decision "$out")" "skip" "off"
assert_contains "$(kv reason "$out")" "use --browser" "hint when UI changed"
out=$(det --override on)
assert_eq "$(kv decision "$out")/$(kv required "$out")" "run/yes" "--browser forces and requires"
setconf BROWSER_VERIFICATION=auto
assert_eq "$(kv decision "$(det --override off)")" "skip" "--no-browser"
reset_changes
setconf BROWSER_VERIFICATION=required
printf 'package api // x\n' >"$P/internal/api/handler.go"
out=$(det)
assert_eq "$(kv decision "$out")/$(kv required "$out")" "run/yes" "required runs even for backend changes"
reset_changes
setconf BROWSER_VERIFICATION=sometimes
assert_contains "$(bc config)" "ignored invalid BROWSER_VERIFICATION=sometimes" "invalid mode warned"
assert_contains "$(bc config)" "BROWSER_VERIFICATION=off" "invalid mode keeps the default"
det --override maybe >/dev/null 2>&1
assert_eq "$?" "2" "bad override"
bc detect >/dev/null 2>&1
assert_eq "$?" "2" "detect without baseline"

describe "non-web project: auto skips, required still runs and says why"
G="$TEST_TMP/goapp"
new_repo "$G"
printf 'module x\n' >"$G/go.mod" && git -C "$G" add -A && git -C "$G" commit -qm go
gb=$(git -C "$G" rev-parse HEAD)
mkdir -p "$G/.claude/ticket-dev" "$G/web" && printf 'BROWSER_VERIFICATION=auto\n' >"$G/.claude/ticket-dev/browser.conf"
printf '<p>x</p>\n' >"$G/web/x.html"
out=$(cd "$G" && bash "$BC" detect --baseline "$gb")
assert_eq "$(kv web_project "$out")" "no" "go project"
assert_contains "$(kv reason "$out")" "not a web project"

describe "URL policy: local by default, production refused"
setconf BROWSER_VERIFICATION=auto
for u in http://127.0.0.1:3000/ http://localhost:5173/cart https://app.localhost/x 'http://[::1]:8080/' about:blank; do
	bc url-allowed "$u" >/dev/null && pass || fail "should allow $u"
done
for u in https://shop.example.com/ http://10.0.0.5:3000 file:///etc/passwd 'javascript:alert(1)' http://localhost.evil.com/ 'http://user:pw@prod.example.com/'; do
	bc url-allowed "$u" >/dev/null && fail "should refuse $u" || pass
done
setconf 'BROWSER_ALLOWED_HOSTS=localhost,127.0.0.1,staging.internal.test'
bc url-allowed https://staging.internal.test/login >/dev/null && pass || fail "configured test host"

describe "tool discovery: missing tools are reported with setup guidance, nothing installed"
setconf BROWSER_VERIFICATION=auto
out=$(PATH=/usr/bin:/bin TICKET_DEV_PLAYWRIGHT_CLI= bc env)
assert_contains "$out" "exploratory=unavailable"
assert_contains "$out" "setup=exploratory: npm install -g @playwright/cli"
assert_contains "$out" "the workflow never installs"
assert_contains "$out" "e2e=none"
printf 'export default {}\n' >"$P/playwright.config.ts"
assert_contains "$(bc env)" "e2e=unavailable (playwright.config.ts found but node_modules/.bin/playwright is missing" "config without deps"
mkdir -p "$P/node_modules/.bin" && printf '#!/bin/sh\nexit 0\n' >"$P/node_modules/.bin/playwright" && chmod +x "$P/node_modules/.bin/playwright"
assert_contains "$(bc env)" "e2e_cmd=npx playwright test --reporter=line --output " "Playwright Test detected"
rm -rf "$P/node_modules" "$P/playwright.config.ts"
setconf 'BROWSER_E2E_COMMAND=pnpm test:e2e --port {port}'
assert_contains "$(bc env)" "e2e_cmd=pnpm test:e2e --port " "project e2e command"

describe "playwright-cli is configured to write artifacts outside the repository"
STUB="$TEST_TMP/bin/playwright-cli"
mkdir -p "$TEST_TMP/bin"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
# stub: remembers the opened URL; snapshot --filename=F saves the page's HTML to F
state="${PWCLI_STATE:?}"
args=" $* "
case "$args" in *" --version "*) echo "0.1.0-stub"; exit 0 ;; esac
url=""; file=""
for a in "$@"; do case "$a" in http://* | https://*) url=$a ;; --filename=*) file=${a#--filename=} ;; esac; done
case "$args" in
*" open "* | *" goto "*) echo "$url" >"$state" ;;
*" snapshot "*) curl -s "$(cat "$state")" >"$file" ;;
*" console "*) echo "0 errors" ;;
esac
exit 0
EOF
chmod +x "$STUB"
export TICKET_DEV_PLAYWRIGHT_CLI="$STUB" PWCLI_STATE="$TEST_TMP/pw.state"
setconf BROWSER_VERIFICATION=auto
out=$(bc env)
ART=$(kv artifacts "$out")
assert_contains "$out" "exploratory=playwright-cli 0.1.0-stub"
assert_contains "$out" "exploratory_open=$STUB -s=td-"
assert_contains "$out" " open --config $ART/playwright-cli.json" "config is given when the session opens"
assert_contains "$out" "exploratory_cmd=$STUB -s=td-"
assert_contains "$(cat "$ART/playwright-cli.json")" "\"outputDir\": \"$ART\""
case "$ART" in "$P"*) fail "artifacts inside the repository" ;; *) pass ;; esac
assert_eq "$(git -C "$P" status --porcelain | grep -v scratch.tsx | grep -v '.claude/')" "" "env wrote nothing into the repository"

describe "dev server: unavailable, refused and timeout are never a pass"
FREE=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})' 2>/dev/null || echo 39517)
export TICKET_DEV_PORT=$FREE
setconf BROWSER_VERIFICATION=auto
out=$(bc server start)
assert_eq "$?" "3" "nothing running and no dev command"
assert_contains "$out" "server: unavailable"
setconf 'BROWSER_DEV_COMMAND=npm run deploy'
out=$(bc server start)
assert_eq "$?" "4" "guard-blocked dev command"
assert_contains "$out" "blocked by the guard"
setconf 'BROWSER_DEV_COMMAND=echo starting; exit 3'
out=$(bc server start)
assert_eq "$?" "4" "dev command crashes"
assert_contains "$out" "FAILED: the dev command exited"
assert_contains "$out" "starting" "log tail shown"
setconf 'BROWSER_DEV_COMMAND=sleep 30' BROWSER_READY_TIMEOUT=2
out=$(bc server start)
assert_eq "$?" "4" "never ready"
assert_contains "$out" "TIMEOUT"
assert_eq "$(ps -eo args | grep -c '^sleep 30$')" "0" "timed-out server stopped"
setconf 'BROWSER_BASE_URL=https://shop.example.com' 'BROWSER_DEV_COMMAND=sleep 1'
out=$(bc server start)
assert_eq "$?" "4" "production URL refused"

if command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
	describe "dev server: start, reuse, stop only our own"
	cat >"$TEST_TMP/server.js" <<'EOF'
const http = require('http');
const page = process.env.VARIANT === 'broken' ? '<h1>Products</h1><p>Page 1 of 5</p>' : '<h1>Products</h1><p>Page 2 of 5</p>';
http.createServer((q, s) => s.end(page)).listen(process.env.PORT, '127.0.0.1');
EOF
	setconf "BROWSER_DEV_COMMAND=node $TEST_TMP/server.js" BROWSER_READY_TIMEOUT=20
	CONF0=$(cat "$P/.claude/ticket-dev/browser.conf")
	FP0=$(bash "$SCRIPTS/ticket-env.sh" --fingerprint "$P")
	out=$(bc server start)
	assert_eq "$?" "0" "start"
	assert_contains "$out" "server: started at http://127.0.0.1:$FREE"
	assert_contains "$(bc server start)" "started by this ticket" "second start reuses our server"
	assert_contains "$(bc env)" "server=running (started by this ticket" "env sees it"

	describe "simulated passing journey produces evidence the validator accepts"
	CMDP=$(kv exploratory_cmd "$(bc env)")
	OPENP=$(kv exploratory_open "$(bc env)")
	$OPENP "http://127.0.0.1:$FREE/products?page=2" && $CMDP snapshot --filename="$ART/j1-after.yml"
	grep -q 'Page 2 of 5' "$ART/j1-after.yml" && r1=PASS || r1=FAIL
	assert_eq "$r1" "PASS" "observed via the browser tool"
	cat <<EOF | bc save-report >"$TEST_TMP/v.out"
BROWSER VERIFICATION: PASS

Environment: web, server started (http://127.0.0.1:$FREE)
URL: http://127.0.0.1:$FREE
Browser/tool: playwright-cli 0.1.0-stub
Automated E2E: not configured

Journeys:
- Scenario: J1 open page 2 of the product list
  Expected: the pager shows Page 2 of 5
  Observed: snapshot contains "Page 2 of 5"
  Result: $r1
  Evidence: $ART/j1-after.yml

Console/navigation errors: none
Responsive checks: n/a - pager text only, no layout change
Artifacts: $ART
Limitations: none
EOF
	assert_eq "$?" "0" "valid report"
	assert_contains "$(cat "$TEST_TMP/v.out")" "effective=PASS"
	assert_file "$ART/report.md" "report stored with the artifacts"

	describe "simulated failing journey is reported as FAIL with evidence"
	bc server stop >/dev/null
	setconf "BROWSER_DEV_COMMAND=VARIANT=broken node $TEST_TMP/server.js" BROWSER_READY_TIMEOUT=20
	bc server start >/dev/null
	$OPENP "http://127.0.0.1:$FREE/products?page=2" && $CMDP snapshot --filename="$ART/j1-fail.yml"
	grep -q 'Page 2 of 5' "$ART/j1-fail.yml" && r1=PASS || r1=FAIL
	assert_eq "$r1" "FAIL" "observed regression"
	cat >"$TEST_TMP/fail.md" <<EOF
BROWSER VERIFICATION: FAIL
URL: http://127.0.0.1:$FREE
Journeys:
- Scenario: J1 open page 2 of the product list
  Expected: the pager shows Page 2 of 5
  Observed: the pager still shows Page 1 of 5
  Result: FAIL
  Evidence: $ART/j1-fail.yml
Console/navigation errors: none
Responsive checks: n/a - not reached
Artifacts: $ART
Limitations: none
EOF
	out=$(bc validate-report "$TEST_TMP/fail.md")
	assert_eq "$?" "0" "a truthful FAIL report is valid"
	assert_contains "$out" "effective=FAIL"
	assert_contains "$out" "journeys=1 passed=0 failed=1"

	describe "foreign servers are never reused when this ticket owns a dev command"
	bc server stop >/dev/null
	PORT=$FREE node "$TEST_TMP/server.js" &
	foreign=$!
	sleep 1
	out=$(bc server start)
	assert_eq "$?" "4" "another process on our port"
	assert_contains "$out" "another ticket's server?"
	setconf BROWSER_VERIFICATION=auto
	assert_contains "$(bc server start)" "server: reused" "no dev command: reuse the developer's server"
	assert_contains "$(bc server stop)" "nothing started by this ticket" "stop leaves foreign servers alone"
	kill -0 "$foreign" 2>/dev/null && pass || fail "foreign server was killed"
	kill "$foreign" 2>/dev/null
	wait "$foreign" 2>/dev/null
	printf '%s\n' "$CONF0" >"$P/.claude/ticket-dev/browser.conf" # the test itself edited it
	assert_eq "$(bash "$SCRIPTS/ticket-env.sh" --fingerprint "$P")" "$FP0" "browser stage changed nothing in the repository"
else
	echo "  (skipped server lifecycle and journeys: node or curl missing)"
fi
unset TICKET_DEV_PORT

describe "report validation refuses claims without execution evidence"
ev="$TEST_TMP/shot.yml"
echo snapshot >"$ev"
report() { # status result evidence [extra]
	cat <<EOF
BROWSER VERIFICATION: $1
URL: http://127.0.0.1:3000
Journeys:
- Scenario: J1 submit the empty form
  Expected: a required-field error
  Observed: error "Email is required" shown
  Result: $2
  Evidence: $3
${4:-}
Console/navigation errors: none
Responsive checks: mobile 390x844 ok, $ev
Artifacts: $TEST_TMP
Limitations: none
EOF
}
vr() { printf '%s\n' "$1" >"$TEST_TMP/r.md"; bc validate-report "$TEST_TMP/r.md" "${@:2}"; }
out=$(vr "$(report PASS PASS "$ev")")
assert_eq "$?" "0" "complete PASS"
out=$(vr "$(report PASS PASS none)")
assert_eq "$?" "1" "PASS without evidence"
assert_contains "$out" "effective=INCOMPLETE"
out=$(vr "$(report PASS PASS "$TEST_TMP/missing.png")")
assert_contains "$out" "evidence file does not exist"
out=$(vr "$(report PASS FAIL "$ev")")
assert_contains "$out" "effective=FAIL" "failed journey cannot be PASS"
out=$(vr "$(report PASS BLOCKED "-")")
assert_contains "$out" "effective=INCOMPLETE" "blocked journey cannot be PASS"
out=$(vr "BROWSER VERIFICATION: PASS
Console/navigation errors: none
Responsive checks: n/a")
assert_contains "$out" "PASS without any executed journey"
out=$(vr "$(report PASS PASS "$ev" | grep -v '^Responsive')")
assert_contains "$out" "without a 'Responsive checks:' section"
out=$(vr "$(report PASS PASS "$ev" "Note: session cookie token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghij")")
assert_contains "$out" "possible credentials" "tokens must be redacted"
out=$(vr "BROWSER VERIFICATION: SKIP
Limitations: playwright-cli not installed" --required)
assert_contains "$out" "effective=INCOMPLETE" "required stage cannot be skipped"
out=$(vr "BROWSER VERIFICATION: INCOMPLETE
Limitations: no dev server")
assert_eq "$?" "0" "honest INCOMPLETE is valid"
out=$(vr "everything looks great")
assert_eq "$?" "1" "no status line"

finish
