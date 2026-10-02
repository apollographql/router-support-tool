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

If you deployed the router with a hand-authored manifest or a custom chart that doesn't follow the official chart's conventions, this tool still works — you'll just need to supply more. None of the official chart's conventions (standard labels, known ConfigMap naming) apply, so the tool can't locate your router's config or pod on its own, and, if you're running collection as a Job (`mode: job`), it can't locate your metrics endpoint either, since that also relies on the same standard label. Supply your namespace, pod selector, and ConfigMap name, and metricsPort (if it differs from the default port of `9090`) and the chart handles the rest. See [Metrics require the Prometheus endpoint to be enabled](#metrics-require-the-prometheus-endpoint-to-be-enabled) for more info on collecting metrics.

## Collection Modes

Getting a spec into the cluster is done through a single Helm chart, `router-diagnostics-chart`, with a `mode` value controlling how collection actually runs. Both modes collect the same spec, but the shape of what runs, where, and what it needs is genuinely different:

| | `mode: local` | `mode: job` |
| --- | --- | --- |
| Who runs collection | You, from your own machine with your own kubectl access | A Kubernetes Job, in-cluster, using its own ServiceAccount |
| What gets installed | Spec ConfigMap only | Spec ConfigMap + Job + ServiceAccount/RBAC (namespace-scoped and cluster-scoped) |
| `support-bundle` binary | Pinned by the router-diagnostics collect script | Pinned by Apollo's published Job image |
| Where the bundle lands | Your current directory | In-cluster; your platform team retrieves it (`specs/storage/`) |
| Use when | You have kubectl access to production | Your kubectl access is restricted and a platform team runs it on your behalf |

See [Permissions for on-demand collection](#permissions-for-on-demand-collection) below for exactly what each mode needs.

## Local mode

### Step 1: Download the router-diagnostics collect script
Download the collect script onto the machine you'll collect from, and make it executable.

```bash
curl -sSLo collect.sh https://storage.googleapis.com/<bucket>/router-diagnostics-collect.sh
chmod +x collect.sh
```

This gives you a single `./collect.sh` command for collecting a support bundle, see [Step two](#step-two-install-the-helm-chart) below.

### Step two: install the Helm chart

**If you deployed with the official Apollo Helm chart:**

```bash
helm install router-diagnostics oci://registry-1.docker.io/apollograph/router-diagnostics-chart \
  --namespace production \
  --set namespace=production \
  --set mode=local
```

`namespace` is the only value you need to supply. The chart's collectors target your router by its standard `app.kubernetes.io/name=router` label.

**If you use a raw-manifest or custom deployment:**

```bash
helm install router-diagnostics oci://registry-1.docker.io/apollograph/router-diagnostics-chart \
  --namespace production \
  --set namespace=production \
  --set selector="app=my-router" \
  --set configMapName=my-config \
  --set mode=local
```

Since none of the official chart's conventions apply to your deployment, supply your pod selector and ConfigMap name in addition to the namespace, so the chart's collectors know where to find your router and its configuration.

### Step three: collect a support bundle

```bash
./collect.sh --namespace production
```

## Job mode

If you don't have kubectl access to production, use the same chart with `mode: job`. A platform team member with cluster access installs it:

```bash
helm install router-diagnostics oci://registry-1.docker.io/apollograph/router-diagnostics-chart \
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

**A populated configuration section means a `router.yaml` matching the expected ConfigMap was found, it does not confirm that's the config your router process actually has loaded.** If your router reads its config from somewhere other than the ConfigMap this tool looks for, a file on a volume, for example, the config section may be empty, or may contain something that looks plausible but has since diverged from what's actually running.

Sensitive data is redacted automatically before the output bundle is created — see [Redaction](#redaction) below. You can inspect the bundle contents before sharing. Nothing persists in the cluster after collection completes, though the chart itself remains installed unless you remove it — see [Cluster footprint](#cluster-footprint) below.

### Metrics require the Prometheus endpoint to be enabled

The metrics collector targets port `9090` by default. You can override this default via the chart's `metricsPort` value, see below. Two settings in your `router.yaml` need to be in place for it to collect anything:

- `telemetry.exporters.metrics.prometheus.enabled: true` — turns the exporter on.
- `telemetry.exporters.metrics.prometheus.listen` — the `host:port` the exporter binds to. The host must be reachable from outside the router container — binding to loopback won't work even with the exporter enabled. If you change the port, set the chart's `metricsPort` to match. Leaving `metricsPort` unset while the exporter binds to a non-default port makes this section empty the same way an unreachable host would.

Note that the **router chart's** `serviceMonitor.enabled` value (not `router-diagnostics-chart`) is a *different* switch. It exposes the metrics port on the Service and renders a ServiceMonitor for your own Prometheus, but it does not enable the exporter — the two settings above are what do that. You can have one without the other.

If the exporter is off, or bound somewhere the collector can't reach, that section of the bundle will simply be empty — the rest of the bundle is unaffected.

**Under `mode: local`, reaching this port also requires bridging your machine to the cluster network**, since pod IPs aren't reachable directly from outside the cluster. This is handled automatically by our chart's own script, run as the `router-metrics` collector. It resolves matching pods and port-forwards each one in turn.

**If you're on a raw-manifest or custom deployment**, the `selector` you already set to locate your router is also what enables metrics collection under `mode: job`. This tier has no fixed label to resolve pods from otherwise, so leaving `selector` unset means no pods to try, and this section stays empty. If your exporter listens on a port other than `9090`, also set `metricsPort`. Under `mode: local`, the collector always targets `localhost:<metricsPort>` (default `9090`) once a pod is bridged.

**If you're on the Apollo Operator**, see the Operator's own documentation for whether metrics are collected — the port is set by the Operator rather than by you, so it isn't something you configure.

**A service mesh enforcing strict mTLS can also empty this section**, even with the exporter correctly configured above — this applies to `mode: local` and `mode: job` alike, since collection runs from outside the mesh either way. See `specs/deployment/v1/v1.md` → Running outside the mesh doesn't have to mean losing metrics.

### Redaction

Redaction runs automatically with no configuration needed. JWT/auth config, header values, operation bodies in logs, subgraph URLs are redacted automatically.

`APOLLO_KEY` is never collected **as long as it's stored in a Kubernetes Secret and referenced via `secretKeyRef`**, the recommended setup, and what the official Apollo router Helm chart produces. In that case the key is structurally isolated from everything this tool reads.

That guarantee does not extend to a customer who sets `APOLLO_KEY`, or any other secret, as a literal env value. For this case there is a redaction safety net, not structural isolation. **If your deployment sets secrets as literal env values rather than through Kubernetes Secrets, inspect your bundle before sharing it**, the same way you would for any other config you're not certain is fully covered.

### Cluster footprint

Installing the chart creates a persistent object in your cluster — the spec ConfigMap, plus Helm release metadata. This is minimal but not zero. If you'd rather leave nothing behind, remove the chart after collecting:

```bash
helm uninstall router-diagnostics --namespace production
```

If you expect to run diagnostics more than once, you may prefer to leave it installed. On `mode: local`, subsequent collections then only need `./collect.sh --namespace production` again.

### Permissions for on-demand collection

Installing with `mode: local` requires permission to create a ConfigMap in the target namespace — the same level of access needed to install the router itself. `collect.sh` then runs using your existing kubectl credentials; no additional ServiceAccount is created for that step. Reaching `router-metrics` also needs `create` on the `pods/portforward` subresource in the router's namespace because `router-metrics` port-forwards directly to each matching pod under the hood as part of running `support-bundle` itself. Declining it doesn't fail collection, it only means `router-metrics` throws an error.

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
