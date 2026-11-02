# ticket-dev-workflow

`/ticket-dev` is a Claude Code skill that takes a development ticket from a one-line description to a verified change in an existing repository. You describe the ticket once. The workflow then:

1. explores the relevant code,
2. rates complexity and risk from evidence,
3. writes a short implementation contract,
4. routes implementation to Haiku, Sonnet or Opus,
5. runs the repository's own checks,
6. reports what changed and what is still risky.

Its goals are fewer prompts, less context and AI usage, and no hallucinated paths or "tests passed" claims. Correctness comes first.

This is developer tooling, not an application template. It is technology-agnostic: it detects and uses whatever checks a repository already has (TypeScript, ESLint, Jest/Vitest/node:test, Go, Python, Rust, Make, Gradle/Maven) and can be told about others.

```
/ticket-dev Implement pagination on the existing products API
/ticket-dev Add audit logging for profile updates. Start with @src/services/users
/ticket-dev --plan-only Sync Stripe subscription status via webhooks
```

## Contents

- [Quick start](#quick-start)
- [How a ticket runs](#how-a-ticket-runs)
- [Architecture](#architecture)
- [Installation](#installation)
- [Using /ticket-dev](#using-ticket-dev)
- [How models are selected](#how-models-are-selected)
- [Project-specific conventions](#project-specific-conventions)
- [Optional GPT review](#optional-gpt-review)
- [Safety](#safety)
- [Usage and cost](#usage-and-cost)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Repository layout](#repository-layout)

## Quick start

Requirements: Claude Code (tested with v2.1.301), bash, git. No OpenAI key, no extra services, no `sudo`. `jq` is used when present but not required.

```bash
git clone <this repo> ticket-dev-workflow
cd ticket-dev-workflow
./scripts/install.sh --global                  # all your projects
# or: ./scripts/install.sh --project ~/code/my-app   (commit it with that repo)
```

Restart Claude Code if the installer says so. Then open your project in VS Code, start Claude Code, and run:

```
/ticket-dev Implement pagination on the existing products API
```

To try it without changing anything, add `--plan-only`.

**Recommended: install a code intelligence plugin for your language.** It gives the explorer and implementer symbol navigation (fewer file reads) and type errors right after each edit. For TypeScript/JavaScript:

```bash
npm install -g typescript-language-server typescript     # the language server
# then inside Claude Code:
/plugin install typescript-lsp@claude-plugins-official
```

Other languages use the same pattern: Go (`gopls-lsp`, binary `gopls`), Python (`pyright-lsp`, `pyright-langserver`), Rust (`rust-analyzer-lsp`, `rust-analyzer`) and more; see the [code intelligence docs](https://code.claude.com/docs/en/plugins/code-intelligence). The workflow works without it; the agents simply use the `LSP` tool when it exists.

## How a ticket runs

```
/ticket-dev <ticket> [@paths] [flags]
        │
        ▼
 preflight.sh ─ git state + baseline snapshot, project config, models, the repo's check commands
        │                                                           (deterministic, no model)
        ▼
 triage ─ route.sh --triage: risk keywords → fast path (trivial) or exploration
        │
        ├─► ticket-dev-explorer (haiku, read-only) ─ compact map of files, patterns, tests, risks
        ▼
 assess ─ route.sh: evidence → complexity, risk, route, model, gates  (same inputs ⇒ same answer)
        ▼
 contract ─ objective, acceptance criteria, affected code (path:line), risks, verification plan
        ▼
 gates ─ blocking questions · plan approval (HIGH) · optional GPT review · --plan-only stop
        ▼
 ticket-dev-implementer (model chosen per invocation: haiku | sonnet | opus)
        ▼
 ticket-dev-verifier (haiku) ─ runs checks via run-check.sh, scope vs baseline, criteria → evidence
        ▼
 diff review by the orchestrator ─ report with verbatim check results, assumptions and risks
```

What each level looks like in practice:

| | LOW | MEDIUM | HIGH |
|---|---|---|---|
| Exploration | Often skipped (fast path) | Haiku explorer | Haiku explorer |
| Contract | Compact, in chat | Standard | Standard + Opus plan |
| Implementation | Haiku (light route) or Sonnet | Sonnet | Opus |
| Approval | No | Only for blocking questions | Plan approval; required for HIGH risk |
| GPT review | Never | Offered only if uncertainty is high | Offered only if independent reasoning would change the outcome |
| Verification | Targeted tests | + typecheck + lint | + full suite + build |
| Independent review | No | No | `/code-review` in a fresh context after the checks pass |

See [examples/tickets.md](examples/tickets.md) for a simple frontend fix, a moderate API feature and a complex database/external integration ticket. Each one includes the real routing output.

## Architecture

The design uses native Claude Code features only: a skill, three custom subagents and hooks. Each piece exists for a specific reason.

| Component | Where | Why it exists |
|---|---|---|
| `/ticket-dev` skill (orchestrator) | `.claude/skills/ticket-dev/SKILL.md` | Coordinates the workflow in your main session. It is short (about 100 lines); details live in `references/` and load only when needed. `disable-model-invocation: true`, so it runs only when you invoke it. |
| `preflight.sh` | `scripts/` | Injected into the skill when it starts (`` !`…` ``): git status, a non-destructive baseline (`git stash create`), project config, models and check commands, at no model cost. |
| `route.sh` + `routing.conf` + `risk-keywords.txt` | skill root and `scripts/` | Deterministic assessor/router. The model supplies evidence; the script applies the policy the same way every time. All model names live in `routing.conf`. |
| `detect-checks.sh`, `run-check.sh` | `scripts/` | Find the repository's own verification commands, and run them with an unambiguous `[PASS]`/`[FAIL]`/`[SKIP]`/`[TIMEOUT]` status and trimmed output. |
| `guard.sh` | `scripts/` | `PreToolUse` hook that keeps each subagent in its role (see [Safety](#safety)). |
| `scan-secrets.sh` | `scripts/` | Checks a GPT review package for credentials and personal data before you copy it. |
| `ticket-dev-explorer` | `.claude/agents/` | Context isolation: exploration output stays out of your session, and only a compact summary returns. Runs on Haiku; read-only. |
| `ticket-dev-implementer` | `.claude/agents/` | One implementer whose model is chosen **per invocation** by the router (haiku, sonnet or opus), so there are no three near-identical agent files to keep in sync. |
| `ticket-dev-verifier` | `.claude/agents/` | Keeps verbose test output out of your session and reports exactly what ran. Runs on Haiku; never edits. |

Design decisions, the documentation they rely on, and rejected alternatives are in [docs/design-notes.md](docs/design-notes.md).

## Installation

### Global (all your projects)

```bash
./scripts/install.sh --global            # into ~/.claude (or $CLAUDE_CONFIG_DIR)
./scripts/install.sh --global --dry-run  # show what would happen
```

### Project (version-controlled with one repository)

```bash
./scripts/install.sh --project /path/to/repo
cd /path/to/repo && git add .claude/skills/ticket-dev .claude/agents/ticket-dev-*.md
```

When you first open the project, accept Claude Code's workspace trust prompt. Hooks defined by project-level subagents, which is how the safety guard runs, only run in trusted folders.

### What the installer does and does not do

- It copies `skills/ticket-dev/` and `agents/ticket-dev-*.md`. It never touches `settings.json`, `CLAUDE.md`, other skills or agents, and it never uses `sudo`.
- A file that exists with different content (not installed by this tool, or modified by you) is **not** overwritten. You get a `CONFLICT` line and exit code 1, unless you answer "y" interactively or pass `--force`, which keeps a `.bak-<timestamp>` copy.
- A manifest (`skills/ticket-dev/.install-manifest`) records checksums. Re-running the installer upgrades only files that are still as installed, and removes files a newer version no longer ships.
- **Restart:** skills are picked up live. If the installer created a new `agents/` directory, restart Claude Code (new agent directories are only read at startup). If it created a new `skills/` directory, run `/reload-skills` or restart. The installer tells you which applies.
- **Do not install both globally and in the same project.** Claude Code gives personal skills precedence over project skills, but project agents precedence over user agents, so you would mix versions. The installer warns when this happens.

### Uninstall

```bash
./scripts/uninstall.sh --global
./scripts/uninstall.sh --project /path/to/repo
./scripts/uninstall.sh --global --dry-run
```

Only files listed in the manifest are removed. Files you modified since installing are kept (exit code 1) unless you pass `--force`, which moves them to `.bak-<timestamp>`. Your project settings in `.claude/ticket-dev/` are never removed.

## Using /ticket-dev

```
/ticket-dev <ticket text> [@path ...] [--plan-only] [--model haiku|sonnet|opus] [--gpt]
```

| Flag | Effect |
|---|---|
| `@path` | Starting hints for exploration (files or folders). The workflow still looks beyond them. |
| `--plan-only` | Stops after the contract and routing (and the Opus plan for HIGH tickets). Edits nothing. Reply `proceed` to implement in the same session without re-exploring. |
| `--model <alias>` | Forces the implementation model. If it is below the computed route for a high-risk ticket, the report says so. |
| `--gpt` | Prepares a GPT review package even if one was not suggested. |

What you will see:

1. A contract: compact for trivial tickets, standard otherwise.
2. A stop only when needed: a blocking question, plan approval for HIGH tickets, or an optional GPT-review offer. Reply in plain words, such as `approved`, `proceed`, `use offset pagination`, or `skip`.
3. A report with the routing decision, changed files, verbatim check lines, assumptions, and remaining risks. It also has a **review checklist** for your own review: one row per acceptance criterion, with the specific test that checks it (`file:line` and test name) and a command that re-runs only that test. Criteria without a test point you to the diff lines to read instead.

The workflow never commits. Review `git diff <baseline>` (the baseline is in the preflight output) and commit yourself. Run `/clear` before starting an unrelated ticket.

The orchestrator runs on **your session model** (Opus by default on Pro, Max, Team and Enterprise). Its own work is mostly reading summaries and making judgment calls. Exploration, implementation and verification run in subagents on the routed models. To reduce usage further, run the session on Sonnet (`/model sonnet`); Haiku is not recommended for the orchestrator.

## How models are selected

`route.sh` turns evidence into a decision:

- **Complexity** points come from files changed (0-2 / 3-6 / 7+), modules touched, technical uncertainty, a missing precedent pattern, and external-integration, concurrency or migration work. 0-1 points is LOW, 2-3 is MEDIUM, 4 or more is HIGH.
- **Risk** is rated separately. Any of `auth security secrets migration data-loss payments irreversible infra` makes it HIGH. `public-api external-integration concurrency pii performance`, or untested behavior-bearing code, makes it MEDIUM.
- **Route:**
  - `complex` if complexity or risk is HIGH;
  - `light` only for LOW/LOW changes with no uncertainty, no open decisions, an existing pattern, and at most 2 files;
  - `standard` otherwise.
- **Keyword flags** from the ticket text (`risk-keywords.txt`) must be confirmed or dismissed *with a reason*. Unaddressed flags count as confirmed, so a risky ticket can't be downgraded by omission.
- **Escalation:**
  - The implementer gets at most two fix attempts per failing check, and there are at most two verifier fix rounds.
  - A failure, an architecture conflict, or newly found data, security or compatibility risk causes a re-assessment and at most one automatic step up (light → standard → complex), announced in the report.
  - The workflow never steps down to save usage.

Full rules: [references/routing-policy.md](.claude/skills/ticket-dev/references/routing-policy.md).

### Overriding and updating models

| You want to... | Do this |
|---|---|
| Force a model for one ticket | `/ticket-dev --model opus <ticket>` |
| Change routing for one project | `.claude/ticket-dev/routing.conf` in that project, with only the keys to change (template in [examples/project-config/routing.conf](examples/project-config/routing.conf)) |
| Change routing everywhere | Edit `routing.conf` in this repo and re-run the installer (or edit the installed copy) |
| Adopt a new model family | Set its alias, e.g. `MODEL_COMPLEX=fable`. Unknown aliases are accepted with a warning. No agent or skill file changes are needed. |
| Pin exact versions | Keep aliases in `routing.conf` and set `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` in your environment or settings |

`routing.conf` keys are `MODEL_LIGHT`, `MODEL_STANDARD`, `MODEL_COMPLEX`, `MODEL_EXPLORER`, `MODEL_VERIFIER`, `LIGHT_MAX_FILES` and `REVIEW_ROUTES` (which routes get the independent `/code-review` pass: default `complex`, or e.g. `standard,complex`, or `none`). The agent files' own `model:` lines are fallbacks used only outside the workflow; a test keeps them equal to the defaults.

Before changing defaults, measure: [docs/benchmarking.md](docs/benchmarking.md). Organization `availableModels` restrictions and `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` take precedence over this routing.

## Project-specific conventions

**Recommended: put area-specific conventions in `.claude/rules/`.** Rules are a native Claude Code feature. A rule with a `paths:` header loads automatically whenever Claude reads or edits a matching file, in subagents too. So the implementer gets your API rules when it touches `src/api/`, without anyone copying them. Preflight lists your rules and their scopes. Example: [examples/project-config/rules/api.md](examples/project-config/rules/api.md).

```markdown
---
paths:
  - "src/api/**/*.ts"
---
- Paginate list endpoints with src/lib/pagination.ts (page/pageSize, max 100).
```

Optional workflow files in `<repo>/.claude/ticket-dev/`. Templates are in [examples/project-config/](examples/project-config/).

| File | Purpose |
|---|---|
| `conventions.md` | Rules about the ticket workflow itself (for example "anything under `src/billing/` needs approval"). Code conventions are better in `.claude/rules/`. Preflight shows the first 80 lines to `/ticket-dev` runs only, so it costs nothing in other sessions. |
| `checks.txt` | Verification commands (`name: command`, `targeted-name: template`). When present, it replaces auto-detection. Useful for monorepos. |
| `routing.conf` | Model routing overrides for this repo. |

**Existing project skills are used too.** Preflight lists the project's other skills in `.claude/skills/` (name and description). For each ticket, the orchestrator reads the relevant ones, such as an API or testing conventions skill, and copies the applicable rules into the contract, citing the skill. This matters because subagents don't see your skills on their own. Skills that perform actions (deploy, release, migrate) are never invoked by the workflow.

General project rules (build commands, code style) still belong in `CLAUDE.md`, which every session and subagent loads. Keep `CLAUDE.md` short, and put workflow-only detail in `conventions.md`.

## Optional GPT review

GPT is **never** part of the mandatory path, and Version 1 needs no OpenAI API key. A ChatGPT subscription does not include API access, so the review is manual copy and paste.

- **When it is offered:** only when an independent opinion could change what gets built. That means real uncertainty on a non-trivial ticket, or an open decision on a HIGH ticket. A HIGH label alone never triggers it.
- **How to request it anyway:** pass `--gpt`, or say "prepare a GPT review" at a gate.
- **What you get:** a review package saved outside the repository, under `$TMPDIR/ticket-dev/`. It has:
  1. objective
  2. repository findings
  3. confirmed requirements
  4. constraints
  5. unresolved decisions
  6. options
  7. specific questions

  It contains signatures and summaries rather than source files, and no secrets, customer data, hostnames or IPs. `scan-secrets.sh` must report `CLEAN` before you are given the path.
- **How to use it:**
  1. Paste the package into ChatGPT (GPT-6 High, or stronger only if the questions warrant it).
  2. Paste the reply back into the same Claude Code session, starting with `GPT feedback:`.
  3. Each recommendation is checked against the repository and marked VERIFIED, CONFLICTS, UNVERIFIABLE or OUT OF SCOPE. Only verified advice is adopted, and the gates still apply.

A possible future OpenAI API adapter is sketched in [docs/design-notes.md](docs/design-notes.md#future-openai-api-adapter-not-implemented). It is not implemented.

## Safety

Never automatic: pushing, committing, merging, deploying, publishing, applying migrations, database access, destructive data operations, installing dependencies, touching credential files, or deleting unrelated files.

- **Pre-existing work is preserved.**
  - Preflight lists uncommitted changes and takes a baseline snapshot with `git stash create`, which writes a dangling commit object and does not touch your working tree, index or stash list.
  - `git diff <baseline>` shows only what the ticket changed.
  - The verifier flags any pre-existing file the ticket touched.
- **Guard hooks** (`guard.sh`) run before every Bash, Read and Edit call in the subagents:
  - explorer: read-only allowlist (grep, find, sed -n, git log/show/diff...);
  - verifier: may run checks; blocks fixers, formatters, snapshot updates, installs, git changes and file writes;
  - implementer: may edit; blocks push/commit/stash/reset/checkout/clean, recursive or wildcard `rm`, installs, migration tools and `db:*` scripts, database clients, deploy/publish/cloud CLIs, mutating `curl`, and secret files.

  A blocked subagent reports `BLOCKED`, and the orchestrator asks you.
- **Approval gates** are enforced by the orchestrator: blocking questions, plan approval, and HIGH risk.
- **Not a git repository:** the workflow asks before editing anything.

The guard is a guardrail against mistakes, not a security sandbox: it reads command text and can be bypassed by deliberately obfuscated commands. Frontmatter hooks of *project-level* agents only run after you accept the workspace trust prompt. They do not run in `claude -p` sessions; globally installed agents' hooks always run. Your normal Claude Code permission mode still applies on top.

## Usage and cost

What the design does to save context and usage:

- The full workflow loads only when invoked.
- Mechanical work (git state, check discovery, routing) is done by scripts.
- Exploration and verification run in isolated Haiku subagents that return compact summaries.
- Trivial tickets skip exploration.
- The implementer gets the explorer's findings so it doesn't re-explore.
- Checks run targeted first, and only failing output is shown.
- Retries are capped, and nothing calls a second model to "confirm" a trivial ticket.

What it does **not** do is claim savings. Whether the light route on Haiku is cheaper overall than Sonnet for your tickets depends on retries and corrections, so measure it with [docs/benchmarking.md](docs/benchmarking.md). For reference, the live `--plan-only` smoke run on the sample app reported `total_cost_usd` 0.24 at list price (Sonnet orchestrator $0.239, Haiku explorer $0.004). That is one run on a tiny repository, not a benchmark.

**Subscription vs API:**

- On Pro, Max, Team and Enterprise plans, usage counts against rolling plan limits (5-hour and weekly windows, shared with Claude chat). Dollar figures in `/usage` or `--output-format json` are list-price estimates, not bills. `/usage` also attributes recent usage to skills and subagents.
- On an API key or cloud provider, usage is billed per token. The Console or your cloud billing is authoritative.
- A ChatGPT subscription is separate from both, and does not include OpenAI API usage.

## Testing

```bash
bash tests/run.sh                    # offline: ~460 assertions, temp dirs and a temp HOME only
TICKET_DEV_LIVE=1 bash tests/smoke.sh   # also runs real /ticket-dev sessions (uses Claude usage)
```

| Test file | Covers |
|---|---|
| `test_structure.sh` | Skill discoverable (frontmatter, `$ARGUMENTS`, references exist, preflight pre-approved), agents well-formed, read-only tools, model defaults equal `routing.conf`, no pinned model IDs, bash 3.2/BSD portability |
| `test_route.sh` | LOW→light with minimal process; MEDIUM→standard; HIGH→complex with approval; risk floors; unaddressed flags; GPT optional; overrides; alias changes via config only |
| `test_checks.sh` | Check detection per ecosystem, project overrides; `run-check.sh` PASS / FAIL / SKIP / TIMEOUT |
| `test_guard.sh` | ~100 allow/deny cases per mode, hook JSON with and without `jq`, the agents' real hook commands, fail-closed when the guard is missing |
| `test_preflight.sh` | Baseline isolates new changes, nothing in the repo is modified, non-git and empty repos, project config; secret scanning |
| `test_install.sh` | Dry run, foreign files untouched, conflicts, `--force` backups, upgrades, uninstall of modified files, project install, precedence warning |
| `smoke.sh` | Temporary sample app with uncommitted work: install, preflight, routing, honest verification, preservation, uninstall. With `TICKET_DEV_LIVE=1`: real plan-only, HIGH approval-gate and LOW implementation runs |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `/ticket-dev` not in the `/` menu | Run `/reload-skills`, or restart (needed if `~/.claude/skills` or the project's `.claude/skills` did not exist at startup). Check `ls ~/.claude/skills/ticket-dev/SKILL.md`. |
| "Shell command permission check failed" on start | A deny or ask rule in your settings matches `bash …/scripts/preflight.sh`. Allow `Bash(bash ~/.claude/skills/ticket-dev/scripts/*)`, or let the skill fall back to running preflight itself. |
| Subagents not found | Restart Claude Code after the first install that created an `agents/` directory. Run `/agents` to list them. |
| Wrong version runs | You have both a global and a project install. Remove one. |
| A subagent reports `BLOCKED` by the guard | Intended for pushes, installs, migrations and similar. Run the command yourself, or approve it to the orchestrator in the main session. If a harmless command was blocked, open an issue with the command; the rules are in `guard.sh`. |
| "ticket-dev guard not found" | The agent cannot find `scripts/guard.sh`. Reinstall. For project installs, start Claude Code inside the repository. |
| Guard never blocks anything | Project-level agent hooks need workspace trust, and do not run under `claude -p`. Accept the trust prompt, or install globally. |
| Checks are wrong or missing (monorepo) | Add `.claude/ticket-dev/checks.txt`. |
| Model not what you expected | Check the `routing:` lines in preflight output, `.claude/ticket-dev/routing.conf`, `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`, and your organization's `availableModels`. |
| A tool or permission prompt appears after you reply at a gate | The skill's `allowed-tools` pre-approval lasts only for the invoking turn. Approve the prompt, or allow `Bash(bash <skill dir>/scripts/*)` in your settings. |

## Limitations

- **Instruction-level steps:**
  - The orchestrator's gates, retry limits and model choice are instructions to Claude, not code, so the model can still deviate.
  - Deterministic parts (routing, checks, guard) narrow that gap, and the live smoke tests check the main paths.
  - `--plan-only` is enforced by instructions. The smoke test verifies that it leaves the repository unchanged.
- **Guard:**
  - Pattern-based; see [Safety](#safety).
  - It needs workspace trust for project installs.
  - It does not cover the main session; there, your permission mode applies.
- **Inherited orchestrator model:** the orchestrator uses whatever model your session runs on. Skill-level model pinning was deliberately not used (see design notes).
- **Per-invocation model choice** relies on Claude Code's documented `model` parameter of the Agent tool. If your organization restricts models, subagents fall back as Claude Code decides.
- **Check detection** covers common ecosystems only; use `checks.txt` for anything else.
- **Platforms:** Linux and macOS only. Windows (outside WSL) is not supported.
- **GPT review** is manual in Version 1.

## Repository layout

```
ticket-dev-workflow/
├── README.md                       this file
├── CLAUDE.md                       rules for working on this repository
├── .claude/
│   ├── skills/ticket-dev/
│   │   ├── SKILL.md                orchestrator
│   │   ├── routing.conf            models per route (single source of truth)
│   │   ├── risk-keywords.txt       triage keyword flags
│   │   ├── references/             routing-policy, implementation-contract, gpt-review
│   │   └── scripts/                preflight, route, detect-checks, run-check, guard, scan-secrets
│   └── agents/                     ticket-dev-explorer, -implementer, -verifier
├── scripts/                        install.sh, uninstall.sh
├── tests/                          offline suite + smoke test
├── examples/                       tickets.md, project-config/, sample-app/ (smoke-test fixture)
└── docs/                           design-notes.md, benchmarking.md
```
