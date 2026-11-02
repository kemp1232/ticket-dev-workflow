---
paths:
  - "src/api/**/*.ts"
  - "src/**/handler.ts"
---

# API rules

<!-- Copy into <repo>/.claude/rules/. Claude Code loads this file automatically, in the
     main session and in subagents, whenever a matching file is read or edited. -->

- List endpoints paginate with `src/lib/pagination.ts` (`page`/`pageSize`, default 20, max 100).
- Errors use `{ error: string }` with the matching HTTP status; never return stack traces.
- Validate query and body input at the handler boundary before calling repositories.
- Every handler change needs a test next to the existing ones in `test/<feature>.test.ts`.
