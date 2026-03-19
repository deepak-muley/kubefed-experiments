#!/usr/bin/env bash
# Fix KubeFedCluster API endpoints for Kind on macOS.
# On macOS, Kind uses Docker Desktop networking and the default API endpoint
# (https://:6443) doesn't work. This script patches each KubeFedCluster with
# the correct Docker container IP.

set -o errexit
set -o nounset
set -o pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script is only needed on macOS. Skipping."
  exit 0
fi

NS="${KUBEFED_NAMESPACE:-kube-federation-system}"
INSPECT_PATH='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'

echo "Fixing KubeFedCluster API endpoints for Kind on macOS..."

clusters=$(kubectl get kubefedclusters -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
if [[ -z "${clusters}" ]]; then
  echo "No KubeFedClusters found in ${NS}. Is KubeFed deployed?"
  exit 1
fi

for cluster in ${clusters}; do
  if docker inspect "${cluster}-control-plane" &>/dev/null; then
    ip_addr=$(docker inspect -f "${INSPECT_PATH}" "${cluster}-control-plane")
    endpoint="https://${ip_addr}:6443"
    echo "  Patching ${cluster} -> ${endpoint}"
    kubectl patch kubefedclusters -n "${NS}" "${cluster}" --type merge \
      --patch "{\"spec\":{\"apiEndpoint\":\"${endpoint}\"}}"
  else
    echo "  Skipping ${cluster} (not a Kind cluster or container not found)"
  fi
done

echo "Done. Verify with: kubectl get kubefedclusters -n ${NS}"
