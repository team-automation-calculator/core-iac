#!/bin/bash

set -euo pipefail

# Make a branch and a pull request for one half of an app image deploy
# (docs/promotion.md):
#
#   staging (default)  bumps the tag and hash in every values file, including
#                      values-production.yaml. Merging it deploys to staging
#                      (ArgoCD tracks main); production does not move.
#   production         after staging is verified: promotes the main commit
#                      whose values-production.yaml carries this tag, by
#                      moving production's pin (argocd_app_target_revision and
#                      promoted_ref, scripts/promote_to_production.sh addons).
#                      Merging it deploys to production: the production
#                      add-ons workspace applies the pin with no confirm and
#                      ArgoCD syncs automatically.
#
# Usage: scripts/bump_app_docker_image_version_branch.sh <new_version> <short_commit_hash> [staging|production [commit]]
#   commit  production only: the main commit to promote (default: origin/main).
#           Its values-production.yaml must carry <new_version>.

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
    echo "Usage: $0 <new_version> <short_commit_hash> [staging|production [commit]]"
    exit 1
fi

NEW_VERSION=${1}
NEW_HASH=${2}
TARGET=${3:-staging}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/helm/automation-calculator"
ADDONS_DIR="${REPO_ROOT}/terraform/env/production/aws/us-west-1/cluster-addons-layer"

#if branch is not main, warn
if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
    echo "You must be on the main branch to run this script"
    #exit 1
fi

# The staging branch keeps the name it always had, so
# watch_app_docker_image_versions.py still finds an existing bump PR by it.
case "${TARGET}" in
    staging)
        if [ $# -eq 4 ]; then
            echo "A commit argument is only for the production target"
            exit 1
        fi
        BRANCH="bump-app-docker-image-version-${NEW_VERSION}"
        TITLE="Bump app docker image version to ${NEW_VERSION} on staging"
        BODY="Staging half of the ${NEW_VERSION} deploy (docs/promotion.md). Edits every values file, values-production.yaml included; ArgoCD rolls it out to staging after the merge, and production does not move (it renders from the commit pinned in its terraform.tfvars). Production follows in its own pull request once staging is verified: scripts/bump_app_docker_image_version_branch.sh ${NEW_VERSION} ${NEW_HASH} production"
        git checkout -b "${BRANCH}"
        "${SCRIPT_DIR}/bump_app_docker_image_version.sh" "${NEW_VERSION}" "${NEW_HASH}"
        git add "${CHART_DIR}"/values*.yaml
        ;;
    production)
        git fetch origin main
        COMMIT="$(git rev-parse --verify "${4:-origin/main}^{commit}")"
        PROMOTED_TAG="$(git show "${COMMIT}:helm/automation-calculator/values-production.yaml" | yq '.image.tag')"
        if [ "${PROMOTED_TAG}" != "${NEW_VERSION}" ]; then
            echo "values-production.yaml at ${COMMIT:0:7} has image.tag ${PROMOTED_TAG}, not ${NEW_VERSION}:"
            echo "pass the main commit of the verified staging deploy as the fourth argument"
            exit 1
        fi
        BRANCH="bump-app-docker-image-version-${NEW_VERSION}-production"
        TITLE="Promote app docker image version ${NEW_VERSION} to production"
        git checkout -b "${BRANCH}" origin/main
        mkdir -p "${REPO_ROOT}/tmp"
        RANGE_FILE="${REPO_ROOT}/tmp/promote-${NEW_VERSION}.txt"
        "${SCRIPT_DIR}/promote_to_production.sh" addons "${COMMIT}" | tee "${RANGE_FILE}"
        BODY="Production half of the ${NEW_VERSION} deploy (docs/promotion.md): moves production's pin to ${COMMIT:0:7}. Merge only after staging is verified on this image. Merging deploys: the production add-ons workspace applies the pin with no confirm, and ArgoCD syncs the app from that commit by itself. Read the speculative plan first; it should change only the argocd-apps release (the Application's targetRevision) unless other production changes are waiting on main.

What the pin move brings to production:

\`\`\`
$(cat "${RANGE_FILE}")
\`\`\`"
        rm -f "${RANGE_FILE}"
        git add "${ADDONS_DIR}/promoted_ref" "${ADDONS_DIR}/terraform.tfvars"
        ;;
    *)
        echo "Unknown target '${TARGET}': expected staging or production"
        exit 1
        ;;
esac

git commit -m "${TITLE}"
git push origin "${BRANCH}"
gh pr create --title "${TITLE}" --body "${BODY}"
gh pr view --web
