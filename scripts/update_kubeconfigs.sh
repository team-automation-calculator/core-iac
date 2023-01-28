#!/bin/bash

set -euo pipefail

# This script updates kubeconfigs for all clusters in the current AWS account
for cluster in $(aws eks list-clusters | jq -r .clusters[]); do
  aws eks update-kubeconfig --name $cluster
done
