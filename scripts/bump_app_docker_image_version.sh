#!/bin/bash

set -euo pipefail

# This script is used to bump the version of the docker image used by the helm chart/terraform

# Usage: ./bump_app_docker_image_version.sh <new_version>
# Example: ./bump_app_docker_image_version.sh 1.2.3
# This script assumes that the docker image has already been pushed to the registry

HELM_VALUES_FILE="../helm/automation-calculator/values.yaml"
DEV_TFVARS="../terraform/env/development/aws/us-west-1/cluster-addons-layer/terraform.tfvars"
STAGING_TFVARS="../terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars"
PROD_TFVARS="../terraform/env/production/aws/us-west-1/cluster-addons-layer/terraform.tfvars"
NEW_VERSION=${1}

if [ $# -ne 1 ]; then
    echo "Usage: $0 <new_version>"
    exit 1
fi

ls ${HELM_VALUES_FILE}
ls ${DEV_TFVARS}
ls ${STAGING_TFVARS}
ls ${PROD_TFVARS}

YQ_EXPRESSION=".image.tag=\"${NEW_VERSION}\""

OLD_TAG_VALUE=$(yq -r .image.tag ${HELM_VALUES_FILE})

yq -i ${HELM_VALUES_FILE} --expression ${YQ_EXPRESSION}

for TFVARS_FILE in "${DEV_TFVARS}" "${STAGING_TFVARS}" "${PROD_TFVARS}"; do
    sed -i '' "s/${OLD_TAG_VALUE}/${NEW_VERSION}/g" "${TFVARS_FILE}"
done
