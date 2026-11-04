# ticket-dev-workflow

`/ticket-dev` is a Claude Code skill that takes a development ticket from a one-line description to a verified change in an existing repository. You describe the ticket once. The workflow then:

1. explores the relevant code,
2. rates complexity and risk from evidence,
3. writes a short implementation contract,
4. routes implementation to Haiku, Sonnet or Opus,
5. runs the repository's own checks,
6. reports what changed and what is still risky.

Three optional additions, each off unless you ask for it:

- **Parallel tickets:** each ticket runs in its own git worktree and Claude Code session. Run `/ticket-dev` in a new chat while another ticket is running, and it moves itself into a new worktree from the branch you choose. From a terminal, use `ticket-worktree.sh`, built on `claude --worktree`.
- **Browser verification:** a subagent drives your locally running web app to check UI behavior (Playwright CLI or Claude in Chrome).
- **Cross-model review:** OpenAI's Codex CLI reviews exactly the ticket's changes, read-only, using your ChatGPT sign-in.

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
- [Parallel tickets in worktrees](#parallel-tickets-in-worktrees)
- [Browser verification](#browser-verification)
- [Cross-model review with Codex CLI](#cross-model-review-with-codex-cli)
- [Safety](#safety)
- [Usage and cost](#usage-and-cost)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Repository layout](#repository-layout)

## Quick start

Requirements: Claude Code (tested with v2.1.301; the worktree flags were checked against v2.1.314), bash, git. No OpenAI key, no extra services, no `sudo`. `jq` is used when present but not required.

Optional, only for the optional features (the workflow never installs them):

| Feature | Needs |
|---|---|
| Parallel tickets | nothing extra (`claude --worktree` is built in); `tmux` only for `--tmux` |
| Browser verification | a dev server command for your app; `playwright-cli` (`npm install -g @playwright/cli@latest`, Node 18+, plus a browser: `playwright-cli install-browser chromium`; tested with 0.1.23), or Claude in Chrome (`claude --chrome`); `@playwright/test` only for existing E2E suites |
| Codex review | Codex CLI (`npm install -g @openai/codex`, tested with 0.164) and `codex login` (ChatGPT sign-in is enough) |

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
 browser-check.sh detect ─ UI files changed? (deterministic)  ── optional ──┐
        │                                                                  ▼
        │                     ticket-dev-browser-verifier (sonnet) ─ journeys in a real browser
        ▼
 one independent review: codex-review.sh (Codex CLI, opt-in) or /code-review (complex route)
        ▼
 validated findings → at most two fix rounds in total → re-verify
        ▼
 diff review by the orchestrator ─ report with verbatim check results, assumptions and risks
```

Run in parallel, each ticket gets this whole pipeline in its own worktree and session (`ticket-worktree.sh start`). Nothing is shared except the git object store.

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
| `ticket-env.sh` | `scripts/` | Per-checkout identity: private temp dir, port and log dir, so parallel worktrees never collide. Also lists the ticket's own changes against the baseline, and fingerprints the repository to prove read-only steps changed nothing. |
| `ticket-worktree.sh` | `scripts/` | Parallel tickets. For you, in a terminal: a launcher over `claude --worktree` with conflict checks, status, diff, and a cleanup that never deletes work. For the orchestrator: records which session owns a checkout, and creates a worktree from a chosen base branch. |
| `browser-check.sh` + `browser.conf` | `scripts/`, skill root | Decides from changed files whether browser verification applies, finds tools, runs the project's dev server per ticket, and rejects reports that claim more than they show. |
| `codex-review.sh` | `scripts/` | Runs `codex exec review` read-only on a synthetic commit that contains exactly the ticket's changes, and normalizes the findings. |
| `ticket-dev-browser-verifier` | `.claude/agents/` | Optional. Interacts with the running app and reports observed behavior with evidence files. Never edits; its guard allows only approved local URLs. |
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
            [--browser|--no-browser] [--codex-review|--no-codex-review]
```

| Flag | Effect |
|---|---|
| `@path` | Starting hints for exploration (files or folders). The workflow still looks beyond them. |
| `--plan-only` | Stops after the contract and routing (and the Opus plan for HIGH tickets). Edits nothing. Reply `proceed` to implement in the same session without re-exploring. |
| `--model <alias>` | Forces the implementation model. If it is below the computed route for a high-risk ticket, the report says so. |
| `--gpt` | Prepares a GPT review package even if one was not suggested. |
| `--browser` / `--no-browser` | Forces (and requires) or skips browser verification for this ticket. |
| `--codex-review` / `--no-codex-review` | Requests a Codex CLI review for this ticket, or declines the project's configured one. |

Without these flags and without project configuration, `/ticket-dev Fix a simple backend bug` runs exactly as before: no worktree, no browser and no Codex.

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

`routing.conf` keys are `MODEL_LIGHT`, `MODEL_STANDARD`, `MODEL_COMPLEX`, `MODEL_EXPLORER`, `MODEL_VERIFIER`, `MODEL_BROWSER_VERIFIER`, `LIGHT_MAX_FILES`, `REVIEW_ROUTES` (which routes get the independent `/code-review` pass: default `complex`, or e.g. `standard,complex`, or `none`) and `CODEX_REVIEW_ROUTES` (project config only; see [Codex review](#cross-model-review-with-codex-cli)). The agent files' own `model:` lines are fallbacks used only outside the workflow; a test keeps them equal to the defaults.

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
| `routing.conf` | Model routing overrides for this repo, and the Codex opt-in (`CODEX_REVIEW_ROUTES`). |
| `browser.conf` | Browser verification for this repo: mode, URL, dev command, allowed hosts, viewports, E2E command. |

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

## Parallel tickets in worktrees

Each ticket runs in its own [git worktree](https://code.claude.com/docs/en/worktrees) (its own directory and branch) with its own interactive Claude Code session and its own `/ticket-dev` run, including the approval gates and checks. Parallelism happens across tickets; each ticket still has one implementer. Start with **two tickets at a time**. Add more only if your machine (test suites, dev servers) and your review capacity keep up.

### From a chat (VS Code or terminal): automatic

1. Ticket 1 is running in chat A.
2. Open a new chat B and type `/ticket-dev <ticket 2>` as usual.
3. Preflight sees that chat A's session still owns this checkout (`checkout=busy`), so chat B asks whether to use a new worktree, take over this checkout (if chat A has finished), or cancel. With a new worktree, chat B:
   1. asks which branch the worktree should start from, offering your remote's default branch, `staging`, `develop` and so on, and whether to save it as the default. With a saved default, it doesn't ask;
   2. fetches that branch and creates `.claude/worktrees/<name>` on a new branch `worktree-<name>`, with no upstream, so a stray `git push` cannot hit `staging`;
   3. copies the git-ignored files that `.worktreeinclude` lists, such as `.env`;
   4. moves chat B into the worktree with Claude Code's `EnterWorktree` tool;
   5. runs the repository's lockfile install, such as `npm ci`, plus one per subdirectory with its own lockfile (for example `server/`);
   6. re-runs preflight there and continues with the normal workflow. If a dev server (Expo, Metro, Vite, Next...) is still running from the main checkout, chat B warns you, and the report repeats it: that server keeps showing the old code.

| Flag | Effect |
|---|---|
| `--base <branch>` | Use this base and skip the questions; implies a new worktree |
| `--worktree` | New worktree without asking, even if nobody else is running a ticket here |
| `--here` | Stay in this checkout without asking, even though it is busy; both chats then edit the same files |

- **Default base:** stored per repository in local git config, never committed. Change it with `git config ticket-dev.worktreeBase main`, or clear it with `git config --unset ticket-dev.worktreeBase`.
- **How "busy" works:** when `/ticket-dev` starts, it records its session ID and Claude Code process in the checkout's git directory (`.git/ticket-dev-session`, or the worktree's own git dir). The ticket releases it whenever it stops (report, BLOCKED, plan only, a gate that waits for you). Otherwise the record counts only while that process runs *and* the session's transcript changed in the last 30 minutes (`TICKET_DEV_CLAIM_IDLE_MINUTES`). The IDE extension keeps its process alive after a chat ends, so the process alone proves nothing. A single chat behaves exactly as before.
- **When you're done:** commit in the worktree chat, close it, then use `ticket-worktree diff|clean <name>` from a terminal. `clean` refuses while a chat still owns the worktree.

### From a terminal

The launcher is installed with the skill. Give it a short name:

```bash
alias ticket-worktree='bash ~/.claude/skills/ticket-dev/scripts/ticket-worktree.sh'   # global install
# project install: bash .claude/skills/ticket-dev/scripts/ticket-worktree.sh
echo '.claude/worktrees/' >> .git/info/exclude      # once per repository (or add to .gitignore)
```

Start two tickets, each in its own terminal:

```bash
ticket-worktree start feature-pagination --ticket "Implement frontend pagination on the products page"
ticket-worktree start backend-filtering  --ticket "Add a category filter to GET /products"
```

This runs `claude --worktree <name> --name ticket-<name> "/ticket-dev <ticket>"` from your main checkout. Claude Code creates `.claude/worktrees/<name>/` on branch `worktree-<name>`, branched from your default branch. Add `--base head` to branch from your current HEAD instead, or `--tmux` to open it in a tmux session (native `claude --tmux`). Pass arguments for `claude` after `--`.

| Task | Command |
|---|---|
| See all ticket worktrees | `ticket-worktree list` (name, branch, changed files, commits, in use) |
| Inspect one | `ticket-worktree status <name>`; `ticket-worktree diff <name>` (committed and uncommitted, plus untracked files) |
| Continue later | `ticket-worktree resume <name>` (`claude --worktree <name> --resume`) |
| Finish | review, commit on `worktree-<name>`, merge it yourself (`git merge worktree-<name>` or a PR) |
| Remove | `ticket-worktree clean <name>` (add `--delete-branch` to delete a merged branch) |

Safety rules:

- **Start** refuses invalid names, an existing worktree or `worktree-<name>` branch, a repository with no commits, a missing `claude` CLI, and a repository where the new checkout would not contain ticket-dev (install globally, or commit the project install first). It also refuses inside a Claude Code session, so an agent cannot launch sessions.
- **Clean** refuses while a session holds the worktree lock, while there are uncommitted changes or untracked files, and while git-ignored files exist unless you pass `--discard-ignored` (for `node_modules`, build output, copied `.env`). It never uses `--force`, and it deletes a branch only with `git branch -d`, which git refuses for unmerged work. When you exit a session, Claude Code also offers its own keep-or-remove prompt.
- **Nothing is merged, committed or pushed** for you.
- **Isolation:** each worktree has its own baseline, temp dir (`$TMPDIR/ticket-dev/<worktree>-<hash>/` for check logs, browser artifacts and Codex output), dev-server port (`{port}`) and browser session. Preflight shows them. Claude Code also blocks a worktree session from editing the main checkout.
- **Worktree isolation is not a security sandbox.** Sessions share your user account, the git object store, network, databases and any service your tests touch. Two tickets that run migrations against one local database can still collide.
- A worktree is a fresh checkout: install dependencies there yourself, and use [`.worktreeinclude`](https://code.claude.com/docs/en/worktrees#copy-gitignored-files-into-worktrees) to copy files such as `.env.local`.

Single-checkout use is unchanged: run `/ticket-dev` as before and preflight shows `worktree=main`.

## Browser verification

An optional stage after the code verifier passes. It checks what a user sees: clicks, forms, navigation, modals, loading and error states, console errors, and a mobile viewport. It never replaces the code checks.

**When it runs:** `browser-check.sh detect` decides deterministically from the ticket's changed files and `browser.conf`, without a model. UI files are `.tsx/.jsx/.vue/.svelte/.astro/.html/.css...`, JS or TS under `app/`, `pages/`, `components/` and similar, framework configs, `public/`, and your own `BROWSER_FRONTEND_PATHS`, in a project with a web framework or `index.html`. Tests, docs and backend files (for example Go) never trigger it.

| `BROWSER_VERIFICATION` | Behavior |
|---|---|
| `off` (default) | Never runs; the report notes it when UI files changed. |
| `auto` | Runs when UI files changed in a web project. |
| `required` | Always runs. The ticket cannot be reported as a clean DONE unless the browser result is PASS. |
| per ticket | `--browser` forces it on and makes it required for that ticket; `--no-browser` skips it. |

**Enable it for a Next.js project:** create `.claude/ticket-dev/browser.conf` (template: [examples/project-config/browser.conf](examples/project-config/browser.conf)):

```ini
BROWSER_VERIFICATION=auto
BROWSER_BASE_URL=http://127.0.0.1:{port}
BROWSER_DEV_COMMAND=npx next dev -p {port}
BROWSER_READY_TIMEOUT=90
```

`{port}` is this checkout's own port, so parallel worktrees run separate dev servers. `browser-check.sh server start` runs the command (after checking it against the guard), waits up to the timeout for the URL to answer, and keeps the log in the ticket's temp dir. `server stop` stops only a server this ticket started. With no `BROWSER_DEV_COMMAND`, it only reuses a server you started yourself at `BROWSER_BASE_URL`.

**Two kinds of evidence, never mixed:**

- **Exploratory (agent):** the `ticket-dev-browser-verifier` subagent (Sonnet, from `MODEL_BROWSER_VERIFIER`) drives `playwright-cli` (headless): `open`, `snapshot`, `click`, `fill`, `console`, `resize`, `screenshot`. It derives one to five journeys from the acceptance criteria and asserts facts from snapshots, such as text, state and URL. Artifacts go to `$TMPDIR/ticket-dev/<checkout>/browser/`, never into the repository. Claude in Chrome (`claude --chrome`) can be used instead when connected.
- **Repeatable (your suite):** if the project has `playwright.config.*` with `@playwright/test` installed, or `BROWSER_E2E_COMMAND`, it runs through `run-check.sh` as `e2e`, with output under the temp dir. A green E2E suite is reported as such and never as "exploratory checks passed".

`browser-check.sh validate-report` rejects a PASS without executed journeys, without evidence files, or with a failed journey, and flags tokens in the report. The orchestrator re-runs it and uses its `effective=` status. Sample report:

```text
BROWSER VERIFICATION: FAIL

Environment: feature-pagination, server started (http://127.0.0.1:3412)
URL: http://127.0.0.1:3412
Browser/tool: playwright-cli 0.1.x, headless chromium
Automated E2E: [PASS] e2e (exit 0, 41s) - npx playwright test --reporter=line --output /tmp/ticket-dev/feature-pagination-1234/browser/test-results

Journeys:
- Scenario: J1 go to page 2 of the product list
  Expected: list shows items 21-40 and "Page 2 of 5"
  Observed: URL changed to ?page=2 but the list still shows items 1-20
  Result: FAIL
  Evidence: /tmp/ticket-dev/feature-pagination-1234/browser/j1-after.yml, /tmp/ticket-dev/feature-pagination-1234/browser/j1-fail.png

Console/navigation errors: GET /api/products?page=2 -> 500 (J1)
Responsive checks: mobile 390x844: pager visible and tappable, j1-mobile.png
Artifacts: /tmp/ticket-dev/feature-pagination-1234/browser
Limitations: logged-out state only (no test account configured)
```

**Security:** only `localhost`, `127.0.0.1`, `::1`, `*.localhost` and hosts you add to `BROWSER_ALLOWED_HOSTS` can be opened. The guard checks every URL in commands and in Claude-in-Chrome tool calls. The agent treats page content as untrusted, uses only test accounts you name, stops at logins or CAPTCHAs it cannot pass legitimately, and never puts cookies or tokens in reports. The guard also blocks it from editing files, installing browsers, and starting servers outside `browser-check.sh`.

## Cross-model review with Codex CLI

An independent review by OpenAI's Codex CLI after the checks pass. Claude validates every finding before anything is fixed.

```bash
npm install -g @openai/codex
codex login            # choose "Sign in with ChatGPT"; no API key needed
```

```
/ticket-dev --codex-review Implement pagination on the products API
```

To opt a whole project in for some routes, set this in that project's `.claude/ticket-dev/routing.conf`:

```ini
CODEX_REVIEW_ROUTES=complex      # or standard,complex
```

Because reviewed code is sent to OpenAI, this key is honored only in a project's own config. A value in the installed or shared `routing.conf` is ignored with a warning. `codex-review.sh` itself also refuses to send anything without `--consent requested` (your `--codex-review`) or `--consent configured`, which it verifies against the project config.

**Exactly the ticket's changes:** `codex review --uncommitted` would include your pre-existing edits and untracked files, and `--base` would include the whole branch. `codex-review.sh` therefore builds a commit whose parent is the preflight baseline and whose tree is the baseline plus the ticket's changes, including new and deleted files. Untracked files that existed before preflight are left out. It builds this in a *temporary* index, so your index, files, stash and refs are untouched, and runs `codex exec review --commit <sha>` with `sandbox_mode="read-only"`, `--ephemeral` and `--ignore-user-config` (your `~/.codex/config.toml`, and with it your MCP servers, are not loaded; your login is). It fingerprints the repository before and after. A pre-existing untracked file that the ticket edited cannot be attributed, so it is reported as a scope gap and not sent.

**One reviewer, bounded:** `--codex-review` > project opt-in > the Claude `/code-review` pass (`REVIEW_ROUTES`) > none. If Codex is selected but unavailable, the Claude review runs only if `REVIEW_ROUTES` would have selected it anyway, and is labeled as Claude's review. Codex runs at most once per ticket. VERIFIED correctness findings go to the implementer within the shared two-round fix limit. VERIFIED security, data-integrity and architecture findings stop for you.

Sample output (from a live run on a test repository):

```text
CROSS-MODEL REVIEW: FINDINGS

Reviewer: Codex CLI (codex-cli 0.164.0-alpha.11.1), auth: ChatGPT sign-in (counts against your ChatGPT plan; no API key used)
Scope: ticket changes only - 2 file(s) since baseline 1cd9581, review commit fa5a3ba
  M	src/stats.js
  A	src/version.js
Excluded: pre-existing untracked files unchanged since preflight (record 0c87107...); pre-existing tracked edits are part of the baseline
Scope gaps: none
Read-only check: repository unchanged by the review (HEAD, refs, index, working tree, untracked files)

Findings: 1
- F1 Severity: P1 (high)
  File and line: src/stats.js:4-4
  Description: Stop iteration before the array length
  Evidence: `i <= xs.length` adds xs[xs.length] (undefined), so average([1, 2, 3]) returns NaN instead of 2.
  Recommended action: decide after validation (fix if VERIFIED and in scope)

Disposition: pending - validate each finding against the repository (VERIFIED, CONFLICTS, UNVERIFIABLE, OUT OF SCOPE) before acting on it.
```

Statuses: `PASS` (ran, no findings), `FINDINGS`, `INCOMPLETE` (timeout, error, failed login, repository changed, unparseable output, or scope gaps without findings), and `SKIP` (nothing sent: Codex missing or logged out, or no changes). The default timeout is 540 s (`TICKET_DEV_CODEX_TIMEOUT`).

The manual `--gpt` package and the `/code-review` skill are unchanged and independent of this.

## Safety

Never automatic: pushing, committing, merging, deploying, publishing, applying migrations, database access, destructive data operations, installing dependencies, touching credential files, or deleting unrelated files.

- **Pre-existing work is preserved.**
  - Preflight lists uncommitted changes and takes a baseline snapshot with `git stash create`, which writes a dangling commit object and does not touch your working tree, index or stash list.
  - `git diff <baseline>` shows only what the ticket changed.
  - The verifier flags any pre-existing file the ticket touched.
- **Guard hooks** (`guard.sh`) run before every Bash, Read and Edit call in the subagents:
  - explorer: read-only allowlist (grep, find, sed -n, git log/show/diff...);
  - verifier: may run checks; blocks fixers, formatters, snapshot updates, installs, git changes and file writes;
  - implementer: may edit; blocks push/commit/stash/reset/checkout/clean, recursive or wildcard `rm`, installs, migration tools and `db:*` scripts, database clients, deploy/publish/cloud CLIs, mutating `curl`, and secret files;
  - browser verifier: verifier rules, plus approved URLs only (commands and MCP browser tools), `playwright-cli` only with the ticket's config, no direct dev-server starts, no browser installs;
  - all agents: no `claude`, `codex`, `codex-review.sh` or `ticket-worktree.sh`. Sessions and cross-provider review belong to you and the orchestrator.

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
- **Codex review** with `codex login` via ChatGPT counts against your ChatGPT plan's Codex limits; nothing is billed per token. If Codex is logged in with an API key, or `OPENAI_API_KEY`/`CODEX_API_KEY` is set, the review may be billed to that API account; the report says which auth method was used.
- **Parallel tickets** multiply usage: two tickets use roughly twice the Claude usage at the same time, and count against the same 5-hour window.
- **Browser verification** adds one Sonnet subagent run per ticket where it applies (snapshots are text, and a screenshot is read only when needed).

## Testing

```bash
bash tests/run.sh                    # offline: ~950 assertions, temp dirs and a temp HOME only
TICKET_DEV_LIVE=1 bash tests/smoke.sh   # also runs real /ticket-dev sessions (uses Claude usage)
TICKET_DEV_LIVE_CODEX=1 bash tests/live.sh   # real Codex review of a synthetic repo (ChatGPT plan usage)
```

| Test file | Covers |
|---|---|
| `test_structure.sh` | Skill discoverable (frontmatter, `$ARGUMENTS`, references exist, preflight pre-approved), agents well-formed, read-only tools, model defaults equal `routing.conf`, no pinned model IDs, bash 3.2/BSD portability |
| `test_route.sh` | LOW→light with minimal process; MEDIUM→standard; HIGH→complex with approval; risk floors; unaddressed flags; GPT optional; overrides; alias changes via config only |
| `test_checks.sh` | Check detection per ecosystem, project overrides; `run-check.sh` PASS / FAIL / SKIP / TIMEOUT |
| `test_guard.sh` | ~100 allow/deny cases per mode, hook JSON with and without `jq`, the agents' real hook commands, fail-closed when the guard is missing |
| `test_preflight.sh` | Baseline isolates new changes, nothing in the repo is modified, non-git and empty repos, project config; secret scanning |
| `test_install.sh` | Dry run, foreign files untouched, conflicts, `--force` backups, upgrades, uninstall of modified files, project install, precedence warning |
| `test_worktree.sh` | Launcher with a stub `claude`: validation, name and branch conflicts, missing tools, refusal inside sessions, two concurrent workers isolated from each other and from the developer's work, per-worktree baselines, temp dirs, ports and logs, list/status/diff/resume, clean refusing dirty, untracked, ignored or locked worktrees, safe branch deletion |
| `test_browser.sh` | Detection (frontend vs backend, docs, tests; non-web projects), off/auto/required and overrides, URL policy, tool discovery without installs, dev server unavailable, refused, crashed, timed out, reused and stopped, a simulated passing and failing journey against a real local server, report validation |
| `test_codex.sh` | Stub `codex`: scope excludes pre-existing tracked, staged and untracked work and includes new and deleted ticket files; read-only flags; repository untouched; finding normalization; PASS; not installed, logged out, old version, auth and rate-limit errors, timeout, empty and unparseable output, repository modified, scope gaps, API-key billing notes, worktrees |
| `smoke.sh` | Temporary sample app with uncommitted work: install, preflight, routing, honest verification, preservation, uninstall. With `TICKET_DEV_LIVE=1`: real plan-only, HIGH approval-gate and LOW implementation runs |
| `live.sh` (not in `run.sh`) | Opt-in real integrations on synthetic repositories: `TICKET_DEV_LIVE_CODEX=1` (real Codex review), `TICKET_DEV_LIVE_BROWSER=1` (real headless browser via playwright-cli), `TICKET_DEV_LIVE_WORKTREE=1` (two concurrent `claude --worktree` sessions; Claude usage). Disabled parts print NOT RUN |

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
| `ticket-worktree start` says ticket-dev is not installed or committed | The new checkout would lack the skill and its guard. Install globally, or commit `.claude/skills/ticket-dev` and `.claude/agents/ticket-dev-*.md` |
| `--worktree` exits asking about workspace trust | Run `claude` once in the repository and accept the trust dialog |
| Main checkout shows `?? .claude/worktrees/` | `echo '.claude/worktrees/' >> .git/info/exclude` |
| `ticket-worktree clean` refuses | It lists the uncommitted, untracked or ignored files. Commit or move them, or pass `--discard-ignored` for disposable ignored files. A lock means a session is still open |
| Browser verification always SKIP | `BROWSER_VERIFICATION` is `off` by default; set `auto`, or pass `--browser` |
| `exploratory=unavailable` | Install `playwright-cli` and a browser yourself (see `setup=` in `browser-check.sh env`) |
| `server: unavailable` / `TIMEOUT` / `refused` | Set `BROWSER_DEV_COMMAND` (with `{port}`), raise `BROWSER_READY_TIMEOUT`, or stop the other process on that port (or set `TICKET_DEV_PORT`) |
| Codex review `SKIP: not installed` / `not logged in` | `npm install -g @openai/codex`, then `codex login` |
| Codex review `INCOMPLETE: timed out` | Raise `TICKET_DEV_CODEX_TIMEOUT`; for long reviews run the command in the background |
| `CODEX_REVIEW_ROUTES ... must be enabled per project` | Move the key into the project's `.claude/ticket-dev/routing.conf` |
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
- **Worktrees:** the launcher relies on Claude Code's `--worktree` behavior (location, branch name, base ref, exit prompt), which was verified against v2.1.314 and its documentation. Worktrees are not a sandbox; they share the git object store, network, databases and your account. Each worktree needs its own dependency install.
- **Browser verification:**
  - It needs a runnable local app and tools you install.
  - Detection is by file path, so a UI change hidden in a generic `src/lib/*.ts` file needs `--browser` or `BROWSER_FRONTEND_PATHS`.
  - Journeys are only as good as the acceptance criteria.
  - Authenticated flows need a test account you configure.
  - The Claude in Chrome path is untested here (no extension in the test environment).
- **Codex review:**
  - It depends on the Codex CLI's `exec review --commit` (verified with 0.164; older versions are reported as INCOMPLETE).
  - Codex reads the repository from disk, so it sees your pre-existing edits in other files as context; only the reviewed diff is restricted.
  - Codex output is advice and is validated before use.
  - Gitignored files the ticket created are not reviewed.

## Repository layout

```
ticket-dev-workflow/
├── README.md                       this file
├── CLAUDE.md                       rules for working on this repository
├── .claude/
│   ├── skills/ticket-dev/
│   │   ├── SKILL.md                orchestrator
│   │   ├── routing.conf            models per route (single source of truth)
│   │   ├── browser.conf            browser verification defaults (off)
│   │   ├── risk-keywords.txt       triage keyword flags
│   │   ├── references/             routing-policy, implementation-contract, gpt-review,
│   │   │                           browser-verification, codex-review
│   │   └── scripts/                preflight, route, detect-checks, run-check, guard, scan-secrets,
│   │                               ticket-env, ticket-worktree, browser-check, codex-review
│   └── agents/                     ticket-dev-explorer, -implementer, -verifier, -browser-verifier
├── scripts/                        install.sh, uninstall.sh
├── tests/                          offline suite + smoke test; live.sh for opt-in real integrations
├── examples/                       tickets.md, project-config/, sample-app/ (smoke-test fixture)
└── docs/                           design-notes.md, benchmarking.md
```
