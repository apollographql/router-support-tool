---
category: feat
breaking: false
---

Run the collection Job under your own ServiceAccount with `job.serviceAccount.name`

In `mode: job`, set `job.serviceAccount.name` to the name of a ServiceAccount that already
exists in the release namespace. The chart then creates no ServiceAccount, Role, RoleBinding,
ClusterRole or ClusterRoleBinding, so installing it needs no RBAC permissions, and the Job
runs as the ServiceAccount you named. That ServiceAccount must hold the grants listed in the
specs, which are the ones the chart would otherwise create. Without them, the collection
reports what it could not read.

Nothing changes if you leave the value unset.
