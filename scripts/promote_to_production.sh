#!/bin/bash

set -euo pipefail

# Promote a main commit verified on staging to production: write it to the
# production working directories, so that a pull request has a production file
# to change and merging it is the production deploy (docs/promotion.md).
#
#   promoted_ref                 base and/or addons: a file Terraform does not
#                                read; changing it is what triggers the
#                                workspace for shared Terraform code.
#   argocd_app_target_revision   addons only, in terraform.tfvars: the commit
#                                production's ArgoCD Application renders the
#                                chart and values-production.yaml from. Moving
#                                it deploys the app (automated sync), together
#                                with every chart change up to that commit.
#
# Merging the pull request applies everything on main up to the commit to
# production, with no confirm: read its speculative plan, and for the app the
# `git log` range this script prints, first.
#
# Usage, from the repo root:
#   scripts/promote_to_production.sh <base|addons|both> [commit]
#   base    terraform/env/production/aws/us-west-1/base-cluster-layer
#   addons  terraform/env/production/aws/us-west-1/cluster-addons-layer
#   commit  the main commit verified on staging (default: origin/main); it must
#           be on origin/main
#
# A rollback is the same command with the earlier commit.
#
# Only edits files in the working tree. Branch, commit, push and the pull
# request are the usual steps afterwards (bump_app_docker_image_version_branch.sh
# does them for an app image).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRODUCTION_DIR="${REPO_ROOT}/terraform/env/production/aws/us-west-1"
TFVARS="${PRODUCTION_DIR}/cluster-addons-layer/terraform.tfvars"
PIN_VAR="argocd_app_target_revision"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <base|addons|both> [commit]"
    exit 1
fi

case "${1}" in
    base) LAYERS=(base-cluster-layer) ;;
    addons) LAYERS=(cluster-addons-layer) ;;
    both) LAYERS=(base-cluster-layer cluster-addons-layer) ;;
    *)
        echo "Unknown layer '${1}': expected base, addons or both"
        exit 1
        ;;
esac

COMMIT="$(git -C "${REPO_ROOT}" rev-parse --verify "${2:-origin/main}^{commit}")"
if ! git -C "${REPO_ROOT}" merge-base --is-ancestor "${COMMIT}" origin/main; then
    echo "${COMMIT} is not on origin/main: promote only commits merged to main (git fetch first?)"
    exit 1
fi
SHORT="$(git -C "${REPO_ROOT}" rev-parse --short "${COMMIT}")"

for LAYER in "${LAYERS[@]}"; do
    FILE="${PRODUCTION_DIR}/${LAYER}/promoted_ref"
    ls -d "${PRODUCTION_DIR}/${LAYER}" >/dev/null
    cat > "${FILE}" <<EOF
# The main commit last promoted to this workspace (docs/promotion.md).
# Terraform does not read this file; changing it is what triggers the
# workspace. Written by scripts/promote_to_production.sh.
${SHORT}
EOF
    echo "${LAYER}/promoted_ref -> ${SHORT}"
done

if [[ " ${LAYERS[*]} " == *" cluster-addons-layer "* ]]; then
    OLD="$(sed -nE "s/^${PIN_VAR}[[:space:]]*=[[:space:]]*\"([0-9a-f]+)\".*/\1/p" "${TFVARS}")"
    if [ -z "${OLD}" ]; then
        echo "No ${PIN_VAR} line in ${TFVARS}"
        exit 1
    fi
    # Keeps the alignment terraform fmt gave the line; only the value changes.
    sed -i.bak -E "s/^(${PIN_VAR}[[:space:]]*=[[:space:]]*)\"[0-9a-f]+\"/\1\"${COMMIT}\"/" "${TFVARS}"
    rm -f "${TFVARS}.bak"
    echo "cluster-addons-layer/terraform.tfvars ${PIN_VAR}: ${OLD:0:7} -> ${SHORT}"
    if [ "${OLD}" = "${COMMIT}" ]; then
        echo "The app pin was already at ${SHORT}: nothing new reaches the app"
    else
        echo
        if git -C "${REPO_ROOT}" merge-base --is-ancestor "${COMMIT}" "${OLD}"; then
            echo "ROLLBACK: the pin moves back, taking these main commits off production:"
            git -C "${REPO_ROOT}" log --oneline --first-parent "${COMMIT}..${OLD}"
        else
            echo "What the app pin move brings to production (chart, values and anything else):"
            git -C "${REPO_ROOT}" log --oneline --first-parent "${OLD}..${COMMIT}"
        fi
        echo
        echo "Chart files changed:"
        git -C "${REPO_ROOT}" diff --stat "${OLD}" "${COMMIT}" -- helm/automation-calculator
    fi
fi
