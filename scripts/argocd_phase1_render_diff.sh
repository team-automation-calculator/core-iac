#!/bin/bash

set -euo pipefail

# ArgoCD migration Phase 1 proof: render the app chart as it was before the
# refactor (from a git ref, with the values Terraform used to build from
# terraform.tfvars + values.yml) and as it is in the working tree (chart
# values-<env>.yaml + the certificate ARN injected as a parameter, by
# Terraform's release until Phase 9 and by the ArgoCD Application since), then
# diff the two renders per environment. Read-only: no cluster access.
#
# Historical since Phase 1 landed, kept because it still runs: everything on
# the "old" side comes from BASE_REF through `git show`, so Phase 9 deleting
# terraform/modules/aws/main_rails_app/values.yml from the working tree does
# not affect it. Expect the diff to have grown since Phase 4: every
# values-<env>.yaml sets secrets.create=false, so the new render has no
# Secret (the placeholders below only reach the old chart).
#
# Usage: scripts/argocd_phase1_render_diff.sh [BASE_REF]
#   BASE_REF defaults to origin/argocd-phase-0 (the chart before Phase 1);
#   pass the merge commit of PR #377 once that branch is gone.
# Output lands in tmp/argocd-phase1-render/ (gitignored). Exit code is 0 when
# every env rendered; the diffs are printed and saved for review.

BASE_REF="${1:-origin/argocd-phase-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_REL="helm/automation-calculator"
NEW_CHART="${REPO_ROOT}/${CHART_REL}"
OUT="${REPO_ROOT}/tmp/argocd-phase1-render"
OLD_CHART="${OUT}/old-chart/${CHART_REL}"
ENVS=(development staging production)

# Same placeholders on both sides; Terraform passes the real values with
# set_sensitive (secrets) and templatefile (certificate ARN).
CERT_ARN="arn:aws:acm:us-west-1:000000000000:certificate/phase1-render-diff"
SECRET_SETS=(
    --set secrets.databaseUrl=DATABASE_URL_PLACEHOLDER
    --set secrets.githubOAuthAppId=GITHUB_OAUTH_APP_ID_PLACEHOLDER
    --set secrets.githubOAuthAppSecret=GITHUB_OAUTH_APP_SECRET_PLACEHOLDER
    --set secrets.googleOAuthAppId=GOOGLE_OAUTH_APP_ID_PLACEHOLDER
    --set secrets.googleOAuthAppSecret=GOOGLE_OAUTH_APP_SECRET_PLACEHOLDER
    --set secrets.secretKeyBase=SECRET_KEY_BASE_PLACEHOLDER
)

rm -rf "${OUT}"
mkdir -p "${OUT}/old-chart" "${OUT}/old-values" "${OUT}/renders"

cd "${REPO_ROOT}"
git archive "${BASE_REF}" "${CHART_REL}" | tar -x -C "${OUT}/old-chart"
git show "${BASE_REF}:terraform/modules/aws/main_rails_app/values.yml" > "${OUT}/old-values/values.yml.tpl"

tfvar() {
    # tfvar <file> <name>: value of a quoted string assignment in a tfvars file.
    sed -n -E "s/^${2}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "${1}"
}

for ENV in "${ENVS[@]}"; do
    TFVARS="${OUT}/old-values/${ENV}.tfvars"
    git show "${BASE_REF}:terraform/env/${ENV}/aws/us-west-1/cluster-addons-layer/terraform.tfvars" > "${TFVARS}"
    APP_VERSION="$(tfvar "${TFVARS}" app_version)"
    SHORT_COMMIT_HASH="$(tfvar "${TFVARS}" short_commit_hash)"
    APP_HOST="$(tfvar "${TFVARS}" automation_calculator_app_host)"

    # Replicate templatefile() in main_rails_app/main.tf at BASE_REF.
    OLD_VALUES="${OUT}/old-values/${ENV}.yaml"
    sed \
        -e "s|\${app_image_pull_policy}|Always|g" \
        -e "s|\${app_image_repo}|automationcalculationsci/automation-calculator|g" \
        -e "s|\${app_version}|${APP_VERSION}|g" \
        -e "s|\${automation_calculator_app_host}|${APP_HOST}|g" \
        -e "s|\${alb_name}|ac-app-${ENV}|g" \
        -e "s|\${cert_arn}|${CERT_ARN}|g" \
        -e "s|\${short_commit_hash}|${SHORT_COMMIT_HASH}|g" \
        "${OUT}/old-values/values.yml.tpl" > "${OLD_VALUES}"

    helm template automation-calculator "${OLD_CHART}" \
        --namespace automation-calculator \
        --values "${OLD_VALUES}" \
        "${SECRET_SETS[@]}" > "${OUT}/renders/${ENV}-old.yaml"

    helm template automation-calculator "${NEW_CHART}" \
        --namespace automation-calculator \
        --values "${NEW_CHART}/values-${ENV}.yaml" \
        --set "ingress.certificateArn=${CERT_ARN}" \
        "${SECRET_SETS[@]}" > "${OUT}/renders/${ENV}-new.yaml"

    echo "=== ${ENV}: diff old (${BASE_REF}) vs new (working tree)"
    diff -u "${OUT}/renders/${ENV}-old.yaml" "${OUT}/renders/${ENV}-new.yaml" \
        | tee "${OUT}/renders/${ENV}.diff" || true
    echo
done

echo "Renders and diffs saved under ${OUT}/renders/"
