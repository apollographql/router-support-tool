---
category: ci
breaking: false
---

Make CI's chart render/lint and spec lint jobs track `mise.toml`'s pinned versions

`static-checks.yaml`'s `helm_lint` and `spec_lint` jobs installed Helm via a separately
hardcoded `azure/setup-helm` version, decoupled from `mise.toml`'s own `helm` pin.
`spec_lint` now installs tools via `mise`, so whatever version is pinned in `mise.toml` is what's
actually tested.

`helm_lint` now runs every tier/mode combination under both major Helm versions explicitly,
via `mise exec "helm@<version>"`, rather than only ever testing whichever one version happens
to be the current pin.

We also added a custom Renovate manager so both of those explicit versions actually get kept
current automatically.
