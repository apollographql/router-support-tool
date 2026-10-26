---
category: fix
breaking: false
---

Redact router.yaml secrets in the `last-applied-configuration` annotation

A ConfigMap created with `kubectl apply` carries a second copy of `router.yaml` in its
`kubectl.kubernetes.io/last-applied-configuration` annotation and is collected in
`cluster-resources/configmaps/*.json`. That copy is a JSON string inside a JSON string, so its
quotes and newlines are escaped twice, and the redactors for JWKS fetch headers, header
`insert`/`propagate` values and defaults, Redis `username`/`password` and the subgraph URL
override only allowed for one level of escaping. They masked the data copy and left the
annotation copy unredacted. The patterns now accept any number of backslashes.
