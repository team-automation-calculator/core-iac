#!/bin/bash

set -euo pipefail

# This script is used to make a branch and PR to bump the version of the docker image used by the helm chart

if [ $# -ne 2 ]; then
    echo "Usage: $0 <new_version> <short_commit_hash>"
    exit 1
fi

NEW_VERSION=${1}
NEW_HASH=${2}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm/automation-calculator"

#if branch is not main, exit
if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
    echo "You must be on the main branch to run this script"
    #exit 1
fi

#make new branch from NEW_VERSION arg
git checkout -b bump-app-docker-image-version-${NEW_VERSION}

#call bump_app_docker_image_version.sh
"${SCRIPT_DIR}/bump_app_docker_image_version.sh" ${NEW_VERSION} ${NEW_HASH}

#commit changes
git add "${CHART_DIR}/values.yaml"
git add "${CHART_DIR}/values-development.yaml"
git add "${CHART_DIR}/values-staging.yaml"
git add "${CHART_DIR}/values-production.yaml"

git commit -m "Bump app docker image version to ${NEW_VERSION}"

#push
git push origin bump-app-docker-image-version-${NEW_VERSION}

#make PR
gh pr create --title "Bump app docker image version to ${NEW_VERSION}" --body ""

#show PR
gh pr view --web
