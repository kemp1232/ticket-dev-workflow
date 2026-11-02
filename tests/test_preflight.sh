#!/usr/bin/env bash
# Preflight never fails, never changes the repository, and gives a baseline that
# separates the workflow's changes from pre-existing work. Also covers scan-secrets.
. "$(dirname "$0")/lib.sh"

pre() { (cd "$1" && bash "$SCRIPTS/preflight.sh"); }

describe "dirty repository: pre-existing changes are listed and left untouched"
r="$TEST_TMP/dirty"
new_repo "$r"
printf 'one\n' >"$r/app.txt"
git -C "$r" add app.txt && git -C "$r" commit -qm app
printf 'local edit\n' >>"$r/README.md"
printf 'scratch\n' >"$r/notes.txt"
before=$(git -C "$r" status --porcelain; git -C "$r" diff | cksum)
out=$(pre "$r")
assert_eq "$?" "0" "exit code"
after=$(git -C "$r" status --porcelain; git -C "$r" diff | cksum)
assert_eq "$after" "$before" "working tree and index unchanged"
assert_eq "$(git -C "$r" stash list | wc -l | tr -d ' ')" "0" "stash list untouched"
assert_contains "$out" "pre-existing changes: 2"
assert_contains "$out" " M README.md"
assert_contains "$out" "?? notes.txt"
base=$(printf '%s\n' "$out" | sed -n 's/^baseline: \([0-9a-f]\{40\}\).*/\1/p')
[ -n "$base" ] && pass || fail "no baseline sha in: $out"
assert_contains "$out" "snapshot of tracked files"

describe "pre-existing untracked files are recorded without touching the repository"
rec=$(printf '%s\n' "$out" | sed -n 's/^baseline-untracked: \([0-9a-f]\{40\}\).*/\1/p')
[ -n "$rec" ] && pass || fail "no untracked record in: $out"
assert_eq "$(git -C "$r" cat-file blob "$rec")" "$(git -C "$r" hash-object notes.txt) notes.txt" "record content"
assert_contains "$out" "### Ticket environment"
assert_contains "$out" "worktree=main"
assert_contains "$out" "browser: BROWSER_VERIFICATION=off"
tmpd=$(printf '%s\n' "$out" | sed -n 's/.* tmp=\([^ ]*\) .*/\1/p')
case "$tmpd" in "$r"*) fail "ticket temp dir inside the repository" ;; "") fail "no ticket tmp" ;; *) pass ;; esac

describe "baseline diff shows only changes made after preflight"
printf 'two\n' >>"$r/app.txt"
changed=$(git -C "$r" diff --name-only "$base")
assert_eq "$changed" "app.txt" "files changed since baseline"
assert_eq "$(cat "$r/notes.txt")" "scratch" "untracked work intact"
assert_contains "$(cat "$r/README.md")" "local edit" "tracked work intact"

describe "changed-files lists the ticket's own changes only"
printf 'new\n' >"$r/ticket-new.txt"
ch=$(bash "$SCRIPTS/ticket-env.sh" --changed-files --baseline "$base" --untracked-at-baseline "$rec" "$r")
assert_contains "$ch" "changed app.txt"
assert_contains "$ch" "new ticket-new.txt"
assert_not_contains "$ch" "notes.txt" "pre-existing untracked"
assert_not_contains "$ch" "README.md" "pre-existing tracked edit"
printf 'more\n' >>"$r/notes.txt"
assert_contains "$(bash "$SCRIPTS/ticket-env.sh" --changed-files --baseline "$base" --untracked-at-baseline "$rec" "$r")" "gap modified-preexisting-untracked notes.txt"
rm "$r/notes.txt"
assert_contains "$(bash "$SCRIPTS/ticket-env.sh" --changed-files --baseline "$base" --untracked-at-baseline "$rec" "$r")" "gap deleted-preexisting-untracked notes.txt"
printf 'scratch\n' >"$r/notes.txt"
rm "$r/ticket-new.txt"
fp=$(bash "$SCRIPTS/ticket-env.sh" --fingerprint "$r")
assert_eq "$(bash "$SCRIPTS/ticket-env.sh" --fingerprint "$r")" "$fp" "fingerprint is stable"
printf 'x' >>"$r/notes.txt"
[ "$(bash "$SCRIPTS/ticket-env.sh" --fingerprint "$r")" != "$fp" ] && pass || fail "fingerprint missed an untracked edit"
printf 'scratch\n' >"$r/notes.txt"

describe "clean repository uses HEAD as baseline"
c="$TEST_TMP/clean"
new_repo "$c"
out=$(pre "$c")
assert_contains "$out" "baseline: $(git -C "$c" rev-parse HEAD) (HEAD"
assert_contains "$out" "pre-existing changes: none"
assert_contains "$out" "baseline-untracked: none"

describe "repository without commits and non-git directories still succeed"
e="$TEST_TMP/nocommit"
mkdir -p "$e" && git -C "$e" init -q
out=$(pre "$e")
assert_eq "$?" "0" "exit code"
assert_contains "$out" "no commits yet"
n="$TEST_TMP/nogit"
mkdir -p "$n"
out=$(pre "$n")
assert_eq "$?" "0" "exit code"
assert_contains "$out" "NOT A GIT REPOSITORY"
assert_contains "$out" "Ask the developer to confirm before editing"

describe "project configuration is surfaced"
mkdir -p "$c/.claude/ticket-dev"
printf -- '- Use the pagination helper in src/lib.\n' >"$c/.claude/ticket-dev/conventions.md"
printf 'MODEL_COMPLEX=fable\n' >"$c/.claude/ticket-dev/routing.conf"
for i in $(seq 1 100); do echo "line $i" >>"$c/.claude/ticket-dev/conventions.md"; done
out=$(pre "$c")
assert_contains "$out" "Use the pagination helper"
assert_contains "$out" "truncated at 80"
assert_contains "$out" "MODEL_COMPLEX=fable"
assert_contains "$out" "run-check: bash $SCRIPTS/run-check.sh"

describe "project skills are listed for the orchestrator, ticket-dev excluded"
k="$TEST_TMP/skills"
new_repo "$k"
out=$(pre "$k")
assert_contains "$out" "project skills: none"
mkdir -p "$k/.claude/skills/api-conventions" "$k/.claude/skills/testing-guide" "$k/.claude/skills/deploy" "$k/.claude/skills/ticket-dev"
printf -- '---\nname: api-conventions\ndescription: "REST conventions: kebab-case paths, page/pageSize pagination"\n---\nbody\n' >"$k/.claude/skills/api-conventions/SKILL.md"
printf -- '---\ndescription: >\n  How we write tests:\n  vitest, no mocks for the DB\nuser-invocable: true\n---\nbody\n' >"$k/.claude/skills/testing-guide/SKILL.md"
printf 'no frontmatter here\n' >"$k/.claude/skills/deploy/SKILL.md"
printf -- '---\nname: ticket-dev\ndescription: should not be listed\n---\n' >"$k/.claude/skills/ticket-dev/SKILL.md"
out=$(pre "$k")
assert_eq "$?" "0" "exit code"
assert_contains "$out" "project skills: 3"
assert_contains "$out" "api-conventions - REST conventions: kebab-case paths, page/pageSize pagination (.claude/skills/api-conventions/SKILL.md)"
assert_contains "$out" "testing-guide - How we write tests: vitest, no mocks for the DB (.claude/skills/testing-guide/SKILL.md)" "folded description, name from directory"
assert_contains "$out" "deploy - (no description)"
assert_not_contains "$out" "should not be listed"

describe "scan-secrets flags credentials without printing them"
f="$TEST_TMP/package.md"
cat >"$f" <<'EOF'
# Review request
Contact: dev@example.com
DATABASE_URL=postgres://admin:hunter2pass@db.internal:5432/app
export API_KEY="abcd1234efgh5678"
key AKIAABCDEFGHIJKLMNOP
owner jane.doe@acme-corp.io on 10.2.3.4 (local 127.0.0.1)
EOF
out=$(bash "$SCRIPTS/scan-secrets.sh" "$f")
assert_eq "$?" "1" "exit code"
assert_contains "$out" "url with credentials on line(s): 3"
assert_contains "$out" "secret assignment on line(s): 4"
assert_contains "$out" "aws access key on line(s): 5"
assert_contains "$out" "email address on line(s): 3 6" "credential URL also looks like an address"
assert_contains "$out" "ip address on line(s): 6"
assert_not_contains "$out" "hunter2pass" "output"
assert_not_contains "$out" "AKIAABCDEFGHIJKLMNOP" "output"
printf 'Signature: listProducts(opts: ListOptions): Promise<Page<Product>>\nSee dev@example.com\n' >"$f"
out=$(bash "$SCRIPTS/scan-secrets.sh" "$f")
assert_eq "$?" "0" "clean exit code"
assert_contains "$out" "CLEAN"


describe "project rules are listed with their path scope"
u="$TEST_TMP/rules"
new_repo "$u"
out=$(pre "$u")
assert_contains "$out" "project rules: none"
mkdir -p "$u/.claude/rules/backend"
printf -- '---\npaths:\n  - "src/api/**/*.ts"\n  - "src/**/handler.ts"\n---\n- validate input\n' >"$u/.claude/rules/backend/api.md"
printf -- '---\npaths: "test/**/*"\n---\n- no mocks\n' >"$u/.claude/rules/testing.md"
printf -- '- always use pnpm\n' >"$u/.claude/rules/general.md"
out=$(pre "$u")
assert_contains "$out" "project rules: 3"
assert_contains "$out" ".claude/rules/backend/api.md - when touching src/api/**/*.ts, src/**/handler.ts"
assert_contains "$out" ".claude/rules/testing.md - when touching test/**/*"
assert_contains "$out" ".claude/rules/general.md - always loaded"

finish
