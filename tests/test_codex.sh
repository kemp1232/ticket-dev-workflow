#!/usr/bin/env bash
# codex-review.sh: the Codex CLI reviews exactly the ticket's changes (never the
# developer's pre-existing work), runs read-only, cannot change the repository unnoticed,
# and every failure mode ends in SKIP or INCOMPLETE, never in a false PASS. Offline:
# codex is a stub whose behavior is chosen with STUB_CODEX_* variables.
. "$(dirname "$0")/lib.sh"

CR="$SCRIPTS/codex-review.sh"
BIN="$TEST_TMP/bin"
SD="$TEST_TMP/stub"
mkdir -p "$BIN" "$SD"
cat >"$BIN/codex" <<'EOF'
#!/usr/bin/env bash
sd=${STUB_DIR:?}
case "$*" in
--version) echo "codex-cli 0.164.0-stub"; exit 0 ;;
"exec review --help")
	[ -n "${STUB_CODEX_OLD:-}" ] && { echo "  --uncommitted"; exit 0; }
	echo "  --uncommitted"; echo "  --commit <SHA>"; exit 0 ;;
"login status")
	case "${STUB_CODEX_LOGIN:-chatgpt}" in
	chatgpt) echo "Logged in using ChatGPT" ;;
	apikey) echo "Logged in using an API key - sk-proj-****" ;;
	*) echo "Not logged in"; exit 1 ;;
	esac
	exit 0 ;;
esac
[ "$1 $2" = "exec review" ] || { echo "stub: unexpected $*" >&2; exit 9; }
printf '%s\n' "$@" >"$sd/argv"
sha=""; out=""
while [ $# -gt 0 ]; do case "$1" in --commit) sha=$2 ;; -o) out=$2 ;; esac; shift; done
git show --name-status --format= "$sha" >"$sd/scope"
git show --format= "$sha" >"$sd/patch"
root=$(git rev-parse --show-toplevel)
case "${STUB_CODEX_MODE:-findings}" in
findings)
	printf 'The change adds discounts but mishandles empty carts.\n\nFull review comments:\n\n' >"$out"
	printf -- '- [P1] Total is negative for empty carts \342\200\224 %s/src/cart.js:3-4\n  When items is empty the discount still applies,\n  so total() returns -5.\n\n' "$root" >>"$out"
	printf -- '- [P3] Prefer const \342\200\224 %s/src/new.js:1-1\n  Style only.\n' "$root" >>"$out" ;;
pass) printf 'No correctness issues found. The patch is consistent with the surrounding code.\n' >"$out" ;;
unparsed) printf 'I found one issue ([P2]) in the cart logic but cannot format it.\n' >"$out" ;;
empty) : ;;
failed) echo "Reviewer failed to output a response." >"$out" ;;
auth) echo "error: unexpected status 401 Unauthorized: please log in again" >&2; exit 1 ;;
limit) echo "error: You've hit your usage limit (429)" >&2; exit 1 ;;
timeout) sleep 5 ;;
modify) echo "oops" >>"$root/src/cart.js"; echo "no issues" >"$out" ;;
esac
exit 0
EOF
chmod +x "$BIN/codex"
export TICKET_DEV_CODEX_BIN="$BIN/codex" STUB_DIR="$SD"
unset OPENAI_API_KEY CODEX_API_KEY

R="$TEST_TMP/shop"
new_repo "$R"
mkdir -p "$R/src"
printf 'export function total(items) {\n  const sum = items.reduce((a, b) => a + b, 0)\n  return sum\n}\n' >"$R/src/cart.js"
printf 'old\n' >"$R/src/legacy.js"
printf 'config\n' >"$R/src/config.js"
git -C "$R" add -A && git -C "$R" commit -qm shop

# The developer's pre-existing work: a tracked edit in a file the ticket also changes,
# a tracked edit elsewhere, and untracked files.
printf '// dev: TODO rename\n' >>"$R/src/cart.js"
printf 'dev config\n' >>"$R/src/config.js"
printf 'scratch\n' >"$R/notes.txt"
printf 'draft\n' >"$R/src/draft.js"
git -C "$R" add src/config.js # one staged pre-existing change too
pre=$(cd "$R" && bash "$SCRIPTS/preflight.sh")
BASE=$(printf '%s\n' "$pre" | sed -n 's/^baseline: \([0-9a-f]\{40\}\).*/\1/p')
REC=$(printf '%s\n' "$pre" | sed -n 's/^baseline-untracked: \([0-9a-f]\{40\}\).*/\1/p')
assert_contains "$pre" "baseline-untracked: $REC (2 pre-existing untracked files recorded)" "preflight records untracked files"

# The ticket's work: edit cart.js, add a new file, delete a file.
sed 's/  return sum/  return sum - 5/' "$R/src/cart.js" >"$TEST_TMP/c" && cat "$TEST_TMP/c" >"$R/src/cart.js"
printf 'export let n = 1\n' >"$R/src/new.js"
rm "$R/src/legacy.js"
DEV_INDEX=$(git -C "$R" diff --cached | cksum)
DEV_STATUS=$(git -C "$R" status --porcelain)
cr() { (cd "$R" && bash "$CR" --consent requested --baseline "$BASE" --untracked-at-baseline "$REC" --title "Cart discount" "$@"); }
reset_stub() { rm -f "$SD/argv" "$SD/scope" "$SD/patch"; }

describe "scope: only the ticket's changes, including new and deleted files"
reset_stub
out=$(cr)
code=$?
assert_eq "$code" "1" "FINDINGS exit code"
assert_eq "$(cat "$SD/scope" | tr '\t' ' ' | tr '\n' '|')" "M src/cart.js|D src/legacy.js|A src/new.js|" "files Codex reviewed"
patch=$(cat "$SD/patch")
assert_contains "$patch" "+  return sum - 5" "ticket edit reviewed"
assert_not_contains "$patch" "+// dev: TODO rename" "pre-existing edit in the same file is not part of the change"
assert_contains "$patch" " // dev: TODO rename" "it is only context of the ticket's hunk"
assert_not_contains "$patch" "dev config" "pre-existing staged edit excluded"
assert_not_contains "$patch" "scratch" "pre-existing untracked file excluded"
assert_not_contains "$patch" "draft" "pre-existing untracked source excluded"
assert_contains "$out" "Scope: ticket changes only - 3 file(s) since baseline"
assert_contains "$out" "Scope gaps: none"

describe "read-only invocation through the supported review target"
argv=$(cat "$SD/argv" | tr '\n' ' ')
assert_contains "$argv" "exec review --commit "
assert_contains "$argv" 'sandbox_mode="read-only"'
assert_contains "$argv" 'approval_policy="never"'
assert_contains "$argv" "--ephemeral"
assert_contains "$argv" "--ignore-user-config" "user MCP servers and profiles are not loaded"
assert_not_contains "$argv" "--uncommitted" "never reviews the whole working tree"
assert_not_contains "$argv" "--base" "never reviews the whole branch"
assert_contains "$argv" "--title Cart discount"

describe "the developer's repository is untouched"
assert_eq "$(git -C "$R" diff --cached | cksum)" "$DEV_INDEX" "index (staged work)"
assert_eq "$(git -C "$R" status --porcelain)" "$DEV_STATUS" "working tree"
assert_eq "$(git -C "$R" stash list | wc -l | tr -d ' ')" "0" "stash list"
assert_eq "$(git -C "$R" branch --list | wc -l | tr -d ' ')" "1" "no branches created"
assert_contains "$out" "Read-only check: repository unchanged by the review"

describe "findings are normalized for validation"
assert_contains "$out" "CROSS-MODEL REVIEW: FINDINGS"
assert_contains "$out" "Reviewer: Codex CLI (codex-cli 0.164.0-stub), auth: ChatGPT sign-in"
assert_contains "$out" "Findings: 2"
assert_contains "$out" "- F1 Severity: P1 (high)"
assert_contains "$out" "  File and line: src/cart.js:3-4" "absolute path made relative"
assert_contains "$out" "  Description: Total is negative for empty carts"
assert_contains "$out" "  Evidence: When items is empty the discount still applies, so total() returns -5."
assert_contains "$out" "- F2 Severity: P3 (low)"
assert_contains "$out" "Disposition: pending - validate each finding"
assert_contains "$out" "Raw output: "

describe "clean review is PASS; a clean baseline (HEAD) works the same"
out=$(STUB_CODEX_MODE=pass cr)
assert_eq "$?" "0" "exit code"
assert_contains "$out" "CROSS-MODEL REVIEW: PASS"
C="$TEST_TMP/clean"
new_repo "$C"
cb=$(cd "$C" && bash "$SCRIPTS/preflight.sh" | sed -n 's/^baseline: \([0-9a-f]\{40\}\).*/\1/p')
assert_eq "$cb" "$(git -C "$C" rev-parse HEAD)" "clean baseline is HEAD"
printf 'more\n' >>"$C/README.md"
reset_stub
out=$(cd "$C" && STUB_CODEX_MODE=pass bash "$CR" --consent requested --baseline "$cb" --untracked-at-baseline none)
assert_eq "$?" "0" "clean-baseline PASS"
assert_eq "$(cat "$SD/scope" | tr '\t' ' ')" "M README.md" "clean-baseline scope"

describe "nothing is sent when there is nothing to review or Codex cannot run"
reset_stub
out=$(cd "$C" && git checkout -q -- README.md && bash "$CR" --consent requested --baseline "$cb")
assert_eq "$?" "3" "no changes: SKIP"
assert_contains "$out" "no changes to review"
assert_no_file "$SD/argv" "codex not called without changes"
out=$(cr --scope-only)
assert_eq "$?" "3" "--scope-only"
assert_contains "$out" "nothing was sent"
assert_contains "$out" "A	src/new.js" "scope shown"
assert_no_file "$SD/argv" "codex not called for --scope-only"
out=$(TICKET_DEV_CODEX_BIN="$TEST_TMP/none/codex" cr)
assert_eq "$?" "3" "not installed"
assert_contains "$out" "CROSS-MODEL REVIEW: SKIP"
assert_contains "$out" "Codex CLI not installed"
out=$(STUB_CODEX_LOGIN=none cr)
assert_eq "$?" "3" "logged out"
assert_contains "$out" "not logged in: run 'codex login'"
assert_no_file "$SD/argv" "codex review not called when logged out"
out=$(STUB_CODEX_OLD=1 cr)
assert_eq "$?" "4" "unsupported version"
assert_contains "$out" "no 'codex exec review --commit'"

describe "failures and timeouts are INCOMPLETE, never PASS"
for m in auth limit empty failed; do
	out=$(STUB_CODEX_MODE=$m cr)
	assert_eq "$?" "4" "$m exit code"
	assert_contains "$out" "CROSS-MODEL REVIEW: INCOMPLETE" "$m status"
done
assert_contains "$(STUB_CODEX_MODE=auth cr)" "authentication failed, run 'codex login'"
assert_contains "$(STUB_CODEX_MODE=limit cr)" "usage or rate limit"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
	out=$(STUB_CODEX_MODE=timeout TICKET_DEV_CODEX_TIMEOUT=1 cr)
	assert_eq "$?" "4" "timeout exit code"
	assert_contains "$out" "timed out after 1s"
fi
out=$(STUB_CODEX_MODE=unparsed cr)
assert_eq "$?" "1" "unparseable findings are not a pass"
assert_contains "$out" "Findings: unparsed"

describe "a review that changes the repository is detected"
cp "$R/src/cart.js" "$TEST_TMP/cart.bak"
out=$(STUB_CODEX_MODE=modify cr)
assert_eq "$?" "4" "exit code"
assert_contains "$out" "UNEXPECTED MODIFICATION"
cp "$TEST_TMP/cart.bak" "$R/src/cart.js"

describe "unattributable files are scope gaps, not silently included"
printf 'ticket edit to a developer file\n' >>"$R/src/draft.js"
reset_stub
out=$(STUB_CODEX_MODE=pass cr)
assert_eq "$?" "4" "no findings + gap = INCOMPLETE"
assert_contains "$out" "Scope gaps: modified-preexisting-untracked src/draft.js"
assert_not_contains "$(cat "$SD/scope")" "draft" "gap file not sent"
out=$(cd "$R" && STUB_CODEX_MODE=pass bash "$CR" --consent requested --baseline "$BASE" --untracked-at-baseline unknown)
assert_contains "$out" "unknown-if-preexisting src/new.js" "unknown record: new files are gaps"
assert_not_contains "$(cat "$SD/scope")" "new.js" "unknown new files not sent"
printf 'draft\n' >"$R/src/draft.js"
out=$(cd "$R" && bash "$CR" --consent requested --baseline 0000000000000000000000000000000000000000)
assert_eq "$?" "4" "bad baseline"
assert_contains "$out" "scope cannot be established"

describe "authentication: subscription by default, API billing called out"
out=$(env -u OPENAI_API_KEY -u CODEX_API_KEY STUB_CODEX_MODE=pass bash -c "cd '$R' && bash '$CR' --consent requested --baseline $BASE --untracked-at-baseline $REC")
assert_eq "$?" "0" "works with no API key in the environment"
assert_contains "$out" "no API key used"
out=$(STUB_CODEX_LOGIN=apikey STUB_CODEX_MODE=pass cr)
assert_contains "$out" "auth: API key (billed to that OpenAI API account)"
assert_not_contains "$out" "sk-proj" "login details are not echoed"
out=$(OPENAI_API_KEY=sk-test-123 STUB_CODEX_MODE=pass cr)
assert_contains "$out" "API key variable is set"
assert_not_contains "$out" "sk-test-123" "key value never printed"

describe "works in a parallel ticket worktree"
git -C "$C" worktree add -q -b t1 "$TEST_TMP/c-t1" HEAD
wb=$(cd "$TEST_TMP/c-t1" && bash "$SCRIPTS/preflight.sh" | sed -n 's/^baseline: \([0-9a-f]\{40\}\).*/\1/p')
printf 'wt\n' >"$TEST_TMP/c-t1/feature.js"
printf 'main checkout work\n' >"$C/other.js"
reset_stub
out=$(cd "$TEST_TMP/c-t1" && STUB_CODEX_MODE=pass bash "$CR" --consent requested --baseline "$wb" --untracked-at-baseline none)
assert_eq "$?" "0" "exit code"
assert_eq "$(cat "$SD/scope" | tr '\t' ' ')" "A feature.js" "only this worktree's ticket"

describe "nothing is sent without consent; configured consent is verified"
reset_stub
out=$(cd "$R" && STUB_CODEX_MODE=pass bash "$CR" --baseline "$BASE" --untracked-at-baseline "$REC")
assert_eq "$?" "3" "no consent: SKIP"
assert_contains "$out" "nothing was sent"
out=$(cd "$R" && STUB_CODEX_MODE=pass bash "$CR" --consent configured --baseline "$BASE" --untracked-at-baseline "$REC")
assert_eq "$?" "3" "configured without project opt-in"
assert_contains "$out" "does not set CODEX_REVIEW_ROUTES"
assert_no_file "$SD/argv" "codex never called without consent"
mkdir -p "$R/.claude/ticket-dev" && printf 'CODEX_REVIEW_ROUTES=complex\n' >"$R/.claude/ticket-dev/routing.conf"
echo '.claude/' >>"$R/.git/info/exclude"
out=$(cd "$R" && STUB_CODEX_MODE=pass bash "$CR" --consent configured --baseline "$BASE" --untracked-at-baseline "$REC")
assert_eq "$?" "0" "configured with project opt-in"
rm -rf "$R/.claude"

describe "user config can be loaded only on request"
reset_stub
out=$(TICKET_DEV_CODEX_USER_CONFIG=1 STUB_CODEX_MODE=pass cr)
assert_not_contains "$(cat "$SD/argv" | tr '\n' ' ')" "--ignore-user-config"
assert_contains "$out" "user config.toml loaded"

describe "usage"
bash "$CR" >/dev/null 2>&1
assert_eq "$?" "2" "no baseline"

finish
