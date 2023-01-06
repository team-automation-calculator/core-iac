#!/bin/bash

set -euo pipefail

export target_cluster=$(aws eks list-clusters | jq -r ".clusters[0]")
echo "Deleting ${target_cluster}"
export target_nodegroup=$(aws eks list-nodegroups --cluster-name $target_cluster | jq -r ".nodegroups[0]")
echo "Deleting $target_nodegroup"
aws eks delete-nodegroup --cluster-name $target_cluster --nodegroup-name $target_nodegroup
aws eks delete-cluster --name $target_cluster
unset target_cluster
