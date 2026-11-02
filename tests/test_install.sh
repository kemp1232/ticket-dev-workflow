#!/usr/bin/env bash
# Installation and uninstallation are safe: nothing foreign is overwritten or removed.
# Uses a temporary HOME; the real ~/.claude is never touched.
. "$(dirname "$0")/lib.sh"

INSTALL="$REPO/scripts/install.sh"
UNINSTALL="$REPO/scripts/uninstall.sh"
GC="$HOME/.claude"

describe "dry run changes nothing"
out=$(bash "$INSTALL" --global --dry-run)
assert_eq "$?" "0" "exit code"
assert_contains "$out" "[dry-run]   create   skills/ticket-dev/SKILL.md"
assert_no_file "$GC" "~/.claude after dry run"

describe "global install with pre-existing user configuration"
mkdir -p "$GC/agents" "$GC/skills/my-skill"
echo "my agent" >"$GC/agents/my-agent.md"
echo "my skill" >"$GC/skills/my-skill/SKILL.md"
echo '{"model":"opus"}' >"$GC/settings.json"
echo "# my rules" >"$GC/CLAUDE.md"
out=$(bash "$INSTALL" --global)
assert_eq "$?" "0" "exit code"
assert_file "$GC/skills/ticket-dev/SKILL.md"
assert_file "$GC/skills/ticket-dev/routing.conf"
assert_file "$GC/skills/ticket-dev/.install-manifest"
for a in explorer implementer verifier; do assert_file "$GC/agents/ticket-dev-$a.md"; done
[ -x "$GC/skills/ticket-dev/scripts/guard.sh" ] && pass || fail "scripts not executable"
assert_contains "$(cat "$GC/agents/ticket-dev-explorer.md")" "g=\"$GC/skills/ticket-dev/scripts/guard.sh\"" "global guard path"
assert_eq "$(cat "$GC/agents/my-agent.md")" "my agent" "foreign agent"
assert_eq "$(cat "$GC/skills/my-skill/SKILL.md")" "my skill" "foreign skill"
assert_eq "$(cat "$GC/settings.json")" '{"model":"opus"}' "settings.json"
assert_eq "$(cat "$GC/CLAUDE.md")" "# my rules" "CLAUDE.md"

describe "installed global hook finds its guard"
J='{"tool_name":"Bash","tool_input":{"command":"git push"}}'
cmd=$(sed -n "s/^ *command: '\(.*\)'$/\1/p" "$GC/agents/ticket-dev-implementer.md")
(cd "$TEST_TMP" && printf '%s' "$J" | CLAUDE_PROJECT_DIR="$TEST_TMP" sh -c "$cmd" 2>/dev/null)
assert_eq "$?" "2" "guard reached from any project"

describe "reinstall is idempotent"
out=$(bash "$INSTALL" --global)
assert_contains "$out" "Already up to date."

describe "CLAUDE_CONFIG_DIR is respected"
out=$(CLAUDE_CONFIG_DIR="$TEST_TMP/altconfig" bash "$INSTALL" --global)
assert_file "$TEST_TMP/altconfig/skills/ticket-dev/SKILL.md"

describe "a different file with the same name is never overwritten silently"
rm -rf "$GC/agents/ticket-dev-verifier.md"
echo "someone else's verifier" >"$GC/agents/ticket-dev-verifier.md"
out=$(bash "$INSTALL" --global </dev/null)
assert_eq "$?" "1" "exit code with conflict"
assert_contains "$out" "CONFLICT agents/ticket-dev-verifier.md"
assert_eq "$(cat "$GC/agents/ticket-dev-verifier.md")" "someone else's verifier" "untouched"

describe "--force replaces it and keeps a backup"
out=$(bash "$INSTALL" --global --force)
assert_eq "$?" "0" "exit code"
assert_contains "$(cat "$GC/agents/ticket-dev-verifier.md")" "name: ticket-dev-verifier" "replaced"
bak=$(ls "$GC/agents/" | grep 'ticket-dev-verifier.md.bak-' | head -n 1)
[ -n "$bak" ] && assert_eq "$(cat "$GC/agents/$bak")" "someone else's verifier" "backup" || fail "no backup"

describe "upgrades update untouched files and remove obsolete ones"
NEWREPO="$TEST_TMP/newversion"
cp -R "$REPO" "$NEWREPO"
echo "<!-- v2 -->" >>"$NEWREPO/.claude/skills/ticket-dev/SKILL.md"
rm "$NEWREPO/.claude/skills/ticket-dev/references/gpt-review.md"
out=$(bash "$NEWREPO/scripts/install.sh" --global </dev/null)
assert_eq "$?" "0" "exit code"
assert_contains "$out" "update   skills/ticket-dev/SKILL.md"
assert_contains "$(cat "$GC/skills/ticket-dev/SKILL.md")" "<!-- v2 -->" "updated"
assert_no_file "$GC/skills/ticket-dev/references/gpt-review.md" "obsolete file"
bash "$INSTALL" --global >/dev/null

describe "uninstall keeps files the user modified"
echo "# tuned" >>"$GC/skills/ticket-dev/routing.conf"
out=$(bash "$UNINSTALL" --global)
assert_eq "$?" "1" "exit code with kept files"
assert_contains "$out" "KEEP     skills/ticket-dev/routing.conf"
assert_file "$GC/skills/ticket-dev/routing.conf" "modified file"
assert_no_file "$GC/skills/ticket-dev/SKILL.md"
assert_no_file "$GC/agents/ticket-dev-explorer.md"
assert_file "$GC/skills/ticket-dev/.install-manifest" "manifest kept while modified files remain"

describe "uninstall --force moves modified files aside and removes only ours"
out=$(bash "$UNINSTALL" --global --force)
assert_eq "$?" "0" "exit code"
assert_no_file "$GC/skills/ticket-dev/routing.conf"
ls "$GC/skills/ticket-dev/" 2>/dev/null | grep -q 'routing.conf.bak-' && pass || fail "modified routing.conf not backed up"
assert_eq "$(cat "$GC/agents/my-agent.md")" "my agent" "foreign agent after uninstall"
assert_eq "$(cat "$GC/skills/my-skill/SKILL.md")" "my skill" "foreign skill after uninstall"
assert_file "$GC/settings.json"
[ -d "$GC/agents" ] && [ -d "$GC/skills" ] && pass || fail "shared directories removed"

describe "uninstall without a manifest removes nothing"
mkdir -p "$TEST_TMP/manual/.claude/skills/ticket-dev"
echo x >"$TEST_TMP/manual/.claude/skills/ticket-dev/SKILL.md"
out=$(bash "$UNINSTALL" --project "$TEST_TMP/manual")
assert_eq "$?" "1" "exit code"
assert_file "$TEST_TMP/manual/.claude/skills/ticket-dev/SKILL.md" "untouched"

describe "project install"
P="$TEST_TMP/app"
new_repo "$P"
mkdir -p "$P/.claude/ticket-dev"
echo "- house rule" >"$P/.claude/ticket-dev/conventions.md"
out=$(bash "$INSTALL" --project "$P")
assert_eq "$?" "0" "exit code"
assert_file "$P/.claude/skills/ticket-dev/SKILL.md"
assert_contains "$(cat "$P/.claude/agents/ticket-dev-implementer.md")" '$CLAUDE_PROJECT_DIR/.claude/skills/ticket-dev/scripts/guard.sh' "project guard path"
assert_contains "$out" "Commit .claude/skills/ticket-dev"
bash "$INSTALL" --global >/dev/null
out=$(bash "$INSTALL" --project "$P")
assert_contains "$out" "also installed globally" "precedence warning"
out=$(bash "$UNINSTALL" --project "$P")
assert_eq "$?" "0" "exit code"
assert_no_file "$P/.claude/skills/ticket-dev"
assert_file "$P/.claude/ticket-dev/conventions.md" "project settings kept"
assert_contains "$out" "Left in place"
assert_eq "$(git -C "$P" status --porcelain)" "?? .claude/" "only the user's own config remains"

describe "refuses to install into itself or a missing directory"
bash "$INSTALL" --project "$REPO" >/dev/null 2>&1
assert_eq "$?" "2" "self install"
bash "$INSTALL" --project "$TEST_TMP/missing" >/dev/null 2>&1
assert_eq "$?" "2" "missing dir"

finish
