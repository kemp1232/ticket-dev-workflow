#!/usr/bin/env bash
# Run the whole test suite: bash tests/run.sh
# Offline and side-effect free. Set TICKET_DEV_LIVE=1 to also run the live Claude Code
# smoke test (uses your Claude usage; see tests/smoke.sh).

set -u
DIR=$(cd "$(dirname "$0")" && pwd)
failed=""
for t in "$DIR"/test_*.sh "$DIR"/smoke.sh; do
	if ! bash "$t"; then
		failed="$failed $(basename "$t")"
	fi
done
echo
if [ -n "$failed" ]; then
	echo "FAILED:$failed"
	exit 1
fi
echo "All test files passed."
