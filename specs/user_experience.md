# User Experience

## The full lifecycle at a glance

```
Customer wants to collect data
    - They have hit an issue and want to collect data to attach to an support ticket
    - They want to collect a "healthy" snapshot
        │
        ▼
User (or platform team) triggers collection — via the chart, or with the Apollo Operator
        │
        ▼
.tar.gz support bundle produced, redacted automatically
        │
        ▼
Customer inspects bundle contents (optional)
        │
        ▼
Customer shares bundle with support (or keeps it for their own knowledge)
        │
        ▼
Support has: router version, sanitized config, metrics
             (if enabled), logs, pod state
        │
        ▼
(Future) - Temporary dashboard created for support with the metrics collected
         - Bundle fed into RTF to spin up REP cluster for issue reproduction
```

---

## On-demand (flare-style) collection

**Note: this tool currently supports Kubernetes deployments only.** Non-k8s deployments, including ECS, Fargate, or standalone EC2/VM deployments, aren't covered by this flow. If you're running on ECS or another non-k8s environment, the closest equivalent today is a manual collection: your sanitized `router.yaml`, router version, recent logs (via CloudWatch Logs export, for example), and container-level CPU/memory metrics (via CloudWatch Container Insights, for example) cover much of the same ground the automated bundle would.

### Which path applies to you

The tool supports three deployment tiers in v1:

| Deployment | Support in v1 | What you supply |
| --- | --- | --- |
| **Apollo Operator** | Full support, zero config once enabled | Nothing |
| **Official Apollo router Helm chart** | Full support | `namespace` only |
| **Raw manifests / custom deployment** | Supported | `namespace`, `selector`, `configMapName` |

If you deployed the router with a hand-authored manifest or a custom chart that doesn't follow the official chart's conventions, this tool still works — you'll just need to supply more. None of the official chart's conventions (standard labels, known ConfigMap naming) apply, so the tool can't locate your router's config or pod on its own. Supply your namespace, pod selector, and ConfigMap name, and the same chart and collection engine used for every other tier handles the rest.

## Collection Modes

Getting a spec into the cluster is done through a single Helm chart, `router-diagnostics`, with a `mode` value controlling how collection actually runs. Both modes collect the same spec, but the shape of what runs, where, and what it needs is genuinely different:

| | `mode: local` | `mode: job` |
| --- | --- | --- |
| Who runs collection | You, from your own machine with your own kubectl access | A Kubernetes Job, in-cluster, using its own ServiceAccount |
| What gets installed | Spec ConfigMap only | Spec ConfigMap + Job + ServiceAccount/RBAC (namespace-scoped and cluster-scoped) |
| `support-bundle` binary | Pinned by the `router-diagnostics` Helm plugin | Pinned by Apollo's published Job image |
| Where the bundle lands | Your current directory | In-cluster; your platform team retrieves it (`specs/storage/`) |
| Use when | You have kubectl access to production | Your kubectl access is restricted and a platform team runs it on your behalf |

See [Permissions for on-demand collection](#permissions-for-on-demand-collection) below for exactly what each mode needs.

**If you use the Apollo Operator**, you don't need this chart at all — the Operator installs the same spec for you, with the values already filled in. You do still need the plugin from step one. Skip to [Apollo Operator customers](#apollo-operator-customers) below.

## Local mode

### Step 1: Install the Apollo router-diagnostics plugin
Install the `router-diagnostics` Helm plugin on the machine you'll collect from.

```bash
helm plugin install https://github.com/apollographql/router-diagnostics-helm-plugin
```

This gives you a single `helm router-diagnostics collect` command for collecting a support bundle, see [Step two](#step-two-install-the-helm-chart) below. The plugin also comes with its own pinned copy of the troubleshoot.sh `support-bundle` binary, and, if your router's metrics are enabled, it sets up and tears down the port-forward `router-metrics` needs to reach them. See [Metrics require the Prometheus endpoint to be enabled](#metrics-require-the-prometheus-endpoint-to-be-enabled) below.

### Step two: install the Helm chart

**If you deployed with the official Apollo Helm chart:**

```bash
helm install router-diagnostics apollo/router-diagnostics \
  --namespace production \
  --set namespace=production \
  --set mode=local
```

`namespace` is the only value you need to supply. The chart's collectors target your router by its standard `app.kubernetes.io/name=router` label — no release name, selector, or ConfigMap name is needed **for the official chart.**

**If you use a raw-manifest or custom deployment:**

```bash
helm install router-diagnostics apollo/router-diagnostics \
  --namespace production \
  --set namespace=production \
  --set selector="app=my-router" \
  --set configMapName=my-config \
  --set mode=local
```

Since none of the official chart's conventions apply to your deployment, supply your pod selector and ConfigMap name in addition to the namespace, so the chart's collectors know where to find your router and its configuration.

### Step three: collect a support bundle

```bash
helm router-diagnostics collect
```

## Job mode

If you don't have kubectl access to production, use the same chart with `mode: job`. A platform team member with cluster access installs it:

```bash
helm install router-diagnostics apollo/router-diagnostics \
  --namespace production \
  --set namespace=production \
  --set mode=job
```

If you're on a raw-manifest or custom deployment, also set `selector` and `configMapName` as shown above.

The Job runs the collection automatically using a namespace-scoped ServiceAccount, and the platform team retrieves the completed bundle. See `specs/storage/`. Installing this mode needs someone who can create Jobs, namespace RBAC, *and* cluster-scoped RBAC — see [Permissions for on-demand collection](#permissions-for-on-demand-collection) below for the full grant list.

**If your cluster runs a service mesh, the Job's pod doesn't join it by default.** Sidecar injection is disabled automatically so the Job reliably reaches `Completed` instead of getting stuck in `Running` waiting on a long-lived sidecar. If your platform team's policy requires every pod to be in the mesh, this can be overridden. See `specs/deployment/v1/v1.md` → Service mesh environments for how to override it.

## Apollo Operator customers

Zero configuration. The Operator writes the spec into a cluster ConfigMap directly, filling in its values from the deployment conventions it already knows. It is the same spec every other tier runs — only the values come from the Operator instead of from you. Run:

```bash
kubectl support-bundle --load-cluster-specs
```

No chart install and no values to supply — the `support-bundle` plugin from step one is the only thing you set up.

---

## What you get, whichever path you used

The rest of this section applies to **every** path — `mode: local`, `mode: job`, and the Apollo Operator. Only where a path differs is it called out.

### Support tool output

Collection produces a support bundle — a `support-bundle-<timestamp>.tar.gz` archive, a point-in-time snapshot of the router and cluster state. Where it lands depends on how you ran it:

- **`mode: local`** — the file appears in your current directory.
- **`mode: job`** — the Job writes it in-cluster and your platform team retrieves it. See `specs/storage/`
- **Apollo Operator** - see `specs/deployment/v1/operator.md`

It includes router version, sanitized configuration, recent logs, metrics (if you've enabled the Prometheus endpoint), and pod status. Your Redis configuration and any Redis errors in the router logs are captured, so support can still see how Redis is configured and whether the router is failing against it. See `specs/collection/output.md` for exactly what the extracted archive looks like, including a worked directory-tree example.

Sensitive data is redacted automatically before the output bundle is created — see [Redaction](#redaction) below. You can inspect the bundle contents before sharing. Nothing persists in the cluster after collection completes, though the chart itself remains installed unless you remove it — see [Cluster footprint](#cluster-footprint) below.

### Metrics require the Prometheus endpoint to be enabled

The metrics collector targets the official chart's known metrics port (`9090`). Two settings in your `router.yaml` need to be in place for it to collect anything:

- `telemetry.exporters.metrics.prometheus.enabled: true` — turns the exporter on.
- `telemetry.exporters.metrics.prometheus.listen` — the `host:port` the exporter binds to. The host must be reachable from outside the router container — binding to loopback won't work even with the exporter enabled. The port must also stay `9090`, as the collector targets that port specifically and has no way to discover a different one. Changing it (for example to avoid a conflict with another workload) makes this section empty the same way an unreachable host would.

Note that the **router chart's** `serviceMonitor.enabled` value (not `router-diagnostics`) is a *different* switch. It exposes the metrics port on the Service and renders a ServiceMonitor for your own Prometheus, but it does not enable the exporter — the two settings above are what do that. You can have one without the other.

If the exporter is off, or bound somewhere the collector can't reach, that section of the bundle will simply be empty — the rest of the bundle is unaffected.

**Under `mode: local` on the official chart, reaching this port also requires bridging your machine to the cluster network**, since the router's Service DNS name doesn't resolve outside it. `helm router-diagnostics collect` handles this for you.

**If you're on a raw-manifest or custom deployment**, the collector has no way to discover your metrics port so this section will be empty if metrics don't go to port `9090`.

**If you're on the Apollo Operator**, see the Operator's own documentation for whether metrics are collected — the port is set by the Operator rather than by you, so it isn't something you configure.

**A service mesh enforcing strict mTLS can also empty this section**, even with the exporter correctly configured above — this applies to `mode: local` and `mode: job` alike, since collection runs from outside the mesh either way. See `specs/deployment/v1/v1.md` → Running outside the mesh doesn't have to mean losing metrics.

**If you're running `mode: local`**, there's one more step: your machine can't reach the router's in-cluster address on its own, so run `kubectl port-forward svc/<router-service> 9090:9090` in a separate terminal before collecting. Skip this and `router-metrics` fails with a connection error instead of coming back empty. `mode: job` doesn't need this — the Job runs inside the cluster already. See `specs/deployment/v1/v1.md` → Prerequisite: reaching router-metrics under `mode: local`.

### Redaction

Redaction runs automatically with no configuration needed. JWT/auth config, header values, operation bodies in logs, subgraph URLs are redacted automatically. `APOLLO_KEY` is never collected under any circumstances.

### Cluster footprint

Installing the chart creates a persistent object in your cluster — the spec ConfigMap, plus Helm release metadata. This is minimal but not zero. If you'd rather leave nothing behind, remove the chart after collecting:

```bash
helm uninstall router-diagnostics --namespace production
```

If you expect to run diagnostics more than once, you may prefer to leave it installed. On `mode: local`, subsequent collections then only need `helm router-diagnostics collect`.

### Permissions for on-demand collection

Installing with `mode: local` requires permission to create a ConfigMap in the target namespace — the same level of access needed to install the router itself. `helm router-diagnostics collect` then runs using your existing kubectl credentials; no additional ServiceAccount is created for that step. Reaching `router-metrics` also needs `create` on the `pods/portforward` subresource in the router's namespace — port-forwarding to a Service resolves to one of its pods under the hood, and `helm router-diagnostics collect` does this on your behalf. Declining it doesn't fail collection, it only means `router-metrics` throws an error.

Installing with `mode: job` requires more: creating a Job, a ServiceAccount, a Role/RoleBinding, and — because container memory/CPU come from the kubelet — cluster-scoped RBAC. Creating cluster-scoped RBAC is a broader capability than installing the router needs, so whoever installs the chart in `mode: job` needs more access than someone who could simply run `mode: local` themselves.

Collection itself needs read access in the router's namespace to pods, pod logs, ConfigMaps, and deployments — standard permissions for anyone managing a k8s workload — plus three separate cluster-scoped grants, deliberately kept independent so you can decline the more sensitive ones without losing the others:

- **`list`/`get` on `nodes`** — an ordinary, low-risk read of node objects. This is what surfaces node pressure conditions (`MemoryPressure`, `DiskPressure`).
- **`get` on `nodes/proxy`** — required by the API server for any request proxied through it to a kubelet, regardless of what's being asked for. This is a broader grant than it may look: Kubernetes' own documentation notes that `nodes/proxy` "provides access to privileged kubelet APIs that can retrieve container logs or execute and attach to pod processes... This access bypasses audit logging and admission control," and is explicitly "not a read-only permission." What this tool actually does with it is read-only — it only ever asks for the kubelet's stats endpoint — but the grant itself authorizes more than that one use.
- **`get` on `nodes/stats`** — required separately by the kubelet's own authorization check specifically for the stats endpoint. This is what actually narrows what the kubelet will serve once `nodes/proxy` gets the request there; it does not replace `nodes/proxy`.

Node access alone is the only one of the three that reaches outside the namespace with no other caveats. All three are read-only in what this tool does with them.

**`pods/exec` is not required** — nothing runs inside your router container.

If you'd rather not grant `nodes/proxy`/`nodes/stats`, you can decline both and keep `nodes` access: you'll still get OOM kills, restart counts, configured limits, and node pressure conditions, but you'll lose container memory and CPU usage over time. `nodes/proxy` and `nodes/stats` are only useful together — declining either one loses the same capability, so there's no reason to grant one without the other.

### Sharing with support

Attach the `.tar.gz` to your support ticket.
