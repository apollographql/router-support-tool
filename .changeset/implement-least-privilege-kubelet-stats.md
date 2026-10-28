---
category: feat
breaking: true
---

Collect job-mode container memory and CPU from the kubelet with `nodes/stats` only

Under `mode: job` the chart now runs a `router-resource-usage` script that reads the kubelet
directly from the Job's pod and keeps only the router's pods, instead of the `nodeMetrics`
collector which needed `nodes/proxy`. The ClusterRole holds `nodes` (list) and `nodes/stats`
plus `nodes/metrics` with the new `job.collectCadvisorMetrics`. When a node's kubelet can't be
read, the script falls back to the metrics API through a new namespaced Role rule. The new
`job.nodeStatsSource: apiServer` keeps the `nodeMetrics` collector. Bundles from `mode: job`
now hold `host-collectors/run-host/router-resource-usage/nodes/<node>/` in place of
`node-metrics/`, and the Job image gains a pinned `python3`. `mode: local` is unchanged.
