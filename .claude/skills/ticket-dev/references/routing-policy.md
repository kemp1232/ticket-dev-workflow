# Routing policy

`scripts/route.sh` applies this policy. Your job is to give it accurate, evidence-based inputs; its job is to turn them into the same decision every time. Models are configured in `routing.conf`, never here.

## Inputs

| Input | Meaning | How to decide |
|---|---|---|
| `--files N` | Files expected to change, including tests | Count from the explorer's findings and the contract. Round up when unsure. |
| `--modules N` | Distinct modules touched | A module is a package, service, app, or a top-level directory with its own responsibility (e.g. `api/`, `billing/`, `web/`). Layers inside one feature folder count once. |
| `--uncertainty` | Technical uncertainty | `none`: an existing pattern covers it and the approach is obvious. `low`: minor unknowns you can resolve while coding. `high`: no precedent, unclear approach, or behavior of an external system you could not verify. |
| `--tests` | Coverage of the code being changed | `good`/`partial`: existing tests exercise it. `none`: behavior-bearing code without tests. `na`: copy, docs, comments, styling. |
| `--signals` | Confirmed risk signals | See the list below. Only signals backed by evidence in the code or the ticket. |
| `--dismiss "flag:reason"` | A triage flag that does not apply | The reason must be evidence, e.g. `"payments:label text only, no payment code touched"`. |
| `--decisions N` | Unresolved decisions that would change behavior | Count only questions you would have to ask (see rule 4 in SKILL.md). Decisions you can settle with a reversible default are assumptions, not decisions. |
| `--new-pattern` | No existing pattern to follow | Set when the change introduces a mechanism the repository has never used. |
| `--model X` | Developer override | Only from the developer's `--model` flag. |

## Signals

HIGH risk (any one makes risk HIGH):
- `auth`: authentication, authorization, sessions, permissions, tokens.
- `security`: input handling with security impact, crypto, CORS/CSP, injection surfaces.
- `secrets`: reading, storing or rotating credentials or keys.
- `migration`: schema or data migrations, backfills, index changes on large tables.
- `data-loss`: deletes, purges, destructive updates, cascade changes.
- `payments`: charging, refunds, invoices, subscriptions, pricing.
- `irreversible`: anything that cannot be rolled back by reverting code.
- `infra`: deployment, CI/CD, infrastructure, cron or production configuration.

MEDIUM risk:
- `public-api`: changes to a contract other code or clients rely on (response shape, routes, events, exported functions).
- `external-integration`: calls to third-party services, webhooks, queues.
- `concurrency`: locking, transactions, retries, idempotency, parallel workers.
- `pii`: personal data, audit trails, compliance-relevant logging.
- `performance`: latency-, memory- or query-sensitive paths.

`--tests none` also sets a MEDIUM risk floor.

## Rules (what route.sh computes)

Complexity points: files 0-2 = 0, 3-6 = 1, 7+ = 2; modules 0-1 = 0, 2-3 = 1, 4+ = 2; uncertainty none/low/high = 0/1/2; `--new-pattern` +1; each of `external-integration`, `concurrency`, `migration` +1.
LOW is 0-1 points, MEDIUM is 2-3, HIGH is 4 or more.

| Route | When | Model key (default) | Gates and verification |
|---|---|---|---|
| light | LOW complexity, LOW risk, uncertainty none, no decisions, no new pattern, files <= `LIGHT_MAX_FILES` | `MODEL_LIGHT` (haiku) | No approval; targeted checks |
| standard | Everything between light and complex | `MODEL_STANDARD` (sonnet) | No approval unless questions; standard checks |
| complex | HIGH complexity or HIGH risk | `MODEL_COMPLEX` (opus) | PLAN phase first; approval `required` (HIGH risk) or `plan` (HIGH complexity); broad checks |

Independent review: `independent_review=yes` for the routes in `REVIEW_ROUTES` (default `complex`). Those tickets get a fresh-context `/code-review` after the verifier passes; findings outside the ticket's own changes are ignored.

GPT review: `offer` when complexity is not LOW and uncertainty is high, or when there are blocking decisions on a HIGH ticket; `requested` when the developer passed `--gpt`; otherwise `skip`. A HIGH label alone never triggers it.

Keyword flags from triage that you neither confirm nor dismiss are counted as confirmed, so a risky ticket cannot be downgraded by omission.

## Escalation and retries

- The implementer fixes a failing check at most twice, then returns `ESCALATE`.
- Two verifier FAIL rounds, an `ESCALATE`, an architecture conflict, or newly found risk (data integrity, security, backward compatibility) all mean: re-run route.sh with the new evidence.
- Move up one route at most once automatically, and say why. A new HIGH risk goes through the approval gate first.
- After the escalated attempt fails, stop and report the diagnosis. Do not keep retrying.
- Never move down a route to save usage. Only the developer's `--model` override can run below the computed route; route.sh then emits a warning that must appear in the report.

## Changing models

- Edit `MODEL_*` in `routing.conf` (installed copy) or add `.claude/ticket-dev/routing.conf` in a project with only the keys to change.
- Pin exact versions with `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL` and `ANTHROPIC_DEFAULT_OPUS_MODEL`; keep aliases in routing.conf.
- Do not claim a cheaper route saves usage unless it was measured (see docs/benchmarking.md in the ticket-dev-workflow repository).
