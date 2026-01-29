#!/bin/bash
# Crown Jules - Session Comparison Script
# Usage: ./compare-sessions.sh <run_id> [base_branch]
# Analyzes patch files and generates comparison report with metrics and scoring
# Compatible with bash 3.2+ (macOS default)

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <run_id> [base_branch]"
    echo "Example: $0 abc123 main"
    exit 1
fi

RUN_ID="$1"
BASE_BRANCH="${2:-main}"

# Get repository root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    exit 1
fi

# All Crown Jules files live under .crown-jules/<run_id>/
CROWN_JULES_DIR="$REPO_ROOT/.crown-jules/$RUN_ID"
REPORT_JSON="$CROWN_JULES_DIR/report.json"
REPORT_MD="$CROWN_JULES_DIR/report.md"

# Check if directory exists
if [ ! -d "$CROWN_JULES_DIR" ]; then
    echo "ERROR: No Crown Jules directory found at $CROWN_JULES_DIR"
    echo "Run generate-patches.sh $RUN_ID first."
    exit 1
fi

# Find all patch files
PATCH_FILES=($(find "$CROWN_JULES_DIR" -maxdepth 1 -type f -name "*.patch" 2>/dev/null | sort))
SESSION_COUNT=${#PATCH_FILES[@]}

if [ $SESSION_COUNT -eq 0 ]; then
    echo "ERROR: No patch files found in $CROWN_JULES_DIR"
    exit 1
fi

echo "Crown Jules - Comparing $SESSION_COUNT implementations"
echo "Run ID: $RUN_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Helper to ensure clean integer values from grep -c
clean_count() {
    local val
    val=$(cat 2>/dev/null | head -1 | tr -cd '0-9')
    echo "${val:-0}"
}

# Function to analyze a patch file
analyze_patch() {
    local patch_file="$1"
    local session_id=$(basename "$patch_file" .patch)

    # Count patterns directly from file (more reliable than loading into variable)
    local files_changed=$(grep -c "^diff --git" "$patch_file" 2>/dev/null | clean_count)
    local hunks=$(grep -c "^@@" "$patch_file" 2>/dev/null | clean_count)
    local lines_added=$(grep -c "^+[^+]" "$patch_file" 2>/dev/null | clean_count)
    local lines_removed=$(grep -c "^-[^-]" "$patch_file" 2>/dev/null | clean_count)
    local new_files=$(grep -c "^--- /dev/null" "$patch_file" 2>/dev/null | clean_count)
    local deleted_files=$(grep -c "^+++ /dev/null" "$patch_file" 2>/dev/null | clean_count)

    # Modified files = total - new - deleted
    local modified_files=$((files_changed - new_files - deleted_files))
    [ $modified_files -lt 0 ] && modified_files=0

    # Create temp file for added lines (more reliable than variables for large patches)
    local added_lines_file=$(mktemp)
    grep "^+" "$patch_file" 2>/dev/null | grep -v "^+++" > "$added_lines_file" || true

    # Test files detection (look for test/spec patterns in file names in diff headers)
    local test_files=$(grep "^diff --git" "$patch_file" 2>/dev/null | grep -cE '\.(test|spec)\.(js|ts|jsx|tsx|py|rb)|_test\.(go|py)|Test\.java' | clean_count)

    # Type definitions in added lines
    local type_defs=$(grep -cE '(interface |type |: [A-Z][a-zA-Z]+)' "$added_lines_file" 2>/dev/null | clean_count)

    # Config file changes
    local config_changes=$(grep "^diff --git" "$patch_file" 2>/dev/null | grep -cE '\.(json|yaml|yml|toml|ini|env)$|config' | clean_count)

    # Comments added
    local comments_added=$(grep -cE '(/\*|\*/|//|#.*[a-zA-Z])' "$added_lines_file" 2>/dev/null | clean_count)

    # Error handling patterns
    local error_handling=$(grep -cE '(try|catch|throw|Error|Exception|raise|rescue|if err|\.catch\(|\.error\()' "$added_lines_file" 2>/dev/null | clean_count)

    # Complexity estimation - decision points in added lines
    local decision_points=$(grep -cE '(if |else |for |while |switch |case |&&|\|\||try |catch )' "$added_lines_file" 2>/dev/null | clean_count)

    # Estimate nesting depth
    local max_indent=$(sed 's/^+//' "$added_lines_file" 2>/dev/null | awk '{
        match($0, /^[ \t]*/);
        indent = RLENGTH;
        if (indent > max) max = indent;
    } END {print int(max/2)}' | clean_count)

    # Function/method count
    local func_count=$(grep -cE '(function |def |func |fn |=> \{|->|public |private |protected ).*[\(\{]' "$added_lines_file" 2>/dev/null | clean_count)

    # Cleanup temp file
    rm -f "$added_lines_file"

    # Total lines changed (informational only - not used for scoring)
    local total_lines=$((lines_added + lines_removed))

    # Output JSON for this session
    cat << EOF
{
    "session_id": "$session_id",
    "patch_file": "$patch_file",
    "url": "https://jules.google.com/session/$session_id",
    "metrics": {
        "change": {
            "lines_added": $lines_added,
            "lines_removed": $lines_removed,
            "files_changed": $files_changed,
            "hunks": $hunks,
            "new_files": $new_files,
            "modified_files": $modified_files,
            "deleted_files": $deleted_files
        },
        "complexity": {
            "decision_points": $decision_points,
            "max_nesting_depth": $max_indent,
            "function_count": $func_count
        },
        "patterns": {
            "test_files": $test_files,
            "type_definitions": $type_defs,
            "config_changes": $config_changes,
            "comments_added": $comments_added,
            "error_handling": $error_handling
        }
    }
}
EOF
}

# Collect all session data
TEMP_DIR=$(mktemp -d)
SESSION_DATA=()

for ((i=0; i<SESSION_COUNT; i++)); do
    patch_file="${PATCH_FILES[$i]}"
    session_id=$(basename "$patch_file" .patch)

    echo "Analyzing session $session_id..."

    result_file="$TEMP_DIR/session_$i.json"
    analyze_patch "$patch_file" > "$result_file"
    SESSION_DATA+=("$result_file")
done

echo ""
echo "Generating reports..."

# Build complete JSON report
{
    echo '{'
    echo '  "generated_at": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'",'
    echo '  "run_id": "'$RUN_ID'",'
    echo '  "base_branch": "'$BASE_BRANCH'",'
    echo '  "session_count": '$SESSION_COUNT','
    echo '  "sessions": ['

    for ((i=0; i<SESSION_COUNT; i++)); do
        if [ $i -gt 0 ]; then echo '    ,'; fi
        # Indent the session JSON (with guard for missing files)
        if [ -f "${SESSION_DATA[$i]}" ]; then
            sed 's/^/    /' "${SESSION_DATA[$i]}"
        else
            echo '    {"error": "Session data file not found"}'
        fi
    done

    echo '  ]'
    echo '}'
} > "$REPORT_JSON"

# Build session list for markdown report
declare -a SESSION_LIST
for ((i=0; i<SESSION_COUNT; i++)); do
    session_id=$(basename "${PATCH_FILES[$i]}" .patch)
    SESSION_LIST+=("$session_id")
done

# Generate Markdown report
{
    echo "# Crown Jules Metrics Report"
    echo ""
    echo "**Run ID:** \`$RUN_ID\`"
    echo "**Generated:** $(date)"
    echo "**Base branch:** \`$BASE_BRANCH\`"
    echo ""

    echo "## Summary"
    echo ""
    echo "| Session ID | Lines +/- | Files | Tests | Error Handling |"
    echo "|------------|-----------|-------|-------|----------------|"

    for session_id in "${SESSION_LIST[@]}"; do
        for data_file in "${SESSION_DATA[@]}"; do
            if grep -q "\"session_id\": \"$session_id\"" "$data_file"; then
                lines_added=$(grep '"lines_added":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                lines_removed=$(grep '"lines_removed":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                files=$(grep '"files_changed":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                tests=$(grep '"test_files":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                error_handling=$(grep '"error_handling":' "$data_file" | tail -1 | sed 's/.*: *\([0-9]*\).*/\1/')

                echo "| [$session_id](https://jules.google.com/session/$session_id) | +$lines_added/-$lines_removed | $files | $tests | $error_handling |"
                break
            fi
        done
    done

    echo ""
    echo "## Session Details"
    echo ""

    for session_id in "${SESSION_LIST[@]}"; do
        for data_file in "${SESSION_DATA[@]}"; do
            if grep -q "\"session_id\": \"$session_id\"" "$data_file"; then
                echo "### Session $session_id"
                echo ""
                echo "**Patch file:** \`$CROWN_JULES_DIR/$session_id.patch\`"
                echo "**Jules URL:** https://jules.google.com/session/$session_id"
                echo ""

                # Extract change metrics
                lines_added=$(grep '"lines_added":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                lines_removed=$(grep '"lines_removed":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                files=$(grep '"files_changed":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                new_files=$(grep '"new_files":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                modified=$(grep '"modified_files":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                deleted=$(grep '"deleted_files":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')

                # Extract complexity metrics
                decision_points=$(grep '"decision_points":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                func_count=$(grep '"function_count":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')

                # Extract pattern metrics
                tests=$(grep '"test_files":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                comments=$(grep '"comments_added":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                error_handling=$(grep '"error_handling":' "$data_file" | tail -1 | sed 's/.*: *\([0-9]*\).*/\1/')

                echo "**Changes:**"
                echo "- Lines: +$lines_added / -$lines_removed"
                echo "- Files: $files total ($new_files new, $modified modified, $deleted deleted)"
                echo ""
                echo "**Complexity:** $decision_points decision points, $func_count functions"
                echo ""
                echo "**Patterns:** $tests test files, $comments comments, $error_handling error handling instances"
                echo ""
                break
            fi
        done
    done

    echo "---"
    echo ""
    echo "*Note: This report provides metrics only. Claude will evaluate and rank implementations based on correctness and adherence to the original request.*"

} > "$REPORT_MD"

# Cleanup temp files
rm -rf "$TEMP_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Metrics collected!"
echo ""
echo "Reports generated:"
echo "  JSON: $REPORT_JSON"
echo "  Markdown: $REPORT_MD"
echo ""
echo "Sessions analyzed:"
for session_id in "${SESSION_LIST[@]}"; do
    echo "  - $session_id"
done
echo ""
echo "Note: Claude will evaluate and rank implementations based on correctness."
