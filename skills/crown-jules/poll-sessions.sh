#!/bin/bash
# Crown Jules - Session Polling Script
# Usage: ./poll-sessions.sh <session_id1> <session_id2> ...
# Polls Jules sessions via API every 30 seconds until all reach terminal state (Completed/Failed)
# Compatible with bash 3.2+ (macOS default)

# Source the API client library
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/api-client.sh"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <session_id1> [session_id2] ..."
    exit 1
fi

# Check authentication
if ! jules_api_check_auth; then
    exit 1
fi

POLL_INTERVAL=30

# Store session IDs in a simple array
SESSION_IDS=("$@")
SESSION_COUNT=${#SESSION_IDS[@]}

# Store statuses in a parallel array (same indices)
SESSION_STATUSES=()
for ((i=0; i<SESSION_COUNT; i++)); do
    SESSION_STATUSES+=("Pending")
done

# Print status table
print_status_table() {
    echo ""
    echo "Crown Jules - Polling Sessions (every ${POLL_INTERVAL}s)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-22s %-24s %s\n" "Session ID" "Status" "URL"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    for ((i=0; i<SESSION_COUNT; i++)); do
        local session_id="${SESSION_IDS[$i]}"
        local status="${SESSION_STATUSES[$i]}"
        local url=$(jules_api_session_url "$session_id")
        local status_display="$status"

        # Add checkmark for completed, X for failed
        case "$status" in
            Completed) status_display="Completed ✓" ;;
            Failed) status_display="Failed ✗" ;;
        esac

        printf "%-22s %-24s %s\n" "$session_id" "$status_display" "$url"
    done

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Main polling loop
all_done=false
poll_count=0
consecutive_failures=0
MAX_CONSECUTIVE_FAILURES=10

while [ "$all_done" = false ]; do
    poll_count=$((poll_count + 1))
    all_done=true
    poll_failed=false

    # Poll each session individually via API
    for ((i=0; i<SESSION_COUNT; i++)); do
        session_id="${SESSION_IDS[$i]}"

        # Get session status via API
        response=$(jules_api_get_session "$session_id" 2>/dev/null)

        if [ -z "$response" ]; then
            poll_failed=true
            continue
        fi

        # Extract state from response
        api_state=$(echo "$response" | jq -r '.state // empty')

        if [ -n "$api_state" ]; then
            # Convert API state to display name
            display_status=$(jules_api_state_to_display "$api_state")
            SESSION_STATUSES[$i]="$display_status"

            # Check if terminal
            if ! jules_api_is_terminal_state "$api_state"; then
                all_done=false
            fi
        else
            poll_failed=true
        fi
    done

    # Handle consecutive failures
    if [ "$poll_failed" = true ] && [ "$all_done" = true ]; then
        # Only count as failure if we think we're done but had errors
        consecutive_failures=$((consecutive_failures + 1))
        echo "Warning: Could not get status for some sessions (attempt $consecutive_failures/$MAX_CONSECUTIVE_FAILURES)"

        if [ $consecutive_failures -ge $MAX_CONSECUTIVE_FAILURES ]; then
            echo ""
            echo "ERROR: Failed to get session status after $MAX_CONSECUTIVE_FAILURES attempts."
            echo "Possible causes:"
            echo "  - JULES_API_KEY is invalid or expired"
            echo "  - Network connectivity issues"
            echo "  - Jules API is down"
            exit 1
        fi

        sleep 5
        all_done=false
        continue
    fi

    # Reset failure counter on success
    consecutive_failures=0

    # Print current status
    print_status_table

    # If not all done, wait and poll again
    if [ "$all_done" = false ]; then
        echo ""
        echo "Poll #$poll_count - Waiting ${POLL_INTERVAL}s... (Ctrl+C to stop)"
        sleep $POLL_INTERVAL
    fi
done

echo ""
echo "All sessions have reached terminal state."
echo ""

# Print final summary
completed=0
failed=0
for ((i=0; i<SESSION_COUNT; i++)); do
    case "${SESSION_STATUSES[$i]}" in
        Completed) completed=$((completed + 1)) ;;
        Failed) failed=$((failed + 1)) ;;
    esac
done

echo "Summary: $completed completed, $failed failed out of $SESSION_COUNT total"
