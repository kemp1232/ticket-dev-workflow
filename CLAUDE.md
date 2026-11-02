# ticket-dev-workflow

Reusable Claude Code workflow (`/ticket-dev`). Developer tooling, not an application.

- Source of truth: `.claude/skills/ticket-dev/` and `.claude/agents/ticket-dev-*.md`; `scripts/install.sh` copies them into `~/.claude` or a project.
- Test: `bash tests/run.sh` (offline, temp dirs only; stubs stand in for claude, codex and playwright-cli). Live: `TICKET_DEV_LIVE=1 bash tests/smoke.sh` uses Claude usage; ask first. `tests/live.sh` holds opt-in real Codex, browser and worktree checks (each behind its own `TICKET_DEV_LIVE_*` variable); it is not part of run.sh.
- Shell scripts must stay bash 3.2 and BSD compatible (macOS): no associative arrays, `mapfile`, `${x,,}`, `grep -P`, `readlink -f`, or bare `sed -i`. `preflight.sh` must always exit 0.
- Model names live only in `routing.conf` (agent `model:` lines are fallbacks kept equal by tests). Never pin model IDs.
- Keep `SKILL.md` short; put detail in `references/`. Do not add agents or scripts without a clear, distinct responsibility.
- When changing guard rules, add allow and deny cases to `tests/test_guard.sh`.
- Optional stages (worktrees, browser, Codex) stay off by default; plain `/ticket-dev` must behave as before. Anything that sends code to another provider needs per-project or per-ticket opt-in.
