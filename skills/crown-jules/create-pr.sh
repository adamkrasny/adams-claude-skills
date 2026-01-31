#!/usr/bin/env bash
# Crown Jules - Create PR Script
# Sends a message to a completed Jules session asking it to create a PR
# Usage: create-pr.sh <session_id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/api-client.sh"

# Validate arguments
if [ $# -lt 1 ]; then
    echo "Usage: create-pr.sh <session_id>" >&2
    exit 1
fi

session_id="$1"

# Check auth
jules_api_check_auth || exit 1

# Send message asking to create PR
echo "Requesting PR creation for session $session_id..." >&2
jules_api_send_message "$session_id" "Please create a pull request for these changes."

# Poll session until PR appears (max 2 minutes, 5 second intervals)
max_polls=24
poll_interval=5

for ((i=1; i<=max_polls; i++)); do
    session=$(jules_api_get_session "$session_id")
    pr_url=$(jules_api_extract_pr_url "$session")

    if [ -n "$pr_url" ]; then
        echo "PR created successfully!" >&2
        echo "$pr_url"
        exit 0
    fi

    echo "Poll $i/$max_polls - Waiting for PR creation..." >&2
    sleep $poll_interval
done

echo "ERROR: PR was not created within timeout (2 minutes)" >&2
echo "You can manually create a PR from: $(jules_api_session_url "$session_id")" >&2
exit 1
