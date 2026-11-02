---
name: ticket-dev
description: Take a development ticket from description to a verified change in the current repository. Explores the code, rates complexity and risk, routes implementation to a haiku, sonnet or opus subagent, runs the repository's own checks and reports with evidence. Usage /ticket-dev <ticket> [@path ...] [--plan-only] [--model <alias>] [--gpt]
argument-hint: "<ticket> [@path ...] [--plan-only] [--model haiku|sonnet|opus] [--gpt]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*)
  - Bash(git status *)
  - Bash(git diff *)
  - Bash(git log *)
  - Bash(git show *)
---

# /ticket-dev

**Input:** $ARGUMENTS

## Preflight (deterministic, already run)

!`bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh`

If the preflight above is empty, failed, or says shell execution is disabled, run `bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh` yourself before anything else. Below, `<route>` means `bash ${CLAUDE_SKILL_DIR}/scripts/route.sh`. `scan-secrets.sh` is only for a GPT review package, never for code or diffs.

## Rules that always apply

1. **No irreversible or shared-state actions.** Never push, commit, merge, deploy, publish, apply migrations, run destructive data operations, read or change credentials/secret files, or delete files outside the ticket's scope. If the ticket needs one, stop at a gate and let the developer do it or approve it.
2. **Preserve pre-existing changes** listed in preflight: never revert, stash, reset, stage or reformat them. If the ticket needs a file that is already modified, say so in the contract and change only the lines the ticket needs.
3. **No invented facts.** Every path, symbol, API, schema, dependency and convention you state comes from a file you or a subagent read (cite `path:line`) or is labeled ASSUMPTION.
4. **Ask only when it matters.** Ask only when an open decision would change correctness, security, data integrity or user-visible behavior. Otherwise choose the most reversible reasonable option and list it under Assumptions.
5. **Status needs evidence.** A check passed only if `run-check.sh` printed `[PASS]` for it in this run. Everything else is FAIL, SKIP, TIMEOUT or NOT RUN, and the report says which.
6. **Minimal diff.** Reuse existing utilities and patterns. No unrelated refactors or formatting. No new dependency without a stated reason and developer approval.
7. **Subagents.** Run them in the foreground (`run_in_background: false`) and wait for the result. One implementer at a time. Always pass the model named by route.sh through the Agent tool's `model` parameter.

## Workflow

### 1. Parse the input
- `--plan-only`: stop after step 5 and edit nothing.
- `--model <alias>`: developer override for the implementation model; pass it to route.sh.
- `--gpt`: the developer wants a GPT review package; pass `--gpt` to route.sh.
- `@path` tokens are starting hints, not the full scope. The remaining text is the ticket.
- No ticket text: ask for it and stop. Not a git repository: say so and get confirmation before step 6.

### 2. Triage (no subagent)
Run `<route> --triage --ticket-stdin <<'TICKET'` with the ticket text, closed by `TICKET`.
Take the **fast path** only if `fast_path_allowed=yes` and the ticket is one localized change you can locate with at most three searches (or the @paths point straight at it): read just the relevant lines yourself and skip step 3.

### 3. Explore (unless on the fast path)
Do not search or read application code yourself here, however small the repository looks: delegate to the `ticket-dev-explorer` subagent with `model` = `explorer_model`. Give it the ticket, the @hints, the preflight `stack:` line, the triage flags to confirm or rule out, and three to six concrete questions (where the change lives, which pattern to copy, which tests cover it). Do not re-read what it summarized; read a specific range only to close a gap it reported.

### 4. Assess and route
Read [references/routing-policy.md](references/routing-policy.md) for the input definitions unless this is a trivial fast-path change. Then run:

```
<route> --files N --modules N --uncertainty none|low|high --tests good|partial|none|na \
  [--signals a,b] [--dismiss "flag:reason"]... [--decisions N] [--new-pattern] [--model X] [--gpt] \
  --ticket-stdin <<'TICKET'
<ticket text>
TICKET
```

Confirm (`--signals`) or dismiss with an evidence-based reason (`--dismiss`) every triage flag. Use the result as-is. You may escalate (more signals, higher uncertainty) when evidence supports it; never shade inputs to get a cheaper route.

### 5. Contract and gates
**Project skills.** If preflight lists project skills that bear on this ticket (coding, API, testing or naming conventions for the touched area), read each relevant `SKILL.md` once, plus a file it links only when needed. Copy the rules that apply into the contract's Constraints, citing the skill path: subagents never see these skills themselves. Do not invoke skills that act (deploy, release, migrate, publish) as part of the workflow. Files listed under `project rules` load by themselves, in subagents too: follow them, but do not copy them.

Write the contract per [references/implementation-contract.md](references/implementation-contract.md): compact form for `route=light`, standard form otherwise. Then apply, in order:
1. `blocking_questions` > 0: ask them (AskUserQuestion if available) and stop until answered.
2. `route=complex`: run step 6 with `PHASE: PLAN` now and show its plan with the contract.
3. `approval=required` or `approval=plan`: show contract and plan and wait for explicit approval. On the complex route only approval given *after the developer has seen the plan* counts: answering questions or approving the contract alone does not. If the plan has not been shown yet, run PLAN, show it, and stop again.
4. `gpt_review=offer`: add one line offering an optional GPT review and what it would settle. If accepted, or `gpt_review=requested`, follow [references/gpt-review.md](references/gpt-review.md) and stop until the developer returns with feedback or declines.
5. `--plan-only`: show contract, routing and any plan, then stop. Tell the developer they can reply `proceed` to implement this contract in the same session (no re-exploration).

If no gate applies, continue without waiting. When the developer approves or says `proceed` after a stop, continue from where you stopped, without exploring again and without skipping a gate you have not shown yet.

### 6. Implement
Delegate to the `ticket-dev-implementer` subagent with `model` = route.sh `model`. Its prompt contains: `PHASE: PLAN` or `PHASE: IMPLEMENT`, the route, the contract, the relevant explorer findings (paths, ranges, symbols, pattern), the pre-existing changes, the targeted check commands and the run-check path.
After a PLAN is approved, resume the same implementer (SendMessage to its agent ID) with `PHASE: IMPLEMENT` and any changes from the approval; if resuming is unavailable, start a new one with the approved plan. A resumed subagent may run in the background: wait for its completion notification and do nothing else meanwhile (no `sleep`, no polling `git status`).

Act on its STATUS:
- `DONE`: go to step 7.
- `BLOCKED`: it needs something only the developer may do or decide. Present it and stop.
- `ESCALATE`: re-run route.sh with the new evidence and announce the change. Move up at most one route automatically (light, standard, complex); a new HIGH risk goes through the approval gate. If the escalated attempt also fails, stop and report.

### 7. Verify
Delegate to the `ticket-dev-verifier` subagent with `model` = `verifier_model`. Give it: the baseline, the pre-existing changes, the acceptance criteria, the expected affected paths, the run-check path, and concrete commands for the `verification` level (fill the preflight templates with real paths):
- `targeted`: tests for the touched code, plus typecheck if it is fast.
- `standard`: targeted, typecheck and lint.
- `broad`: standard, the full test suite and the build (plus race tests for Go concurrency).

On `VERDICT: FAIL`, send the failure details to the implementer (resume it, or start a new one with the contract and current diff). At most two fix rounds per ticket; then escalate per step 6 or stop and report.

### 8. Review the diff yourself
Run `git diff --stat <baseline>` and compare `git status --short` with the preflight list. Read only hunks the verifier flagged, hunks behind an UNVERIFIED criterion, and risky code. Confirm each acceptance criterion, nothing out of scope changed, pre-existing changes are intact, and no debug leftovers remain.

If `independent_review=yes` and the verifier passed, invoke the `code-review` skill with the argument `high` for a fresh-context review (never `--fix`, `--comment` or `ultra`). It reviews the whole working-tree diff, so discard findings outside the ticket's changes (`git diff <baseline>`). Send real correctness or requirement gaps to the implementer as a fix round (it counts toward the limit of two) and verify again; put the rest under Risks. If the skill is unavailable, say so in the report.

### 9. Report
A developer reviews every change after you. The review checklist must let them double-check each acceptance criterion quickly: name the specific test that checks it (`file:line` and the test's exact name, from the verifier and implementer reports) and a command that re-runs only that test. If no test covers a criterion, say so and point to the diff lines to read.

```
## /ticket-dev: DONE | PARTIAL | BLOCKED | PLAN ONLY
Routing: complexity C, risk R -> route (model): reason. Escalations: none | ...
Changes: file - what changed (from git diff --stat <baseline>)
Checks: verbatim [PASS]/[FAIL]/[SKIP]/[TIMEOUT] lines; not run: name - why
Independent review: not required | N findings, M fixed, rest under Risks | unavailable
Review checklist:
| AC | Status | Checked by | Re-run only this |
|----|--------|------------|------------------|
| AC1 <criterion> | MET | test/x.test.js:17 "exact test name" | <single-test command> |
| AC2 <criterion> | MET, no test | diff src/y.js:9-12 | read the diff |
Not covered by automated tests (check by hand): ... | none
Assumptions: ...
Risks and follow-ups: ...
Next: review `git diff <baseline>` and commit when satisfied; /clear before an unrelated ticket.
```
