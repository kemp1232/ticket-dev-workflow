#!/usr/bin/env bash
# Parallel tickets: ticket-worktree.sh starts each ticket in its own native Claude Code
# worktree, refuses unsafe names and conflicts, never removes work, and every worktree
# gets its own baseline, temp dir, port and logs. Claude Code is a stub that emulates
# `claude --worktree NAME` (documented: .claude/worktrees/NAME on branch worktree-NAME).
. "$(dirname "$0")/lib.sh"

unset CLAUDECODE
TW="$SCRIPTS/ticket-worktree.sh"
BIN="$TEST_TMP/bin"
mkdir -p "$BIN"
export STUB_LOG="$TEST_TMP/claude.log"
cat >"$BIN/claude" <<'EOF'
#!/usr/bin/env bash
{ printf 'ARGS'; for a in "$@"; do printf ' [%s]' "$a"; done; echo
  echo "TICKET=${TICKET_DEV_TICKET:-} PWD=$(pwd)"; } >>"$STUB_LOG"
name=""
while [ $# -gt 0 ]; do case "$1" in --worktree) name=$2; shift ;; esac; shift; done
[ -n "$name" ] || exit 0
wt=".claude/worktrees/$name"
[ -d "$wt" ] || git worktree add -q -b "worktree-$name" "$wt" HEAD 2>/dev/null || exit 1
[ -z "${STUB_ACTION:-}" ] || (cd "$wt" && sh -c "$STUB_ACTION")
exit 0
EOF
chmod +x "$BIN/claude"
export TICKET_DEV_CLAUDE_BIN="$BIN/claude"
tw() { (cd "$R" && bash "$TW" "$@"); }

R="$TEST_TMP/repo"
new_repo "$R"
mkdir -p "$R/src"
printf 'shared\n' >"$R/src/shared.txt"
git -C "$R" add -A && git -C "$R" commit -qm src
# The developer's own uncommitted work in the main checkout.
printf 'dev edit\n' >>"$R/README.md"
printf 'dev notes\n' >"$R/notes.txt"
DEV_STATE=$(git -C "$R" status --porcelain; git -C "$R" diff | cksum)

describe "start refuses when the new worktree would not contain ticket-dev"
out=$(tw start feat-a --ticket "Do A" 2>&1)
assert_eq "$?" "2" "exit code"
assert_contains "$out" "neither installed globally nor committed"
assert_no_file "$R/.claude/worktrees/feat-a" "worktree"
bash "$REPO/scripts/install.sh" --global >/dev/null

describe "inside a Claude Code session the launcher refuses to start sessions"
out=$(CLAUDECODE=1 tw start feat-a --ticket "Do A" 2>&1)
assert_eq "$?" "2" "exit code"
assert_contains "$out" "from inside a Claude Code session"
for c in resume clean; do
	CLAUDECODE=1 tw "$c" feat-a >/dev/null 2>&1
	assert_eq "$?" "2" "$c refused inside a session"
done

describe "invalid names and missing input are rejected before anything runs"
for n in '../x' 'a/b' '-x' '.hidden' 'a..b' 'x.lock' 'sp ace' "$(printf 'n%.0s' $(seq 1 65))"; do
	tw start "$n" --ticket "t" >/dev/null 2>&1
	assert_eq "$?" "2" "name '$n'"
done
tw start feat-a >/dev/null 2>&1
assert_eq "$?" "2" "no ticket text"
tw start feat-a --ticket "t" --base sideways >/dev/null 2>&1
assert_eq "$?" "2" "bad --base"
assert_no_file "$STUB_LOG" "claude never started"

describe "missing tools are reported"
out=$(TICKET_DEV_CLAUDE_BIN="$TEST_TMP/nope/claude" tw start feat-a --ticket "t" 2>&1)
assert_eq "$?" "2" "no claude"
assert_contains "$out" "Claude Code CLI not found"
mkdir -p "$TEST_TMP/nogit"
out=$(cd "$R" && PATH="$TEST_TMP/nogit" "$(command -v bash)" "$TW" list 2>&1)
assert_eq "$?" "2" "no git"
assert_contains "$out" "git is not installed"
out=$(cd "$TEST_TMP" && bash "$TW" list 2>&1)
assert_contains "$out" "not inside a git repository"
e="$TEST_TMP/empty"
mkdir -p "$e" && git -C "$e" init -q
out=$(cd "$e" && bash "$TW" start x --ticket t 2>&1)
assert_contains "$out" "no commits"
if ! command -v tmux >/dev/null 2>&1; then
	out=$(tw start feat-a --ticket t --tmux 2>&1)
	assert_contains "$out" "--tmux needs tmux"
fi

describe "dry run shows the native command and creates nothing"
out=$(tw start feat-a --ticket "Implement frontend pagination" --base head --dry-run)
assert_eq "$?" "0" "exit code"
assert_contains "$out" "worktree: $R/.claude/worktrees/feat-a"
assert_contains "$out" "branch:   worktree-feat-a"
assert_contains "$out" "'--worktree' 'feat-a'"
assert_contains "$out" "'{\"worktree\":{\"baseRef\":\"head\"}}'" "base head via settings"
assert_contains "$out" "'/ticket-dev Implement frontend pagination'"
assert_contains "$out" "is not git-ignored" "worktrees dir warning"
assert_no_file "$R/.claude/worktrees/feat-a"

describe "two tickets start in separate native worktrees"
echo '.claude/worktrees/' >>"$R/.git/info/exclude"
STUB_ACTION='printf "A\n" > src/a.txt; printf "A edit\n" >> src/shared.txt' tw start feat-a --ticket "Implement frontend pagination" >"$TEST_TMP/a.out" 2>&1 &
pa=$!
STUB_ACTION='printf "B\n" > src/b.txt' tw start feat-b --ticket "Implement backend filtering" >"$TEST_TMP/b.out" 2>&1 &
pb=$!
wait "$pa"; assert_eq "$?" "0" "worker A exit"
wait "$pb"; assert_eq "$?" "0" "worker B exit"
A="$R/.claude/worktrees/feat-a"
B="$R/.claude/worktrees/feat-b"
assert_eq "$(git -C "$A" symbolic-ref --short HEAD)" "worktree-feat-a" "A branch"
assert_eq "$(git -C "$B" symbolic-ref --short HEAD)" "worktree-feat-b" "B branch"
log=$(cat "$STUB_LOG")
assert_contains "$log" "[--worktree] [feat-a] [--name] [ticket-feat-a] [/ticket-dev Implement frontend pagination]"
assert_contains "$log" "[/ticket-dev Implement backend filtering]"
assert_contains "$log" "TICKET=feat-b PWD=$R" "ticket label exported, run from the main checkout"
assert_not_contains "$(cat "$TEST_TMP/a.out")" "is not git-ignored" "excluded dir: no warning"
assert_contains "$(cat "$TEST_TMP/a.out")" "Ticket worktree kept: $A on branch worktree-feat-a" "location reported"

describe "changes stay in their own worktree; the developer's work is untouched"
assert_file "$A/src/a.txt"
assert_no_file "$A/src/b.txt" "B's file in A"
assert_file "$B/src/b.txt"
assert_no_file "$B/src/a.txt" "A's file in B"
assert_eq "$(cat "$B/src/shared.txt")" "shared" "A's edit to a shared file is not in B"
assert_no_file "$R/src/a.txt" "A's file in main"
assert_eq "$(git -C "$R" status --porcelain; git -C "$R" diff | cksum)" "$DEV_STATE" "main checkout"
assert_contains "$(cat "$A/README.md" "$B/README.md")" "# repo" "worktrees start from the commit"
assert_not_contains "$(cat "$A/README.md")" "dev edit" "uncommitted work is not copied"

describe "each worktree has its own identity, temp dir, port and check logs"
envs() { bash "$SCRIPTS/ticket-env.sh" "$1"; }
ea=$(envs "$A"); eb=$(envs "$B"); em=$(envs "$R")
assert_eq "$(kv worktree "$ea")" "linked" "A kind"
assert_eq "$(kv worktree "$em")" "main" "main kind"
assert_eq "$(kv main_checkout "$ea")" "$(cd "$R" && pwd -P)" "A main checkout"
assert_eq "$(kv branch "$eb")" "worktree-feat-b" "B branch"
[ "$(kv tmp "$ea")" != "$(kv tmp "$eb")" ] && [ "$(kv tmp "$ea")" != "$(kv tmp "$em")" ] && pass || fail "temp dirs shared"
[ "$(kv port "$ea")" != "$(kv port "$eb")" ] && pass || fail "ports shared"
[ -d "$(kv tmp "$ea")" ] && pass || fail "temp dir not created"
case "$(kv tmp "$ea")" in "$R"*) fail "temp dir inside the repository" ;; *) pass ;; esac
assert_eq "$(TICKET_DEV_PORT=4999 envs "$A" | sed -n 's/^port=//p')" "4999" "port override"
la=$(cd "$A" && unset TICKET_DEV_LOG_DIR && bash "$SCRIPTS/run-check.sh" t -- "echo boom; exit 1" | sed -n 's/^  log: \([^ ]*\).*/\1/p')
lb=$(cd "$B" && unset TICKET_DEV_LOG_DIR && bash "$SCRIPTS/run-check.sh" t -- "echo boom; exit 1" | sed -n 's/^  log: \([^ ]*\).*/\1/p')
case "$la" in "$(kv tmp "$ea")"/checks/*) pass ;; *) fail "A's log not in A's temp dir: $la" ;; esac
case "$lb" in "$(kv tmp "$eb")"/checks/*) pass ;; *) fail "B's log not in B's temp dir: $lb" ;; esac

describe "per-worktree preflight baselines stay accurate when run concurrently"
(cd "$A" && bash "$SCRIPTS/preflight.sh") >"$TEST_TMP/pa" &
p1=$!
(cd "$B" && bash "$SCRIPTS/preflight.sh") >"$TEST_TMP/pb" &
p2=$!
wait "$p1" "$p2"
assert_contains "$(cat "$TEST_TMP/pa")" "worktree=linked" "preflight shows the worktree"
assert_contains "$(cat "$TEST_TMP/pa")" "?? src/a.txt" "A's pre-existing work"
assert_not_contains "$(cat "$TEST_TMP/pa")" "src/b.txt" "B's work not in A"
ba=$(sed -n 's/^baseline: \([0-9a-f]\{40\}\).*/\1/p' "$TEST_TMP/pa")
bb=$(sed -n 's/^baseline: \([0-9a-f]\{40\}\).*/\1/p' "$TEST_TMP/pb")
printf 'ticket\n' >>"$A/README.md"
printf 'ticket\n' >>"$B/src/shared.txt"
assert_eq "$(git -C "$A" diff --name-only "$ba")" "README.md" "A's ticket diff"
assert_eq "$(git -C "$B" diff --name-only "$bb")" "src/shared.txt" "B's ticket diff"
assert_eq "$(cat "$A/src/shared.txt")" "shared
A edit" "A's pre-existing edit preserved"

describe "existing name and existing branch are conflicts, never reused or overwritten"
out=$(tw start feat-a --ticket "again" 2>&1)
assert_eq "$?" "2" "existing worktree"
assert_contains "$out" "already exists"
assert_contains "$out" "resume feat-a"
git -C "$R" branch worktree-feat-c
out=$(tw start feat-c --ticket "c" 2>&1)
assert_eq "$?" "2" "existing branch"
assert_contains "$out" "branch worktree-feat-c already exists"
assert_no_file "$R/.claude/worktrees/feat-c"

describe "list, status, diff and resume"
out=$(tw list)
assert_contains "$out" "feat-a"
assert_contains "$out" "worktree-feat-b"
assert_contains "$(printf '%s\n' "$out" | grep feat-a)" " 3 " "A has 3 changed files"
out=$(tw status feat-a)
assert_contains "$out" "worktree: $A"
assert_contains "$out" "?? src/a.txt"
git -C "$B" add src/b.txt && git -C "$B" commit -qm "B work"
out=$(tw status feat-b)
assert_contains "$out" "B work" "commit listed"
out=$(tw diff feat-b)
assert_contains "$out" "+B" "committed change in diff"
assert_contains "$out" "+ticket" "uncommitted change in diff"
out=$(tw diff feat-a)
assert_contains "$out" "#   src/a.txt" "untracked files listed"
: >"$STUB_LOG"
out=$(tw resume feat-a)
assert_eq "$?" "0" "resume"
assert_contains "$(cat "$STUB_LOG")" "[--worktree] [feat-a] [--resume]"
out=$(tw start feat-e --ticket "e" --dry-run -- -p --allowedTools "Bash(git *)")
assert_contains "$out" "'/ticket-dev e' '-p' '--allowedTools' 'Bash(git *)'" "prompt precedes pass-through arguments"
tw resume nope >/dev/null 2>&1
assert_eq "$?" "2" "resume of a missing worktree"

describe "clean never removes work"
out=$(tw clean feat-a 2>&1)
assert_eq "$?" "1" "uncommitted and untracked work"
assert_contains "$out" "Refusing to remove"
assert_contains "$out" "src/a.txt"
assert_file "$A/src/a.txt" "work kept"
git -C "$B" checkout -q -- src/shared.txt
mkdir -p "$B/node_modules" && echo dep >"$B/node_modules/x.js"
printf 'node_modules/\n' >>"$R/.git/info/exclude"
out=$(tw clean feat-b 2>&1)
assert_eq "$?" "1" "ignored files need confirmation"
assert_contains "$out" "node_modules/"
git -C "$R" worktree lock "$B"
out=$(tw clean feat-b --discard-ignored 2>&1)
assert_eq "$?" "2" "locked worktree"
assert_contains "$out" "locked"
git -C "$R" worktree unlock "$B"
out=$(tw clean feat-b --discard-ignored --delete-branch 2>&1)
assert_eq "$?" "1" "unmerged branch is kept"
assert_no_file "$B" "clean worktree removed"
assert_contains "$out" "Kept branch worktree-feat-b"
git -C "$R" show-ref --verify -q refs/heads/worktree-feat-b && pass || fail "branch with commits deleted"
assert_eq "$(git -C "$R" status --porcelain; git -C "$R" diff | cksum)" "$DEV_STATE" "main checkout after clean"

describe "a clean, merged ticket can be removed together with its branch"
tw start feat-d --ticket "d" >/dev/null 2>&1
out=$(tw clean feat-d --delete-branch 2>&1)
assert_eq "$?" "0" "exit code"
assert_contains "$out" "Deleted branch worktree-feat-d"
git -C "$R" show-ref --verify -q refs/heads/worktree-feat-d && fail "merged branch kept" || pass

describe "single-checkout use needs no worktree"
out=$(cd "$R" && bash "$SCRIPTS/preflight.sh")
assert_contains "$out" "worktree=main"
assert_contains "$out" " M README.md"

finish
