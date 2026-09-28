---
category: fix
breaking: false
---

Fix collect.sh crashing instead of degrading gracefully when no Service matches

`kubectl get svc -o jsonpath='{.items[0].metadata.name}'` errors out ("array index out of
bounds") when zero Services match the selector, rather than printing empty output - so a
wrong or missing selector/namespace made `collect.sh` hard-exit before `support-bundle`
ever ran, producing no bundle at all.

Caught by the new integration test (`testing/chainsaw/multi-release`) added to verify
specs/collection/base_spec.md's "Each router release in a namespace gets its own file in
the support bundle" claim - two ConfigMaps labeled `app.kubernetes.io/name=router` with no
backing Service reproduced this exact crash before the fix.
