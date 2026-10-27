#!/bin/bash

set -euo pipefail

# Bump the app Docker image tag (and the short commit hash baked into the pods)
# in the Helm chart's values files. These files are the single source of truth
# for what is deployed: Terraform reads values-<env>.yaml at release time and
# ArgoCD will read the same files once the migration lands.

# Usage: ./bump_app_docker_image_version.sh <new_version> <short_commit_hash>
# Example: ./bump_app_docker_image_version.sh 1.2.3 a1b2c3d
# This script assumes that the docker image has already been pushed to the registry

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm/automation-calculator"
VALUES_FILES=(
    "${CHART_DIR}/values.yaml"
    "${CHART_DIR}/values-development.yaml"
    "${CHART_DIR}/values-staging.yaml"
    "${CHART_DIR}/values-production.yaml"
)

if [ $# -ne 2 ]; then
    echo "Usage: $0 <new_version> <short_commit_hash>"
    exit 1
fi

NEW_VERSION=${1}
NEW_HASH=${2}

for VALUES_FILE in "${VALUES_FILES[@]}"; do
    ls "${VALUES_FILE}"
done

for VALUES_FILE in "${VALUES_FILES[@]}"; do
    yq -i ".image.tag = \"${NEW_VERSION}\" | .shortCommitHash = \"${NEW_HASH}\"" "${VALUES_FILE}"
done
