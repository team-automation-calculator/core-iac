#!/bin/bash

# ArgoCD migration Phase 7 (docs/argocd-phase-7-staging-soak.md): verify that
# a merged bump (or revert) PR reached the cluster through ArgoCD, and nothing
# else did.
#
# Read-only. Against the current kubeconfig context and the argocd CLI login it
# prints and checks:
#   - the Application's sync status, health, sync policy, synced revision and
#     the last operation (phase, who started it, start and finish times)
#   - the image tag on the live Deployment, and that its rollout is complete
#   - the image tag and the SHORT_COMMIT_HASH env var on the newest app pod
#   - GET https://<ingress.host>/health (host from values-<env>.yaml)
#   - the tail of `argocd app history`
#   - `helm -n <namespace> list`, which must be empty after Phase 6
#
# Exits non-zero on any mismatch against the expected tag and hash, which
# default to image.tag and shortCommitHash in helm/automation-calculator/
# values-<env>.yaml (the file ArgoCD deploys from main). Only `kubectl get`,
# `argocd app get|history`, `helm list` and `curl` are used; nothing is
# written to the cluster.
#
# Usage:
#   eval "$(scripts/infra_eng_sso.py up --environment staging)"
#   kubectl -n argocd port-forward svc/argocd-server 8080:80 &   # see docs/argocd-phase-2-install.md
#   argocd login localhost:8080 --username admin --plaintext
#   scripts/argocd_staging_verify.sh                              # expect what values-staging.yaml says
#   scripts/argocd_staging_verify.sh --expect-tag 0.9.7-981 --expect-hash a1b2c3d
#   scripts/argocd_staging_verify.sh | tee tmp/phase7-cycle-1-verify.txt
#
# Options:
#   --env NAME          environment (default staging); selects values-NAME.yaml
#   --expect-tag TAG    image tag the cluster must run (default: image.tag in values-NAME.yaml)
#   --expect-hash HASH  SHORT_COMMIT_HASH the newest pod must carry (default: shortCommitHash in values-NAME.yaml)
#   --history-lines N   lines of `argocd app history` to show (default 5)
#   -h, --help
#
# Environment:
#   ARGOCD_SERVER     argocd API address (default localhost:8080, the port-forward)
#   ARGOCD_OPTS       extra argocd CLI flags (default --plaintext, for server.insecure=true)
#   APP_NAME          Application and Deployment name (default automation-calculator)
#   APP_NAMESPACE     app namespace (default automation-calculator)
#   ARGOCD_NAMESPACE  namespace ArgoCD runs in (default argocd)
#   HEALTH_PATH       path to GET on the ingress host (default /health)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm/automation-calculator"

ENV_NAME="staging"
EXPECT_TAG=""
EXPECT_HASH=""
HISTORY_LINES=5

usage() {
  sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --expect-tag) EXPECT_TAG="$2"; shift 2 ;;
    --expect-hash) EXPECT_HASH="$2"; shift 2 ;;
    --history-lines) HISTORY_LINES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

export ARGOCD_SERVER="${ARGOCD_SERVER:-localhost:8080}"
export ARGOCD_OPTS="${ARGOCD_OPTS:---plaintext}"
APP_NAME="${APP_NAME:-automation-calculator}"
APP_NAMESPACE="${APP_NAMESPACE:-automation-calculator}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
VALUES_FILE="${CHART_DIR}/values-${ENV_NAME}.yaml"

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

for cli in kubectl argocd yq curl; do
  if ! command -v "${cli}" >/dev/null 2>&1; then
    echo "${cli} is not installed; nothing to check." >&2
    exit 1
  fi
done

if [ ! -f "${VALUES_FILE}" ]; then
  echo "Values file not found: ${VALUES_FILE}" >&2
  exit 1
fi

values_tag="$(yq -r '.image.tag' "${VALUES_FILE}")"
values_hash="$(yq -r '.shortCommitHash' "${VALUES_FILE}")"
host="$(yq -r '.ingress.host' "${VALUES_FILE}")"
EXPECT_TAG="${EXPECT_TAG:-${values_tag}}"
EXPECT_HASH="${EXPECT_HASH:-${values_hash}}"

if [ -z "${EXPECT_TAG}" ] || [ "${EXPECT_TAG}" = "null" ]; then
  echo "No expected tag: pass --expect-tag or set image.tag in ${VALUES_FILE}" >&2
  exit 1
fi
if [ -z "${host}" ] || [ "${host}" = "null" ]; then
  echo "No ingress.host in ${VALUES_FILE}" >&2
  exit 1
fi

echo "Context:        $(kubectl config current-context)"
echo "ArgoCD server:  ${ARGOCD_SERVER} (ARGOCD_OPTS: ${ARGOCD_OPTS})"
echo "Time:           $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Values file:    values-${ENV_NAME}.yaml (image.tag ${values_tag}, shortCommitHash ${values_hash})"
echo "Expected:       tag ${EXPECT_TAG}, SHORT_COMMIT_HASH ${EXPECT_HASH:-<empty>}"
echo

# 1. Application status, from the CR (one API read; the argocd CLI is used
#    below for the history tail). jsonpath cannot express "the last history
#    entry", so the history id is taken from the CLI output instead.
echo "Application ${ARGOCD_NAMESPACE}/${APP_NAME}:"
app_row="$(kubectl -n "${ARGOCD_NAMESPACE}" get application.argoproj.io "${APP_NAME}" \
  -o jsonpath='{.status.sync.status}{"\t"}{.status.health.status}{"\t"}{.status.sync.revision}{"\t"}{.spec.syncPolicy.automated}{"\t"}{.status.operationState.phase}{"\t"}{.status.operationState.operation.initiatedBy.automated}{"\t"}{.status.operationState.operation.initiatedBy.username}{"\t"}{.status.operationState.startedAt}{"\t"}{.status.operationState.finishedAt}{"\t"}{.status.operationState.message}' 2>/dev/null || true)"
if [ -z "${app_row}" ]; then
  fail "Application ${APP_NAME} not found in namespace ${ARGOCD_NAMESPACE}"
else
  sync_status="$(printf '%s' "${app_row}" | cut -f1)"
  health_status="$(printf '%s' "${app_row}" | cut -f2)"
  sync_revision="$(printf '%s' "${app_row}" | cut -f3)"
  automated_policy="$(printf '%s' "${app_row}" | cut -f4)"
  op_phase="$(printf '%s' "${app_row}" | cut -f5)"
  op_automated="$(printf '%s' "${app_row}" | cut -f6)"
  op_username="$(printf '%s' "${app_row}" | cut -f7)"
  op_started="$(printf '%s' "${app_row}" | cut -f8)"
  op_finished="$(printf '%s' "${app_row}" | cut -f9)"
  op_message="$(printf '%s' "${app_row}" | cut -f10)"
  if [ "${op_automated}" = "true" ]; then
    op_initiator="automated"
  elif [ -n "${op_username}" ]; then
    op_initiator="user ${op_username} (manual sync)"
  else
    op_initiator="unknown"
  fi
  echo "  sync:              ${sync_status} (${sync_revision:0:12})"
  echo "  health:            ${health_status}"
  echo "  sync policy:       ${automated_policy:+automated }${automated_policy:-manual}"
  echo "  last operation:    ${op_phase:-none}, started by ${op_initiator}"
  echo "    started:         ${op_started:-n/a}"
  echo "    finished:        ${op_finished:-n/a}"
  if [ -n "${op_message}" ]; then
    echo "    message:         ${op_message}"
  fi
  if [ "${sync_status}" != "Synced" ]; then
    fail "Application sync status is ${sync_status:-<empty>}, expected Synced"
  fi
  if [ "${health_status}" != "Healthy" ]; then
    fail "Application health is ${health_status:-<empty>}, expected Healthy"
  fi
  if [ -n "${op_phase}" ] && [ "${op_phase}" != "Succeeded" ]; then
    fail "last sync operation phase is ${op_phase}, expected Succeeded"
  fi
  if [ -z "${automated_policy}" ]; then
    echo "  note: sync policy is manual; Phase 6 left ${ENV_NAME} on automated sync" >&2
  fi
fi

# 2. Live Deployment: image tag and rollout completeness.
echo
echo "Deployment ${APP_NAMESPACE}/${APP_NAME}:"
deploy_row="$(kubectl -n "${APP_NAMESPACE}" get deploy "${APP_NAME}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\t"}{.metadata.generation}{"\t"}{.status.observedGeneration}{"\t"}{.spec.replicas}{"\t"}{.status.updatedReplicas}{"\t"}{.status.availableReplicas}{"\t"}{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || true)"
if [ -z "${deploy_row}" ]; then
  fail "Deployment ${APP_NAME} not found in namespace ${APP_NAMESPACE}"
else
  deploy_image="$(printf '%s' "${deploy_row}" | cut -f1)"
  deploy_gen="$(printf '%s' "${deploy_row}" | cut -f2)"
  deploy_observed="$(printf '%s' "${deploy_row}" | cut -f3)"
  deploy_replicas="$(printf '%s' "${deploy_row}" | cut -f4)"
  deploy_updated="$(printf '%s' "${deploy_row}" | cut -f5)"
  deploy_available="$(printf '%s' "${deploy_row}" | cut -f6)"
  deploy_revision="$(printf '%s' "${deploy_row}" | cut -f7)"
  deploy_tag="${deploy_image##*:}"
  echo "  image:             ${deploy_image}"
  echo "  generation:        ${deploy_gen} (observed ${deploy_observed}), rollout revision ${deploy_revision:-?}"
  echo "  replicas:          ${deploy_replicas} desired, ${deploy_updated:-0} updated, ${deploy_available:-0} available"
  if [ "${deploy_tag}" != "${EXPECT_TAG}" ]; then
    fail "Deployment image tag is ${deploy_tag}, expected ${EXPECT_TAG}"
  fi
  if [ "${deploy_gen}" != "${deploy_observed}" ]; then
    fail "Deployment generation ${deploy_gen} not yet observed (${deploy_observed}); rollout in progress"
  fi
  if [ "${deploy_updated:-0}" != "${deploy_replicas}" ] || [ "${deploy_available:-0}" != "${deploy_replicas}" ]; then
    fail "Deployment rollout incomplete: ${deploy_updated:-0}/${deploy_replicas} updated, ${deploy_available:-0}/${deploy_replicas} available"
  fi
fi

# 3. Newest pod: image tag, SHORT_COMMIT_HASH, readiness. The selector labels
#    are the chart's (templates/_helpers.tpl); the release name is the
#    Application's helm.releaseName, which Phase 5 fixed to APP_NAME.
echo
echo "Newest pod:"
newest_pod="$(kubectl -n "${APP_NAMESPACE}" get pods \
  -l "app.kubernetes.io/name=${APP_NAME},app.kubernetes.io/instance=${APP_NAME}" \
  --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -n 1 | sed 's#^pod/##')"
if [ -z "${newest_pod}" ]; then
  fail "no pods found with the ${APP_NAME} selector labels in ${APP_NAMESPACE}"
else
  pod_row="$(kubectl -n "${APP_NAMESPACE}" get pod "${newest_pod}" \
    -o jsonpath='{.metadata.creationTimestamp}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].restartCount}{"\t"}{.spec.containers[0].image}{"\t"}{.spec.containers[0].env[?(@.name=="SHORT_COMMIT_HASH")].value}')"
  pod_created="$(printf '%s' "${pod_row}" | cut -f1)"
  pod_phase="$(printf '%s' "${pod_row}" | cut -f2)"
  pod_ready="$(printf '%s' "${pod_row}" | cut -f3)"
  pod_restarts="$(printf '%s' "${pod_row}" | cut -f4)"
  pod_image="$(printf '%s' "${pod_row}" | cut -f5)"
  pod_hash="$(printf '%s' "${pod_row}" | cut -f6)"
  pod_tag="${pod_image##*:}"
  echo "  name:              ${newest_pod}"
  echo "  created:           ${pod_created}"
  echo "  phase:             ${pod_phase}, ready ${pod_ready:-false}, restarts ${pod_restarts:-0}"
  echo "  image:             ${pod_image}"
  echo "  SHORT_COMMIT_HASH: ${pod_hash:-<empty>}"
  if [ "${pod_tag}" != "${EXPECT_TAG}" ]; then
    fail "newest pod image tag is ${pod_tag}, expected ${EXPECT_TAG}"
  fi
  if [ "${pod_hash}" != "${EXPECT_HASH}" ]; then
    fail "newest pod SHORT_COMMIT_HASH is '${pod_hash}', expected '${EXPECT_HASH}'"
  fi
  if [ "${pod_phase}" != "Running" ] || [ "${pod_ready}" != "true" ]; then
    fail "newest pod is ${pod_phase}, ready=${pod_ready:-false}"
  fi
fi

# 4. The site serves. The health endpoint runs SELECT 1 against the database.
echo
health_url="https://${host}${HEALTH_PATH}"
echo "GET ${health_url}:"
if health_body="$(curl -fsS --max-time 20 "${health_url}" 2>&1)"; then
  echo "  ok: $(printf '%s' "${health_body}" | head -c 200 | tr '\n' ' ')"
else
  fail "GET ${health_url} failed: ${health_body}"
fi

# 5. ArgoCD history tail. The last line is the entry a bump cycle is recorded
#    under in docs/argocd-staging-soak-log.md.
echo
echo "argocd app history ${APP_NAME} (last ${HISTORY_LINES} lines):"
if history_out="$(argocd app history "${APP_NAME}" 2>&1)"; then
  printf '%s\n' "${history_out}" | head -n 1 | sed 's/^/  /'
  printf '%s\n' "${history_out}" | tail -n +2 | tail -n "${HISTORY_LINES}" | sed 's/^/  /'
  latest_history_id="$(printf '%s\n' "${history_out}" | tail -n 1 | awk '{ print $1 }')"
  echo "  latest history id: ${latest_history_id:-?}"
else
  fail "argocd app history failed (is the port-forward up and argocd logged in?): ${history_out}"
fi

# 6. Helm must have forgotten the release (Phase 6 deleted its history).
echo
echo "helm -n ${APP_NAMESPACE} list:"
if command -v helm >/dev/null 2>&1; then
  helm_releases="$(helm -n "${APP_NAMESPACE}" list -q 2>/dev/null || true)"
else
  echo "  (helm not installed; checking Helm release Secrets with kubectl instead)"
  helm_releases="$(kubectl -n "${APP_NAMESPACE}" get secret -l owner=helm -o name 2>/dev/null || true)"
fi
if [ -z "${helm_releases}" ]; then
  echo "  empty (ok)"
else
  printf '%s\n' "${helm_releases}" | sed 's/^/  /'
  fail "Helm still has a release in ${APP_NAMESPACE}; Phase 6 should have removed its history (never helm uninstall)"
fi

echo
if [ "${failures}" -gt 0 ]; then
  echo "Verify FAILED (${failures} problem(s))."
  exit 1
fi
echo "Verify OK: ${ENV_NAME} runs ${EXPECT_TAG} (${EXPECT_HASH:-<empty hash>}) through ArgoCD."
