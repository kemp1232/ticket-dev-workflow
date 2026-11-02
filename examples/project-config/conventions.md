# ticket-dev conventions for this repository

<!-- Copy to <repo>/.claude/ticket-dev/conventions.md. Preflight shows the first 80 lines
     to /ticket-dev runs only, so keep it short and specific to how tickets are done here.
     General project rules belong in CLAUDE.md, which every session (and subagent) loads;
     rules for specific code areas belong in .claude/rules/ (see rules/api.md). -->

- API handlers live in `src/<feature>/handler.ts`; data access only in `src/<feature>/repository.ts`.
- List endpoints paginate with `src/lib/pagination.ts` (`page`/`pageSize`, max 100). Do not add cursor pagination.
- Every behavior change needs a test next to the existing ones in `test/<feature>.test.ts`.
- Anything under `src/billing/` or `migrations/` always needs developer approval before implementation.
- Feature flags: add new flags to `config/flags.ts`; never read `process.env` directly in handlers.
