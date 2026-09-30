---
category: fix
breaking: false
---

Port-forward directly to a pod instead of via Service, and degrade gracefully on lookup failure

The metrics port-forward now targets `pod/<name>` rather than `svc/<name>`, removing the
Service as a dependency and making explicit that only one pod's metrics are collected. A
failed `kubectl get pods` call now warns and continues rather than aborting the run, consistent
with the "no matching pod" case.
