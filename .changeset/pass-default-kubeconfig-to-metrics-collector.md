---
category: fix
breaking: false
---

Fix `mode: local` metrics collection for users who rely on the default kubeconfig.

The `router-metrics` script runs with a stripped environment that keeps `KUBECONFIG` but drops
HOME`. Therefore, a `kubectl` using the default `~/.kube/config` found no kubeconfig and the
bundle said it could not list pods. `collect.sh` and `collect.ps1` now set `KUBECONFIG` to
the default kubeconfig when the user hasn't set it.
