#!/bin/bash
# count_warnings.sh — count unique compiler warnings in a `swift build` log.
#
# Usage: scripts/count_warnings.sh build.log [--sources-only] [--summary]
#
# SwiftPM can print the same diagnostic more than once (e.g. once per
# compile job), so this de-duplicates on "file:line:col: warning: message".
set -euo pipefail

LOG="${1:?usage: count_warnings.sh build.log [--sources-only] [--summary]}"
shift || true
SOURCES_ONLY=0
SUMMARY=0
for arg in "$@"; do
    case "$arg" in
        --sources-only) SOURCES_ONLY=1 ;;
        --summary) SUMMARY=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Strip ANSI colour codes, keep only located warnings, de-duplicate.
UNIQUE="$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E '^[^ ]+:[0-9]+:[0-9]+: warning: ' | sort -u || true)"
if [ "$SOURCES_ONLY" = 1 ]; then
    UNIQUE="$(printf '%s\n' "$UNIQUE" | grep '/Sources/' || true)"
fi

if [ -z "$UNIQUE" ]; then
    echo 0
    exit 0
fi

COUNT="$(printf '%s\n' "$UNIQUE" | wc -l | tr -d ' ')"
echo "$COUNT"

if [ "$SUMMARY" = 1 ]; then
    echo "--- top warning kinds ---"
    printf '%s\n' "$UNIQUE" | sed -E 's/.*: warning: //; s/'"'"'[^'"'"']*'"'"'/X/g; s/ \[#.*//' \
        | sort | uniq -c | sort -rn | head -15
fi
