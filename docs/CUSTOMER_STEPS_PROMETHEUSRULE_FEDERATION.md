# Federating Custom PrometheusRule in NKP

These steps have been validated against the e2e demo in this repo. Use them to federate custom PrometheusRules (e.g. AlertManager rules) to workload clusters in NKP.

---

## Prerequisites (Verify First)

1. **PrometheusRule CRD** must exist on **all** target clusters (workload + management). If using kube-prometheus-stack, it is already installed. Otherwise:
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
   ```
   Run this on each cluster that will receive the federated rule.

2. **Target namespace** must be **federated to the workload clusters** you are targeting. **Important:** The `kommander` namespace is often federated only to the host-cluster (management), not to workload clusters. Use a **workspace namespace** (e.g. `my-workspace`, `prod-workspace`) that is federated to your workload clusters. Check:
   ```bash
   kubectl get federatednamespace <namespace> -n <namespace>
   kubectl --context=<workload> get ns <namespace>
   ```
   If the namespace does not exist on the workload cluster, the PrometheusRule will not propagate there.

3. **KubeFedCluster labels**: For workspace-based placement, workload clusters must have the label `kommander.d2iq.io/workspace-namespace-ref: <workspace-namespace>`. This is set when clusters are attached to a workspace.
   ```bash
   kubectl get kubefedclusters -n kube-federation-system -o custom-columns=NAME:.metadata.name,LABELS:.metadata.labels
   ```

4. **kubefedctl** installed and matching the KubeFed controller version. Options:
   - **Download** from [kubernetes-retired/kubefed v0.9.2](https://github.com/kubernetes-retired/kubefed/releases/tag/v0.9.2):
     - If using this repo: `./scripts/download-kubefedctl.sh v0.9.2` (installs to `bin/kubefedctl`)
     - Manual: download `kubefedctl-0.9.2-<os>-<arch>.tgz` from the [releases page](https://github.com/kubernetes-retired/kubefed/releases/tag/v0.9.2), extract, and add to `PATH` or set `KUBEFEDCTL_PATH`
   - Use the NKP/Kommander bundle, or build from [mesosphere/kubefed](https://github.com/mesosphere/kubefed).

5. **Get workspace namespace**:
   ```bash
   nkp get workspaces
   # Use the value under NAMESPACE column for your workspace (e.g. my-workspace, prod-workspace)
   export WORKSPACE_NAMESPACE=<your-workspace-namespace>
   ```

---

## Step-by-Step Commands

### Step 1: Create the custom PrometheusRule on the management cluster

Create your PrometheusRule in a namespace that is **federated to your workload clusters**. Use your workspace namespace (e.g. `my-workspace`, `prod-workspace`), not `kommander` — `kommander` is typically only on the host-cluster:

```bash
export TARGET_NAMESPACE=my-workspace   # or your workspace namespace from nkp get workspaces

cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cluster-health-alerts
  namespace: ${TARGET_NAMESPACE}
spec:
  groups:
    - name: cluster-health
      rules:
        - alert: ClusterHealthCheck
          expr: vector(1)
          for: 1m
          labels:
            severity: warning
          annotations:
            message: "Custom federated alert - cluster health check"
EOF
```
Replace `${TARGET_NAMESPACE}` with your actual workspace namespace if the variable is not set.

### Step 2: Enable PrometheusRule type for federation

Use the **fully qualified type name** (not `PrometheusRules`):

```bash
kubefedctl enable prometheusrules.monitoring.coreos.com --kubefed-namespace=kube-federation-system
```

**Verification:**
```bash
kubectl get federatedtypeconfigs -n kube-federation-system | grep prometheus
# Should show: prometheusrules.monitoring.coreos.com
```

### Step 3: Federate with workspace placement

Use the same namespace as Step 1 (`$TARGET_NAMESPACE` = your workspace namespace):

```bash
export WORKSPACE_NAMESPACE=my-workspace   # from nkp get workspaces (same as TARGET_NAMESPACE typically)
export TARGET_NAMESPACE=my-workspace      # namespace where you created the PrometheusRule

kubefedctl federate prometheusrules.monitoring.coreos.com cluster-health-alerts \
  --kubefed-namespace=kube-federation-system -n $TARGET_NAMESPACE -o yaml | \
  yq '.spec.placement = {"clusterSelector": {"matchLabels": {"kommander.d2iq.io/workspace-namespace-ref": "'"$WORKSPACE_NAMESPACE"'"}}}' - | \
  kubectl apply -f -
```

**Alternative (if kubefed is in `kommander` namespace on your NKP):**
```bash
kubefedctl federate prometheusrules.monitoring.coreos.com cluster-health-alerts \
  --kubefed-namespace=kommander -n $TARGET_NAMESPACE -o yaml | \
  yq '.spec.placement = {"clusterSelector": {"matchLabels": {"kommander.d2iq.io/workspace-namespace-ref": "'"$WORKSPACE_NAMESPACE"'"}}}' - | \
  kubectl apply -f -
```

### Step 4: Verify propagation

```bash
# Check FederatedPrometheusRule status
kubectl describe federatedprometheusrules cluster-health-alerts -n $TARGET_NAMESPACE

# Check propagation condition
kubectl get federatedprometheusrules cluster-health-alerts -n $TARGET_NAMESPACE -o yaml | grep -A5 status

# Verify on each workload cluster
kubectl --context=<workload-kubeconfig> -n $TARGET_NAMESPACE get prometheusrules.monitoring.coreos.com cluster-health-alerts
```

---

## Optional: Explicit placement by cluster name

If you prefer to target specific clusters by name instead of workspace:

```bash
# First, get exact KubeFedCluster names
kubectl get kubefedclusters -n kube-federation-system -o custom-columns=NAME:.metadata.name

# Federate with explicit placement
kubefedctl federate prometheusrules.monitoring.coreos.com cluster-health-alerts \
  --kubefed-namespace=kube-federation-system -n $TARGET_NAMESPACE -o yaml | \
  yq 'del(.spec.placement.clusterSelector) | .spec.placement.clusters = [{"name": "workload-cluster-1"}]' - | \
  kubectl apply -f -
```

**Note:** Use the exact `metadata.name` from `kubectl get kubefedclusters`, not the Kommander display name.

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| Rule on mgmt but not on workload clusters | **Most common:** Target namespace (e.g. `kommander`) not federated to workloads. Use workspace namespace (e.g. `my-workspace`) instead. |
| Propagation not working | `kubectl describe federatedprometheusrules <name> -n <ns>` |
| Status: `NamespaceNotFederated` | Federate the target namespace first, or use a namespace that is federated to workload clusters |
| Status: `CreationFailed` | PrometheusRule CRD missing on target cluster |
| Status: `CheckClusters` | Inspect per-cluster status in `status.clusters` |
| No clusters match placement | Verify KubeFedCluster labels match `clusterSelector` |
| Wrong `--kubefed-namespace` | KubeFed system namespace (often `kube-federation-system` or `kommander`) |

See [TROUBLESHOOTING_PROMETHEUSRULE_FEDERATION.md](TROUBLESHOOTING_PROMETHEUSRULE_FEDERATION.md) for more detail.

---

## yq Version Note

The `yq` commands above use [mikefarah/yq](https://github.com/mikefarah/yq) syntax. If you use a different yq (e.g. kislyuk/yq), the syntax may differ. Alternative with `jq`:

```bash
kubefedctl federate prometheusrules.monitoring.coreos.com cluster-health-alerts \
  --kubefed-namespace=kube-federation-system -n $TARGET_NAMESPACE -o json | \
  jq '.spec.placement = {"clusterSelector": {"matchLabels": {"kommander.d2iq.io/workspace-namespace-ref": "'"$WORKSPACE_NAMESPACE"'"}}}' | \
  kubectl apply -f -
```

---

## Run the E2E Demo

To validate locally with Kind clusters:

```bash
# 1. Create clusters and deploy KubeFed
./scripts/create-kind-clusters.sh
./scripts/deploy-kubefed.sh
./scripts/fix-kind-macos.sh   # macOS only

# 2. Download kubefedctl (optional; e2e uses bin/kubefedctl or KUBEFEDCTL_PATH)
./scripts/download-kubefedctl.sh v0.9.2

# 3. Run PrometheusRule federation e2e
./scripts/run-prometheusrule-e2e.sh
```
