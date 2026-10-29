---
category: docs
breaking: false
---

Specify least-privilege container memory and CPU collection for job mode

Job mode currently gets container memory and CPU through the `nodeMetrics` collector, which
needs `nodes`, `nodes/proxy` and `nodes/stats`. `nodes/proxy` is documented by Kubernetes as
not read-only. The specs now describe a `router-resource-usage` script that reads the kubelet
directly from the Job's pod and needs only `nodes/stats`. When a node's kubelet can't be reached
or refuses the request, that node has no memory or CPU figures and the bundle names the reason
for every missing file.

The script sends the Job's ServiceAccount token to each kubelet, so the Job's pod uses a
short-lived projected token (`expirationSeconds: 600`) instead of the default one. The kubelet's
certificate isn't verified. `mode: local` is unchanged.
