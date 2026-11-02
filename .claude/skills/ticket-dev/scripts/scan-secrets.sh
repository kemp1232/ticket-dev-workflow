#!/usr/bin/env bash
# scan-secrets.sh FILE - check text that will leave the machine (e.g. a GPT review
# package) for credentials and personal data before the developer copies it.
#
# Prints one line per finding with the line number and category, never the value.
# Exit codes: 0 clean, 1 findings, 2 usage error. Bash 3.2 compatible.

set -u
set -f # patterns contain glob characters

[ $# -eq 1 ] && [ -f "$1" ] || {
	echo "usage: scan-secrets.sh FILE" >&2
	exit 2
}
FILE=$1

# category@@extended-regex
PATTERNS='
private key@@-----BEGIN [A-Z ]*PRIVATE KEY-----
aws access key@@(AKIA|ASIA)[0-9A-Z]{16}
github token@@(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})
slack token@@xox[abprs]-[A-Za-z0-9-]{10,}
api key (sk-)@@sk-(ant-|proj-|live-|test-)?[A-Za-z0-9_-]{20,}
stripe key@@(sk|rk|pk)_(live|test)_[0-9A-Za-z]{16,}
google api key@@AIza[0-9A-Za-z_-]{35}
jwt@@eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+
url with credentials@@[a-zA-Z][a-zA-Z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]+@
secret assignment@@([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy])[A-Za-z_]*[[:space:]]*[:=][[:space:]]*["'"'"']?[^"'"'"'[:space:]<>{}]{8,}
email address@@[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
ip address@@(^|[^0-9.])((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])([^0-9.]|$)
'

found=0
oldifs=$IFS
IFS='
'
for entry in $PATTERNS; do
	IFS=$oldifs
	cat_name=${entry%%@@*}
	re=${entry#*@@}
	# Mask documentation placeholders (example.com addresses, localhost IPs) first.
	lines=$(sed -E -e 's/[A-Za-z0-9._%+-]+@(example\.(com|org|net)|test\.com|localhost)//g' \
		-e 's/(127\.0\.0\.1|0\.0\.0\.0)/LOCALHOST/g' "$FILE" |
		grep -nE -- "$re" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
	if [ -n "$lines" ]; then
		echo "FOUND $cat_name on line(s): $lines"
		found=1
	fi
done
IFS=$oldifs

if [ "$found" -eq 0 ]; then
	echo "CLEAN: no credential or personal-data patterns found in $FILE"
	exit 0
fi
echo "Remove or redact the lines above before sharing $FILE."
exit 1
