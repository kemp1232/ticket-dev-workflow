#!/usr/bin/env bash
# uninstall.sh - remove what scripts/install.sh installed, and nothing else.
#
#   scripts/uninstall.sh --global          from ~/.claude (or $CLAUDE_CONFIG_DIR)
#   scripts/uninstall.sh --project DIR     from DIR/.claude
#
# Options:
#   --dry-run   print what would happen and change nothing
#   --force     also remove files you modified after installing (they are renamed
#               to <file>.bak-<timestamp> rather than deleted)
#
# Only files listed in the install manifest are touched. Project settings in
# .claude/ticket-dev/ are yours and are left in place. Bash 3.2 compatible.

set -u
set -f

SCOPE=""
PROJECT=""
DRY=0
FORCE=0

usage() {
	sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
	--global) SCOPE=global ;;
	--project)
		[ $# -ge 2 ] || usage
		SCOPE=project
		PROJECT=$2
		shift
		;;
	--dry-run) DRY=1 ;;
	--force) FORCE=1 ;;
	-h | --help) usage ;;
	*) echo "unknown option: $1" >&2; usage ;;
	esac
	shift
done
[ -n "$SCOPE" ] || usage

if [ "$SCOPE" = global ]; then
	TARGET=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
else
	[ -d "$PROJECT" ] || { echo "error: project directory not found: $PROJECT" >&2; exit 2; }
	TARGET="$(cd "$PROJECT" && pwd)/.claude"
fi

MANIFEST="$TARGET/skills/ticket-dev/.install-manifest"
if [ ! -f "$MANIFEST" ]; then
	echo "No ticket-dev install manifest at $MANIFEST; nothing was removed."
	echo "If you copied the files by hand, delete $TARGET/skills/ticket-dev and $TARGET/agents/ticket-dev-*.md yourself."
	exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
sum() { cksum <"$1" | awk '{ print $1 "-" $2 }'; }
say() { if [ "$DRY" -eq 1 ]; then echo "[dry-run] $*"; else echo "$*"; fi; }

echo "Uninstalling ticket-dev - scope: $SCOPE - target: $TARGET"
kept=0
while read -r recorded rel; do
	case "$recorded" in '' | '#'*) continue ;; esac
	case "$rel" in skills/ticket-dev/* | agents/ticket-dev-*.md) ;; *)
		echo "  skip     $rel (outside ticket-dev paths; manifest entry ignored)"
		continue
		;;
	esac
	dst="$TARGET/$rel"
	[ -e "$dst" ] || continue
	if [ "$(sum "$dst")" = "$recorded" ]; then
		say "  remove   $rel"
		[ "$DRY" -eq 1 ] || rm -f "$dst"
	elif [ "$FORCE" -eq 1 ]; then
		say "  backup   $rel -> $rel.bak-$STAMP (modified after install)"
		[ "$DRY" -eq 1 ] || mv "$dst" "$dst.bak-$STAMP"
	else
		echo "  KEEP     $rel (modified after install; use --force to move it aside)"
		kept=$((kept + 1))
	fi
done <"$MANIFEST"

if [ "$DRY" -eq 0 ]; then
	if [ "$kept" -eq 0 ]; then
		rm -f "$MANIFEST"
		# Remove now-empty directories inside the skill, never skills/ or agents/ themselves.
		find "$TARGET/skills/ticket-dev" -depth -type d -empty -exec rmdir {} \; 2>/dev/null
	else
		echo "The manifest is kept because $kept modified file(s) remain."
	fi
fi

[ -d "$TARGET/ticket-dev" ] && echo "Left in place: $TARGET/ticket-dev (your project settings)."
echo "Done. Open Claude Code sessions drop the skill automatically; restart if /ticket-dev still appears."
[ "$kept" -eq 0 ] || exit 1
exit 0
