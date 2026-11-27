#!/bin/bash

set -euo pipefail

# Bump the app Docker image tag (and the short commit hash baked into the pods)
# in every Helm values file: the chart default values.yaml and
# values-<env>.yaml for development, staging and production.
#
# A deploy is two pull requests (docs/promotion.md). This edit is the first:
# staging's ArgoCD Application tracks main and deploys it on merge.
# Production's Application renders from the commit pinned in production's
# terraform.tfvars, so values-production.yaml changes here but production
# does not move until the second pull request promotes a commit that contains
# the change (bump_app_docker_image_version_branch.sh <tag> <hash> production,
# or scripts/promote_to_production.sh addons <commit>). values-production.yaml
# on main is therefore what production runs next, not what it runs now.
#
# Usage: scripts/bump_app_docker_image_version.sh <new_version> <short_commit_hash>
# Example: scripts/bump_app_docker_image_version.sh 0.9.6-997 a1b2c3d
# This script assumes that the docker image has already been pushed to the registry

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm/automation-calculator"

if [ $# -eq 3 ] && [ "${3}" = "staging" ]; then
    set -- "${1}" "${2}"
fi
if [ $# -eq 3 ] && [ "${3}" = "production" ]; then
    echo "Production is no longer bumped by editing values-production.yaml: the staging bump"
    echo "already did, and production deploys when a pull request promotes that commit:"
    echo "  scripts/bump_app_docker_image_version_branch.sh ${1} ${2} production"
    exit 1
fi
if [ $# -ne 2 ]; then
    echo "Usage: $0 <new_version> <short_commit_hash>"
    exit 1
fi

NEW_VERSION=${1}
NEW_HASH=${2}

VALUES_FILES=(
    "${CHART_DIR}/values.yaml"
    "${CHART_DIR}/values-development.yaml"
    "${CHART_DIR}/values-staging.yaml"
    "${CHART_DIR}/values-production.yaml"
)

for VALUES_FILE in "${VALUES_FILES[@]}"; do
    ls "${VALUES_FILE}"
done

for VALUES_FILE in "${VALUES_FILES[@]}"; do
    yq -i ".image.tag = \"${NEW_VERSION}\" | .shortCommitHash = \"${NEW_HASH}\"" "${VALUES_FILE}"
done
