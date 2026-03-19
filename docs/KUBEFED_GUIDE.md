# KubeFed: Complete Guide from Basic to Advanced

A comprehensive guide to **KubeFed** (Kubernetes Cluster Federation) — what it is, how it differs across forks, and how to use it with `kubefedctl` and Kind clusters.

---

## Table of Contents

1. [Mesosphere vs Kubernetes-Retired KubeFed](#1-mesosphere-vs-kubernetes-retired-kubefed)
2. [What is KubeFed?](#2-what-is-kubefed)
3. [Architecture](#3-architecture)
4. [Prerequisites](#4-prerequisites)
5. [Quickstart with Kind](#5-quickstart-with-kind)
6. [Basic Concepts](#6-basic-concepts)
7. [kubefedctl CLI Reference](#7-kubefedctl-cli-reference)
8. [Intermediate: Placement & Overrides](#8-intermediate-placement--overrides)
9. [Advanced: Custom Types & NKP Integration](#9-advanced-custom-types--nkp-integration)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Mesosphere vs Kubernetes-Retired KubeFed

### Overview

| Aspect | [kubernetes-retired/kubefed](https://github.com/kubernetes-retired/kubefed) | [mesosphere/kubefed](https://github.com/mesosphere/kubefed) |
|--------|-----------------------------------------------------------------------------|-------------------------------------------------------------|
| **Status** | Archived (April 25, 2023) | Active maintenance |
| **Latest Release** | v0.9.2 (May 2022) | v0.11.1 (Jan 2025) |
| **Source** | Original upstream | Fork of kubernetes-retired |
| **Use Case** | Reference only | Production use (NKP, Kommander, etc.) |

### New Features & Changes in Mesosphere KubeFed

Mesosphere maintains an active fork with these additions beyond v0.9.2:

#### v0.10.0 (from kubernetes-sigs, before archive)
- **Ingress propagation**: Migrated from `extensions/v1beta1.Ingress` to `networking.k8s.io/v1.Ingress` (required for Kubernetes ≥1.22)
- Controller-manager panic fix when `insecure-skip-tls-verify` in kubeconfig
- Configurable webhook replica count
- Standard controller-runtime metrics
- Use specific ServiceAccount token secret for join
- Wait for SA token population before join
- KinD-based Helm chart sync
- `intersectWithClusterSelector` documentation

#### v0.11.0 (Mesosphere-specific)
- **Go 1.23.4** upgrade
- **Envtest** version upgrade for tests
- **Kind and Kubectl** version upgrades
- Release Please action for automated releases
- Dependabot configuration
- GitHub Actions updates (setup-go, checkout, docker/login-action)
- **k8s.io dependencies** bump (controller-runtime, kubectl, etc.)

#### v0.11.1 (Mesosphere-specific)
- Release Please action fix

### Why Use Mesosphere KubeFed?

- **Active development**: Bug fixes and compatibility with newer Kubernetes versions
- **NKP/Kommander**: Used in Nutanix Kubernetes Platform and D2iQ Kommander
- **Modern tooling**: Compatible with Kind, newer Go, and current k8s APIs

---

## 2. What is KubeFed?

**KubeFed** is a **control plane** that runs on a **host cluster** and propagates Kubernetes resources to **member clusters**. You define **federated resources** (e.g. `FederatedNamespace`, `FederatedConfigMap`, `FederatedSecret`) on the host; KubeFed's sync controllers push the underlying resources to member clusters according to **placement** (which clusters receive the resource).

### Core Concepts

- **Type configuration**: Declares which API types KubeFed should handle
- **Cluster configuration**: Declares which clusters KubeFed should target
- **Propagation**: The mechanism that distributes resources to federated clusters

### Three Fundamental Abstractions

| Concept | Purpose |
|---------|---------|
| **Templates** | Define the representation of a resource common across clusters |
| **Placement** | Defines which clusters the resource is intended to appear in |
| **Overrides** | Define per-cluster field-level variation to apply to the template |

### Features

| Feature | Maturity | Feature Gate | Default |
|---------|----------|--------------|---------|
| Push propagation of arbitrary types | Alpha | PushReconciler | true |
| CLI utility (kubefedctl) | Alpha | — | — |
| Generate KubeFed APIs without code | Alpha | — | — |
| Replica Scheduling Preferences | Alpha | SchedulerPreferences | true |

---

## 3. Architecture

### Hub-and-Spoke Model

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │                  HOST (MANAGEMENT) CLUSTER                   │
                    │  ┌───────────────────────────────────────────────────────┐  │
                    │  │           kube-federation-system namespace             │  │
                    │  │  • KubeFedCluster (cluster1, cluster2, …)              │  │
                    │  │  • FederatedTypeConfig (namespaces, configmaps, …)     │  │
                    │  │  • kubefed-controller-manager                          │  │
                    │  └───────────────────────────────────────────────────────┘  │
                    │  ┌───────────────────────────────────────────────────────┐  │
                    │  │  User namespaces (e.g. test-namespace)                   │  │
                    │  │  • FederatedNamespace, FederatedConfigMap,              │  │
                    │  │    FederatedSecret, FederatedDeployment, …              │  │
                    │  └───────────────────────────────────────────────────────┘  │
                    └─────────────────────────────────────────────────────────────┘
                                              │
                    ┌─────────────────────────┼─────────────────────────┐
                    │                         │                         │
                    ▼                         ▼                         ▼
            ┌───────────────┐         ┌───────────────┐         ┌───────────────┐
            │   cluster1    │         │   cluster2    │         │   cluster3    │
            │               │         │               │         │               │
            │ Propagated    │         │ Propagated    │         │ Propagated    │
            │ resources     │         │ resources     │         │ resources     │
            └───────────────┘         └───────────────┘         └───────────────┘
```

### Key CRs

| Resource | API | Purpose |
|----------|-----|---------|
| **KubeFedCluster** | `core.kubefed.io/v1beta1` | One per member cluster. Stored in `kube-federation-system`. |
| **FederatedTypeConfig** | `core.kubefed.io/v1beta1` | Enables federation for a type (e.g. `namespaces`, `configmaps`). |
| **FederatedNamespace** | `types.kubefed.io/v1beta1` | Propagates a Namespace to selected clusters. |
| **FederatedConfigMap** / **FederatedSecret** | `types.kubefed.io/v1beta1` | Propagates ConfigMap/Secret to selected clusters. |
| **PropagatedVersion** | `core.kubefed.io/v1alpha1` | Tracks propagation version per cluster (internal). |

---

## 4. Prerequisites

- **kubectl** installed
- **kind** (Kubernetes in Docker)
- **helm** installed
- **Docker** (for Kind)
- **Go 1.23+** (if building from source)
- **kubefedctl** — options:
  - **Download** from [kubernetes-retired/kubefed v0.9.2](https://github.com/kubernetes-retired/kubefed/releases/tag/v0.9.2): `./scripts/download-kubefedctl.sh v0.9.2` (installs to `bin/kubefedctl`)
  - Build from mesosphere/kubefed: `make kubefedctl`

---

## 5. Quickstart with Kind

### Option A: Single Cluster (Self-Join)

```bash
# 1. Create a Kind cluster
kind create cluster

# 2. Clone and deploy KubeFed (from mesosphere/kubefed repo)
git clone https://github.com/mesosphere/kubefed.git
cd kubefed
make deploy.kind   # Uses ghcr.io/mesosphere/kubefed image

# 3. On macOS: Fix API endpoints for Kind
./scripts/fix-joined-kind-clusters.sh

# 4. Verify
kubectl -n kube-federation-system get kubefedcluster
```

### Option B: Multi-Cluster (cluster1 + cluster2)

```bash
# 1. Create two Kind clusters
./scripts/create-clusters.sh   # Creates cluster1 and cluster2

# 2. Deploy KubeFed to cluster1 and join both clusters
CONTEXT=cluster1
KIND_LOAD_IMAGE=y FORCE_REDEPLOY=y ./scripts/deploy-kubefed.sh ghcr.io/mesosphere/kubefed:latest cluster2

# 3. On macOS: Fix API endpoints
./scripts/fix-joined-kind-clusters.sh

# 4. Verify
kubectl --context=cluster1 -n kube-federation-system get kubefedcluster
```

### Option C: Use This Repo's Scripts

```bash
# From kubefed-experiments root
./scripts/create-kind-clusters.sh
./scripts/deploy-kubefed.sh
./scripts/fix-kind-macos.sh   # macOS only
```

---

## 6. Basic Concepts

### Federating a Namespace

```bash
# Create a namespace
kubectl create ns federate-me

# Federate it (creates FederatedNamespace)
kubefedctl federate ns federate-me

# Federate namespace with all its contents
kubefedctl federate ns federate-me --contents
```

### Federating a ConfigMap

```bash
# Create a ConfigMap
kubectl -n federate-me create cm my-cm --from-literal=key=value

# Federate it
kubefedctl -n federate-me federate configmap my-cm

# Or with --enable-type to enable the type if not already
kubefedctl -n federate-me federate configmap my-cm --enable-type
```

### Enabling a New Type for Federation

```bash
# Enable a built-in type
kubefedctl enable configmaps
kubefedctl enable secrets
kubefedctl enable deployments.apps
kubefedctl enable services

# Enable a CRD
kubefedctl enable customresourcedefinitions
kubefedctl federate crd prometheusrules.monitoring.coreos.com
```

### Disabling a Type

```bash
# Temporarily disable propagation
kubectl patch federatedtypeconfigs configmaps -n kube-federation-system \
  --type=merge -p '{"spec":{"propagation":"Disabled"}}'

# Permanently disable
kubefedctl disable configmaps
```

---

## 7. kubefedctl CLI Reference

### Commands

| Command | Purpose |
|---------|---------|
| `kubefedctl join <cluster-name>` | Join a cluster to the federation |
| `kubefedctl unjoin <cluster-name>` | Remove a cluster from the federation |
| `kubefedctl enable <type>` | Enable federation for an API type |
| `kubefedctl disable <name>` | Disable federation for a type |
| `kubefedctl federate <type> <name>` | Create a federated resource from a kubernetes resource |
| `kubefedctl orphaning-deletion enable/disable/status` | Control whether managed resources are deleted when federated resource is removed |

### Common Flags

| Flag | Description |
|------|-------------|
| `--host-cluster-context` | Context of the host cluster |
| `--cluster-context` | Context of the cluster to join |
| `--kubefed-namespace` | KubeFed system namespace (default: `kube-federation-system`) |
| `--namespace` / `-n` | Namespace for the resource |
| `--enable-type` / `-t` | Enable federation of the type if not already enabled |
| `--output` / `-o yaml` | Output YAML instead of applying |

### Join/Unjoin Examples

```bash
# Join cluster2 to host cluster1
kubefedctl join cluster2 --cluster-context cluster2 \
  --host-cluster-context cluster1 --v=2

# Unjoin cluster2
kubefedctl unjoin cluster2 --cluster-context cluster2 \
  --host-cluster-context cluster1 --v=2

# Custom namespace
kubefedctl join mycluster --cluster-context mycluster \
  --host-cluster-context mycluster --v=2 \
  --kubefed-namespace=test-namespace
```

### Federate Examples

```bash
# Federate ConfigMap
kubefedctl federate configmaps my-configmap -n my-namespace

# Federate namespace with contents, skip specific types
kubefedctl federate namespace my-namespace --contents \
  --skip-api-resources "configmaps,apps"

# Federate from file
kubefedctl federate --filename ./my-resources.yaml

# Output to YAML only
kubefedctl federate configmaps my-cm -n my-ns -o yaml
```

---

## 8. Intermediate: Placement & Overrides

### Placement

**Placement** determines which clusters receive a federated resource.

#### Option 1: Explicit cluster list

```yaml
spec:
  placement:
    clusters:
      - name: cluster1
      - name: cluster2
```

#### Option 2: Cluster selector (all clusters)

```yaml
spec:
  placement:
    clusterSelector: {}   # Empty = all clusters
```

#### Option 3: Cluster selector (labeled clusters)

```bash
# Label clusters
kubectl label kubefedclusters -n kube-federation-system cluster1 env=prod
kubectl label kubefedclusters -n kube-federation-system cluster2 env=prod

# Federated resource
spec:
  placement:
    clusterSelector:
      matchLabels:
        env: prod
```

#### Option 4: No clusters (no propagation)

```yaml
spec:
  placement: {}
```

### Overrides

**Overrides** allow per-cluster variation of the template.

```yaml
apiVersion: types.kubefed.io/v1beta1
kind: FederatedDeployment
metadata:
  name: my-app
  namespace: my-ns
spec:
  template:
    spec:
      replicas: 2
      template:
        spec:
          containers:
            - name: app
              image: myapp:latest
  placement:
    clusterSelector: {}
  overrides:
    - clusterName: cluster1
      clusterOverrides:
        - path: "/spec/replicas"
          value: 5
        - path: "/spec/template/spec/containers/0/image"
          value: "myapp:canary"
```

### Propagation Status

Check status on federated resources:

```bash
kubectl describe federatedconfigmap my-cm -n my-ns
```

Common status values:

| Status | Description |
|--------|-------------|
| CheckClusters | One or more clusters not in desired state |
| ClusterRetrievalFailed | Error retrieving member clusters |
| NamespaceNotFederated | Containing namespace is not federated |

---

## 9. Advanced: Custom Types & NKP Integration

### Federating a Custom Resource (e.g. PrometheusRule)

```bash
# 1. Ensure CRD exists on all member clusters
kubectl get crd prometheusrules.monitoring.coreos.com

# 2. Enable federation for the type
kubefedctl enable prometheusrules.monitoring.coreos.com

# 3. Federate an existing PrometheusRule
kubefedctl federate prometheusrules.monitoring.coreos.com my-alerts -n monitoring
```

### KubeFed in NKP (Nutanix Kubernetes Platform)

In NKP/Kommander:

- **Host cluster** = NKP management cluster
- **Member clusters** = Workload clusters + host (as `host-cluster`)
- **Workspace placement** → `kommander.d2iq.io/workspace-namespace-ref` label
- **KommanderClusterKubefed** controller performs join/unjoin on attach/detach

See [Nutanix NKP documentation](https://portal.nutanix.com/page/documents/list) for platform-specific details.

### Orphaning Deletion

```bash
# Leave managed resources when federated resource is deleted
kubefedctl orphaning-deletion enable federatedconfigmap my-cm -n my-ns

# Check status
kubefedctl orphaning-deletion status federatedconfigmap my-cm -n my-ns

# Revert to default (delete when federated resource is removed)
kubefedctl orphaning-deletion disable federatedconfigmap my-cm -n my-ns
```

---

## 10. Troubleshooting

### KubeFedCluster not Ready

```bash
# On macOS with Kind: Fix API endpoints
./scripts/fix-joined-kind-clusters.sh

# Check cluster status
kubectl get kubefedclusters -n kube-federation-system -o wide
```

### Propagation Not Working

```bash
# Check events on federated resource
kubectl describe federatedconfigmap <name> -n <namespace>

# Check controller logs
kubectl logs deployment/kubefed-controller-manager -n kube-federation-system
```

### Type Not Enabled

```bash
# List enabled types
kubectl get federatedtypeconfigs -n kube-federation-system

# Enable if missing
kubefedctl enable <type>
```

### Namespace Not Federated

If the containing namespace is not federated, propagation fails with `NamespaceNotFederated`:

```bash
kubefedctl federate ns <namespace-name>
```

---

## References

- [mesosphere/kubefed](https://github.com/mesosphere/kubefed) — Active fork
- [kubernetes-retired/kubefed](https://github.com/kubernetes-retired/kubefed) — Archived upstream
- [KubeFed User Guide](https://github.com/mesosphere/kubefed/blob/master/docs/userguide.md)
- [Cluster Registration](https://github.com/mesosphere/kubefed/blob/master/docs/cluster-registration.md)
- [Karmada](https://karmada.io/) — Successor project (KubeFed migration path)
