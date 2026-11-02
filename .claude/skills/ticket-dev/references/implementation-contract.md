# Implementation contract

The contract is the single statement of what will be built and how it will be checked. The implementer and verifier receive it instead of the conversation, so it must stand on its own. Keep it in the conversation; do not write it to a file unless the developer asks.

## Grounding rules

- Cite `path:line` for every existing file, function, type, route, table, config key or convention you mention.
- Rules from the project's own Claude skills go into Constraints with the skill path, because the implementer and verifier cannot see those skills.
- Anything not confirmed in the code is labeled `ASSUMPTION` with the reason it could not be confirmed.
- Never invent paths, interfaces, schemas, functions, dependencies or conventions. If the explorer did not find something, it goes under Unresolved, not into the plan.
- Acceptance criteria must be checkable: by a test, a command, or a specific line in the diff.
- New files are allowed only where the repository's structure shows where they belong (cite the sibling you are following).

## Compact form (route=light)

```
Contract
- Objective: one sentence
- Change: path:line - what changes
- Acceptance: AC1 ...; AC2 ...
- Verify: exact command(s)
- Assumptions: ... | none
```

## Standard form (route=standard or complex)

```
## Contract: <short title>
Objective: what changes for whom, in one or two sentences.

Requirements (confirmed):
- R1 ... (source: ticket | path:line)

Acceptance criteria:
- AC1 ... (checked by: test file and test name | command | diff location; "no test" if none will exist)

Affected code:
- path:line-range - what changes and why (pattern to follow: path:line)
Tests to add or update:
- path - cases

Out of scope: ...
Constraints: conventions, compatibility and performance limits that apply (with evidence: path:line, or .claude/skills/<name>/SKILL.md for rules taken from a project skill)
Edge cases: ...
Risks: risk - mitigation (complex route: also rollback approach and which steps need approval)
Verification plan: targeted -> typecheck/lint -> broad, with concrete commands for the routed level
Unresolved:
- Blocking (must ask): ...
- Non-blocking (assumption taken): ...
Routing: complexity C, risk R -> route (model); reasons from route.sh; dismissed flags with reasons
```

For the complex route the implementer's PLAN output is shown together with this contract at the approval gate. Update the contract if the plan or the developer changes it.
