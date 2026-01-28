#!/bin/bash
# Crown Jules - Worktree Setup Script
# Usage: ./setup-worktrees.sh <run_id> <base_branch> <session_id1> <session_id2> ...
# Creates git worktrees in parallel for evaluating Jules session changes
# Compatible with bash 3.2+ (macOS default)

set -e

if [ $# -lt 3 ]; then
    echo "Usage: $0 <run_id> <base_branch> <session_id1> [session_id2] ..."
    echo "Example: $0 abc123 main 15117933240154076744 7829403212940903160"
    exit 1
fi

RUN_ID="$1"
BASE_BRANCH="$2"
shift 2
SESSION_IDS=("$@")
SESSION_COUNT=${#SESSION_IDS[@]}

# Get repository root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    exit 1
fi

# All Crown Jules files live under .crown-jules/<run_id>/
CROWN_JULES_DIR="$REPO_ROOT/.crown-jules/$RUN_ID"
WORKTREE_DIR="$CROWN_JULES_DIR/worktrees"

# Verify base branch exists
if ! git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
    echo "ERROR: Base branch '$BASE_BRANCH' does not exist"
    exit 1
fi

# Check for clean working tree
if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: Working tree is not clean. Commit or stash changes first."
    exit 1
fi

# Create directories
mkdir -p "$WORKTREE_DIR"
echo "Run ID: $RUN_ID"
echo "Setting up worktrees in: $WORKTREE_DIR"
echo ""

# Track results
declare -a PIDS
declare -a RESULTS
TEMP_DIR=$(mktemp -d)

# Function to setup a single worktree
setup_worktree() {
    local session_id="$1"
    local result_file="$2"
    local branch_name="crown-jules/$RUN_ID/$session_id"
    local worktree_path="$WORKTREE_DIR/session-$session_id"

    # Initialize result as failure
    echo "FAILED: Unknown error" > "$result_file"

    # Check if worktree already exists
    if [ -d "$worktree_path" ]; then
        echo "SUCCESS: Worktree already exists" > "$result_file"
        return 0
    fi

    # Check if branch already exists
    if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
        # Branch exists, just create worktree
        if git worktree add "$worktree_path" "$branch_name" 2>/dev/null; then
            echo "SUCCESS: Worktree created (existing branch)" > "$result_file"
            return 0
        else
            echo "FAILED: Could not create worktree for existing branch" > "$result_file"
            return 1
        fi
    fi

    # Create new branch and worktree from base branch
    if ! git worktree add -b "$branch_name" "$worktree_path" "$BASE_BRANCH" 2>/dev/null; then
        echo "FAILED: Could not create worktree and branch" > "$result_file"
        return 1
    fi

    # Apply Jules changes in the worktree
    # Use 'builtin cd' to bypass shell hooks like zoxide that can break in subprocesses
    builtin cd "$worktree_path"

    # Pull changes from Jules session
    if ! npx -y @google/jules@latest remote pull --session "$session_id" --apply 2>/dev/null; then
        echo "FAILED: Could not apply Jules changes (session may have failed or have conflicts)" > "$result_file"
        builtin cd "$REPO_ROOT"
        return 1
    fi

    # Check if there are any changes to commit
    if [ -z "$(git -C "$worktree_path" status --porcelain)" ]; then
        echo "FAILED: No changes from Jules session" > "$result_file"
        builtin cd "$REPO_ROOT"
        return 1
    fi

    # Commit the changes
    git -C "$worktree_path" add -A
    git -C "$worktree_path" commit -m "Jules implementation from session $session_id" 2>/dev/null

    builtin cd "$REPO_ROOT"
    echo "SUCCESS: Worktree ready with Jules changes" > "$result_file"
    return 0
}

# Launch parallel worktree setup
echo "Creating worktrees for $SESSION_COUNT sessions in parallel..."
echo ""

for ((i=0; i<SESSION_COUNT; i++)); do
    session_id="${SESSION_IDS[$i]}"
    result_file="$TEMP_DIR/result_$i"

    # Run setup in background
    setup_worktree "$session_id" "$result_file" &
    PIDS+=($!)
done

# Wait for all processes and collect results
success_count=0
failed_count=0

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-24s %-50s\n" "Session ID" "Result"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for ((i=0; i<SESSION_COUNT; i++)); do
    wait "${PIDS[$i]}" 2>/dev/null || true

    session_id="${SESSION_IDS[$i]}"
    result_file="$TEMP_DIR/result_$i"

    if [ -f "$result_file" ]; then
        result=$(cat "$result_file")
    else
        result="FAILED: No result file"
    fi

    if [[ "$result" == SUCCESS* ]]; then
        success_count=$((success_count + 1))
        status_icon="✓"
    else
        failed_count=$((failed_count + 1))
        status_icon="✗"
    fi

    printf "%-24s %s %s\n" "$session_id" "$status_icon" "$result"
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Cleanup temp files
rm -rf "$TEMP_DIR"

# Print summary
echo "Summary: $success_count succeeded, $failed_count failed out of $SESSION_COUNT total"
echo ""

if [ $success_count -gt 0 ]; then
    echo "Worktrees created:"
    git worktree list | grep "crown-jules/$RUN_ID" || true
    echo ""
    echo "Run compare-sessions.sh $RUN_ID to analyze the implementations."
fi

# Exit with error if all failed
if [ $success_count -eq 0 ]; then
    exit 1
fi

exit 0
