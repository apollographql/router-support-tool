---
category: test
breaking: false
---

Assert the `mode: job` nodeMetrics ClusterRole rules

The `job-mode-rbac` chainsaw test now checks that the ClusterRole holds only `nodes: list` and
`nodes/stats: get`. It also checks that installing with
`job.collectNodeMetrics=false` renders no ClusterRole or ClusterRoleBinding.
