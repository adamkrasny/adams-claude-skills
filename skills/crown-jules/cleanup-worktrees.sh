#!/bin/bash
# Crown Jules - Cleanup Script
# Usage: ./cleanup-worktrees.sh <run_id> [delete_branches]
# Removes worktrees and optionally deletes branches for a specific run
# Compatible with bash 3.2+ (macOS default)

if [ $# -lt 1 ]; then
    echo "Usage: $0 <run_id> [delete_branches]"
    echo "Example: $0 abc123 true"
    exit 1
fi

RUN_ID="$1"
DELETE_BRANCHES="${2:-false}"

# Get repository root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    exit 1
fi

# All Crown Jules files live under .crown-jules/<run_id>/
CROWN_JULES_DIR="$REPO_ROOT/.crown-jules/$RUN_ID"
WORKTREE_DIR="$CROWN_JULES_DIR/worktrees"

# Ensure we're on a branch that isn't being deleted
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" == crown-jules/$RUN_ID/* ]]; then
    echo "Currently on branch '$CURRENT_BRANCH'. Switching to main..."
    git checkout main 2>/dev/null || git checkout master 2>/dev/null || {
        echo "ERROR: Could not switch away from crown-jules branch"
        exit 1
    }
fi

echo "Crown Jules - Cleanup"
echo "Run ID: $RUN_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Track what we cleaned up
worktrees_removed=0
branches_removed=0

# Remove worktrees
if [ -d "$WORKTREE_DIR" ]; then
    echo "Removing worktrees..."

    # Find all session directories
    SESSION_DIRS=($(find "$WORKTREE_DIR" -maxdepth 1 -type d -name "session-*" 2>/dev/null))

    for worktree_path in "${SESSION_DIRS[@]}"; do
        session_id=$(basename "$worktree_path" | sed 's/session-//')

        # Remove the worktree using git
        if git worktree remove "$worktree_path" --force 2>/dev/null; then
            echo "  ✓ Removed worktree: session-$session_id"
            worktrees_removed=$((worktrees_removed + 1))
        else
            # Try manual removal if git worktree fails
            rm -rf "$worktree_path" 2>/dev/null && {
                echo "  ✓ Removed worktree (manual): session-$session_id"
                worktrees_removed=$((worktrees_removed + 1))
            } || {
                echo "  ✗ Failed to remove worktree: session-$session_id"
            }
        fi
    done

    # Prune worktree metadata
    git worktree prune 2>/dev/null

    echo ""
else
    echo "No worktree directory found at $WORKTREE_DIR"
    echo ""
fi

# Remove branches if requested
if [ "$DELETE_BRANCHES" = "true" ]; then
    echo "Removing crown-jules/$RUN_ID branches..."

    # Find all branches for this run
    BRANCHES=($(git branch --list "crown-jules/$RUN_ID/*" 2>/dev/null | sed 's/^[* ]*//' || true))

    for branch in "${BRANCHES[@]}"; do
        if [ -n "$branch" ]; then
            if git branch -D "$branch" 2>/dev/null; then
                echo "  ✓ Deleted branch: $branch"
                branches_removed=$((branches_removed + 1))
            else
                echo "  ✗ Failed to delete branch: $branch"
            fi
        fi
    done

    if [ ${#BRANCHES[@]} -eq 0 ]; then
        echo "  No crown-jules/$RUN_ID branches found"
    fi

    echo ""
fi

# Remove the run directory (contains reports, worktrees dir)
files_removed=0
if [ -d "$CROWN_JULES_DIR" ]; then
    # Count files before removal
    if [ -f "$CROWN_JULES_DIR/report.json" ]; then
        files_removed=$((files_removed + 1))
    fi
    if [ -f "$CROWN_JULES_DIR/report.md" ]; then
        files_removed=$((files_removed + 1))
    fi

    # Remove the entire run directory
    rm -rf "$CROWN_JULES_DIR" && echo "✓ Removed $CROWN_JULES_DIR"

    # Clean up parent .crown-jules dir if empty
    rmdir "$REPO_ROOT/.crown-jules" 2>/dev/null && echo "✓ Removed empty .crown-jules directory"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cleanup complete!"
echo ""
echo "Summary:"
echo "  Worktrees removed: $worktrees_removed"
if [ "$DELETE_BRANCHES" = "true" ]; then
    echo "  Branches deleted: $branches_removed"
else
    echo "  Branches: kept (run with 'true' to delete)"
fi
echo "  Report files removed: $files_removed"

# Show remaining branches if any
remaining_branches=$(git branch --list "crown-jules/$RUN_ID/*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$remaining_branches" -gt 0 ]; then
    echo ""
    echo "Remaining crown-jules/$RUN_ID branches:"
    git branch --list "crown-jules/$RUN_ID/*" | sed 's/^/  /'
fi
