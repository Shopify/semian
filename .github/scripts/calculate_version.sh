#!/bin/bash

# Script to calculate new version based on current version and release type
# Usage: calculate_version.sh <current_version> <release_type>

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <current_version> <release_type>"
    echo "Example: $0 1.2.3 minor"
    echo "Release types: major, minor, patch"
    exit 1
fi

CURRENT_VERSION="$1"
RELEASE_TYPE="$2"

echo "Calculating new version from $CURRENT_VERSION using $RELEASE_TYPE bump"

# Validate release type
case $RELEASE_TYPE in
    "major"|"minor"|"patch")
        ;;
    *)
        echo "Error: Invalid release type '$RELEASE_TYPE'. Must be major, minor, or patch."
        exit 1
        ;;
esac

# Parse current version
IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"

# Validate version components are numbers
if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]] || ! [[ "$patch" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid version format '$CURRENT_VERSION'. Expected format: x.y.z"
    exit 1
fi

# Increment based on release type
case $RELEASE_TYPE in
    "major")
        major=$((major + 1))
        minor=0
        patch=0
        ;;
    "minor")
        minor=$((minor + 1))
        patch=0
        ;;
    "patch")
        patch=$((patch + 1))
        ;;
esac

NEW_VERSION="$major.$minor.$patch"
echo "New version: $NEW_VERSION"

# Output for GitHub Actions
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "version=$NEW_VERSION" >> "$GITHUB_OUTPUT"
fi
