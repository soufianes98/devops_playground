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
source ".github/scripts/utils.sh"

update_version(){
    if [[ -z $latest_tag ]]; then
        return 0
    fi

    find_text="version: $latest_tag"
    replace_text="version: $next_tag"

    # Syntax: "s/pattern/replacement/g"
    sed -i "s/$find_text/$replace_text/g" "config.yaml"
    git add config.yaml

    commit_message="chore: bump version to $next_tag [no ci]"
    git commit -S -m "$commit_message"
    git log --show-signature
}

# NOTE: Always publish changelog before creating a new tag
publish_changelog() {
    echo "===== Publish changelog ======"

    git add CHANGELOG.md
    commit_message="chore(release): update changelog for v$next_tag"
    git commit -S -m "$commit_message"
    git log --show-signature
    git push

    log_info "Changelog successfully published"
}

publish_github_tag() {
    echo "===== Create a new Github tag ======"

    # Create a signed and annotated git tag
    git tag -s -a "v$next_tag" -m "Release version $next_tag"

    # Verify signed tag
    # git tag -v "v$next_tag"

    message="The tag has been successfully published 🎉"

    # Push the tag to remote
    git push origin "v$next_tag" && log_info "$message"

    # Show the tag details
    git show "v$next_tag"

    # Wait for the tag to be available on GitHub
    sleep 10s

    log_info "Tag v$next_tag pushed successfully to remote repository"
}

publish_github_release() {
    echo "===== Create a new Github release ======"

    upload_artifacts(){
        echo "===== Upload artifacts to a Github release ======"
        IFS=' ' read -r -a ARTIFACTS_PATHS <<< "$ARTIFACTS_PATHS_STR"

        if [[ -z "${ARTIFACTS_PATHS:-}" ]]; then
            log_warning "No artifacts to upload"
            return 0
        fi

        RELEASE_ID=$1

        log_info "Uploading artifacts for the latest release"

        for artifact_path in "${ARTIFACTS_PATHS[@]}"; do
            # Check if the artifact exists
            if [[ -f "$artifact_path" ]]; then
                log_info "Found artifact: $artifact_path"
            else
                handle_error 1 "Artifact not found: $artifact_path"
            fi

            # Extract filename from the path
            artifact_filename=$(basename "$artifact_path")
            # Get the MIME type dynamically
            mime_type=$(file -b --mime-type "$artifact_path")
            upload_url="https://uploads.github.com/repos/$USERNAME/$REPOSITORY_NAME/releases/$RELEASE_ID/assets?name=$artifact_filename"

            log_info "Uploading $artifact_path..."

            HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
                -L \
                -X POST \
                -H "Authorization: Bearer $GH_TOKEN" \
                -H "Content-Type: $mime_type" \
                --data-binary @"$artifact_path" \
                "$upload_url"
                ) || {
                    handle_error 1 "Failed to upload $artifact_filename"
                }

            HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)
            HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n 1)

            if [[ "$HTTP_STATUS" -ne 201 ]]; then
                handle_error 1 "Failed to upload: $artifact_filename (Status: $HTTP_STATUS)"

                continue # Skip t handle_error 1 "Response: $(echo "$HTTP_BODY" | jq . 2>/dev/null || echo "$HTTP_BODY")"o the next artifact
            fi

            log_info "- $artifact_path file uploaded successfully."
        done

        log_info "All artifacts were uploaded successfully."
    }

    # TODO: Before publishing a release check if the git tag is published to github
    # First check if the remote tag is pushed and available in github
    # git ls-remote --tags origin
    if ! git ls-remote --tags origin "v$next_tag" | grep -q "v$next_tag"; then
        handle_error 1 "Tag v$next_tag not found on remote. Push the tag first."
    fi

    # https://www.lucavall.in/blog/how-to-create-a-release-with-multiple-artifacts-from-a-github-actions-workflow-using-the-matrix-strategy
    # https://chatgpt.com/share/7a299605-4d36-48c0-9b5f-edbf8f055d01

    log_info "Creating release for tag v$next_tag (pre-release: $is_pre_release)"

    local release_notes
    release_notes=$(build_latest_changelog)

    log_info "release_notes: $release_notes"

    escaped_release_notes=$(jq -n --arg notes "$release_notes" '$notes')
    read -r -d '' JSON_PAYLOAD <<EOF || true
{
  "tag_name": "v$next_tag",
  "target_commitish": "main",
  "name": "v$next_tag",
  "body": $escaped_release_notes,
  "draft": false,
  "prerelease": $is_pre_release,
  "generate_release_notes": false
}
EOF

    # Create a new release
    HTTP_RESPONSE=$(
        curl -s -w "\n%{http_code}" \
            -L \
            -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            https://api.github.com/repos/"$USERNAME"/"$REPOSITORY_NAME"/releases \
            -d "$JSON_PAYLOAD"
    ) || {
        handle_error 1 "Failed to make an API request to GitHub"
    }

    HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)   # All except last 3 chars
    HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n 1) # Last 3 chars

    if [[ "$HTTP_STATUS" -ne 201 ]]; then
        handle_error 1 "Failed to create a new release in GitHub, HTTP status $HTTP_STATUS"
        echo "$HTTP_BODY" | jq '.message, .errors' 2>/dev/null || echo "$HTTP_BODY"
    fi

    RELEASE_ID=$(echo "$HTTP_BODY" | jq -r '.id')
    if [[ -z "$RELEASE_ID" || "$RELEASE_ID" == "null" ]]; then
        handle_error 1 "ERROR: Release ID missing in response"
    fi

    log_info "Release created with ID: $RELEASE_ID"
    upload_artifacts "$RELEASE_ID"

    # Then check the response status code is 201 (created) to make sure the release is published in github
    # And also print the release info and maybe export it to a service using jq command and curl
    # and display a message to confirm that the release is published to github
    # like
    log_info "Release published successfully! 🎉"
}

setup_git
update_version
publish_changelog
publish_github_tag
publish_github_release
