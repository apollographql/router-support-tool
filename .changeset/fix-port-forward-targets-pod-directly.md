---
category: fix
breaking: false
---

Collect metrics from every router pod instead of one arbitrarily selected via a Service

Under `mode: job`, the spec now emits one `http` collector per router pod (named
`router-metrics-<pod-name>`), each targeting that pod's IP directly. Pod IPs are resolved at
Helm render time via `lookup`, so a pod replaced between install and collection produces a 404
for that slot. The `routerServiceName` and `metricsTargetHost` helpers, which previously 
resolved a single Service host, are removed.

Under `mode: local`, `collect.sh`'s port-forward now targets `pod/<name>` directly rather than
`svc/<name>`, removing the Service as a dependency. A failed `kubectl get pods` call now warns
and continues rather than aborting the run, consistent with the "no matching pod" case.
