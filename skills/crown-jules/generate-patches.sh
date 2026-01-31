#!/bin/bash
# Crown Jules - Patch Generation Script
# Usage: ./generate-patches.sh <run_id> <session_id1> <session_id2> ...
# Fetches patches from Jules API and saves them to .crown-jules/<run_id>/
# Falls back to git diff if API fails but branch is available
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
echo "Fetching patches for $SESSION_COUNT sessions..."
echo ""

# Track results
success_count=0
failed_count=0
no_changes_count=0
api_failed_count=0

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-24s %-50s\n" "Session ID" "Result"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper function to try git diff fallback
# Arguments:
#   $1 - Session ID
#   $2 - Patch file path
#   $3 - Session response JSON (optional, to avoid redundant API call)
try_git_fallback() {
    local session_id="$1"
    local patch_file="$2"
    local session_response="$3"

    local branch_name=""

    # Use provided session response, or fetch if not provided
    if [ -z "$session_response" ]; then
        session_response=$(jules_api_get_session "$session_id" 2>/dev/null)
    fi

    if [ -n "$session_response" ]; then
        branch_name=$(jules_api_extract_branch "$session_response")
    fi

    # If API didn't return branch name, try to find it by session ID pattern
    if [ -z "$branch_name" ]; then
        branch_name=$(jules_api_find_branch_by_session "$session_id")
    fi

    if [ -z "$branch_name" ]; then
        echo ""
        return 1
    fi

    # Fetch the branch from origin
    if ! git fetch origin "$branch_name" 2>/dev/null; then
        echo ""
        return 1
    fi

    # Generate patch using git diff
    local patch_content
    patch_content=$(git diff main...origin/"$branch_name" 2>/dev/null)

    if [ -z "$patch_content" ]; then
        # Try without the three-dot syntax
        patch_content=$(git diff main..origin/"$branch_name" 2>/dev/null)
    fi

    if [ -n "$patch_content" ]; then
        echo "$patch_content" > "$patch_file"
        echo "$branch_name"
        return 0
    fi

    # Branch exists but no diff - session completed without changes
    echo "NO_CHANGES:$branch_name"
    return 2
}

# Process each session
for session_id in "${SESSION_IDS[@]}"; do
    patch_file="$CROWN_JULES_DIR/$session_id.patch"
    result=""
    method=""

    # First, try to fetch session from API (patch is in .outputs[].changeSet.gitPatch.unidiffPatch)
    session_response=$(jules_api_get_session "$session_id" 2>/dev/null)
    patch_content=""

    if [ -n "$session_response" ]; then
        # Extract the patch from session outputs
        patch_content=$(jules_api_extract_patch_from_session "$session_response")
    fi

    if [ -n "$patch_content" ]; then
        # API method succeeded
        echo "$patch_content" > "$patch_file"
        method="API"
    else
        # API failed or no patch - try git fallback
        api_failed_count=$((api_failed_count + 1))
        fallback_result=$(try_git_fallback "$session_id" "$patch_file" "$session_response")
        fallback_exit=$?

        if [ $fallback_exit -eq 0 ] && [ -n "$fallback_result" ] && [ -f "$patch_file" ]; then
            method="git ($fallback_result)"
        elif [ $fallback_exit -eq 2 ]; then
            # Session completed but made no changes
            branch_name="${fallback_result#NO_CHANGES:}"
            result="NO CHANGES: Session completed but made no code changes (branch: $branch_name)"
            printf "%-24s ⊘ %s\n" "$session_id" "$result"
            no_changes_count=$((no_changes_count + 1))
            continue
        else
            result="FAILED: No patch from API and git fallback failed"
            printf "%-24s ✗ %s\n" "$session_id" "$result"
            failed_count=$((failed_count + 1))
            continue
        fi
    fi

    # Get patch stats
    lines_added=$(grep -c "^+[^+]" "$patch_file" 2>/dev/null || echo "0")
    lines_removed=$(grep -c "^-[^-]" "$patch_file" 2>/dev/null || echo "0")
    files_changed=$(grep -c "^diff --git" "$patch_file" 2>/dev/null || echo "0")

    result="SUCCESS via $method: +$lines_added/-$lines_removed lines, $files_changed files"
    printf "%-24s ✓ %s\n" "$session_id" "$result"
    success_count=$((success_count + 1))
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Summary
echo "Summary: $success_count succeeded, $failed_count failed, $no_changes_count no-changes out of $SESSION_COUNT total"
if [ $api_failed_count -gt 0 ] && [ $success_count -gt 0 ]; then
    echo "  Note: $api_failed_count session(s) used git fallback (API patch unavailable)"
fi
if [ $no_changes_count -gt 0 ]; then
    echo "  Note: $no_changes_count session(s) completed but made no code changes"
    echo "        (Jules may have interpreted the task differently or decided no changes were needed)"
fi
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
    echo ""
    echo "All patch generation failed. Possible causes:"
    echo "  - API authentication issues (check JULES_API_KEY)"
    echo "  - Sessions did not create branches (check Jules web UI)"
    echo "  - Network connectivity issues"
    echo ""
    echo "You can still view the implementations at:"
    for session_id in "${SESSION_IDS[@]}"; do
        echo "  https://jules.google.com/session/$session_id"
    done
    exit 1
fi

exit 0
