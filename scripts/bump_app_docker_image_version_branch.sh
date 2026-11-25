#!/bin/bash

set -euo pipefail

# Make a branch and a pull request that bump the app Docker image for one
# target: staging (the default) or production. A deploy is two pull requests
# (docs/promotion.md): the staging one first, the production one after staging
# is verified. Merging the production pull request deploys to production; the
# production Terraform Cloud workspace applies without a confirm.
#
# Usage: scripts/bump_app_docker_image_version_branch.sh <new_version> <short_commit_hash> [staging|production]

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 <new_version> <short_commit_hash> [staging|production]"
    exit 1
fi

NEW_VERSION=${1}
NEW_HASH=${2}
TARGET=${3:-staging}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm/automation-calculator"

# The staging branch keeps the name it always had, so
# watch_app_docker_image_versions.py still finds an existing bump PR by it.
case "${TARGET}" in
    staging)
        BRANCH="bump-app-docker-image-version-${NEW_VERSION}"
        BODY="Staging half of the ${NEW_VERSION} deploy (docs/promotion.md). ArgoCD rolls it out to staging after the merge. Production follows in its own pull request once staging is verified: scripts/bump_app_docker_image_version_branch.sh ${NEW_VERSION} ${NEW_HASH} production"
        ;;
    production)
        BRANCH="bump-app-docker-image-version-${NEW_VERSION}-production"
        BODY="Production half of the ${NEW_VERSION} deploy (docs/promotion.md). Merge only after staging is verified on this image: the production workspace applies on merge, with no confirm. Read the speculative plan on this pull request first; it shows everything the merge will apply, including shared module or chart changes merged since production last ran."
        ;;
    *)
        echo "Unknown target '${TARGET}': expected staging or production"
        exit 1
        ;;
esac

#if branch is not main, exit
if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
    echo "You must be on the main branch to run this script"
    #exit 1
fi

#make new branch from NEW_VERSION arg
git checkout -b "${BRANCH}"

#call bump_app_docker_image_version.sh
"${SCRIPT_DIR}/bump_app_docker_image_version.sh" "${NEW_VERSION}" "${NEW_HASH}" "${TARGET}"

#commit changes: only values files can have changed
git add "${CHART_DIR}"/values*.yaml

git commit -m "Bump app docker image version to ${NEW_VERSION} on ${TARGET}"

#push
git push origin "${BRANCH}"

#make PR
gh pr create --title "Bump app docker image version to ${NEW_VERSION} on ${TARGET}" --body "${BODY}"

#show PR
gh pr view --web
