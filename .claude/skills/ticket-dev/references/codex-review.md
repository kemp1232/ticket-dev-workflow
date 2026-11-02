# Cross-model review with Codex CLI (optional)

An independent review of the ticket's changes by OpenAI's Codex CLI, using the developer's own `codex login`. A ChatGPT sign-in is enough, and no API key is read or needed. It sends the reviewed code to OpenAI, so it runs only when `codex_review=requested` (the developer passed `--codex-review`) or `configured` (this project opted in with `CODEX_REVIEW_ROUTES` in its own `.claude/ticket-dev/routing.conf`). Never run it otherwise, and never let a subagent run it.

## Run it once

After the code verifier (and browser stage, if any) passes:

```
bash <codex-review> --consent <requested|configured, as codex_review says> --baseline <baseline> --untracked-at-baseline <record from preflight> --title "<short ticket title>"
```

Pass `unknown` as the record when preflight printed `not recorded`. Run it in the foreground with a Bash timeout of 600000 ms. It is itself bounded by `TICKET_DEV_CODEX_TIMEOUT` (default 540 s). The script reviews only the ticket's changes: it builds a synthetic baseline-to-ticket commit in a temporary index and runs `codex exec review --commit` with a read-only sandbox. It never touches the developer's index, files or refs, and it checks that the repository is unchanged afterwards.

Run Codex at most once per ticket. After fixes, do not run it again unless the developer asks.

## Statuses

| Status | Meaning | What you do |
|---|---|---|
| PASS | Ran on the exact scope, no findings | Report it |
| FINDINGS | Codex reported findings | Validate them (below) |
| INCOMPLETE | Timeout, error, failed auth, repository changed, unparseable output, or scope gaps with no findings | Report the reason. If the repository changed, stop and tell the developer |
| SKIP | Nothing was sent: Codex not installed, logged out, or no changes | Report the reason and the setup step |

On SKIP or INCOMPLETE caused by Codex being unavailable, run the Claude `/code-review` instead only if `review_fallback=claude`. Label it as the Claude review. Never present it as a Codex result.

## Validate every finding

Codex output is advice, not fact. For each finding, read the cited lines yourself and label it:

- `VERIFIED`: the defect is real in the ticket's own changes (cite `path:line`).
- `CONFLICTS`: the code shows otherwise (cite it).
- `UNVERIFIABLE`: depends on behavior you cannot check here.
- `OUT OF SCOPE`: pre-existing code, unrelated files, or style-only.

Only VERIFIED findings about correctness, regressions, security, data integrity, edge cases, concurrency, broken contracts or missing tests for consequential behavior count. Then:

- VERIFIED and safe to fix within the contract: send it to the implementer as a fix round. It shares the ticket's limit of two fix rounds. Then re-run the code verifier, plus the browser stage if it ran.
- VERIFIED security, data-integrity or architectural issues: do not auto-fix. Stop and present them to the developer with the evidence.
- Everything else goes under Risks or is dropped, with its label.

## Report block

```
Cross-model review: Codex PASS | FINDINGS | INCOMPLETE | SKIP - reason
Reviewer: Codex CLI <version>, auth <ChatGPT sign-in | API key>; Scope: ticket changes only (<n> files)
Findings: F1 P1 src/a.js:12 <title> - VERIFIED, fixed in round 1 | CONFLICTS (src/a.js:9 already guards it) | ...
Fixes applied: ... | none. Remaining risks: ...
```
