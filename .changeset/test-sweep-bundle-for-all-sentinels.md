---
category: test
breaking: false
---

Search the whole RTF bundle for every redaction sentinel

The `full` redaction RTF variants now search every file in the extracted bundle for each
`SENTINEL_*` secret the variant's ConfigMap fixture plants, instead of checking the dedicated
`configMap` collector's file alone. `router.yaml` is also collected in
`cluster-resources/configmaps/*.json` and, for a ConfigMap created with `kubectl apply`, in its
`last-applied-configuration` annotation, where it is escaped twice. A failure lists each
leaked sentinel with every file it was found in.
