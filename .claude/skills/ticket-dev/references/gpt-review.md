# Optional GPT review (manual, no API)

The developer may want an independent second opinion from ChatGPT (for example GPT-6 High) on a hard decision. This is copy-and-paste only: nothing here calls OpenAI, and the workflow never depends on it.

## When to offer it

Offer it only if an independent opinion could change what gets built:
- two or more viable architectures with real trade-offs,
- an ambiguous specification where domain reasoning would settle it,
- a high-risk integration whose external behavior could not be verified from the repository,
- debugging that is stuck after an escalation.

Do not offer it because a ticket is HIGH, large, or unfamiliar, or for anything the repository itself can answer.

## Build the package

Write it to `${TMPDIR:-/tmp}/ticket-dev/<repo-name>-<short-ticket-slug>-gpt-review.md` (outside the repository) with this structure, at most about 150 lines:

```
# Review request: <ticket title>
Suggested model: GPT-6 High. Use a stronger model only if the questions need it.

## 1. Objective
## 2. Repository context
Stack, architecture of the relevant part, and the interfaces involved as signatures or types.
## 3. Confirmed requirements
## 4. Constraints that must hold
## 5. Unresolved decisions
## 6. Options considered
Option A / B (/ C): how it works, pros, cons, risks, and our current lean with the reason.
## 7. Questions
1. Specific and answerable, e.g. "Given X and Y, is A or B safer for Z, and why?"

## How to answer
For each question: recommendation, reasoning, risks, and what fact about the codebase would change the answer. Under 600 words. No full implementations.
```

## Keep it small and safe

- Summaries, signatures and types instead of source files. Include a code excerpt only when the question depends on it, at most 15 lines each.
- Never include secrets, keys, tokens, connection strings, `.env` values, internal hostnames or IPs, customer or production data, or personal data. Replace real identifiers with placeholders if the developer asks for it.
- Do not repeat context: state each fact once and refer to it.
- Run `bash <scan-secrets> <package-file>` (path in preflight). If it reports anything, redact those lines and run it again until it prints `CLEAN`.

Then tell the developer: the file path, the questions in one short list, and "Paste ChatGPT's reply here (start with `GPT feedback:`), or say `skip`". Stop and wait.

## Using the feedback

1. Treat the reply as advice, not as facts about this repository.
2. For each recommendation, check it against the code and label it: `VERIFIED` (consistent, cite path:line), `CONFLICTS` (the code says otherwise, cite it), `UNVERIFIABLE` (needs information you do not have) or `OUT OF SCOPE`.
3. Adopt only VERIFIED recommendations. Update the contract, re-run route.sh if the risk picture changed, and go through the gates again.
4. Safety rules and approval gates still apply to anything GPT suggests.

If the developer comes back in a new session, they can resume the old session (`claude --continue` or the VS Code session list) and paste the reply, or re-run `/ticket-dev` with the same ticket and paste the reply at the gate (this repeats exploration).
