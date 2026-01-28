#!/bin/bash
# Crown Jules - Session Comparison Script
# Usage: ./compare-sessions.sh <run_id> [base_branch]
# Analyzes all worktrees and generates comparison report with metrics and scoring
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
WORKTREE_DIR="$CROWN_JULES_DIR/worktrees"
REPORT_JSON="$CROWN_JULES_DIR/report.json"
REPORT_MD="$CROWN_JULES_DIR/report.md"

# Check if worktree directory exists
if [ ! -d "$WORKTREE_DIR" ]; then
    echo "ERROR: No worktrees found at $WORKTREE_DIR"
    echo "Run setup-worktrees.sh $RUN_ID first."
    exit 1
fi

# Find all session worktrees
SESSION_DIRS=($(find "$WORKTREE_DIR" -maxdepth 1 -type d -name "session-*" 2>/dev/null | sort))
SESSION_COUNT=${#SESSION_DIRS[@]}

if [ $SESSION_COUNT -eq 0 ]; then
    echo "ERROR: No session worktrees found in $WORKTREE_DIR"
    exit 1
fi

echo "Crown Jules - Comparing $SESSION_COUNT implementations"
echo "Run ID: $RUN_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Initialize JSON report
echo '{"sessions": [], "generated_at": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'", "base_branch": "'$BASE_BRANCH'", "run_id": "'$RUN_ID'"}' > "$REPORT_JSON"

# Function to count pattern occurrences in diff
count_pattern() {
    local diff="$1"
    local pattern="$2"
    echo "$diff" | grep -c "$pattern" 2>/dev/null || echo "0"
}

# Function to analyze a single session
analyze_session() {
    local worktree_path="$1"
    local session_id=$(basename "$worktree_path" | sed 's/session-//')

    # Use git -C instead of cd to avoid issues with shell hooks (e.g., zoxide)
    # Get diff against base branch
    local diff_stat=$(git -C "$worktree_path" diff "$BASE_BRANCH" --stat 2>/dev/null || echo "")
    local diff_full=$(git -C "$worktree_path" diff "$BASE_BRANCH" 2>/dev/null || echo "")
    local diff_numstat=$(git -C "$worktree_path" diff "$BASE_BRANCH" --numstat 2>/dev/null || echo "")

    # Change metrics
    local lines_added=$(echo "$diff_numstat" | awk '{sum += $1} END {print sum+0}')
    local lines_removed=$(echo "$diff_numstat" | awk '{sum += $2} END {print sum+0}')
    local files_changed=$(echo "$diff_numstat" | wc -l | tr -d ' ')
    local hunks=$(echo "$diff_full" | grep -c "^@@" 2>/dev/null || echo "0")

    # File type analysis
    local new_files=$(git -C "$worktree_path" diff "$BASE_BRANCH" --diff-filter=A --name-only 2>/dev/null | wc -l | tr -d ' ')
    local modified_files=$(git -C "$worktree_path" diff "$BASE_BRANCH" --diff-filter=M --name-only 2>/dev/null | wc -l | tr -d ' ')
    local deleted_files=$(git -C "$worktree_path" diff "$BASE_BRANCH" --diff-filter=D --name-only 2>/dev/null | wc -l | tr -d ' ')

    # Pattern detection
    local test_files=$(git -C "$worktree_path" diff "$BASE_BRANCH" --name-only 2>/dev/null | grep -cE '\.(test|spec)\.(js|ts|jsx|tsx|py|rb)$|_test\.(go|py)$|Test\.java$' 2>/dev/null || echo "0")
    local type_defs=$(echo "$diff_full" | grep -cE '^\+.*(interface |type |: [A-Z][a-zA-Z]+)' 2>/dev/null || echo "0")
    local config_changes=$(git -C "$worktree_path" diff "$BASE_BRANCH" --name-only 2>/dev/null | grep -cE '\.(json|yaml|yml|toml|ini|env)$|config' 2>/dev/null || echo "0")
    local comments_added=$(echo "$diff_full" | grep -cE '^\+.*(/\*|\*/|//|#.*[a-zA-Z])' 2>/dev/null || echo "0")
    local error_handling=$(echo "$diff_full" | grep -cE '^\+.*(try|catch|throw|Error|Exception|raise|rescue|if err|\.catch\(|\.error\()' 2>/dev/null || echo "0")

    # Complexity estimation (simplified - count decision points in added lines)
    local decision_points=$(echo "$diff_full" | grep -cE '^\+.*(if |else |for |while |switch |case |&&|\|\||try |catch )' 2>/dev/null || echo "0")

    # Estimate nesting depth (count leading whitespace patterns in added lines)
    local max_indent=$(echo "$diff_full" | grep '^+' | sed 's/^+//' | awk '{
        match($0, /^[ \t]*/);
        indent = RLENGTH;
        if (indent > max) max = indent;
    } END {print int(max/2)}' 2>/dev/null || echo "0")

    # Function/method count (approximate)
    local func_count=$(echo "$diff_full" | grep -cE '^\+.*(function |def |func |fn |=> \{|->|public |private |protected ).*[\(\{]' 2>/dev/null || echo "0")

    # Calculate scores (0-100 scale)
    local size_score=50
    local total_lines=$((lines_added + lines_removed))
    if [ $total_lines -lt 20 ]; then
        size_score=$((total_lines * 2))  # Penalize too small
    elif [ $total_lines -gt 1000 ]; then
        size_score=$((100 - (total_lines - 1000) / 50))  # Penalize too large
        [ $size_score -lt 0 ] && size_score=0
    else
        size_score=$((50 + (total_lines - 20) * 50 / 980))  # Scale 20-1000 to 50-100
    fi

    local complexity_score=50
    if [ $decision_points -gt 0 ] && [ $decision_points -le 50 ]; then
        complexity_score=$((50 + decision_points))
    elif [ $decision_points -gt 50 ]; then
        complexity_score=$((100 - (decision_points - 50)))
        [ $complexity_score -lt 20 ] && complexity_score=20
    fi

    local testing_score=0
    [ $test_files -gt 0 ] && testing_score=$((50 + test_files * 10))
    [ $testing_score -gt 100 ] && testing_score=100

    local documentation_score=0
    [ $comments_added -gt 0 ] && documentation_score=$((comments_added * 5))
    [ $documentation_score -gt 100 ] && documentation_score=100

    local error_score=0
    [ $error_handling -gt 0 ] && error_score=$((error_handling * 10))
    [ $error_score -gt 100 ] && error_score=100

    # Overall score (weighted average)
    local overall_score=$(( (size_score * 25 + complexity_score * 20 + testing_score * 25 + documentation_score * 15 + error_score * 15) / 100 ))

    # Output JSON for this session
    cat << EOF
{
    "session_id": "$session_id",
    "worktree_path": "$worktree_path",
    "branch": "crown-jules/$RUN_ID/$session_id",
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
    },
    "scores": {
        "size": $size_score,
        "complexity": $complexity_score,
        "testing": $testing_score,
        "documentation": $documentation_score,
        "error_handling": $error_score,
        "overall": $overall_score
    }
}
EOF
}

# Collect all session data
TEMP_DIR=$(mktemp -d)
SESSION_DATA=()

for ((i=0; i<SESSION_COUNT; i++)); do
    worktree="${SESSION_DIRS[$i]}"
    session_id=$(basename "$worktree" | sed 's/session-//')

    echo "Analyzing session $session_id..."

    result_file="$TEMP_DIR/session_$i.json"
    analyze_session "$worktree" > "$result_file"
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
        # Indent the session JSON
        sed 's/^/    /' "${SESSION_DATA[$i]}"
    done

    echo '  ],'

    # Add rankings (sorted by overall score)
    echo '  "rankings": ['

    # Create ranking data
    declare -a RANKINGS
    for ((i=0; i<SESSION_COUNT; i++)); do
        session_id=$(basename "${SESSION_DIRS[$i]}" | sed 's/session-//')
        # Extract overall score using grep/sed (jq-free)
        overall=$(grep '"overall":' "${SESSION_DATA[$i]}" | sed 's/.*: *\([0-9]*\).*/\1/')
        RANKINGS+=("$overall:$session_id")
    done

    # Sort rankings (descending by score)
    IFS=$'\n' SORTED_RANKINGS=($(printf '%s\n' "${RANKINGS[@]}" | sort -t: -k1 -rn))
    unset IFS

    for ((i=0; i<${#SORTED_RANKINGS[@]}; i++)); do
        score=$(echo "${SORTED_RANKINGS[$i]}" | cut -d: -f1)
        session_id=$(echo "${SORTED_RANKINGS[$i]}" | cut -d: -f2)
        rank=$((i + 1))

        if [ $i -gt 0 ]; then echo '    ,'; fi
        echo '    {"rank": '$rank', "session_id": "'$session_id'", "overall_score": '$score'}'
    done

    echo '  ]'
    echo '}'
} > "$REPORT_JSON"

# Generate Markdown report
{
    echo "# Crown Jules Comparison Report"
    echo ""
    echo "**Run ID:** \`$RUN_ID\`"
    echo "**Generated:** $(date)"
    echo "**Base branch:** \`$BASE_BRANCH\`"
    echo ""

    echo "## Rankings"
    echo ""
    echo "| Rank | Session ID | Overall Score | Lines +/- | Files | Tests |"
    echo "|------|------------|---------------|-----------|-------|-------|"

    for ((i=0; i<${#SORTED_RANKINGS[@]}; i++)); do
        score=$(echo "${SORTED_RANKINGS[$i]}" | cut -d: -f1)
        session_id=$(echo "${SORTED_RANKINGS[$i]}" | cut -d: -f2)
        rank=$((i + 1))

        # Find the data file for this session
        for data_file in "${SESSION_DATA[@]}"; do
            if grep -q "\"session_id\": \"$session_id\"" "$data_file"; then
                lines_added=$(grep '"lines_added":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                lines_removed=$(grep '"lines_removed":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                files=$(grep '"files_changed":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                tests=$(grep '"test_files":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')

                medal=""
                [ $rank -eq 1 ] && medal="🥇 "
                [ $rank -eq 2 ] && medal="🥈 "
                [ $rank -eq 3 ] && medal="🥉 "

                echo "| ${medal}${rank} | [$session_id](https://jules.google.com/session/$session_id) | **$score** | +$lines_added/-$lines_removed | $files | $tests |"
                break
            fi
        done
    done

    echo ""
    echo "## Detailed Analysis"
    echo ""

    for ((i=0; i<${#SORTED_RANKINGS[@]}; i++)); do
        session_id=$(echo "${SORTED_RANKINGS[$i]}" | cut -d: -f2)
        rank=$((i + 1))

        for data_file in "${SESSION_DATA[@]}"; do
            if grep -q "\"session_id\": \"$session_id\"" "$data_file"; then
                echo "### Rank #$rank: Session $session_id"
                echo ""
                echo "**Branch:** \`crown-jules/$RUN_ID/$session_id\`"
                echo "**Worktree:** \`$WORKTREE_DIR/session-$session_id\`"
                echo "**Jules URL:** https://jules.google.com/session/$session_id"
                echo ""

                # Extract and display scores
                size_score=$(grep '"size":' "$data_file" | head -1 | sed 's/.*: *\([0-9]*\).*/\1/')
                complexity_score=$(grep '"complexity":' "$data_file" | head -1 | sed 's/.*: *\([0-9]*\).*/\1/')
                testing_score=$(grep '"testing":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                doc_score=$(grep '"documentation":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                error_score=$(grep '"error_handling":' "$data_file" | tail -1 | sed 's/.*: *\([0-9]*\).*/\1/')
                overall=$(grep '"overall":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')

                echo "| Metric | Score |"
                echo "|--------|-------|"
                echo "| Size (25%) | $size_score |"
                echo "| Complexity (20%) | $complexity_score |"
                echo "| Testing (25%) | $testing_score |"
                echo "| Documentation (15%) | $doc_score |"
                echo "| Error Handling (15%) | $error_score |"
                echo "| **Overall** | **$overall** |"
                echo ""

                # Extract change metrics
                lines_added=$(grep '"lines_added":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                lines_removed=$(grep '"lines_removed":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                files=$(grep '"files_changed":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                new_files=$(grep '"new_files":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                modified=$(grep '"modified_files":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')
                deleted=$(grep '"deleted_files":' "$data_file" | sed 's/.*: *\([0-9]*\).*/\1/')

                echo "**Change Summary:**"
                echo "- Lines: +$lines_added / -$lines_removed"
                echo "- Files: $files total ($new_files new, $modified modified, $deleted deleted)"
                echo ""
                break
            fi
        done
    done

    echo "## Recommended Implementation"
    echo ""

    if [ ${#SORTED_RANKINGS[@]} -gt 0 ]; then
        top_session=$(echo "${SORTED_RANKINGS[0]}" | cut -d: -f2)
        top_score=$(echo "${SORTED_RANKINGS[0]}" | cut -d: -f1)

        echo "**Session $top_session** with an overall score of **$top_score** is recommended."
        echo ""
        echo "To review locally:"
        echo "\`\`\`bash"
        echo "cd $WORKTREE_DIR/session-$top_session"
        echo "# or"
        echo "git checkout crown-jules/$RUN_ID/$top_session"
        echo "\`\`\`"
        echo ""
        echo "To create a PR from Jules:"
        echo "https://jules.google.com/session/$top_session"
    fi

    echo ""
    echo "---"
    echo ""
    echo "Generated by Crown Jules comparison script"

} > "$REPORT_MD"

# Cleanup temp files
rm -rf "$TEMP_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Analysis complete!"
echo ""
echo "Reports generated:"
echo "  JSON: $REPORT_JSON"
echo "  Markdown: $REPORT_MD"
echo ""

# Print quick summary
echo "Quick Rankings:"
for ((i=0; i<${#SORTED_RANKINGS[@]}; i++)); do
    score=$(echo "${SORTED_RANKINGS[$i]}" | cut -d: -f1)
    session_id=$(echo "${SORTED_RANKINGS[$i]}" | cut -d: -f2)
    rank=$((i + 1))

    medal=""
    [ $rank -eq 1 ] && medal="🥇"
    [ $rank -eq 2 ] && medal="🥈"
    [ $rank -eq 3 ] && medal="🥉"

    printf "%s #%d: Session %s (Score: %s)\n" "$medal" "$rank" "$session_id" "$score"
done
