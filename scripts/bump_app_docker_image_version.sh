#!/bin/bash

set -euo pipefail

# Bump the app Docker image tag (and the short commit hash baked into the pods)
# in the Helm chart's values files. These files are the single source of truth
# for what is deployed: ArgoCD (staging) and Terraform (production) read
# values-<env>.yaml.
#
# A deploy is two pull requests (docs/promotion.md): staging first, production
# after staging is verified. The target decides which files change:
#
#   staging     values-staging.yaml, plus the chart default values.yaml and
#               values-development.yaml, which no live environment reads
#   production  values-production.yaml only
#
# Usage: scripts/bump_app_docker_image_version.sh <new_version> <short_commit_hash> [staging|production]
# Example: scripts/bump_app_docker_image_version.sh 0.9.6-997 a1b2c3d            # staging
#          scripts/bump_app_docker_image_version.sh 0.9.6-997 a1b2c3d production
# This script assumes that the docker image has already been pushed to the registry

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm/automation-calculator"

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 <new_version> <short_commit_hash> [staging|production]"
    exit 1
fi

NEW_VERSION=${1}
NEW_HASH=${2}
TARGET=${3:-staging}

case "${TARGET}" in
    staging)
        VALUES_FILES=(
            "${CHART_DIR}/values.yaml"
            "${CHART_DIR}/values-development.yaml"
            "${CHART_DIR}/values-staging.yaml"
        )
        ;;
    production)
        VALUES_FILES=(
            "${CHART_DIR}/values-production.yaml"
        )
        ;;
    *)
        echo "Unknown target '${TARGET}': expected staging or production"
        exit 1
        ;;
esac

for VALUES_FILE in "${VALUES_FILES[@]}"; do
    ls "${VALUES_FILE}"
done

for VALUES_FILE in "${VALUES_FILES[@]}"; do
    yq -i ".image.tag = \"${NEW_VERSION}\" | .shortCommitHash = \"${NEW_HASH}\"" "${VALUES_FILE}"
done
