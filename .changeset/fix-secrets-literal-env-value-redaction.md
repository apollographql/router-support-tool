---
category: fix
breaking: false
---

Redact secrets set as literal pod-spec env values

`clusterResources` collects the full pod spec for every pod/deployment/replicaset/etc. in the
namespace, literal env values included. A customer on a raw-manifest or custom deployment who
sets `APOLLO_KEY` (or another secret) as a literal `value:` instead of via `secretKeyRef` had
that value sitting unredacted in `cluster-resources/{pods,deployments,replicasets}/*.json`.

Adds two new redactors, unscoped (no fileSelector), so they run against every file in the bundle,
matching any env var name ending in KEY/_KEY or PASS/_PASS and extends the existing Redis and
TLS private key redactors to run unscoped.
