---
category: docs
breaking: false
---

Correct the memory and CPU claims in the specs and docs

The router's Prometheus endpoint does not serve `process_resident_memory_bytes` or
`process_cpu_seconds_total`. It serves only jemalloc memory gauges and only on builds with
jemalloc. The specs and docs no longer list those two signals. Container RSS and CPU come
from the kubelet Summary API through the `nodeMetrics` collector, which needs `nodes`,
`nodes/proxy` and `nodes/stats`. `job.collectNodeMetrics: false` now says plainly what is
lost.
