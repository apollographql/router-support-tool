---
category: fix
breaking: false
---

Redact a quoted response cache `shared_key` in the `last-applied-configuration` annotation

A quoted `shared_key` was masked in the collected `router.yaml` but not in the
`kubectl.kubernetes.io/last-applied-configuration` annotation that `kubectl apply` stores on a
ConfigMap, which lands in `cluster-resources/configmaps/*.json`. The annotation holds the
`router.yaml` string inside a JSON string inside the file so the quotes around the value are
escaped twice and the redactor only allowed for one level. It now accepts any number of
backslashes before the quote.
