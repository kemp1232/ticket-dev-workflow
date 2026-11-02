#!/usr/bin/env bash
# preflight.sh - deterministic context for /ticket-dev, injected when the skill starts.
#
# Prints the repository state (with a non-destructive baseline snapshot so the
# workflow can tell its own changes from pre-existing ones), project-specific
# configuration, routing models and candidate verification commands.
#
# MUST always exit 0: a failing injected command aborts the skill invocation.
# Bash 3.2 compatible.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MAX_STATUS_LINES=40
MAX_CONVENTION_LINES=80
MAX_SKILLS=30

echo "### Repository"
echo "root: $ROOT"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	branch=$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
	head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "")
	if [ -z "$head" ]; then
		echo "git: branch $branch, no commits yet"
		echo "baseline: none (no commits); every file counts as pre-existing work"
	else
		echo "git: branch $branch @ $head"
		# `git stash create` snapshots tracked changes as a dangling commit without
		# touching the working tree, the index or the stash list.
		snap=$(git -C "$ROOT" stash create 2>/dev/null || true)
		if [ -n "$snap" ]; then
			echo "baseline: $snap (snapshot of tracked files incl. uncommitted edits; \`git diff $snap\` shows only changes made after this point)"
		else
			echo "baseline: $(git -C "$ROOT" rev-parse HEAD) (HEAD; tracked files were clean)"
		fi
	fi
	status=$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all 2>/dev/null)
	if [ -z "$status" ]; then
		echo "pre-existing changes: none"
	else
		count=$(printf '%s\n' "$status" | wc -l | tr -d ' ')
		echo "pre-existing changes: $count (preserve them: never revert, stash, reset, stage or reformat these)"
		printf '%s\n' "$status" | head -n "$MAX_STATUS_LINES" | sed 's/^/  /'
		[ "$count" -gt "$MAX_STATUS_LINES" ] && echo "  ... $((count - MAX_STATUS_LINES)) more (run git status --short)"
	fi
else
	echo "git: NOT A GIT REPOSITORY - changes cannot be diffed or undone with git."
	echo "baseline: none. Ask the developer to confirm before editing any file."
fi

echo
echo "### Project configuration"
conv="$ROOT/.claude/ticket-dev/conventions.md"
if [ -f "$conv" ]; then
	echo "conventions (.claude/ticket-dev/conventions.md):"
	head -n "$MAX_CONVENTION_LINES" "$conv" | sed 's/^/  /'
	lines=$(wc -l <"$conv" | tr -d ' ')
	[ "$lines" -gt "$MAX_CONVENTION_LINES" ] && echo "  ... truncated at $MAX_CONVENTION_LINES of $lines lines; read the file if needed"
else
	echo "conventions: none (.claude/ticket-dev/conventions.md not present; CLAUDE.md still applies)"
fi

# Other project skills may hold conventions the subagents never see on their own.
# List name, description and path only; the orchestrator reads the relevant ones.
skills=""
for f in "$ROOT"/.claude/skills/*/SKILL.md; do
	[ -f "$f" ] || continue
	dir=$(basename "$(dirname "$f")")
	[ "$dir" = ticket-dev ] && continue
	info=$(awk -v dir="$dir" '
		NR == 1 { if ($0 != "---") exit; fm = 1; next }
		fm && $0 == "---" { exit }
		fm && /^name:/ { sub(/^name:[[:space:]]*/, ""); name = $0; next }
		fm && /^description:/ {
			sub(/^description:[[:space:]]*/, ""); desc = $0
			if (desc ~ /^[>|]/) { desc = ""; folded = 1 }
			next
		}
		fm && folded && /^[[:space:]]+[^[:space:]]/ { sub(/^[[:space:]]+/, ""); desc = desc (desc == "" ? "" : " ") $0; next }
		fm { folded = 0 }
		END {
			if (name == "") name = dir
			gsub(/^["\047]|["\047]$/, "", name); gsub(/^["\047]|["\047]$/, "", desc)
			if (desc == "") desc = "(no description)"
			if (length(desc) > 160) desc = substr(desc, 1, 157) "..."
			print name " - " desc
		}' "$f")
	skills="$skills  $info (.claude/skills/$dir/SKILL.md)
"
done
if [ -n "$skills" ]; then
	count=$(printf '%s' "$skills" | grep -c '^  ')
	echo "project skills: $count (read the relevant ones; subagents do not see them)"
	printf '%s' "$skills" | head -n "$MAX_SKILLS"
	[ "$count" -gt "$MAX_SKILLS" ] && echo "  ... $((count - MAX_SKILLS)) more in .claude/skills/"
else
	echo "project skills: none"
fi

# .claude/rules/ load automatically (path-scoped ones when a matching file is read or
# edited), in subagents too, so the orchestrator should not copy them anywhere.
rules=""
if [ -d "$ROOT/.claude/rules" ]; then
	rules=$(cd "$ROOT" && find .claude/rules -type f -name '*.md' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
		scope=$(awk '
			NR == 1 { if ($0 != "---") exit; fm = 1; next }
			fm && $0 == "---" { exit }
			fm && /^paths:/ {
				v = $0; sub(/^paths:[[:space:]]*/, "", v); gsub(/[]["\047]/, "", v)
				if (v != "") out = v; inlist = 1; next
			}
			fm && inlist && /^[[:space:]]*-[[:space:]]/ {
				v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); gsub(/["\047]/, "", v)
				out = out (out == "" ? "" : ", ") v; next
			}
			fm { inlist = 0 }
			END { print (out == "" ? "always loaded" : "when touching " out) }' "$f")
		echo "  $f - $scope"
	done)
fi
if [ -n "$rules" ]; then
	count=$(printf '%s\n' "$rules" | wc -l | tr -d ' ')
	echo "project rules: $count (load automatically, also in subagents; follow them, no need to copy them)"
	printf '%s\n' "$rules" | head -n "$MAX_SKILLS"
	[ "$count" -gt "$MAX_SKILLS" ] && echo "  ... $((count - MAX_SKILLS)) more in .claude/rules/"
else
	echo "project rules: none (.claude/rules/)"
fi
bash "$SCRIPT_DIR/route.sh" --print-config --project-dir "$ROOT" 2>&1 | sed 's/^/  /' | sed '1s/^  /routing: /'

echo
echo "### Verification candidates"
bash "$SCRIPT_DIR/detect-checks.sh" "$ROOT" 2>&1

echo
echo "### Scripts (pass these absolute paths to subagents)"
echo "route: bash $SCRIPT_DIR/route.sh"
echo "run-check: bash $SCRIPT_DIR/run-check.sh"
echo "scan-secrets: bash $SCRIPT_DIR/scan-secrets.sh"
exit 0
