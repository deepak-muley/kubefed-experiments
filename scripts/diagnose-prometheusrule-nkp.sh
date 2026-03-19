#!/usr/bin/env bash
# Diagnose why PrometheusRule is not on workload clusters.
# Run from repo root. Set MGMT_KUBECONFIG, WL1_KUBECONFIG, WL2_KUBECONFIG (or NKP_WS).
#
# How to verify if a namespace is federated to workload clusters:
#   1. Direct check: kubectl get ns <namespace> on each workload cluster.
#   2. FederatedNamespace placement: kubectl get federatednamespace <ns> -n <ns> -o yaml
#      Example: kommander often has placement matching host-cluster only; workspace namespaces
#      have placement matching workload clusters (kommander.d2iq.io/workspace-namespace-ref).

set -o nounset

NKP_WS="${NKP_WS:-}"
MGMT_KUBECONFIG="${MGMT_KUBECONFIG:-${NKP_WS:+${NKP_WS}/mgmt-cluster.conf}}"
WL1_KUBECONFIG="${WL1_KUBECONFIG:-${NKP_WS:+${NKP_WS}/workload-1.kubeconfig}}"
WL2_KUBECONFIG="${WL2_KUBECONFIG:-${NKP_WS:+${NKP_WS}/workload-2.kubeconfig}}"
KUBEFED_NS="${KUBEFED_NS:-kube-federation-system}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-kommander}"
RULE_NAME="${RULE_NAME:-cluster-health-alerts}"

echo "=========================================="
echo " PrometheusRule Propagation Diagnostic (NKP)"
echo "=========================================="
echo ""

echo "1. FederatedNamespace for '${TARGET_NAMESPACE}' - placement (which clusters get this namespace)"
echo "   FederatedNamespace.spec.placement defines which clusters receive this namespace."
echo "   If placement excludes workload clusters, the namespace won't exist there."
echo ""
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get federatednamespace "${TARGET_NAMESPACE}" -n "${TARGET_NAMESPACE}" -o yaml 2>/dev/null | grep -A 30 "spec:" | head -35 || echo "   (FederatedNamespace not found)"
echo ""

echo "2. Does '${TARGET_NAMESPACE}' namespace exist on each cluster?"
for label in "Workload 1" "Workload 2"; do
  case "${label}" in
    "Workload 1") kc="${WL1_KUBECONFIG}" ;;
    "Workload 2") kc="${WL2_KUBECONFIG}" ;;
  esac
  if KUBECONFIG="${kc}" kubectl get ns "${TARGET_NAMESPACE}" &>/dev/null; then
    echo "   ${label}: YES"
  else
    echo "   ${label}: NO  <-- namespace missing, PrometheusRule cannot propagate"
  fi
done
echo ""

echo "3. FederatedPrometheusRule status.clusters (per-cluster propagation status)"
echo "   Look for: CreationFailed, NamespaceNotFederated, ClusterNotReady"
echo ""
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get federatedprometheusrules "${RULE_NAME}" -n "${TARGET_NAMESPACE}" -o yaml 2>/dev/null | grep -A 100 "status:" | head -60 || echo "   (resource not found)"
echo ""

echo "4. KubeFedCluster labels vs FederatedPrometheusRule placement"
echo "   FederatedPrometheusRule placement uses clusterSelector (e.g. workspace-namespace-ref)."
echo "   But the TARGET NAMESPACE (${TARGET_NAMESPACE}) must also exist on those clusters."
echo ""
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get kubefedclusters -n "${KUBEFED_NS}" -o custom-columns=NAME:.metadata.name,WORKSPACE:.metadata.labels.kommander\.d2iq\.io/workspace-namespace-ref 2>/dev/null
echo ""

echo "5. RECOMMENDATION"
echo "   If '${TARGET_NAMESPACE}' namespace does NOT exist on workload clusters:"
echo "   - Use a namespace that IS federated to workload clusters (e.g. your workspace namespace)"
echo "   - Set TARGET_NAMESPACE=<workspace-ns> and re-run with a PrometheusRule in that ns"
echo ""
echo "   If '${TARGET_NAMESPACE}' exists on workloads but rule still missing:"
echo "   - Check KubeFed controller logs: kubectl logs -n ${KUBEFED_NS} -l control-plane=kubefed-controller-manager --tail=100"
echo ""
