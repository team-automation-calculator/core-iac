#!/bin/bash

set -euo pipefail

# Record the main commit being promoted to production in a production
# workspace's promoted_ref file, so that a pull request has a production file
# to change.
#
# Production's cluster workspaces run only when one of production's own files
# changes (docs/promotion.md). A change that lives entirely in shared code (a
# module, a chart template) has no such file, so its production pull request
# changes promoted_ref instead. Merging that pull request applies everything
# on main to production, with no confirm: read its speculative plan first.
#
# Usage: scripts/promote_to_production.sh <base|addons|both> [commit]
#   base    terraform/env/production/aws/us-west-1/base-cluster-layer
#   addons  terraform/env/production/aws/us-west-1/cluster-addons-layer
#   commit  the main commit verified on staging (default: origin/main)
#
# Only edits files in the working tree. Branch, commit, push and the pull
# request are the usual steps afterwards.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="${SCRIPT_DIR}/../terraform/env/production/aws/us-west-1"

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

COMMIT="$(git -C "${SCRIPT_DIR}" rev-parse --short "${2:-origin/main}")"

for LAYER in "${LAYERS[@]}"; do
    FILE="${PRODUCTION_DIR}/${LAYER}/promoted_ref"
    ls -d "${PRODUCTION_DIR}/${LAYER}" >/dev/null
    # The file is created by the first promotion that needs it.
    cat > "${FILE}" <<EOF
# The main commit last promoted to this workspace by a pull request that had no
# other production file to change (docs/promotion.md). Terraform does not read
# this file; changing it is what triggers the workspace. Written by
# scripts/promote_to_production.sh.
${COMMIT}
EOF
    echo "${LAYER}/promoted_ref -> ${COMMIT}"
done
