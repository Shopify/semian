#!/bin/bash

# Script to update CHANGELOG.md with commits since the last tag
# Filters out dependabot commits, merge commits, and version bump commits
# Usage: update_changelog.sh <new_version> <current_version>

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check arguments
if [[ $# -ne 2 ]]; then
    echo -e "${RED}Error: Please provide both new version and current version as arguments${NC}"
    echo "Usage: $0 <new_version> <current_version>"
    echo "Example: $0 1.2.0 1.1.0"
    exit 1
fi

NEW_VERSION="$1"
CURRENT_VERSION="$2"

echo -e "${GREEN}Updating changelog from v$CURRENT_VERSION to v$NEW_VERSION${NC}"

# Get commits since the current version tag, excluding merges
COMMITS=$(git log --oneline --no-merges "v${CURRENT_VERSION}..HEAD" --pretty=format:"%s")

if [[ -z "$COMMITS" ]]; then
    echo -e "${YELLOW}No new commits since v$CURRENT_VERSION${NC}"
    exit 0
fi

echo -e "${GREEN}Found commits since v$CURRENT_VERSION${NC}"

# Filter out unwanted commits
FILTERED_COMMITS=""
while IFS= read -r commit; do
    # Skip empty lines
    [[ -z "$commit" ]] && continue
    
    # Skip dependabot commits (format: "Bump .. from x to y")
    if [[ "$commit" =~ ^Bump[[:space:]].+[[:space:]]from[[:space:]].+[[:space:]]to[[:space:]].+ ]]; then
        echo -e "${YELLOW}Skipping dependabot commit: $commit${NC}"
        continue
    fi
    
    # Skip version bump commits (format: "bump version to <version>" - case insensitive)
    if [[ "$commit" =~ ^[Bb]ump[[:space:]]version[[:space:]]to[[:space:]].+ ]]; then
        echo -e "${YELLOW}Skipping version bump commit: $commit${NC}"
        continue
    fi
        
    # Add to filtered commits
    if [[ -z "$FILTERED_COMMITS" ]]; then
        FILTERED_COMMITS="* $commit"
    else
        FILTERED_COMMITS="$FILTERED_COMMITS"$'\n'"* $commit"
    fi
done <<< "$COMMITS"

if [[ -z "$FILTERED_COMMITS" ]]; then
    echo -e "${YELLOW}No valid commits to add to changelog after filtering${NC}"
    exit 0
fi

echo -e "${GREEN}Creating changelog entry for version $NEW_VERSION${NC}"

# Create temporary file with new changelog content
TEMP_FILE=$(mktemp)

# Add new version header and commits
echo "# v$NEW_VERSION" > "$TEMP_FILE"
echo "" >> "$TEMP_FILE"
printf "%s\n" "$FILTERED_COMMITS" >> "$TEMP_FILE"
echo "" >> "$TEMP_FILE"

# Append existing changelog content
cat CHANGELOG.md >> "$TEMP_FILE"

# Replace the original file
mv "$TEMP_FILE" CHANGELOG.md

echo -e "${GREEN}Successfully updated CHANGELOG.md with $NEW_VERSION${NC}"
echo -e "${GREEN}Added the following commits:${NC}"
echo "$FILTERED_COMMITS"