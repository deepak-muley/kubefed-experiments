#!/usr/bin/env bash
# PrometheusRule federation on NKP clusters.
# Set MGMT_KUBECONFIG, WL1_KUBECONFIG, WL2_KUBECONFIG (or NKP_WS) to your kubeconfig paths.
# Prerequisites: NKP clusters with KubeFedClusters already registered.
# Run from repo root.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NKP_DEMO="${REPO_ROOT}/nkp-prometheusrule-demo"
BIN_DIR="${REPO_ROOT}/bin"

# NKP kubeconfigs - set MGMT_KUBECONFIG, WL1_KUBECONFIG, WL2_KUBECONFIG
# Or set NKP_WS to dir containing mgmt-cluster.conf, workload-1.kubeconfig, workload-2.kubeconfig
NKP_WS="${NKP_WS:-}"
MGMT_KUBECONFIG="${MGMT_KUBECONFIG:-${NKP_WS:+${NKP_WS}/mgmt-cluster.conf}}"
WL1_KUBECONFIG="${WL1_KUBECONFIG:-${NKP_WS:+${NKP_WS}/workload-1.kubeconfig}}"
WL2_KUBECONFIG="${WL2_KUBECONFIG:-${NKP_WS:+${NKP_WS}/workload-2.kubeconfig}}"

KUBEFED_NS="${KUBEFED_NS:-kube-federation-system}"
# Workspace namespace - must match kommander.d2iq.io/workspace-namespace-ref on KubeFedClusters
WORKSPACE_NAMESPACE="${WORKSPACE_NAMESPACE:-my-workspace}"
# Target namespace for PrometheusRule (must be federated to workload clusters)
TARGET_NAMESPACE="${TARGET_NAMESPACE:-my-workspace}"
RULE_NAME="${RULE_NAME:-cluster-health-alerts}"
TIMEOUT=120

# Resolve kubefedctl
resolve_kubefedctl() {
  if [[ -n "${KUBEFEDCTL_PATH:-}" && -x "${KUBEFEDCTL_PATH}" ]]; then
    echo "${KUBEFEDCTL_PATH}"
    return
  fi
  if [[ -x "${BIN_DIR}/kubefedctl" ]]; then
    echo "${BIN_DIR}/kubefedctl"
    return
  fi
  if command -v kubefedctl &>/dev/null; then
    echo "kubefedctl"
    return
  fi
  echo ""
}

red() { echo -e "\033[0;31m$*\033[0m"; }
green() { echo -e "\033[0;32m$*\033[0m"; }
yellow() { echo -e "\033[0;33m$*\033[0m"; }
log() { echo "[$(date +%H:%M:%S)] $*"; }
pass() { green "  PASS: $*"; }
fail() { red "  FAIL: $*"; exit 1; }

echo "=========================================="
echo " PrometheusRule Federation - NKP Real Clusters"
echo "=========================================="
echo ""
[[ -n "${MGMT_KUBECONFIG}" || -n "${NKP_WS}" ]] || { echo "Error: Set MGMT_KUBECONFIG, WL1_KUBECONFIG, WL2_KUBECONFIG or NKP_WS"; exit 1; }
log "Mgmt kubeconfig: ${MGMT_KUBECONFIG}"
log "Workload 1:      ${WL1_KUBECONFIG}"
log "Workload 2:      ${WL2_KUBECONFIG}"
log "Workspace:       ${WORKSPACE_NAMESPACE}"
log "Target ns:       ${TARGET_NAMESPACE}"
echo ""

# Pre-checks
log "Pre-checks..."
[[ -f "${MGMT_KUBECONFIG}" ]] || fail "Mgmt kubeconfig not found: ${MGMT_KUBECONFIG}"
[[ -f "${WL1_KUBECONFIG}" ]] || fail "Workload 1 kubeconfig not found: ${WL1_KUBECONFIG}"
[[ -f "${WL2_KUBECONFIG}" ]] || fail "Workload 2 kubeconfig not found: ${WL2_KUBECONFIG}"

KUBEFEDCTL=$(resolve_kubefedctl)
[[ -n "${KUBEFEDCTL}" ]] || fail "kubefedctl not found. Run: ./scripts/download-kubefedctl.sh  OR  set KUBEFEDCTL_PATH"
log "Using kubefedctl: ${KUBEFEDCTL}"
"${KUBEFEDCTL}" version 2>/dev/null || true

KUBECONFIG="${MGMT_KUBECONFIG}" kubectl cluster-info &>/dev/null || fail "Cannot reach management cluster"
clusters=$(KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get kubefedclusters -n "${KUBEFED_NS}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null | tr -d '\n')
[[ -n "${clusters}" ]] || fail "No KubeFedClusters found in ${KUBEFED_NS}"
log "KubeFedClusters: ${clusters}"
echo ""

# Step 0: Ensure PrometheusRule CRD on all clusters
log "Step 0: Verifying PrometheusRule CRD on all clusters..."
CRD_URL="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml"
for kc in "${MGMT_KUBECONFIG}" "${WL1_KUBECONFIG}" "${WL2_KUBECONFIG}"; do
  KUBECONFIG="${kc}" kubectl get crd prometheusrules.monitoring.coreos.com &>/dev/null || {
    KUBECONFIG="${kc}" kubectl apply -f "${CRD_URL}" || \
      KUBECONFIG="${kc}" kubectl apply -f "${REPO_ROOT}/prometheusrule-demo/prometheusrule-crd.yaml"
  }
  pass "PrometheusRule CRD OK on $(basename "${kc}")"
done
echo ""

# Step 1: Enable PrometheusRule type for federation
log "Step 1: kubefedctl enable prometheusrules.monitoring.coreos.com..."
log "FederatedTypeConfigs BEFORE enable:"
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get federatedtypeconfigs -n "${KUBEFED_NS}" 2>/dev/null | sed 's/^/  /' || true
KUBECONFIG="${MGMT_KUBECONFIG}" "${KUBEFEDCTL}" enable prometheusrules.monitoring.coreos.com \
  --kubefed-namespace="${KUBEFED_NS}"
pass "PrometheusRule type enabled"
log "FederatedTypeConfigs AFTER enable:"
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get federatedtypeconfigs -n "${KUBEFED_NS}" 2>/dev/null | sed 's/^/  /' || true
echo ""

# Step 2: Create PrometheusRule on management cluster
# Use YAML matching TARGET_NAMESPACE (workspace or kommander)
log "Step 2: Creating PrometheusRule ${RULE_NAME}..."
if [[ "${TARGET_NAMESPACE}" == "kommander" ]]; then
  KUBECONFIG="${MGMT_KUBECONFIG}" kubectl apply -f "${NKP_DEMO}/cluster-health-alerts-kommander.yaml"
else
  # Workspace template: substitute namespace
  sed "s/namespace: my-workspace/namespace: ${TARGET_NAMESPACE}/" "${NKP_DEMO}/cluster-health-alerts-workspace.yaml" | \
    KUBECONFIG="${MGMT_KUBECONFIG}" kubectl apply -f -
fi
pass "PrometheusRule created"
echo ""

# Step 3: Federate with workspace placement
# kubefedctl must use MGMT_KUBECONFIG to find the PrometheusRule on the mgmt cluster
log "Step 3: Federating with workspace placement (${WORKSPACE_NAMESPACE})..."
if command -v yq &>/dev/null; then
  KUBECONFIG="${MGMT_KUBECONFIG}" "${KUBEFEDCTL}" federate prometheusrules.monitoring.coreos.com "${RULE_NAME}" \
    --kubefed-namespace="${KUBEFED_NS}" -n "${TARGET_NAMESPACE}" -o yaml | \
    yq '.spec.placement = {"clusterSelector": {"matchLabels": {"kommander.d2iq.io/workspace-namespace-ref": "'"${WORKSPACE_NAMESPACE}"'"}}}' - | \
    KUBECONFIG="${MGMT_KUBECONFIG}" kubectl apply -f -
else
  KUBECONFIG="${MGMT_KUBECONFIG}" "${KUBEFEDCTL}" federate prometheusrules.monitoring.coreos.com "${RULE_NAME}" \
    --kubefed-namespace="${KUBEFED_NS}" -n "${TARGET_NAMESPACE}" -o json | \
    jq '.spec.placement = {"clusterSelector": {"matchLabels": {"kommander.d2iq.io/workspace-namespace-ref": "'"${WORKSPACE_NAMESPACE}"'"}}}' | \
    KUBECONFIG="${MGMT_KUBECONFIG}" kubectl apply -f -
fi
pass "FederatedPrometheusRule created"
echo ""

# Step 4: Wait for propagation
log "Step 4: Waiting for propagation..."
elapsed=0
status="Unknown"
while [[ ${elapsed} -lt ${TIMEOUT} ]]; do
  status=$(KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get federatedprometheusrules "${RULE_NAME}" -n "${TARGET_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Propagation")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${status}" == "True" ]]; then
    pass "FederatedPrometheusRule propagated"
    break
  fi
  if [[ ${elapsed} -gt 30 ]]; then
    KUBECONFIG="${MGMT_KUBECONFIG}" kubectl describe federatedprometheusrules "${RULE_NAME}" -n "${TARGET_NAMESPACE}" | tail -30
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
[[ "${status}" == "True" ]] || fail "Propagation did not complete within ${TIMEOUT}s"
echo ""

# Step 5: Verify PrometheusRule on each cluster
log "Step 5: Verifying PrometheusRule on each cluster..."
for label in Mgmt Workload1 Workload2; do
  case "${label}" in
    Mgmt)      kc="${MGMT_KUBECONFIG}" ;;
    Workload1) kc="${WL1_KUBECONFIG}" ;;
    Workload2) kc="${WL2_KUBECONFIG}" ;;
  esac
  display_label="${label}"; [[ "${label}" == "Workload1" ]] && display_label="Workload 1"; [[ "${label}" == "Workload2" ]] && display_label="Workload 2"
  KUBECONFIG="${kc}" kubectl -n "${TARGET_NAMESPACE}" get prometheusrules.monitoring.coreos.com "${RULE_NAME}" &>/dev/null || \
    fail "PrometheusRule ${RULE_NAME} not found on ${display_label}"
  pass "PrometheusRule present on ${display_label}"
done
echo ""

green "=========================================="
green " PrometheusRule federation on NKP passed!"
green "=========================================="
echo ""
echo "Cleanup:"
echo "  KUBECONFIG=${MGMT_KUBECONFIG} kubectl delete federatedprometheusrules ${RULE_NAME} -n ${TARGET_NAMESPACE}"
echo "  KUBECONFIG=${MGMT_KUBECONFIG} kubectl delete prometheusrules.monitoring.coreos.com ${RULE_NAME} -n ${TARGET_NAMESPACE}"
