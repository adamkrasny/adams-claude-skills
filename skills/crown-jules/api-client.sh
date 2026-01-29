#!/bin/bash
# Crown Jules - Jules API Client Library
# Provides functions for interacting with the Jules REST API
# Source this file in other scripts: source "$(dirname "$0")/api-client.sh"
# Compatible with bash 3.2+ (macOS default)

# API Configuration
JULES_API_BASE="https://jules.googleapis.com/v1alpha"
JULES_WEB_BASE="https://jules.google.com/session"

# Maximum retries for rate limiting
MAX_RETRIES=5
INITIAL_BACKOFF_MS=1000

# ============================================================================
# Authentication
# ============================================================================

# Check that JULES_API_KEY is set
# Returns: 0 if set, 1 if not
jules_api_check_auth() {
    if [ -z "$JULES_API_KEY" ]; then
        echo "ERROR: JULES_API_KEY environment variable is not set" >&2
        echo "Please set your Jules API key:" >&2
        echo "  export JULES_API_KEY='your-api-key'" >&2
        return 1
    fi
    return 0
}

# ============================================================================
# Core Request Functions
# ============================================================================

# Make a raw API request with retry logic for rate limiting
# Arguments:
#   $1 - HTTP method (GET, POST, etc.)
#   $2 - API endpoint (e.g., "/sessions" or "/sessions/{id}")
#   $3 - Request body (optional, for POST/PUT)
# Returns: curl output on stdout, exits with curl exit code
# Side effects: Writes error messages to stderr
jules_api_request() {
    local method="$1"
    local endpoint="$2"
    local body="$3"
    local url="${JULES_API_BASE}${endpoint}"

    local retry=0
    local backoff_ms=$INITIAL_BACKOFF_MS

    while [ $retry -le $MAX_RETRIES ]; do
        local curl_args=(
            -s
            -w "\n%{http_code}"
            -X "$method"
            -H "x-goog-api-key: $JULES_API_KEY"
            -H "Content-Type: application/json"
        )

        if [ -n "$body" ]; then
            curl_args+=(-d "$body")
        fi

        curl_args+=("$url")

        local response
        response=$(curl "${curl_args[@]}" 2>/dev/null)
        local curl_exit=$?

        if [ $curl_exit -ne 0 ]; then
            echo "ERROR: curl failed with exit code $curl_exit" >&2
            return $curl_exit
        fi

        # Extract HTTP status code (last line) and body (everything else)
        local http_code
        local response_body
        http_code=$(echo "$response" | tail -n1)
        response_body=$(echo "$response" | sed '$d')

        # Handle rate limiting (429)
        if [ "$http_code" = "429" ]; then
            retry=$((retry + 1))
            if [ $retry -gt $MAX_RETRIES ]; then
                echo "ERROR: Rate limited after $MAX_RETRIES retries" >&2
                echo "$response_body"
                return 1
            fi

            # Calculate backoff with jitter
            local jitter=$((RANDOM % 500))
            local sleep_ms=$((backoff_ms + jitter))
            local sleep_sec
            sleep_sec=$(awk "BEGIN {printf \"%.2f\", $sleep_ms/1000}")

            echo "Rate limited, retrying in ${sleep_sec}s (attempt $retry/$MAX_RETRIES)..." >&2
            sleep "$sleep_sec"

            # Exponential backoff
            backoff_ms=$((backoff_ms * 2))
            continue
        fi

        # Handle other errors
        if [ "$http_code" -ge 400 ]; then
            echo "ERROR: API returned HTTP $http_code" >&2
            echo "$response_body" >&2
            return 1
        fi

        # Success - output response body
        echo "$response_body"
        return 0
    done
}

# GET request wrapper
# Arguments:
#   $1 - API endpoint
jules_api_get() {
    jules_api_request "GET" "$1"
}

# POST request wrapper
# Arguments:
#   $1 - API endpoint
#   $2 - Request body (JSON)
jules_api_post() {
    jules_api_request "POST" "$1" "$2"
}

# ============================================================================
# Session Operations
# ============================================================================

# List all connected sources
# Arguments: none
# Returns: JSON response with sources array
jules_api_list_sources() {
    jules_api_get "/sources"
}

# Get a specific source by name
# Arguments:
#   $1 - Source name (e.g., "sources/github-owner-repo" or just "github-owner-repo")
# Returns: JSON response with source details
jules_api_get_source() {
    local source_name="$1"
    # Ensure proper format
    if [[ "$source_name" != sources/* ]]; then
        source_name="sources/$source_name"
    fi
    jules_api_get "/$source_name"
}

# Build source name from owner/repo
# Arguments:
#   $1 - GitHub repo (owner/repo format)
# Returns: Source name in format "sources/github-owner-repo"
jules_api_build_source_name() {
    local repo="$1"
    echo "sources/github-${repo//\//-}"
}

# Create a new Jules session
# Arguments:
#   $1 - Prompt text
#   $2 - GitHub repo (owner/repo format)
#   $3 - Branch name (optional, defaults to "main")
# Returns: JSON response with session details
jules_api_create_session() {
    local prompt="$1"
    local repo="$2"
    local branch="${3:-main}"

    # Escape special characters in prompt for JSON
    local escaped_prompt
    escaped_prompt=$(echo "$prompt" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' ')

    # Build source name - format: sources/github-{owner}-{repo}
    local source_name
    source_name=$(jules_api_build_source_name "$repo")

    local body
    body=$(cat <<EOF
{
  "prompt": "$escaped_prompt",
  "sourceContext": {
    "source": "$source_name",
    "githubRepoContext": {
      "startingBranch": "$branch"
    }
  },
  "requirePlanApproval": false
}
EOF
)

    jules_api_post "/sessions" "$body"
}

# Get session details by ID
# Arguments:
#   $1 - Session ID
# Returns: JSON response with session details including state
jules_api_get_session() {
    local session_id="$1"
    jules_api_get "/sessions/$session_id"
}

# Get activities for a session (includes patches)
# Arguments:
#   $1 - Session ID
# Returns: JSON response with activities array
jules_api_get_activities() {
    local session_id="$1"
    jules_api_get "/sessions/$session_id/activities"
}

# ============================================================================
# Helper Functions
# ============================================================================

# Map API state to display name
# Arguments:
#   $1 - API state (e.g., "IN_PROGRESS", "COMPLETED")
# Returns: Human-readable state name
jules_api_state_to_display() {
    local state="$1"
    case "$state" in
        QUEUED) echo "Queued" ;;
        PLANNING) echo "Planning" ;;
        AWAITING_PLAN_APPROVAL) echo "Awaiting Plan Approval" ;;
        IN_PROGRESS) echo "In Progress" ;;
        COMPLETED) echo "Completed" ;;
        FAILED) echo "Failed" ;;
        AWAITING_USER_FEEDBACK) echo "Awaiting User Feedback" ;;
        *) echo "$state" ;;
    esac
}

# Check if a state is terminal (session is done)
# Arguments:
#   $1 - API state
# Returns: 0 if terminal, 1 if not
jules_api_is_terminal_state() {
    local state="$1"
    case "$state" in
        COMPLETED|FAILED) return 0 ;;
        *) return 1 ;;
    esac
}

# Extract session ID from full session name
# Arguments:
#   $1 - Full session name (e.g., "sessions/12345")
# Returns: Just the ID (e.g., "12345")
jules_api_extract_session_id() {
    local name="$1"
    echo "${name##*/}"
}

# Build Jules web URL from session ID
# Arguments:
#   $1 - Session ID
# Returns: Full web URL
jules_api_session_url() {
    local session_id="$1"
    echo "${JULES_WEB_BASE}/${session_id}"
}

# Extract patch from activities response
# Arguments:
#   $1 - Activities JSON response
# Returns: Unified diff patch content, or empty if no patch found
jules_api_extract_patch() {
    local activities_json="$1"

    # Look for changeSet.gitPatch.unidiffPatch in any activity
    # Activities are ordered, so we want the most recent one with a patch
    echo "$activities_json" | jq -r '
        .activities // []
        | map(select(.artifact.changeSet.gitPatch.unidiffPatch != null))
        | last
        | .artifact.changeSet.gitPatch.unidiffPatch // empty
    ' 2>/dev/null
}
