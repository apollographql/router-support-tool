---
category: docs
breaking: false
---

Fix "release name" wording for collected ConfigMap filenames

`data-collected.mdx`, `job-mode-details.mdx`, `local-mode-details.mdx`, and the specs
they're drafted from (`base_spec.md`, `output.md`) described the collected
`configmaps/<namespace>/` filename as `<release-name>.json`. That's wrong for a
raw-manifest or custom deployment, which has no Helm release of the router at all -
confirmed against a real `mode: job` bundle, where the file is actually named after the
matched ConfigMap's own Kubernetes name (`router-config.json` in that case). The two
only coincide on the official Apollo router Helm chart, which happens to name its
ConfigMap after the release.
