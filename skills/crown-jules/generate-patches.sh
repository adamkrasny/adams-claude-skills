#!/bin/bash
# Crown Jules - Patch Generation Script
# Usage: ./generate-patches.sh <run_id> <base_branch> <session_id1> <session_id2> ...
# Creates a single worktree, applies each session's changes, generates patch files, then cleans up
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
WORKTREE_BRANCH="crown-jules/$RUN_ID"
WORKTREE_PATH="$CROWN_JULES_DIR/worktree"

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

# Create output directory
mkdir -p "$CROWN_JULES_DIR"
echo "Run ID: $RUN_ID"
echo "Generating patches for $SESSION_COUNT sessions..."
echo ""

# Cleanup function to ensure worktree is removed
cleanup_worktree() {
    if [ -d "$WORKTREE_PATH" ]; then
        git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || rm -rf "$WORKTREE_PATH"
        git worktree prune 2>/dev/null || true
    fi
    if git rev-parse --verify "$WORKTREE_BRANCH" >/dev/null 2>&1; then
        git branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
    fi
}

# Set trap to cleanup on exit (success or failure)
trap cleanup_worktree EXIT

# Create single worktree from base branch
echo "Creating worktree on branch $WORKTREE_BRANCH..."
if ! git worktree add -b "$WORKTREE_BRANCH" "$WORKTREE_PATH" "$BASE_BRANCH" 2>/dev/null; then
    # Branch might exist from a previous failed run, try to clean it up
    git branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
    if ! git worktree add -b "$WORKTREE_BRANCH" "$WORKTREE_PATH" "$BASE_BRANCH" 2>/dev/null; then
        echo "ERROR: Could not create worktree"
        exit 1
    fi
fi
echo ""

# Track results
success_count=0
failed_count=0

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-24s %-50s\n" "Session ID" "Result"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Process each session sequentially
for session_id in "${SESSION_IDS[@]}"; do
    patch_file="$CROWN_JULES_DIR/$session_id.patch"
    result=""

    # Use 'builtin cd' to bypass shell hooks like zoxide
    builtin cd "$WORKTREE_PATH"

    # Apply Jules changes
    if ! npx -y @google/jules@latest remote pull --session "$session_id" --apply 2>/dev/null; then
        result="FAILED: Could not apply Jules changes"
        printf "%-24s ✗ %s\n" "$session_id" "$result"
        failed_count=$((failed_count + 1))
        # Reset for next session
        git checkout . 2>/dev/null
        git clean -fd 2>/dev/null
        builtin cd "$REPO_ROOT"
        continue
    fi

    # Check if there are any changes
    if [ -z "$(git -C "$WORKTREE_PATH" status --porcelain)" ]; then
        result="FAILED: No changes from Jules session"
        printf "%-24s ✗ %s\n" "$session_id" "$result"
        failed_count=$((failed_count + 1))
        builtin cd "$REPO_ROOT"
        continue
    fi

    # Stage all changes for diff
    git -C "$WORKTREE_PATH" add -A

    # Generate patch file (diff against base branch)
    git -C "$WORKTREE_PATH" diff --cached > "$patch_file"

    # Get patch stats for output
    lines_added=$(git -C "$WORKTREE_PATH" diff --cached --numstat | awk '{sum += $1} END {print sum+0}')
    lines_removed=$(git -C "$WORKTREE_PATH" diff --cached --numstat | awk '{sum += $2} END {print sum+0}')
    files_changed=$(git -C "$WORKTREE_PATH" diff --cached --numstat | wc -l | tr -d ' ')

    result="SUCCESS: +$lines_added/-$lines_removed lines, $files_changed files"
    printf "%-24s ✓ %s\n" "$session_id" "$result"
    success_count=$((success_count + 1))

    # Reset worktree for next session
    git -C "$WORKTREE_PATH" reset --hard HEAD 2>/dev/null
    git -C "$WORKTREE_PATH" clean -fd 2>/dev/null

    builtin cd "$REPO_ROOT"
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

# Cleanup happens via trap on EXIT

# Exit with error if all failed
if [ $success_count -eq 0 ]; then
    exit 1
fi

exit 0
