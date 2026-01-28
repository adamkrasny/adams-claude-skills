#!/bin/bash
# Crown Jules - Cleanup Script
# Usage: ./cleanup.sh <run_id>
# Removes the .crown-jules/<run_id>/ directory containing patch files and reports
# Compatible with bash 3.2+ (macOS default)

if [ $# -lt 1 ]; then
    echo "Usage: $0 <run_id>"
    echo "Example: $0 abc123"
    exit 1
fi

RUN_ID="$1"

# Get repository root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    exit 1
fi

# All Crown Jules files live under .crown-jules/<run_id>/
CROWN_JULES_DIR="$REPO_ROOT/.crown-jules/$RUN_ID"

echo "Crown Jules - Cleanup"
echo "Run ID: $RUN_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Track what we cleaned up
patches_removed=0
reports_removed=0

if [ -d "$CROWN_JULES_DIR" ]; then
    # Count files before removal
    patches_removed=$(find "$CROWN_JULES_DIR" -maxdepth 1 -type f -name "*.patch" 2>/dev/null | wc -l | tr -d ' ')

    if [ -f "$CROWN_JULES_DIR/report.json" ]; then
        reports_removed=$((reports_removed + 1))
    fi
    if [ -f "$CROWN_JULES_DIR/report.md" ]; then
        reports_removed=$((reports_removed + 1))
    fi

    # List what will be removed
    echo "Removing:"
    for patch in "$CROWN_JULES_DIR"/*.patch; do
        [ -f "$patch" ] && echo "  - $(basename "$patch")"
    done
    [ -f "$CROWN_JULES_DIR/report.json" ] && echo "  - report.json"
    [ -f "$CROWN_JULES_DIR/report.md" ] && echo "  - report.md"
    echo ""

    # Remove the entire run directory
    rm -rf "$CROWN_JULES_DIR" && echo "Removed $CROWN_JULES_DIR"

    # Clean up parent .crown-jules dir if empty
    rmdir "$REPO_ROOT/.crown-jules" 2>/dev/null && echo "Removed empty .crown-jules directory"
else
    echo "No Crown Jules directory found at $CROWN_JULES_DIR"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cleanup complete!"
echo ""
echo "Summary:"
echo "  Patch files removed: $patches_removed"
echo "  Report files removed: $reports_removed"
