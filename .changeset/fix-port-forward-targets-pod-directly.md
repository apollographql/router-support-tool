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

Under `mode: local`, the single `http` collector targeting `localhost:metricsPort` is replaced
with a `hostCollectors.run` collector whose embedded shell script loops over every pod matching
the selector, sequentially port-forwards each pod's metrics port to localhost, and writes each
pod's scrape to its own `<pod-name>.txt` file. `collect.sh` no longer sets up a port-forward
before invoking `support-bundle` — all port-forward logic is embedded in the run collector's
shell script.
