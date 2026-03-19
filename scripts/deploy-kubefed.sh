#!/usr/bin/env bash
# Deploy KubeFed to the host cluster (cluster1) and join member clusters.
# Requires: kubefed repo (clone or set KUBEFED_REPO), helm, kubectl, kind

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# KubeFed repo path - use env var or default to sibling directory
KUBEFED_REPO="${KUBEFED_REPO:-$(cd "${REPO_ROOT}/../kubefed" 2>/dev/null && pwd)}"
if [[ -z "${KUBEFED_REPO}" || ! -d "${KUBEFED_REPO}" ]]; then
  echo "KubeFed repo not found. Clone it first:"
  echo "  git clone https://github.com/mesosphere/kubefed.git ${REPO_ROOT}/../kubefed"
  echo "  export KUBEFED_REPO=${REPO_ROOT}/../kubefed"
  echo ""
  echo "Or set KUBEFED_REPO to the path of your kubefed clone."
  exit 1
fi

# Use pre-built image from Mesosphere (no need to build)
KUBEFED_IMAGE="${KUBEFED_IMAGE:-ghcr.io/mesosphere/kubefed:v0.11.1}"
HOST_CONTEXT="${HOST_CONTEXT:-cluster1}"
# For single cluster: JOIN_CLUSTERS="" (host joins itself). For multi: JOIN_CLUSTERS="cluster2"
JOIN_CLUSTERS="${JOIN_CLUSTERS:-cluster2}"
# If cluster2 doesn't exist (e.g. NUM_CLUSTERS=1), only join host
if [[ "${JOIN_CLUSTERS}" == "cluster2" ]] && ! kind get clusters 2>/dev/null | grep -q "^cluster2$"; then
  echo "Note: cluster2 not found (single-cluster mode)"
  JOIN_CLUSTERS=""
fi
KIND_LOAD_IMAGE="${KIND_LOAD_IMAGE:-y}"
FORCE_REDEPLOY="${FORCE_REDEPLOY:-y}"

echo "Deploying KubeFed..."
echo "  Host context: ${HOST_CONTEXT}"
echo "  Join clusters: ${JOIN_CLUSTERS}"
echo "  Image: ${KUBEFED_IMAGE}"
echo ""

# Ensure we're on host context
kubectl config use-context "${HOST_CONTEXT}"

# Pull and load image into Kind clusters if using kind
if [[ "${KIND_LOAD_IMAGE}" == "y" ]]; then
  echo "Pulling KubeFed image..."
  docker pull "${KUBEFED_IMAGE}" 2>/dev/null || true
  for cluster in ${HOST_CONTEXT} ${JOIN_CLUSTERS}; do
    if kind get clusters 2>/dev/null | grep -q "^${cluster}$"; then
      echo "Loading KubeFed image into ${cluster}..."
      kind load docker-image "${KUBEFED_IMAGE}" --name="${cluster}" 2>/dev/null || true
    fi
  done
fi

# Build kubefedctl from source (needed for join)
echo "Building kubefedctl..."
cd "${KUBEFED_REPO}"
make kubefedctl
cd - >/dev/null

# Deploy using kubefed's deploy script
# Skip KIND_LOAD_IMAGE in kubefed script - we already loaded into cluster1/cluster2
cd "${KUBEFED_REPO}"
KIND_LOAD_IMAGE=n \
FORCE_REDEPLOY="${FORCE_REDEPLOY}" \
./scripts/deploy-kubefed.sh "${KUBEFED_IMAGE}" ${JOIN_CLUSTERS}
cd - >/dev/null

echo ""
echo "KubeFed deployed. If on macOS, run: ./scripts/fix-kind-macos.sh"
