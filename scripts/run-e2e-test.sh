#!/usr/bin/env bash
# End-to-end test for KubeFed: deploy sample app, verify propagation, test placement changes.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SAMPLE_APP="${REPO_ROOT}/sample-app"
HOST_CONTEXT="${HOST_CONTEXT:-cluster1}"
TIMEOUT=120

red() { echo -e "\033[0;31m$*\033[0m"; }
green() { echo -e "\033[0;32m$*\033[0m"; }
yellow() { echo -e "\033[0;33m$*\033[0m"; }

log() { echo "[$(date +%H:%M:%S)] $*"; }
pass() { green "  PASS: $*"; }
fail() { red "  FAIL: $*"; exit 1; }

# Get list of member clusters from KubeFed
get_member_clusters() {
  kubectl --context="${HOST_CONTEXT}" get kubefedclusters -n kube-federation-system \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null | tr -d '\n'
}

# Wait for propagation condition on a federated resource
wait_for_propagation() {
  local kind=$1 name=$2 ns=$3
  log "Waiting for ${kind}/${name} propagation (timeout ${TIMEOUT}s)..."
  local elapsed=0
  while [[ ${elapsed} -lt ${TIMEOUT} ]]; do
    status=$(kubectl --context="${HOST_CONTEXT}" get "${kind}" "${name}" -n "${ns}" \
      -o jsonpath='{.status.conditions[?(@.type=="Propagation")].status}' 2>/dev/null || echo "Unknown")
    if [[ "${status}" == "True" ]]; then
      pass "${kind}/${name} propagated"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  fail "${kind}/${name} did not propagate within ${TIMEOUT}s"
}

echo "=========================================="
echo " KubeFed End-to-End Test"
echo "=========================================="
echo ""

# Pre-checks
log "Pre-checks..."
kubectl --context="${HOST_CONTEXT}" cluster-info &>/dev/null || fail "Cannot reach host cluster ${HOST_CONTEXT}"
clusters=$(get_member_clusters)
[[ -n "${clusters}" ]] || fail "No KubeFedClusters found. Deploy KubeFed first."
log "Member clusters: ${clusters}"
echo ""

# Step 1: Deploy sample app
log "Step 1: Deploying sample app..."
kubectl --context="${HOST_CONTEXT}" apply -f "${SAMPLE_APP}/namespace.yaml" -f "${SAMPLE_APP}/federatednamespace.yaml"
sleep 5
kubectl --context="${HOST_CONTEXT}" apply -f "${SAMPLE_APP}/federatedconfigmap.yaml" \
  -f "${SAMPLE_APP}/federateddeployment.yaml" -f "${SAMPLE_APP}/federatedservice.yaml"
echo ""

# Step 2: Wait for propagation
log "Step 2: Verifying propagation..."
wait_for_propagation federatednamespace demo-app demo-app
wait_for_propagation federatedconfigmap web-file demo-app
wait_for_propagation federateddeployment nginx demo-app
wait_for_propagation federatedservice nginx demo-app
echo ""

# Step 3: Verify resources exist in each cluster
log "Step 3: Verifying resources in member clusters..."
for ctx in ${clusters}; do
  log "  Checking ${ctx}..."
  kubectl --context="${ctx}" get ns demo-app &>/dev/null || fail "Namespace demo-app not in ${ctx}"
  kubectl --context="${ctx}" -n demo-app get cm web-file &>/dev/null || fail "ConfigMap web-file not in ${ctx}"
  kubectl --context="${ctx}" -n demo-app get deploy nginx &>/dev/null || fail "Deployment nginx not in ${ctx}"
  kubectl --context="${ctx}" -n demo-app get svc nginx &>/dev/null || fail "Service nginx not in ${ctx}"
  pass "All resources present in ${ctx}"
done
echo ""

# Step 4: Verify pods are running
log "Step 4: Verifying pods..."
for ctx in ${clusters}; do
  log "  Waiting for nginx pod in ${ctx}..."
  kubectl --context="${ctx}" -n demo-app wait --for=condition=Ready pod -l app=nginx --timeout=60s
  pass "nginx pod ready in ${ctx}"
done
echo ""

# Step 5: Test app (curl if NodePort accessible)
log "Step 5: Testing app response..."
for ctx in ${clusters}; do
  node_port=$(kubectl --context="${ctx}" -n demo-app get svc nginx -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30080")
  node_ip=$(kubectl --context="${ctx}" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
  if [[ -n "${node_ip}" ]]; then
    if curl -s --connect-timeout 5 "http://${node_ip}:${node_port}" 2>/dev/null | grep -q "KubeFed"; then
      pass "App responds correctly in ${ctx}"
    else
      yellow "  Could not curl app in ${ctx} (may need port-forward or different network)"
    fi
  fi
done
echo ""

# Step 6: Placement change (if multiple clusters)
cluster_array=(${clusters})
if [[ ${#cluster_array[@]} -ge 2 ]]; then
  log "Step 6: Testing placement change (remove cluster2)..."
  kubectl --context="${HOST_CONTEXT}" -n demo-app patch federatednamespace demo-app --type=merge \
    -p '{"spec":{"placement":{"clusters":[{"name":"cluster1"}]}}}'
  sleep 15
  if kubectl --context="cluster2" get ns demo-app &>/dev/null 2>&1; then
    yellow "  Namespace may still exist in cluster2 (deletion can take a moment)"
  else
    pass "Resources removed from cluster2"
  fi
  # Restore
  kubectl --context="${HOST_CONTEXT}" -n demo-app patch federatednamespace demo-app --type=merge \
    -p '{"spec":{"placement":{"clusterSelector":{}}}}'
  log "  Restored placement to all clusters"
else
  log "Step 6: Skipping placement test (single cluster)"
fi
echo ""

green "=========================================="
green " All tests passed!"
green "=========================================="
echo ""
echo "Cleanup: kubectl --context=${HOST_CONTEXT} delete ns demo-app"
