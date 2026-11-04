#!/usr/bin/env bash
# Shared helpers for the test suite. Every test works in a temporary directory with
# a temporary HOME, so it never touches real projects or the real Claude Code setup.
# Bash 3.2 compatible.

set -u

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SKILL="$REPO/.claude/skills/ticket-dev"
SCRIPTS="$SKILL/scripts"
AGENTS="$REPO/.claude/agents"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ticket-dev-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
REAL_HOME=$HOME
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR
# Per-ticket temp dirs (ticket-env.sh) go inside the test's temp dir and vanish with it.
export TICKET_DEV_TMP_BASE="$TEST_TMP/tmpbase"
unset TICKET_DEV_LOG_DIR TICKET_DEV_PORT TICKET_DEV_TICKET
# Tests run inside Claude Code sessions too: never detect the real session process.
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID
export TICKET_DEV_SESSION_PID=0
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

PASSED=0
FAILED=0
CURRENT=""

describe() { CURRENT=$1; }
pass() { PASSED=$((PASSED + 1)); }
fail() {
	FAILED=$((FAILED + 1))
	echo "  FAIL [$CURRENT] $1" >&2
}

assert_eq() { # actual expected [message]
	if [ "$1" = "$2" ]; then pass; else fail "${3:-value}: expected '$2', got '$1'"; fi
}
assert_contains() { # haystack needle [message]
	case "$1" in *"$2"*) pass ;; *) fail "${3:-output} should contain '$2'; got: $(printf '%s' "$1" | head -c 300)" ;; esac
}
assert_not_contains() {
	case "$1" in *"$2"*) fail "${3:-output} should not contain '$2'" ;; *) pass ;; esac
}
assert_file() { if [ -f "$1" ]; then pass; else fail "${2:-file} missing: $1"; fi; }
assert_no_file() { if [ -e "$1" ]; then fail "${2:-path} should not exist: $1"; else pass; fi; }

# kv KEY "key=value lines" -> value
kv() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -n 1; }

# new_repo DIR: git repository with one commit
new_repo() {
	mkdir -p "$1"
	git -C "$1" init -q
	git -C "$1" checkout -q -b main 2>/dev/null || true
	echo "# repo" >"$1/README.md"
	git -C "$1" add -A
	git -C "$1" commit -qm init
}

finish() {
	echo "$(basename "$0"): $PASSED passed, $FAILED failed"
	[ "$FAILED" -eq 0 ]
}
