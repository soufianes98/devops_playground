#!/usr/bin/env bash

# Shows each command and it's expanded arguments as it's run
set -x # Enable debug output

# Exit on error
# set -e

# Treat unset variables as errors
# set -u

# Strict mode for better error handling
# Catch errors in pipelines
# set -euo pipefail

# shellcheck disable=SC1091
source .github/scripts/utils.sh

# Unit tests https://github.com/bats-core/bats-core
# Use single quote because `!` is a reserved symbol

# Declaring global variables
unset is_pre_release
unset latest_tag
unset next_tag

# First check if this is the first release
# List latest commits
# Parse commits
# Categorize commits based on scope and type
# TODO: WRITE/SAVE ALL RESULTS IN A LOG FILE
# TODO: GENERATE SHA

# merged_pull_requests=()
# closed_issues=()


check_git_tags() {
    echo "===== Check git tags ======"

    # Check if this is a git repo
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        handle_error 1 "This is not a git repository!"
    fi

    # Check for tags that starts with "v" (e.g., v0.1.0)
    if [ -z "$(git tag --list "v*")" ]; then
        log_info "No tags found in $REPOSITORY_NAME project, This is likely the first release."
        latest_tag=""
    else
        # Get the most recent tag and remove "v" prefix
        # `git describe --tags --abbrev=0` gets the most recent tag
        # sed removes the "v" prefix from the version number
        # `git describe` only works with annotated tags
        latest_tag=$(git describe --abbrev=0 --tags 2>/dev/null | sed 's/^v//') # Example output 0.1.0

        if [ -n "$latest_tag" ]; then
            log_info "Tags detected in the $REPOSITORY_NAME"
        else
            handle_error 1 "Unable to determine the latest tag."
        fi
    fi

    log_info "latest_tag = $latest_tag"
}

parse_latest_commits() {
    echo "===== Parse latest commits ======"

    local git_log_cmd
    if [ -n "$latest_tag" ]; then
        log_info "Fetching commits since tag: v${latest_tag}"
        # Get all commits since the latest tag
        git_log_cmd=(git log v"${latest_tag}"..HEAD --pretty=format:'__START__%n%h%n%s%n%b')
    else
        log_info "No tags exist, Fetching all commits"
        # Get all commits since the start
        git_log_cmd=(git log --pretty=format:'__START__%n%h%n%s%n%b')
    fi

    # Create a new json file using jq
    jq -n '{data: []}' >data.json

    # Pipe it to awk
    "${git_log_cmd[@]}" | awk '
    BEGIN {
        RS="";
        FS="\n";
        print "["
    }

    function json_escape(str) {
        if(str == "") return "";
        gsub(/\\/, "\\\\", str);       # Escape backslashes first
        gsub(/"/, "\\\"", str);        # Escape quotes
        gsub(/\//, "\\/", str);        # Escape forward slashes
        gsub(/\t/, "\\t", str);        # Escape tabs
        gsub(/\n/, "\\n", str);        # Escape new lines
        gsub(/\r/ , "\\r", str);       # Escape carriage returns
        gsub(/[\x00-\x1f]/, "", str); # Escape Remove other control characters

        return str;
    }

    {
        if (NR > 1) print ","
        

        hash = json_escape($2);
        raw_subject = json_escape($3);
        type = ""; scope = ""; breaking = "false"; message = ""; trigger = ""; prerelease = "";

        # Parse Conventional Commit subject
        if (match(raw_subject, /^([a-z]+)(\(([^\)]+)\))?(!)?:[ ]*(.*)$/, parts)) {
            type = json_escape(parts[1]);
            scope = json_escape(parts[3]);
            breaking = (parts[4] == "!") ? "true" : "false";
            trigger = (parts[4] == "!") ? "subject" : "";
            message = json_escape(parts[5]);
        } else {
            message = raw_subject;
        }

        body_lines = "";
        body_count = 0;
        for (i = 4; i <= NF; i++) {
            line = json_escape($i);
            if (line == "") continue;

            if (body_count++ > 0) body_lines = body_lines ",\n";
            body_lines = body_lines "    \"" line "\"";

            if (line ~ /^BREAKING CHANGE:/) {
                breaking = "true";
                trigger = "body"
            }

            if (match(line, /^Pre-Release:[ \t]*([a-zA-Z0-9.-]+)/, pr_parts)) {
                prerelease = json_escape(pr_parts[1]);
            }
        }

        # Ensure all fields are properly quoted and escaped
        printf "  {\n";
        printf "    \"hash\": \"%s\", \n", hash;
        printf "    \"raw_subject\": \"%s\",\n", raw_subject;
        printf "    \"type\": \"%s\",\n", type;
        printf "    \"scope\": \"%s\",\n", scope;
        printf "    \"breaking\": \"%s\",\n", breaking;
        printf "    \"trigger\": \"%s\",\n", trigger;
        printf "    \"prerelease\": \"%s\",\n", prerelease;
        printf "    \"message\": \"%s\",\n", message;
        printf "    \"body_lines\": [\n";
        printf "%s\n", body_lines;
        printf "    ]\n";
        printf "  }";
    }

    END {
        print "]"
    }' | jq '{data: .}' >data.json
}

bump_version() {
    echo "===== Bumping versions ======"

    # Helper function
    # Determine the next version based on changes
    parse_latest_tag() {
        local latest_tag="$1"
        local major minor patch

        # TODO: Validate input
        if [ -z "$latest_tag" ]; then
            handle_error 1 "Error: Empty tag provided"
        fi

        # Regex to match: major.minor.patch-prerelease.N
        regex='^([0-9]+)\.([0-9]+)\.([0-9]+)(-([a-zA-Z]+)\.([0-9]+))?$'

        # TODO: Validate semantic version format
        if [[ "$latest_tag" =~ $regex ]]; then
            major="${BASH_REMATCH[1]}"
            minor="${BASH_REMATCH[2]}"
            patch="${BASH_REMATCH[3]}"
            pre_release="${BASH_REMATCH[5]}"
            pre_num="${BASH_REMATCH[6]}"

            # Only output the version components
            # Return components as a string with proper spacing
            echo "${major} ${minor} ${patch} ${pre_release:-} ${pre_num:-}"
            return 0
        else
            handle_error 1 "Error: Invalid semantic version format. Expected 'major.minor.patch-prerelease.N' but got '$latest_tag'"
        fi
    }

    first_prerelease=$(jq -r '.data[0].prerelease' data.json)

    # Handle first release
    # If latest_tag is empty
    if [[ -z "$latest_tag" ]]; then
        # initial commit | first commit | Initial public release

        case "$first_prerelease" in
        dev)
            next_tag="0.1.0-dev.1"
            ;;
        alpha)
            next_tag="0.1.0-alpha.1"
            ;;
        beta)
            next_tag="0.1.0-beta.1"
            ;;
        rc)
            next_tag="0.1.0-rc.1"
            ;;
        *)
            next_tag="0.1.0"
            ;;
        esac
        
        is_pre_release=true
        log_info "First release: v$next_tag (pre-release)"
        return 0
    fi

    # Parse the current version components
    version_components=$(parse_latest_tag "$latest_tag")
    if ! read -r major minor patch pre_release pre_num <<<"$version_components"; then
        handle_error 1 "Error: Failed to parse current version $latest_tag"
    fi

    case "$first_prerelease" in
    dev)
        echo "Development snapshot version"
        if [[ "$pre_release" == "dev" ]]; then
            next_tag="$major.$minor.$patch-dev.$((pre_num + 1))"
        else
            next_tag="$major.$minor.$patch-dev.1"
        fi

        is_pre_release=true
        return
        ;;
    alpha)
        echo "Alpha version"
        if [[ "$pre_release" == "alpha" ]]; then
            next_tag="$major.$minor.$patch-alpha.$((pre_num + 1))"
        else
            next_tag="$major.$minor.$patch-alpha.1"
        fi

        is_pre_release=true
        return
        ;;
    beta)
        echo "Beta version"
        if [[ "$pre_release" == "beta" ]]; then
            next_tag="$major.$minor.$patch-beta.$((pre_num + 1))"
        else
            next_tag="$major.$minor.$patch-beta.1"
        fi

        is_pre_release=true
        return
        ;;
    rc)
        echo "Release candidate"
        if [[ "$pre_release" == "rc" ]]; then
            next_tag="$major.$minor.$patch-rc.$((pre_num + 1))"
        else
            next_tag="$major.$minor.$patch-rc.1"
        fi

        is_pre_release=true
        return
        ;;
    *)
        echo "Stable release"
        ;;
    esac

    log_summary(){
        docs_count=$(jq '[.data[] | select(.type == "docs")] | length' data.json)
        tests_count=$(jq '[.data[] | select(.type == "tests")] | length' data.json)
        chores_count=$(jq '[.data[] | select(.type == "chore")] | length' data.json)
        styling_count=$(jq '[.data[] | select(.type == "style")] | length' data.json)
        build_count=$(jq '[.data[] | select(.type == "build")] | length' data.json)
        ci_count=$(jq '[.data[] | select(.type == "ci")] | length' data.json)
        code_refactoring_count=$(jq '[.data[] | select(.type == "refactor")] | length' data.json)
        reverts_count=$(jq '[.data[] | select(.type == "revert")] | length' data.json)

        log_info "===== Change summary: ====="
        log_info "Documentation(${docs_count}):"
        log_info "Tests(${tests_count}):"
        log_info "Chores(${chores_count})"
        log_info "Styling(${styling_count})"
        log_info "Build(${build_count})"
        log_info "Continuous Integration(${ci_count})"
        log_info "Code Refactoring(${code_refactoring_count})"
        log_info "Reverts(${reverts_count})"
        log_info "==========================="
    }

    # Determine version bump based on changes
    # Array size of: ${#breaking_changes[@]}
    breaking_changes_count=$(jq '[.data[] | select(.breaking == "true")] | length' data.json)
    if [[ "${breaking_changes_count}" -ne 0 ]]; then
        # Bump major(major version increment)
        next_tag="$((major + 1)).0.0"
        is_pre_release=false

        log_info "Major version bump to: v$next_tag"
        log_info "Breaking changes(${breaking_changes_count}):"
        log_summary

        return 0 # Exit/Break this function and move to the next function
    fi

    new_features_count=$(jq '[.data[] | select(.type == "feat")] | length' data.json)
    performance_improvements_count=$(jq '[.data[] | select(.type == "perf")] | length' data.json)
    if [[ "${new_features_count}" -ne 0 || "${performance_improvements_count}" -ne 0 ]]; then
        # Bump minor
        next_tag="$major.$((minor + 1)).0"
        log_info "Minor version bump to: v$next_tag"

        if [[ "$major" -eq 0 ]]; then
            is_pre_release=true
        else
            is_pre_release=false
        fi

        log_info "New Features(${new_features_count})"
        log_info "Performance Improvements: ${performance_improvements_count}"
        log_summary

        return 0
    fi

    bug_fixes_count=$(jq '[.data[] | select(.type == "fix")] | length' data.json)
    if [[ "${bug_fixes_count}" -ne 0 ]]; then
        # Bump patch
        next_tag="$major.$minor.$((patch + 1))"
        log_info "Patch version bump to: v$next_tag"

        if [[ "$major" -eq 0 ]]; then
            is_pre_release=true
        else
            is_pre_release=false
        fi

        log_info "Bug Fixes(${bug_fixes_count})"
        log_summary

        return 0
    fi

    log_info "No version-impacting changes detected in codebase!"
    log_info "Current version remains at v$latest_tag"
}

generate_changelog() {
    echo "===== Generate changelog ======"

    local latest_changelog
    latest_changelog=$(build_latest_changelog)

    # Clean up any placeholder content
    latest_changelog=$(echo "$latest_changelog" | grep -v "No body content")

    current_date=$(date +%Y-%m-%d)

    # https://chat.openai.com/share/404f983a-046b-4112-a86c-6b3bf0c07be5

    repo_url="https://github.com/$USERNAME/$REPOSITORY_NAME"

    # `-z` means that the variable is empty, `-n` means the variable is not empty
    if [ -z "$latest_tag" ]; then
        # First release create a fresh changelog file
        url="$repo_url/releases/tag/v$next_tag"

        changelog="# Changelog\n\n## [$next_tag]($url) ($current_date)\n\n$latest_changelog"
        # Create the first changelog file in project directory
        echo -e "$changelog" > "CHANGELOG.md"
    elif [ -n "$latest_tag" ]; then
        # Subsequent releases - update existing changelog file
        url="$repo_url/compare/v$latest_tag...v$next_tag"

        # Content for new version, including its heading
        new_version_content="## [$next_tag]($url) ($current_date)\\n\\n$latest_changelog"

        # Read the existing changelog, skipping the first line ('# Changelog')
        # This prevents duplicating the main header and old entries
        existing_changelog_without_header=$(tail -n +2 "CHANGELOG.md")

        # Reconstruct the changelog: new main header, new version content, then existing content
        printf "# Changelog\\n\\n%b\\n\\n%b" "$new_version_content" "$existing_changelog_without_header" > "CHANGELOG.md"
    fi

    log_info "Changelog created successfully."
}

post_setup() {
    echo '===== post_setup ====='
    # TODO: Cleanup
    {
        echo  "is_pre_release=$is_pre_release"
        echo "latest_tag=$latest_tag"
        echo "next_tag=$next_tag"
    } >> "$GITHUB_OUTPUT"
    
    log_info "Cleaning up temporary files"
    rm -f data.json
}

verify_conditions
setup_git
check_git_tags
parse_latest_commits
bump_version
generate_changelog
post_setup
