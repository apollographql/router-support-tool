# User Experience

## The full lifecycle at a glance

```
Customer wants to collect data
    - They have hit an issue and want data
    - they want to collect a "healthy" snapshot
        │
        ▼
V1: User (or platform team) triggers collection via the chart
V2: watcher already triggered a bundle at threshold crossing
        │
        ▼
.tar.gz bundle produced, redacted automatically
        │
        ▼
Customer inspects bundle contents (optional)
        │
        ▼
Customer shares bundle with support
        │
        ▼
Support has: router version, sanitized config, metrics
             (if enabled), logs, pod state, Redis health
        │
        ▼
(Future) - Temporary dashboard created for support with the metrics collected
         - Bundle fed into RTF to spin up REP cluster for issue reproduction
```

---

## On-demand (flare-style) collection

**Note: this tool currently supports Kubernetes deployments only.** Non-k8s deployments, including ECS, Fargate, or standalone EC2/VM deployments, aren't covered by this flow. If you're running on ECS or another non-k8s environment, the closest equivalent today is a manual collection: your sanitized `router.yaml`, router version, recent logs (via CloudWatch Logs export), and container-level CPU/memory metrics (via CloudWatch Container Insights) cover much of the same ground the automated bundle would.

### Which path applies to you

The tool supports three deployment tiers in v1:

| Deployment | Support in v1 | What you supply |
| --- | --- | --- |
| **Apollo Operator** | Full support, zero config | Nothing |
| **Official Apollo router Helm chart** | Full support | `namespace` only |
| **Raw manifests / custom deployment** | Supported | `namespace`, `selector`, `configMapName` |

If you deployed the router with a hand-authored manifest or a custom chart that doesn't follow the official chart's conventions, this tool still works — you'll just need to supply more. None of the official chart's conventions (standard labels, known ConfigMap naming) apply, so the tool can't locate your router's config or pod on its own. Supply your namespace, pod selector, and ConfigMap name, and the same chart and collection engine used for every other tier handles the rest.

### Setup: one chart, two modes

Getting a spec into the cluster is done through a single Helm chart, `router-diagnostics-spec`, with a `mode` value controlling how collection actually runs:

- **`mode: local`** — renders the spec into a cluster ConfigMap. You run the collection yourself from a machine with kubectl access.
- **`mode: job`** — renders the same spec plus a Kubernetes Job (and its ServiceAccount/RBAC) that runs the collection in-cluster. Use this if your own kubectl access to production is restricted — a platform team installs the chart and runs the Job on your behalf.

Both modes use the same spec and collection engine; only who runs it and where differs.

**If you're on the Apollo Operator**, you don't need this chart at all — the Operator already installs a fully-populated spec for you. Skip to [Apollo Operator customers](#apollo-operator-customers) below.

**If you're on the official Apollo Helm chart:**

```bash
helm install router-diagnostics apollo/router-diagnostics \
  --namespace production \
  --set namespace=production \
  --set mode=local
```

Then invoke the collection:

```bash
kubectl support-bundle --load-cluster-specs
```

`namespace` is the only value you need to supply. The chart's collectors target your router by its standard `app.kubernetes.io/name=router` label — no release name, selector, or ConfigMap name is needed **for the official chart.**

**If you're on a raw-manifest or custom deployment:**

```bash
helm install router-diagnostics apollo/router-diagnostics \
  --namespace production \
  --set namespace=production \
  --set selector="app=my-router" \
  --set configMapName=my-config \
  --set mode=local
```

Then invoke the collection the same way:

```bash
kubectl support-bundle --load-cluster-specs
```

Since none of the official chart's conventions apply to your deployment, supply your pod selector and ConfigMap name in addition to the namespace, so the chart's collectors know where to find your router and its configuration.

### Apollo Operator customers

Zero configuration. The Operator installs a fully-populated spec into a cluster ConfigMap directly, using the deployment conventions it already knows. Run:

```bash
kubectl support-bundle --load-cluster-specs
```

Nothing else is required. Note: today this requires opting in via the Operator — check with your Operator configuration whether spec provisioning is enabled.

### Restricted-access clusters (`mode: job`)

If you don't have kubectl access to production, use the same chart with `mode: job`. A platform team member with cluster access installs it:

```bash
helm install router-diagnostics apollo/router-diagnostics \
  --namespace production \
  --set namespace=production \
  --set mode=job
```

If you're on a raw-manifest or custom deployment, also set `selector` and `configMapName` as shown above.

The Job runs the collection automatically using a namespace-scoped ServiceAccount, and the platform team retrieves the completed bundle. *(Bundle retrieval mechanism — mounted volume vs. object storage — is still being finalized.)* No one outside the platform team needs raw kubectl access. This is the same spec and collection engine as `mode: local`; only who runs it and how the bundle is retrieved differs.

The ServiceAccount needs the same namespace-scoped read permissions as the local path, applied by whoever has permission to create Jobs and RBAC objects in the namespace.

#### Support tool output

A `support-bundle-<timestamp>.tar.gz` file appears in your current directory: a point-in-time snapshot of the router and cluster state. It includes router version, sanitized configuration, recent logs, metrics (if you've enabled the Prometheus endpoint), pod status, and Redis health if Redis is configured. Sensitive data is redacted automatically before the file is created — see [Redaction preferences](#redaction-preferences) below. You can inspect the bundle contents before sharing. Nothing persists in the cluster after collection completes, though the chart itself remains installed unless you remove it — see [Cluster footprint](#cluster-footprint) below.

#### Metrics require the Prometheus endpoint to be enabled

The metrics collector targets the official chart's known metrics port (`9090`). If you haven't enabled the Prometheus exporter in your `router.yaml` (`telemetry.exporters.metrics.prometheus.enabled: true`), that section of the bundle will simply be empty — the rest of the bundle is unaffected. This currently applies to the official chart tier only; other tiers will not have metrics populated in v1.

#### Redaction preferences

By default, schema/SDL is included in the bundle since it's usually needed for diagnosis. If your schema is sensitive enough that even its presence shouldn't be shared, opt out:

```bash
helm install router-diagnostics apollo/router-diagnostics \
  --namespace production \
  --set namespace=production \
  --set mode=local \
  --set redaction.includeSchema=false
```

Everything else — JWT/auth config, header values, operation bodies in logs, subgraph URLs — is redacted automatically with no configuration available or needed. `APOLLO_KEY` is never collected under any circumstances.

#### Cluster footprint

Installing the chart creates a persistent object in your cluster — the spec ConfigMap, plus Helm release metadata. This is minimal but not zero. If you'd rather leave nothing behind, remove the chart after collecting:

```bash
helm uninstall router-diagnostics --namespace production
```

If you expect to run diagnostics more than once, you may prefer to leave it installed — subsequent collections then only need `kubectl support-bundle --load-cluster-specs`, with no reinstall.

#### Permissions

The chart install itself requires permission to create ConfigMaps, ServiceAccounts, and RBAC objects in the target namespace, plus (for `mode: job`) permission to create Jobs — the same level of access needed to install the router itself. `kubectl support-bundle --load-cluster-specs` (for `mode: local`) runs using your existing kubectl credentials; no additional ServiceAccount is created for that step. You need read access to pods, logs, ConfigMaps, and cluster resources in the router's namespace — standard permissions for anyone managing a k8s workload.

### Sharing with support

Attach the `.tar.gz` to your support ticket.

---

## Scheduled and threshold-triggered collection (v2)

### Setup

Install the Helm chart. This must be installed in the same Kubernetes cluster and namespace as your router:

```bash
helm install apollo-router-diagnostics apollo/router-diagnostics \
  --namespace production \
  -f values.yaml
```

The chart deploys a CronJob (for scheduled collection) and a watcher Deployment (for threshold-triggered collection). Both are disabled by default — enable them by setting `scheduled.base.enabled: true` and `thresholds.enabled: true` in your `values.yaml`.

> **Open question:** this v2 chart has not yet gone through the same parameter-passing and deployment-tier analysis as the v1 chart above. Whether it can rely on the same official-chart label-based targeting, is still to be determined.

### Permissions

Installing the chart requires permission to create Deployments, CronJobs, ServiceAccounts, and RBAC objects in the target namespace — the same level of access needed to install the router itself.

The chart's ServiceAccount needs:

- **Namespace-scoped** (Role + RoleBinding in the router's namespace): read pods, deployments, logs, and ConfigMaps; `pods/exec` for the graph ref read
- **Cluster-scoped** (ClusterRole + ClusterRoleBinding): read-only access to `nodes`, since node objects are not namespaced and are required for node/container resource metrics

The only cluster-scoped permission is read-only access to node information. Everything else is confined to the router's namespace. Both are documented explicitly so customers with strict security review can approve exactly what's granted.

### Automatic collection

Once configured, collection runs without any user involvement:

- **Every 15 minutes (configurable)** — the base spec is collected, covering logs, metrics, and pod status.
- **When memory or CPU crosses a configured threshold** — a bundle is triggered automatically, capturing router state before conditions worsen further.

Bundles are pushed to a customer-configured S3 or GCS bucket. Apollo cannot access your bundles — sharing is always your choice.

### Sharing with support

When opening a ticket, support can ask for the most recent bundle from around the time of the incident. Since scheduled collection has been running, there is likely a healthy baseline bundle to compare against — making diagnosis significantly faster than a single reactive snapshot.
