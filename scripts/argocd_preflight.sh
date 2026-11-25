#!/bin/bash

# ArgoCD migration Phase 0 preflight (docs/argocd-migration-plan.md).
#
# Read-only. Against the current kubeconfig context it prints:
#   - allocatable pods per node (and the instance type)
#   - the cluster-wide pod count (non-terminal pods, which are what count
#     against the kubelet's max-pods; the raw `get pods -A` count is shown too)
#   - the headroom left after adding ArgoCD's pods (4 by default: application
#     controller, repo-server, server, redis). ArgoCD pods already running in
#     ARGOCD_NAMESPACE are part of the pod count, so only the ones still to
#     come are subtracted: the script gives the same answer before the Phase 2
#     install and after it.
#   - the aws-load-balancer-controller replica count
#   - whether the helm and argocd CLIs are installed
#
# Exits non-zero if the headroom is below ARGOCD_PODS or a required CLI is
# missing. Only `kubectl get` is used; nothing is written to the cluster.
#
# Usage:
#   eval "$(scripts/infra_eng_sso.py up --environment staging)"
#   scripts/argocd_preflight.sh
#
# Environment:
#   ARGOCD_PODS       pods a full ArgoCD install runs (default 4)
#   ARGOCD_NAMESPACE  namespace ArgoCD is installed into (default argocd)
#   ALB_DEPLOY        ALB controller Deployment name (default aws-load-balancer-controller)
#   ALB_NAMESPACE     ALB controller namespace (default kube-system)

set -euo pipefail

ARGOCD_PODS="${ARGOCD_PODS:-4}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ALB_DEPLOY="${ALB_DEPLOY:-aws-load-balancer-controller}"
ALB_NAMESPACE="${ALB_NAMESPACE:-kube-system}"

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is not installed; nothing to check." >&2
  exit 1
fi

context="$(kubectl config current-context)"
echo "Context: ${context}"
echo

echo "Nodes (name, allocatable pods, instance type):"
node_rows="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.pods}{"\t"}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}')"
if [ -z "${node_rows}" ]; then
  echo "No nodes returned by the API server." >&2
  exit 1
fi
printf '%s\n' "${node_rows}" | awk -F'\t' 'NF { printf "  %-45s %4s  %s\n", $1, $2, $3 }'

node_count="$(printf '%s\n' "${node_rows}" | awk 'NF { n++ } END { print n + 0 }')"
allocatable_total="$(printf '%s\n' "${node_rows}" | awk -F'\t' 'NF { s += $2 } END { print s + 0 }')"

# Terminal pods (Succeeded/Failed) do not count toward max-pods, so count
# only the ones that do. The raw count matches the plan's one-liner.
active_pods="$(kubectl get pods -A --no-headers --field-selector=status.phase!=Succeeded,status.phase!=Failed | awk 'NF { n++ } END { print n + 0 }')"
all_pods="$(kubectl get pods -A --no-headers | awk 'NF { n++ } END { print n + 0 }')"

# ArgoCD pods that already run are inside active_pods; subtracting all of
# ARGOCD_PODS again would count them twice once Phase 2 has installed ArgoCD.
# A missing namespace lists as zero pods.
argocd_running="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods --no-headers --field-selector=status.phase!=Succeeded,status.phase!=Failed 2>/dev/null | awk 'NF { n++ } END { print n + 0 }')"
argocd_to_add=$((ARGOCD_PODS - argocd_running))
if [ "${argocd_to_add}" -lt 0 ]; then
  argocd_to_add=0
fi

headroom=$((allocatable_total - active_pods - argocd_to_add))

echo
echo "Nodes:                         ${node_count}"
echo "Allocatable pods (all nodes):  ${allocatable_total}"
echo "Pods now (non-terminal):       ${active_pods}  (raw kubectl get pods -A count: ${all_pods})"
echo "ArgoCD pods already running:   ${argocd_running}  (namespace ${ARGOCD_NAMESPACE})"
echo "ArgoCD pods to add:            ${argocd_to_add}  (of ${ARGOCD_PODS})"
echo "Headroom after ArgoCD:         ${headroom}"

if [ "${headroom}" -lt "${ARGOCD_PODS}" ]; then
  fail "headroom after ArgoCD (${headroom}) is below ${ARGOCD_PODS} pods. Raise desired_size or set the ALB controller replicaCount to 1 (see docs/argocd-phase-0-preflight.md)."
fi

echo
alb_replicas="$(kubectl -n "${ALB_NAMESPACE}" get deploy "${ALB_DEPLOY}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
if [ -z "${alb_replicas}" ]; then
  echo "ALB controller Deployment ${ALB_NAMESPACE}/${ALB_DEPLOY}: not found"
else
  echo "ALB controller replicas:       ${alb_replicas}"
  if [ "${node_count}" -eq 1 ] && [ "${alb_replicas}" -gt 1 ]; then
    echo "  note: ${alb_replicas} replicas on a single node buy no availability; replicaCount=1 frees $((alb_replicas - 1)) pod slot(s)."
  fi
fi

echo
echo "CLIs:"
for cli in helm argocd; do
  if command -v "${cli}" >/dev/null 2>&1; then
    printf '  %-8s %s\n' "${cli}" "$(command -v "${cli}")"
  else
    printf '  %-8s MISSING (brew install %s)\n' "${cli}" "${cli}"
    fail "${cli} CLI is not installed"
  fi
done

echo
if [ "${failures}" -gt 0 ]; then
  echo "Preflight FAILED (${failures} problem(s))."
  exit 1
fi
echo "Preflight OK."
