#!/usr/bin/env bash
# Verify PrometheusRule federation to all clusters.
# Prerequisites: clusters created, KubeFed deployed, PrometheusRule federated.
# Usage: ./scripts/verify-prometheusrule-federation.sh

set -o errexit
set -o nounset

HOST_CONTEXT="${HOST_CONTEXT:-cluster1}"
KUBEFED_NS="${KUBEFED_NS:-kube-federation-system}"
WORKSPACE_NAMESPACE="${WORKSPACE_NAMESPACE:-demo-app}"
RULE_NAME="${RULE_NAME:-cluster-health-alerts}"

echo "=========================================="
echo " PrometheusRule Federation Verification"
echo "=========================================="
echo ""

echo "--- SETUP COMMANDS (that caused this state) ---"
echo ""
echo "# 0. Prerequisites: create clusters, deploy KubeFed, federate namespace (demo-app)"
echo "#    Install PrometheusRule CRD on all clusters"
echo ""
echo "# 1. Enable PrometheusRule type for federation"
echo "kubefedctl enable prometheusrules.monitoring.coreos.com --kubefed-namespace=${KUBEFED_NS}"
echo ""
echo "# 2. Create PrometheusRule on MANAGEMENT cluster only (${HOST_CONTEXT}) - SOURCE, created first"
echo "#    This creates the rule ONLY on ${HOST_CONTEXT}. Other clusters do not have it yet."
echo "kubectl --context=${HOST_CONTEXT} apply -f prometheusrule-demo/cluster-health-alerts.yaml"
echo ""
echo "# 3. Federate = creates FederatedPrometheusRule; KubeFed AUTOMATICALLY propagates to other clusters"
echo "#    This command triggers propagation to cluster2, cluster3, etc. (all matching placement)"
echo "kubefedctl federate prometheusrules.monitoring.coreos.com ${RULE_NAME} \\"
echo "  --kubefed-namespace=${KUBEFED_NS} -n ${WORKSPACE_NAMESPACE} -o yaml | \\"
echo "  yq '.spec.placement = {\"clusterSelector\": {\"matchLabels\": {\"kommander.d2iq.io/workspace-namespace-ref\": \"${WORKSPACE_NAMESPACE}\"}}}' - | \\"
echo "  kubectl --context=${HOST_CONTEXT} apply -f -"
echo ""
echo "--- VERIFICATION COMMANDS ---"
echo ""

echo "1. Member clusters"
echo "   Command: kubectl --context=${HOST_CONTEXT} get kubefedclusters -n ${KUBEFED_NS}"
echo "   Output:"
kubectl --context="${HOST_CONTEXT}" get kubefedclusters -n "${KUBEFED_NS}" | sed 's/^/   /'
echo ""
echo "1b. Cluster labels (clusterSelector matches clusters with kommander.d2iq.io/workspace-namespace-ref=${WORKSPACE_NAMESPACE})"
echo "   Command: kubectl --context=${HOST_CONTEXT} get kubefedclusters -n ${KUBEFED_NS} -o yaml"
echo "   (Labels extracted below; full YAML shows labels under each cluster's metadata)"
echo "   Output:"
kubectl --context="${HOST_CONTEXT}" get kubefedclusters -n "${KUBEFED_NS}" -o json 2>/dev/null | python3 -c "
import json,sys
for i in json.load(sys.stdin).get('items',[]):
    n=i['metadata']['name']
    l=i['metadata'].get('labels',{})
    lbl=', '.join(k+'='+v for k,v in l.items()) if l else '(no labels)'
    print('   '+n+': '+lbl)
" 2>/dev/null || echo "   (run: kubectl --context=${HOST_CONTEXT} get kubefedclusters -n ${KUBEFED_NS} -o yaml)"
echo ""

echo "1c. Federated type configs (all types enabled for federation)"
echo "   Command: kubectl --context=${HOST_CONTEXT} get federatedtypeconfigs -n ${KUBEFED_NS}"
echo "   Output:"
kubectl --context="${HOST_CONTEXT}" get federatedtypeconfigs -n "${KUBEFED_NS}" 2>/dev/null | sed 's/^/   /'
echo ""

echo "2. FederatedPrometheusRule propagation status"
echo "   Command: kubectl --context=${HOST_CONTEXT} get federatedprometheusrules ${RULE_NAME} -n ${WORKSPACE_NAMESPACE} -o jsonpath='{.status.conditions[?(@.type==\"Propagation\")].status}'"
status=$(kubectl --context="${HOST_CONTEXT}" get federatedprometheusrules "${RULE_NAME}" -n "${WORKSPACE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Propagation")].status}' 2>/dev/null || echo "Unknown")
echo "   Output: Propagation=${status}"
echo ""

echo "3. FederatedPrometheusRule details"
echo "   Command: kubectl --context=${HOST_CONTEXT} describe federatedprometheusrules ${RULE_NAME} -n ${WORKSPACE_NAMESPACE}"
echo "   Output:"
kubectl --context="${HOST_CONTEXT}" describe federatedprometheusrules "${RULE_NAME}" -n "${WORKSPACE_NAMESPACE}" | tail -25 | sed 's/^/   /'
echo ""

echo "4. PrometheusRule in each cluster"
echo "   (${HOST_CONTEXT} = source/created first; others = propagated by kubefedctl federate)"
clusters=$(kubectl --context="${HOST_CONTEXT}" get kubefedclusters -n "${KUBEFED_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null | tr -d '\n')
for ctx in ${clusters}; do
  if [[ "${ctx}" == "${HOST_CONTEXT}" ]]; then
    role="source (created first)"
  else
    role="propagated"
  fi
  echo "   Command: kubectl --context=${ctx} -n ${WORKSPACE_NAMESPACE} get prometheusrules.monitoring.coreos.com ${RULE_NAME}"
  if kubectl --context="${ctx}" -n "${WORKSPACE_NAMESPACE}" get prometheusrules.monitoring.coreos.com "${RULE_NAME}" &>/dev/null; then
    echo "   Output (${ctx}, ${role}): OK - PrometheusRule found"
  else
    echo "   Output (${ctx}, ${role}): NOT FOUND"
    exit 1
  fi
done
echo ""

echo "--- Verification complete ---"
