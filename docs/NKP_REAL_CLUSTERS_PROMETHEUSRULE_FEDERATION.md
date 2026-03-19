# PrometheusRule Federation on NKP Clusters

This guide uses **NKP management and workload clusters** with kubeconfigs. Set `MGMT_KUBECONFIG`, `WL1_KUBECONFIG`, `WL2_KUBECONFIG` (or `NKP_WS` to a directory containing the configs). The clusters must have KubeFedClusters registered.

---

## Kubeconfig Layout

| Variable | Purpose |
|----------|---------|
| `MGMT_KUBECONFIG` | Management cluster (host) kubeconfig |
| `WL1_KUBECONFIG` | Workload cluster 1 kubeconfig |
| `WL2_KUBECONFIG` | Workload cluster 2 kubeconfig |

Or set `NKP_WS` to a directory containing: `mgmt-cluster.conf`, `workload-1.kubeconfig`, `workload-2.kubeconfig`.

**KubeFedCluster names** (used for placement): Use `kubectl get kubefedclusters -n kube-federation-system` to see your cluster names.

---

## KubeFed namespace layout (mgmt vs workload)

| Namespace | Management cluster | Workload cluster |
|-----------|--------------------|------------------|
| `kube-federation-system` | Yes (KubeFed controller, KubeFedClusters, FederatedTypeConfigs) | Yes (federation components) |
| `kommander` | Yes | No |
| `kommander-default-workspace` | Yes | No |
| `kommander-flux` | Yes | Yes |

**Notes:**
- **kube-federation-system** exists on both. On mgmt it hosts the KubeFed controller, KubeFedClusters, FederatedTypeConfigs, and Federated* resources. Use `--kubefed-namespace=kube-federation-system` for kubefedctl.
- **kommander** exists only on mgmt. Do not use it as the target namespace when federating to workload clusters.
- **Workspace namespaces** (e.g. `my-workspace`, `my-workspace`) exist on mgmt and on clusters attached to that workspace.

---

## Prerequisites (Verify First)

### 1. PrometheusRule CRD on all clusters

```bash
export MGMT_KUBECONFIG=/path/to/mgmt-cluster.conf
export WL1_KUBECONFIG=/path/to/workload-1.kubeconfig
export WL2_KUBECONFIG=/path/to/workload-2.kubeconfig

# Check (should already exist if kube-prometheus-stack is installed)
KUBECONFIG=$MGMT_KUBECONFIG kubectl get crd prometheusrules.monitoring.coreos.com
KUBECONFIG=$WL1_KUBECONFIG kubectl get crd prometheusrules.monitoring.coreos.com
KUBECONFIG=$WL2_KUBECONFIG kubectl get crd prometheusrules.monitoring.coreos.com
```

If missing, apply:
```bash
CRD_URL="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml"
KUBECONFIG=$MGMT_KUBECONFIG kubectl apply -f "$CRD_URL"
KUBECONFIG=$WL1_KUBECONFIG kubectl apply -f "$CRD_URL"
KUBECONFIG=$WL2_KUBECONFIG kubectl apply -f "$CRD_URL"
```

### 2. Target namespace federated to workload clusters

The target namespace must **exist on each workload cluster** that receives the PrometheusRule. Two ways to verify:

**Method 1: Direct check** — Does the namespace exist on each cluster?
```bash
KUBECONFIG=$WL1_KUBECONFIG kubectl get ns <namespace>
KUBECONFIG=$WL2_KUBECONFIG kubectl get ns <namespace>
```
If the namespace exists = it is federated there (or created manually).

**Method 2: FederatedNamespace placement** — Which clusters does the FederatedNamespace target?
```bash
KUBECONFIG=$MGMT_KUBECONFIG kubectl get federatednamespace <namespace> -n <namespace> -o yaml
```
Inspect `spec.placement` (clusterSelector or clusters). The namespace is propagated only to clusters matching that placement.

**Example:** In NKP, `kommander` often exists on mgmt but not on workload clusters (placement targets host-cluster). Workspace namespaces (e.g. `my-workspace`) exist on workload clusters when placement matches `kommander.d2iq.io/workspace-namespace-ref`.

### 3. KubeFedCluster labels (workspace placement)

Workload clusters must have `kommander.d2iq.io/workspace-namespace-ref` label for workspace-based placement:

```bash
KUBECONFIG=$MGMT_KUBECONFIG kubectl get kubefedclusters -n kube-federation-system \
  -o custom-columns=NAME:.metadata.name,WORKSPACE:.metadata.labels.kommander\.d2iq\.io/workspace-namespace-ref
```

Use the workspace namespace from your setup (from `nkp get workspaces` → NAMESPACE column).

### 4. kubefedctl

```bash
./scripts/download-kubefedctl.sh v0.9.2   # or set KUBEFEDCTL_PATH
```

---

## Step-by-Step Commands

### Environment

```bash
export MGMT_KUBECONFIG=/path/to/mgmt-cluster.conf
export WL1_KUBECONFIG=/path/to/workload-1.kubeconfig
export WL2_KUBECONFIG=/path/to/workload-2.kubeconfig

# Workspace namespace (from nkp get workspaces or kubectl get kubefedclusters labels)
export WORKSPACE_NAMESPACE=my-workspace

# Target namespace for the PrometheusRule (must be federated to workload clusters)
export TARGET_NAMESPACE=my-workspace

# KubeFed system namespace
export KUBEFED_NS=kube-federation-system
```

### Step 1: Enable PrometheusRule type for federation

**Important:** `kubefedctl` uses `KUBECONFIG` from the environment. Set it so kubefedctl targets the management cluster:

```bash
export KUBECONFIG=$MGMT_KUBECONFIG
kubefedctl enable prometheusrules.monitoring.coreos.com \
  --kubefed-namespace=$KUBEFED_NS
```

**Verification:**
```bash
KUBECONFIG=$MGMT_KUBECONFIG kubectl get federatedtypeconfigs -n $KUBEFED_NS | grep prometheus
```

### Step 2: Create the PrometheusRule on management cluster

Use the YAML that matches your target namespace:

```bash
# For workspace namespace (federated to workload clusters) - recommended
sed "s/namespace: my-workspace/namespace: $TARGET_NAMESPACE/" nkp-prometheusrule-demo/cluster-health-alerts-workspace.yaml | \
  kubectl --kubeconfig=$MGMT_KUBECONFIG apply -f -

# For kommander (only if federated to workload clusters)
kubectl --kubeconfig=$MGMT_KUBECONFIG apply -f nkp-prometheusrule-demo/cluster-health-alerts-kommander.yaml
```

### Step 3: Federate with workspace placement

**Important:** `kubefedctl federate` must use the management kubeconfig to find the PrometheusRule. Set `KUBECONFIG` (or use `KUBECONFIG=...` prefix):

```bash
KUBECONFIG=$MGMT_KUBECONFIG kubefedctl federate prometheusrules.monitoring.coreos.com cluster-health-alerts \
  --kubefed-namespace=$KUBEFED_NS -n $TARGET_NAMESPACE -o yaml | \
  yq '.spec.placement = {"clusterSelector": {"matchLabels": {"kommander.d2iq.io/workspace-namespace-ref": "'"$WORKSPACE_NAMESPACE"'"}}}' - | \
  kubectl --kubeconfig=$MGMT_KUBECONFIG apply -f -
```

**Alternative with jq** (if yq is mikefarah/yq):
```bash
KUBECONFIG=$MGMT_KUBECONFIG kubefedctl federate prometheusrules.monitoring.coreos.com cluster-health-alerts \
  --kubefed-namespace=$KUBEFED_NS -n $TARGET_NAMESPACE -o json | \
  jq '.spec.placement = {"clusterSelector": {"matchLabels": {"kommander.d2iq.io/workspace-namespace-ref": "'"$WORKSPACE_NAMESPACE"'"}}}' | \
  kubectl --kubeconfig=$MGMT_KUBECONFIG apply -f -
```

### Step 4: Verify propagation

```bash
# FederatedPrometheusRule status
KUBECONFIG=$MGMT_KUBECONFIG kubectl describe federatedprometheusrules cluster-health-alerts -n $TARGET_NAMESPACE

# PrometheusRule on each cluster
KUBECONFIG=$MGMT_KUBECONFIG kubectl -n $TARGET_NAMESPACE get prometheusrules.monitoring.coreos.com cluster-health-alerts
KUBECONFIG=$WL1_KUBECONFIG kubectl -n $TARGET_NAMESPACE get prometheusrules.monitoring.coreos.com cluster-health-alerts
KUBECONFIG=$WL2_KUBECONFIG kubectl -n $TARGET_NAMESPACE get prometheusrules.monitoring.coreos.com cluster-health-alerts
```

---

## Optional: Explicit placement by cluster name

If workspace placement does not match, target specific clusters by name:

```bash
# Replace with your actual KubeFedCluster names from kubectl get kubefedclusters
kubefedctl federate prometheusrules.monitoring.coreos.com cluster-health-alerts \
  --kubefed-namespace=$KUBEFED_NS -n $TARGET_NAMESPACE -o yaml | \
  yq 'del(.spec.placement.clusterSelector) | .spec.placement.clusters = [{"name": "workload-1"}, {"name": "workload-2"}]' - | \
  kubectl --kubeconfig=$MGMT_KUBECONFIG apply -f -
```

---

## Run the NKP Script

For a one-shot run, set kubeconfig env vars and workspace namespace:

```bash
./scripts/run-prometheusrule-nkp.sh
```

To diagnose why the PrometheusRule is not on workload clusters:

```bash
./scripts/diagnose-prometheusrule-nkp.sh
```

For verification only (after federation is done):

```bash
./scripts/verify-prometheusrule-nkp.sh
```

---

## Cleanup

```bash
# Clean up from kommander namespace (if you ran with TARGET_NAMESPACE=kommander)
KUBECONFIG=$MGMT_KUBECONFIG kubectl delete federatedprometheusrules cluster-health-alerts -n kommander --ignore-not-found
KUBECONFIG=$MGMT_KUBECONFIG kubectl delete prometheusrules.monitoring.coreos.com cluster-health-alerts -n kommander --ignore-not-found

# Clean up from workspace namespace
KUBECONFIG=$MGMT_KUBECONFIG kubectl delete federatedprometheusrules cluster-health-alerts -n $TARGET_NAMESPACE --ignore-not-found
KUBECONFIG=$MGMT_KUBECONFIG kubectl delete prometheusrules.monitoring.coreos.com cluster-health-alerts -n $TARGET_NAMESPACE --ignore-not-found
```

---

## Troubleshooting

### PrometheusRule not on workload clusters

**Root cause:** The target namespace (e.g. `kommander`) may not be federated to workload clusters. In NKP, `kommander` is often federated only to the host-cluster; workspace namespaces are federated to workload clusters.

**Fix:** Use a namespace federated to workload clusters:
```bash
export TARGET_NAMESPACE=my-workspace  # your workspace namespace
./scripts/run-prometheusrule-nkp.sh
```

**Diagnose:** Run the diagnostic script:
```bash
./scripts/diagnose-prometheusrule-nkp.sh
```

| Issue | Check |
|-------|-------|
| Propagation not working | `kubectl describe federatedprometheusrules <name> -n <ns>` |
| Status: `NamespaceNotFederated` | Federate the target namespace first, or use a workspace namespace |
| Status: `CreationFailed` | PrometheusRule CRD missing on target cluster |
| Status: `CheckClusters` | Inspect per-cluster status in `status.clusters` |
| No clusters match placement | Verify KubeFedCluster labels match `clusterSelector` |
| Wrong kubeconfig | Set `MGMT_KUBECONFIG` to your management cluster kubeconfig |

See [TROUBLESHOOTING_PROMETHEUSRULE_FEDERATION.md](TROUBLESHOOTING_PROMETHEUSRULE_FEDERATION.md) for more detail.
