#!/usr/bin/env bash
# Wait for a kube-system add-on Deployment to roll out a new revision, then
# print its readiness and container resources. Used to validate a
# cluster-addons-layer apply (e.g. a TFC auto-apply after merging to main).
#
# Usage: scripts/watch_addon_rollout.sh KUBE_CONTEXT DEPLOYMENT BASELINE_GENERATION [TIMEOUT_SECONDS]
#
# Polls until .metadata.generation differs from BASELINE_GENERATION (the value
# observed before the change was merged), then runs `kubectl rollout status`
# and prints the deployment's generation, ready replicas, and resources.
# Exits non-zero on timeout or a failed rollout.
set -euo pipefail

context="${1:?kube context required}"
deployment="${2:?deployment name required}"
baseline_generation="${3:?baseline generation required}"
timeout_seconds="${4:-1500}"
namespace="kube-system"
interval=15

kc() { kubectl --context "$context" -n "$namespace" "$@"; }

elapsed=0
while true; do
  generation="$(kc get deploy "$deployment" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")"
  if [ -n "$generation" ] && [ "$generation" != "$baseline_generation" ]; then
    echo "$deployment generation $baseline_generation -> $generation after ${elapsed}s"
    break
  fi
  if [ "$elapsed" -ge "$timeout_seconds" ]; then
    echo "TIMEOUT: $deployment still at generation $baseline_generation after ${elapsed}s"
    exit 1
  fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

if ! kc rollout status "deploy/$deployment" --timeout=300s; then
  echo "ROLLOUT FAILED: $deployment"
  kc get pods -l "app.kubernetes.io/name=$deployment" -o wide
  exit 1
fi

kc get deploy "$deployment" -o 'custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,GEN:.metadata.generation,CPU_REQ:.spec.template.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.template.spec.containers[0].resources.requests.memory,CPU_LIM:.spec.template.spec.containers[0].resources.limits.cpu,MEM_LIM:.spec.template.spec.containers[0].resources.limits.memory'
kc get pods -l "app.kubernetes.io/name=$deployment" -o wide
