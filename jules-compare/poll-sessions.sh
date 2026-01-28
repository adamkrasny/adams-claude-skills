#!/bin/bash
# Jules Compare - Session Polling Script
# Usage: ./poll-sessions.sh <session_id1> <session_id2> ...
# Polls jules sessions every 30 seconds until all reach terminal state (Completed/Failed)
# Compatible with bash 3.2+ (macOS default)

if [ $# -eq 0 ]; then
    echo "Usage: $0 <session_id1> [session_id2] ..."
    exit 1
fi

POLL_INTERVAL=30
JULES_URL_BASE="https://jules.google.com/session"

# Store session IDs in a simple array
SESSION_IDS=("$@")
SESSION_COUNT=${#SESSION_IDS[@]}

# Store statuses in a parallel array (same indices)
SESSION_STATUSES=()
for ((i=0; i<SESSION_COUNT; i++)); do
    SESSION_STATUSES+=("Pending")
done

# Terminal states that indicate a session is done
is_terminal_status() {
    local status="$1"
    case "$status" in
        Completed|Failed) return 0 ;;
        *) return 1 ;;
    esac
}

# Get status for a single session from jules remote list output
get_session_status() {
    local session_id="$1"
    local output="$2"

    # Find the line containing this session ID
    # Use grep -F for fixed string matching, strip ANSI codes first
    local clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    local line=$(echo "$clean_output" | grep -F "$session_id" | head -1)

    if [ -z "$line" ]; then
        echo "Pending"
        return
    fi

    # Status is the last column - extract it
    # The output format is: ID  Description  Repo  LastActive  Status
    local status=$(echo "$line" | awk '{print $NF}')

    # Handle multi-word statuses that got truncated in the output
    case "$status" in
        Progress) echo "In Progress" ;;
        Approval|A|A...) echo "Awaiting Plan Approval" ;;
        F|F...) echo "Awaiting User Feedback" ;;
        Planning) echo "Planning" ;;
        Completed) echo "Completed" ;;
        Failed) echo "Failed" ;;
        *)
            # Check if it might be part of "In Progress" or other multi-word status
            if echo "$line" | grep -q "In Progress"; then
                echo "In Progress"
            elif echo "$line" | grep -q "Awaiting"; then
                echo "Awaiting Approval"
            else
                echo "$status"
            fi
            ;;
    esac
}

# Print status table
print_status_table() {
    echo ""
    echo "Jules Compare - Polling Sessions (every ${POLL_INTERVAL}s)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-22s %-24s %s\n" "Session ID" "Status" "URL"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    for ((i=0; i<SESSION_COUNT; i++)); do
        local session_id="${SESSION_IDS[$i]}"
        local status="${SESSION_STATUSES[$i]}"
        local url="${JULES_URL_BASE}/${session_id}"
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

while [ "$all_done" = false ]; do
    poll_count=$((poll_count + 1))

    # Get current status from jules (capture both stdout and stderr, but only use stdout)
    output=$(jules remote list --session 2>/dev/null) || output=""

    # If output is empty, try again
    if [ -z "$output" ]; then
        echo "Warning: Could not get session list from Jules CLI. Retrying..."
        sleep 5
        continue
    fi

    # Update statuses
    all_done=true
    for ((i=0; i<SESSION_COUNT; i++)); do
        session_id="${SESSION_IDS[$i]}"
        status=$(get_session_status "$session_id" "$output")
        SESSION_STATUSES[$i]="$status"

        if ! is_terminal_status "$status"; then
            all_done=false
        fi
    done

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
