#!/bin/bash
# Crown Jules - Patch Generation Script
# Usage: ./generate-patches.sh <run_id> <session_id1> <session_id2> ...
# Fetches patches from Jules API and saves them to .crown-jules/<run_id>/
# Compatible with bash 3.2+ (macOS default)

set -e

# Source the API client library
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/api-client.sh"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <run_id> <session_id1> [session_id2] ..."
    echo "Example: $0 abc123 15117933240154076744 7829403212940903160"
    exit 1
fi

RUN_ID="$1"
shift
SESSION_IDS=("$@")
SESSION_COUNT=${#SESSION_IDS[@]}

# Check authentication
if ! jules_api_check_auth; then
    exit 1
fi

# Get repository root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    exit 1
fi

# All Crown Jules files live under .crown-jules/<run_id>/
CROWN_JULES_DIR="$REPO_ROOT/.crown-jules/$RUN_ID"

# Create the output directory
mkdir -p "$CROWN_JULES_DIR"

echo "Run ID: $RUN_ID"
echo "Fetching patches for $SESSION_COUNT sessions via API..."
echo ""

# Track results
success_count=0
failed_count=0

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-24s %-50s\n" "Session ID" "Result"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Process each session
for session_id in "${SESSION_IDS[@]}"; do
    patch_file="$CROWN_JULES_DIR/$session_id.patch"
    result=""

    # Fetch activities for this session
    activities_response=$(jules_api_get_activities "$session_id" 2>/dev/null)

    if [ -z "$activities_response" ]; then
        result="FAILED: Could not fetch activities from API"
        printf "%-24s ✗ %s\n" "$session_id" "$result"
        failed_count=$((failed_count + 1))
        continue
    fi

    # Extract the patch from activities
    patch_content=$(jules_api_extract_patch "$activities_response")

    if [ -z "$patch_content" ]; then
        result="FAILED: No patch found in session activities"
        printf "%-24s ✗ %s\n" "$session_id" "$result"
        failed_count=$((failed_count + 1))
        continue
    fi

    # Write patch to file
    echo "$patch_content" > "$patch_file"

    # Get patch stats
    lines_added=$(grep -c "^+[^+]" "$patch_file" 2>/dev/null || echo "0")
    lines_removed=$(grep -c "^-[^-]" "$patch_file" 2>/dev/null || echo "0")
    files_changed=$(grep -c "^diff --git" "$patch_file" 2>/dev/null || echo "0")

    result="SUCCESS: +$lines_added/-$lines_removed lines, $files_changed files"
    printf "%-24s ✓ %s\n" "$session_id" "$result"
    success_count=$((success_count + 1))
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Summary
echo "Summary: $success_count succeeded, $failed_count failed out of $SESSION_COUNT total"
echo ""

if [ $success_count -gt 0 ]; then
    echo "Patch files generated:"
    for session_id in "${SESSION_IDS[@]}"; do
        patch_file="$CROWN_JULES_DIR/$session_id.patch"
        if [ -f "$patch_file" ]; then
            echo "  $patch_file"
        fi
    done
    echo ""
    echo "Run compare-sessions.sh $RUN_ID to analyze the implementations."
fi

# Exit with error if all failed
if [ $success_count -eq 0 ]; then
    exit 1
fi

exit 0
