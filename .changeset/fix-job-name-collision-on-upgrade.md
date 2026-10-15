---
category: fix
breaking: true
---

Fix `mode: job` failing to re-collect via `helm upgrade`/`helm install`

A second `helm upgrade` under `mode: job` (e.g. to change `job.storage.*` or just to
trigger another collection) always failed with a Kubernetes "field is immutable" error,
because the Job's fixed name (`router-diagnostics-job`) meant every upgrade tried to
mutate the same Job's `spec.template`, which Kubernetes does not allow. A second
`helm install` into the same release name failed outright with "cannot re-use a name
that is still in use."

Each collection now gets its own uniquely-named Job, `router-diagnostics-job-{{ .Release.Revision }}`,
with `helm.sh/resource-policy: keep` so Helm doesn't prune the previous run's Job the
moment a new one supersedes it — a previous run's Job and logs stay inspectable after
triggering a new one, until its own TTL (`job.ttlSecondsAfterFinished`) cleans it up.

**Breaking**: the Job's name is no longer the fixed `router-diagnostics-job` — anything
that referenced that name directly (scripts, runbooks, `kubectl logs job/router-diagnostics-job`)
needs to use `router-diagnostics-job-<n>` instead. Upgrading an existing `mode: job`
install to this version also prunes its current Job once, during that one upgrade,
since the old fixed name was never annotated with `resource-policy: keep` — every
upgrade after that is safe. The ServiceAccount/Role/RoleBinding name
(`router-diagnostics-job`) is unchanged.

Known edge case, documented in `docs/getting-started/job-mode.mdx` → "Cleaning up":
`helm uninstall` no longer deletes the Job early (same annotation), so a fresh
`helm install` into the same namespace within the Job's TTL window can collide with a
leftover Job from the previous install, since `.Release.Revision` restarts at 1.
