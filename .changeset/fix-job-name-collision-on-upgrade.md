---
category: fix
breaking: true
---

Fix `mode: job` failing to re-collect via `helm upgrade`/`helm install`

A second `helm upgrade` under `mode: job` always failed with a Kubernetes "field is immutable"
error, because the Job's fixed name (`router-diagnostics-job`) meant every upgrade tried to
mutate the same Job's `spec.template`, which Kubernetes does not allow. A second
`helm install` into the same release name failed outright with "cannot re-use a name
that is still in use."

Each collection now gets its own uniquely-named Job, `router-diagnostics-job-{{ .Release.Revision }}`,
with `helm.sh/resource-policy: keep` so Helm doesn't prune the previous run's Job the
moment a new one supersedes it.

**Breaking**: The Job's name is no longer the fixed `router-diagnostics-job`. Anything
that referenced that name directly needs to use `router-diagnostics-job-<n>` instead.
Upgrading an existing `mode: job` install to this version also prunes its current Job
once, during that one upgrade, since the old fixed name predates the `resource-policy:
keep` annotation. Every upgrade after that is safe. The ServiceAccount/Role/RoleBinding
name (`router-diagnostics-job`) is unchanged.
