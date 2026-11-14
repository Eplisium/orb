#!/bin/bash
# check_warnings.sh — fail when a build log has more unique compiler warnings
# than the committed baseline.
#
# Usage: scripts/check_warnings.sh build.log [baseline-file]
#
# The baseline file (default scripts/warnings-baseline.txt) holds two lines:
#   total=<N>      unique warnings across all targets
#   sources=<N>    unique warnings in Sources/
# Lower the numbers in the same commit that removes warnings. Raising them
# needs a reviewed reason, not a quiet bump.
#
# An incremental build only re-reports warnings for recompiled files, so it can
# under-count; it can never over-count.
set -euo pipefail

LOG="${1:?usage: check_warnings.sh build.log [baseline-file]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASELINE="${2:-$SCRIPT_DIR/warnings-baseline.txt}"
[ -f "$LOG" ] || { echo "error: build log not found: $LOG" >&2; exit 2; }
[ -f "$BASELINE" ] || { echo "error: baseline not found: $BASELINE" >&2; exit 2; }

read_baseline() {
    local value
    value="$(grep -E "^$1=[0-9]+$" "$BASELINE" | head -1 | cut -d= -f2 || true)"
    [ -n "$value" ] || { echo "error: $BASELINE has no '$1=<number>' line" >&2; exit 2; }
    echo "$value"
}

max_total="$(read_baseline total)"
max_sources="$(read_baseline sources)"
total="$(bash "$SCRIPT_DIR/count_warnings.sh" "$LOG")"
sources="$(bash "$SCRIPT_DIR/count_warnings.sh" "$LOG" --sources-only)"

echo "Unique warnings: total $total (baseline $max_total), Sources/ $sources (baseline $max_sources)"
status=0
if [ "$total" -gt "$max_total" ]; then
    echo "::error::Unique compiler warnings rose to $total (baseline $max_total)."
    status=1
fi
if [ "$sources" -gt "$max_sources" ]; then
    echo "::error::Unique Sources/ warnings rose to $sources (baseline $max_sources)."
    status=1
fi
if [ "$status" -ne 0 ]; then
    echo "--- current unique warnings ---"
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E '^[^ ]+:[0-9]+:[0-9]+: warning: ' | sort -u \
        | sed -E 's#^.*/(Sources|Tests)/#\1/#' || true
fi
exit "$status"
