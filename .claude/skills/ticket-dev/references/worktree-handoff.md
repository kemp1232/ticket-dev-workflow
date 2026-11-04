# Moving a ticket into its own worktree

Follow this only when SKILL.md's **Checkout** rule sends you here (`--worktree`, `--base`, or the developer chose "New worktree"). Do it before triage, and before you edit anything in the current checkout. `<ticket-worktree>` and `<session>` are defined in SKILL.md.

## 1. Choose the base branch

- `--base <branch>` was given: use it and skip to step 2.
- Otherwise run `<ticket-worktree> bases`.
- If `default=` is set, use it. Say so in one line: "New worktree from `<default>` (your saved default; change it with `git config ticket-dev.worktreeBase <branch>`)".
- If there is no default, ask with AskUserQuestion, both questions in one call:
  1. "Which branch should this ticket's worktree start from?" (header `Base`). Offer up to four `candidates`, in their order. Each option's description says whether the branch comes from origin or is local only. If `main_checkout_branch` is offered, describe it as "the branch checked out in your main checkout".
  2. "Save that branch as the default base for future ticket worktrees in this repository?" (header `Default`). Options: "Yes, save as default" and "No, ask each time".

  Without AskUserQuestion, ask the same two questions in plain text and stop until the developer answers.

## 2. Create the worktree

Pick a short name from the ticket id or summary: lowercase letters, digits and dashes, at most 40 characters (for example `abc-123-products-pagination`). Then run:

```
<ticket-worktree> release --session <session>
<ticket-worktree> create <name> --base <branch> [--set-default]
```

`release` gives up this session's claim on the current checkout, if it holds one. Add `--set-default` only if the developer chose to save the branch as the default. `create` fetches `origin/<branch>`, then creates `.claude/worktrees/<name>` on a new branch `worktree-<name>` with no upstream. If the name is taken, it adds a suffix. It also copies the git-ignored files that `.worktreeinclude` lists.

If `create` fails, show its message and stop. Never fall back to working in the busy checkout.

## 3. Move this session into it

Call the `EnterWorktree` tool with `path` set to the `worktree=` value that `create` printed. If the tool is deferred, load it first. If it is unavailable or the developer declines, stop and tell the developer:
- the worktree is ready at that path;
- to continue, open a new chat in that folder and run the ticket again, or ask "enter the worktree at <path>".

## 4. Prepare and re-run preflight

- If `setup_hint` is not `none`, run that command in the worktree. It is the repository's own lockfile-based install. Each `setup_hint_dir=<dir>: <command>` line is a subdirectory with its own lockfile (for example a separate `server/`) that the root install does not cover: run that command in `<worktree>/<dir>` too. If an install fails, say so and continue; verification will report the checks that cannot run.
- Run `bash <scripts dir>/preflight.sh --session <session>`, using the `preflight:` path from the Scripts section. From now on, use its baseline, pre-existing changes, `tmp`, `port` and checks. The first preflight described the other checkout.
- If it lists `dev_server=` lines, a dev server (Expo, Metro, Vite, Next and so on) is serving the main checkout, so it will not show this ticket's change. Tell the developer now in one line, and repeat it in the report's `Dev server:` line.

Then continue with step 2 (triage) of the workflow. In the report's `Worktree:` line, give the path, the branch and the base (for example `origin/staging @ 1a2b3c4`).

## Never

- Reuse, reset, remove or clean an existing worktree.
- Create a worktree after this ticket has already edited files in the current checkout.
- Run `start`, `resume` or `clean`. Those are the developer's terminal commands.
- Push the new branch or set an upstream for it.
