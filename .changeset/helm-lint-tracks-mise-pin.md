---
category: ci
breaking: false
---

Make CI's chart render/lint and spec lint jobs track `mise.toml`'s pinned versions

`static-checks.yaml`'s `helm_lint` and `spec_lint` jobs installed Helm via a separately
hardcoded `azure/setup-helm` version, decoupled from `mise.toml`'s own `helm` pin.
`spec_lint` now installs `yq`/`jq` via `mise` too, so those track `mise.toml`'s pins instead
of whatever happens to ship on the runner image.
