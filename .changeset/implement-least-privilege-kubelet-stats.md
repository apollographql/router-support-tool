---
category: feat
breaking: true
---

Collect job-mode container memory and CPU from the kubelet with `nodes/stats` only

Under `mode: job` the chart now runs a `router-resource-usage` script that reads the kubelet
directly from the Job's pod and keeps only the router's pods, instead of the `nodeMetrics`
collector which needed `nodes/proxy`. The ClusterRole holds `nodes` (list) and `nodes/stats`.
When a node's kubelet can't be read, that node has no memory or CPU data and the bundle says
why. The Job's pod now uses a short-lived projected ServiceAccount token
(`expirationSeconds: 600`). Bundles from `mode: job` now hold
one `host-collectors/run-host/router-resource-usage/nodes/<node-name>.json` per node in place of `node-metrics/`,
and the Job image gains a pinned `python3`. `mode: local` is unchanged.
