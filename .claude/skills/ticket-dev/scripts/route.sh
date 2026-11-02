#!/usr/bin/env bash
# route.sh - deterministic complexity/risk scoring and model routing for /ticket-dev.
#
# The orchestrator supplies evidence-based inputs (counts and signals it found in
# the repository); this script applies the routing policy identically every time
# and prints key=value lines. Models come from routing.conf, never from code.
#
# Bash 3.2 compatible (stock macOS); needs only POSIX tools.

set -u
set -f # keyword stems contain '*'; never glob

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SKILL_DIR=$(dirname "$SCRIPT_DIR")

HIGH_SIGNALS="auth security secrets migration data-loss payments irreversible infra"
MEDIUM_SIGNALS="public-api external-integration concurrency pii performance"
KNOWN_MODELS="haiku sonnet opus fable"
FAST_PATH_MAX_WORDS=50
TAB=$(printf '\t')
NL='
'

usage() {
	cat <<'EOF'
Usage:
  route.sh --triage (--ticket TEXT | --ticket-stdin)
  route.sh --files N --modules N --uncertainty none|low|high --tests good|partial|none|na
           [--signals a,b] [--dismiss "flag:reason"]... [--decisions N] [--new-pattern]
           [--model ALIAS] [--gpt] [--ticket TEXT | --ticket-stdin]
  route.sh --print-config

Inputs (full mode):
  --files N          files expected to change, including tests
  --modules N        distinct modules/packages/services touched
  --uncertainty      none: precedent exists, approach obvious | low: minor unknowns |
                     high: no precedent, unclear approach, or unverified external behavior
  --tests            good|partial: tests cover the touched code | none: no coverage |
                     na: not behavior-bearing (copy, docs, styling, comments)
  --signals          confirmed risk signals (comma separated)
  --dismiss          a keyword flag that does not apply, with the reason (repeatable)
  --decisions N      unresolved decisions that would change behavior (must be asked)
  --new-pattern      no existing pattern in the repository to follow
  --model ALIAS      developer override for the implementation model
  --gpt              developer asked for a GPT review package

Signals:
  HIGH risk:   auth security secrets migration data-loss payments irreversible infra
  MEDIUM risk: public-api external-integration concurrency pii performance

Other options:
  --project-dir DIR  repository root for .claude/ticket-dev/routing.conf (default: git root or $PWD)
  --config FILE      base routing config (default: <skill>/routing.conf)
  --keywords FILE    risk keyword file (default: <skill>/risk-keywords.txt)
EOF
}

die() {
	echo "route.sh: $*" >&2
	exit 2
}

WARNINGS=""
warn() {
	if [ -z "$WARNINGS" ]; then WARNINGS=$1; else WARNINGS="$WARNINGS; $1"; fi
}

# in_list WORD "space separated list"
in_list() {
	case " $2 " in *" $1 "*) return 0 ;; esac
	return 1
}

# add_word VAR WORD: append WORD to space-separated VAR unless present
add_word() {
	eval "_cur=\${$1}"
	in_list "$2" "$_cur" && return 0
	if [ -z "$_cur" ]; then eval "$1=\$2"; else eval "$1=\"\$_cur \$2\""; fi
}

join_commas() { printf '%s' "$1" | tr ' ' ','; }

is_uint() {
	case "$1" in '' | *[!0-9]*) return 1 ;; esac
	return 0
}

valid_model() {
	printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9.-]*(\[1m\])?$'
}

model_rank() {
	case "$1" in
	haiku) echo 1 ;;
	sonnet) echo 2 ;;
	opus) echo 3 ;;
	fable) echo 4 ;;
	*) echo 0 ;;
	esac
}

# ---------------------------------------------------------------- config

MODEL_LIGHT=haiku
MODEL_STANDARD=sonnet
MODEL_COMPLEX=opus
MODEL_EXPLORER=haiku
MODEL_VERIFIER=haiku
LIGHT_MAX_FILES=2
REVIEW_ROUTES=complex
CONFIG_SOURCES=""

# Parse KEY=value lines without executing anything; unknown keys are ignored.
load_conf() {
	[ -f "$1" ] || return 0
	CONFIG_SOURCES="${CONFIG_SOURCES:+$CONFIG_SOURCES }$1"
	while IFS= read -r _line || [ -n "$_line" ]; do
		_line=${_line%%#*}
		_line=$(printf '%s' "$_line" | tr -d '[:space:]')
		[ -z "$_line" ] && continue
		_key=${_line%%=*}
		_val=${_line#*=}
		case "$_key" in
		MODEL_LIGHT | MODEL_STANDARD | MODEL_COMPLEX | MODEL_EXPLORER | MODEL_VERIFIER)
			if valid_model "$_val"; then
				eval "$_key=\$_val"
				in_list "$_val" "$KNOWN_MODELS" || warn "$_key=$_val is not a known alias; make sure your Claude Code version supports it"
			else
				warn "ignored invalid value $_key=$_val in $1"
			fi
			;;
		LIGHT_MAX_FILES)
			if is_uint "$_val"; then LIGHT_MAX_FILES=$_val; else warn "ignored invalid LIGHT_MAX_FILES=$_val in $1"; fi
			;;
		REVIEW_ROUTES)
			_ok=1
			for _r in $(printf '%s' "$_val" | tr ',' ' '); do
				in_list "$_r" "light standard complex none" || _ok=0
			done
			if [ "$_ok" -eq 1 ] && [ -n "$_val" ]; then REVIEW_ROUTES=$_val; else warn "ignored invalid REVIEW_ROUTES=$_val in $1"; fi
			;;
		*) warn "ignored unknown key $_key in $1" ;;
		esac
	done <"$1"
}

# ---------------------------------------------------------------- keywords

normalize() {
	printf ' %s ' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' '
}

# Prints "flag<TAB>keyword" for the first matching keyword of each flag.
scan_flags() {
	[ -f "$KEYWORDS_FILE" ] || {
		warn "keyword file not found: $KEYWORDS_FILE"
		return 0
	}
	awk -v text="$(normalize "$1")" '
		/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
		{
			i = index($0, ":"); if (i == 0) next
			flag = substr($0, 1, i - 1); gsub(/[[:space:]]/, "", flag)
			n = split(substr($0, i + 1), kws, ",")
			for (k = 1; k <= n; k++) {
				kw = tolower(kws[k])
				gsub(/[^a-z0-9*]+/, " ", kw); gsub(/^ +| +$/, "", kw)
				if (kw == "") continue
				if (substr(kw, length(kw)) == "*") pat = " " substr(kw, 1, length(kw) - 1)
				else pat = " " kw " "
				if (index(text, pat) > 0) { print flag "\t" kw; break }
			}
		}' "$KEYWORDS_FILE"
}

DETECTED_LIST=""
FLAGS_DETECTED=""
collect_flags() {
	_hits=$(scan_flags "$1")
	_oldifs=$IFS
	IFS=$NL
	for _h in $_hits; do
		_f=${_h%%"$TAB"*}
		_k=${_h#*"$TAB"}
		if ! in_list "$_f" "$HIGH_SIGNALS $MEDIUM_SIGNALS"; then
			warn "unknown flag '$_f' in $KEYWORDS_FILE"
			continue
		fi
		add_word DETECTED_LIST "$_f"
		FLAGS_DETECTED="${FLAGS_DETECTED:+$FLAGS_DETECTED,}$_f($_k)"
	done
	IFS=$_oldifs
}

# ---------------------------------------------------------------- arguments

MODE=full
TICKET=""
FILES=""
MODULES=""
UNCERTAINTY=""
TESTS=""
SIGNALS_IN=""
DISMISS_IN=""
DECISIONS=0
NEW_PATTERN=0
OVERRIDE=""
GPT_REQUESTED=0
PROJECT_DIR=""
CONFIG_FILE="$SKILL_DIR/routing.conf"
KEYWORDS_FILE="$SKILL_DIR/risk-keywords.txt"

need() { [ "$1" -ge 2 ] || die "$2 needs a value"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--triage) MODE=triage ;;
	--print-config) MODE=config ;;
	--ticket) need $# "$1"; TICKET=$2; shift ;;
	--ticket-stdin) TICKET=$(cat) ;;
	--files) need $# "$1"; FILES=$2; shift ;;
	--modules) need $# "$1"; MODULES=$2; shift ;;
	--uncertainty) need $# "$1"; UNCERTAINTY=$2; shift ;;
	--tests) need $# "$1"; TESTS=$2; shift ;;
	--signals) need $# "$1"; SIGNALS_IN="$SIGNALS_IN $2"; shift ;;
	--dismiss) need $# "$1"; DISMISS_IN="$DISMISS_IN$2$NL"; shift ;;
	--decisions) need $# "$1"; DECISIONS=$2; shift ;;
	--new-pattern) NEW_PATTERN=1 ;;
	--model) need $# "$1"; OVERRIDE=$2; shift ;;
	--gpt) GPT_REQUESTED=1 ;;
	--project-dir) need $# "$1"; PROJECT_DIR=$2; shift ;;
	--config) need $# "$1"; CONFIG_FILE=$2; shift ;;
	--keywords) need $# "$1"; KEYWORDS_FILE=$2; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

if [ -z "$PROJECT_DIR" ]; then
	PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
load_conf "$CONFIG_FILE"
load_conf "$PROJECT_DIR/.claude/ticket-dev/routing.conf"

print_models() {
	printf 'explorer_model=%s\n' "$MODEL_EXPLORER"
	printf 'verifier_model=%s\n' "$MODEL_VERIFIER"
}

# ---------------------------------------------------------------- config mode

if [ "$MODE" = config ]; then
	printf 'config_sources=%s\n' "${CONFIG_SOURCES:-none (built-in defaults)}"
	printf 'MODEL_LIGHT=%s\nMODEL_STANDARD=%s\nMODEL_COMPLEX=%s\n' "$MODEL_LIGHT" "$MODEL_STANDARD" "$MODEL_COMPLEX"
	printf 'MODEL_EXPLORER=%s\nMODEL_VERIFIER=%s\nLIGHT_MAX_FILES=%s\n' "$MODEL_EXPLORER" "$MODEL_VERIFIER" "$LIGHT_MAX_FILES"
	printf 'REVIEW_ROUTES=%s\n' "$REVIEW_ROUTES"
	printf 'warnings=%s\n' "$WARNINGS"
	exit 0
fi

# ---------------------------------------------------------------- triage mode

if [ "$MODE" = triage ]; then
	[ -n "$TICKET" ] || die "--triage needs --ticket or --ticket-stdin"
	collect_flags "$TICKET"
	words=$(printf '%s' "$TICKET" | wc -w | tr -d ' ')
	fast=yes
	why="no risk keywords, short ticket"
	if [ -n "$DETECTED_LIST" ]; then
		fast=no
		why="risk keywords present: confirm or dismiss each after exploring"
	elif [ "$words" -gt "$FAST_PATH_MAX_WORDS" ]; then
		fast=no
		why="ticket longer than $FAST_PATH_MAX_WORDS words"
	fi
	printf 'mode=triage\n'
	printf 'flags_detected=%s\n' "$FLAGS_DETECTED"
	printf 'ticket_words=%s\n' "$words"
	printf 'fast_path_allowed=%s\n' "$fast"
	printf 'fast_path_reason=%s\n' "$why"
	print_models
	printf 'warnings=%s\n' "$WARNINGS"
	exit 0
fi

# ---------------------------------------------------------------- full mode: validate

is_uint "$FILES" || die "--files must be a non-negative integer"
is_uint "$MODULES" || die "--modules must be a non-negative integer"
is_uint "$DECISIONS" || die "--decisions must be a non-negative integer"
case "$UNCERTAINTY" in none | low | high) ;; *) die "--uncertainty must be none, low or high" ;; esac
case "$TESTS" in good | partial | none | na) ;; *) die "--tests must be good, partial, none or na" ;; esac
if [ -n "$OVERRIDE" ]; then
	valid_model "$OVERRIDE" || die "--model '$OVERRIDE' is not a model alias"
fi

SIGNALS=""
for s in $(printf '%s' "$SIGNALS_IN" | tr ',' ' '); do
	in_list "$s" "$HIGH_SIGNALS $MEDIUM_SIGNALS" || die "unknown signal '$s' (see --help)"
	add_word SIGNALS "$s"
done

DISMISSED_LIST=""
FLAGS_DISMISSED=""
_oldifs=$IFS
IFS=$NL
for d in $DISMISS_IN; do
	IFS=$_oldifs
	flag=$(printf '%s' "${d%%:*}" | tr -d '[:space:]')
	reason=$(printf '%s' "${d#*:}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
	case "$d" in *:*) ;; *) reason="" ;; esac
	in_list "$flag" "$HIGH_SIGNALS $MEDIUM_SIGNALS" || die "cannot dismiss unknown flag '$flag'"
	[ -n "$reason" ] || die "--dismiss '$flag' needs a reason: --dismiss \"$flag:why it does not apply\""
	if in_list "$flag" "$SIGNALS"; then
		warn "$flag is both confirmed and dismissed; keeping it confirmed"
		continue
	fi
	add_word DISMISSED_LIST "$flag"
	FLAGS_DISMISSED="${FLAGS_DISMISSED:+$FLAGS_DISMISSED; }$flag($reason)"
done
IFS=$_oldifs

if [ -n "$TICKET" ]; then
	collect_flags "$TICKET"
else
	warn "no --ticket given; keyword flags were not checked"
fi

EFFECTIVE=$SIGNALS
UNADDRESSED=""
for f in $DETECTED_LIST; do
	if in_list "$f" "$EFFECTIVE" || in_list "$f" "$DISMISSED_LIST"; then continue; fi
	add_word UNADDRESSED "$f"
	add_word EFFECTIVE "$f"
done
[ -n "$UNADDRESSED" ] && warn "keyword flags treated as confirmed because they were neither confirmed nor dismissed: $(join_commas "$UNADDRESSED")"

# ---------------------------------------------------------------- complexity

points=0
reasons=""
note() { reasons="${reasons:+$reasons; }$1"; }

if [ "$FILES" -le 2 ]; then p=0; elif [ "$FILES" -le 6 ]; then p=1; else p=2; fi
points=$((points + p)); note "files=$FILES(+$p)"
if [ "$MODULES" -le 1 ]; then p=0; elif [ "$MODULES" -le 3 ]; then p=1; else p=2; fi
points=$((points + p)); note "modules=$MODULES(+$p)"
case "$UNCERTAINTY" in none) p=0 ;; low) p=1 ;; high) p=2 ;; esac
points=$((points + p)); note "uncertainty=$UNCERTAINTY(+$p)"
if [ "$NEW_PATTERN" -eq 1 ]; then points=$((points + 1)); note "new-pattern(+1)"; fi
for s in external-integration concurrency migration; do
	if in_list "$s" "$EFFECTIVE"; then points=$((points + 1)); note "$s(+1)"; fi
done

if [ "$points" -le 1 ]; then COMPLEXITY=LOW; elif [ "$points" -le 3 ]; then COMPLEXITY=MEDIUM; else COMPLEXITY=HIGH; fi

# ---------------------------------------------------------------- risk

high_hits=""
medium_hits=""
for s in $EFFECTIVE; do
	if in_list "$s" "$HIGH_SIGNALS"; then add_word high_hits "$s"; else add_word medium_hits "$s"; fi
done
if [ -n "$high_hits" ]; then
	RISK=HIGH
	note "risk HIGH: $(join_commas "$high_hits")"
elif [ -n "$medium_hits" ] || [ "$TESTS" = none ]; then
	RISK=MEDIUM
	[ -n "$medium_hits" ] && note "risk MEDIUM: $(join_commas "$medium_hits")"
	[ "$TESTS" = none ] && note "no tests cover the change (risk floor MEDIUM)"
else
	RISK=LOW
fi

# ---------------------------------------------------------------- route and gates

if [ "$COMPLEXITY" = HIGH ] || [ "$RISK" = HIGH ]; then
	ROUTE=complex
	MODEL=$MODEL_COMPLEX
elif [ "$COMPLEXITY" = LOW ] && [ "$RISK" = LOW ] && [ "$UNCERTAINTY" = none ] &&
	[ "$DECISIONS" -eq 0 ] && [ "$NEW_PATTERN" -eq 0 ] && [ "$FILES" -le "$LIGHT_MAX_FILES" ]; then
	ROUTE=light
	MODEL=$MODEL_LIGHT
else
	ROUTE=standard
	MODEL=$MODEL_STANDARD
fi
MODEL_SOURCE=routing.conf

if [ -n "$OVERRIDE" ]; then
	computed=$MODEL
	MODEL=$OVERRIDE
	MODEL_SOURCE=developer-override
	rc=$(model_rank "$computed")
	ro=$(model_rank "$OVERRIDE")
	if [ "$rc" -gt 0 ] && [ "$ro" -gt 0 ] && [ "$ro" -lt "$rc" ]; then
		warn "developer override runs $OVERRIDE below the computed $ROUTE route ($computed); risk is $RISK, so state this in the report"
	fi
fi

if [ "$RISK" = HIGH ]; then
	APPROVAL=required
elif [ "$COMPLEXITY" = HIGH ]; then
	APPROVAL=plan
else
	APPROVAL=none
fi

if [ "$GPT_REQUESTED" -eq 1 ]; then
	GPT=requested
elif [ "$COMPLEXITY" != LOW ] && [ "$UNCERTAINTY" = high ]; then
	GPT=offer
elif [ "$DECISIONS" -gt 0 ] && { [ "$COMPLEXITY" = HIGH ] || [ "$RISK" = HIGH ]; }; then
	GPT=offer
else
	GPT=skip
fi

if [ "$ROUTE" = complex ]; then
	VERIFICATION=broad
elif [ "$COMPLEXITY" = MEDIUM ] || [ "$RISK" = MEDIUM ]; then
	VERIFICATION=standard
else
	VERIFICATION=targeted
fi

# A fresh-context review (/code-review) costs a full extra pass, so it is reserved
# for the routes listed in REVIEW_ROUTES (default: complex only).
if in_list "$ROUTE" "$(printf '%s' "$REVIEW_ROUTES" | tr ',' ' ')"; then REVIEW=yes; else REVIEW=no; fi

# ---------------------------------------------------------------- output

printf 'complexity=%s\n' "$COMPLEXITY"
printf 'complexity_points=%s\n' "$points"
printf 'risk=%s\n' "$RISK"
printf 'route=%s\n' "$ROUTE"
printf 'model=%s\n' "$MODEL"
printf 'model_source=%s\n' "$MODEL_SOURCE"
print_models
printf 'approval=%s\n' "$APPROVAL"
printf 'blocking_questions=%s\n' "$DECISIONS"
printf 'gpt_review=%s\n' "$GPT"
printf 'verification=%s\n' "$VERIFICATION"
printf 'independent_review=%s\n' "$REVIEW"
printf 'signals=%s\n' "$(join_commas "$EFFECTIVE")"
printf 'flags_detected=%s\n' "$FLAGS_DETECTED"
printf 'flags_dismissed=%s\n' "$FLAGS_DISMISSED"
printf 'flags_unaddressed=%s\n' "$(join_commas "$UNADDRESSED")"
printf 'reasons=%s\n' "$reasons"
printf 'warnings=%s\n' "$WARNINGS"
