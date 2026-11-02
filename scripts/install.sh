#!/usr/bin/env bash
# install.sh - install the /ticket-dev skill and its subagents for Claude Code.
#
#   scripts/install.sh --global          into ~/.claude (or $CLAUDE_CONFIG_DIR): every project
#   scripts/install.sh --project DIR     into DIR/.claude: commit it with that repository
#
# Options:
#   --dry-run   print what would happen and change nothing
#   --force     replace files that differ from this version, keeping a .bak-<timestamp> copy
#
# Safe by default: never uses sudo, never edits settings.json or CLAUDE.md, and never
# overwrites a file it did not install (or that you modified) without --force or an
# interactive "yes". A manifest records what was installed so upgrades and
# scripts/uninstall.sh touch only those files. Bash 3.2 compatible.

set -u
set -f

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/.claude"
SCOPE=""
PROJECT=""
DRY=0
FORCE=0

usage() {
	sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
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
	PROJECT=$(cd "$PROJECT" && pwd)
	if [ "$PROJECT" = "$REPO" ]; then
		echo "error: $PROJECT is the ticket-dev-workflow repository itself; it already contains the workflow." >&2
		exit 2
	fi
	TARGET="$PROJECT/.claude"
	git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1 ||
		echo "warning: $PROJECT is not a git repository; /ticket-dev will ask before editing there."
fi

MANIFEST_REL="skills/ticket-dev/.install-manifest"
MANIFEST="$TARGET/$MANIFEST_REL"
STAMP=$(date +%Y%m%d-%H%M%S)
VERSION=$(git -C "$REPO" describe --always --dirty 2>/dev/null || echo "unversioned")
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ticket-dev-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

sum() { cksum <"$1" | awk '{ print $1 "-" $2 }'; }
say() { if [ "$DRY" -eq 1 ]; then echo "[dry-run] $*"; else echo "$*"; fi; }
recorded_sum() { [ -f "$MANIFEST" ] && awk -v p="$1" '$2 == p { print $1 }' "$MANIFEST" | head -n 1; }

# Files that belong to the workflow, relative to .claude/.
FILES=$(cd "$SRC" && {
	find skills/ticket-dev -type f ! -name '.install-manifest' ! -name '*.bak-*' ! -name '.DS_Store'
	find agents -type f -name 'ticket-dev-*.md'
} | LC_ALL=C sort)
[ -n "$FILES" ] || { echo "error: no workflow files found under $SRC" >&2; exit 2; }

# Global agents cannot rely on $CLAUDE_PROJECT_DIR to find the guard script.
render() { # rel -> path of the content to install
	case "$1" in
	agents/*)
		if [ "$SCOPE" = global ]; then
			esc=$(printf '%s' "$TARGET" | sed -e 's/[\\&#]/\\&/g')
			sed "s#\\\$CLAUDE_PROJECT_DIR/\\.claude/skills/ticket-dev/#$esc/skills/ticket-dev/#g" "$SRC/$1" >"$TMP/render"
			echo "$TMP/render"
			return
		fi
		;;
	esac
	echo "$SRC/$1"
}

confirm() { # question -> 0 yes
	[ "$FORCE" -eq 1 ] && return 0
	[ "$DRY" -eq 1 ] && return 1
	[ -t 0 ] || return 1
	printf '%s [y/N] ' "$1"
	read -r ans
	case "$ans" in y | Y | yes | YES) return 0 ;; esac
	return 1
}

had_skills=0
had_agents=0
[ -d "$TARGET/skills" ] && had_skills=1
[ -d "$TARGET/agents" ] && had_agents=1

echo "Installing ticket-dev ($VERSION) - scope: $SCOPE - target: $TARGET"
NEW_MANIFEST="$TMP/manifest"
{
	echo "# ticket-dev install manifest: <cksum-size> <path relative to $TARGET>"
	echo "# version $VERSION, scope $SCOPE, installed $STAMP"
} >"$NEW_MANIFEST"

conflicts=0
changed=0
for rel in $FILES; do
	from=$(render "$rel")
	dst="$TARGET/$rel"
	new=$(sum "$from")
	if [ ! -e "$dst" ]; then
		say "  create   $rel"
		action=write
	elif [ "$(sum "$dst")" = "$new" ]; then
		action=keep
	elif [ -n "$(recorded_sum "$rel")" ] && [ "$(recorded_sum "$rel")" = "$(sum "$dst")" ]; then
		say "  update   $rel"
		action=write
	elif confirm "  $rel exists and differs (not installed by this tool, or modified by you). Replace it? A backup is kept."; then
		say "  replace  $rel (backup: $rel.bak-$STAMP)"
		[ "$DRY" -eq 1 ] || cp -p "$dst" "$dst.bak-$STAMP"
		action=write
	else
		echo "  CONFLICT $rel differs; left untouched (rerun with --force to replace it, keeping a backup)"
		conflicts=$((conflicts + 1))
		# Still ours if an earlier install wrote it: keep that entry so uninstall reports it.
		old=$(recorded_sum "$rel")
		[ -n "$old" ] && echo "$old $rel" >>"$NEW_MANIFEST"
		continue
	fi
	if [ "$action" = write ] && [ "$DRY" -eq 0 ]; then
		mkdir -p "$(dirname "$dst")"
		cp "$from" "$dst"
		case "$rel" in *.sh) chmod 755 "$dst" ;; *) chmod 644 "$dst" ;; esac
	fi
	[ "$action" = write ] && changed=$((changed + 1))
	echo "$new $rel" >>"$NEW_MANIFEST"
done

# Files from a previous version that this version no longer ships.
if [ -f "$MANIFEST" ]; then
	for rel in $(awk '!/^#/ { print $2 }' "$MANIFEST"); do
		printf '%s\n' "$FILES" | grep -qxF "$rel" && continue
		dst="$TARGET/$rel"
		[ -e "$dst" ] || continue
		if [ "$(sum "$dst")" = "$(recorded_sum "$rel")" ]; then
			say "  remove   $rel (no longer part of ticket-dev)"
			[ "$DRY" -eq 1 ] || rm -f "$dst"
		else
			echo "  keep     $rel (obsolete but modified by you)"
		fi
	done
fi

if [ "$DRY" -eq 0 ]; then
	mkdir -p "$(dirname "$MANIFEST")"
	cp "$NEW_MANIFEST" "$MANIFEST"
fi

echo
if [ "$changed" -eq 0 ] && [ "$conflicts" -eq 0 ]; then
	echo "Already up to date."
else
	say "$changed file(s) installed or updated."
fi

GLOBAL_MANIFEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/$MANIFEST_REL"
if [ "$SCOPE" = project ] && [ -f "$GLOBAL_MANIFEST" ]; then
	cat <<EOF
Note: ticket-dev is also installed globally. Claude Code gives personal skills
precedence over project skills, so /ticket-dev will use the GLOBAL SKILL.md and scripts,
while subagents resolve to this project's copies. Keep both on the same version, or
remove one with scripts/uninstall.sh.
EOF
fi

if [ "$had_agents" -eq 0 ] && [ "$DRY" -eq 0 ]; then
	echo "Restart Claude Code: $TARGET/agents is new, and new agent directories are only picked up at startup."
elif [ "$had_skills" -eq 0 ] && [ "$DRY" -eq 0 ]; then
	echo "Run /reload-skills in open Claude Code sessions (or restart): $TARGET/skills is new."
else
	echo "Open sessions pick up the changes automatically; if /ticket-dev is missing, run /reload-skills or restart."
fi
if [ "$SCOPE" = project ]; then
	echo "Commit .claude/skills/ticket-dev and .claude/agents/ticket-dev-*.md to share it with your team."
	echo "Optional project settings: copy files from $REPO/examples/project-config/ into $PROJECT/.claude/ticket-dev/."
	echo "Accept the workspace trust prompt for this folder so the subagents' safety hooks run."
fi
[ "$conflicts" -eq 0 ] || exit 1
exit 0
