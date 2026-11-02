#!/usr/bin/env bash
# End-to-end smoke test on a temporary copy of examples/sample-app.
#
# Part 1 (always): project install, preflight, routing of the example tickets, a
# simulated implementation verified with run-check.sh, preservation of pre-existing
# changes, and uninstall.
#
# Part 2 (only with TICKET_DEV_LIVE=1): real headless Claude Code runs of /ticket-dev
# in the temporary repository. This uses your Claude usage (Sonnet session, Haiku
# subagents). Optional settings: CLAUDE_BIN, TICKET_DEV_LIVE_BUDGET (USD cap per run,
# default 3), TICKET_DEV_LIVE_KEEP=1 to keep the transcripts.
. "$(dirname "$0")/lib.sh"

if ! command -v node >/dev/null 2>&1; then
	echo "smoke.sh: skipped (node is required for the sample app)"
	exit 0
fi

APP="$TEST_TMP/sample-app"
cp -R "$REPO/examples/sample-app" "$APP"
git -C "$APP" init -q
git -C "$APP" add -A
git -C "$APP" commit -qm "sample app"

# The developer's own uncommitted work, which the workflow must preserve.
printf '\nLocal note: deploy freeze until Friday.\n' >>"$APP/README.md"
printf 'scratch notes\n' >"$APP/notes.txt"
README_SUM=$(cksum <"$APP/README.md")
NOTES_SUM=$(cksum <"$APP/notes.txt")

describe "project install into the sample app"
bash "$REPO/scripts/install.sh" --project "$APP" >/dev/null
assert_eq "$?" "0" "install"
S="$APP/.claude/skills/ticket-dev/scripts"

describe "preflight on the sample app"
out=$(cd "$APP" && bash "$S/preflight.sh")
assert_contains "$out" " M README.md"
assert_contains "$out" "?? notes.txt"
assert_contains "$out" "check test: npm test"
assert_contains "$out" "targeted test: node --test <path>"
assert_contains "$out" 'targeted test-name: node --test --test-name-pattern="<name>" <path>'
BASE=$(printf '%s\n' "$out" | sed -n 's/^baseline: \([0-9a-f]\{40\}\).*/\1/p')
[ -n "$BASE" ] && pass || fail "no baseline"

describe "example tickets route as documented"
r() { (cd "$APP" && bash "$S/route.sh" "$@"); }
out=$(r --triage --ticket "Change the 404 message for unknown products to say Product not found")
assert_eq "$(kv fast_path_allowed "$out")" "yes" "LOW triage"
out=$(r --files 2 --modules 1 --uncertainty none --tests good --ticket "Change the 404 message for unknown products to say Product not found")
assert_eq "$(kv route "$out")/$(kv model "$out")" "light/haiku" "LOW route"
out=$(r --files 3 --modules 1 --uncertainty low --tests good --signals public-api --ticket "Implement pagination on the existing products API")
assert_eq "$(kv route "$out")/$(kv model "$out")" "standard/sonnet" "MEDIUM route"
out=$(r --files 4 --modules 2 --uncertainty low --tests good --signals auth --ticket "Require an API key header for GET /products")
assert_eq "$(kv route "$out")/$(kv approval "$out")" "complex/required" "HIGH route"

describe "simulated implementation is verified honestly"
sed 's/Not found/Product not found/' "$APP/src/products/handler.js" >"$TEST_TMP/h.js" && cp "$TEST_TMP/h.js" "$APP/src/products/handler.js"
out=$(cd "$APP" && bash "$S/run-check.sh" test-targeted -- node --test test/products.test.js)
assert_eq "$?" "1" "the old test now fails"
assert_contains "$out" "[FAIL] test-targeted"
sed "s/'Not found'/'Product not found'/" "$APP/test/products.test.js" >"$TEST_TMP/t.js" && cp "$TEST_TMP/t.js" "$APP/test/products.test.js"
out=$(cd "$APP" && bash "$S/run-check.sh" test-targeted -- node --test test/products.test.js)
assert_contains "$out" "[PASS] test-targeted"
out=$(cd "$APP" && bash "$S/run-check.sh" test -- npm test)
assert_contains "$out" "[PASS] test"
# The single-test command a review checklist would hand to the developer.
out=$(cd "$APP" && bash "$S/run-check.sh" ac1 -- 'node --test --test-name-pattern="returns 404" test/products.test.js')
assert_contains "$out" "[PASS] ac1"
out=$(cd "$APP" && bash "$S/run-check.sh" lint --skip "no lint configured")
assert_contains "$out" "[SKIP] lint - no lint configured"

describe "baseline isolates the ticket's changes; pre-existing work intact"
changed=$(git -C "$APP" diff --name-only "$BASE" | tr '\n' ' ')
assert_eq "$changed" "src/products/handler.js test/products.test.js " "changed since baseline"
assert_eq "$(cksum <"$APP/README.md")" "$README_SUM" "README.md"
assert_eq "$(cksum <"$APP/notes.txt")" "$NOTES_SUM" "notes.txt"

describe "uninstall leaves only the developer's and the ticket's changes"
bash "$REPO/scripts/uninstall.sh" --project "$APP" >/dev/null
assert_eq "$?" "0" "uninstall"
st=$(git -C "$APP" status --porcelain | tr '\n' '|')
assert_eq "$st" " M README.md| M src/products/handler.js| M test/products.test.js|?? notes.txt|" "git status"

# ---------------------------------------------------------------- live part
if [ "${TICKET_DEV_LIVE:-}" != "1" ]; then
	echo "  (live Claude Code runs skipped; set TICKET_DEV_LIVE=1 to enable)"
	finish
	exit $?
fi

CLAUDE=${CLAUDE_BIN:-$(command -v claude || true)}
if [ -z "$CLAUDE" ] || ! "$CLAUDE" --version >/dev/null 2>&1; then
	fail "TICKET_DEV_LIVE=1 but no working claude CLI (set CLAUDE_BIN)"
	finish
	exit $?
fi
# Live runs use the real account, so restore the real HOME for authentication.
export HOME="$REAL_HOME"
BUDGET=${TICKET_DEV_LIVE_BUDGET:-3}
LOGS="$TEST_TMP/live"
[ "${TICKET_DEV_LIVE_KEEP:-}" = "1" ] && LOGS="${TMPDIR:-/tmp}/ticket-dev-live-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"

fresh_app() { # fresh sample app with the developer's pre-existing changes, workflow installed
	rm -rf "$APP"
	cp -R "$REPO/examples/sample-app" "$APP"
	git -C "$APP" init -q && git -C "$APP" add -A && git -C "$APP" commit -qm "sample app"
	printf '\nLocal note: deploy freeze until Friday.\n' >>"$APP/README.md"
	printf 'scratch notes\n' >"$APP/notes.txt"
	bash "$REPO/scripts/install.sh" --project "$APP" >/dev/null
	git -C "$APP" add .claude && git -C "$APP" commit -qm "install ticket-dev" -- .claude
}
live() { # name prompt
	(cd "$APP" && "$CLAUDE" -p "$2" --model sonnet --effort medium --output-format stream-json --verbose \
		--permission-mode acceptEdits --max-budget-usd "$BUDGET" --no-session-persistence \
		--allowedTools "Bash(bash *)" "Bash(git *)" "Bash(npm *)" "Bash(node *)" "Bash(grep *)" "Bash(find *)" \
		"Bash(ls *)" "Bash(cat *)" "Bash(head *)" "Bash(sed -n *)" "Bash(wc *)" \
		>"$LOGS/$1.jsonl" 2>"$LOGS/$1.err")
	echo "  live run '$1': exit $?, transcript $LOGS/$1.jsonl"
}
result_text() { grep '"type":"result"' "$LOGS/$1.jsonl" | tail -n 1; }
agent_calls() { # "subagent=model" for each ticket-dev subagent the main session started
	if command -v python3 >/dev/null 2>&1; then
		python3 -c '
import json, sys
seen = []
for line in open(sys.argv[1]):
    m = json.loads(line).get("message")
    content = m.get("content") if isinstance(m, dict) else None
    for c in content if isinstance(content, list) else []:
        if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") in ("Agent", "Task"):
            i = c.get("input") or {}
            if str(i.get("subagent_type", "")).startswith("ticket-dev-"):
                seen.append("%s=%s" % (i["subagent_type"], i.get("model", "default")))
print(" ".join(seen))' "$LOGS/$1.jsonl"
	else
		grep -oE '"subagent_type":"ticket-dev-[a-z]+"' "$LOGS/$1.jsonl" | cut -d'"' -f4 | tr '\n' ' '
	fi
}

describe "live: --plan-only makes no application changes"
fresh_app
before=$(git -C "$APP" status --porcelain; git -C "$APP" diff | cksum)
live plan-only "/ticket-dev --plan-only Implement pagination on the existing products API"
after=$(git -C "$APP" status --porcelain; git -C "$APP" diff | cksum)
assert_eq "$after" "$before" "repository unchanged"
res=$(result_text plan-only)
assert_contains "$res" "standard" "routed to the standard route"
echo "  subagents: $(agent_calls plan-only)"
assert_contains "$(agent_calls plan-only)" "ticket-dev-explorer=haiku" "explorer used on haiku"
assert_not_contains "$(agent_calls plan-only)" "ticket-dev-implementer" "no implementation"

describe "live: HIGH-risk ticket stops at the approval gate"
fresh_app
before=$(git -C "$APP" status --porcelain; git -C "$APP" diff | cksum)
live high-gate "/ticket-dev Require an X-API-Key header matching the API_KEY environment variable for GET /products"
after=$(git -C "$APP" status --porcelain; git -C "$APP" diff | cksum)
assert_eq "$after" "$before" "nothing implemented before approval"
assert_contains "$(result_text high-gate)" "approv" "asks for approval"
echo "  subagents: $(agent_calls high-gate)"
assert_contains "$(agent_calls high-gate)" "ticket-dev-implementer=opus" "plan drafted on the complex route model"

describe "live: LOW ticket is implemented, verified and preserves local work"
fresh_app
base=$(git -C "$APP" stash create)
live low-impl "/ticket-dev Change the 404 error message for unknown products from 'Not found' to 'Product not found' and update its test. Start with @src/products/handler.js"
changed=$(git -C "$APP" diff --name-only "$base" | tr '\n' ' ')
assert_eq "$changed" "src/products/handler.js test/products.test.js " "only the ticket's files changed"
assert_contains "$(cat "$APP/README.md")" "deploy freeze" "pre-existing tracked change kept"
assert_eq "$(cat "$APP/notes.txt")" "scratch notes" "pre-existing untracked file kept"
(cd "$APP" && node --test >/dev/null 2>&1) && pass || fail "sample app tests fail after the run"
calls=$(agent_calls low-impl)
echo "  subagents: $calls"
assert_contains "$calls" "ticket-dev-implementer" "implementer used"
assert_contains "$calls" "ticket-dev-verifier=haiku" "verifier used on haiku"
assert_contains "$(result_text low-impl)" "[PASS]" "report quotes check results"

finish
