---
category: fix
breaking: false
---

Fix redundant `router-metrics` bundle path under `mode: local`

The `router-metrics` host collector's `collectorName` and `outputDir` were
both `router-metrics`, which troubleshoot.sh nests as `host-collectors/run-host/router-metrics/router-metrics/<pod>.txt`.
`outputDir` is now `pods`, so per-pod metrics land at `host-collectors/run-host/router-metrics/pods/<pod>.txt`.
