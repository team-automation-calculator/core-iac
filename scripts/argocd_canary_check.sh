#!/bin/bash

# ArgoCD migration Phase 3 (docs/argocd-phase-3-dry-run.md): the "real
# namespace is untouched" check, run before and after each exercise step.
#
# Read-only. Against the current kubeconfig context it prints:
#   - the real app namespace (automation-calculator): Deployment generation,
#     observedGeneration, image and resourceVersion; Ingress resourceVersion;
#     Secret resourceVersion and a sha256 over its sorted data keys/values
#   - the canary namespace (argocd-canary): Deployments, Services, Secrets and
#     pods, or a note that the namespace does not exist
#   - the ac-canary Application's sync and health status, if it exists
#
# The real-namespace numbers must be identical before and after every step of
# the dry run. Only `kubectl get` is used; nothing is written to the cluster.
#
# Usage:
#   eval "$(scripts/infra_eng_sso.py up --environment staging)"
#   scripts/argocd_canary_check.sh                          # print
#   scripts/argocd_canary_check.sh > tmp/canary-before.txt  # keep a copy to diff
#
# Environment:
#   APP_NAMESPACE     real app namespace (default automation-calculator)
#   APP_DEPLOYMENT    real Deployment / Ingress name (default automation-calculator)
#   APP_SECRET        real Secret name (default automation-calculator-app-secrets)
#   CANARY_NAMESPACE  canary namespace (default argocd-canary)
#   CANARY_APP        canary Application name in the argocd namespace (default ac-canary)
#   ARGOCD_NAMESPACE  namespace ArgoCD runs in (default argocd)

set -euo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-automation-calculator}"
APP_DEPLOYMENT="${APP_DEPLOYMENT:-automation-calculator}"
APP_SECRET="${APP_SECRET:-automation-calculator-app-secrets}"
CANARY_NAMESPACE="${CANARY_NAMESPACE:-argocd-canary}"
CANARY_APP="${CANARY_APP:-ac-canary}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is not installed; nothing to check." >&2
  exit 1
fi

sha256() {
  # shasum ships with macOS; sha256sum with coreutils.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    sha256sum | awk '{ print $1 }'
  fi
}

echo "Context: $(kubectl config current-context)"
echo "Time:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

echo "Real namespace ${APP_NAMESPACE} (must not change during the dry run):"
if ! kubectl get namespace "${APP_NAMESPACE}" >/dev/null 2>&1; then
  echo "  namespace not found" >&2
  exit 1
fi

deploy_row="$(kubectl -n "${APP_NAMESPACE}" get deploy "${APP_DEPLOYMENT}" \
  -o jsonpath='{.metadata.generation}{"\t"}{.status.observedGeneration}{"\t"}{.spec.template.spec.containers[0].image}{"\t"}{.metadata.resourceVersion}{"\t"}{.metadata.creationTimestamp}' 2>/dev/null || true)"
if [ -z "${deploy_row}" ]; then
  echo "  Deployment ${APP_DEPLOYMENT}: not found"
else
  printf '%s\n' "${deploy_row}" | awk -F'\t' -v name="${APP_DEPLOYMENT}" '{
    printf "  Deployment %s\n", name
    printf "    generation:          %s (observed %s)\n", $1, $2
    printf "    image:               %s\n", $3
    printf "    resourceVersion:     %s\n", $4
    printf "    created:             %s\n", $5
  }'
fi

ingress_rv="$(kubectl -n "${APP_NAMESPACE}" get ingress "${APP_DEPLOYMENT}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)"
if [ -z "${ingress_rv}" ]; then
  echo "  Ingress ${APP_DEPLOYMENT}: not found"
else
  echo "  Ingress ${APP_DEPLOYMENT}"
  echo "    resourceVersion:     ${ingress_rv}"
fi

secret_rv="$(kubectl -n "${APP_NAMESPACE}" get secret "${APP_SECRET}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)"
if [ -z "${secret_rv}" ]; then
  echo "  Secret ${APP_SECRET}: not found"
else
  # go-template ranges over a map in key order, so the digest is stable. The
  # values are the base64 data, never decoded or printed.
  secret_sha="$(kubectl -n "${APP_NAMESPACE}" get secret "${APP_SECRET}" \
    -o go-template='{{range $k, $v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' | sha256)"
  secret_keys="$(kubectl -n "${APP_NAMESPACE}" get secret "${APP_SECRET}" \
    -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}')"
  echo "  Secret ${APP_SECRET}"
  echo "    resourceVersion:     ${secret_rv}"
  echo "    data sha256:         ${secret_sha}"
  echo "    keys:                ${secret_keys}"
fi

echo
echo "Canary namespace ${CANARY_NAMESPACE}:"
if ! kubectl get namespace "${CANARY_NAMESPACE}" >/dev/null 2>&1; then
  echo "  namespace does not exist"
else
  ns_phase="$(kubectl get namespace "${CANARY_NAMESPACE}" -o jsonpath='{.status.phase}')"
  echo "  namespace phase: ${ns_phase}"
  kubectl -n "${CANARY_NAMESPACE}" get deploy,svc,secret,pods -o wide 2>&1 | sed 's/^/  /'
fi

echo
echo "Application ${ARGOCD_NAMESPACE}/${CANARY_APP}:"
app_row="$(kubectl -n "${ARGOCD_NAMESPACE}" get application.argoproj.io "${CANARY_APP}" \
  -o jsonpath='{.spec.source.targetRevision}{"\t"}{.status.sync.status}{"\t"}{.status.sync.revision}{"\t"}{.status.health.status}{"\t"}{.status.operationState.phase}' 2>/dev/null || true)"
if [ -z "${app_row}" ]; then
  echo "  not found"
else
  printf '%s\n' "${app_row}" | awk -F'\t' '{
    printf "  targetRevision:        %s\n", $1
    printf "  sync:                  %s (%s)\n", $2, substr($3, 1, 12)
    printf "  health:                %s\n", $4
    printf "  last operation:        %s\n", $5
  }'
fi
