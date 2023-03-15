#!/bin/bash

set -euo pipefail

# This script is used to make a branch and PR to bump the version of the docker image used by the helm chart/terraform

NEW_VERSION=${1}

if [ $# -ne 1 ]; then
    echo "Usage: $0 <new_version>"
    exit 1
fi

#if branch is not main, exit
if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
    echo "You must be on the main branch to run this script"
    #exit 1
fi

#make new branch from NEW_VERSION arg
git checkout -b bump-app-docker-image-version-${NEW_VERSION}

#call bump_app_docker_image_version.sh
./bump_app_docker_image_version.sh ${NEW_VERSION}

#commit changes
git add .
git commit -m "Bump app docker image version to ${NEW_VERSION}"

#push
git push origin bump-app-docker-image-version-${NEW_VERSION}

#make PR
hub pull-request -m "Bump app docker image version to ${NEW_VERSION}"

#show PR
hub pr show
