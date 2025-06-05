#!/usr/bin/env bash

# Shows each command and it's expanded arguments as it's run
# set -x

# Exit on error
# set -e

# Treat unset variables as errors
# set -u

# Strict mode for better error handling
# Catch errors in pipelines
# set -euo pipefail

export TERM=xterm-color
export GPG_TTY=$(tty)

# Unit tests https://github.com/bats-core/bats-core
# https://stackoverflow.com/questions/971945/unit-tests-for-shell-scripts

# Use single quote because `!` is a reserved symbol
# https://github.com/conventional-commits/conventionalcommits.org/issues/144#issuecomment-1615952692

# Secrets/environment variables and should be stored in a safe place (github workflow)
#GPG_PRIVATE_KEY
#GPG_PASSPHRASE
#GPG_KEY_ID
#GH_TOKEN
#GIT_AUTHOR_EMAIL
#GIT_AUTHOR_NAME

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

#
# cd /home/soufiane/Projects/git_playground/  to test the commands
#

# upload log file as an asset!!
LOG_FILE="release_script.log"
LOG_LEVEL_INFO="INFO"
# shellcheck disable=SC2034
LOG_LEVEL_WARN="WARN"
LOG_LEVEL_ERROR="ERROR"

# Logging utility
log() {
    local LOG_LEVEL=$1
    local MESSAGE=$2
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    case ${LOG_LEVEL} in
    INFO) COLOR="\033[;32m" ;;  # Green
    WARN) COLOR="\033[;33m" ;;  # Yellow
    ERROR) COLOR="\033[;31m" ;; # Red
    *) COLOR="\033[0m" ;;       # No color
    esac

    # Log to both console and file (tee)
    echo -e "${COLOR}[${TIMESTAMP}] [${LOG_LEVEL}] ${MESSAGE}\033[m" | tee -a "${LOG_FILE}"
}

handle_error() {
    local error_code=$1
    local error_message=$2

    log "${LOG_LEVEL_ERROR}" "$error_message"
    cleanup
    exit "$error_code"
}

verify_conditions() {
    echo "===== Verify Conditions ======"

    log "${LOG_LEVEL_INFO}" "Install jq"
    apt-get update && apt-get install -y jq

    required_commands=(git tee wget sed awk tr cut mapfile mktemp curl jq basename file)

    for cmd in "${required_commands[@]}"; do
        # Verify that a program exist
        if command -v "$cmd" &>/dev/null; then
            log "${LOG_LEVEL_INFO}" "$cmd does exist!"
        else
            log "${LOG_LEVEL_ERROR}" "Error: $cmd does not exist!"
            exit 1
        fi
    done

    echo "===== Setup Environment Variables ======"

    required_env_vars=(GH_TOKEN GIT_AUTHOR_EMAIL GPG_PRIVATE_KEY GPG_PASSPHRASE GPG_KEY_ID GIT_AUTHOR_NAME USERNAME REPOSITORY_NAME)

    for var in "${required_env_vars[@]}"; do
        # Verify that an environment variable exists
        if [[ -z "${!var}" ]]; then
            log "${LOG_LEVEL_ERROR}" "Error: $var is not set!"
            exit 1
        fi
    done

    log "${LOG_LEVEL_INFO}" "All required commands and environment variables are verified! ✔️"
}

setup_git() {
    echo "===== Setup git ======"

    # Detect GPG binary
    local GPG_BIN
    # Get the path of GPG binary dynamically
    GPG_BIN=$(command -v gpg) || {
        log "${LOG_LEVEL_ERROR}" "gpg binary not found!"
        exit 1
    }

    # Import private key
    if ! echo "$GPG_PRIVATE_KEY" | "$GPG_BIN" --batch --yes --no-tty --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" --import; then
        log "${LOG_LEVEL_ERROR}" "Failed to import GPG private key!"
        exit 1
    fi

    # Create a secure temporary GPG wrapper script
    local gpg_wrapper
    gpg_wrapper=$(mktemp /tmp/gpg_wrapper.XXXXXX) || {
        log "${LOG_LEVEL_ERROR}" "Failed to create temporary file for GPG wrapper!"
        exit 1
    }

    #chmod +x "$gpg_wrapper"
    chmod 0700 "$gpg_wrapper"

    # Clean up temp file on exit
    cleanup() {
        rm -f "$gpg_wrapper"
    }

    trap cleanup EXIT

    # `--no-tty` is an argument used by the GPG program to ensure that GPG does not use the terminal for any input
    cat <<EOF >"$gpg_wrapper"
#!/usr/bin/env bash
"$GPG_BIN" --batch --no-tty --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" "\$@"
EOF

    # Configure Git

    # Set username
    git config --global user.name "$GIT_AUTHOR_NAME"
    log "${LOG_LEVEL_INFO}" "Git author name is set"

    # Set email
    git config --global user.email "$GIT_AUTHOR_EMAIL"
    log "${LOG_LEVEL_INFO}" "Git author email is set"

    # Used to sign commits with GPG signing key
    git config --global user.signingkey "$GPG_KEY_ID"
    log "${LOG_LEVEL_INFO}" "GPG signing key configured"

    git config --global commit.gpgsign true
    log "${LOG_LEVEL_INFO}" "GPG signing key enabled"

    git config --global tag.gpgsign true
    log "${LOG_LEVEL_INFO}" "Tag signing enabled"
    git config --global gpg.program "$gpg_wrapper"

    log "${LOG_LEVEL_INFO}" "Git setup complete. ✔️"
}

check_git_tags() {
    echo "===== Check git tags ======"

    # Check for tags that starts with "v" (e.g., v0.1.0)
    if [ -z "$(git tag --list "v*")" ]; then
        log "${LOG_LEVEL_INFO}" "No tags found in $REPOSITORY_NAME project, This is likely the first release."
        latest_tag=""
    else
        # Get the most recent tag and remove "v" prefix
        # `git describe --tags --abbrev=0` gets the most recent tag
        # sed removes the "v" prefix from the version number
        latest_tag=$(git describe --abbrev=0 --tags 2>/dev/null | sed 's/^v//') # Example output 0.1.0

        if [ -n "$latest_tag" ]; then
            log "${LOG_LEVEL_INFO}" "Tags detected in the $REPOSITORY_NAME"
        else
            log "${LOG_LEVEL_ERROR}" "Unable to determine the latest tag."
            exit 1
        fi
    fi

    log "${LOG_LEVEL_INFO}" "latest_tag = $latest_tag"
}

# TODO: https://github.com/soufianes98/devops_playground/actions/runs/14814689065/job/41593729811
parse_latest_commits() {
    echo "===== Parse latest commits ======"

    #latest_tag=""
    local git_log_cmd
    if [ -n "$latest_tag" ]; then
        log "${LOG_LEVEL_INFO}" "Fetching commits since tag: v${latest_tag}"
        # Get all commits since the latest tag
        git_log_cmd=(git log v"${latest_tag}"..HEAD --pretty=format:'__START__%n%h%n%s%n%b')
    else
        # If no tags exist, get all commits
        log "${LOG_LEVEL_INFO}" "No tags exist, fetching all commits"
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
        type = ""; scope = ""; breaking = "false"; message = ""; trigger = "";

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
        }

        # Ensure all fields are properly quoted and escaped
        printf "  {\n";
        printf "    \"hash\": \"%s\", \n", hash;
        printf "    \"raw_subject\": \"%s\",\n", raw_subject;
        printf "    \"type\": \"%s\",\n", type;
        printf "    \"scope\": \"%s\",\n", scope;
        printf "    \"breaking\": \"%s\",\n", breaking;
        printf "    \"trigger\": \"%s\",\n", trigger;
        printf "    \"message\": \"%s\",\n", message;
        printf "    \"body_lines\": [\n";
        printf "%s\n", body_lines;
        printf "    ]\n";
        printf "  }";
    }

    END {
        print "]"
    }' | jq '{data: .}' >data.json

    return 0
}

bump_version() {
    echo "===== Bumping versions ======"

    # Determine the next version based on changes
    parse_latest_tag() {
        local latest_tag="$1"
        local major minor patch

        # TODO: Validate input
        if [ -z "$latest_tag" ]; then
            log "${LOG_LEVEL_ERROR}" "Error: Empty tag provided"
            exit 1 # exit 1
        fi

        # TODO: Validate semantic version format (x.y.z)
        if [[ ! "$latest_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log "${LOG_LEVEL_ERROR}" "Error: Invalid semantic version format. Expected 'x.y.z' but got '$latest_tag'"
            exit 1 # exit 1
        fi

        # Split the version into components, into major, minor and patch using `.` as the delimiter
        IFS='.' read -r major minor patch <<<"$latest_tag"

        # Return components
        echo "$major $minor $patch"
        return 0
    }

    # NOTE: https://chatgpt.com/share/675616ba-109c-800f-b2b2-018234f97e9a

    # Create a git tag if all conditions met

    # Handle first release
    # If latest_tag is empty
    if [[ -z "$latest_tag" ]]; then
        # initial commit | first commit | Initial public release
        next_tag="0.1.0"
        is_pre_release=true
        log "${LOG_LEVEL_INFO}" "First release: v$next_tag (pre-release)"
        return 0
    fi

    if ! read -r major minor patch <<<"$(parse_latest_tag "$latest_tag")"; then
        log "${LOG_LEVEL_ERROR}" "Error: Failed to parse current version $latest_tag"
        exit 1
    fi

    # Determine version bump based on changes
    # Array size of: ${#breaking_changes[@]}
    breaking_changes_count=$(jq '[.data[] | select(.breaking == "true")] | length' data.json)
    if [[ "${breaking_changes_count}" -ne 0 ]]; then
        # Bump major(major version increment)
        next_tag="$((++major)).0.0"
        log "${LOG_LEVEL_INFO}" "Major version bump to: v$next_tag"
        is_pre_release=false

        log "${LOG_LEVEL_INFO}" "Breaking changes(${breaking_changes_count}):"

        return 0 # Exit/Break this function and move to the next function
    fi

    new_features_count=$(jq '[.data[] | select(.type == "feat")] | length' data.json)
    performance_improvements_count=$(jq '[.data[] | select(.type == "perf")] | length' data.json)
    if [[ "${new_features_count}" -ne 0 || "${performance_improvements_count}" -ne 0 ]]; then
        # Bump minor
        next_tag="$major.$((++minor)).0"
        log "${LOG_LEVEL_INFO}" "Minor version bump to: v$next_tag"

        if [[ "$major" -eq 0 ]]; then
            is_pre_release=true
        else
            is_pre_release=false
        fi

        log "${LOG_LEVEL_INFO}" "New Features(${new_features_count})"
        log "${LOG_LEVEL_INFO}" "Performance Improvements: ${performance_improvements_count}"

        return 0 # Exit/Break this function and move to the next function
    fi

    bug_fixes_count=$(jq '[.data[] | select(.type == "fix")] | length' data.json)
    if [[ "${bug_fixes_count}" -ne 0 ]]; then
        # Bump patch
        next_tag="$major.$minor.$((++patch))"
        log "${LOG_LEVEL_INFO}" "Patch version bump to: v$next_tag"

        if [[ "$major" -eq 0 ]]; then
            is_pre_release=true
        else
            is_pre_release=false
        fi

        log "${LOG_LEVEL_INFO}" "Bug Fixes(${bug_fixes_count})"

        return 0 # Exit/Break this function and move to the next function
    fi

    log "${LOG_LEVEL_INFO}" "No version-impacting changes detected in codebase!"
    log "${LOG_LEVEL_INFO}" "Current version remains at v$latest_tag"

    docs_count=$(jq '[.data[] | select(.type == "docs")] | length' data.json)
    tests_count=$(jq '[.data[] | select(.type == "tests")] | length' data.json)
    chores_count=$(jq '[.data[] | select(.type == "chore")] | length' data.json)
    styling_count=$(jq '[.data[] | select(.type == "style")] | length' data.json)
    build_count=$(jq '[.data[] | select(.type == "build")] | length' data.json)
    ci_count=$(jq '[.data[] | select(.type == "ci")] | length' data.json)
    code_refactoring_count=$(jq '[.data[] | select(.type == "feat")] | length' data.json)
    reverts_count=$(jq '[.data[] | select(.type == "revert")] | length' data.json)

    log "${LOG_LEVEL_INFO}" "Change summary:"
    log "${LOG_LEVEL_INFO}" "Breaking changes(${breaking_changes_count})"
    log "${LOG_LEVEL_INFO}" "New Features(${new_features_count})"
    log "${LOG_LEVEL_INFO}" "Performance Improvements(${performance_improvements_count})"
    log "${LOG_LEVEL_INFO}" "Bug Fixes(${bug_fixes_count})"
    log "${LOG_LEVEL_INFO}" "Documentation(${docs_count}):"
    log "${LOG_LEVEL_INFO}" "Tests(${docs_count}):"
    log "${LOG_LEVEL_INFO}" "Chores(${chores_count})"
    log "${LOG_LEVEL_INFO}" "Styling(${styling_count})"
    log "${LOG_LEVEL_INFO}" "Build(${build_count})"
    log "${LOG_LEVEL_INFO}" "Continuous Integration(${ci_count})"
    log "${LOG_LEVEL_INFO}" "Code Refactoring(${code_refactoring_count})"
    log "${LOG_LEVEL_INFO}" "Reverts(${reverts_count})"

    # The following code will exit the entire script
    exit 0

    # TODO more conditions

}

prepare_latest_changelog() {
    # echo "===== Generate release notes ======"

    # Helper function
    create_commit_hash_url() {
        local username="$1"
        local repository_name="$1"
        local commit_hash="$1"

        # Return the URL
        echo "https://github.com/$username/$repository_name/commit/$commit_hash"
    }

    local release_notes=""

    local breaking_changes_content=""
    local new_features_content=""
    local performance_improvements_content=""
    local bug_fixes_content=""
    local docs_content=""
    local test_content=""
    local chores_content=""
    local styling_content=""
    local build_content=""
    local ci_content=""
    local code_refactoring_content=""
    local reverts_content=""

    if [[ -z "$latest_tag" ]]; then
        release_notes="initial commit"

        # This is like a return value
        echo "$release_notes"
        return 0 # Will exit this function
    fi

    json_file="data.json"
    # jq '.' "$json_file"

    log "${LOG_LEVEL_INFO}" "Processing commits:"
    while read -r commit; do
        # Extract fields safely
        hash=$(echo "$commit" | jq -r '.hash? // ""')
        type=$(echo "$commit" | jq -r '.type? // ""')
        scope=$(echo "$commit" | jq -r '.scope? // ""')
        message=$(echo "$commit" | jq -r '.message? // ""')
        breaking=$(echo "$commit" | jq -r '.breaking? // "false"')

        # Process body lines with proper array handling
        echo "Body:"
        body_lines=$(echo "$commit" | jq -c '.body_lines? // []')

        if [ "$(echo "$body_lines" | jq 'length')" -gt 0 ]; then
            echo "$body_lines" | jq -r '.[]' | while read -r line; do
                # shellcheck disable=SC1019
                # shellcheck disable=SC1020
                # shellcheck disable=SC1072
                # shellcheck disable=SC1073
                [ -n "$line" ] && echo "  - $line"
                # TODO:
            done
        else
            echo "  (No body content)"
        fi

        # TODO: "$breaking" -eq true | "$breaking" -eq "true"
        if [[ "$breaking" == "true" ]]; then
            # Append release_notes
            breaking_changes_content+="**BREAKING CHANGES**\n\n"
            if [ -n "$scope" ]; then
                breaking_changes_content+="* ${scope}: ${message}\n"
            else
                breaking_changes_content+="* ${message}\n"
            fi
        else
            log "${LOG_LEVEL_INFO}" "No breaking changes found!"
        fi

        case $type in
        "feat")
            new_features_content="**Features**\n\n"
            commit_hash_url=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                new_features_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                new_features_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        "perf")
            performance_improvements_content="**Performance Improvements**\n\n"
            commit_hash_url=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                performance_improvements_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                performance_improvements_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        "fix")
            bug_fixes_content="**Bug Fixes**\n\n"
            commit_hash_url=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                bug_fixes_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                bug_fixes_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        "docs")
            docs_content="**Documentation**\n\n"
            commit_hash_url=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                docs_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                docs_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        "test")
            test_content="**Tests**\n\n"
            commit_hash_url=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                test_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                test_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        "chore")
            chores_content="**Chores**\n\n"
            commit_hash_url=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                chores_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                chores_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        "style")
            styling_content="**Styling**\n\n"
            styling_content=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                styling_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                styling_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        "build")
            build_content="**Build**\n\n"
            build_content=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                build_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                build_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        "ci")
            ci_content="**Continuous Integration**\n\n"
            ci_content=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                ci_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                ci_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        "refactor")
            code_refactoring_content="**Code Refactoring**\n\n"
            code_refactoring_content=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                code_refactoring_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                code_refactoring_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        "revert")
            reverts_content="**Reverts**\n\n"
            reverts_content=$(create_commit_hash_url "$USERNAME" "$REPOSITORY_NAME" "$hash")

            if [ -n "$scope" ]; then
                reverts_content+="* $scope: $message ([#$hash]($commit_hash_url))\n"
            else
                reverts_content+="* $message ([#$hash]($commit_hash_url))\n"
            fi
            ;;
        *)
            echo "default: INVALID OPTION!!"
            ;;
        esac
    done < <(jq -c '.data[]' "$json_file")

    # TODO
    release_notes="$breaking_changes_content$new_features_content$performance_improvements_content$bug_fixes_content$docs_content$test_content$chores_content$styling_content$build_content$ci_content$code_refactoring_content$reverts_content"
    # This is like a return value
    echo "$release_notes"
}

generate_changelog() {
    echo "===== Generate changelog ======"

    local latest_changelog
    latest_changelog=$(prepare_latest_changelog)

    current_date=$(date +%Y-%m-%d)

    # https://chat.openai.com/share/404f983a-046b-4112-a86c-6b3bf0c07be5
    # Append or create a CHANGELOG.md file
    local changelog_file="CHANGELOG.md"

    # `-z` means that the variable is empty, `-n` means the variable is not empty
    if [ -z "$latest_tag" ]; then
        # e.g. https://github.com/USERNAME/project-name/releases/tag/v0.1.0
        url="https://github.com/$USERNAME/$REPOSITORY_NAME/releases/tag/v$next_tag"

        changelog="# Changelog\n\n## [$next_tag]($url) ($current_date)\n\n$latest_changelog"
        # Create the first changelog file
        echo -e "$changelog" >"$changelog_file"
    elif [ -n "$latest_tag" ]; then
        # https://github.com/USERNAME/project-name/compare/v0.1.0...v0.2.0
        url="https://github.com/$USERNAME/$REPOSITORY_NAME/compare/v$latest_tag...v$next_tag"

        # Remove the first line that contains the phrase '# Changelog'
        sed -i '/^# Changelog/d' "$changelog_file"

        # Create new changelog content
        changelog="# Changelog \n\n## [$next_tag]($url) ($current_date)\n\n$latest_changelog\n\n$(cat "$changelog_file")"

        # Prepend the new changelog content to the existing file
        echo -e "$changelog" | cat - "$changelog_file" >temp_changelog && mv temp_changelog "$changelog_file"
    fi

    log "${LOG_LEVEL_INFO}" "Changelog created"
}

# NOTE: Always publish changelog before creating a new tag
publish_changelog() {
    echo "===== Publish changelog ======"

    commit_message="chore(release): update changelog for v$next_tag"
    git add CHANGELOG.md
    git commit -S -m "$commit_message"
    git log --show-signature
    git push

    log "${LOG_LEVEL_INFO}" "Changelog successfully published"
}

create_new_github_tag() {
    echo "===== Create a new Github tag ======"

    # Create a signed and annotated git tag
    git tag -s -a "v$next_tag" -m "Release version $next_tag"

    # Verify signed tag
    # git tag -v "v$next_tag"

    message="The tag has been successfully published 🎉"

    # Push the tag to remote
    git push origin "v$next_tag" && log "${LOG_LEVEL_INFO}" "$message"

    # Show the tag details
    git show "v$next_tag"
}

create_github_release() {
    echo "===== Create a new Github release ======"

    # First check if the remote tag is pushed and available in github
    # git ls-remote --tags origin

    # push release to github using curl using: <https://docs.github.com/en/rest> , <https://docs.github.com/en/rest/releases/releases> , <https://docs.github.com/en/rest/releases/assets>

    # TODO: Every release should contain shipped source code and all assets(Artifacts) like:
    # https://github.com/jgraph/drawio/releases
    # https://github.com/ssdev98/test_technique/releases/new
    # https://www.lucavall.in/blog/how-to-create-a-release-with-multiple-artifacts-from-a-github-actions-workflow-using-the-matrix-strategy
    # https://stackoverflow.com/questions/71816958/how-to-upload-artifacts-to-existing-release
    # https://stackoverflow.com/questions/75164222/how-to-upload-a-release-in-github-action-using-github-script-action
    # https://chatgpt.com/share/7a299605-4d36-48c0-9b5f-edbf8f055d01
    #

    # Make sure to add release notes or setup via github

    # https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28
    # To list all releases

    # Boolean value
    echo "$is_pre_release"

    # TODO: Before publishing a release check if the git tag is published to github

    curl -L \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        https://api.github.com/repos/"$USERNAME"/"$REPOSITORY_NAME"/releases
    log "${LOG_LEVEL_INFO}" 'Checking if the tag is published to github'

    #
    #
    #
    #
    #

    local release_notes
    release_notes=$(prepare_latest_changelog)

    log "${LOG_LEVEL_INFO}" "release_notes: $release_notes"

escaped_release_notes=$(printf '%s' "$release_notes" | jq -Rs .)
    read -r -d '' JSON_PAYLOAD <<EOF
{
  "tag_name": "v$next_tag",
  "target_commitish": "main",
  "name": "v$next_tag",
  "body": $escaped_release_notes,
  "draft": false,
  "prerelease": $is_pre_release,
  "generate_release_notes": true
}
EOF

    # Create a new release
    HTTP_RESPONSE=$(
        curl -w "%{http_code}" \
            -L \
            -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            https://api.github.com/repos/"$USERNAME"/"$REPOSITORY_NAME"/releases \
            -d "$JSON_PAYLOAD"
    )

    HTTP_BODY=${HTTP_RESPONSE::-3}   # All except last 3 chars
    HTTP_STATUS=${HTTP_RESPONSE: -3} # Last 3 chars

    if [[ "$HTTP_STATUS" -ne 201 ]]; then
        log "${LOG_LEVEL_ERROR}" "Failed to create release, HTTP status $HTTP_STATUS"
        echo "$HTTP_BODY" | jq '.message, .errors' 2>/dev/null || echo "$HTTP_BODY"
        log "${LOG_LEVEL_ERROR}" 'Error: Failed to create a new release in GitHub'
        exit 1
    fi

    RELEASE_ID=$(echo "$HTTP_BODY" | jq -r '.id')
    if [[ -z "$RELEASE_ID" || "$RELEASE_ID" == "null" ]]; then
        echo "ERROR: Release ID missing in response"
        exit 1
    fi

    log "${LOG_LEVEL_INFO}" "Release created with ID: $RELEASE_ID"

    log "${LOG_LEVEL_INFO}" "Uploading artifacts for the latest release"
    # TODO:
    artifacts_paths=("$HOME/Downloads/artifacts/artifact1.js" "$HOME/Downloads/artifacts/artifact2.txt")

    for artifact_path in "${artifacts_paths[@]}"; do
        # Check if the artifact exists
        if [[ ! -f "$artifact_path" ]]; then
            log "${LOG_LEVEL_ERROR}" "Artifact not found: $artifact_path"
            continue # Skip to the next artifact
        fi

        # Extract filename from the path
        artifact_filename=$(basename "$artifact_path")

        # Get the MIME type dynamically
        mime_type=$(file -b --mime-type "$artifact_path")

        log "${LOG_LEVEL_INFO}" "Uploading $artifact_path..."

        HTTP_RESPONSE=$(curl -w "%{http_code}" \
            -L \
            -X POST \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "Content-Type: $mime_type" \
            --data-binary @"$artifact_path" \
            "https://uploads.github.com/repos/$USERNAME/$REPOSITORY_NAME/releases/$RELEASE_ID/assets?name=$artifact_filename-$next_tag")

        HTTP_STATUS=$(echo $HTTP_RESPONSE | tail -c 4)

        if [[ "$HTTP_STATUS" -ne 201 ]]; then
            log "${LOG_LEVEL_ERROR}" "Failed to upload: $artifact_filename"
            continue # Skip to the next artifact
        fi

        log "${LOG_LEVEL_INFO}" "- $artifact_path file uploaded successfully."
    done

    log "${LOG_LEVEL_INFO}" "All artifacts uploaded successfully."

    # Then check the response status code is 201 (created) to make sure the release is published in github
    # And also print the release info and maybe export it to a service using jq command and curl
    # and display a message to confirm that the release is published to github
    # like
    log "${LOG_LEVEL_INFO}" "Release published successfully! 🎉"

}

post_release() {
    # TODO: Cleanup
    # TODO: Delete temporary files
    echo 'post_release'
    #exit 0
}

main() {
    verify_conditions
    setup_git
    check_git_tags
    parse_latest_commits
    bump_version
    generate_changelog
    publish_changelog
    create_new_github_tag
    create_github_release
    post_release
}

# Program entry point
main
