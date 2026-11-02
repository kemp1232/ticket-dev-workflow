#!/usr/bin/env bash
# The subagent guard: read-only explorer, non-mutating verifier, implementer that
# cannot push, discard changes, install, migrate, deploy or touch secrets.
. "$(dirname "$0")/lib.sh"

G="$SCRIPTS/guard.sh"
allow() { # mode command
	if out=$(bash "$G" "$1" --command "$2" 2>&1); then pass; else fail "$1 should allow: $2 ($out)"; fi
}
deny() {
	if bash "$G" "$1" --command "$2" >/dev/null 2>&1; then fail "$1 should block: $2"; else pass; fi
}

describe "explore: read-only commands pass"
for c in 'grep -rn "useState|useEffect" src | head -20' "find . -name '*.ts' -not -path '*/node_modules/*'" \
	'sed -n "1,40p" src/a.ts' 'git log --oneline -5 -- src/a.ts' 'git -C repo diff HEAD~1 --stat' \
	'rg -n "=>" src 2>/dev/null' 'ls -la && wc -l src/a.ts' 'find src -name "*.go" -exec grep -l Handler {} \;' \
	'git branch -a' 'git stash list' 'cat package.json' 'git show HEAD:src/a.ts | head -50'; do
	allow explore "$c"
done

describe "explore: anything that writes is blocked"
for c in 'git stash' 'git stash pop' 'git reflog expire --all' 'git checkout -- .' 'npm install' \
	'echo x > out.txt' 'sed -i s/a/b/ f' 'find . -delete' 'cat .env' 'grep -rn KEY $(ls)' \
	'git branch newbranch' 'awk 1 f' 'git diff --output=x' 'touch a' 'rm -rf node_modules' 'npm test' \
	'cat a | tee b' 'python3 -c "open(1)"'; do
	deny explore "$c"
done

describe "implement: normal development commands pass"
for c in 'npm test -- src/products' 'pnpm exec vitest run src/a.test.ts' 'go test ./internal/... -run TestList' \
	'git status --short' 'git diff --stat' 'rm src/old.ts' 'mv src/a.ts src/b.ts' 'grep -rn "=>" src' \
	'bash /x/run-check.sh test -- "npm test"' 'npx prisma generate' 'pnpm test src/migrations/foo.test.ts' \
	'npm run test -- migration' 'sort -u f' 'grep -rn az src' 'cat .env.example' 'git mv a b' \
	'curl -fsSL http://localhost:3000/health' 'npx tsc --noEmit' 'python -m pytest -q tests/test_x.py'; do
	allow implement "$c"
done

describe "implement: irreversible or out-of-scope commands are blocked"
for c in 'git push origin main' 'git commit -am x' 'git -C . stash' 'git reset --hard HEAD' \
	'git checkout -- src/a.ts' 'git restore .' 'git clean -fd' 'git add -A' 'rm -rf dist' 'rm src/*.ts' \
	'npm install lodash' 'pnpm add zod' 'yarn' 'npx prisma migrate deploy' 'pnpm run db:migrate' \
	'psql -c "drop table x"' 'npm publish' 'kubectl apply -f k.yaml' 'terraform apply' 'vercel --prod' \
	'bash -c "git push"' 'FOO=1 npm install' 'echo SECRET=1 > .env' 'cat .env' 'go mod tidy' \
	'aws s3 rm s3://b/x' 'sudo rm x' 'curl -X POST https://api.example.com' 'cd sub && git push' \
	'python manage.py migrate' 'gh pr merge 1' 'rails db:migrate' 'alembic upgrade head' \
	'docker compose down -v' 'echo $(git push)'; do
	deny implement "$c"
done

describe "verify: running checks passes"
for c in 'bash /x/run-check.sh test -- "npm test"' 'npm test 2>&1 | tail -20' 'go test -race ./pkg/...' \
	'git diff --stat abc123' 'git status --porcelain --untracked-files=all' 'npx eslint src/a.ts' \
	'ruff check .' 'ruff format --check .' 'cargo fmt --check' 'npm test > /tmp/out.log 2>&1' \
	'bash /x/run-check.sh lint --skip "no linter configured"'; do
	allow verify "$c"
done

describe "verify: fixing, formatting, snapshot updates and installs are blocked"
for c in 'npx eslint --fix src' 'prettier --write .' 'npm test -- -u' 'npx vitest run -u' 'rm a.log' \
	'sed -i s/a/b/ f' 'npm test > out.log' 'git stash' 'pnpm run format' 'cargo fmt' 'black .' \
	'go test ./... -update' 'npm ci' 'bash /x/run-check.sh test -- "npm test -- -u"'; do
	deny verify "$c"
done

describe "all agent modes: no nested sessions, cross-provider review or worktree management"
for m in implement verify browser; do
	for c in 'claude -p "/ticket-dev x"' 'codex exec review --uncommitted' 'npx codex review' \
		'bash /home/u/.claude/skills/ticket-dev/scripts/codex-review.sh --baseline abc' \
		'bash .claude/skills/ticket-dev/scripts/ticket-worktree.sh clean feat' 'npx playwright install chromium' \
		'playwright-cli install --skills'; do
		deny "$m" "$c"
	done
done
allow implement 'grep -rn "claude" src'
allow implement 'npm test -- codex'

describe "browser: local app checks pass"
for c in 'bash /x/browser-check.sh env' 'bash /x/browser-check.sh server start' \
	'playwright-cli -s=td-a open --config /tmp/td/browser/playwright-cli.json http://127.0.0.1:3142/products' \
	'playwright-cli -s=td-a snapshot --filename=/tmp/td/browser/j1.yml' \
	'playwright-cli -s=td-a click e12' 'playwright-cli -s=td-a resize 390 844' 'playwright-cli -s=td-a console error' \
	'curl -s -o /dev/null -w "%{http_code}" http://localhost:3142/' 'bash /x/run-check.sh e2e -- "npx playwright test --reporter=line"' \
	'git status --porcelain' 'echo see https://docs.example.com for details' \
	'playwright-cli -s=td-a goto http://app.localhost:3000/'; do
	allow browser "$c"
done

describe "browser: production URLs, unmanaged servers, repo artifacts and edits are blocked"
for c in 'playwright-cli -s=td-a open --config /tmp/c.json https://shop.example.com' \
	'playwright-cli -s=td-a goto --url=https://admin.example.com' \
	'playwright-cli -s=td-a open http://127.0.0.1:3142' 'npx playwright-cli snapshot' 'playwright-cli click e3' \
	'playwright-cli -s=td-a attach' 'playwright-cli -s=td-a open --config /tmp/c.json --persistent http://localhost:3000' \
	'playwright-cli -s=td-a open --config /tmp/c.json --profile ~/.config/google-chrome http://localhost:3000' \
	'curl https://api.example.com/v1/orders' 'wget http://10.0.0.8/' 'npm run dev' 'pnpm dev' 'next dev -p 3000' \
	'kill 1234' 'rm -rf .next' 'echo x > src/app.tsx' 'git checkout -- src' 'npx playwright test -u' 'npm install'; do
	deny browser "$c"
done
bash "$G" browser --edit src/app.tsx 2>/dev/null && fail "browser verifier edited" || pass
bash "$G" browser --url https://bank.example.com 2>/dev/null && fail "MCP navigation to production" || pass
bash "$G" browser --url http://localhost:3000/cart && pass || fail "MCP navigation to localhost"
J='{"tool_name":"mcp__claude-in-chrome__navigate","tool_input":{"url":"https://prod.example.com","tabId":1}}'
printf '%s' "$J" | bash "$G" browser 2>/dev/null && fail "jq path allowed MCP navigation" || pass
printf '%s' "$J" | TICKET_DEV_GUARD_NO_JQ=1 bash "$G" browser 2>/dev/null && fail "fallback path allowed MCP navigation" || pass
printf '%s' "$J" | bash "$G" implement && pass || fail "MCP check is browser-mode only"
REPORT=$(printf "bash /x/browser-check.sh save-report --required <<'EOF'\nBROWSER VERIFICATION: FAIL\n- requests to https://api.example.com > 0 failed (rm -rf noted)\nEOF")
allow browser "$REPORT"
deny browser "$(printf "bash /x/browser-check.sh save-report <<'EOF'; git push\nx\nEOF")"
deny implement "$(printf "bash <<'EOF'\ngit push\nEOF")"

describe "file tools: secrets and read-only roles"
bash "$G" implement --edit src/a.ts && pass || fail "implementer edits source"
bash "$G" implement --edit config/.env.example && pass || fail "implementer edits .env.example"
bash "$G" implement --edit .env.production 2>/dev/null && fail "implementer edited .env.production" || pass
bash "$G" implement --edit deploy/server.pem 2>/dev/null && fail "implementer edited a key" || pass
bash "$G" explore --edit src/a.ts 2>/dev/null && fail "explorer edited" || pass
bash "$G" verify --edit src/a.ts 2>/dev/null && fail "verifier edited" || pass
bash "$G" verify --read .env 2>/dev/null && fail "verifier read .env" || pass
bash "$G" explore --read src/a.ts && pass || fail "explorer reads source"

describe "hook JSON input, with and without jq"
J='{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin \"main\"","description":"push \"it\""}}'
printf '%s' "$J" | bash "$G" implement 2>/dev/null && fail "jq path allowed push" || pass
printf '%s' "$J" | TICKET_DEV_GUARD_NO_JQ=1 bash "$G" implement 2>/dev/null && fail "fallback path allowed push" || pass
J='{"tool_name":"Bash","tool_input":{"command":"grep -rn \"=>\" src | head","description":"search"}}'
printf '%s' "$J" | TICKET_DEV_GUARD_NO_JQ=1 bash "$G" explore && pass || fail "fallback path blocked a search"
J='{"tool_name":"Edit","tool_input":{"file_path":"/repo/.env.local","old_string":"a","new_string":"b"}}'
printf '%s' "$J" | TICKET_DEV_GUARD_NO_JQ=1 bash "$G" implement 2>/dev/null && fail "fallback path allowed .env edit" || pass
J='{"tool_name":"Read","tool_input":{"file_path":"/repo/src/app.ts"}}'
printf '%s' "$J" | bash "$G" explore && pass || fail "read of source blocked"

describe "agent hook commands locate the guard and fail closed"
hook_cmd() { sed -n "s/^ *command: '\(.*\)'$/\1/p" "$AGENTS/$1.md"; }
proj="$TEST_TMP/hookproj"
new_repo "$proj"
mkdir -p "$proj/.claude/skills/ticket-dev"
cp -R "$SCRIPTS" "$proj/.claude/skills/ticket-dev/scripts"
PUSH='{"tool_name":"Bash","tool_input":{"command":"git push"}}'
LS='{"tool_name":"Bash","tool_input":{"command":"ls src"}}'
for a in ticket-dev-explorer ticket-dev-implementer ticket-dev-verifier ticket-dev-browser-verifier; do
	cmd=$(hook_cmd "$a")
	printf '%s' "$PUSH" | CLAUDE_PROJECT_DIR="$proj" sh -c "$cmd" 2>/dev/null
	assert_eq "$?" "2" "$a blocks git push via its hook"
	printf '%s' "$LS" | CLAUDE_PROJECT_DIR="$proj" sh -c "$cmd" 2>/dev/null
	assert_eq "$?" "0" "$a allows ls via its hook"
	# Started from a subdirectory with no CLAUDE_PROJECT_DIR: falls back to the git root.
	mkdir -p "$proj/sub"
	(cd "$proj/sub" && printf '%s' "$LS" | CLAUDE_PROJECT_DIR="$proj/sub" sh -c "$cmd" 2>/dev/null)
	assert_eq "$?" "0" "$a finds the guard from a subdirectory"
	# No guard anywhere: block rather than run unguarded.
	(cd "$TEST_TMP" && printf '%s' "$LS" | CLAUDE_PROJECT_DIR="$TEST_TMP" sh -c "$cmd" 2>/dev/null)
	assert_eq "$?" "2" "$a fails closed without the guard"
done

finish
