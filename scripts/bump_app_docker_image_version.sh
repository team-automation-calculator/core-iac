#!/bin/bash

set -euo pipefail

# This script is used to bump the version of the docker image used by the helm chart/terraform

# Usage: ./bump_app_docker_image_version.sh <new_version>
# Example: ./bump_app_docker_image_version.sh 1.2.3
# This script assumes that the docker image has already been pushed to the registry

HELM_VALUES_FILE="../helm/automation-calculator/values.yaml"
TERRAFORM_APP_MODULE_VARIABLES_FILE="../terraform/modules/aws/main_rails_app/variables.tf"
NEW_VERSION=${1}

if [ $# -ne 1 ]; then
    echo "Usage: $0 <new_version>"
    exit 1
fi

ls ${HELM_VALUES_FILE}
ls ${TERRAFORM_APP_MODULE_VARIABLES_FILE}

YQ_EXPRESSION=".image.tag=\"${NEW_VERSION}\""

OLD_TAG_VALUE=$(yq -r .image.tag ${HELM_VALUES_FILE})

yq -i ${HELM_VALUES_FILE} --expression ${YQ_EXPRESSION}

sed -i -e "s/${OLD_TAG_VALUE}/${NEW_VERSION}/g" ${TERRAFORM_APP_MODULE_VARIABLES_FILE}
