#!/usr/bin/env bash
# detect-checks.sh [DIR] - list the verification commands a repository already has.
#
# Output lines:
#   stack: <ecosystems>
#   check <name>: <command>          a whole-project check
#   targeted <name>: <template>      a narrower form; replace <path>/<name> before running
#                                    ("targeted test-name" runs a single test by name)
#   note: <text>
#   source: <where the commands came from>
#
# If DIR/.claude/ticket-dev/checks.txt exists it is used verbatim instead of
# auto-detection (format: "name: command", "targeted-name: template").
# Always exits 0. Bash 3.2 compatible.

set -u
set -f

ROOT=${1:-}
if [ -z "$ROOT" ]; then
	ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
cd "$ROOT" 2>/dev/null || {
	echo "note: cannot enter $ROOT"
	exit 0
}

OVERRIDE=".claude/ticket-dev/checks.txt"
if [ -f "$OVERRIDE" ]; then
	found=0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '' | '#'*) continue ;; esac
		name=$(printf '%s' "${line%%:*}" | tr -d '[:space:]')
		cmd=$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//')
		[ -n "$name" ] && [ -n "$cmd" ] || continue
		case "$name" in
		targeted-*) echo "targeted ${name#targeted-}: $cmd" ;;
		*) echo "check $name: $cmd" ;;
		esac
		found=1
	done <"$OVERRIDE"
	[ "$found" -eq 1 ] || echo "note: $OVERRIDE has no commands"
	echo "source: $OVERRIDE (project-defined)"
	exit 0
fi

STACK=""
add_stack() { case " $STACK " in *" $1 "*) ;; *) STACK="${STACK:+$STACK }$1" ;; esac; }
ANY=0
check() { echo "check $1: $2"; ANY=1; }
targeted() { echo "targeted $1: $2"; }
note() { echo "note: $1"; }
has_file() { [ -f "$1" ]; }

# ------------------------------------------------------------------ Node / TypeScript
if has_file package.json; then
	add_stack node
	if has_file pnpm-lock.yaml; then
		PM=pnpm; RUN="pnpm run"; EXEC="pnpm exec"
	elif has_file yarn.lock; then
		PM=yarn; RUN="yarn"; EXEC="yarn"
	elif has_file bun.lockb || has_file bun.lock; then
		PM=bun; RUN="bun run"; EXEC="bunx"
	else
		PM=npm; RUN="npm run"; EXEC="npx"
	fi

	# "script <name>\t<command>" and "dep <name>" lines.
	if command -v node >/dev/null 2>&1; then
		PKG=$(node -e '
			const p = require(require("path").resolve(process.argv[1]));
			for (const [k, v] of Object.entries(p.scripts || {})) console.log("script " + k + "\t" + v);
			const d = Object.assign({}, p.dependencies, p.devDependencies);
			for (const k of Object.keys(d)) console.log("dep " + k);
			if (p.workspaces) console.log("workspaces");
		' package.json 2>/dev/null)
	else
		PKG=$(awk '
			/"scripts"[[:space:]]*:[[:space:]]*\{/ { s = 1; next }
			s && /^[[:space:]]*\}/ { s = 0 }
			s && match($0, /"[^"]+"[[:space:]]*:/) {
				k = substr($0, RSTART + 1); sub(/".*/, "", k); print "script " k "\t?"
			}
			match($0, /"(vitest|jest|mocha|ava|typescript|eslint|@biomejs\/biome)"[[:space:]]*:/) {
				d = substr($0, RSTART + 1); sub(/".*/, "", d); print "dep " d
			}
			/"workspaces"/ { print "workspaces" }' package.json)
		note "node not found; package.json parsed approximately"
	fi
	has_script() { printf '%s\n' "$PKG" | grep -q "^script $1	"; }
	script_cmd() { printf '%s\n' "$PKG" | grep "^script $1	" | head -1 | cut -f2-; }
	has_dep() { printf '%s\n' "$PKG" | grep -qx "dep $1"; }

	if has_dep typescript || has_file tsconfig.json; then add_stack typescript; fi

	tc=""
	for s in typecheck type-check check-types types tsc; do
		if has_script "$s"; then tc="$RUN $s"; break; fi
	done
	if [ -z "$tc" ] && has_file tsconfig.json && has_dep typescript; then tc="$EXEC tsc --noEmit"; fi
	[ -n "$tc" ] && check typecheck "$tc"

	if has_script lint; then
		check lint "$RUN lint"
	elif has_dep @biomejs/biome || has_file biome.json || has_file biome.jsonc; then
		check lint "$EXEC biome check ."
	fi
	if has_dep eslint; then targeted lint "$EXEC eslint <changed-files>"; fi

	if has_script test; then
		case "$PM" in npm) check test "npm test" ;; *) check test "$RUN test" ;; esac
		tcmd=$(script_cmd test)
	else
		tcmd=""
	fi
	if has_dep vitest || printf '%s' "$tcmd" | grep -q vitest; then
		targeted test "$EXEC vitest run <path>"
		targeted test-name "$EXEC vitest run <path> -t \"<name>\""
	elif has_dep jest || printf '%s' "$tcmd" | grep -q jest; then
		targeted test "$EXEC jest <path>"
		targeted test-name "$EXEC jest <path> -t \"<name>\""
	elif has_dep mocha || printf '%s' "$tcmd" | grep -q mocha; then
		targeted test "$EXEC mocha <path>"
		targeted test-name "$EXEC mocha <path> --grep \"<name>\""
	elif printf '%s' "$tcmd" | grep -q 'node --test'; then
		targeted test "node --test <path>"
		targeted test-name "node --test --test-name-pattern=\"<name>\" <path>"
	fi
	for s in test:unit test:integration test:e2e; do
		has_script "$s" && check "$(printf '%s' "$s" | tr ':' '-')" "$RUN $s"
	done
	has_script build && check build "$RUN build"

	if printf '%s\n' "$PKG" | grep -qx workspaces || has_file pnpm-workspace.yaml || has_file turbo.json || has_file nx.json; then
		note "monorepo detected: prefer package-scoped commands, or define them in $OVERRIDE"
	fi
fi

# ------------------------------------------------------------------ Go
if has_file go.mod; then
	add_stack go
	check build "go build ./..."
	check vet "go vet ./..."
	check test "go test ./..."
	targeted test "go test ./<pkg-dir>/... -run '<TestName>'"
	targeted race "go test -race ./<pkg-dir>/..."
	if has_file .golangci.yml || has_file .golangci.yaml || has_file .golangci.toml; then
		check lint "golangci-lint run ./..."
	fi
fi

# ------------------------------------------------------------------ Python
if has_file pyproject.toml || has_file setup.py || has_file setup.cfg || has_file requirements.txt; then
	add_stack python
	if has_file uv.lock; then PY="uv run "; elif has_file poetry.lock; then PY="poetry run "; else PY=""; fi
	cfg=$(cat pyproject.toml setup.cfg tox.ini requirements*.txt 2>/dev/null)
	if has_file pytest.ini || has_file conftest.py || printf '%s' "$cfg" | grep -qi pytest; then
		check test "${PY}pytest -q"
		targeted test "${PY}pytest -q <path>::<test_name>"
	fi
	if has_file ruff.toml || has_file .ruff.toml || printf '%s' "$cfg" | grep -q '\[tool.ruff'; then
		check lint "${PY}ruff check ."
	fi
	if has_file mypy.ini || printf '%s' "$cfg" | grep -q '\[tool.mypy\]\|\[mypy\]'; then
		check typecheck "${PY}mypy ."
	elif has_file pyrightconfig.json || printf '%s' "$cfg" | grep -q '\[tool.pyright\]'; then
		check typecheck "${PY}pyright"
	fi
fi

# ------------------------------------------------------------------ Rust
if has_file Cargo.toml; then
	add_stack rust
	check build "cargo check"
	check lint "cargo clippy -- -D warnings"
	check test "cargo test"
	targeted test "cargo test <test_name>"
fi

# ------------------------------------------------------------------ JVM
if has_file gradlew; then
	add_stack jvm
	check test "./gradlew test"
	check build "./gradlew build -x test"
elif has_file pom.xml; then
	add_stack jvm
	check test "mvn -q test"
	targeted test "mvn -q test -Dtest=<TestClass>"
fi

# ------------------------------------------------------------------ Make
if has_file Makefile; then
	add_stack make
	for t in check typecheck lint test build; do
		if grep -q "^$t:" Makefile; then check "make-$t" "make $t"; fi
	done
fi

echo "stack: ${STACK:-unknown}"
if [ "$ANY" -eq 0 ]; then
	note "no verification commands detected; define them in $OVERRIDE"
fi
echo "source: auto-detected (confirm a command exists before relying on it)"
exit 0
