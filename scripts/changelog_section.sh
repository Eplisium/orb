#!/bin/bash
# changelog_section.sh — print the CHANGELOG.md body for one version, for use
# as GitHub Release notes.
#
# Usage: scripts/changelog_section.sh 1.2.0 [CHANGELOG.md]
#
# Prints everything between the "## [1.2.0]" heading and the next "## "
# heading (exclusive), with leading/trailing blank lines trimmed. Exits 1 when
# the section is missing or empty, so a release can't ship without notes.
set -euo pipefail

VERSION="${1:?usage: changelog_section.sh VERSION [CHANGELOG.md]}"
FILE="${2:-$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md}"
[ -f "$FILE" ] || { echo "error: $FILE not found" >&2; exit 2; }

body="$(awk -v version="$VERSION" '
    BEGIN { heading = "## [" version "]" }
    index($0, "## ") == 1 {
        if (found) exit
        if (index($0, heading) == 1) { found = 1; next }
    }
    found && index($0, "[") == 1 && $0 ~ /^\[[^]]+\]: / { next }  # compare links
    found { print }
' "$FILE" | sed -e '/./,$!d')"  # trim leading blank lines; $(…) drops trailing ones

if [ -z "${body//[[:space:]]/}" ]; then
    echo "error: no '## [$VERSION]' section with content in $FILE" >&2
    exit 1
fi
printf '%s\n' "$body"
