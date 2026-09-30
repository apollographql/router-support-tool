---
category: test
breaking: false
---

Fix race in router-recently-restarted RTF scenario's readiness wait

`env_setup.sh` checked the router pod's `Ready` condition immediately after sending `kill 1`
to its container, with no wait beforehand. That first check could read a stale "True" from
before the kubelet had observed the container exit, breaking out of the wait loop before the
restart (and the previous-container log it's meant to produce) had actually happened. The
scenario's sentinel curl would then hit the router mid-restart and fail to connect, aborting
the run before `helm install router-diagnostics` ever executed. The loop now waits for the
router container's restart count to increment before checking readiness.
