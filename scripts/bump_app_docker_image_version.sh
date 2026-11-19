#!/bin/bash

set -euo pipefail

# This script is used to bump the version of the docker image used by the helm chart/terraform

# Usage: ./bump_app_docker_image_version.sh <new_version> <short_commit_hash>
# Example: ./bump_app_docker_image_version.sh 1.2.3 a1b2c3d
# This script assumes that the docker image has already been pushed to the registry

HELM_VALUES_FILE="../helm/automation-calculator/values.yaml"
DEV_TFVARS="../terraform/env/development/aws/us-west-1/cluster-addons-layer/terraform.tfvars"
STAGING_TFVARS="../terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars"
PROD_TFVARS="../terraform/env/production/aws/us-west-1/cluster-addons-layer/terraform.tfvars"

if [ $# -ne 2 ]; then
    echo "Usage: $0 <new_version> <short_commit_hash>"
    exit 1
fi

NEW_VERSION=${1}
NEW_HASH=${2}

ls ${HELM_VALUES_FILE}
ls ${DEV_TFVARS}
ls ${STAGING_TFVARS}
ls ${PROD_TFVARS}

YQ_EXPRESSION=".image.tag=\"${NEW_VERSION}\""

yq -i ${HELM_VALUES_FILE} --expression ${YQ_EXPRESSION}

# Rewrite each app_version line whatever it currently holds. The environments
# are pinned per env and can differ from each other and from values.yaml, so
# replacing the old values.yaml tag would skip any env on a different tag
# while still changing its short_commit_hash.
for TFVARS_FILE in "${DEV_TFVARS}" "${STAGING_TFVARS}" "${PROD_TFVARS}"; do
    sed -i '' -E "s/^(app_version[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\1\"${NEW_VERSION}\"/" "${TFVARS_FILE}"
    sed -i '' -E "s/^(short_commit_hash[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\1\"${NEW_HASH}\"/" "${TFVARS_FILE}"

    grep -q "^app_version[[:space:]]*=[[:space:]]*\"${NEW_VERSION}\"" "${TFVARS_FILE}" \
        || { echo "app_version was not set to ${NEW_VERSION} in ${TFVARS_FILE}" >&2; exit 1; }
    grep -q "^short_commit_hash[[:space:]]*=[[:space:]]*\"${NEW_HASH}\"" "${TFVARS_FILE}" \
        || { echo "short_commit_hash was not set to ${NEW_HASH} in ${TFVARS_FILE}" >&2; exit 1; }
done
