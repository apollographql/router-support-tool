---
category: fix
breaking: true
---

Fix `mode: job` collecting no router metrics when the chart is rendered by ArgoCD

`mode: job` looked up router pod IPs once, when the chart rendered, using Helm's `lookup`.
`lookup` returns nothing under `helm template`, which is all ArgoCD and similar GitOps tools
run, so those installs collected no metrics and the bundle didn't say why. Under `helm install`,
the IPs also went stale as pods were replaced after install.

The Job now finds the pods matching `selector` each time collection runs and scrapes each one
directly, the same way `mode: local` already does.

**Breaking**: `mode: job` metrics move from `router-metrics-<pod-name>/result.json` to
`host-collectors/run-host/router-metrics/pods/<pod-name>.txt`, the path `mode: local` already
uses. Each file is now the pod's raw Prometheus text response rather than troubleshoot.sh's
`http` result JSON.
