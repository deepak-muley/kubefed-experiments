# KubeFed Experiments

Experiments and learning resources for **KubeFed** (Kubernetes Cluster Federation) using [mesosphere/kubefed](https://github.com/mesosphere/kubefed).

## Contents

| Path | Description |
|------|-------------|
| [docs/KUBEFED_GUIDE.md](docs/KUBEFED_GUIDE.md) | Comprehensive guide: Mesosphere vs kubernetes-retired, concepts, kubefedctl, placement, overrides |
| [sample-app/](sample-app/) | Demo app: FederatedNamespace, ConfigMap, Deployment, Service |
| [scripts/](scripts/) | Kind cluster setup, KubeFed deploy, macOS fix, E2E test, PrometheusRule e2e, download-kubefedctl |
| [docs/CUSTOMER_STEPS_PROMETHEUSRULE_FEDERATION.md](docs/CUSTOMER_STEPS_PROMETHEUSRULE_FEDERATION.md) | Steps to federate custom PrometheusRule in NKP |
| [docs/NKP_REAL_CLUSTERS_PROMETHEUSRULE_FEDERATION.md](docs/NKP_REAL_CLUSTERS_PROMETHEUSRULE_FEDERATION.md) | PrometheusRule federation on NKP clusters (set MGMT_KUBECONFIG, WL1_KUBECONFIG, WL2_KUBECONFIG) |
| [docs/SUPPORT_VERIFICATION_CHECKLIST_PROMETHEUSRULE.md](docs/SUPPORT_VERIFICATION_CHECKLIST_PROMETHEUSRULE.md) | Verification checklist when PrometheusRule federation is not working |

## Quick Start

### Prerequisites

- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/)
- [Docker](https://www.docker.com/)

### 1. Create Kind Clusters

```bash
./scripts/create-kind-clusters.sh
```

Creates `cluster1` (host) and `cluster2` (member). Set `NUM_CLUSTERS=1` for a single self-joined cluster.

### 2. Clone KubeFed and Deploy

```bash
# Clone mesosphere/kubefed (if not already)
git clone https://github.com/mesosphere/kubefed.git ../kubefed

# Deploy KubeFed to cluster1, join cluster2
./scripts/deploy-kubefed.sh
```

### 3. Fix Kind on macOS (if needed)

```bash
./scripts/fix-kind-macos.sh
```

### 4. Run E2E Test

```bash
./scripts/run-e2e-test.sh
```

Deploys the sample app, verifies propagation to all clusters, and tests placement changes.

### 5. kubefedctl (optional)

For PrometheusRule federation e2e or manual `kubefedctl` commands, download from [kubernetes-retired/kubefed v0.9.2](https://github.com/kubernetes-retired/kubefed/releases/tag/v0.9.2):

```bash
./scripts/download-kubefedctl.sh v0.9.2
# Binary is installed to bin/kubefedctl; scripts auto-detect it
```

### 6. Manual Demo with kubefedctl

```bash
# Use host cluster
kubectl config use-context cluster1

# Verify clusters
kubectl get kubefedclusters -n kube-federation-system

# Deploy sample app
kubectl apply -f sample-app/namespace.yaml -f sample-app/federatednamespace.yaml
kubectl apply -f sample-app/federatedconfigmap.yaml -f sample-app/federateddeployment.yaml -f sample-app/federatedservice.yaml

# Check propagation
kubectl describe federatednamespace demo-app -n demo-app

# Verify in each cluster
kubectl --context=cluster1 -n demo-app get all
kubectl --context=cluster2 -n demo-app get all
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|--------------|
| `KUBEFED_REPO` | `../kubefed` | Path to kubefed clone |
| `KUBEFED_IMAGE` | `ghcr.io/mesosphere/kubefed:v0.11.1` | KubeFed container image |
| `HOST_CONTEXT` | `cluster1` | Host cluster context |
| `JOIN_CLUSTERS` | `cluster2` | Clusters to join (space-separated) |
| `NUM_CLUSTERS` | `2` | Number of Kind clusters to create |

## Cleanup

```bash
# Delete sample app
kubectl --context=cluster1 delete ns demo-app

# Delete Kind clusters
kind delete cluster --name cluster1
kind delete cluster --name cluster2
```

## References

- [mesosphere/kubefed](https://github.com/mesosphere/kubefed) — Active fork
- [KubeFed User Guide](https://github.com/mesosphere/kubefed/blob/master/docs/userguide.md)
- [Nutanix NKP](https://portal.nutanix.com/page/documents/list) — Nutanix Kubernetes Platform (KubeFed integration)
