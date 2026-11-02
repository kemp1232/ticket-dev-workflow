# Design notes

Written for maintainers. They cover why the workflow is built the way it is, which documented Claude Code behavior it relies on, and what was deliberately left out. Verified against the official documentation and Claude Code v2.1.301 (October 2026).

## Capabilities relied on

| Capability | Documented in | How it is used | Verified |
|---|---|---|---|
| Skills with `disable-model-invocation`, `argument-hint`, `allowed-tools`, `$ARGUMENTS`, `${CLAUDE_SKILL_DIR}` | [skills](https://code.claude.com/docs/en/skills) | Orchestrator definition | Live run: skill listed and invoked headlessly |
| `` !`command` `` injection; a non-zero exit aborts the skill; outside auto mode the command must be allowed | skills | `preflight.sh` always exits 0 and is pre-approved via `Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*)` | Live run in `acceptEdits` mode |
| Supporting files loaded on demand; keep SKILL.md under 500 lines | skills | `references/*.md` | test_structure.sh |
| Subagent frontmatter: `tools`, `model`, `maxTurns`, `hooks`, `color` | [sub-agents](https://code.claude.com/docs/en/sub-agents) | Three agents | Live run |
| Per-invocation `model` parameter overrides the frontmatter model | sub-agents ("Choose a model") | One implementer, model chosen by route.sh | Live transcript shows `"model":"haiku"` on the Agent call |
| Subagents get CLAUDE.md and git status but not the conversation; no `AskUserQuestion` in subagents | sub-agents | Orchestrator passes self-contained prompts; only the orchestrator asks questions | Docs |
| Frontmatter `PreToolUse` hooks; exit 2 blocks; project agent hooks need workspace trust and do not run under `-p` | sub-agents, [hooks](https://code.claude.com/docs/en/hooks) | `guard.sh` | Live run with `--agents`: `touch` blocked, `ls` allowed |
| Resuming a subagent with SendMessage | sub-agents | PLAN, then IMPLEMENT, on the same Opus implementer | Docs (fallback: new invocation with the approved plan) |
| Model aliases `haiku`, `sonnet`, `opus`, `fable`; `ANTHROPIC_DEFAULT_*_MODEL` pinning; `availableModels` | [model-config](https://code.claude.com/docs/en/model-config) | `routing.conf` holds aliases only | Docs |
| Skill and agent directories are watched; new directories need `/reload-skills` or a restart | skills, sub-agents | Installer messages | Docs |
| Personal skills override project skills; project agents override user agents | skills, sub-agents | Installer warns about dual installs | Docs |
| `-p` loads the first skill with the rest of the line as arguments; `--output-format json` reports cost and usage | skills, [headless](https://code.claude.com/docs/en/headless) | Smoke test, benchmarking | Live run |

Observed in this version: the native build exposes no `Grep` or `Glob` tools (search goes through Bash). Agents still list `Grep, Glob` so builds that have them can use them; unknown tool names are ignored. Because the explorer therefore needs Bash, read-only behavior is enforced by the guard hook rather than by the tool list alone.

## Decisions

**One implementer, model per invocation, instead of three agent files.** Three near-identical files (`implement-lightweight/standard/complex`) would put the model choice in three places and duplicate the instructions. The documented per-invocation `model` parameter lets `routing.conf` be the single source of truth. Tier-specific behavior (escalate early on the light route; re-check assumptions and plan first on the complex route) is a short section in the one agent.

**Deterministic router instead of an assessor model.** The orchestrator already has the evidence in context. A second model call to classify the ticket would add cost and variance. `route.sh` makes the decision reproducible and testable, and keyword flags that must be explicitly dismissed stop silent downgrades.

**The orchestrator runs on the session model.** The skill's `model` field would switch the rest of the turn to a fixed model. That was rejected because it overrides the developer's choice, and the orchestrator's work (judgment over summaries) benefits from a strong model while costing little context. The README recommends Sonnet for cost-conscious sessions.

**No `context: fork` for the orchestrator.** It needs `AskUserQuestion` and the approval gates, which subagents do not have.

**Verifier as a Haiku subagent plus `run-check.sh`.** This keeps test output out of the main context. The verifier only runs commands and maps evidence, so a small model is enough, and the script makes PASS, FAIL, SKIP and TIMEOUT unambiguous. There is no second AI review on top. The orchestrator reads only flagged hunks.

**Baseline via `git stash create`.** This snapshots tracked changes as a dangling commit without touching the working tree, index or stash list. It is the only reliable way to separate the ticket's diff from pre-existing uncommitted edits in the same files.

**Bash scripts, bash 3.2 compatible.** They run on stock macOS and Linux with no Node or Python requirement, so the workflow stays technology-agnostic. `jq` is used when present.

**No persistent spec files.** The contract lives in the conversation. Files are written only for the optional GPT package, outside the repository.

**Project rules over copied conventions.** `.claude/rules/` files with `paths:` frontmatter load automatically when a matching file is read or edited, in subagents too ([memory docs](https://code.claude.com/docs/en/memory)). They are therefore the best home for area-specific code conventions. Preflight lists them so the orchestrator knows they exist, but nothing copies them. Project *skills* still need copying into the contract, because subagents with a `tools` allowlist cannot invoke them.

**Code intelligence is optional but wired in.** The explorer and implementer list the `LSP` tool, which exists only when a code intelligence plugin is installed ([docs](https://code.claude.com/docs/en/plugins/code-intelligence)). Diagnostics after edits reach the implementer automatically. Unknown tool names are ignored, so nothing breaks without a plugin.

**Independent review only where it pays.** The docs recommend a fresh-context review for long or risky work, and warn that reviewers asked for gaps will usually find some. So `/code-review high` runs only for `REVIEW_ROUTES` (default: complex). Only correctness or requirement findings inside the ticket's own changes count, and fixes go through the implementer within the existing two-round cap. `--fix` is never used, so edits stay behind the implementer's guard.

## Known limitations

- Gates, retry caps and per-invocation model choice are instructions to the model, not enforced code. The live smoke tests exercise them, but they cannot guarantee them.
- The guard is text-based and bypassable on purpose (for example `eval` of an encoded string). It protects against mistakes, not against an adversarial agent.
- Project-level agent hooks require workspace trust and are skipped under `claude -p`.
- The skill's `allowed-tools` grant ends with the invoking turn, so after a gate you may see permission prompts for the workflow's own scripts in manual mode.
- Keyword triage is English-only and approximate; it raises flags for review and never lowers risk.

## Future OpenAI API adapter (not implemented)

A Version 2 could automate the manual GPT review without changing the workflow's shape:

- **Script:** `scripts/gpt-review-api.sh <package-file>`. It runs `scan-secrets.sh` first and refuses unless the result is `CLEAN`, then sends the package to the OpenAI Responses API, writes the reply next to the package, and prints its path.
- **Configuration:**
  - `OPENAI_API_KEY`, read from the environment and never written to disk;
  - `TICKET_DEV_GPT_MODEL`, with no default, so the developer chooses the model;
  - `TICKET_DEV_GPT_MAX_OUTPUT_TOKENS`.
- **Invocation:** `--gpt=api`, opt-in per ticket. The default stays manual. The script is never called automatically and never on the critical path; failures fall back to the manual flow.
- **Feedback:** handled exactly like pasted feedback (VERIFIED / CONFLICTS / UNVERIFIABLE / OUT OF SCOPE).
- **Billing:** API calls are billed by OpenAI separately from a ChatGPT subscription. Document that before enabling it.

## Version 2 ideas

- Effort routing per route (`effort` per invocation) once benchmarks show where it helps.
- An optional Stop or SubagentStop hook that refuses to end a ticket while the verifier's last verdict is FAIL.
- Packaging as a Claude Code plugin with a marketplace entry, removing the install script.
- A benchmark runner script on top of `claude -p --output-format json`, and a results dashboard.
- Language-aware check targeting: map changed files to their test files automatically.
- Optional issue-tracker intake (`/ticket-dev #123` through `gh` or an MCP server), still without making any service mandatory.
