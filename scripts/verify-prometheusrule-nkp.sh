#!/usr/bin/env bash
# Verify PrometheusRule federation on NKP clusters.
# Set MGMT_KUBECONFIG, WL1_KUBECONFIG, WL2_KUBECONFIG (or NKP_WS).
# Run after: ./scripts/run-prometheusrule-nkp.sh

set -o errexit
set -o nounset

NKP_WS="${NKP_WS:-}"
MGMT_KUBECONFIG="${MGMT_KUBECONFIG:-${NKP_WS:+${NKP_WS}/mgmt-cluster.conf}}"
WL1_KUBECONFIG="${WL1_KUBECONFIG:-${NKP_WS:+${NKP_WS}/workload-1.kubeconfig}}"
WL2_KUBECONFIG="${WL2_KUBECONFIG:-${NKP_WS:+${NKP_WS}/workload-2.kubeconfig}}"

KUBEFED_NS="${KUBEFED_NS:-kube-federation-system}"
WORKSPACE_NAMESPACE="${WORKSPACE_NAMESPACE:-my-workspace}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-my-workspace}"
RULE_NAME="${RULE_NAME:-cluster-health-alerts}"

echo "=========================================="
echo " PrometheusRule Federation Verification (NKP)"
echo "=========================================="
echo ""
echo "Mgmt:       ${MGMT_KUBECONFIG}"
echo "Workload 1: ${WL1_KUBECONFIG}"
echo "Workload 2: ${WL2_KUBECONFIG}"
echo ""

echo "1. KubeFedClusters"
echo "   Command: KUBECONFIG=\$MGMT_KUBECONFIG kubectl get kubefedclusters -n ${KUBEFED_NS}"
echo "   Output:"
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get kubefedclusters -n "${KUBEFED_NS}" | sed 's/^/   /'
echo ""

echo "2. KubeFedCluster labels (workspace-namespace-ref)"
echo "   Output:"
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get kubefedclusters -n "${KUBEFED_NS}" -o json 2>/dev/null | python3 -c "
import json,sys
for i in json.load(sys.stdin).get('items',[]):
    n=i['metadata']['name']
    ref=i['metadata'].get('labels',{}).get('kommander.d2iq.io/workspace-namespace-ref','(none)')
    print('   '+n+': '+ref)
" 2>/dev/null || echo "   (run: kubectl get kubefedclusters -n ${KUBEFED_NS} -o yaml)"
echo ""

echo "3. Namespace federation: does '${TARGET_NAMESPACE}' exist on each cluster?"
echo "   A namespace is 'federated to' a cluster if it exists there (created by FederatedNamespace)."
echo "   If missing on a workload cluster, PrometheusRule cannot propagate there."
echo "   Check: kubectl get ns <namespace> on each cluster"
echo "   Output:"
for label in Mgmt Workload1 Workload2; do
  case "${label}" in
    Mgmt)      kc="${MGMT_KUBECONFIG}" ;;
    Workload1) kc="${WL1_KUBECONFIG}" ;;
    Workload2) kc="${WL2_KUBECONFIG}" ;;
  esac
  display_label="${label}"
  [[ "${label}" == "Workload1" ]] && display_label="Workload 1"
  [[ "${label}" == "Workload2" ]] && display_label="Workload 2"
  if KUBECONFIG="${kc}" kubectl get ns "${TARGET_NAMESPACE}" &>/dev/null; then
    echo "   ${display_label}: YES (namespace exists, can receive federated resources)"
  else
    echo "   ${display_label}: NO  <-- namespace missing, PrometheusRule will NOT propagate here"
  fi
done
echo ""

echo "4. FederatedNamespace placement for '${TARGET_NAMESPACE}' (which clusters get this namespace)"
echo "   Command: KUBECONFIG=\$MGMT_KUBECONFIG kubectl get federatednamespace ${TARGET_NAMESPACE} -n ${TARGET_NAMESPACE} -o yaml"
echo "   Look at spec.placement: clusterSelector or clusters list."
echo "   Output:"
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get federatednamespace "${TARGET_NAMESPACE}" -n "${TARGET_NAMESPACE}" -o yaml 2>/dev/null | grep -A 15 "spec:" | head -20 || echo "   (FederatedNamespace not found)"
echo ""

echo "5. FederatedTypeConfigs (all federated types)"
echo "   Command: KUBECONFIG=\$MGMT_KUBECONFIG kubectl get federatedtypeconfigs -n ${KUBEFED_NS}"
echo "   Output:"
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get federatedtypeconfigs -n "${KUBEFED_NS}" 2>/dev/null | sed 's/^/   /' || echo "   (none or error)"
echo ""

echo "6. FederatedPrometheusRule propagation status"
status=$(KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get federatedprometheusrules "${RULE_NAME}" -n "${TARGET_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Propagation")].status}' 2>/dev/null || echo "Unknown")
echo "   Propagation=${status}"
echo ""

echo "7. FederatedPrometheusRule details"
echo "   Command: KUBECONFIG=\$MGMT_KUBECONFIG kubectl describe federatedprometheusrules ${RULE_NAME} -n ${TARGET_NAMESPACE}"
echo "   Output:"
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl describe federatedprometheusrules "${RULE_NAME}" -n "${TARGET_NAMESPACE}" 2>/dev/null | tail -25 | sed 's/^/   /' || echo "   (resource not found)"
echo ""

echo "8. PrometheusRule on each cluster"
for label in Mgmt Workload1 Workload2; do
  case "${label}" in
    Mgmt)      kc="${MGMT_KUBECONFIG}" ;;
    Workload1) kc="${WL1_KUBECONFIG}" ;;
    Workload2) kc="${WL2_KUBECONFIG}" ;;
  esac
  display_label="${label}"
  [[ "${label}" == "Workload1" ]] && display_label="Workload 1"
  [[ "${label}" == "Workload2" ]] && display_label="Workload 2"
  echo "   ${display_label} (${kc}):"
  if KUBECONFIG="${kc}" kubectl -n "${TARGET_NAMESPACE}" get prometheusrules.monitoring.coreos.com "${RULE_NAME}" &>/dev/null; then
    echo "     OK - PrometheusRule found"
  else
    echo "     NOT FOUND"
    exit 1
  fi
done
echo ""

echo "--- Verification complete ---"
