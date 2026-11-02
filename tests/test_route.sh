#!/usr/bin/env bash
# Routing decisions: tiers, risk, gates, GPT policy, overrides and model configuration.
. "$(dirname "$0")/lib.sh"

P="$TEST_TMP/proj"
mkdir -p "$P"
route() { bash "$SCRIPTS/route.sh" --project-dir "$P" "$@"; }

describe "triage: trivial ticket may skip exploration"
out=$(route --triage --ticket "Fix the typo in the footer copyright text")
assert_eq "$(kv fast_path_allowed "$out")" "yes" "fast path"
assert_eq "$(kv flags_detected "$out")" "" "flags"

describe "triage: risky keywords force exploration"
out=$(route --triage --ticket "Add a migration for the session table")
assert_eq "$(kv fast_path_allowed "$out")" "no" "fast path"
assert_contains "$(kv flags_detected "$out")" "migration(" "flags"
assert_contains "$(kv flags_detected "$out")" "auth(session" "flags"

describe "triage: long tickets are not fast-pathed"
long=$(printf 'word %.0s' $(seq 1 60))
assert_eq "$(kv fast_path_allowed "$(route --triage --ticket "$long")")" "no" "fast path"

describe "triage: ticket via stdin keeps quotes and dollars intact"
out=$(printf '%s\n' 'Show "$5.00" price label; it'"'"'s wrong' | route --triage --ticket-stdin)
assert_eq "$(kv ticket_words "$out")" "6" "words"

describe "LOW routes to the light model with minimal process"
out=$(route --files 1 --modules 1 --uncertainty none --tests na --ticket "Fix footer typo")
assert_eq "$(kv complexity "$out")" "LOW"
assert_eq "$(kv route "$out")" "light"
assert_eq "$(kv model "$out")" "haiku"
assert_eq "$(kv approval "$out")" "none"
assert_eq "$(kv gpt_review "$out")" "skip"
assert_eq "$(kv verification "$out")" "targeted"

describe "LOW but more files than LIGHT_MAX_FILES uses standard"
out=$(route --files 3 --modules 1 --uncertainty none --tests good)
assert_eq "$(kv complexity "$out")" "LOW"
assert_eq "$(kv route "$out")" "standard"

describe "MEDIUM routes to standard implementation without approval"
out=$(route --files 4 --modules 2 --uncertainty low --tests good --signals public-api --ticket "Implement pagination on the existing products API")
assert_eq "$(kv complexity "$out")" "MEDIUM"
assert_eq "$(kv risk "$out")" "MEDIUM"
assert_eq "$(kv route "$out")" "standard"
assert_eq "$(kv model "$out")" "sonnet"
assert_eq "$(kv approval "$out")" "none"
assert_eq "$(kv gpt_review "$out")" "skip"
assert_eq "$(kv verification "$out")" "standard"

describe "HIGH complexity routes to complex with plan approval"
out=$(route --files 8 --modules 4 --uncertainty high --tests good)
assert_eq "$(kv complexity "$out")" "HIGH"
assert_eq "$(kv risk "$out")" "LOW"
assert_eq "$(kv route "$out")" "complex"
assert_eq "$(kv model "$out")" "opus"
assert_eq "$(kv approval "$out")" "plan"
assert_eq "$(kv verification "$out")" "broad"

describe "HIGH risk escalates even a small change and requires approval"
out=$(route --files 1 --modules 1 --uncertainty none --tests good --signals auth)
assert_eq "$(kv complexity "$out")" "LOW"
assert_eq "$(kv risk "$out")" "HIGH"
assert_eq "$(kv route "$out")" "complex"
assert_eq "$(kv approval "$out")" "required"

describe "untested behavior sets a MEDIUM risk floor"
out=$(route --files 1 --modules 1 --uncertainty none --tests none)
assert_eq "$(kv risk "$out")" "MEDIUM"
assert_eq "$(kv route "$out")" "standard"

describe "keyword flags cannot be dropped silently"
out=$(route --files 1 --modules 1 --uncertainty none --tests good --ticket "Add a column via migration")
assert_eq "$(kv risk "$out")" "HIGH" "unaddressed migration flag"
assert_eq "$(kv flags_unaddressed "$out")" "migration"
assert_contains "$(kv warnings "$out")" "treated as confirmed"
out=$(route --files 1 --modules 1 --uncertainty none --tests good --dismiss "migration:the word refers to a docs page title" --ticket "Fix typo on the migration guide page")
assert_eq "$(kv risk "$out")" "LOW" "dismissed with reason"
assert_contains "$(kv flags_dismissed "$out")" "migration(the word refers to a docs page title)"

describe "invalid input is rejected, not guessed"
route --files 1 --modules 1 --uncertainty none --tests good --dismiss "migration" >/dev/null 2>&1
assert_eq "$?" "2" "dismiss without reason"
route --files 1 --modules 1 --uncertainty none --tests good --signals made-up >/dev/null 2>&1
assert_eq "$?" "2" "unknown signal"
route --files many --modules 1 --uncertainty none --tests good >/dev/null 2>&1
assert_eq "$?" "2" "non-numeric files"
route --files 1 --modules 1 --uncertainty maybe --tests good >/dev/null 2>&1
assert_eq "$?" "2" "bad uncertainty"

describe "GPT review is optional and never automatic for HIGH alone"
out=$(route --files 9 --modules 4 --uncertainty none --tests good --signals migration)
assert_eq "$(kv route "$out")" "complex"
assert_eq "$(kv gpt_review "$out")" "skip" "HIGH without uncertainty"
out=$(route --files 4 --modules 2 --uncertainty high --tests good)
assert_eq "$(kv gpt_review "$out")" "offer" "real uncertainty"
out=$(route --files 2 --modules 1 --uncertainty none --tests good --signals payments --decisions 1)
assert_eq "$(kv gpt_review "$out")" "offer" "open decision on HIGH risk"
assert_eq "$(kv blocking_questions "$out")" "1"
out=$(route --files 1 --modules 1 --uncertainty none --tests na --gpt)
assert_eq "$(kv gpt_review "$out")" "requested" "developer asked"

describe "developer override is honored and downgrades are flagged"
out=$(route --files 1 --modules 1 --uncertainty none --tests good --signals auth --model haiku)
assert_eq "$(kv model "$out")" "haiku"
assert_eq "$(kv model_source "$out")" "developer-override"
assert_eq "$(kv approval "$out")" "required" "gate still applies"
assert_contains "$(kv warnings "$out")" "below the computed complex route"
out=$(route --files 1 --modules 1 --uncertainty none --tests na --model opus)
assert_eq "$(kv model "$out")" "opus"
assert_not_contains "$(kv warnings "$out")" "below the computed" "upgrade needs no warning"

describe "changing a model alias needs only routing config"
mkdir -p "$P/.claude/ticket-dev"
printf 'MODEL_COMPLEX=fable\nMODEL_LIGHT=sonnet\n' >"$P/.claude/ticket-dev/routing.conf"
out=$(route --files 9 --modules 4 --uncertainty high --tests good)
assert_eq "$(kv model "$out")" "fable" "project override"
out=$(route --files 1 --modules 1 --uncertainty none --tests na)
assert_eq "$(kv model "$out")" "sonnet" "project override light"
out=$(route --print-config)
assert_eq "$(kv MODEL_STANDARD "$out")" "sonnet" "unchanged keys inherited"
printf 'MODEL_COMPLEX=opus-next\nMODEL_STANDARD=$(rm -rf /)\nBOGUS=1\n' >"$P/.claude/ticket-dev/routing.conf"
out=$(route --files 9 --modules 4 --uncertainty high --tests good)
assert_eq "$(kv model "$out")" "opus-next" "new alias accepted"
assert_contains "$(kv warnings "$out")" "not a known alias"
assert_contains "$(kv warnings "$out")" "ignored invalid value MODEL_STANDARD"
assert_contains "$(kv warnings "$out")" "ignored unknown key BOGUS"
rm -f "$P/.claude/ticket-dev/routing.conf"
printf 'MODEL_STANDARD=opus\n' >"$TEST_TMP/base.conf"
out=$(route --config "$TEST_TMP/base.conf" --files 4 --modules 2 --uncertainty low --tests good)
assert_eq "$(kv model "$out")" "opus" "alternate base config"


describe "independent review only on the routes REVIEW_ROUTES names"
rm -f "$P/.claude/ticket-dev/routing.conf"
assert_eq "$(kv independent_review "$(route --files 9 --modules 4 --uncertainty high --tests good)")" "yes" "complex"
assert_eq "$(kv independent_review "$(route --files 3 --modules 1 --uncertainty low --tests good)")" "no" "standard"
assert_eq "$(kv independent_review "$(route --files 1 --modules 1 --uncertainty none --tests na)")" "no" "light"
mkdir -p "$P/.claude/ticket-dev"
printf 'REVIEW_ROUTES=standard,complex\n' >"$P/.claude/ticket-dev/routing.conf"
assert_eq "$(kv independent_review "$(route --files 3 --modules 1 --uncertainty low --tests good)")" "yes" "standard when configured"
printf 'REVIEW_ROUTES=none\n' >"$P/.claude/ticket-dev/routing.conf"
assert_eq "$(kv independent_review "$(route --files 9 --modules 4 --uncertainty high --tests good)")" "no" "disabled"
printf 'REVIEW_ROUTES=sometimes\n' >"$P/.claude/ticket-dev/routing.conf"
out=$(route --files 9 --modules 4 --uncertainty high --tests good)
assert_eq "$(kv independent_review "$out")" "yes" "invalid value keeps the default"
assert_contains "$(kv warnings "$out")" "ignored invalid REVIEW_ROUTES"
rm -f "$P/.claude/ticket-dev/routing.conf"

describe "Codex cross-model review: explicit request first, opt-in per project, one reviewer"
cx() { route --files 9 --modules 4 --uncertainty high --tests good "$@"; }
out=$(cx)
assert_eq "$(kv codex_review "$out")/$(kv independent_review "$out")/$(kv review_fallback "$out")" "no/yes/none" "default: Claude review only"
out=$(route --files 1 --modules 1 --uncertainty none --tests na --codex-review)
assert_eq "$(kv codex_review "$out")/$(kv independent_review "$out")/$(kv review_fallback "$out")" "requested/no/none" "explicit request on a light ticket, no Claude fallback"
out=$(cx --codex-review)
assert_eq "$(kv codex_review "$out")/$(kv independent_review "$out")/$(kv review_fallback "$out")" "requested/no/claude" "Codex replaces Claude review, which stays the fallback"
mkdir -p "$P/.claude/ticket-dev"
printf 'CODEX_REVIEW_ROUTES=complex\n' >"$P/.claude/ticket-dev/routing.conf"
assert_eq "$(kv codex_review "$(cx)")" "configured" "project opt-in"
assert_eq "$(kv codex_review "$(route --files 3 --modules 1 --uncertainty low --tests good)")" "no" "other routes unaffected"
out=$(cx --no-codex-review)
assert_eq "$(kv codex_review "$out")/$(kv independent_review "$out")" "no/yes" "developer declines: Claude review as before"
assert_contains "$(route --print-config)" "CODEX_REVIEW_ROUTES=complex ($P/.claude/ticket-dev/routing.conf)" "config shows the opt-in source"
printf 'CODEX_REVIEW_ROUTES=often\n' >"$P/.claude/ticket-dev/routing.conf"
out=$(cx)
assert_eq "$(kv codex_review "$out")" "no" "invalid value"
assert_contains "$(kv warnings "$out")" "ignored invalid CODEX_REVIEW_ROUTES"
rm -f "$P/.claude/ticket-dev/routing.conf"
printf 'CODEX_REVIEW_ROUTES=standard,complex\n' >"$TEST_TMP/shared.conf"
out=$(route --config "$TEST_TMP/shared.conf" --files 9 --modules 4 --uncertainty high --tests good)
assert_eq "$(kv codex_review "$out")" "no" "a shared/global config cannot opt projects in"
assert_contains "$(kv warnings "$out")" "must be enabled per project"
assert_eq "$(sed -n 's/^CODEX_REVIEW_ROUTES=//p' "$SKILL/routing.conf")" "none" "shipped default"
assert_eq "$(kv browser_verifier_model "$(route --triage --ticket x)")" "sonnet" "browser verifier model from routing.conf"

finish
