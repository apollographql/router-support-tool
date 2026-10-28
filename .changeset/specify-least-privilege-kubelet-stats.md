---
category: docs
breaking: false
---

Specify least-privilege container memory and CPU collection for job mode

Job mode currently gets container memory and CPU through the `nodeMetrics` collector which
needs `nodes`, `nodes/proxy` and `nodes/stats`. `nodes/proxy` is documented by Kubernetes as
not read-only. The specs now describe a `router-resource-usage` script that reads the kubelet
directly from the Job's pod and needs only `nodes/stats` with the kubelet's cAdvisor endpoint
(`nodes/metrics`) as an opt-in through `job.collectCadvisorMetrics`. When a node's kubelet can't
be reached or refuses the request, the script falls back to the metrics API (`metrics.k8s.io`),
which needs only a namespaced Role. `job.nodeStatsSource: apiServer` keeps the `nodeMetrics`
collector as an opt-in. The script names the reason for every missing file. `mode: local` is unchanged.
