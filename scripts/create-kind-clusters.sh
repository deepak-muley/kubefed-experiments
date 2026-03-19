#!/usr/bin/env bash
# Create multiple Kind clusters for KubeFed federation testing.
# Creates cluster1 (host) and cluster2 (member) by default.

set -o errexit
set -o nounset
set -o pipefail

NUM_CLUSTERS="${NUM_CLUSTERS:-2}"
KIND_IMAGE="${KIND_IMAGE:-}"
KIND_TAG="${KIND_TAG:-v1.32.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Creating ${NUM_CLUSTERS} Kind clusters..."

for i in $(seq 1 "${NUM_CLUSTERS}"); do
  cluster_name="cluster${i}"
  if kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"; then
    echo "Cluster ${cluster_name} already exists, skipping..."
  else
    if [[ -n "${KIND_IMAGE}" ]]; then
      kind create cluster --name "${cluster_name}" --image="${KIND_IMAGE}"
    else
      kind create cluster --name "${cluster_name}" --image="ghcr.io/mesosphere/kind-node:${KIND_TAG}"
    fi
    echo "Created ${cluster_name}"
  fi

  # On Linux (non-macOS): Set container IP as API endpoint for cross-cluster access
  if [[ "$(uname)" != "Darwin" ]]; then
    docker_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${cluster_name}-control-plane" 2>/dev/null || true)
    if [[ -n "${docker_ip}" ]]; then
      kubectl config set-cluster "kind-${cluster_name}" --server="https://${docker_ip}:6443"
    fi
  fi

  # Simplify context name from kind-cluster1 to cluster1
  if kubectl config get-contexts "kind-${cluster_name}" &>/dev/null; then
    kubectl config rename-context "kind-${cluster_name}" "${cluster_name}" 2>/dev/null || true
  fi
done

echo ""
echo "Waiting for clusters to be ready..."
for i in $(seq 1 "${NUM_CLUSTERS}"); do
  cluster_name="cluster${i}"
  for _ in $(seq 1 60); do
    if kubectl --context="${cluster_name}" get --raw=/healthz &>/dev/null; then
      echo "  ${cluster_name}: ready"
      break
    fi
    sleep 2
  done
done

kubectl config use-context cluster1
echo ""
echo "Done. Use 'kubectl config use-context cluster1' or 'cluster2' to switch."
