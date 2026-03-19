#!/usr/bin/env bash
# E2E test for PrometheusRule federation - simulates NKP workspace scenario.
# Prerequisites: Kind clusters created, KubeFed deployed.
# kubefedctl: Use KUBEFEDCTL_PATH, or run ./scripts/download-kubefedctl.sh, or have kubefed repo for build.
# Run after: ./scripts/create-kind-clusters.sh && ./scripts/deploy-kubefed.sh [&& ./scripts/fix-kind-macos.sh]

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROMETHEUSRULE_DEMO="${REPO_ROOT}/prometheusrule-demo"
KUBEFED_REPO="${KUBEFED_REPO:-$(cd "${REPO_ROOT}/../kubefed" 2>/dev/null && pwd)}"
BIN_DIR="${REPO_ROOT}/bin"
HOST_CONTEXT="${HOST_CONTEXT:-cluster1}"

# Resolve kubefedctl: KUBEFEDCTL_PATH > downloaded in bin/ > built from kubefed repo
resolve_kubefedctl() {
  if [[ -n "${KUBEFEDCTL_PATH:-}" && -x "${KUBEFEDCTL_PATH}" ]]; then
    echo "${KUBEFEDCTL_PATH}"
    return
  fi
  if [[ -x "${BIN_DIR}/kubefedctl" ]]; then
    echo "${BIN_DIR}/kubefedctl"
    return
  fi
  if [[ -n "${KUBEFED_REPO}" && -x "${KUBEFED_REPO}/bin/kubefedctl" ]]; then
    echo "${KUBEFED_REPO}/bin/kubefedctl"
    return
  fi
  echo ""
}
KUBEFED_NS="${KUBEFED_NS:-kube-federation-system}"
# Workspace namespace for placement (simulates NKP workspace)
WORKSPACE_NAMESPACE="${WORKSPACE_NAMESPACE:-demo-app}"
TIMEOUT=120

red() { echo -e "\033[0;31m$*\033[0m"; }
green() { echo -e "\033[0;32m$*\033[0m"; }
yellow() { echo -e "\033[0;33m$*\033[0m"; }
log() { echo "[$(date +%H:%M:%S)] $*"; }
pass() { green "  PASS: $*"; }
fail() { red "  FAIL: $*"; exit 1; }

get_member_clusters() {
  kubectl --context="${HOST_CONTEXT}" get kubefedclusters -n "${KUBEFED_NS}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null | tr -d '\n'
}

echo "=========================================="
echo " PrometheusRule Federation E2E"
echo "=========================================="
echo ""

# Pre-checks
log "Pre-checks..."
KUBEFEDCTL=$(resolve_kubefedctl)
[[ -n "${KUBEFEDCTL}" ]] || fail "kubefedctl not found. Run: ./scripts/download-kubefedctl.sh  OR  set KUBEFEDCTL_PATH  OR  clone kubefed and build"
log "Using kubefedctl: ${KUBEFEDCTL}"
"${KUBEFEDCTL}" version 2>/dev/null || true
kubectl --context="${HOST_CONTEXT}" cluster-info &>/dev/null || fail "Cannot reach host cluster"
clusters=$(get_member_clusters)
[[ -n "${clusters}" ]] || fail "No KubeFedClusters found. Deploy KubeFed first."
log "Member clusters: ${clusters}"
echo ""

# Step 0: Ensure demo-app namespace exists and is federated (from main e2e)
log "Step 0: Ensuring demo-app namespace is federated..."
kubectl --context="${HOST_CONTEXT}" apply -f "${REPO_ROOT}/sample-app/namespace.yaml" -f "${REPO_ROOT}/sample-app/federatednamespace.yaml" 2>/dev/null || true
sleep 3
echo ""

# Step 1: Install PrometheusRule CRD on ALL clusters
log "Step 1: Installing PrometheusRule CRD on all clusters..."
CRD_URL="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml"
for ctx in ${clusters}; do
  kubectl --context="${ctx}" apply -f "${CRD_URL}" || \
    kubectl --context="${ctx}" apply -f "${PROMETHEUSRULE_DEMO}/prometheusrule-crd.yaml"
  pass "PrometheusRule CRD installed on ${ctx}"
done
echo ""

# Step 2: Label KubeFedClusters with workspace (simulates NKP workspace attachment)
log "Step 2: Labeling KubeFedClusters with workspace (simulates NKP)..."
for ctx in ${clusters}; do
  kubectl --context="${HOST_CONTEXT}" label kubefedclusters -n "${KUBEFED_NS}" "${ctx}" \
    "kommander.d2iq.io/workspace-namespace-ref=${WORKSPACE_NAMESPACE}" --overwrite 2>/dev/null || true
done
pass "KubeFedClusters labeled"
echo ""

# Step 3: Enable PrometheusRule type for federation
log "Step 3: kubefedctl enable prometheusrules.monitoring.coreos.com..."
"${KUBEFEDCTL}" enable prometheusrules.monitoring.coreos.com \
  --kubefed-namespace="${KUBEFED_NS}"
pass "PrometheusRule type enabled"
kubectl --context="${HOST_CONTEXT}" get federatedtypeconfigs -n "${KUBEFED_NS}" | grep -i prometheus || true
echo ""

# Step 4: Create custom PrometheusRule on management cluster
log "Step 4: Creating custom PrometheusRule cluster-health-alerts..."
kubectl --context="${HOST_CONTEXT}" apply -f "${PROMETHEUSRULE_DEMO}/cluster-health-alerts.yaml"
pass "PrometheusRule created"
echo ""

# Step 5: Federate with workspace placement
log "Step 5: Federating with workspace placement..."
"${KUBEFEDCTL}" federate prometheusrules.monitoring.coreos.com cluster-health-alerts \
  --kubefed-namespace="${KUBEFED_NS}" -n "${WORKSPACE_NAMESPACE}" -o yaml | \
  yq '.spec.placement = {"clusterSelector": {"matchLabels": {"kommander.d2iq.io/workspace-namespace-ref": "'"${WORKSPACE_NAMESPACE}"'"}}}' - | \
  kubectl --context="${HOST_CONTEXT}" apply -f -
pass "FederatedPrometheusRule created with workspace placement"
echo ""

# Step 6: Wait for propagation
log "Step 6: Waiting for propagation..."
elapsed=0
while [[ ${elapsed} -lt ${TIMEOUT} ]]; do
  status=$(kubectl --context="${HOST_CONTEXT}" get federatedprometheusrules cluster-health-alerts -n "${WORKSPACE_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Propagation")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${status}" == "True" ]]; then
    pass "FederatedPrometheusRule propagated"
    break
  fi
  if [[ ${elapsed} -gt 30 ]]; then
    kubectl --context="${HOST_CONTEXT}" describe federatedprometheusrules cluster-health-alerts -n "${WORKSPACE_NAMESPACE}" | tail -30
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
[[ "${status}" == "True" ]] || fail "Propagation did not complete within ${TIMEOUT}s"
echo ""

# Step 7: Verify PrometheusRule exists in each cluster
log "Step 7: Verifying PrometheusRule in each cluster..."
for ctx in ${clusters}; do
  kubectl --context="${ctx}" -n "${WORKSPACE_NAMESPACE}" get prometheusrules.monitoring.coreos.com cluster-health-alerts &>/dev/null || \
    fail "PrometheusRule cluster-health-alerts not found in ${ctx}"
  pass "PrometheusRule present in ${ctx}"
done
echo ""

green "=========================================="
green " PrometheusRule federation E2E passed!"
green "=========================================="
echo ""
echo "Cleanup:"
echo "  kubectl --context=${HOST_CONTEXT} delete federatedprometheusrules cluster-health-alerts -n ${WORKSPACE_NAMESPACE}"
echo "  kubectl --context=${HOST_CONTEXT} delete prometheusrules.monitoring.coreos.com cluster-health-alerts -n ${WORKSPACE_NAMESPACE}"
