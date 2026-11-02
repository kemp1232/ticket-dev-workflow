# ticket-dev-workflow

Reusable Claude Code workflow (`/ticket-dev`). Developer tooling, not an application.

- Source of truth: `.claude/skills/ticket-dev/` and `.claude/agents/ticket-dev-*.md`; `scripts/install.sh` copies them into `~/.claude` or a project.
- Test: `bash tests/run.sh` (offline, temp dirs only). Live: `TICKET_DEV_LIVE=1 bash tests/smoke.sh` uses Claude usage; ask first.
- Shell scripts must stay bash 3.2 and BSD compatible (macOS): no associative arrays, `mapfile`, `${x,,}`, `grep -P`, `readlink -f`, or bare `sed -i`. `preflight.sh` must always exit 0.
- Model names live only in `routing.conf` (agent `model:` lines are fallbacks kept equal by tests). Never pin model IDs.
- Keep `SKILL.md` short; put detail in `references/`. Do not add agents or scripts without a clear, distinct responsibility.
- When changing guard rules, add allow and deny cases to `tests/test_guard.sh`.
