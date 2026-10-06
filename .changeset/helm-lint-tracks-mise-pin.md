---
category: ci
breaking: false
---

Make CI's chart render/lint and spec lint jobs track `mise.toml`'s pinned versions

`static-checks.yaml`'s `helm_lint` and `spec_lint` jobs installed Helm via a separately
hardcoded `azure/setup-helm` version, decoupled from `mise.toml`'s own `helm` pin -
confirmed this meant a Renovate bump to the chart's own `mise.toml`-pinned Helm version
would never actually be exercised by the jobs that render, lint, and schema-validate the
chart. `helm_lint`'s hardcoded `kubeconform` curl install had the same problem. Both jobs
now install tools via `mise`, so whatever version is pinned in `mise.toml` is what's
actually tested.
