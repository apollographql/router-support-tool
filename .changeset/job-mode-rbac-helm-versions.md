---
category: ci
breaking: false
---

Add a Chainsaw test for `mode: job`'s cluster-scoped RBAC, run under both Helm major versions

`mode: job` is the one tier that installs cluster-scoped RBAC. The new `job-mode-rbac`
Chainsaw test installs the chart twice, into two different namespaces,
under both Helm major versions.
