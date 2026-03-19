# Troubleshooting: PrometheusRule Federation Not Propagating in NKP

This document addresses the issue where a custom PrometheusRule is successfully created on the NKP management cluster but **does not propagate** to workload clusters, despite correct `kubefedctl` commands and both workspace-based and explicit cluster placement.

---

## Scenario Summary

- **Management cluster**: CDC/NKP with Kommander
- **Target**: Federate custom PrometheusRule `cluster-health-alerts` from `kommander` namespace to workload clusters
- **Placement tried**: (1) Workspace-based (`my-workspace`), (2) Explicit cluster (`workload-cluster-1`)
- **Result**: Rule exists on mgmt cluster but does not propagate
- **Version**: kubefedctl binary labeled 0.10.0 but reports v0.9.2

---

## Root Cause Checklist

### 1. Incorrect `kubefedctl enable` Syntax

**What you ran:**
```bash
kubefedctl enable PrometheusRules --kubefed-namespace kommander
```

**Issue:** `kubefedctl enable` expects the **fully qualified API type** (group-qualified plural), not the short kind name.

**Correct command** (use your actual KubeFed namespace):
```bash
kubefedctl enable prometheusrules.monitoring.coreos.com --kubefed-namespace=<kubefed-ns>
```

**Verification:**
```bash
kubectl get federatedtypeconfigs -n <kubefed-ns> | grep -i prometheus
# Should show: prometheusrules.monitoring.coreos.com
```

If the FederatedTypeConfig was never created correctly, the sync controller for PrometheusRule will not run, and no propagation occurs.

---

### 2. Wrong KubeFed Namespace

**What you used:** `--kubefed-namespace kommander`

**Issue:** The `--kubefed-namespace` must match where KubeFed actually runs. In NKP with Kommander, this can be either:
- `kube-federation-system` (default KubeFed install)
- `kommander` (if Kommander deploys KubeFed there)

**Typical NKP namespace layout:**
| Namespace | Mgmt cluster | Workload cluster |
|-----------|--------------|------------------|
| `kube-federation-system` | Yes (KubeFed controller, KubeFedClusters) | Yes |
| `kommander` | Yes | No |
| `kommander-flux` | Yes | Yes |

Use `kube-federation-system` for `--kubefed-namespace` unless KubeFed is deployed in `kommander` on your setup.

**Verification:** Find the actual KubeFed namespace:
```bash
kubectl get kubefedclusters -A
kubectl get federatedtypeconfigs -A
# Use the namespace where these resources exist
```

Then use that namespace consistently:
```bash
--kubefed-namespace=<actual-kubefed-namespace>
```

**Note:** In your federate command you used `--kubefed-namespace=kube-federation-system` while enable used `kommander`. Use the **same** namespace for both.

---

### 3. Target Namespace Not Federated (Most Common Cause)

**Critical:** The target namespace must **exist on all target workload clusters** before a FederatedPrometheusRule can propagate. In NKP, the `kommander` namespace is **often federated only to the host-cluster (management)**, not to workload clusters. If you use `kommander` and place the rule to workload clusters, it will not propagate.

**Check:**
```bash
# On management cluster: Is there a FederatedNamespace for the target namespace?
kubectl get federatednamespace <target-ns> -n <target-ns> -o yaml
# Inspect spec.placement — does it include workload clusters?

# On each workload cluster: Does the namespace exist?
kubectl --context=<workload-kubeconfig> get ns <target-ns>
```

**If the namespace does not exist on workload clusters:**
- **Recommended:** Place the PrometheusRule in a **workspace namespace** (e.g. `my-workspace`, `my-workspace`) that is federated to your workload clusters.
- Or federate the target namespace to the workload clusters first (may require Kommander/NKP configuration).

---

### 4. KubeFedCluster Labels for Workspace Placement

For `clusterSelector.matchLabels: kommander.d2iq.io/workspace-namespace-ref: my-workspace` to work, the **KubeFedCluster** objects for the workload clusters must have that label.

**Check:**
```bash
kubectl get kubefedclusters -n kube-federation-system -o custom-columns=NAME:.metadata.name,LABELS:.metadata.labels
```

**Expected:** Workload clusters attached to the `my-workspace` workspace should have:
```yaml
metadata:
  labels:
    kommander.d2iq.io/workspace-namespace-ref: my-workspace
```

**If labels are missing:** The cluster is not associated with the workspace. Attach the cluster to the `my-workspace` workspace via Kommander UI/API so the label is applied.

---

### 5. KubeFedCluster Name Mismatch

**What you used:** `clusters: [{"name": "workload-cluster-1"}]`

**Issue:** The KubeFedCluster `metadata.name` may not match the Kommander cluster name. NKP/Kommander often names KubeFedClusters differently (e.g. from `KommanderCluster.metadata.name` or a generated ID).

**Check actual names:**
```bash
kubectl get kubefedclusters -n kube-federation-system -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status
```

Use the **exact** `NAME` from this output in `spec.placement.clusters`.

---

### 6. PrometheusRule CRD on Workload Clusters

**Requirement:** The PrometheusRule CRD (`prometheusrules.monitoring.coreos.com`) must be installed on **every** cluster that receives the federated resource. If it exists only on the management cluster, propagation to workload clusters will fail.

**Check:**
```bash
# On each workload cluster
kubectl --context=<workload> get crd prometheusrules.monitoring.coreos.com
```

**If CRD is missing:** Install Prometheus Operator (or at least the PrometheusRule CRD) on each workload cluster before federating.

---

### 7. kubefedctl Version Mismatch (v0.9.2 vs 0.10.0)

**Observation:** Binary labeled `kubefedctl-0.10.0-linux-amd64` reports `v0.9.2-29-g76ad91b1f`.

**Implications:**
- The binary is built from a v0.9.2 base with additional commits (likely from NKP/Kommander fork).
- v0.9.2 has known limitations and bugs that were fixed in v0.10.0 (e.g. Ingress propagation, controller panic fixes, SA token handling).
- CRD federation behavior may differ between versions.

**Recommendation:** Use a kubefedctl version that matches the KubeFed controller version deployed in the cluster. Check the controller image:
```bash
kubectl get deployment kubefed-controller-manager -n kube-federation-system -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Align kubefedctl with that version. NKP 2.15 may ship a specific KubeFed version; use the kubefedctl provided by Nutanix for that release.

---

### 8. Propagation Status and Events

**Diagnose propagation failures:**
```bash
# Check FederatedPrometheusRule status
kubectl describe federatedprometheusrules.monitoring.coreos.com cluster-health-alerts -n kommander

# Look for:
# - status.conditions (Propagation: True/False)
# - status.clusters (per-cluster status: CreationFailed, ClusterNotReady, etc.)
# - Events (ComputePlacementFailed, CreationFailed, etc.)
```

**Common failure reasons in status:**
- `ClusterNotReady` — KubeFedCluster not healthy
- `CreationFailed` — API error (e.g. CRD missing, RBAC, namespace missing)
- `NamespaceNotFederated` — Containing namespace not federated
- `ComputePlacementFailed` — No clusters matched placement (wrong labels or names)

---

## Answers to Your Questions

### Q1: Will this work for a custom PrometheusRule, or only for default rules present on all clusters?

**Answer:** Federation works for **any** PrometheusRule (custom or default) as long as:

1. The PrometheusRule CRD exists on all target clusters.
2. The type is correctly enabled: `kubefedctl enable prometheusrules.monitoring.coreos.com`
3. The containing namespace is federated to the target clusters.
4. Placement (clusterSelector or clusters) correctly targets the intended KubeFedClusters.
5. KubeFedCluster resources are Ready.

Custom rules are not treated differently from default rules. The blocker is usually one of the conditions above (often namespace or CRD).

### Q2: If it's not supported, should we configure rules on all clusters directly?

**Answer:** Federation **is** supported for PrometheusRule. Before falling back to per-cluster configuration:

1. **Verify the checklist above** — especially `kubefedctl enable` syntax, namespace federation, and KubeFedCluster labels/names.
2. **Check controller logs:**
   ```bash
   kubectl logs deployment/kubefed-controller-manager -n kube-federation-system --tail=200
   ```
   Look for errors related to `cluster-health-alerts` or `prometheusrules`.
3. **Confirm FederatedTypeConfig:**
   ```bash
   kubectl get federatedtypeconfig prometheusrules.monitoring.coreos.com -n kube-federation-system -o yaml
   ```
   Ensure `spec.propagation` is not `Disabled`.

If federation still fails after these checks, **direct configuration on each cluster** is a valid workaround. You would maintain the same PrometheusRule YAML (or a GitOps manifest) and apply it to each workload cluster. The trade-off is loss of centralized placement control and manual updates per cluster.

---

## Recommended Corrected Workflow

```bash
# 1. Use correct KubeFed namespace and type name
kubefedctl enable prometheusrules.monitoring.coreos.com --kubefed-namespace=kube-federation-system

# 2. Verify FederatedTypeConfig
kubectl get federatedtypeconfigs -n kube-federation-system | grep prometheus

# 3. Ensure kommander namespace is federated to target clusters (or use a federated namespace)
kubectl get federatednamespace kommander -n kommander -o yaml

# 4. Federate with workspace placement (after verifying KubeFedCluster labels)
kubefedctl federate prometheusrules.monitoring.coreos.com cluster-health-alerts \
  --kubefed-namespace=kube-federation-system -n kommander -o yaml | \
  yq '.spec.placement = {"clusterSelector": {"matchLabels": {"kommander.d2iq.io/workspace-namespace-ref": "my-workspace"}}}' - | \
  kubectl apply -f -

# 5. Verify propagation
kubectl describe federatedprometheusrules.monitoring.coreos.com cluster-health-alerts -n kommander
```

---

## Support Verification Checklist

Use [SUPPORT_VERIFICATION_CHECKLIST_PROMETHEUSRULE.md](SUPPORT_VERIFICATION_CHECKLIST_PROMETHEUSRULE.md) — a quick list of commands to verify your setup.

---

## References

- [Nutanix NKP: Federate Prometheus Alerting Rules](https://portal.nutanix.com/page/documents/details?targetId=Nutanix-Kubernetes-Platform-v2_15:top-federate-prometheus-alerting-rules-t.html)
- Nutanix NKP documentation — KubeFed architecture in NKP
- [KubeFed User Guide - Enabling Federation](https://github.com/mesosphere/kubefed/blob/master/docs/userguide.md#enabling-federation-of-an-api-type)
