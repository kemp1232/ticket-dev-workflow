#!/usr/bin/env bash
# Skill and agent definitions are well-formed, discoverable and consistent.
. "$(dirname "$0")/lib.sh"

frontmatter() { awk 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { exit } f' "$1"; }
field() { frontmatter "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -n 1; }

describe "skill is discoverable"
SK="$SKILL/SKILL.md"
assert_file "$SK"
assert_eq "$(field "$SK" name)" "ticket-dev" "skill name"
assert_contains "$(field "$SK" description)" "ticket" "description"
assert_eq "$(field "$SK" disable-model-invocation)" "true" "manual invocation only (side effects)"
hint=$(field "$SK" argument-hint)
assert_contains "$hint" "--plan-only" "argument-hint"
assert_contains "$hint" "@path" "argument-hint"
assert_contains "$hint" "--model" "argument-hint"

describe "skill accepts the ticket and file references"
assert_eq "$(grep -c '\$ARGUMENTS' "$SK")" "1" "\$ARGUMENTS placeholder count"
# $0, $1 ... would be replaced by positional arguments.
assert_eq "$(grep -cE '\$[0-9]' "$SK")" "0" "no positional placeholders"
assert_contains "$(cat "$SK")" '`@path` tokens are starting hints' "file references"

describe "skill stays small and loads detail on demand"
lines=$(wc -l <"$SK" | tr -d ' ')
[ "$lines" -lt 200 ] && pass || fail "SKILL.md has $lines lines (budget 200, docs limit 500)"
for ref in $(grep -oE '\(references/[a-z-]+\.md\)' "$SK" | tr -d '()' | sort -u); do
	assert_file "$SKILL/$ref" "linked reference"
done
assert_eq "$(grep -c '^!`' "$SK")" "1" "exactly one injected command"
assert_contains "$(grep '^!`' "$SK")" 'scripts/preflight.sh' "injected command"
assert_contains "$(frontmatter "$SK")" 'Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*)' "preflight pre-approved (non-auto modes abort otherwise)"

describe "project skills reach the subagents through the contract"
assert_contains "$(cat "$SK")" "**Project skills.**" "orchestrator instruction"
assert_contains "$(cat "$SKILL/references/implementation-contract.md")" ".claude/skills/<name>/SKILL.md" "contract cites skills"

describe "report gives the human reviewer per-criterion tests"
assert_contains "$(cat "$SK")" "Review checklist:" "report template"
assert_contains "$(cat "$SK")" "Re-run only this" "report template"
assert_contains "$(cat "$AGENTS/ticket-dev-verifier.md")" "a command that runs only that test" "verifier evidence"
assert_contains "$(cat "$AGENTS/ticket-dev-implementer.md")" "acceptance criterion it covers" "implementer test mapping"

describe "agents are well-formed"
for name in ticket-dev-explorer ticket-dev-implementer ticket-dev-verifier ticket-dev-browser-verifier; do
	f="$AGENTS/$name.md"
	assert_file "$f"
	assert_eq "$(field "$f" name)" "$name" "$name name"
	[ -n "$(field "$f" description)" ] && pass || fail "$name has no description"
	model=$(field "$f" model)
	case "$model" in haiku | sonnet | opus | fable) pass ;; *) fail "$name model '$model' is not a family alias" ;; esac
	assert_contains "$(frontmatter "$f")" "guard.sh" "$name guard hook"
done
assert_not_contains "$(field "$AGENTS/ticket-dev-explorer.md" tools)" "Edit" "explorer tools"
assert_not_contains "$(field "$AGENTS/ticket-dev-explorer.md" tools)" "Write" "explorer tools"
assert_not_contains "$(field "$AGENTS/ticket-dev-verifier.md" tools)" "Edit" "verifier tools"
assert_not_contains "$(field "$AGENTS/ticket-dev-verifier.md" tools)" "Write" "verifier tools"
assert_contains "$(field "$AGENTS/ticket-dev-implementer.md" tools)" "Edit" "implementer tools"
assert_contains "$(frontmatter "$AGENTS/ticket-dev-explorer.md")" 'bash "$g" explore' "explorer guard mode"
assert_contains "$(frontmatter "$AGENTS/ticket-dev-verifier.md")" 'bash "$g" verify' "verifier guard mode"
assert_contains "$(frontmatter "$AGENTS/ticket-dev-implementer.md")" 'bash "$g" implement' "implementer guard mode"
BV="$AGENTS/ticket-dev-browser-verifier.md"
assert_not_contains "$(field "$BV" tools)" "Edit" "browser verifier tools"
assert_not_contains "$(field "$BV" tools)" "Write" "browser verifier tools"
assert_contains "$(frontmatter "$BV")" 'bash "$g" browser' "browser verifier guard mode"
assert_contains "$(frontmatter "$BV")" 'mcp__.*' "guard also sees MCP browser tools"

describe "agent default models match routing.conf (one source of truth)"
conf() { sed -n "s/^$1=//p" "$SKILL/routing.conf"; }
assert_eq "$(field "$AGENTS/ticket-dev-explorer.md" model)" "$(conf MODEL_EXPLORER)" "explorer default"
assert_eq "$(field "$AGENTS/ticket-dev-verifier.md" model)" "$(conf MODEL_VERIFIER)" "verifier default"
assert_eq "$(field "$AGENTS/ticket-dev-implementer.md" model)" "$(conf MODEL_STANDARD)" "implementer default"
assert_eq "$(field "$AGENTS/ticket-dev-browser-verifier.md" model)" "$(conf MODEL_BROWSER_VERIFIER)" "browser verifier default"
# Workflow instructions name config keys, never concrete models.
assert_eq "$(grep -cE 'model[` ]*(=|:) *`?(haiku|sonnet|opus)' "$SK")" "0" "SKILL.md hardcodes no model"
assert_eq "$(grep -rlE 'claude-(opus|sonnet|haiku)-[0-9]' "$SKILL" "$AGENTS" | wc -l | tr -d ' ')" "0" "no pinned model IDs"

describe "scripts are valid bash and stay macOS (bash 3.2 / BSD) compatible"
for s in "$SCRIPTS"/*.sh "$REPO"/scripts/*.sh "$REPO"/tests/*.sh; do
	bash -n "$s" && pass || fail "syntax error in $s"
	assert_eq "$(head -n 1 "$s")" "#!/usr/bin/env bash" "shebang of $(basename "$s")"
	[ "$(basename "$s")" = test_structure.sh ] && continue # contains the patterns below
	bad=$(grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)\}|grep -[a-zA-Z]*P|readlink -f|\[\[ -v| &>> | \|& ' "$s" | grep -v '^[0-9]*:[[:space:]]*#' || true)
	[ -z "$bad" ] && pass || fail "non-portable construct in $(basename "$s"): $bad"
	# GNU-only in-place sed at a command position (BSD sed needs a suffix argument).
	insed=$(grep -nE '(^|[|;&(]|\$\()[[:space:]]*sed -i( |$)' "$s" | grep -v '^[0-9]*:[[:space:]]*#' || true)
	[ -z "$insed" ] && pass || fail "GNU-only sed -i in $(basename "$s"): $insed"
done


describe "code intelligence and independent review are wired in"
assert_contains "$(field "$AGENTS/ticket-dev-explorer.md" tools)" "LSP" "explorer tools"
assert_contains "$(field "$AGENTS/ticket-dev-implementer.md" tools)" "LSP" "implementer tools"
assert_contains "$(cat "$SK")" "independent_review=yes" "review step"
assert_contains "$(cat "$SK")" "never \`--fix\`" "review never edits on its own"
assert_contains "$(cat "$SK")" "project rules" "rules are not copied"
assert_eq "$(sed -n 's/^REVIEW_ROUTES=//p' "$SKILL/routing.conf")" "complex" "review default"

describe "optional stages: off by default, bounded, one reviewer, detail in references"
hint=$(field "$SK" argument-hint)
for f in --browser --no-browser --codex-review --no-codex-review; do assert_contains "$hint" "$f" "argument-hint"; done
assert_contains "$(cat "$SK")" "references/browser-verification.md" "browser reference linked"
assert_contains "$(cat "$SK")" "references/codex-review.md" "codex reference linked"
assert_contains "$(cat "$SK")" "at most one reviewer" "no stacked reviewers"
assert_contains "$(cat "$SK")" "Run Codex at most once per ticket" "no review loop"
assert_contains "$(cat "$SK")" "counting verifier, browser and review findings together" "shared fix-round cap"
assert_contains "$(cat "$SK")" "review_fallback=claude" "fallback only when allowed"
assert_contains "$(cat "$SKILL/references/codex-review.md")" "Never present it as a Codex result" "no mislabeled review"
assert_contains "$(cat "$SKILL/references/codex-review.md")" "do not auto-fix" "security findings escalate"
assert_contains "$(cat "$SKILL/references/browser-verification.md")" "Never decide by reading code" "deterministic decision"
assert_contains "$(cat "$SKILL/references/browser-verification.md")" "cannot be reported as a clean DONE" "required mode"
assert_eq "$(sed -n 's/^BROWSER_VERIFICATION=//p' "$SKILL/browser.conf")" "off" "browser default"
for s in ticket-env browser-check codex-review; do
	assert_contains "$(cat "$SCRIPTS/preflight.sh")" "$s: bash" "preflight lists $s"
done

describe "gates and waiting rules found in live runs"
assert_contains "$(cat "$SK")" "after the developer has seen the plan" "plan approval needs the plan"
assert_contains "$(cat "$SK")" "without skipping a gate you have not shown yet" "proceed does not skip gates"
assert_contains "$(cat "$SK")" "no \`sleep\`, no polling" "wait for resumed subagents"
assert_contains "$(cat "$SK")" "never for code or diffs" "scan-secrets scope"

describe "a busy checkout hands the ticket to a new worktree"
assert_contains "$(grep '^!`' "$SK")" '--session ${CLAUDE_SESSION_ID}' "preflight knows the session"
assert_contains "$(cat "$SK")" "checkout=busy" "checkout rule"
HO="$SKILL/references/worktree-handoff.md"
assert_contains "$(cat "$HO")" "EnterWorktree" "session moves into the worktree"
assert_contains "$(cat "$HO")" "Save that branch as the default" "asks to save the default"
assert_contains "$(cat "$HO")" "Never fall back to working in the busy checkout" "no silent fallback"
assert_contains "$(cat "$SK")" "Take over this checkout" "a busy checkout asks instead of moving"
assert_contains "$(cat "$SK")" "release --session <session>" "the claim is released when the ticket stops"
assert_contains "$(cat "$SK")" "Dev server:" "report warns about a dev server serving the main checkout"
assert_contains "$(cat "$HO")" "setup_hint_dir" "nested installs"
assert_contains "$(cat "$HO")" "dev_server=" "dev-server warning in the handoff"

finish
