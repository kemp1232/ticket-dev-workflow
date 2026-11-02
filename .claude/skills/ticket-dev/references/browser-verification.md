# Browser verification (optional stage)

Checks observable behavior of a web UI change in a real browser. It complements the code verifier and never replaces it. `<bc>` is the `browser-check` path from preflight.

## Decide (deterministic, no model)

Run after the code verifier passes:

```
bash <bc> detect --baseline <baseline> --untracked-at-baseline <record from preflight> [--override on|off]
```

`--override on` comes from the developer's `--browser`, `off` from `--no-browser`. Use `decision` and `required` as printed:
- `decision=skip`: report `Browser verification: SKIP - <reason>`. If the reason says browser-facing files changed while disabled, add one line suggesting `--browser`.
- `decision=run`: continue below.

Never decide by reading code, and never run it for backend-only, docs-only or test-only changes unless `--browser` was given.

## Delegate

1. Run `bash <ticket-env> --fingerprint` and keep the line.
2. Delegate to `ticket-dev-browser-verifier` with `model` = `browser_verifier_model` (route.sh output). Give it the ticket summary, acceptance criteria, one to five concrete user journeys derived from them (page path, actions, expected visible result), the expected affected paths, the `detect` output, any test-account names from project config, and the `browser-check` and `run-check` paths.
3. When it returns, run `bash <ticket-env> --fingerprint` again. If it differs, the stage changed the repository: report this under Risks and treat the browser result as INCOMPLETE.
4. Re-run `bash <bc> validate-report <artifacts>/report.md [--required]` yourself and use its `effective=` status. It downgrades claims that lack evidence.

## Act on the result

- `PASS`: quote the journey lines in the report.
- `FAIL`: confirm in the report that it is behavior (not environment). Send the failing journey, expected versus observed, and its evidence paths to the implementer as a fix round. It shares the ticket's limit of two fix rounds. Then re-run the code verifier and this stage once more.
- `INCOMPLETE` or `SKIP` because tools, server or account were missing: report what is missing and the `setup` line from `env`. Do not install anything.
- With `required=yes`, any result other than PASS means the ticket cannot be reported as a clean DONE. Use PARTIAL and say why.

Keep the two kinds of evidence apart in the report. `Automated E2E` lines are an existing Playwright Test suite run through run-check. `Journeys` are exploratory checks the agent performed. Passing one never implies the other.

## Parallel worktrees

Each checkout gets its own port, temp dir and browser session (`ticket-env.sh`). `{port}` in `BROWSER_BASE_URL` and `BROWSER_DEV_COMMAND` makes parallel dev servers coexist. `server start` refuses to reuse a server this ticket did not start when a dev command is configured, so one ticket never tests another ticket's app.
