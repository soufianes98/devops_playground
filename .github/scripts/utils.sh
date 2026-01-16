#!/usr/bin/env bash

export TERM=xterm-color
export GPG_TTY=$(tty)

GPG_WRAPPER_PATH=""

LOG_FILE="release_script.log"
LOG_LEVEL_INFO="INFO"
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

log_info() {
    local info_message=$1
    log "${LOG_LEVEL_INFO}" "$info_message"
}

log_warning() {
    local warning_message=$1
    log "${LOG_LEVEL_WARN}" "$warning_message"
}

handle_error() {
    local error_code=$1
    local error_message=$2

    log "${LOG_LEVEL_ERROR}" "$error_message"
    # cleanup
    exit "$error_code"
}

setup_git() {
    echo "===== Setup git ======"

    # Detect GPG binary
    local GPG_BIN
    # Get the path of GPG binary dynamically
    GPG_BIN=$(command -v gpg) || {
        handle_error 1 "gpg binary not found!"
    }

    # Import private key
    if ! echo "$GPG_PRIVATE_KEY" | "$GPG_BIN" --batch --yes --no-tty --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" --import; then
        handle_error 1 "Failed to import GPG private key!"
    fi

    # Create a secure temporary GPG wrapper script
    GPG_WRAPPER_PATH=$(mktemp /tmp/gpg_wrapper.XXXXXX) || {
        handle_error 1 "Failed to create temporary file for GPG wrapper!"
    }

    #chmod +x "$GPG_WRAPPER_PATH"
    chmod 0700 "$GPG_WRAPPER_PATH"

    # `--no-tty` is an argument used by the GPG program to ensure that GPG does not use the terminal for any input
    cat <<EOF >"$GPG_WRAPPER_PATH"
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
    git config --global gpg.program "$GPG_WRAPPER_PATH"

    log "${LOG_LEVEL_INFO}" "Git setup complete. ✔️"

    # Verify that GPG wrapper works
    if ! "$GPG_WRAPPER_PATH" --version; then
        log "${LOG_LEVEL_INFO}" "GPG wrapper verification failed"
    fi
}

verify_conditions() {
    echo "===== Verify Conditions ======"

    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$current_branch" != "main" ]]; then
        handle_error 1 "Releases must be created from main branch (currently on $current_branch)."
    fi

    if ! command -v jq &>/dev/null; then
        log "${LOG_LEVEL_INFO}" "Installing jq..."
        if ! apt-get update && apt-get install -y jq; then
            handle_error 1 "Failed to install jq. Please install it manually."
        fi
    fi

    required_commands=(git tee wget sed awk tr cut mapfile mktemp curl jq basename file)

    for cmd in "${required_commands[@]}"; do
        # Verify that a program exist
        if command -v "$cmd" &>/dev/null; then
            log "${LOG_LEVEL_INFO}" "$cmd does exist!"
        else
            handle_error 1 "Error: $cmd does not exist!"
        fi
    done

    echo "===== Setup Environment Variables ======"

    required_env_vars=(GH_TOKEN GIT_AUTHOR_EMAIL GPG_PRIVATE_KEY GPG_PASSPHRASE GPG_KEY_ID GIT_AUTHOR_NAME USERNAME REPOSITORY_NAME)

    for var in "${required_env_vars[@]}"; do
        # Verify that an environment variable exists
        # Safely check if variable is set
        if [[ -z "${!var:-}" ]]; then
            handle_error 1 "Error: $var is not set!"
        fi
    done

    log "${LOG_LEVEL_INFO}" "All required commands and environment variables are verified! ✔️"
}

build_latest_changelog() {
    # Helper function to format changelog item consistently
    format_changelog_list_item(){
        local scope="$1"
        local message="$2"
        local commit_hash="$3"
        local username="$4"
        local repository_name="$5"

        local list_item_text=""
        if [ -n "$scope" ]; then
            list_item_text="* $scope: $message"
        else
            list_item_text="* $message"
        fi

        local commit_url="https://github.com/$username/$repository_name/commit/$commit_hash"
        echo "$list_item_text ([#$commit_hash]($commit_url))"
    }

    if [[ -z "$latest_tag" ]]; then
        echo "initial commit"
        return 0
    fi

    declare -A sections # Associative array to hold content for each changelog section

    # Initialize all possible section keys to empty string to prevent 'inbound variable' error_message
    # if 'set -u' is active and no commits for a specific type are found
    sections["breaking"]=""
    sections["feat"]=""
    sections["perf"]=""
    sections["fix"]=""
    sections["docs"]=""
    sections["test"]=""
    sections["chore"]=""
    sections["style"]=""
    sections["build"]=""
    sections["ci"]=""
    sections["refactor"]=""
    sections["revert"]=""

    local json_file="data.json"

    while read -r commit; do
        # Extract fields safely
        hash=$(echo "$commit" | jq -r '.hash? // ""')
        type=$(echo "$commit" | jq -r '.type? // ""')
        scope=$(echo "$commit" | jq -r '.scope? // ""')
        message=$(echo "$commit" | jq -r '.message? // ""')
        breaking=$(echo "$commit" | jq -r '.breaking? // "false"')

        local formatted_item
        formatted_item="$(format_changelog_list_item "$scope" "$message" "$hash" "$USERNAME" "$REPOSITORY_NAME")"

        # Handle BREAKING CHANGES separately as they can exist alongside other types
        if [[ "$breaking" == "true" ]]; then
            sections["breaking"]+="$formatted_item\n"
        fi

        # Process other commit types
        case $type in
            "feat"|"perf"|"fix"|"docs"|"test"|"chore"|"style"|"build"|"ci"|"refactor"|"revert")
                    sections["$type"]+="$formatted_item\n"
                ;;
            *)
                # Optionally handle or log unknown commit types
                ;;
        esac

        #
        # TODO:
        #

        # Process body lines with proper array handling
        # body_lines=$(echo "$commit" | jq -c '.body_lines? // []')

        # if [ "$(echo "$body_lines" | jq 'length')" -gt 0 ]; then
        #     echo "$body_lines" | jq -r '.[]' | while read -r line; do
        #         # shellcheck disable=SC1019
        #         # shellcheck disable=SC1020
        #         # shellcheck disable=SC1072
        #         # shellcheck disable=SC1073
        #         [ -n "$line" ] && echo "  - $line"
        #         # TODO:
        #     done
        # else
        #     echo "  (No body content)"
        # fi
        #
        # TODO:
        #
    done < <(jq -c '.data[]' "$json_file")

    local final_release_notes=""

    # Define section titles for a cleaner output
    declare -A section_titles=(
        ["breaking"]="**BREAKING CHANGES**"
        ["feat"]="**Features**"
        ["perf"]="**Performance Improvements**"
        ["fix"]="**Bug Fixes**"
        ["docs"]="**Documentation**"
        ["test"]="**Tests**"
        ["chore"]="**Chores**"
        ["style"]="**Styling**"
        ["build"]="**Build**"
        ["ci"]="**Continuous Integration**"
        ["refactor"]="**Code Refactoring**"
        ["revert"]="**Reverts**"
    )

    # Define the order in which sections should appear in the final changelog
    local section_order=("breaking" "feat" "perf" "fix" "docs" "test" "chore" "style" "build" "ci" "refactor" "revert")

    # Iterate through the defined order and append sections only if they have content
    for sec_type in "${section_order[@]}"; do
        if [ -n "${sections[$sec_type]}" ]; then
            # Remove any trailing newlines from the section content
            local clean_content
            clean_content=$(echo -e "${sections[$sec_type]}" | sed -e 's/[[:space:]]*$//')

            # Only add newline between sections, not extra ones within
            if [ -n "$final_release_notes" ]; then
                final_release_notes+="\n\n"
            fi

            final_release_notes+="${section_titles[$sec_type]}\n\n"
            final_release_notes+="$clean_content" #Content already includes newlines from format_changelog_list_item
        fi
    done

    # Trim any trailing whitespace from the final output
    final_release_notes=$(echo -e "$final_release_notes" | sed -e 's/[[:space:]]*$//')

    # This is like a return value
    echo "$final_release_notes"
}