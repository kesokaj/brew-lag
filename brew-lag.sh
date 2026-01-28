#!/usr/bin/env bash

# Configuration
OFFSET=4                # Versions behind latest
PARALLEL_JOBS=4         # Number of concurrent git queries
CONFIG_DIR="$HOME/.brew-lag"
EXCEPTIONS_FILE="$CONFIG_DIR/exceptions"
PLAN_FILE="$CONFIG_DIR/plan.txt"
CONFIG_FILE="$CONFIG_DIR/config"
CACHE_FILE="$CONFIG_DIR/cache.txt"
export CACHE_FILE

# Load Config
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $(basename "$0") [command] [options]"
    echo ""
    echo "Commands:"
    echo "  plan          (default) Analyze and generate a plan."
    echo "  apply         Execute the saved plan."
    echo "  install <pkg> Check or fix a single package."
    echo "  exclude <pkg> Add a package to the exception list (keep at latest)."
    echo "  include <pkg> Remove a package from exceptions (enforce lag)."
    echo "  list          List all excluded packages."
    echo "  cleanup       Remove local tap and cache directory."
    echo ""
    echo "Options:"
    echo "  --update      Run 'brew update' before scanning."
    echo "  --apply       Execute changes (for 'install' command)."
    echo "  --dry-run     Show what would be done without executing."
    echo "  -j, --jobs N  Number of parallel jobs (default: $PARALLEL_JOBS)."
    echo "  -h, --help    Show this help message."
}

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

init_config() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
    fi
    if [ ! -f "$EXCEPTIONS_FILE" ]; then
        touch "$EXCEPTIONS_FILE"
    fi
}

add_exception() {
    local pkg=$1
    if [ -z "$pkg" ]; then error "Package name required."; exit 1; fi
    init_config
    if grep -q "^$pkg$" "$EXCEPTIONS_FILE"; then
        log "$pkg is already excluded."
    else
        echo "$pkg" >> "$EXCEPTIONS_FILE"
        success "Excluded $pkg from lag rules."
    fi
    exit 0
}

remove_exception() {
    local pkg=$1
    if [ -z "$pkg" ]; then error "Package name required."; exit 1; fi
    init_config
    if grep -q "^$pkg$" "$EXCEPTIONS_FILE"; then
        # In-place delete compatible with BSD sed (macOS)
        sed -i '' "/^$pkg$/d" "$EXCEPTIONS_FILE"
        success "Included $pkg back into lag rules."
    else
        log "$pkg was not in the exception list."
    fi
    exit 0
}

list_exceptions() {
    init_config
    echo "Excluded packages (kept at latest):"
    if [ -s "$EXCEPTIONS_FILE" ]; then
        cat "$EXCEPTIONS_FILE"
    else
        echo "  (none)"
    fi
    exit 0
}

# Export logging logic for workers
export RED GREEN YELLOW BLUE NC
export -f log warn error success

# Helper: Get commit unix timestamp
get_commit_date() {
    local repo="$1"
    local hash="$2"
    git -C "$repo" show -s --format=%ct "$hash"
}

# Helper: Find newest commit before date
find_commit_by_date() {
    local repo="$1"
    local rel_path="$2"
    local timestamp="$3"
    # Get the newest commit for path where date <= timestamp
    git -C "$repo" log -n 1 --before="@$timestamp" --pretty=format:"%H" -- "$rel_path"
}

# Helper: Extract runtime dependencies from formula content
get_formula_deps() {
    local repo="$1"
    local hash="$2"
    local rel_path="$3"
    
    # Read file content at revision
    local content=$(git -C "$repo" show "$hash:$rel_path")
    
    # Simple regex to find depends_on "package"
    # Ignores :build, :test dependencies which are usually usually marked with =>
    # Matches: depends_on "openssl@3"
    # Matches: depends_on "openssl@3" => :optional (we might skip these?)
    # Let's match lines starting with 'depends_on' and string quotes
    # Grep is fast.
    echo "$content" | grep '^\s*depends_on\s*["'\'']' | while read -r line; do
        # Filter out :build and :test
        if [[ "$line" =~ :build ]] || [[ "$line" =~ :test ]]; then
             continue
        fi
        
        # Extract name
        # Remove "depends_on", whitespace, quotes
        local dep=$(echo "$line" | sed -E 's/^[[:space:]]*depends_on[[:space:]]+["'\'']([^"'\'']+)["'\'']/\1/')
        # Remove anything after the name (like " => ...")
        dep=${dep%% *}
        echo "$dep"
    done
}

export -f get_commit_date find_commit_by_date get_formula_deps

# Worker function to get metadata for a single formula
# Output format: "formula|current_ver|target_ver|target_hash|rel_path|target_ts"
get_formula_target() {
    local formula="$1"
    local current_ver="$2"
    local repo="$3"
    local idx="$4"
    local total="$5"
    local cache_file="$6"
    local repo_head="$7"

    # CACHE CHECK
    # Key: formula:current_ver:repo_head:OFFSET
    # We add V2 to invalidate old cache
    local cache_key="${formula}:${current_ver}:${repo_head}:${OFFSET}:V2"
    
    # Simple grep check (fast enough for small cache)
    # Format: KEY|TargetVer|TargetHash|RelPath
    if [ -f "$cache_file" ]; then
        local cached_line=$(grep "^${cache_key}|" "$cache_file" | head -n 1)
        if [ -n "$cached_line" ]; then
             IFS='|' read -r _ c_ver c_hash c_path c_ts <<< "$cached_line"
             # Progress (Cache Hit)
             echo -e "${GREEN}[CACHE] ($idx/$total)${NC} $formula" >&2
             echo "$formula|$current_ver|$c_ver|$c_hash|$c_path|$c_ts"
             return 0
        fi
    fi
    
    # Progress indicator to stderr (Real Scan)
    echo -e "${BLUE}[SCAN]  ($idx/$total)${NC} Checking $formula..." >&2
    
    # Standardize path finding logic
    local first_letter="${formula:0:1}"
    local rel_path="Formula/${first_letter}/${formula}.rb"
    
    # Check common paths
    if [ -f "$repo/$rel_path" ]; then
        : # Found at Formula/f/formula.rb
    elif [ -f "$repo/Formula/${formula}.rb" ]; then
        rel_path="Formula/${formula}.rb"
    elif [ -f "$repo/Formula/lib/${formula}.rb" ]; then
        rel_path="Formula/lib/${formula}.rb"
    fi
    
    # SINGLE PASS GIT LOG OPTIMIZATION
    # We get Hash, Subject, Date (Unix)
    local result=$(git -C "$repo" log -n 80 --pretty=format:"%H %ct %s" -- "$rel_path" | \
        awk -v f="$formula" -v offset="$OFFSET" '
            BEGIN { count=0; target_ver=""; target_hash=""; target_ts=""; last_ver=""; last_hash=""; last_ts=""; }
            {
                hash=$1
                ts=$2
                # Check line for formula name. Fields 3+ are the subject
                line_has_name=0
                for(i=3; i<=NF; i++) { 
                    val=$i; gsub(/^[:]+|[:]+$/, "", val); 
                    if (val == f) { line_has_name=1; break; } 
                }
                
                if (line_has_name) {
                    # Scan for version
                    for(i=3; i<=NF; i++) {
                        val=$i
                        # Version regex: starts with digit, contains dot OR hyphen (for date-based versions)
                        if (val ~ /^[0-9]+[\.-][0-9]+/) {
                             ver=val
                             gsub(/[,;:]$/, "", ver)
                             
                             if (!seen[ver]) {
                                 seen[ver]=1
                                 count++
                                 last_ver=ver
                                 last_hash=hash
                                 last_ts=ts
                                 
                                 if (count == offset + 1) {
                                     print ver "|" hash "|" ts
                                     exit
                                 }
                             }
                             break 
                        }
                    }
                }
            }
            END {
                # Fallback: If we didnt exit early but found at least one version, return the oldest one found
                if (last_ver != "") {
                    print last_ver "|" last_hash "|" last_ts
                }
            }
        ')
        
    IFS='|' read -r target_ver target_hash target_ts <<< "$result"
    
    if [ -z "$target_ts" ] && [ -n "$target_hash" ]; then
        # Fallback if awk didn't catch it for some reason? No, awk prints all 3. 
        target_ts=$(git -C "$repo" show -s --format=%ct "$target_hash")
    fi

    if [ -z "$target_hash" ]; then
         # Fallback slow log
         target_hash=$(git -C "$repo" log -n 1 --skip=$OFFSET --pretty=format:%H -- "$rel_path")
         target_ts=$(git -C "$repo" show -s --format=%ct "$target_hash")
         target_ver="commit:${target_hash:0:7}"
    fi
    
    # CACHE WRITE (Append safe)
    # We use a primitive lock or just accept race conditions (worst case: duplicate lines, handled by head -n 1)
    # Or just append.
    # CACHE WRITE (Append safe)
    echo "${cache_key}|${target_ver}|${target_hash}|${rel_path}|${target_ts}" >> "$cache_file"

    echo "$formula|$current_ver|$target_ver|$target_hash|$rel_path|$target_ts"
}
export -f get_formula_target
export OFFSET

EXPORT_TAP="brew-lag/local"

# Worker for dependency extraction logic
# Input: "formula|hash|path|ts"
# Output: Stream of "dep_name|required_ts"
extract_deps_worker() {
    local input="$1"
    IFS='|' read -r formula hash path ts <<< "$input"
    
    # Get dependencies
    local deps=$(get_formula_deps "$BREW_REPO" "$hash" "$path")
    
    # Emit requirements
    # If formula A (ts=100) depends on B, then B must be >= 100
    for dep in $deps; do
        echo "$dep|$ts"
    done
}
export -f extract_deps_worker

ensure_local_tap() {
    if ! brew tap | grep -q "^$EXPORT_TAP$"; then
        log "Creating local tap $EXPORT_TAP..."
        brew tap-new "$EXPORT_TAP" --no-git
    fi
    TAP_PATH=$(brew --repository "$EXPORT_TAP")
}

execute_plan() {
    init_config
    
    if [ ! -f "$PLAN_FILE" ]; then
        error "No plan found. Run 'brew-lag.sh plan' first."
        exit 1
    fi
    
    if [ ! -s "$PLAN_FILE" ]; then
        success "Plan is empty. Nothing to do."
        rm "$PLAN_FILE"
        exit 0
    fi
    
    BREW_REPO=$(brew --repository homebrew/core)
    ensure_local_tap
    
    local count=$(wc -l < "$PLAN_FILE" | tr -d ' ')
    
    log "Applying plan with $count actions..."
    
    while IFS='|' read -r formula hash path action <&3; do
        [ -z "$formula" ] && continue
        
        echo "🚀 $action: $formula..."
        
        # Write to local tap instead of tmp
        local tap_rb="$TAP_PATH/Formula/$formula.rb"
        git -C "$BREW_REPO" show "$hash:$path" > "$tap_rb"
        
        # Must uninstall to switch from homebrew/core to local tap
        # We ignore dependencies to avoid breaking the world, assuming ABI compatibility or rebuild needs
        brew uninstall --ignore-dependencies "$formula" < /dev/null &>/dev/null || true
        
        # Install from local tap
        # We use --ignore-dependencies to ensure we don't fail just because a dependency is pinned
        if out=$(brew install --ignore-dependencies --formula "$EXPORT_TAP/$formula" < /dev/null 2>&1); then
            brew pin "$formula" &>/dev/null
            echo "   ✅ Success."
        else
            echo "   ❌ Failed."
            echo "$out" | sed 's/^/      /' # Indent error output
            echo "   Restoring original version from Homebrew core..."
            # Re-install the latest version from core if our downgrade failed
            brew install "$formula" < /dev/null &>/dev/null
        fi
        rm -f "$tap_rb"
        
    done 3< "$PLAN_FILE"
    
    success "Plan execution complete."
    rm "$PLAN_FILE"
}

check_single_package() {
    local pkg=$1
    if [ -z "$pkg" ]; then error "Package name required."; exit 1; fi
    
    check_deps
    init_config
    BREW_REPO=$(brew --repository homebrew/core)
    
    # Check if installed
    local current_ver=$(brew info --json=v1 "$pkg" | jq -r '.[0].installed[-1].version')
    if [ -z "$current_ver" ] || [ "$current_ver" == "null" ]; then
        error "Package '$pkg' is not installed."
        exit 1
    fi
    
    log "Checking $pkg..."
    # NEW LOGIC: Consult resolved.txt first for Global Consistency
    local resolved_file="$CONFIG_DIR/resolved.txt"
    local found_in_plan=false
    local target_hash=""
    local target_path=""
    
    if [ -f "$resolved_file" ]; then
        # Search for formula line
        # Format: formula|curr|ver|hash|path|final_ts|moved
        local plan_line=$(grep "^$pkg|" "$resolved_file" | head -n 1)
        if [ -n "$plan_line" ]; then
            IFS='|' read -r _ _ target hash path _ moved <<< "$plan_line"
            found_in_plan=true
            target_hash="$hash"
            target_path="$path"
            
            # If it was moved by water level, we MUST use this target
            if [ "$moved" == "1" ]; then
                 log "Using globally resolved target (Water Level) for consistency."
            fi
            
            # RECURSION: Check dependencies first (if in plan)
            # Prevent infinite recursion with visited string passed as arg 2
            local visited="$2"
            if [[ "$visited" != *":$pkg:"* ]]; then
                 local new_visited="$visited:$pkg:"
                 log "Checking dependencies for $pkg..."
                 # Extract deps from this specific hash
                 local deps=$(get_formula_deps "$BREW_REPO" "$hash" "$path")
                 for dep in $deps; do
                     # Recurse
                     check_single_package "$dep" "$new_visited"
                 done
            fi
        fi
    fi
    
    if [ "$found_in_plan" = false ]; then
        warn "Package not found in global plan. Running isolated check (riskier for dependencies)..."
        local repo_head=$(git -C "$BREW_REPO" rev-parse HEAD)
        local result=$(get_formula_target "$pkg" "$current_ver" "$BREW_REPO" "1" "1" "$CACHE_FILE" "$repo_head")
        IFS='|' read -r formula current target hash path <<< "$result"
    fi
    
    # Format target string with commit hash if available
    
    # Format target string with commit hash if available
    local target_display="$target"
    if [ -n "$hash" ]; then
        target_display="$target (${hash:0:7})"
    fi
    
    echo ""
    echo "Current: $current"
    echo "Target:  $target_display (Lag: $OFFSET versions)"
    
    local action="OK"
    local color=""
    local do_change=false
    
    if [ -z "$target" ] || [ -z "$hash" ]; then
         action="ERR:NoHistory"
         color="$RED"
    elif [ "$current" == "$target" ]; then
         action="OK"
         color="$GREEN"
    else
         lower_ver=$(echo -e "$current\n$target" | sort -V | head -n1)
         if [ "$current" != "$target" ]; then
             if [ "$lower_ver" == "$target" ]; then
                 action="DOWNGRADE"
                 color="$RED"
             else
                 action="UPGRADE" 
                 color="$BLUE"
             fi
             do_change=true
         fi
    fi
    
    echo -e "Action:  ${color}${action}${NC}"
    
    if [ "$do_change" = true ]; then
        if [ "$DRY_RUN" = false ]; then
            echo "Applying change..."
            ensure_local_tap
            
            # Write to local tap instead of tmp
            local tap_rb="$TAP_PATH/Formula/$formula.rb"
            git -C "$BREW_REPO" show "$hash:$path" > "$tap_rb"
            
            # Must uninstall to switch tap
            brew uninstall --ignore-dependencies "$formula" < /dev/null &>/dev/null || true
            
            if out=$(brew install --ignore-dependencies --formula "$EXPORT_TAP/$formula" < /dev/null 2>&1); then
                brew pin "$formula" &>/dev/null
                success "Success."
            else
                error "Failed."
                echo "$out" | sed 's/^/   /'
                log "Restoring original..."
                brew install "$formula" < /dev/null &>/dev/null
            fi
            rm -f "$tap_rb"
        else
            warn "Dry-Run. Use --apply to execute."
        fi
    else
        success "Version is correct."
    fi
}

run_analysis() {
    check_deps
    init_config
    
    # Clear old plan
    rm -f "$PLAN_FILE" 2>/dev/null
    touch "$PLAN_FILE"
    
    BREW_REPO=$(brew --repository homebrew/core)
    export BREW_REPO
    
    # Optional Auto-Update
    if [ "$DO_UPDATE" = true ]; then
        log "Updating Homebrew..."
        brew update
    fi

    log "Scanning installed packages..."
    # Batch grab all installed versions
    local installed_json=$(brew info --json=v1 --installed)
    
    # Create a simplified list: formula|version
    local package_list=$(echo "$installed_json" | jq -r '.[] | "\(.name)|\(.installed[-1].version)"')
    local count=$(echo "$package_list" | wc -l | tr -d ' ')
    
    # Add index and total to each line for progress tracking logic: idx|total|name|ver
    local indexed_list=$(echo "$package_list" | awk -v total="$count" '{print NR "|" total "|" $0}')
    
    log "Found $count packages. Calculating targets (Lag: $OFFSET versions)..."
    log "Phase 1: Computing Lagged Targets (Parallel Jobs: $PARALLEL_JOBS)..."
    
    # Get current Homebrew repo HEAD for cache invalidation
    local repo_head=$(git -C "$BREW_REPO" rev-parse HEAD)

    # Phase 1 Output: formula|current_ver|target_ver|target_hash|rel_path|target_ts
    local targets_file="$CONFIG_DIR/targets_initial.txt"
    echo "$indexed_list" | \
        xargs -P "$PARALLEL_JOBS" -I {} nice -n 10 bash -c 'IFS="|" read -r idx total name ver <<< "{}"; get_formula_target "$name" "$ver" "$BREW_REPO" "$idx" "$total" "$CACHE_FILE" "$repo_head"' \
        > "$targets_file"

    log "Phase 2: Building Global Dependency Graph..."
    
    # Extract dependencies in parallel
    # Input needing: formula|hash|path|ts (cols 1, 4, 5, 6 from targets)
    local deps_constraints="$CONFIG_DIR/constraints.txt"
    cut -d'|' -f1,4,5,6 "$targets_file" | \
        xargs -P "$PARALLEL_JOBS" -I {} nice -n 10 bash -c 'extract_deps_worker "{}"' \
        > "$deps_constraints"
        
    log "Phase 3: Resolving Water Level Conflicts..."
    
    # We now have:
    # 1. targets_initial.txt: formula|curr|t_ver|t_hash|path|t_ts
    # 2. constraints.txt:     formula|required_ts
    
    # Use awk to merge and resolve max(ts)
    # Output: formula|curr|t_ver|t_hash|path|final_ts|action
    local resolved_file="$CONFIG_DIR/resolved.txt"
    
    # Load constraints first, then process targets
    awk -F'|' '
        BEGIN { OFS="|"; }
        # File 1: constraints.txt (formula|ts)
        NR==FNR { 
            if ($2 > reqs[$1]) { reqs[$1] = $2 }
            next
        }
        # File 2: targets_initial.txt
        {
            formula=$1
            curr=$2
            ver=$3
            hash=$4
            path=$5
            ts=$6
            
            # Resolve Timestamp
            final_ts = ts
            moved = 0
            if (reqs[formula] > final_ts) {
                final_ts = reqs[formula]
                moved = 1
            }
            
            print formula, curr, ver, hash, path, final_ts, moved
        }
    ' "$deps_constraints" "$targets_file" > "$resolved_file"

    # Load exceptions
    local exceptions_str=""
    if [ -f "$EXCEPTIONS_FILE" ]; then
        exceptions_str=" $(cat "$EXCEPTIONS_FILE" | tr '\n' ' ') "
    fi
    
    local changes_found=false
    
    echo ""
    echo -e "${YELLOW}=== Analysis Report ===${NC}"
    printf "%-30s %-20s %-30s %-10s\n" "Package" "Current" "Target (Lag/Sync)" "Action"
    printf "%-30s %-20s %-30s %-10s\n" "-------" "-------" "---------------" "------"
    
    # Final Pass: Execute Logic
    # We need to iterate and if "moved" is true, find the new hash
    while IFS='|' read -r formula current target_ver hash path ts moved; do
        [ -z "$formula" ] && continue
        
        action="OK"
        color="$GREEN"
        do_change=false
        
        # Check exception
        if [[ "$exceptions_str" == *" $formula "* ]]; then
            action="EXCEPTed"
            color="$YELLOW"
        else
            # Re-resolve hash if moved
            if [ "$moved" == "1" ]; then
                # Find new hash for the "water leveled" timestamp
                # Note: This is synchronous here, might be slow if many conflicts.
                # Assuming few conflicts, it is okay. To optimize we could batch this too.
                # But lets stick to simplicity for safely.
                hash=$(find_commit_by_date "$BREW_REPO" "$path" "$ts")
                
                # Extract real version from this commit to avoid false positives in comparison
                # We reuse the logic from get_formula_target but simplified for single file content
                content=$(git -C "$BREW_REPO" show "$hash:$path")
                # Try explicit version first
                extracted_ver=$(echo "$content" | grep -m 1 "version [\"']" | sed -E "s/.*version [\"']([^\"']+)[\"'].*/\1/")
                
                # Fallback: Extract from URL (common for many formulas)
                # pattern: url "https://.../foo-1.2.3.tar.gz" -> 1.2.3
                if [ -z "$extracted_ver" ]; then
                     # Look for url line, try to grab version-like string
                     # Regex: url ".*-(\d+\.\d+(\.\d+)*)\.tar
                     # Simplified: Find the url line, extract the last segment that looks like a version
                     extracted_ver=$(echo "$content" | grep -m 1 "url [\"']" | grep -oE '[0-9]+\.[0-9]+([_\.-][0-9a-zA-Z]+)*' | head -n 1)
                fi
                
                # Cleanup: Remove .tar.gz / .zip suffix if regex caught it
                extracted_ver=${extracted_ver%.tar.gz}
                extracted_ver=${extracted_ver%.zip}
                extracted_ver=${extracted_ver%.tar.xz}
                extracted_ver=${extracted_ver%.tar.bz2}
                extracted_ver=${extracted_ver%-stable}

                # Check for revision
                # pattern: revision 1
                revision_val=$(echo "$content" | grep -m 1 "revision [0-9]" | grep -oE '[0-9]+' | head -n 1)
                if [ -n "$revision_val" ] && [ "$revision_val" -gt 0 ]; then
                    extracted_ver="${extracted_ver}_${revision_val}"
                fi

                if [ -z "$extracted_ver" ]; then
                     # Fallback 2: Commit subject often has "foo 1.2.3"
                     # We can try to parse the subject from the log line we already have? No, we have the hash.
                     # Let's just use the synced date as last resort.
                     extracted_ver="synced:$(date -r "$ts" +%Y-%m-%d)"
                fi
                
                target_ver="$extracted_ver"
            fi
            
            if [ -z "$hash" ]; then
                action="ERR:Lost"
                color="$RED" 
            else
                 # Compare hashes to verify if change needed (Version comparisons are tricky with dates)
                 # We simply compare the computed target hash with installed receipt? 
                 # Current installed version doesn't tell us the hash easily. 
                 # Simplest heuristic: 
                 # If `current` string != `target_ver` (original check) -> Change
                 # OR if `moved` == 1 -> We likely need to change to sync.
                 
                 # Better: Check if `brew info` matches? No too slow.
                 # Let's stick to the original logic: Version vs Target Version. 
                 # But target_ver is now potentially a date?
                 # If we re-resolved, we don't know the exact version string without parsing the file.
                 # Just treat it as a change if "moved" or if original logic said change.
                 
                 # Refined check:
                 if [ "$current" != "$target_ver" ] && [ "$moved" == "0" ]; then
                     # Normal Lag Check
                     lower_ver=$(echo -e "$current\n$target_ver" | sort -V | head -n1)
                     if [ "$lower_ver" == "$target_ver" ]; then
                         action="DOWNGRADE"
                         color="$RED"
                     else
                         action="UPGRADE"
                         color="$BLUE"
                     fi
                     do_change=true
                 elif [ "$moved" == "1" ]; then
                     # Water Level Check
                     if [ "$current" == "$target_ver" ]; then
                         action="OK-Sync"
                         color="$GREEN"
                         do_change=false
                     else
                         action="SYNC-UP"
                         color="$BLUE"
                         do_change=true
                     fi
                 fi
            fi
        fi
        
        # Display
        target_display="$target_ver"
        if [ -n "$hash" ]; then
             target_display="${target_display} (${hash:0:7})"
        fi
        printf "${color}%-30s %-20s %-30s %-10s${NC}\n" "$formula" "$current" "$target_display" "$action"
        
        if [ "$do_change" = true ] && [ -n "$hash" ]; then
             echo "$formula|$hash|$path|$action" >> "$PLAN_FILE"
             changes_found=true
        fi
        
    done < "$resolved_file"
    
    echo ""
    if [ "$changes_found" = true ]; then
        warn "Plan saved to $PLAN_FILE"
        echo "Run 'brew-lag.sh apply' to execute these changes."
    else
        success "Everything is up to date (lagged/synced)."
        rm -f "$PLAN_FILE"
    fi
}

check_deps() {
    if ! command -v jq &> /dev/null; then
        error "jq is required. Please install it: brew install jq"
        exit 1
    fi
}

run_cleanup() {
    log "Cleaning up resources..."
    
    # Remove local tap
    if brew tap | grep -q "^$EXPORT_TAP$"; then
        log "Untapping $EXPORT_TAP..."
        brew tap-unpin "$EXPORT_TAP" 2>/dev/null || true
        brew untap "$EXPORT_TAP" 2>/dev/null || true
    fi
    
    # Remove config dir
    if [ -d "$CONFIG_DIR" ]; then
        log "Removing configuration directory $CONFIG_DIR..."
        rm -rf "$CONFIG_DIR"
    fi
    
    success "Cleanup complete."
}

# Parse arguments
COMMAND="plan"
DRY_RUN=true  # Default to dry-run for safety
while [[ "$#" -gt 0 ]]; do
    case $1 in
        plan)
            COMMAND="plan"
            shift ;;
        apply)
            COMMAND="apply"
            shift ;;
        cleanup)
            COMMAND="cleanup"
            shift ;;
        install)
            COMMAND="install"
            PKG_ARG="$2"
            shift; shift ;;
        --update)
            DO_UPDATE=true
            shift ;;
        --apply)
            DRY_RUN=false
            shift ;;
        --dry-run)
            DRY_RUN=true
            shift ;;
        exclude)
            COMMAND="exclude"
            PKG_ARG="$2"
            shift; shift ;;
        include)
            COMMAND="include"
            PKG_ARG="$2"
            shift; shift ;;
        list)
            COMMAND="list"
            shift ;;
        -j|--jobs)
            if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ]; then
                PARALLEL_JOBS="$2"
            else
                error "Invalid value for --jobs: '$2'. Must be a positive integer."
                exit 1
            fi
            shift; shift ;;
        -h|--help)
            usage
            exit 0 ;;
        *)
            error "Unknown argument: $1"
            usage
            exit 1 ;;
    esac
done

# Command dispatch
case "$COMMAND" in
    exclude)  add_exception "$PKG_ARG" ;;
    include)  remove_exception "$PKG_ARG" ;;
    list)     list_exceptions ;;
    plan)     run_analysis ;;
    apply)    execute_plan ;;
    install)  check_single_package "$PKG_ARG" ;;
    cleanup)  run_cleanup ;;
esac

exit 0