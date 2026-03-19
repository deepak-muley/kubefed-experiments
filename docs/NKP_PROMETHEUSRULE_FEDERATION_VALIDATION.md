# Validation: KubeFed PrometheusRule Proposal for NKP

This document validates the proposal for federating custom PrometheusRules in NKP against the **Nutanix Kubernetes Platform v2.17** documentation (PDF) and KubeFed behavior.

---

## What the Nutanix NKP v2.17 Doc Says

From the "Federating Prometheus Alerting Rules" section (page 709):

1. **Enable** the PrometheusRule type:
   ```bash
   kubefedctl enable PrometheusRules --kubefed-namespace kommander
   ```

2. **Modify** the existing alertmanager rules:
   ```bash
   kubectl edit PrometheusRules/kube-prometheus-stack-alertmanager.rules -n kommander
   ```

3. **Append** a sample rule (e.g. `MyFederatedAlert`)

4. **Federate** the rules:
   ```bash
   kubefedctl federate PrometheusRules kube-prometheus-stack-alertmanager.rules --kubefed-namespace kommander -n kommander
   ```

5. **Verify** propagation:
   ```bash
   kubectl get federatedprometheusrules kube-prometheus-stack-alertmanager.rules -n kommander -oyaml
   ```

---

## Proposed Guidance

> **For KubeFed PrometheusRule question:**
>
> 1. Steps provided in [Nutanix doc](https://portal.nutanix.com/page/documents/details?targetId=Nutanix-Kubernetes-Platform-v2_17:top-federate-prometheus-alerting-rules-t.html) are accurate
> 2. For new types which are not watched by Kommander kubefed controller (e.g. PrometheusRule), user has to manually use `kubefedctl enable` / `kubefedctl federate`
> 3. For custom PrometheusRule: define the rule on management cluster, then federate to placement-defined clusters using workspace label via patching:
>
> ```bash
> kubefedctl federate prometheusrules.monitoring.coreos.com <your-PrometheusRule> -n <ns> -oyaml | \
>   yq '.spec.placement = {"clusterSelector": {"matchLabels": {"kommander.d2iq.io/workspace-namespace-ref": "'"$WORKSPACE_NAMESPACE"'"}}}' - | \
>   kubectl apply -f -
> ```

---

## Validation Summary

| Aspect | Nutanix Doc | Your Proposal | Verdict |
|--------|-------------|---------------|---------|
| Doc steps accuracy | Uses `PrometheusRules` short form | Agrees doc is accurate | ✅ Correct |
| Manual kubefedctl for PrometheusRule | Implicit (doc shows manual steps) | Explicit: types not watched by Kommander need manual enable/federate | ✅ Correct |
| Workspace-based placement | Doc does not show placement; default is all clusters | Use `clusterSelector` with `kommander.d2iq.io/workspace-namespace-ref` | ✅ Correct |
| kubefedctl syntax | `PrometheusRules` | `prometheusrules.monitoring.coreos.com` | ⚠️ See note below |

---

## Detailed Validation

### 1. Nutanix Doc Steps Are Accurate — ✅ Correct

The Nutanix doc correctly describes the flow: enable type → modify/create rule → federate → verify. Your statement that the doc steps are accurate is correct.

### 2. Manual kubefedctl for Types Not Watched by Kommander — ✅ Correct

From KubeFed/Kommander behavior in NKP:

- **KommanderClusterKubefed** handles cluster join/unjoin and KubeFedCluster lifecycle.
- It does **not** watch PrometheusRule or other arbitrary types.
- Enabling new federated types (FederatedTypeConfig) and creating Federated* resources is **manual** via `kubefedctl enable` and `kubefedctl federate`.

Your explanation is accurate.

### 3. Custom PrometheusRule + Workspace Placement — ✅ Correct

Your approach is sound:

- Define the custom PrometheusRule on the management cluster.
- Use `kubefedctl federate` to create a FederatedPrometheusRule.
- Patch placement with `clusterSelector.matchLabels: kommander.d2iq.io/workspace-namespace-ref: <workspace-namespace>` so only clusters in that workspace receive the rule.

This matches how KubeFed placement works in NKP.

### 4. kubefedctl Syntax: Short Form vs Fully Qualified — ⚠️ Nuance

**Nutanix doc:** `kubefedctl enable PrometheusRules` and `kubefedctl federate PrometheusRules`

**Your proposal:** `kubefedctl federate prometheusrules.monitoring.coreos.com`

**Standard kubefedctl** expects the fully qualified type: `prometheusrules.monitoring.coreos.com`. The short form `PrometheusRules` may work if kubefedctl (or NKP’s bundled version) supports it, but it is not the canonical form in upstream KubeFed.

**Recommendation:** Prefer the fully qualified form in written guidance:

```bash
kubefedctl enable prometheusrules.monitoring.coreos.com --kubefed-namespace kommander
kubefedctl federate prometheusrules.monitoring.coreos.com <your-PrometheusRule> -n <ns> ...
```

If the Nutanix doc’s short form works in their environment, both are acceptable; the fully qualified form is more robust across versions.

---

## Differences: Nutanix Doc vs Custom Rules

| | Nutanix Doc Example | Custom Rule (Your Proposal) |
|---|---------------------|-----------------------------|
| **Rule** | `kube-prometheus-stack-alertmanager.rules` (default, exists on all clusters) | Custom rule, e.g. `cluster-health-alerts` |
| **Placement** | Not shown (defaults to all clusters) | Explicit workspace via `clusterSelector` |
| **Namespace** | `kommander` | User’s namespace (e.g. `kommander` or workspace ns) |

The Nutanix doc focuses on modifying the **default** PrometheusRule that ships with kube-prometheus-stack. Your proposal correctly extends this to **custom** PrometheusRules and adds workspace-based placement.

---

## Prerequisites to Call Out

When recommending this approach, it helps to mention:

1. **PrometheusRule CRD** must exist on all target clusters (from Prometheus Operator / kube-prometheus-stack).
2. **Target namespace** (e.g. `kommander`) must be federated to the workload clusters, or the rule must live in a namespace that is federated.
3. **KubeFedCluster labels** for the workspace must be set (e.g. `kommander.d2iq.io/workspace-namespace-ref: <workspace-namespace>`); Kommander sets these when clusters are attached to a workspace.
4. **`$WORKSPACE_NAMESPACE`** should be the workspace’s namespace (from `nkp get workspaces` → NAMESPACE column), not the workspace display name.

---

## Final Verdict

**Your proposal is correct** and aligns with:

- Nutanix NKP documentation
- KubeFed behavior in NKP

**Suggested refinements:**

1. Prefer `prometheusrules.monitoring.coreos.com` in written guidance; note that Nutanix doc may use `PrometheusRules` if supported in their build.
2. Add a short prerequisites note (CRD, federated namespace, workspace labels).
3. Optionally include `--kubefed-namespace` in the federate command if it differs from the default:
   ```bash
   kubefedctl federate prometheusrules.monitoring.coreos.com <your-PrometheusRule> \
     --kubefed-namespace kommander -n <ns> -o yaml | ...
   ```

---

## Reference

- [Nutanix Portal: Federate Prometheus Alerting Rules](https://portal.nutanix.com/page/documents/details?targetId=Nutanix-Kubernetes-Platform-v2_17:top-federate-prometheus-alerting-rules-t.html)
- Nutanix NKP documentation — KubeFed architecture
