#!/bin/bash
# Crown Jules - Parallel Session Creation Script
# Usage: ./create-sessions.sh <repo> <count> "<prompt>" [branch] [title]
# Creates N Jules sessions in parallel and outputs JSON with session IDs and URLs
# Compatible with bash 3.2+ (macOS default)

set -e

# Source the API client library
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/api-client.sh"

if [ $# -lt 3 ]; then
    echo "Usage: $0 <repo> <count> \"<prompt>\" [branch] [title]"
    echo "Example: $0 owner/repo 4 \"Add dark mode toggle\" main \"Detailed: Add dark mode\""
    exit 1
fi

REPO="$1"
COUNT="$2"
PROMPT="$3"
BRANCH="${4:-main}"
TITLE="${5:-}"

# Validate count is a positive integer
if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Count must be a positive integer, got: $COUNT"
    exit 1
fi

# Check authentication
if ! jules_api_check_auth; then
    exit 1
fi

echo "Creating $COUNT parallel Jules sessions..."
echo "Repository: $REPO"
echo "Branch: $BRANCH"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Create temp directory for session results
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Launch parallel session creation jobs
PIDS=()
for ((i=1; i<=COUNT; i++)); do
    (
        result_file="$TEMP_DIR/session_$i.json"
        error_file="$TEMP_DIR/session_$i.err"

        # Create session
        response=$(jules_api_create_session "$PROMPT" "$REPO" "$BRANCH" "$TITLE" 2>"$error_file")
        exit_code=$?

        if [ $exit_code -eq 0 ] && [ -n "$response" ]; then
            # Extract session name and ID
            session_name=$(echo "$response" | jq -r '.name // empty')
            if [ -n "$session_name" ]; then
                session_id="${session_name##*/}"
                session_url="${JULES_WEB_BASE}/${session_id}"

                # Write result
                echo "{\"id\": \"$session_id\", \"url\": \"$session_url\", \"status\": \"created\"}" > "$result_file"
            else
                echo "{\"error\": \"No session name in response\", \"response\": $(echo "$response" | jq -c .)}" > "$result_file"
            fi
        else
            error_msg=$(cat "$error_file" 2>/dev/null || echo "Unknown error")
            echo "{\"error\": \"$error_msg\"}" > "$result_file"
        fi
    ) &
    PIDS+=($!)
done

# Wait for all jobs to complete
echo "Waiting for $COUNT sessions to be created..."
for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

echo ""

# Collect results
SUCCESS_COUNT=0
FAILED_COUNT=0
SESSIONS=()

for ((i=1; i<=COUNT; i++)); do
    result_file="$TEMP_DIR/session_$i.json"
    if [ -f "$result_file" ]; then
        result=$(cat "$result_file")
        error=$(echo "$result" | jq -r '.error // empty')

        if [ -z "$error" ]; then
            session_id=$(echo "$result" | jq -r '.id')
            session_url=$(echo "$result" | jq -r '.url')
            SESSIONS+=("$result")
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo "Session #$i: $session_id"
            echo "  URL: $session_url"
        else
            FAILED_COUNT=$((FAILED_COUNT + 1))
            echo "Session #$i: FAILED - $error"
        fi
    else
        FAILED_COUNT=$((FAILED_COUNT + 1))
        echo "Session #$i: FAILED - No result file"
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Summary: $SUCCESS_COUNT created, $FAILED_COUNT failed out of $COUNT total"
echo ""

# Output JSON array of sessions
if [ $SUCCESS_COUNT -gt 0 ]; then
    echo "Sessions JSON:"
    echo "["
    first=true
    for session in "${SESSIONS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo "  $session"
    done
    echo "]"
fi

# Exit with error if all failed
if [ $SUCCESS_COUNT -eq 0 ]; then
    echo ""
    echo "ERROR: All session creations failed"
    exit 1
fi

exit 0
