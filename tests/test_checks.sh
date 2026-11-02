#!/usr/bin/env bash
# detect-checks.sh finds the repository's own commands; run-check.sh reports
# PASS, FAIL, SKIP and TIMEOUT distinctly and never as a false pass.
. "$(dirname "$0")/lib.sh"

detect() { bash "$SCRIPTS/detect-checks.sh" "$1"; }
run_check() { bash "$SCRIPTS/run-check.sh" "$@"; }
export TICKET_DEV_LOG_DIR="$TEST_TMP/logs"

describe "node project with npm scripts and vitest"
d="$TEST_TMP/node"
mkdir -p "$d"
cat >"$d/package.json" <<'EOF'
{
  "scripts": { "typecheck": "tsc --noEmit", "lint": "eslint .", "test": "vitest run", "build": "tsc -p ." },
  "devDependencies": { "vitest": "^2.0.0", "typescript": "^5.0.0", "eslint": "^9.0.0" }
}
EOF
touch "$d/package-lock.json"
out=$(detect "$d")
assert_contains "$out" "check typecheck: npm run typecheck"
assert_contains "$out" "check lint: npm run lint"
assert_contains "$out" "check test: npm test"
assert_contains "$out" "check build: npm run build"
assert_contains "$out" "targeted test: npx vitest run <path>"
assert_contains "$out" 'targeted test-name: npx vitest run <path> -t "<name>"'
assert_contains "$out" "stack: node typescript"

describe "pnpm project without a typecheck script falls back to tsc"
d="$TEST_TMP/pnpm"
mkdir -p "$d"
printf '{ "scripts": { "test": "jest" }, "devDependencies": { "typescript": "5", "jest": "29" } }\n' >"$d/package.json"
touch "$d/pnpm-lock.yaml" "$d/tsconfig.json"
out=$(detect "$d")
assert_contains "$out" "check typecheck: pnpm exec tsc --noEmit"
assert_contains "$out" "check test: pnpm run test"
assert_contains "$out" "targeted test: pnpm exec jest <path>"
assert_contains "$out" 'targeted test-name: pnpm exec jest <path> -t "<name>"'

describe "go module"
d="$TEST_TMP/go"
mkdir -p "$d"
printf 'module example.com/x\n\ngo 1.22\n' >"$d/go.mod"
out=$(detect "$d")
assert_contains "$out" "check build: go build ./..."
assert_contains "$out" "check vet: go vet ./..."
assert_contains "$out" "check test: go test ./..."
assert_contains "$out" "targeted race: go test -race"

describe "python project managed by uv"
d="$TEST_TMP/py"
mkdir -p "$d"
printf '[project]\nname = "x"\n[tool.pytest.ini_options]\n[tool.ruff]\n[tool.mypy]\n' >"$d/pyproject.toml"
touch "$d/uv.lock"
out=$(detect "$d")
assert_contains "$out" "check test: uv run pytest -q"
assert_contains "$out" "check lint: uv run ruff check ."
assert_contains "$out" "check typecheck: uv run mypy ."

describe "Makefile targets"
d="$TEST_TMP/make"
mkdir -p "$d"
printf 'test:\n\t./t.sh\nlint:\n\t./l.sh\nother:\n\ttrue\n' >"$d/Makefile"
out=$(detect "$d")
assert_contains "$out" "check make-test: make test"
assert_contains "$out" "check make-lint: make lint"
assert_not_contains "$out" "make other"

describe "project-defined checks replace auto-detection"
d="$TEST_TMP/override"
mkdir -p "$d/.claude/ticket-dev"
printf '{ "scripts": { "test": "jest" } }\n' >"$d/package.json"
printf '# comment\ntest: pnpm -C apps/api test\ntargeted-test: pnpm -C apps/api exec vitest run <path>\n' >"$d/.claude/ticket-dev/checks.txt"
out=$(detect "$d")
assert_contains "$out" "check test: pnpm -C apps/api test"
assert_contains "$out" "targeted test: pnpm -C apps/api exec vitest run <path>"
assert_not_contains "$out" "npm test"
assert_contains "$out" "project-defined"

describe "nothing to detect is stated, not invented"
d="$TEST_TMP/empty"
mkdir -p "$d"
out=$(detect "$d")
assert_contains "$out" "no verification commands detected"
assert_not_contains "$out" "check "

describe "package.json parsing works without node"
if ! PATH=/usr/bin:/bin command -v node >/dev/null 2>&1; then
	out=$(PATH=/usr/bin:/bin bash "$SCRIPTS/detect-checks.sh" "$TEST_TMP/node")
	assert_contains "$out" "check test: npm test"
	assert_contains "$out" "parsed approximately"
else
	echo "  (skipped: node is on the minimal PATH)"
fi

describe "run-check: PASS"
out=$(run_check unit -- true)
assert_eq "$?" "0" "exit code"
assert_contains "$out" "[PASS] unit (exit 0"

describe "run-check: FAIL shows the error and keeps the full log"
out=$(run_check unit -- "echo 'Error: expected 2 to equal 3' >&2; echo done; exit 1")
assert_eq "$?" "1" "exit code"
assert_contains "$out" "[FAIL] unit (exit 1"
assert_contains "$out" "Error: expected 2 to equal 3"
log=$(printf '%s\n' "$out" | sed -n 's/^  log: \([^ ]*\).*/\1/p')
assert_file "$log" "log"
assert_not_contains "$out" "[PASS]"

describe "run-check: SKIP when the tool is missing or the check is not applicable"
out=$(run_check lint -- definitely-not-installed-tool --check)
assert_eq "$?" "3" "exit code"
assert_contains "$out" "[SKIP] lint - not installed: definitely-not-installed-tool"
out=$(run_check lint --skip "no linter configured")
assert_eq "$?" "3" "exit code"
assert_contains "$out" "[SKIP] lint - no linter configured"
out=$(run_check unit -- "exit 127")
assert_eq "$?" "1" "exit 127 from an installed command is a failure"

describe "run-check: TIMEOUT is not a pass"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
	out=$(TICKET_DEV_CHECK_TIMEOUT=1 run_check slow -- sleep 5)
	assert_eq "$?" "4" "exit code"
	assert_contains "$out" "[TIMEOUT] slow"
else
	echo "  (skipped: no timeout command)"
fi

describe "run-check: usage errors"
run_check >/dev/null 2>&1
assert_eq "$?" "2" "no arguments"
run_check 'bad name' -- true >/dev/null 2>&1
assert_eq "$?" "2" "invalid name"

finish
