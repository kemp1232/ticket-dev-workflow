# Benchmarking routing choices

Use this before changing `routing.conf` defaults or adopting a new model, so the decision rests on measurements from your own tickets rather than on assumptions. It is optional and manual.

## What to measure

| Metric | How to get it |
|---|---|
| First-pass success | Verifier `VERDICT: PASS` and all acceptance criteria met without a human correction |
| Time to completion | `duration_ms` from `--output-format json`, or wall-clock for interactive runs |
| Usage | API key or cloud provider: `total_cost_usd` and per-model `modelUsage[*].costUSD` from `--output-format json` (a list-price estimate; the Console or cloud bill is authoritative). Subscription: the same JSON fields are list-price estimates, not billed amounts; `/usage` shows plan bars and the share attributed to skills and subagents. Record what you measured and label it. |
| Retries | Implementer invocations minus one, plus verifier fix rounds (count `ticket-dev-implementer` Agent calls in the transcript) |
| Human corrections | Follow-up prompts or manual edits needed before the change was acceptable |
| Test outcomes | The verbatim `[PASS]`/`[FAIL]`/`[SKIP]` lines in the report, plus the full suite run afterwards |
| Regression risk | Reviewer's judgment (0 none, 1 minor, 2 significant), and whether the broad suite passed |

Never fill in a number you did not measure. If a metric is unavailable, write `n/a`.

## Procedure

1. **Pick tickets.** Choose 6 to 10 past tickets from your repository with known good outcomes: about three LOW, three MEDIUM and two to four HIGH. Note the commit each started from.
2. **Pick configurations.** For example: the default routing, everything on Sonnet (`--model sonnet`), and a candidate change (a project `routing.conf` with the new alias). Change one thing at a time.
3. **Isolate each run.** Use a fresh worktree per ticket and configuration so runs do not see each other's changes. Interactively, `ticket-worktree.sh start <ticket>-<config> --ticket "<text>"` does this, and runs started this way can execute in parallel. Each gets its own temp dir, port and logs. Headless:

   ```bash
   git worktree add ../bench-T1-default <start-commit>
   cd ../bench-T1-default
   claude -p "/ticket-dev <ticket text>" --output-format json --permission-mode acceptEdits \
     --allowedTools "Bash(bash *)" "Bash(git *)" "Bash(npm *)" > ../bench-T1-default.json
   ```

   Headless runs cannot answer approval gates. For HIGH tickets, either benchmark the `--plan-only` phase headlessly and implement interactively, or run them interactively and time them by hand. Project-level agent hooks do not run under `-p`; install globally for benchmarks if you want the guard active.
4. **Read the results.**

   ```bash
   jq '{cost: .total_cost_usd, ms: .duration_ms, turns: .num_turns, models: (.modelUsage | map_values(.costUSD))}' ../bench-T1-default.json
   ```

   These fields were present in Claude Code v2.1.301; check them in your version.
5. **Score correctness.** Review each diff against the ticket, run the full test suite, and count corrections.
6. **Repeat** each ticket-configuration pair at least twice. Model output varies, so a single run proves little.
7. **Record** results in [benchmark-results.template.csv](benchmark-results.template.csv). Compare medians per level, not totals.
8. **Decide.** Change a default only when the candidate is at least as correct (first-pass success, regressions) and measurably better on time or usage. Correctness wins ties.

## Optional stages

Measure the optional stages separately from the base workflow; they change cost and outcome on different tickets:

| Stage | Extra metric |
|---|---|
| Browser verification | Defects found that checks missed; false alarms (environment, flaky UI); added minutes; the browser verifier's `costUSD` in `modelUsage` |
| Codex review | Findings per ticket and how many were VERIFIED vs CONFLICTS; fixes that a reviewer confirmed; Codex wall time (`codex.log`); ChatGPT plan usage as Codex reports it |
| Parallel worktrees | Throughput (tickets per hour) vs single-session runs, and whether checks slowed down from sharing CPU |

Compare "Claude review only" with "Codex review" on the same complex tickets before opting a project in with `CODEX_REVIEW_ROUTES`.

## Subscription limits vs API billing

- **Claude subscription (Pro, Max, Team, Enterprise):** usage counts against rolling 5-hour and weekly limits that are shared with Claude chat. Cheaper routes stretch those limits, but no money changes hands per token, so report usage as list-price-equivalent estimates or plan percentages.
- **API key or cloud provider:** billed per token, at the provider's rates.
- **ChatGPT subscription:** separate from both. It does not include OpenAI API usage, so manual GPT reviews cost nothing extra and an API adapter would. Codex CLI reviews signed in with ChatGPT count against the plan's Codex limits; with an API-key login they are billed per token. Record which applied (the review report states it).
