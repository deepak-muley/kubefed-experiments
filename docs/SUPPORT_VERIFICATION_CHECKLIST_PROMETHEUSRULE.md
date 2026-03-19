# PrometheusRule Federation Verification Checklist

When PrometheusRule federation is not working in NKP, run the following checks to diagnose. **Share the output** when troubleshooting.

---

## Brief: What worked (attach with your output when sending to support)

**What I did:**
- Created Kind clusters (cluster1, cluster2), deployed KubeFed, federated namespace `demo-app`
- Installed PrometheusRule CRD on **all** clusters (management + workload)
- Enabled type with `kubefedctl enable prometheusrules.monitoring.coreos.com` (not `PrometheusRules`)
- Created PrometheusRule on management cluster, then `kubefedctl federate` with workspace placement
- Labeled KubeFedClusters with `kommander.d2iq.io/workspace-namespace-ref: demo-app` so clusterSelector matches

**What worked:**
- PrometheusRule propagated to cluster2 automatically once the above was correct
- Federated namespace must exist on target clusters; PrometheusRule CRD must exist on all clusters
- clusterSelector picks clusters by KubeFedCluster labels — no explicit cluster names needed

**Run the one-liner below on your setup and compare the output.** Look for: federated namespaces, cluster labels, FederatedPrometheusRule status, and per-cluster CRD/namespace/PrometheusRule.

---

## Quick Verification Commands

Run these on the **management cluster** (or with appropriate kubeconfig). Replace `<kubefed-ns>` with `kube-federation-system` or `kommander` (whichever has KubeFed).

**Typical NKP namespace layout:** `kube-federation-system` exists on both mgmt and workload; `kommander` exists on mgmt only. Use `kubectl get ns` on each cluster to confirm.

### 1. PrometheusRule type enabled (correct syntax)

```bash
kubectl get federatedtypeconfigs -n <kubefed-ns> | grep -i prometheus
```

**Expected:** `prometheusrules.monitoring.coreos.com` (not `PrometheusRules`)

**If missing:** You may have used `kubefedctl enable PrometheusRules` instead of `prometheusrules.monitoring.coreos.com`.

---

### 2. KubeFed namespace correct

```bash
kubectl get kubefedclusters -A
kubectl get federatedtypeconfigs -A
```

**Check:** Which namespace has these resources? Use that same namespace for `--kubefed-namespace` in all kubefedctl commands.

---

### 3. Discover federated namespaces (do not assume)

```bash
# List ALL federated namespaces — use these, don't assume "kommander"
kubectl get federatednamespaces -A
```

**Output:** NAMESPACE and NAME columns. Each row is a namespace that is federated. The PrometheusRule must live in one of these namespaces to propagate.

**Common pitfall:** The `kommander` namespace is often federated only to the host-cluster, not to workload clusters. Use a **workspace namespace** (e.g. `my-workspace`, `my-workspace`) that is federated to the workload clusters.

**If empty:** No namespaces are federated — federate the target namespace first (e.g. `kubefedctl federate namespace <workspace-ns>`).

---

### 4. Target namespace federated to workload clusters (critical)

Cross-check: the PrometheusRule's namespace must **exist on each workload cluster** that receives the rule. Check FederatedNamespace placement — does it include the workload clusters?

```bash
# For the namespace where the PrometheusRule lives (from kubectl get federatedprometheusrules -A)
kubectl get federatednamespace <target-ns> -n <target-ns> -o yaml
# Inspect spec.placement — does it include the workload clusters?

# On each workload cluster — does the namespace exist?
kubectl --context=<workload> get ns <target-ns>
```

**Expected:** FederatedNamespace exists; its placement includes workload clusters; namespace exists on each workload cluster.

**If namespace missing on workload:** This is the most common cause. The `kommander` namespace is typically only on host-cluster. Use a workspace namespace (e.g. `my-workspace`) that is federated to workload clusters, or federate the target namespace to workloads.

---

### 5. KubeFedCluster labels (for workspace placement)

```bash
kubectl get kubefedclusters -n <kubefed-ns> -o yaml
```

**Check:** Do workload clusters have `kommander.d2iq.io/workspace-namespace-ref: <workspace-namespace>`?

**If missing:** No clusters match `clusterSelector` — attach clusters to the workspace in Kommander.

---

### 6. PrometheusRule CRD on workload clusters

```bash
kubectl --context=<workload> get crd prometheusrules.monitoring.coreos.com
```

**Run on each workload cluster** that should receive the rule.

**If missing:** Install Prometheus Operator or the PrometheusRule CRD on each target cluster.

---

### 7. FederatedPrometheusRule status and events

```bash
# First list all FederatedPrometheusRules to find namespace and name
kubectl get federatedprometheusrules -A

# Then describe (use namespace from above)
kubectl describe federatedprometheusrules <rule-name> -n <namespace>
```

**Look for:**
- `status.conditions` — Propagation: True/False
- `status.clusters` — per-cluster status (CreationFailed, ClusterNotReady, NamespaceNotFederated, etc.)
- Events — ComputePlacementFailed, CreationFailed, etc.

---

### 8. KubeFedCluster names (for explicit placement)

If using `placement.clusters: [{name: "..."}]`:

```bash
kubectl get kubefedclusters -n <kubefed-ns> -o custom-columns=NAME:.metadata.name
```

**Check:** Use exact `NAME` from output, not Kommander display name.

---

### 9. KubeFed controller logs

```bash
kubectl logs deployment/kubefed-controller-manager -n <kubefed-ns> --tail=200
```

**Look for:** Errors mentioning the PrometheusRule name or `prometheusrules`.

---

### 10. All-cluster verification (run on each cluster)

For each KubeFedCluster (management + workload), verify CRD, namespace, PrometheusRule, and Ready status:

```bash
KUBEFED_NS="<kubefed-ns>"
TARGET_NS="<namespace>"    # from kubectl get federatedprometheusrules -A
RULE_NAME="<rule-name>"    # from kubectl get federatedprometheusrules -A

for ctx in $(kubectl get kubefedclusters -n $KUBEFED_NS -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do
  echo "=== $ctx ==="
  kubectl --context=$ctx get crd prometheusrules.monitoring.coreos.com &>/dev/null && echo "  CRD: OK" || echo "  CRD: MISSING"
  kubectl --context=$ctx get ns $TARGET_NS &>/dev/null && echo "  Namespace: OK" || echo "  Namespace: MISSING"
  kubectl --context=$ctx -n $TARGET_NS get prometheusrules.monitoring.coreos.com $RULE_NAME &>/dev/null && echo "  PrometheusRule: OK" || echo "  PrometheusRule: MISSING"
  ready=$(kubectl get kubefedclusters $ctx -n $KUBEFED_NS -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  echo "  KubeFedCluster Ready: ${ready:-Unknown}"
  echo ""
done
```

**Interpretation:**
- **CRD MISSING** — Install PrometheusRule CRD on that cluster
- **Namespace MISSING** — Namespace not federated to that cluster
- **PrometheusRule MISSING** — Propagation failed; check FederatedPrometheusRule status and controller logs
- **Ready False/Unknown** — Cluster not healthy; KubeFed cannot propagate

---

### 11. Cluster connectivity (can management reach each cluster?)

```bash
for ctx in $(kubectl get kubefedclusters -n <kubefed-ns> -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do
  echo -n "$ctx: " && kubectl --context=$ctx cluster-info 2>&1 | head -1 || echo "UNREACHABLE"
done
```

**If UNREACHABLE:** Network, kubeconfig, or cluster API down.

---

## Summary Table

| # | Check | Command | Common failure |
|---|-------|---------|----------------|
| 1 | Type enabled | `kubectl get federatedtypeconfigs \| grep prometheus` | Wrong syntax: `PrometheusRules` vs `prometheusrules.monitoring.coreos.com` |
| 2 | KubeFed namespace | `kubectl get kubefedclusters -A` | Mismatch between enable/federate commands |
| 3 | **Discover federated namespaces** | `kubectl get federatednamespaces -A` | Do not assume; use discovered list |
| 4 | Namespace federated | `kubectl get federatednamespace <ns>` | Target namespace not in federated list |
| 5 | Cluster labels | `kubectl get kubefedclusters -o yaml` | No clusters match clusterSelector |
| 6 | CRD on workload | `kubectl --context=<wl> get crd prometheusrules...` | CRD missing on target cluster |
| 7 | FederatedPrometheusRule status | `kubectl get federatedprometheusrules -A` then `describe` | CreationFailed, NamespaceNotFederated, etc. |
| 8 | Cluster names | `kubectl get kubefedclusters -o custom-columns=NAME:.metadata.name` | Wrong name in explicit placement |
| 9 | Controller logs | `kubectl logs deployment/kubefed-controller-manager` | API/CRD/RBAC errors |
| 10 | **All clusters: CRD, NS, Rule, Ready** | Loop over kubefedclusters; check each | CRD/namespace missing; propagation failed; cluster NotReady |
| 11 | **Cluster connectivity** | `kubectl --context=<ctx> cluster-info` per cluster | Network/kubeconfig/API unreachable |

---

## One-Liner to Collect All (for support)

```bash
echo "=== federatedtypeconfigs ===" && kubectl get federatedtypeconfigs -A | grep -E "prometheus|NAME"
echo "=== kubefedclusters ===" && kubectl get kubefedclusters -A
echo "=== kubefedcluster labels ===" && kubectl get kubefedclusters -A -o json | python3 -c "import json,sys; [print(i['metadata']['name']+': '+str(i['metadata'].get('labels',{}))) for i in json.load(sys.stdin).get('items',[])]" 2>/dev/null || kubectl get kubefedclusters -A -o yaml
echo "=== federated namespaces (discover, do not assume) ===" && kubectl get federatednamespaces -A
echo "=== federatedprometheusrules (all namespaces) ===" && kubectl get federatedprometheusrules -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PROPAGATION:.status.conditions 2>/dev/null || kubectl get federatedprometheusrules -A
echo "=== cluster connectivity ===" && for ctx in $(kubectl get kubefedclusters -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null); do echo -n "$ctx: "; kubectl --context=$ctx cluster-info 2>&1 | head -1 || echo "UNREACHABLE"; done
```

**For all-cluster verification (CRD, namespace, PrometheusRule per cluster):** run step 10 separately after setting `KUBEFED_NS`, `TARGET_NS`, and `RULE_NAME` from the output above.

Run this and share output when troubleshooting (redact secrets if needed).

